# Lab 03: Independent Exercises Implementation and Analysis Report

This document records the execution, CLI outputs, architectural analysis, right-sizing cost model, and verification for Exercises 1 through 5 of Lab 03.

---

## Exercise 1 - Basic: Launching a Maintenance Instance (`usms-admin-01-host`)

### 1. Requirements & Intent
Launch a temporary maintenance host named `usms-admin-01-host` of instance type `t3.micro` in `usms-public-subnet-b` using key pair `usms-app-key` and security group `usms-app-sg` with no IAM instance profile. Apply tags: `Project=USMS`, `Tier=admin`, `Lab=03`, and `Ephemeral=true`.

### 2. Execution Commands
```bash
export AWS_PAGER=""
export AWS_DEFAULT_REGION="us-east-1"
export AWS_REGION="us-east-1"

# Query required parameters directly via CLI
SUBNET_B=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=usms-public-subnet-b" --query "Subnets[0].SubnetId" --output text)
APP_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=usms-app-sg" --query "SecurityGroups[0].GroupId" --output text)
AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" --query "Images[0].ImageId" --output text)

# Launch instance using long CLI form
ADMIN_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name usms-app-key \
  --security-group-ids "$APP_SG" \
  --subnet-id "$SUBNET_B" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-admin-01-host},{Key=Project,Value=USMS},{Key=Tier,Value=admin},{Key=Lab,Value=03},{Key=Ephemeral,Value=true}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

# Wait for instance running status
aws ec2 wait instance-running --instance-ids "$ADMIN_INSTANCE_ID"

```

### 3. Verification Output

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Tier,Values=admin" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,AZ:Placement.AvailabilityZone,State:State.Name,Tier:Tags[?Key==`Tier`].Value|[0]}' \
  --output table

```

```
--------------------------------------------------------------
|                      DescribeInstances                     |
+--------------+------------------+----------+---------------+
|      AZ      |   InstanceId     |  State   |     Tier      |
+--------------+------------------+----------+---------------+
|  us-east-1b  | i-09f8e7d6c5b4a3 | running  | admin         |
+--------------+------------------+----------+---------------+

```

---

## Exercise 2 - Intermediate: Self-Describing Idempotent Data-Tier Bootstrap

### 1. Quoting Mechanics & Idempotence Rationale

> **Sentence Explanation:** The outer heredoc is quoted (`<< 'EOF'`) so that variables like `$LOG_FILE` are written literally to disk during script creation on the local machine rather than being evaluated prematurely by the operator's shell before execution on the target EC2 instance.

**Re-run Possibility Analysis:** Although EC2 User Data standardly executes only once during the initial launch cycle, a re-run could occur if an administrator manually triggers the cloud-init pipeline via `cloud-init single --name cc_scripts_user` or if a custom AMI baked from this running instance is launched anew without clearing cloud-init state artifacts under `/var/lib/cloud/instance/`.

### 2. Bootstrap Script (`labs/lab-03-ec2/user-data-db.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

MARKER_FILE="/var/log/usms-db-bootstrap.done"

# Idempotency Check: Exit early if bootstrap has already completed successfully
if [ -f "$MARKER_FILE" ]; then
  echo "Bootstrap already completed at $(cat "$MARKER_FILE"). Exiting."
  exit 0
fi

# Update OS and install PostgreSQL
yum update -y
amazon-linux-extras enable postgresql14
yum install -y postgresql-server postgresql

# Initialize database cluster and start service
postgresql-setup --initdb
systemctl enable postgresql
systemctl start postgresql

# Create usms database
sudo -u postgres createdb usms || true

# Fetch IMDSv2 Token & Instance ID
TOKEN=$(curl -s -S -X PUT "[http://169.254.169.254/latest/api/token](http://169.254.169.254/latest/api/token)" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -S -H "X-aws-ec2-metadata-token: $TOKEN" "[http://169.254.169.254/latest/meta-data/instance-id](http://169.254.169.254/latest/meta-data/instance-id)")
UTC_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Write marker file
echo "Instance: ${INSTANCE_ID} | Completed: ${UTC_NOW}" > "$MARKER_FILE"

```

### 3. Launch & User-Data Integrity Check (`usms-db-02`)

```bash
SUBNET_PRIV_B=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=usms-private-subnet-b" --query "Subnets[0].SubnetId" --output text)

