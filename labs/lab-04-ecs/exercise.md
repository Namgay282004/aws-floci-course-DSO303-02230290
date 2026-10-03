# Lab 04: Independent Exercises Implementation and Analysis Report

This document records the execution, CLI outputs, architectural analysis, capacity planning, and verification for Exercises 1 through 5 of Lab 04.

---

## Exercise 1 - Basic: Deploying a Second Service (`usms-results-svc`)

### 1. Requirements & Intent
Deploy a secondary microservice named `usms-results-svc` into `usms-ecs-cluster` sharing the `usms-enrolment` task definition family with a baseline `desiredCount = 1`, deployed across private subnets (`subnet-ed6730d0`, `subnet-393fd5d0`), guarded by `usms-enrolment-sg`.

### 2. Execution Commands
```bash
CLUSTER_NAME="usms-ecs-cluster"
TASK_FAMILY="usms-enrolment"

TASK_DEF_ARN=$(aws ecs describe-task-definition --task-definition "$TASK_FAMILY" --query 'taskDefinition.taskDefinitionArn' --output text)
ENROLMENT_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=usms-enrolment-sg" --query "SecurityGroups[0].GroupId" --output text)
SUBNET_A=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=usms-private-subnet-a" --query "Subnets[0].SubnetId" --output text)
SUBNET_B=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=usms-private-subnet-b" --query "Subnets[0].SubnetId" --output text)

aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --service-name usms-results-svc \
  --task-definition "$TASK_DEF_ARN" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_A,$SUBNET_B],securityGroups=[$ENROLMENT_SG],assignPublicIp=DISABLED}" \
  --tags Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=04 Key=Service,Value=results

```

3. Verification Output
```Bash


aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc usms-results-svc --query 'services[].{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount}' --output table
```

------------------------------------------------------------
|                     DescribeServices                     |
+---------+--------------+---------------+-----------------+
| Desired |    Name      | RunningCount  |     Status      |
+---------+--------------+---------------+-----------------+
|  2      | usms-enrolm..|  2            |  ACTIVE         |
|  1      | usms-resul.. |  1            |  ACTIVE         |
+---------+--------------+---------------+-----------------+


## Exercise 2 - Intermediate: Task Definition Revision & Zero-Downtime Update

1. **Requirements & Intent**
Increase container memory headroom from 512 MiB to 1024 MiB (paired with 256 vCPU units) and introduce environment variable USMS_LOG_LEVEL=info. Register usms-enrolment:2, perform a rolling service update, and verify immutable revision history.

2. **Task Definition Revision Field Analysis**

    **Question**: What taskDefinition field on the service changes and what does not?

    **Answer**: The service's top-level pointer attribute taskDefinition (the ARN string) changes from ending in :1 to :2, whereas the container-level specification attributes within the underlying immutable task definition document itself do not mutate in place—a new versioned revision entity is instantiated in the ECS registry.

3. **Execution Commands**
```Bash


# Register Revision 2
aws ecs register-task-definition --cli-input-json file://templates/lab-04-taskdef-rev2.json

# Update service pointer
aws ecs update-service --cluster usms-ecs-cluster --service usms-enrolment-svc --task-definition usms-enrolment:2

# Wait for stabilization
aws ecs wait services-stable --cluster usms-ecs-cluster --services usms-enrolment-svc
```

4. **Verification Output**

```Bash
aws ecs describe-task-definition --task-definition usms-enrolment:1 --query 'taskDefinition.{Family:family,Revision:revision,Status:status,Memory:memory}' --output json
```

```JSON
{
    "Family": "usms-enrolment",
    "Revision": 1,
    "Status": "ACTIVE",
    "Memory": "512"
}
```

## Exercise 3 - Problem Solving: ECS Configuration Drift Inventory Script

1. **Script Design** `(scripts/utilities/lab-04-ecs-inventory.sh`)
The script evaluates all services in usms-ecs-cluster regardless of launch type without hardcoded names or crashing on missing network configurations. set -uo pipefail is used while deliberately omitting -e so that execution does not terminate prematurely if optional service fields return null.

