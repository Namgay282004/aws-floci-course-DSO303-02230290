# Lab 05 Independent Exercises Solutions

## Exercise 1 - Basic: A Second Path Through the Same Load Balancer

### Objective

Configure a second target group (`usms-results-tg`) and a Priority 20 listener rule to route `/results` and `/results/*` traffic through the existing Application Load Balancer.

### Commands Executed

```bash
# 1. Create usms-results-tg target group
RESULTS_TG_ARN=$(aws elbv2 create-target-group \
  --name usms-results-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$USMS_VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path / \
  --matcher HttpCode=200-399 \
  --tags Key=Name,Value=usms-results-tg Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

echo "RESULTS_TG_ARN = $RESULTS_TG_ARN"

# 2. Set deregistration delay attribute to 15 seconds
aws elbv2 modify-target-group-attributes \
  --target-group-arn "$RESULTS_TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=15

# 3. Create Priority 20 rule condition and action JSON templates
cat > templates/lab-05-results-conditions.json << 'EOF'
[
  {
    "Field": "path-pattern",
    "PathPatternConfig": {
      "Values": ["/results", "/results/*"]
    }
  }
]
EOF

cat > templates/lab-05-results-actions.json << EOF
[
  {
    "Type": "forward",
    "TargetGroupArn": "$RESULTS_TG_ARN"
  }
]
EOF

# 4. Create Priority 20 listener rule
aws elbv2 create-rule \
  --listener-arn "$USMS_ALB_LISTENER_ARN" \
  --priority 20 \
  --conditions file://templates/lab-05-results-conditions.json \
  --actions file://templates/lab-05-results-actions.json \
  --tags Key=Name,Value=usms-results-rule Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results

# 5. Verify rules in priority order
aws elbv2 describe-rules --listener-arn "$USMS_ALB_LISTENER_ARN" \
  --query 'sort_by(Rules, &Priority)[].{Priority:Priority, Default:IsDefault, Conditions:Conditions[0].Values, Action:Actions[0].Type, TargetGroup:Actions[0].TargetGroupArn}' \
  --output table

```

### Explanation of Empty Target Group Response

If an incoming request is sent to `/results` while `usms-results-tg` is attached to a listener but contains zero registered targets, the Application Load Balancer returns an **HTTP 503 Service Unavailable** error status code.

---

## Exercise 2 - Intermediate: Repair the Verification Script You Broke

### Objective

Update `scripts/utilities/verify-lab-04.sh` to reflect the security cutover architecture (asserting `usms-enrolment-sg` accepts traffic from `usms-alb-sg` and rejects direct access from `usms-app-sg`).

### 1. Architectural Property Asserted

The failing check in `verify-lab-04.sh` was asserting that **the enrolment container security group restricts inbound TCP/80 access strictly to a authorized security group tier rather than an open CIDR block**.

### 2. Code Changes Made to `scripts/utilities/verify-lab-04.sh`

```bash
# Sourced lab-05.env with default fallback
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true
: "${USMS_ALB_SG:=none}"

# Updated assertions:
check "usms-enrolment-sg is sourced from usms-alb-sg (not a CIDR)" \
  "sgsrc $USMS_ENROLMENT_SG | grep -qw $USMS_ALB_SG"

check "usms-enrolment-sg no longer admits usms-app-sg" \
  "! sgsrc $USMS_ENROLMENT_SG | grep -qw $USMS_APP_SG"

```

### 3. Verification Script Output

Running both scripts produces:

```text
./scripts/utilities/verify-lab-04.sh -> PASS=38 FAIL=0
./scripts/utilities/verify-lab-05.sh -> PASS=49 FAIL=0

```

### Note on Updating Verification Scripts

It is appropriate to update a verification script when a planned architectural evolution (such as inserting an ALB edge tier in front of an app tier) intentionally changes boundary ingress rules. Updating a verification script is inappropriate when done merely to force a failing test to turn green without an approved architectural change, as doing so masks security regressions.

---

## Exercise 3 - Problem Solving: A Load Balancer Report Tool

### Objective

Create `scripts/utilities/usms-lb-report.sh` to inspect all load balancers starting with `usms-` and print their complete decision table.

### Script Code (`scripts/utilities/usms-lb-report.sh`)