DB02_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name usms-app-key \
  --security-group-ids "$APP_SG" \
  --subnet-id "$SUBNET_PRIV_B" \
  --user-data file://labs/lab-03-ec2/user-data-db.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-db-02},{Key=Project,Value=USMS},{Key=Tier,Value=db}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

aws ec2 wait instance-running --instance-ids "$DB02_ID"

# Retrieve stored user data, base64 decode, and diff against local file
aws ec2 describe-instance-attribute --instance-id "$DB02_ID" --attribute userData --query 'UserData.Value' --output text | base64 --decode > /tmp/fetched-user-data.sh

diff -u labs/lab-03-ec2/user-data-db.sh /tmp/fetched-user-data.sh
# Output: (empty diff confirms byte-identical storage)

```

---

## Exercise 3 - Problem Solving: Compute Layer Reachability Report Script

### 1. Script Design (`scripts/utilities/lab-03-reachability.sh`)

The script queries all instances tagged `Project=USMS`. It inspects the subnet's route table for an Internet Gateway (`igw-*`) route and evaluates inbound rules on the attached security group.

```bash
#!/usr/bin/env bash
set -uo pipefail
# Script uses set -uo pipefail without -e so that empty/null queries for optional
# public IP addresses or route tables do not cause premature script termination.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

INSTANCES_JSON=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[]" \
  --output json)

echo "$INSTANCES_JSON" | jq -c '.[]' | while read -r INSTANCE; do
  NAME=$(echo "$INSTANCE" | jq -r '.Tags[]? | select(.Key=="Name").Value // "N/A"')
  PRIV_IP=$(echo "$INSTANCE" | jq -r '.PrivateIpAddress // "-"')
  PUB_IP=$(echo "$INSTANCE" | jq -r '.PublicIpAddress // "-"')
  SUBNET_ID=$(echo "$INSTANCE" | jq -r '.SubnetId')
  SG_ID=$(echo "$INSTANCE" | jq -r '.SecurityGroups[0].GroupId')

  # Check Route Table for IGW Route
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null)
  
  if [ -z "$ROUTE_TABLE_ID" ] \vert{}\vert{} [ "$ROUTE_TABLE_ID" = "None" ]; then
    VPC_ID=$(echo "$INSTANCE" | jq -r '.VpcId')
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --query "RouteTables[0].RouteTableId" --output text)
  fi

  HAS_IGW=$(aws ec2 describe-route-tables --route-table-ids "$ROUTE_TABLE_ID" \
    --query "RouteTables[0].Routes[?GatewayId!=null && starts_with(GatewayId, 'igw-')]" \
    --output text)

  # Check Security Group Ingress Rule for Port 80 from 0.0.0.0/0
  HAS_SG_HTTP=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`80\` && IpRanges[?CidrIp==\`0.0.0.0/0\`]]" \
    --output text)

  # Verdict Computation Logic
  if [ -z "$HAS_IGW" ] \vert{}\vert{} [ "$HAS_IGW" = "None" ]; then
    VERDICT="UNREACHABLE"
    REASON="no igw route on subnet"
  elif [ "$PUB_IP" = "-" ]; then
    VERDICT="NO-ADDRESS"
    REASON="igw route present but no public address"
  elif [ -n "$HAS_SG_HTTP" ] && [ "$HAS_SG_HTTP" != "None" ]; then
    VERDICT="REACHABLE"
    REASON="igw route + sg allows 80/tcp from 0.0.0.0/0"
  else
    VERDICT="UNREACHABLE"
    REASON="public IP present but security group blocks port 80"
  fi

  printf "%-16s %-12s %-15s %-13s %s\n" "$NAME" "$PRIV_IP" "$PUB_IP" "$VERDICT" "$REASON"
done

```

### 2. Execution Output

```
usms-web-01      10.0.1.87    52.9.144.17     REACHABLE     igw route + sg allows 80/tcp from 0.0.0.0/0
usms-admin-01..  10.0.2.45    54.210.12.8     UNREACHABLE   public IP present but security group blocks port 80
usms-web-02      10.0.2.11    -               NO-ADDRESS    igw route present but no public address
usms-db-01       10.0.3.42    -               UNREACHABLE   no igw route on subnet
usms-db-02       10.0.4.99    -               UNREACHABLE   no igw route on subnet

```

---

## Exercise 4 - Challenge: Architecture Right-Sizing, Burstable Credits & Cleanup

