# Lab 13 : Independent Exercises & Your Turn Notes

### Step 8 : Your Turn: Filter Pattern False-Positive Analysis
- The token pattern `ERROR` matches event 4 (`ERROR USMS_EVENT ...`) and does not match the three normal `USMS_EVENT` lines.
- However, because CloudWatch text filter patterns match whitespace-delimited tokens anywhere in the message without positional anchoring, the false-positive line `USMS_EVENT {"event":"transcript.processed","reason":"no ERROR here"}` also matches `ERROR` (because `ERROR` is space-delimited inside the string).
- In production, I would not accept an unanchored `ERROR` token match on structured logs; instead, I would enforce a strict positional token check (e.g. `[level=ERROR, ...]`) or emit pure JSON events and use `{ $.level = "ERROR" }` so text inside payload values cannot trigger false error counts.

### Step 10 : Your Turn: Empty Datapoints vs. Zeroes (`defaultValue`)
- Querying the 15-minute window prior to today's upload returned an empty `Datapoints` list (`[]`), whereas querying the window containing our synthetic publish returned a data point with `Sum: 2.0`.
- An empty `Datapoints` list (`[]`) means no metric data points were emitted during that time window (which causes alarms without `defaultValue` or `treat-missing-data=breaching` to treat the period as missing data rather than zero), whereas a list of zeroes (`0.0`) proves a metric filter with `defaultValue=0` actively evaluated quiet periods; because `put-metric-filter` is unsupported on this Floci build, our build produced `[]` outside the synthetic publish window.

### Step 13 : Your Turn: Alias Rollback Comparison
- A real rollback of this regional Lambda alias takes only a few seconds (a single control-plane `UpdateAlias` API call with no cold-build or trigger reconfiguration), whereas the Lambda@Edge rollback described in Lab 10 Step 11 takes several minutes because CloudFront must replicate the reverted association across global edge locations.


## Lab 13 : Independent Lab Exercises

### Exercise 1 : Structured Log Filtering by Faculty & Event Outcome

#### Objective

Query `/usms/central/application` using `aws logs filter-log-events` to isolate structured `USMS_EVENT` records by faculty (`science` vs. `engineering`) and inspect failure reasons without downloading unrelated health-check traffic.

#### Command Executed

```bash
aws logs filter-log-events \
  --log-group-name "/usms/central/application" \
  --filter-pattern "USMS_EVENT" \
  --query 'events[].[timestamp, message]' \
  --output text
```

#### Observed Output & Analysis

Filtering on `USMS_EVENT` excluded `HEALTH_CHECK status=ok component=central-logger` records while returning transcript lifecycle events such as `transcript.requested`, `transcript.processed`, and `ERROR USMS_EVENT transcript.failed`.

Aggregating the JSON payloads across the log group yielded:

| Faculty | Events |
|---|---:|
| `science` | 4 |
| `engineering` | 3 |

This confirms that structured JSON behind a consistent event prefix supports targeted filtering and downstream parsing. The command filters by the event prefix; faculty-specific totals require an additional parsing or filtering step.

---

### Exercise 2 : Custom Metric Dimensional Isolation Verification

#### Objective

Verify that CloudWatch treats different dimension sets on the same metric name (`TranscriptsProcessed`) as independent time series rather than automatically rolling them up.

#### Command Executed

```bash
aws cloudwatch list-metrics \
  --namespace "USMS/Application" \
  --metric-name "TranscriptsProcessed" \
  --output table
```

#### Observed Output & Analysis

`list-metrics` returned three distinct metric definitions under `USMS/Application`:

| Metric | Dimensions |
|---|---|
| `TranscriptsProcessed` | `Faculty=science`, `Stage=notify` |
| `TranscriptsProcessed` | `Faculty=engineering`, `Stage=notify` |
| `TranscriptsProcessed` | None (un-dimensioned) |

Querying `get-metric-statistics` without `--dimensions` reads only the un-dimensioned series. To retrieve a faculty-specific series, supply the **exact complete dimension set** used when the metric was published (for example, both `Faculty` and `Stage`). CloudWatch does not automatically aggregate these distinct series.

---

### Exercise 3 : Cross-Signal Trace Correlation (Logs ↔ Metrics ↔ Trace ID)

#### Objective

Emit a correlated telemetry transaction using `scripts/utilities/usms-emit-telemetry.sh` and match the generated trace identifier across `outputs/lab-13-trace-ids.txt` and `/usms/central/application`.

#### Commands Executed