```bash
#!/usr/bin/env bash
# Generates a complete decision routing report for USMS load balancers.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

LBS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[?starts_with(LoadBalancerName, `usms-`)].LoadBalancerArn' --output text)

for lb_arn in $LBS; do
  LB_NAME=$(aws elbv2 describe-load-balancers --load-balancer-arns "$lb_arn" --query 'LoadBalancers[0].LoadBalancerName' --output text)
  SCHEME=$(aws elbv2 describe-load-balancers --load-balancer-arns "$lb_arn" --query 'LoadBalancers[0].Scheme' --output text)
  TYPE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$lb_arn" --query 'LoadBalancers[0].Type' --output text)
  STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$lb_arn" --query 'LoadBalancers[0].State.Code' --output text)
  AZ_COUNT=$(aws elbv2 describe-load-balancers --load-balancer-arns "$lb_arn" --query 'length(LoadBalancers[0].AvailabilityZones)' --output text)
  SG_COUNT=$(aws elbv2 describe-load-balancers --load-balancer-arns "$lb_arn" --query 'length(LoadBalancers[0].SecurityGroups)' --output text)

  echo "$LB_NAME$SCHEME $TYPE$STATE AZs=$AZ_COUNT SGs=$SG_COUNT"

  LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" --query 'Listeners[].ListenerArn' --output text)
  for l_arn in $LISTENERS; do
    PORT=$(aws elbv2 describe-listeners --listener-arns "$l_arn" --query 'Listeners[0].Port' --output text)
    PROTO=$(aws elbv2 describe-listeners --listener-arns "$l_arn" --query 'Listeners[0].Protocol' --output text)
    echo "  $PROTO:$PORT"

    RULES=$(aws elbv2 describe-rules --listener-arn "$l_arn" --query 'sort_by(Rules[?IsDefault==`false`], &Priority)[].RuleArn' --output text)
    for r_arn in $RULES; do
      PRIO=$(aws elbv2 describe-rules --rule-arns "$r_arn" --query 'Rules[0].Priority' --output text)
      COND=$(aws elbv2 describe-rules --rule-arns "$r_arn" --query 'Rules[0].Conditions[0].Values' --output text | tr '\t' ',')
      ACTION=$(aws elbv2 describe-rules --rule-arns "$r_arn" --query 'Rules[0].Actions[0].Type' --output text)

      if [ "$ACTION" = "forward" ]; then
        TG_ARN=$(aws elbv2 describe-rules --rule-arns "$r_arn" --query 'Rules[0].Actions[0].TargetGroupArn' --output text)
        TG_NAME=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" --query 'TargetGroups[0].TargetGroupName' --output text)
        TOTAL_TGS=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'length(TargetHealthDescriptions)' --output text)
        HEALTHY_TGS=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
        echo "    prio $PRIO path-pattern $COND ->$TG_NAME ($TOTAL_TGS targets,$HEALTHY_TGS healthy)"
      else
        STATUS=$(aws elbv2 describe-rules --rule-arns "$r_arn" --query 'Rules[0].Actions[0].FixedResponseConfig.StatusCode' --output text)
        echo "    prio $PRIO path-pattern$COND -> $ACTION$STATUS"
      fi
    done

    # Default action printed last
    DEF_TG_ARN=$(aws elbv2 describe-listeners --listener-arns "$l_arn" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)
    DEF_TG_NAME=$(aws elbv2 describe-target-groups --target-group-arns "$DEF_TG_ARN" --query 'TargetGroups[0].TargetGroupName' --output text)
    DEF_TOTAL=$(aws elbv2 describe-target-health --target-group-arn "$DEF_TG_ARN" --query 'length(TargetHealthDescriptions)' --output text)
    DEF_HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$DEF_TG_ARN" --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
    echo "    prio default - -> $DEF_TG_NAME ($DEF_TOTAL targets,$DEF_HEALTHY healthy)"
  done
done

```

---

## Exercise 4 - Challenge: The Exposure Review

### Written Analysis Response to Information Security Officer

#### 1. What Changed (Two Sentences)

We introduced an internet-facing Application Load Balancer across two public subnets to act as a single, stable entry point for all incoming HTTP requests. Simultaneously, we revoked direct web-tier access to `usms-enrolment-sg`, ensuring all backend container traffic is routed strictly through `usms-alb-sg`.

#### 2. Internal vs. Internet-Facing Recommendation

Setting `--scheme internal` provisions ALB private IP interfaces inside private subnets, resolving DNS queries exclusively within the VPC. If `usms-web-01` (the portal) is the sole caller of the enrolment API, an internal scheme is strongly recommended to reduce public exposure. Conversely, keeping an internet-facing ALB allows future direct student client connectivity or external API integration without needing reverse proxy re-architecture.

#### 3. Exposure Delta Table

| Layer | Before Lab 05 | After Lab 05 |
| --- | --- | --- |
| **Who can reach the load balancer?** | N/A (Load balancer did not exist)

 | Internet clients (`0.0.0.0/0`) on port 80

 |
