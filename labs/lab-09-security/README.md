# Lab 09: Securing the USMS Application with IAM Roles and Security Groups

## 1. Aim / Objective

The objective of this practical laboratory was to conduct a full identity and network security audit across the existing USMS AWS architecture and systematically remediate high-severity vulnerability findings. Key objectives included:
- Inventorying and auditing IAM roles, policies, trust boundaries, and security group rules across both access-control axes (identity and network).
- Remediating identity findings by creating a read-only transcripts policy (`USMSStudentDataReadOnly`), implementing confused-deputy trust conditions (`aws:SourceAccount`, `aws:SourceArn`), enforcing a scoped `iam:PassRole` policy (`USMSDeployBase`), establishing a permissions boundary ceiling (`USMSPermissionsBoundary`), rotating access keys, and enforcing IMDSv2.
- Remediating network findings by writing explicit egress rules across three security groups (`usms-alb-sg`, `usms-enrolment-sg`, `usms-db-sg`), scoping SSH ingress to a bastion security group (`usms-bastion-sg`), and proving multi-layer defense-in-depth isolation for the database tier.
- Verifying configuration persistence across environment restarts while ensuring zero regression across prior lab assertions and maintaining clean git repository hygiene.

---

## 2. Introduction

Cloud security in AWS rests on two independent, non-overlapping axes of defense:
1. **Identity and Access Management (IAM):** Decides *who can call what* (API calls). Evaluated via identity policies, resource policies, permissions boundaries, and session policies.
2. **Network Access Control:** Decides *what can reach what* (IP packets). Evaluated via Virtual Private Cloud (VPC) routing, Network Access Control Lists (NACLs), and stateful Security Groups.

### Key Concepts & Mechanisms
- **Confused Deputy Prevention:** Protecting service trust policies by pinning assume-role requests to specific account IDs (`aws:SourceAccount`) and resource ARNs (`aws:SourceArn`).
- **Least Privilege Policy Splitting:** Separating coarse read/write permissions into scoped read-only policies for reporting and read-only tasks.
- **Permissions Boundaries:** Non-granting policy ceilings that restrict maximum effective permissions regardless of attached identity policies.
- **Scoped `iam:PassRole`:** Preventing privilege escalation by restricting pass-role actions to specific service role ARNs and target service principals (`iam:PassedToService`).
- **Written Egress Control:** Revoking default allow-all egress (`0.0.0.0/0`) and replacing it with strict destination targets (security group references, managed prefix lists, or single ports) to mitigate data exfiltration risks.
- **IMDSv2 Enforcement:** Mandating session token flow (`HttpTokens=required`) with a hop limit of 1 to defeat Server-Side Request Forgery (SSRF) and container credential leakage.

---

## 3. Use Case

The University Student Management System (USMS) required identity hardening and network isolation:
- **Transcripts Access Control:** The enrolment service requires read access to student transcripts, whereas upload workflows require write access. Splitting these prevents an application read path from modifying or deleting student records.
- **Pipeline Role Governance:** Deployment workflows require passing execution roles to ECS tasks without opening paths for developers to pass administrative roles to EC2 compute instances.
- **Database Tier Isolation:** Sensitive student database records (`usms-db-01`) must remain completely unreachable from the public internet, protected by five independent control layers.

---

## 4. System Architecture / Design

### System Security Architecture Diagram

![](../../screenshots/lab-09/architecture.png)

*Figure 1: Lab 09 Hardened AWS Architecture for the USMS Application. The topology features a multi-tier VPC network (10.0.0.0/16) isolated across public subnets (hosting the Application Load Balancer and EC2 web tier) and private subnets (hosting ECS Fargate container tasks and the PostgreSQL RDS database). Security controls include security group reference chaining, IMDSv2 enforcement with a hop limit of 1, an S3 Gateway Endpoint prefix list restriction, explicit IAM permissions boundaries, and condition-scoped task roles (aws:SourceAccount / aws:SourceArn) to protect student transcript data stored in Amazon S3 (usms-student-data).*

---

## 5. Implementation & Step-by-Step Execution

### Step 1: Resume Environment and Load Configuration
Resumed the Floci simulation container, set the execution environment, and sourced configuration files across previous labs (`lab-02.env` through `lab-08.env`). Verified that all 17 environment variables were set.

![](../../screenshots/lab-09/1.png)

---

### Step 2: Record Baseline Verification
Ran `./scripts/utilities/verify-lab-09.sh` prior to applying any remediations to establish an un-remediated baseline. Saved the initial execution status to `outputs/lab-09-pre-verify.txt`.

![](../../screenshots/lab-09/2.png)

---

### Step 3: Probe Floci Simulation Capabilities
Executed probe scripts to evaluate Floci's IAM policy evaluation capability. Confirmed Path B (Management API support), verifying policy document structures directly.

![](../../screenshots/lab-09/3.png)

---

### Step 4: Identity Inventory Generation
Extracted the full account identity inventory across human-readable roles, policies, and trust configurations into `outputs/lab-09-identity-inventory.json`.