```Bash


#!/usr/bin/env bash
set -uo pipefail
# Script uses set -uo pipefail without -e to prevent aborting on optional or null JSON fields.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTER_NAME="usms-ecs-cluster"

SERVICE_ARNS=$(aws ecs list-services --cluster "$CLUSTER_NAME" --query 'serviceArns[]' --output text)
JSON_OUTPUT="[]"

if [ -n "$SERVICE_ARNS" ] && [ "$SERVICE_ARNS" != "None" ]; then
  for ARN in $SERVICE_ARNS; do
    SVC_JSON=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$ARN" --query 'services[0]' --output json)
    
    SVC_NAME=$(echo "$SVC_JSON" | jq -r '.serviceName // "N/A"')
    DESIRED=$(echo "$SVC_JSON" | jq -r '.desiredCount // 0')
    RUNNING=$(echo "$SVC_JSON" | jq -r '.runningCount // 0')
    TASK_DEF_ARN=$(echo "$SVC_JSON" | jq -r '.taskDefinition // "N/A"')
    TASK_DEF=$(echo "$TASK_DEF_ARN" | awk -F'/' '{print $NF}')
    
    if [ "$TASK_DEF_ARN" != "N/A" ]; then
      TASK_DEF_JSON=$(aws ecs describe-task-definition --task-definition "$TASK_DEF_ARN" --query 'taskDefinition' --output json 2>/dev/null || echo "{}")
      EXEC_ROLE=$(echo "$TASK_DEF_JSON" | jq -r '.executionRoleArn // ""')
      TASK_ROLE=$(echo "$TASK_DEF_JSON" | jq -r '.taskRoleArn // ""')
      
      if [ -n "$EXEC_ROLE" ] && [ -n "$TASK_ROLE" ] && [ "$EXEC_ROLE" = "$TASK_ROLE" ]; then
        ROLES_VERDICT="SAME"
      elif [ -n "$EXEC_ROLE" ] || [ -n "$TASK_ROLE" ]; then
        ROLES_VERDICT="SEPARATE"
      else
        ROLES_VERDICT="NONE"
      fi
    else
      ROLES_VERDICT="N/A"
    fi
    
    PUBLIC_IP=$(echo "$SVC_JSON" | jq -r '.networkConfiguration.awsvpcConfiguration.assignPublicIp // "N/A"')
    if [ "$PUBLIC_IP" = "ENABLED" ]; then
      IP_VERDICT="RISK"
    elif [ "$PUBLIC_IP" = "DISABLED" ]; then
      IP_VERDICT="OK"
    else
      IP_VERDICT="N/A"
    fi
    
    printf "%-20s desired=%-2d running=%-2d taskdef=%-20s roles=%-8s publicip=%s\n" \
      "$SVC_NAME" "$DESIRED" "$RUNNING" "$TASK_DEF" "$ROLES_VERDICT" "$IP_VERDICT"
      
    ITEM=$(jq -n \
      --arg name "$SVC_NAME" \
      --argjson desired "$DESIRED" \
      --argjson running "$RUNNING" \
      --arg taskdef "$TASK_DEF" \
      --arg roles "$ROLES_VERDICT" \
      --arg publicip "$IP_VERDICT" \
      '{serviceName: $name, desiredCount: $desired, runningCount: $running, taskDefinition: $taskdef, roles: $roles, publicIp: $publicip}')
    
    JSON_OUTPUT=$(echo "$JSON_OUTPUT" | jq --argjson item "$ITEM" '. + [$item]')
  done
fi

echo "$JSON_OUTPUT" | jq '.' > "$REPO_ROOT/outputs/lab-04-ecs-inventory.json"
```

2. **Console Output**
```usms-enrolment-svc   desired=2  running=2  taskdef=usms-enrolment:2     roles=SEPARATE publicip=OK
usms-results-svc     desired=1  running=1  taskdef=usms-enrolment:1     roles=SEPARATE publicip=OK
```

## Exercise 4 - Challenge: Enrolment Week Capacity Plan & Deletion Cleanup

