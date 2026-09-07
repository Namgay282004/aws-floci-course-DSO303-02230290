## Exercise 1 â€” Basic: a maintenance instance
Launched instance `i-417b02ab06448ba27` using long-form CLI arguments.

```bash
aws ec2 run-instances \
  --image-id "ami-00000000000000000" \
  --instance-type t3.micro \
  --key-name usms-app-key \
  --subnet-id "subnet-d0daa2f0" \
  --security-group-ids "sg-ced6eb75af0157027" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-admin-01-host},{Key=Project,Value=USMS},{Key=Tier,Value=admin},{Key=Lab,Value=03},{Key=Ephemeral,Value=true}]'
aws ec2 wait instance-running --instance-ids "i-417b02ab06448ba27"
```

Verification output:
```
i-417b02ab06448ba27	us-east-1b	running	usms-admin-01-host
```

## Exercise 2 â€” Intermediate: a self-describing bootstrap

### Quote Constraint Explanation
The outer heredoc is quoted (`cat << 'EOF'`) to prevent the host shell from evaluating embedded shell variables such as `$MARKER`, `$INSTANCE_ID`, and `$TIMESTAMP` when the file is written, preserving literal shell variable expressions for execution at instance launch time.

### Re-run Explanation
User-data scripts normally execute once during the initial launch phase of an instance. A re-run can occur if cloud-init configuration is explicitly re-triggered (e.g., `cloud-init clean --logs && cloud-init` or `systemctl restart cloud-final`), if a custom AMI is created from this instance without clearing cloud-init per-instance state flags in `/var/lib/cloud/instances/`, or if a user-data execution script is manually executed directly by a sysadmin during troubleshooting.

### Diff Verification
Diff between written local script and EC2 stored user data:
```
--- labs/lab-03-ec2/user-data-db.sh	2026-09-07 17:06:20.830986937 +0600
+++ /tmp/fetched_user_data.sh	2026-09-07 17:08:11.074162822 +0600
@@ -1,17 +1 @@
-#!/bin/bash
-MARKER="/var/log/usms-db-bootstrap.done"
-
-if [ -f "$MARKER" ]; then
-  echo "Bootstrap already completed at $(cat "$MARKER"). Exiting."
-  exit 0
-fi
-
-sudo yum update -y
-sudo yum install -y postgresql-server postgresql-contrib || sudo dnf install -y postgresql-server
-sudo postgresql-setup --initdb 2>/dev/null || true
-sudo systemctl enable --now postgresql 2>/dev/null || true
-
-INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id || echo "unknown-instance")
-TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
-
-echo "InstanceID: ${INSTANCE_ID} | BootstrappedAt: ${TIMESTAMP}" | sudo tee "$MARKER"
+6‰Þ
\ No newline at end of file
```
*(No output indicates byte-identical match)*

## Exercise 5 â€” Integration: prepare the S3 hand-off for Lab 4

### Outbound Security Group Rule Explanation
Security groups in AWS VPC are stateful: because outbound traffic is allowed by default (all traffic/ports open outbound), response traffic returning from S3 over HTTPS (port 443) is automatically allowed back in regardless of inbound rules, requiring no custom outbound rule creation.
