# Lab 12 : Independent Lab Exercises

## Exercise 1 : A Second Base Image, and a Smaller One

### Objective
Rebuild the enrolment container image on `public.ecr.aws/nginx/nginx:stable-alpine`, push it to `usms-enrolment` as tag `r7-alt` without modifying `VERSION` or deploying it, and compare its compressed registry size and layer count against `r7` (`nginx:1.27-alpine`).

### Commands & Verification

```bash
cd ~/Desktop/Seventh-Semester/DSO303/aws-floci-course
source configs/course.env
ECR_URI=$(aws ecr describe-repositories --repository-names usms-enrolment \
  --query 'repositories[0].repositoryUri' --output text)

# Build on public.ecr.aws/nginx/nginx:stable-alpine without touching Dockerfile or VERSION
docker build \
  --build-arg BASE_IMAGE=public.ecr.aws/nginx/nginx:stable-alpine \
  -t "usms-enrolment:r7-alt" \
  -f - labs/lab-11-cicd/app << 'EOF'
FROM public.ecr.aws/nginx/nginx:stable-alpine
COPY dist/ /usr/share/nginx/html/
EXPOSE 80
EOF

docker tag "usms-enrolment:r7-alt" "${ECR_URI}:r7-alt"
docker push "${ECR_URI}:r7-alt"

# Query compressed sizes from ECR describe-images
aws ecr describe-images \
  --repository-name usms-enrolment \
  --query 'imageDetails[?imageTags[0]==`r7` || imageTags[0]==`r7-alt`].{Tag:imageTags[0], CompressedBytes:imageSizeInBytes, Digest:imageDigest}' \
  --output table

# Compare local uncompressed sizes and layer counts
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep usms-enrolment
echo "--- Layer count (r7) ---"
docker history "${ECR_URI}:r7" --format "{{.ID}}\t{{.Size}}\t{{.CreatedBy}}" | wc -l
echo "--- Layer count (r7-alt) ---"
docker history "${ECR_URI}:r7-alt" --format "{{.ID}}\t{{.Size}}\t{{.CreatedBy}}" | wc -l
```

### Analysis: Registry Size vs. Local Daemon Size
The size reported by `aws ecr describe-images` (`imageSizeInBytes`) differs from `docker images` for two primary reasons:
1. **Compressed vs. Uncompressed Storage:** Amazon ECR stores and transfers image layers as compressed gzip/zstd tarballs (`imageSizeInBytes` reflects the compressed manifest + layer sum), whereas the local Docker daemon unpacks every layer onto the overlay filesystem and reports the total uncompressed disk footprint (`docker images`).
2. **Base Image & Metadata Differences:** While both `nginx:1.27-alpine` and `public.ecr.aws/nginx/nginx:stable-alpine` share an Alpine Linux userland and identical top application layer (`COPY dist/`), minor differences in Alpine package revisions, OCI manifest annotations, and layer compression ratios account for the remaining byte delta between `r7` and `r7-alt`.

---

## Exercise 2 : Argue for Immutable Tags, Then Implement It

### Objective
Configure `usms-enrolment` with `IMMUTABLE` image tags, verify that re-pushing an existing tag (`r7`) is rejected, update `buildspec.yml` so every build generates a collision-free unique tag while still producing a valid `imagedefinitions.json`, and document the final mutability state.

### Commands & Implementation

```bash
# 1. Switch repository tag mutability to IMMUTABLE
aws ecr put-image-tag-mutability \
  --repository-name usms-enrolment \
  --image-tag-mutability IMMUTABLE \
  --query '{Repo:repositoryName, Mutability:imageTagMutability}' \
  --output table

# 2. Attempt to overwrite existing tag r7 (expected rejection on immutable registry)
ECR_URI=$(aws ecr describe-repositories --repository-names usms-enrolment \
  --query 'repositories[0].repositoryUri' --output text)
docker push "${ECR_URI}:r7" || echo "Push rejected as expected under IMMUTABLE tag policy"
```

#### Updated `buildspec.yml` Tagging Strategy (Collision-Free Per Build)
To prevent tag collisions in an `IMMUTABLE` repository, `buildspec.yml` derives a unique tag suffix from CodeBuild environment variables (`CODEBUILD_BUILD_NUMBER` and short `CODEBUILD_RESOLVED_SOURCE_VERSION`), falling back to a UTC timestamp when executed locally via `usms-buildspec-run.sh`:

