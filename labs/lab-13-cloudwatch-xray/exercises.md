# Lab 13 – Independent Exercises & Your Turn Notes

## Step 8 – Your Turn: Filter Pattern False-Positive Analysis
- The token pattern `ERROR` matches event 4 (`ERROR USMS_EVENT ...`) and does not match the three normal `USMS_EVENT` lines.
- However, because CloudWatch text filter patterns match whitespace-delimited tokens anywhere in the message without positional anchoring, the false-positive line `USMS_EVENT {"event":"transcript.processed","reason":"no ERROR here"}` also matches `ERROR` (because `ERROR` is space-delimited inside the string).
- In production, I would not accept an unanchored `ERROR` token match on structured logs; instead, I would enforce a strict positional token check (e.g. `[level=ERROR, ...]`) or emit pure JSON events and use `{ $.level = "ERROR" }` so text inside payload values cannot trigger false error counts.

## Step 10 – Your Turn: Empty Datapoints vs. Zeroes (`defaultValue`)
- Querying the 15-minute window prior to today's upload returned an empty `Datapoints` list (`[]`), whereas querying the window containing our synthetic publish returned a data point with `Sum: 2.0`.
- An empty `Datapoints` list (`[]`) means no metric data points were emitted during that time window (which causes alarms without `defaultValue` or `treat-missing-data=breaching` to treat the period as missing data rather than zero), whereas a list of zeroes (`0.0`) proves a metric filter with `defaultValue=0` actively evaluated quiet periods; because `put-metric-filter` is unsupported on this Floci build, our build produced `[]` outside the synthetic publish window.

## Step 13 – Your Turn: Alias Rollback Comparison
- A real rollback of this regional Lambda alias takes only a few seconds (a single control-plane `UpdateAlias` API call with no cold-build or trigger reconfiguration), whereas the Lambda@Edge rollback described in Lab 10 Step 11 takes several minutes because CloudFront must replicate the reverted association across global edge locations.
