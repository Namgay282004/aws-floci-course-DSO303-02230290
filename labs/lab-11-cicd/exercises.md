# Lab 11 Independent Lab Exercises

## Exercise 1 — Basic: Second Build Project (`usms-results-build`)
- Created `labs/lab-11-cicd/app-results/` with `VERSION` (`r1`), `src/index.html`, and `buildspec.yml`, packaged it via `usms-pack-source.sh`, and uploaded it to `s3://usms-pipeline-artifacts/source/usms-results-src.zip`.
- Created CodeBuild project `usms-results-build` reusing `usms-codebuild-role` (`arn:aws:iam::000000000000:role/usms-codebuild-role`) and validated its build locally (`build-metadata.json` outputs `"service": "results", "release": "r1"`).
- **Policy scope explanation:** `USMSCodeBuildBase` already permits `usms-results-build` to read its source and write its artifact because its S3 statement grants `s3:GetObject`, `s3:GetObjectVersion`, and `s3:PutObject` on `arn:aws:s3:::usms-pipeline-artifacts/*` rather than restricting to a single object prefix, though its CloudWatch Logs statement only allows `/aws/codebuild/usms-enrolment-build`.

## Exercise 2 — Intermediate: `finally` Block and Build Summary
- Added a `finally` block to `post_build` in `labs/lab-11-cicd/app/buildspec.yml` that writes `release=<ver> smoke_exit=<code> timestamp=<utc>` into `dist/build-summary.txt` regardless of whether `tests/smoke.sh` succeeds or fails.
- **Local runner note:** `scripts/utilities/usms-buildspec-run.sh` parses `phases.<name>.commands` with `set -Eeuo pipefail` and does not parse `finally` blocks, so testing failure behavior locally requires inspecting the generated buildspec YAML or running the `finally` snippet explicitly after a non-zero test exit; on real AWS CodeBuild, `finally` runs automatically after `commands` even when `commands` exits non-zero, while the build still ends `FAILED`.

## Exercise 3 — Problem Solving: Robust Configuration Check & `aws:SourceArn`
- Replaced the whitespace-sensitive `grep` container check in `pre_build` with an inline `python3 -c` JSON parser that compares `config/service.json["container"]` against `"enrolment-api"` and prints both expected and actual values on mismatch.
- Verified formatting independence by reformatting `config/service.json` with 4-space indentation (`indent=4`) and confirming the build still passes.
- Updated `policies/trust-codebuild.json` and `usms-codebuild-role` with `"aws:SourceArn": "arn:aws:codebuild:us-east-1:000000000000:project/usms-enrolment-build"` alongside `aws:SourceAccount` (see `notes/lab-11-notes.md` for the confused-deputy analysis).

## Exercise 4 — Challenge: Event-Driven S3 Trigger Without Polling
- Authored `templates/lab-11-eventbridge-rule.json` matching `source: ["aws.s3"]`, `detail-type: ["Object Created"]`, bucket `usms-pipeline-artifacts`, and exact object key `source/usms-enrolment-src.zip`, and `templates/lab-11-eventbridge-target.json` targeting `arn:aws:codepipeline:us-east-1:000000000000:usms-enrolment-pipeline`.
- **CloudTrail / S3 EventBridge dependency:** Enabling Amazon S3 Event Notifications to EventBridge on `usms-pipeline-artifacts` emits `Object Created` events directly on `PutObject` without requiring a CloudTrail trail, whereas matching `AWS API Call via CloudTrail` requires a trail logging S3 data events.
- **IAM target role:** EventBridge needs its own execution role (`usms-eventbridge-pipeline-role`) trusting `events.amazonaws.com` with only `codepipeline:StartPipelineExecution` on `usms-enrolment-pipeline`—separate from `usms-codepipeline-role` so EventBridge cannot access S3 artifacts or `iam:PassRole`.
- **What ran vs. did not:** Both JSON templates validated cleanly and `aws events put-rule` / `put-targets` registered the configuration in Floci, while end-to-end automatic S3-to-EventBridge event emission is not modeled in Floci.

## Exercise 5 — Integration: Deployment Contract for Lab 12
- Extended the `build` phase of `labs/lab-11-cicd/app/buildspec.yml` to generate `dist/imagedefinitions.json` as a single-element JSON array `[{"name": "enrolment-api", "imageUri": "nginx:alpine"}]` dynamically reading `container` from `config/service.json` and `IMAGE_URI` (defaulting to `nginx:alpine`).
- Added an eighth assertion to `labs/lab-11-cicd/app/tests/smoke.sh` verifying `dist/imagedefinitions.json` is a 1-item JSON array matching `config/service.json`.
- Recorded the artifact store details and `imagedefinitions.json` contents into `outputs/lab-11-lab08b-readiness.txt` for Lab 12 Step 1.