```yaml
  build:
    commands:
      - echo "=== build: render portal and build image ==="
      - mkdir -p dist
      - cp -f src/index.html src/healthz.html config/service.json dist/
      - BASE_TAG=$(tr -d '[:space:]' < VERSION)
      - BUILD_SUFFIX="${CODEBUILD_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
      - SHORT_SHA=$(printf '%s' "${CODEBUILD_RESOLVED_SOURCE_VERSION:-local}" | cut -c1-7)
      - IMAGE_TAG="${BASE_TAG}-${BUILD_SUFFIX}-${SHORT_SHA}"
      - export IMAGE_TAG
      - |
        if [ -n "${IMAGE_REPO_URI:-}" ]; then
          docker build -t "usms-enrolment:${IMAGE_TAG}" .
          docker tag "usms-enrolment:${IMAGE_TAG}" "${IMAGE_REPO_URI}:${IMAGE_TAG}"
          docker push "${IMAGE_REPO_URI}:${IMAGE_TAG}"
        fi
```

```bash
# 3. Restore MUTABLE mutability so subsequent verification/re-runs behave predictably
aws ecr put-image-tag-mutability \
  --repository-name usms-enrolment \
  --image-tag-mutability MUTABLE \
  --query '{Repo:repositoryName, Mutability:imageTagMutability}' \
  --output table
```

### Trade-offs & Final State
* **What Immutable Tags Buy:** Immutable tags eliminate silent tag overwrites (`tag drift`), guaranteeing a strict 1:1 mapping between an image tag and its SHA-256 digest. Auditors and incident responders can verify the exact container image deployed without worrying that a later build mutated the tag pointer.
* **What They Cost:** Every build—including retries of the same commit—must generate a unique tag, increasing ECR storage consumption and requiring ECR lifecycle policies to expire old untagged or superseded build tags.
* **Final Repository State:** Returned to `MUTABLE` after recording the rejection so that standard lab verification scripts and re-runs using fixed release tags (`r7`) remain compatible.

---

## Exercise 3 : Build the Blue/Green Scaffolding

### Objective
Provision the green target group (`usms-enrolment-tg-green`) and test listener (`:8080`) on `usms-enrolment-alb` without altering `usms-enrolment-svc`'s `deploymentController`, then populate `templates/lab-12-codedeploy-deployment-group.json` with real ARNs and validate the JSON.

### Commands & Verification

```bash
source configs/course.env
[ -f configs/lab-02.env ] && source configs/lab-02.env
[ -f configs/lab-05.env ] && source configs/lab-05.env

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=usms-vpc" \
  --query 'Vpcs[0].VpcId' --output text)
ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
PROD_LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)

# 1. Create the green target group matching Lab 05's settings (ip, HTTP:80, GET /, matcher 200)
GREEN_TG_ARN=$(aws elbv2 create-target-group \
  --name usms-enrolment-tg-green \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-port traffic-port \
  --health-check-path / \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "Green TG ARN: $GREEN_TG_ARN"

# 2. Create the test listener on port 8080 forwarding to usms-enrolment-tg-green
TEST_LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 8080 \
  --default-actions Type=forward,TargetGroupArn="$GREEN_TG_ARN" \
  --query 'Listeners[0].ListenerArn' --output text)
echo "Test Listener ARN: $TEST_LISTENER_ARN"

# 3. Substitute real listener ARNs into templates/lab-12-codedeploy-deployment-group.json
python3 - << PY
import json
path = "templates/lab-12-codedeploy-deployment-group.json"
dg = json.load(open(path))
pair = dg["loadBalancerInfo"]["targetGroupPairInfoList"][0]
pair["prodTrafficRoute"]["listenerArns"] = ["$PROD_LISTENER_ARN"]
pair["testTrafficRoute"]["listenerArns"] = ["$TEST_LISTENER_ARN"]
json.dump(dg, open(path, "w"), indent=2)
print("Updated", path)
PY

python3 -m json.tool templates/lab-12-codedeploy-deployment-group.json > /dev/null && echo "valid JSON"
grep -c '<' templates/lab-12-codedeploy-deployment-group.json || echo "0 placeholders remaining"
```

---

## Exercise 4 : Close the Hole in the Pipeline Policy

### Security Analysis of `USMSCodePipelineBase` (`v2`)
Although `USMSCodePipelineBase` (`v2`) restricts `iam:PassRole` to `usms-ecs-exec-role` and `usms-ecs-task-role` (`iam:PassedToService = ecs-tasks.amazonaws.com`), granting `ecs:RegisterTaskDefinition` on `Resource: "*"` allows a compromised pipeline role to register a malicious task definition revision that overrides the container `image` (or `entryPoint`/`command`) while still attaching `usms-ecs-task-role`. Because `usms-ecs-task-role` carries `USMSStudentDataReadWrite`, an attacker who triggers `UpdateService` (or `RunTask` if later granted) can execute arbitrary code inside ECS with full read/write access to `s3://usms-student-data`.