```bash
./scripts/utilities/usms-emit-telemetry.sh science 0.45

TRACE_ID=$(tail -n 1 outputs/lab-13-trace-ids.txt)
echo "Joining trace id: $TRACE_ID"

aws logs filter-log-events \
  --log-group-name "/usms/central/application" \
  --filter-pattern "$TRACE_ID" \
  --query 'events[].[timestamp, message]' \
  --output text
```

#### Observed Output & Analysis

**Trace ID generated:** `1-6af840d5-fb62ea34d792c09c491bec57`

**Matched log event:**

```text
1794654421136   USMS_EVENT {"event": "transcript.processed", "faculty": "science", "seconds": 0.45, "trace_id": "1-6af840d5-fb62ea34d792c09c491bec57"}
```

Embedding a trace ID in structured log messages allows operators to find the corresponding event in `/usms/central/application`, even when X-Ray ingestion is unavailable in the local emulator. This demonstrates **trace-to-log correlation**; full metric-to-trace correlation would additionally require an explicit shared identifier or other linking evidence.

---

### Exercise 4 : Alarm Missing-Data Policy & State Transition Audit

#### Objective

Validate how `usms-transcript-lag-high` (`TreatMissingData=notBreaching`) transitions when manually set to `ALARM` and restored to `OK`, and inspect the configured missing-data policy.

#### Commands Executed

```bash
aws cloudwatch set-alarm-state \
  --alarm-name usms-transcript-lag-high \
  --state-value ALARM \
  --state-reason "Exercise 4: validating threshold alarm transition"

aws cloudwatch describe-alarms \
  --alarm-names usms-transcript-lag-high \
  --query 'MetricAlarms[0].{Name:AlarmName, State:StateValue, MissingData:TreatMissingData}' \
  --output table

aws cloudwatch set-alarm-state \
  --alarm-name usms-transcript-lag-high \
  --state-value OK \
  --state-reason "Exercise 4: restoring OK state"
```

#### Observed Output & Analysis

The alarm was manually set to `ALARM` and then restored to `OK`.

- **`notBreaching`:** Missing datapoints are treated as non-breaching during alarm evaluation, helping avoid false alerts during quiet periods.
- **`breaching`:** Missing datapoints are treated as breaching; this is appropriate for `usms-notify-silence` when absent telemetry indicates a possible stopped notifier.

> **Verification note:** `set-alarm-state` demonstrates manual state changes, not a threshold-driven alarm evaluation. A separate missing-datapoint test is required to prove the policy's behavior over time. State persistence across a restart also requires an explicit restart-and-recheck test.

---

### Exercise 5 : Log Retention Policy Audit & Adjustment

#### Objective

Demonstrate lifecycle governance on edge Lambda logs by reducing retention for `/aws/lambda/usms-edge-viewer-request` from 14 days to 7 days and verifying the change with `describe-log-groups`.

#### Commands Executed

```bash
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/usms-edge-viewer-request" \
  --query 'logGroups[0].[logGroupName, retentionInDays, storedBytes]' \
  --output table

aws logs put-retention-policy \
  --log-group-name "/aws/lambda/usms-edge-viewer-request" \
  --retention-in-days 7

aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/usms-edge-viewer-request" \
  --query 'logGroups[0].[logGroupName, retentionInDays, storedBytes]' \
  --output table
```

#### Observed Output & Analysis

| Property | Before | After |
|---|---|---|
| Log group | `/aws/lambda/usms-edge-viewer-request` | `/aws/lambda/usms-edge-viewer-request` |
| Retention | 14 days | 7 days |
| Stored bytes | 0 | 0 |

A shorter retention period can reduce storage costs for high-volume edge logs, provided it meets operational and compliance needs. Core application logs such as `/usms/central/application` retain 30 days for auditability.

---

### Conclusion

These five independent exercises demonstrate key observability and governance tasks in the Floci-based USMS environment: targeted log filtering, CloudWatch metric dimension isolation, trace-ID-based log correlation, manual alarm-state inspection, and log retention management. Together, they show how consistent telemetry conventions and lifecycle policies can improve troubleshooting and operational control. Additional tests would be needed to demonstrate automatic alarm evaluation, restart persistence, and complete cross-signal tracing.

### Optional Git Commands

To stage and commit the Lab 13 report and independent exercises after saving them to the project:

```bash
git add labs/lab-13-cloudwatch-xray/README.md \
        labs/lab-13-cloudwatch-xray/independent-exercises.md

git commit -m "Add conclusion section to Lab 13 report and separate independent-exercises.md"
```

> These Git commands are provided for reference; they have not been executed here. The `README.md` must be updated separately if it does not already contain the conclusion.