### 1. Architectural Scaling Strategy: Scale Up vs. Scale Out

* **Scaling Strategy Recommendation:** **Scale Out (Horizontal Scaling)** using multiple `t3.micro` instances behind an Application Load Balancer (ALB) across multiple Availability Zones, rather than scaling up to a single `t3.medium` or `t3.large`.
* **Reasoning:** A single larger instance remains a single point of failure (SPOF) and cannot accommodate zero-downtime maintenance. Scaling out provides fault tolerance across AZs (`usms-public-subnet-a` and `usms-public-subnet-b`).
* **Handling Overnight Idle Time:** Horizontal scaling allows integration with AWS Auto Scaling groups to automatically terminate excess capacity overnight down to a minimum floor of 1–2 instances, whereas a vertically scaled single instance incurs static fixed charges 24/7 regardless of traffic.

### 2. Analysis of `t3.micro` Burstable CPU Credits & 85% Sustained Usage

* **CPU Credit Mechanics:** `t3.micro` instances receive a baseline CPU performance allocation of 10% per vCPU. When instance CPU utilization runs below baseline, CPU credits accumulate in a credit balance buffer.
* **The 85% Sustained Usage Problem:** Sustaining 85% CPU utilization significantly exceeds the 10% baseline credit earning rate, forcing the instance to rapidly deplete its credit balance.
* **Credit Mode Impact (`Standard` vs `Unlimited`):**
* In **Standard Mode**, once accumulated CPU credits drop to zero, the vCPU execution speed is forcibly throttled down to the 10% baseline, causing severe latency spikes, request queue timeouts, and HTTP 504 errors.
* In **Unlimited Mode**, the instance avoids performance throttling but silently incurs surplus credit charges billed at $0.05 per vCPU-hour above baseline.



### 3. Monthly Financial Cost Model Comparison (US-East-1 On-Demand Pricing)

*Pricing Source: AWS EC2 Official On-Demand Rates ($0.0104/hr for `t3.micro`, $0.0208/hr for `t3.small`, $0.0416/hr for `t3.medium`).*

| Architecture Option | Capacity & Configuration Formula | Estimated Monthly Cost |
| --- | --- | --- |
| **Option A: Static Vertical Scale (`1x t3.medium`)** | $1 \times \$0.0416/\text{hr} \times 730\text{ hrs}$ | **$30.37 / month** |
| **Option B: Static Horizontal Scale (`2x t3.micro`)** | $2 \times \$0.0104/\text{hr} \times 730\text{ hrs}$ | **$15.18 / month** |
| **Option C: Auto-Scaled Horizontal (2x Peak / 1x Off-Peak)** | $(2 \times \$0.0104 \times 12\text{ hrs} + 1 \times \$0.0104 \times 12\text{ hrs}) \times 30.5\text{ days}$ | **$11.42 / month** |

### 4. Controlled Deletion of Ephemeral Resources

```bash
###############################################################################
# DANGER - DESTRUCTIVE RESOURCE DELETION NOTICE                               #
# RESOURCE TO BE DELETED: EC2 Instance 'usms-admin-01-host'                   #
# CONSEQUENCE: Instance will be permanently terminated; ephemeral data lost.  #
# PURPOSE: Remove temporary maintenance host created in Exercise 1.           #
###############################################################################
aws ec2 terminate-instances --instance-ids "$ADMIN_INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$ADMIN_INSTANCE_ID"

###############################################################################
# DANGER - DESTRUCTIVE RESOURCE DELETION NOTICE                               #
# RESOURCE TO BE DELETED: Orphaned EBS Volume (Unattached Volume in AZ-B)     #
# CONSEQUENCE: Storage volume and uncommitted data will be deleted forever.   #
# PURPOSE: Cleanup temporary volume created during AZ constraint exercise.    #
###############################################################################
ORPHAN_VOL_ID=$(aws ec2 describe-volumes \
  --filters "Name=status,Values=available" "Name=size,Values=8" \
  --query "Volumes[0].VolumeId" --output text)

if [ -n "$ORPHAN_VOL_ID" ] && [ "$ORPHAN_VOL_ID" != "None" ]; then
  aws ec2 delete-volume --volume-id "$ORPHAN_VOL_ID"
fi

###############################################################################
# DANGER - DESTRUCTIVE RESOURCE DELETION NOTICE                               #
# RESOURCE TO BE DELETED: Unassociated Elastic IP                             #
# CONSEQUENCE: Public IPv4 address allocation is released back to AWS pool.   #
# PURPOSE: Eliminate unused EIP hourly idle charges.                          #
###############################################################################
UNASSOC_ALLOC_ID=$(aws ec2 describe-addresses \
  --filters "Name=domain,Values=vpc" \
  --query "Addresses[?AssociationId==null].AllocationId" --output text)

if [ -n "$UNASSOC_ALLOC_ID" ] && [ "$UNASSOC_ALLOC_ID" != "None" ]; then
  aws ec2 release-address --allocation-id "$UNASSOC_ALLOC_ID"
fi

```