| **Who can reach the tasks?** | Web tier (`usms-web-01` carrying `usms-app-sg`)

 | Load balancer security group (`usms-alb-sg`) ONLY

 |
| **Can tasks be reached directly?** | Yes, directly by task private IP from `usms-app-sg`<br> | **NO.** Direct access from `usms-app-sg` is fully revoked

 |

#### 4. Monthly Cost Estimate

* **Application Load Balancer Base Rate:** $\$0.0225\text{ / hour} \times 730\text{ hours} = \mathbf{\$16.425\text{ / month}}$ (AWS Published Rates).


* **LCU Charge (Idle):** Minimum 1 LCU-hour charge = $\$0.008\text{ / hour} \times 730\text{ hours} = \mathbf{\$5.84\text{ / month}}$.


* **Fargate Tasks Baseline:** Two $0.25\text{ vCPU} / 1\text{ GB RAM}$ tasks = $\approx \mathbf{\$18.24\text{ / month}}$.


* **Total Idle Infrastructure Cost:** $\approx \mathbf{\$40.505\text{ / month}}$.

#### 5. HTTPS Implementation Plan

1. **Request Public Certificate:** Request an SSL/TLS certificate in **AWS Certificate Manager (ACM)** for the USMS domain name (*Free of charge from AWS*).


2. **Domain Ownership Validation:** Create a CNAME DNS validation record in your external **Domain Name Registrar**.


3. **HTTPS Listener:** Create an HTTPS listener on port 443 on `usms-enrolment-alb`, attaching the issued ACM certificate ARN.


4. **HTTP to HTTPS Redirect Rule:** Create a Priority 1 listener rule on HTTP port 80 with action `redirect` (`StatusCode=HTTP_301`, `Port=443`, `Protocol=HTTPS`) to automatically upgrade plaintext HTTP requests.



#### 6. Tidy-up Commands Executed

```bash
# Delete priority-20 rule
RULE_20_ARN=$(aws elbv2 describe-rules --listener-arn "$USMS_ALB_LISTENER_ARN" \
  --query 'Rules[?Priority==`20`].RuleArn' --output text)
aws elbv2 delete-rule --rule-arn "$RULE_20_ARN"

# Delete practice target group
aws elbv2 delete-target-group --target-group-arn "$RESULTS_TG_ARN"

```

---

## Exercise 5 - Integration: The ResourceLabel Hand-Off to Lab 06

### Objective

Build the composite `ResourceLabel` string (`app/<alb-name>/<alb-id>/targetgroup/<tg-name>/<tg-id>`) required for Application Auto Scaling metric tracking in Lab 06.

### 1. Script Code (`scripts/utilities/usms-resource-label.sh`)

```bash
#!/usr/bin/env bash
# Derives the ALB ResourceLabel for Application Auto Scaling
set -uo pipefail

LB_NAME="${1:-usms-enrolment-alb}"
TG_NAME="${2:-usms-enrolment-tg}"

LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text)

# Extract suffixes using shell parameter expansion
LB_SUFFIX="${LB_ARN#*:loadbalancer/}"
TG_SUFFIX="${TG_ARN#*:targetgroup/}"

RESOURCE_LABEL="${LB_SUFFIX}/targetgroup/${TG_SUFFIX}"
echo "$RESOURCE_LABEL"

```

### 2. Output and Environmental Append Result

Appending to `configs/lab-05.env`:

```bash
export USMS_ALB_RESOURCE_LABEL=$(./scripts/utilities/usms-resource-label.sh)

```

`configs/lab-05.env` now contains **16 exported variables**.

### 3. Readiness File Created (`outputs/lab-05-lab04c-readiness.txt`)

```text
ResourceLabel: app/usms-enrolment-alb/416c507e37804d2c/targetgroup/usms-enrolment-tg/49098b1d39f34584
TargetGroupARN: arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/usms-enrolment-tg/49098b1d39f34584
LoadBalancerARN: arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/usms-enrolment-alb/416c507e37804d2c
ScalableResourceID: service/usms-ecs-cluster/usms-enrolment-svc
ScalableDimension: ecs:service:DesiredCount
CurrentDesiredCount: 2
Recommended Metric: ALBRequestCountPerTarget is recommended over CPU because request volume directly reflects API demand regardless of container CPU usage efficiency.
Capacity Replacement Duration: 42 seconds

```

### 4. ResourceLabel Structure Assertion

The generated `RESOURCE_LABEL` contains exactly 6 slash-separated segments starting with `app` (`app / usms-enrolment-alb / <id> / targetgroup / usms-enrolment-tg / <id>`). The prefix `app` explicitly denotes an **Application Load Balancer** resource (as opposed to `net` for Network Load Balancers) within AWS CloudWatch metric namespaces.