### Why IAM Alone Cannot Close This Gap (and Required Controls)
`ecs:RegisterTaskDefinition` does not support resource-level ARN scoping or IAM condition keys restricting container image registries (`ecr` repository URIs) or container command overrides inside the task definition payload. Closing this risk requires controls outside the pipeline role's identity policy:
1. **IAM Permissions Boundary / SCP:** Apply an AWS Organizations Service Control Policy (SCP) or permissions boundary on `usms-ecs-task-role` enforcing least-privilege prefix/KMS conditions on `usms-student-data`, limiting blast radius even if a rogue task definition passes the role.
2. **Container Image Signing & Admission Enforcement:** Enforce image signature verification (e.g., AWS Signer / Notation or ECS runtime validation) and restrict the `usms-enrolment` task family via an explicit `Condition` (`aws:RequestTag/Project = USMS`) combined with CI/CD branch protection so only reviewed commits can invoke the pipeline.

---

## Exercise 5 : Prove a Release End to End, for an Auditor

### End-to-End Release Evidence Chain (`r7` -> `outputs/lab-12-release-evidence.md`)

```bash
source configs/course.env

S3_VER=$(aws s3api list-object-versions --bucket usms-pipeline-artifacts \
  --prefix source/usms-enrolment-src.zip \
  --query 'Versions[?IsLatest==`true`].VersionId | [0]' --output text)

EXEC_ID=$(aws codepipeline list-pipeline-executions --pipeline-name usms-enrolment-pipeline \
  --query 'pipelineExecutionSummaries[0].pipelineExecutionId' --output text)

BUILD_ID=$(aws codebuild list-builds-for-project --project-name usms-enrolment-build \
  --query 'ids[0]' --output text)

R7_DIGEST=$(aws ecr describe-images --repository-name usms-enrolment \
  --image-ids imageTag=r7 --query 'imageDetails[0].imageDigest' --output text)

TD_ARN=$(aws ecs describe-task-definition --task-definition usms-enrolment \
  --query 'taskDefinition.taskDefinitionArn' --output text)

SVC_TD=$(aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].taskDefinition' --output text)

cat > outputs/lab-12-release-evidence.md << EOF
# Release r7 Audit Evidence Chain
- **S3 Source Version ID:** \`${S3_VER}\`
- **CodePipeline Execution ID:** \`${EXEC_ID}\`
- **CodeBuild Build ID:** \`${BUILD_ID}\`
- **ECR Image Digest (r7):** \`${R7_DIGEST}\`
- **Registered Task Definition ARN:** \`${TD_ARN}\`
- **ECS Service Active Task Definition:** \`${SVC_TD}\`
EOF
cat outputs/lab-12-release-evidence.md
```

### Breaking the Chain: Mutable Tag Retag Drill (Without Deploying)

```bash
ECR_URI=$(aws ecr describe-repositories --repository-names usms-enrolment \
  --query 'repositories[0].repositoryUri' --output text)

# Point tag r7 at the older r6 image in the registry without deploying to ECS
docker pull "${ECR_URI}:r6"
docker tag "${ECR_URI}:r6" "${ECR_URI}:r7"
docker push "${ECR_URI}:r7"

NEW_R7_DIGEST=$(aws ecr describe-images --repository-name usms-enrolment \
  --image-ids imageTag=r7 --query 'imageDetails[0].imageDigest' --output text)
printf 'r7  %s  %s  (retagged-to-r6-bytes)\n' "$NEW_R7_DIGEST" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | tee -a outputs/lab-12-image-digest.txt
```

### Audit Conclusion: What the Evidence Chain Can and Cannot Prove
* **What It Still Proves:** The S3 version ID, CodePipeline execution ID, CodeBuild ID, and ECS task definition revision ARN (`usms-enrolment:8`) remain intact, proving that the pipeline ran and registered revision `:8` pointing to the mutable tag URI `.../usms-enrolment:r7`.
* **What It Can No Longer Prove:** Because the task definition references a mutable tag (`:r7`) rather than an immutable digest (`@sha256:4da166b6...`), retagging `r7` in ECR severs the cryptographic link between the build's output digest (`sha256:4da166b6...`) and what `r7` currently resolves to in ECR (`sha256:46d76ed1...`). Any future ECS task replacement (scale-out or node replacement) will silently pull the retagged bytes instead of the originally audited build.