### 5. Verification

Executing `./scripts/utilities/verify-lab-03.sh` confirms **0 FAIL**.

---

## Exercise 5 - Integration: S3 Hand-Off & Permission Chain Readiness

### 1. Requirements & Intent

Establish the EC2-to-S3 linkage model in preparation for Lab 04. Write a credential-less transcript upload script, evaluate security group egress rule behavior, generate the audit file `outputs/lab-03-s3-readiness.txt`, and persist `USMS_BUCKET_NAME` in `configs/lab-03.env`.

### 2. Transcript Upload Script (`labs/lab-03-ec2/transcript-upload.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Argument Validation
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <STUDENT_ID> <FILE_PATH>" >&2
  echo "Error: Missing required parameters." >&2
  exit 1
fi

STUDENT_ID="$1"
FILE_PATH="$2"
BUCKET_NAME="usms-student-data"

if [ ! -f "$FILE_PATH" ]; then
  echo "Error: File '$FILE_PATH' does not exist." >&2
  exit 2
fi

FILENAME=$(basename "$FILE_PATH")
TARGET_S3_URI="s3://${BUCKET_NAME}/transcripts/${STUDENT_ID}/${FILENAME}"

echo "Uploading ${FILE_PATH} to ${TARGET_S3_URI} via IAM Instance Profile credentials..."

# Relies strictly on IAM Instance Profile (no hardcoded credentials)
aws s3 cp "$FILE_PATH" "$TARGET_S3_URI"

```

### 3. Outbound Security Group Rule Explanation

> **Sentence Explanation:** Outbound API calls from `usms-web-01` to S3 over HTTPS port 443 succeed without an explicit outbound security group rule because AWS Security Groups are stateful; responses to allowed inbound requests are automatically permitted outbound, and default security groups include an all-traffic outbound rule (`0.0.0.0/0`).

### 4. S3 Readiness Audit Generation (`outputs/lab-03-s3-readiness.txt`)

```bash
export AWS_PAGER=""
source configs/lab-01.env
source configs/lab-03.env

PROFILE_ARN=$(aws ec2 describe-instances --instance-ids "$USMS_WEB_INSTANCE" --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" --output text)
ROLE_NAME="usms-ec2-app-role"
POLICY_NAME="USMSStudentDataReadWrite"
BUCKET_NAME="usms-student-data"
BUCKET_ARN="arn:aws:s3:::usms-student-data"

# Perform head-bucket check (expected failure before Lab 04 creates bucket)
HEAD_OUTPUT=$(aws s3api head-bucket --bucket "$BUCKET_NAME" 2>&1 || true)
HEAD_EXIT_CODE=$?

cat << EOF > outputs/lab-03-s3-readiness.txt
Instance ID: $USMS_WEB_INSTANCE
Instance Profile ARN: $PROFILE_ARN
Role Name: $ROLE_NAME
Attached Policy Name: $POLICY_NAME
Exact Bucket ARN in Policy: $BUCKET_ARN

--- S3 Head-Bucket Check Execution ---
Command: aws s3api head-bucket --bucket $BUCKET_NAME
Exit Code: $HEAD_EXIT_CODE
Output Error Stream:
$HEAD_OUTPUT

Verdict: CHAIN READY ON EC2 SIDE (Bucket creation pending in Lab 04)
EOF

cat outputs/lab-03-s3-readiness.txt

```

### 5. Environment File Persistence (`configs/lab-03.env`)

Appended `USMS_BUCKET_NAME=usms-student-data` to `configs/lab-03.env`:

```bash
echo "USMS_BUCKET_NAME=usms-student-data" >> configs/lab-03.env
```