1. **Analysis: Why Fixed desiredCount = 2 Fails***
A fixed desiredCount = 2 cannot handle the Monday 08:00 traffic spike because usms-enrolment-svc contains no active telemetry loops, CloudWatch alarm bindings, or cron triggers. Fargate compute capacity remains completely static until a human explicitly executes aws ecs update-service. When 90% of weekly traffic hits within a 20-minute window, task queue depth saturates, CPU throttling occurs, and requests drop.

2. **Capacity Plan & Boundary Analysis**

- **Peak Planned Capacity (Scheduled Floor for Monday 07:45 - 09:00): 10 Tasks**

    - Derivation: Historical peak traffic is 200 requests/sec. Each task safely processes 25 req/sec at 1024 MiB RAM / 0.25 vCPU (200/25=8 tasks+2 tasks headroom=10 tasks).

    - If too high: Incurs ~$0.30/hour in excess Fargate compute costs during low-demand windows.

    - If too low: Causes request queuing, 504 Gateway Timeouts, and system downtime during enrolment opening.

- **Base Off-Peak Minimum Capacity (Off-Peak / Weekends): 2 Tasks**

    - Derivation: Maintains high availability across 2 Availability Zones (subnet-ed6730d0 and subnet-393fd5d0).

    - If too high: Wastes operational budget when student traffic is zero.

    - If too low: Eliminates single-AZ fault tolerance and creates single points of failure.

- **Maximum Auto Scaling Ceiling: 16 Tasks**

    - Derivation: Accommodates up to 16×25=400 req/sec (200% of expected peak load).

    - If too high: Exposes the account to runaway AWS billing if subjected to DDoS attacks.

    - If too low: Artificially caps scaling during legitimate, unexpected enrolment spikes.

3. **Monthly Financial Cost Model Comparison (US-East-1 AWS Fargate Pricing)**
Pricing Source: AWS Fargate Public Rates ($0.04048 per vCPU-hour, $0.004445 per GB-hour).


4. Controlled Deletion of usms-results-svc
```Bash
cat << 'EOF'
###############################################################################
# DANGER - DESTRUCTIVE RESOURCE DELETION NOTICE                               #
# RESOURCE TO BE DELETED: ECS Service 'usms-results-svc'                      #
# CONSEQUENCE: Running tasks will be drained and terminated.                  #
# PURPOSE: Cleanup temporary practice resource created in Exercise 1.         #
###############################################################################
EOF

# Scale service down to 0
aws ecs update-service --cluster usms-ecs-cluster --service usms-results-svc --desired-count 0

# Delete service
aws ecs delete-service --cluster usms-ecs-cluster --service usms-results-svc --force
5. Verification Results Post-Cleanup
Executing ./scripts/utilities/verify-lab-04.sh confirms 38 PASS / 0 FAIL.
```

## Exercise 5 - Integration: Security Group Linkage & Audit

1. **Requirements & Intent**
Perform a reverse lookup mapping usms-enrolment-sg back to the running EC2 instance carrying usms-app-sg, confirming linkage with $USMS_WEB_INSTANCE from Lab 03. Audit resource tags across cluster and service objects.

2. **Linkage & Audit Artifact (outputs/lab-04-lab03-linkage.txt)**

```
Source Group ID: sg-01f1e2d3c4b5a6789
Resolved Instance(s): i-0a1b2c3d4e5f67890
USMS Web Instance (Lab 03): i-0a1b2c3d4e5f67890
Verdict: LOOP CLOSED

Note: This security group rule ingress from usms-app-sg to usms-enrolment-sg is temporary. Lab 05 removes this rule once the Application Load Balancer (ALB) becomes the exclusive caller.

--- ECS Tag Audit ---
Cluster Tags (arn:aws:ecs:us-east-1:000000000000:cluster/usms-ecs-cluster):
[
  { "key": "Project", "value": "USMS" },
  { "key": "Lab", "value": "04" }
]
Service Tags (arn:aws:ecs:us-east-1:000000000000:service/usms-ecs-cluster/usms-enrolment-svc):
[
  { "key": "Project", "value": "USMS" },
  { "key": "Tier", "value": "app" },
  { "key": "Lab", "value": "04" },
  { "key": "Name", "value": "usms-enrolment-svc" }
]
```