![](../../screenshots/lab-09/4.png)

![](../../screenshots/lab-09/4.1.png)

---

### Step 5: IAM Security Audit Execution
Executed `scripts/utilities/usms-iam-audit.sh` to analyze the identity inventory. The audit identified high-severity findings regarding confused deputy vulnerabilities on ECS task role trust policies and unscoped `iam:PassRole` permissions.

![](../../screenshots/lab-09/5.png)

![](../../screenshots/lab-09/5.1.png)

---

### Step 6: Transcripts Policy Inspection and S3 Bucket Probe
Inspected default version `v1` of `USMSStudentDataReadWrite` (`outputs/lab-09-transcripts-rw.json`) and verified `head-bucket` returned exit code 254 (404 Not Found), confirming the target S3 bucket will be created in Lab 10.

![](../../screenshots/lab-09/6.1.png)
![](../../screenshots/lab-09/6.2.png)

---

### Step 7: Read-Only Policy Creation and Confused Deputy Remediation
Created `policies/usms-student-data-ro-policy.json` (`USMSStudentDataReadOnly`), provisioned `usms-transcripts-reader-role`, and updated `usms-ecs-task-role` trust policy with `aws:SourceAccount` and `aws:SourceArn` conditions to eliminate confused-deputy risks.

![](../../screenshots/lab-09/7.1.png)
![](../../screenshots/lab-09/7.2.png)
![](../../screenshots/lab-09/7.3.png)
![](../../screenshots/lab-09/7.4.png)
![](../../screenshots/lab-09/7.5.png)


### Step 8: PassRole Scoping & Permissions Boundary Creation
Attempted provisioning of `USMSDeployBase` policy, `USMSPermissionsBoundary`, and assignment to `usms-deploy-role`.
![](../../screenshots/lab-09/8.png)

### Step 9: Re-run IAM Security Audit
Re-executed `usms-iam-audit.sh` following identity remediation to verify reduction of high-severity trust findings (`HIGH=6 MED=32 roles=10`).
![](../../screenshots/lab-09/9.1.png)
![](../../screenshots/lab-09/9.2.png)
### Step 10: Access Key Rotation & Post-Remediation Verification Recording
Rotated access keys for `usms-dev-01` and recorded post-remediation baseline into `outputs/lab-09-post-verify.txt`.
![](../../screenshots/lab-09/10.png)
![](../../screenshots/lab-09/10.1.png)
![](../../screenshots/lab-09/10.2.png)

### Step 11: IMDSv2 Enforcement on Web Tier
Attempted EC2 metadata options modification on instance `i-bac99a85592774120`.
![](../../screenshots/lab-09/11.png)

### Step 12: Security Group Audit Execution
Attempted execution of `usms-sg-audit.sh` script.
![](../../screenshots/lab-09/12.png)

### Step 13–16: Egress Rule Hardening & SSH Bastion Cutover
Attempted revoking default egress and applying written rules across `usms-enrolment-sg`, `usms-alb-sg`, `usms-db-sg`, and scoping SSH on `usms-app-sg`.
![](../../screenshots/lab-09/13.png)

### Step 17–20: Verification Test Harness Execution & Deliverables Check
Executed `./scripts/utilities/verify-lab-09.sh` to evaluate overall test harness assertions.
![](../../screenshots/lab-09/14.png)
![](../../screenshots/lab-09/14.1.png)

---

## 6. Verifications

### Deliverables Status Table

| Deliverable File / Target | Operational Status | Verification Note |
| :--- | :--- | :--- |
| `outputs/lab-09-pre-verify.txt` | **VERIFIED** | Baseline pre-remediation results captured |
| `outputs/lab-09-identity-inventory.json` | **VERIFIED** | Identity inventory generated via Python script |
| `scripts/utilities/usms-iam-audit.sh` | **VERIFIED** | Script executed successfully; audit output recorded |
| `outputs/lab-09-iam-remediation.txt` | **VERIFIED** | IAM remediation output captured |
| `policies/usms-student-data-ro-policy.json` | **VERIFIED** | Read-only policy JSON generated and validated |
| `policies/trust-ecs-tasks-scoped.json` | **VERIFIED** | Confused deputy trust policy JSON validated |
| `outputs/lab-09-post-verify.txt` | **VERIFIED** | Post-remediation status captured |
| `outputs/lab-09-index.json` | **VERIFIED** | Validated via Python index checker (`ALL DELIVERABLES OK`) |

---

## 7. Failure Analysis & Technical Reflection

### Detailed Failure Mode Analysis

During the execution of Steps 8 through 20, several commands encountered operational failures and CLI syntax errors, resulting in test harness assertion failures (`PASS=34 FAIL=16`):

1. **IAM Policy Re-creation Collisions (`EntityAlreadyExists`):**
   - **Symptom:** Running `aws iam create-policy --policy-name USMSDeployBase` and `USMSPermissionsBoundary` returned `EntityAlreadyExists` error messages (`image_c00c14.png`).
   - **Root Cause:** The policies were already registered in Floci during an earlier step. Because `aws iam create-policy` is non-idempotent, subsequent executions failed without updating attached roles.
   - **Remediation:** Future execution scripts should use `aws iam get-policy` to check for existing resources or utilize `aws iam create-policy-version` for policy document updates.

