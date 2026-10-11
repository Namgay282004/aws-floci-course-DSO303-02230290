### Exercise 1: Configure ALB Request Count Target Tracking

**Goal:** Implement a second target tracking scaling policy based on incoming HTTP request volume to maintain high application responsiveness.

1. **Task Description:**
* Configure a target tracking policy named `usms-enrolment-requests-target-tracking` that monitors the `ALBRequestCountPerTarget` metric.
* Set the target value to `1000` requests per target instance over a 1-minute period.
* Apply asymmetric cooldowns: `60` seconds for scale-out and `300` seconds for scale-in.


2. **Implementation Command:**
```bash
# Retrieve ALB resource label
ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg --query 'TargetGroups[0].TargetGroupArn' --output text)

ALB_SUFFIX="${ALB_ARN#*app/}"
TG_SUFFIX="${TG_ARN#*targetgroup/}"
RESOURCE_LABEL="app/${ALB_SUFFIX}/targetgroup/${TG_SUFFIX}"

cat > templates/lab-06-target-tracking-requests.json << EOF
{
  "TargetValue": 1000.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ALBRequestCountPerTarget",
    "ResourceLabel": "${RESOURCE_LABEL}"
  },
  "ScaleOutCooldown": 60,
  "ScaleInCooldown": 300
}
EOF

aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --policy-name "usms-enrolment-requests-target-tracking" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file://templates/lab-06-target-tracking-requests.json

```


3. **Verification:**
* Describe scaling policies to confirm both CPU and Request-Count target tracking policies are active on the scalable target:
```bash
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --resource-id "$RID" \
  --query 'ScalingPolicies[].[PolicyName, PolicyType]' --output table

```



---

### Exercise 2: Configure a Step Scale-In Policy and Low Queue Depth Alarm

**Goal:** Complement your Step Scale-Out policy with an automated Step Scale-In mechanism to safely release excess task capacity when workload queues empty.

1. **Task Description:**
* Create a step scale-in policy named `usms-enrolment-queue-step-in` with a negative adjustment of `-1` task.
* Create a CloudWatch alarm named `usms-enrolment-queue-low` that triggers when `EnrolmentQueueDepth` drops below `10` messages for 2 evaluation periods.
* Link the scale-in policy ARN to the low-queue alarm actions.


2. **Implementation Command:**
```bash
cat > templates/lab-06-step-scaling-in.json << 'EOF'
{
  "AdjustmentType": "ChangeInCapacity",
  "StepAdjustments": [
    {
      "MetricIntervalUpperBound": 0.0,
      "ScalingAdjustment": -1
    }
  ],
  "Cooldown": 180,
  "MetricAggregationType": "Average"
}
EOF

STEP_IN_ARN=$(aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --policy-name "usms-enrolment-queue-step-in" \
  --policy-type StepScaling \
  --step-scaling-policy-configuration file://templates/lab-06-step-scaling-in.json \
  --query 'PolicyARN' --output text)

aws cloudwatch put-metric-alarm \
  --alarm-name "usms-enrolment-queue-low" \
  --alarm-description "USMS enrolment queue depth is low" \
  --namespace "USMS/Enrolment" \
  --metric-name "EnrolmentQueueDepth" \
  --dimensions Name=Service,Value=enrolment \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 10 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$STEP_IN_ARN"

```


3. **Verification:**
* Publish a low metric value (`2` messages) and force the alarm state to verify the policy link:
```bash
aws cloudwatch set-alarm-state --alarm-name "usms-enrolment-queue-low" --state-value ALARM --state-reason "Exercise 2 testing scale-in trigger"
aws cloudwatch describe-alarms --alarm-names "usms-enrolment-queue-low" --query 'MetricAlarms[0].[AlarmName, StateValue, AlarmActions[0]]' --output text

```





---

### Exercise 3: Perform Target Suspension for Scheduled Maintenance

**Goal:** Practice operational runbook controls by completely suspending dynamic auto scaling during a simulated maintenance window without deleting established policies.

1. **Task Description:**
* Create a full suspension document (`templates/lab-06-full-suspension.json`) with all suspension flags set to `true`.
* Apply the suspension to the ECS scalable target.
* Verify that existing scaling policies remain registered while target adjustments are suspended.
* Clear the suspension flags to resume normal automated operations.


2. **Implementation Command:**
```bash
# 1. Create full suspension document
cat > templates/lab-06-full-suspension.json << 'EOF'
{
  "DynamicScalingInSuspended": true,
  "DynamicScalingOutSuspended": true,
  "ScheduledScalingSuspended": true
}
EOF

# 2. Apply suspension
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --suspended-state file://templates/lab-06-full-suspension.json

# 3. Resume all scaling switches
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "$RID" \
  --scalable-dimension "$SDIM" \
  --suspended-state DynamicScalingInSuspended=false,DynamicScalingOutSuspended=false,ScheduledScalingSuspended=false

```


3. **Verification:**
* Confirm that all suspension flags return to `false`:
```bash
aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].SuspendedState' --output json

```





---

### Exercise 4: Construct an Auto Scaling Health Check & Monitoring Script

**Goal:** Write a reusable Bash monitoring script that extracts live metrics, alarm states, policy ARNs, and current task deployment counts into a formatted operational snapshot.

1. **Task Description:**
* Create a shell script named `scripts/utilities/autoscaling-status.sh`.
* The script must query the ECS service running task count, scalable target capacity bounds, active CloudWatch alarms, and configured scaling policies.
* Save the operational summary output to `outputs/lab-06-operational-status.txt`.


2. **Implementation Command:**
```bash
mkdir -p scripts/utilities

cat > scripts/utilities/autoscaling-status.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

source configs/course.env
source configs/lab-04.env
source configs/lab-06.env 2>/dev/null || true

SVC_ARN=$(aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"

{
  echo "=================================================="
  echo "   USMS ENROLMENT SERVICE AUTO SCALING STATUS"
  echo "=================================================="
  echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo ""
  echo "== 1. ECS Task Capacity =="
  aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
    --query 'services[0].{DesiredCount:desiredCount, RunningCount:runningCount, PendingCount:pendingCount}' --output table

  echo "== 2. Scalable Target Bounds =="
  aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
    --query 'ScalableTargets[0].{MinCapacity:MinCapacity, MaxCapacity:MaxCapacity, Suspended:SuspendedState}' --output json

  echo "== 3. Active Scaling Policies =="
  aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
    --query 'ScalingPolicies[].[PolicyName, PolicyType]' --output table

  echo "== 4. CloudWatch Alarm States =="
  aws cloudwatch describe-alarms --alarm-name-prefix "usms-enrolment" \
    --query 'MetricAlarms[].[AlarmName, StateValue, Threshold]' --output table
} | tee outputs/lab-06-operational-status.txt
EOF

chmod +x scripts/utilities/autoscaling-status.sh
./scripts/utilities/autoscaling-status.sh

```


3. **Verification:**
* Verify that `outputs/lab-06-operational-status.txt` is generated cleanly and contains active status metrics across all 4 sections.