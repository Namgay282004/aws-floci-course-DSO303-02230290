# Lab 13 – Review Questions & Answers

1. **Difference between a log group, a log stream, and a log event (and why one stream per container/instance):**
   - A **log group** is the top-level container owning retention policy, KMS encryption, access permissions, and metric filters (e.g., `/usms/central/application`).
   - A **log stream** is a sequence of log events from a single emitter/source inside that group (e.g., one Lambda sandbox or one ECS task).
   - A **log event** is an immutable `(timestamp, message)` record inside a stream.
   - Writing to one stream per container/instance avoids sequence-token contention and keeps interleaved stdout lines from concurrent processes separate so each instance's lifecycle can be traced cleanly.

2. **Why `filter-log-events` is fine for dozens of lines whereas CloudWatch Logs Insights is used for millions:**
   - `filter-log-events` scans log events sequentially and streams raw matching records back to the client; over millions of events, client-side download and scanning become slow and throttled.
   - CloudWatch Logs Insights runs a distributed, parallel query engine inside AWS that parses fields (`parse`, `fields`), filters (`filter`), and aggregates (`stats count(), avg(), pct()`) across gigabytes of logs server-side, returning only the compact aggregated result table.

3. **Why a metric filter sets `defaultValue=0` (and what happens to an absence alarm without it):**
   - `defaultValue=0` forces the metric filter to emit a `0` data point during periods when log events arrive but none match the filter pattern.
   - Without `defaultValue=0`, quiet periods produce *no data points* (missing data) rather than `0`. An alarm configured with `LessThanThreshold` and `TreatMissingData=notBreaching` (or `ignore`) would stay in `OK` or `INSUFFICIENT_DATA` instead of firing when traffic drops to zero.

4. **How dimensions partition metrics and why `StudentId` must never be a dimension:**
   - CloudWatch treats each unique `(Namespace, MetricName, sorted Dimension Name=Value pairs)` combination as a completely separate time series; querying a metric requires specifying the exact dimension set used when publishing.
   - Using high-cardinality values like `StudentId` creates millions of sparse, single-point time series, exploding custom-metric costs (billed per unique metric/dimension combination) and making aggregation across students impossible without publishing a separate un-dimensioned series.

5. **Why `usms-notify-silence` sets `treat-missing-data=breaching` while `usms-transcript-lag-high` sets `notBreaching`:**
   - `usms-notify-silence` detects pipeline silence: if the notifier stops running, zero metrics are emitted, so missing data *is* the failure condition (`breaching`).
   - `usms-transcript-lag-high` detects slow notifications when transcripts are actively processed: if no transcripts are requested overnight, no latency samples are emitted, which means there is no lag breach (`notBreaching`), preventing false pages during quiet hours.

6. **Difference between an X-Ray annotation and X-Ray metadata (which is indexed, and why):**
   - **Annotations** are flat key-value pairs (`string`, `number`, or `boolean`) that X-Ray **indexes** so operators can filter and search traces with expressions like `annotation.faculty = "science"`.
   - **Metadata** can hold arbitrary nested JSON objects, arrays, and strings; it is stored with the trace for inspection when debugging a specific trace ID, but is **not indexed** for search queries in order to bound index storage and query latency.

7. **Why `USMSObservabilityWrite` scopes `logs:PutLogEvents` by ARN prefix and `cloudwatch:PutMetricData` by `cloudwatch:namespace` condition:**
   - Scoping `logs:PutLogEvents` to `/usms/*:*` and `/aws/lambda/usms-*:*` prevents a compromised workload from polluting or overwriting audit/system log groups outside the USMS application.
   - Because `cloudwatch:PutMetricData` does not support resource-level ARNs in IAM, the `StringEquals` condition on `cloudwatch:namespace = "USMS/Application"` enforces least privilege by ensuring workloads cannot inject fake metrics into `AWS/*` namespaces or other teams' namespaces.