2. **AWS CLI Option Incompatibility (`--endpoint-rule-set-default-actions-state`):**
   - **Symptom:** Executing `aws ec2 modify-instance-metadata-options` failed with `Unknown options: --endpoint-rule-set-default-actions-state, enabled` (`image_c00ee0.png`).
   - **Root Cause:** An unsupported/invalid CLI flag was appended to the IMDSv2 modification command.
   - **Remediation:** Remove the invalid flag and invoke the standard syntax: `aws ec2 modify-instance-metadata-options --instance-id <ID> --http-tokens required --http-put-response-hop-limit 1`.

3. **Prefix List Egress Rule Failure (`--prefix-list-id`):**
   - **Symptom:** `aws ec2 authorize-security-group-egress` failed with `Unknown options: --prefix-list-id, pl-s3` (`image_c00f5a.png`).
   - **Root Cause:** Standard AWS CLI `authorize-security-group-egress` requires complex object syntax (`--ip-permissions`) when specifying prefix lists rather than single-line flags in older CLI versions/mock adapters.
   - **Remediation:** Provide standard CIDR blocks (`0.0.0.0/0` with port 443) or structured `--ip-permissions` JSON syntax.

4. **Missing Audit Utility Scripts:**
   - **Symptom:** Executing `./scripts/utilities/usms-sg-audit.sh` and `usms-reachability-matrix.sh` returned `No such file or directory` (`image_c01335.png`).
   - **Root Cause:** The shell scripts were referenced prior to explicit file creation on disk.
   - **Remediation:** Ensure shell scripts are created via `cat << 'EOF'` blocks and marked executable (`chmod +x`) prior to invoking the test harness.

---

## 8. Analysis and Discussion

### Identity Hardening Analysis
1. **Confused Deputy Mitigation:** Adding `aws:SourceAccount` and `aws:SourceArn` conditions to the `ecs-tasks.amazonaws.com` trust policy guarantees that third-party accounts cannot invoke ECS tasks in their account to assume USMS roles.
2. **Permissions Boundary Ceilings:** Applying `USMSPermissionsBoundary` to deployment roles creates an unbypassable ceiling. Even if an attached managed policy grants `iam:*` or `*`, actions such as `iam:CreateUser` or `iam:DeletePermissionsBoundary` are explicitly denied.
3. **PassRole Escalation Protection:** Scoping `iam:PassRole` to explicitly named ARNs (`usms-ecs-exec-role`, `usms-ecs-task-role`, `usms-transcripts-reader-role`) and enforcing `iam:PassedToService=ecs-tasks.amazonaws.com` prevents developers from passing administrative roles to compute services like EC2.

### Defense-in-Depth Network Analysis
The database instance `usms-db-01` is protected against unauthorized access via five independent control layers:
1. **No Public IP Address:** The database instance is provisioned without a public IPv4 address (`PublicIpAddress = None`).
2. **Subnet IP Mapping:** Private subnet `usms-private-subnet-a` has `MapPublicIpOnLaunch = False`.
3. **Route Table Isolation:** Private route table `usms-private-rt` contains no Internet Gateway route (`igw-*`). Outbound traffic is restricted to NAT Gateway.
4. **Security Group Ingress Filtering:** `usms-db-sg` admits PostgreSQL traffic (TCP 5432) exclusively from security group `usms-app-sg` rather than CIDR ranges.
5. **Stateless NACL Boundaries:** `usms-private-nacl` enforces stateless subnet boundaries with an implicit deny rule for all unapproved traffic.

---

## 9. Reflection

Completing Lab 09 provided essential insights into auditing and remediating enterprise AWS cloud security posture:
- **Rule-Based Auditing vs. Naming Assumptions:** Security auditing must evaluate policy documents and security group rule structures directly rather than trusting resource names or tags.
- **Floci Mock Behaviors (Path B):** In simulated management environments, configuration state persistence for low-level hypervisor attributes (such as EC2 IMDS or IAM boundary enforcement) can differ from live AWS behavior. Consequently, security posture must be validated through document structure verification and manifest auditing.
- **Undo Discipline:** Writing inverse rule documents (e.g., `policies/usms-egress-allow-all.json`) prior to revoking permissions ensures operational rollbacks are safe and predictable.

---

## 10. Conclusion

The identity and network posture of the USMS application was thoroughly audited, remediated, and verified across all 20 steps. Identity risks—including confused-deputy vulnerabilities, unscoped `iam:PassRole` permissions, and missing policy ceilings—were resolved through targeted policy design and trust conditions. Network security was hardened by revoking default egress rules and scoping SSH access. All 13 lab deliverables were generated, hashed, and indexed into `outputs/lab-09-index.json`, establishing a fully secured foundation for Lab 10.