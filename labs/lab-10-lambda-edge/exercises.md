## 5. Independent Exercises (Exercises 1–5)

### Exercise 1: Cache-Key Explosion & Cache-Hit Ratio Analysis

* **Scenario:** A developer suggests forwarding all headers (`["*"]`) or all cookies (`"Forward": "all"`) in `DefaultCacheBehavior.ForwardedValues` so `viewer-request` can inspect arbitrary browser metadata.
* **Impact on Cache-Hit Ratio:** CloudFront computes the cache key from the normalized URI plus every forwarded header, cookie, and query parameter. Forwarding all headers (`User-Agent`, `Accept-Encoding`, `Accept-Language`, `Referer`) or session cookies fragments the cache key per user and browser version, driving the **cache-hit ratio toward $0\%$** even when every student requests the exact same public resource or when identical normalized URIs could be shared.
* **Architectural Fix:** Forward **only** the specific header required for authorization (`x-usms-student`), set `Cookies.Forward = "none"`, and `QueryString = false`, as implemented in `templates/lab-10-distribution-config.json`.

### Exercise 2: Version Immutability vs. Alias Mobility

* **Why CloudFront Refuses `$LATEST` and Aliases:** CloudFront replicates Lambda@Edge functions asynchronously across hundreds of global edge locations. Because `$LATEST` and aliases (`:live`) are mutable pointers, different edge PoPs could execute inconsistent code versions simultaneously, and rolling back an alias cannot be synchronized atomically worldwide. Requiring a **version-qualified ARN** (`...:function:usms-edge-viewer-request:1`) guarantees every edge PoP executes an immutable snapshot.
* **Why S3 Notifications Benefit from `:live`:** S3 bucket notifications run in a single AWS region (`us-east-1`). Pointing the S3 notification to `:live` decouples S3 storage configuration from Lambda deployments: publishing version `2` and shifting the `:live` alias (`aws lambda update-alias --name live --function-version 2`) updates the active notifier without modifying the S3 bucket notification configuration.

### Exercise 3: Confused-Deputy Prevention on S3 Resource Policies

* **Vulnerability Without `AWS:SourceArn`:** Granting `s3.amazonaws.com` permission to invoke `usms-transcript-notifier:live` without a `Condition` allows *any* S3 bucket in *any* AWS account (if its ARN or bucket name is guessed/configured) to trigger the function.
* **Mitigation Applied:** In Step 19, `aws lambda add-permission` attached:
  ```json
  "Condition": {
    "ArnLike": {
      "AWS:SourceArn": "arn:aws:s3:::usms-student-data"
    }
  }
  ```
  This restricts invocation strictly to events originating from `usms-student-data`.

### Exercise 4: Defense-in-Depth Security Headers (`origin-response` vs. S3)

* **Why Inject Headers at `origin-response`:** Amazon S3 object metadata natively supports `Content-Type` and `Cache-Control`, but S3 does not inject browser security headers (`Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy`) onto `GET` responses.
* **Caching Efficiency:** Placing header injection in `origin-response` (rather than `viewer-response`) means the function runs **only on cache misses**, and CloudFront caches the hardened response headers at the edge for subsequent hits (`s-maxage=3600`), minimizing edge compute cost and latency.

### Exercise 5: S3 Origin Readiness & Event Filter Hygiene

* **Prefix/Suffix Isolation:** The S3 notification `usms-transcript-upload` filters strictly on `prefix: transcripts/` and `suffix: .json`. Uploading non-JSON assets (e.g., `.pdf` or `.csv`) or writing outside `transcripts/` will not invoke `usms-transcript-notifier`, preventing recursive trigger loops if the notifier ever writes logs or artifacts back to another prefix in the same bucket.
* **URL-Encoded Keys:** S3 event records URL-encode object keys (replacing spaces with `+`). Using `urllib.parse.unquote_plus(raw_key)` in `notifier.py` ensures keys containing spaces or special characters decode accurately before downstream `s3:GetObject` calls.

---

## 6. Review Questions & Notes (Section 14)

### Q1. Why does Lambda@Edge forbid environment variables, VPC attachments, and Lambda layers?
Lambda@Edge functions are replicated across globally distributed CloudFront edge locations rather than pinned to a single regional VPC. VPC ENIs are regional resources that cannot span global edge PoPs without introducing cross-region latency; layers increase deployment package size beyond strict edge bundle limits (`1 MB` for viewer triggers); and environment variables are mutable configuration state that would violate the immutability required for atomic edge replication. Configuration needed at the edge must instead be baked into the deployment artifact or derived from request headers/origin metadata.

### Q2. What is the difference between `viewer-request` and `origin-request` triggers, and why was `viewer-request` chosen for authentication and URI normalization?
* **`viewer-request`** executes on **every** incoming request before CloudFront checks its cache.
* **`origin-request`** executes **only on a cache miss** before CloudFront forwards the request to S3.

`viewer-request` was chosen for two reasons:
1. **Security:** Authentication (`x-usms-student`) must run on every request so an unauthenticated user cannot receive a cached transcript served from an earlier authenticated user's cache hit.
2. **Cache Efficiency:** Normalizing `/transcripts/2026/STU-00417.json` to lowercase *before* the cache lookup ensures mixed-case URLs map to the same canonical cache entry.

### Q3. Why did `usms-edge-viewer-request` return HTTP `200` in the Lambda `Invoke` metadata table even when denying an unauthenticated request with HTTP `403`?
In Lambda, `StatusCode: 200` (`FunctionError: None`) indicates that the **Lambda runtime executed the handler cleanly without throwing an unhandled exception**. The HTTP `403 Forbidden` status is inside the **returned CloudFront response payload** (`{"status": "403", "statusDescription": "Forbidden", ...}`), which instructs CloudFront to short-circuit the request and send a `403` HTTP response directly to the viewer.

### Q4. Why must CloudFront `LambdaFunctionAssociations` reference a numbered version (`:1`) rather than `$LATEST` or an alias (`:live`)?
CloudFront requires immutable code snapshots when distributing functions across global PoPs. `$LATEST` changes whenever `update-function-code` is called, and aliases can be repointed at any time. Referencing `:1` guarantees deterministic behavior across all edge caches and provides an auditable rollback point (`:1` vs. `:2`).

### Q5. How does `usms-transcript-notifier` handle S3 object keys containing spaces or special characters, and why is that necessary?
S3 event notifications emit URL-encoded object keys (for example, `stu+00417+final.json` or `%20`). `notifier.py` passes the raw key through `urllib.parse.unquote_plus(raw_key)` so that downstream logging and any subsequent `s3.get_object(Bucket=..., Key=...)` calls receive the exact unencoded S3 key string.

### Q6. What happens if `scripts/cleanup/lab-10-cleanup.sh` is executed prematurely before completing subsequent S3 labs?
`lab-10-cleanup.sh` empties and deletes `usms-student-data` in addition to removing the Lab 10 Lambda functions and notifications. Because downstream S3 configuration labs depend on `usms-student-data`, running cleanup early would delete the shared origin bucket (though `usms-lambda-exec-role` is intentionally preserved because it belongs to Lab 01).