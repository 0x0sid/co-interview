# Decision evaluation — heldout split

Generated 2026-09-23T18:56:35.275Z. 52 cases. Decision config decisions-2026-09-24.2.

**Jev: real calls via openrouter to typesafe/jev-1.13-20260917 (answered by typesafe/jev-1.13-20260917)**

| Metric | Existing detector | Jev |
| --- | --- | --- |
| Cases scored / total | 52 / 52 | 52 / 52 |
| Question precision | 100.0% | 100.0% |
| Question recall | 94.7% | 100.0% |
| Role accuracy (collapsed: new / attach / no request / unclear) | 88.5% | 100.0% |
| Role accuracy (six roles) | cannot express | 100.0% |
| Parent / grouping accuracy | 91.2% (n=34) | 100.0% (n=34) |
| Correction and narrowing accuracy | 100.0% (n=4) | 100.0% (n=4) |
| Answer-need accuracy | not produced | 89.6% (n=48) |
| Transcription-ambiguity accuracy | not produced | 62.5% (n=8) |
| Lost utterances | 2 | 0 |
| Incorrectly consumed utterances | 0 | 0 |
| Duplicate question events | 0 | 0 |
| Fallback rate (failed calls) | 0.0% | 0.0% |
| Timeout rate | 0.0% | 0.0% |
| Decision latency, median | 663 ms | 362 ms |
| Decision latency, p95 | 752 ms | 1577 ms |
| Inference cost (reported usage × published price) | not reported | $0.002535 |

Latency for the detector is measured at the client, round trip through the backend; for Jev, the adapter's own call time.
Confidence values are recorded per case in the JSON. They are **not** calibrated accuracies and no threshold is derived from them here.

## Complete answer requests

| Case | Decisions off | Shadow with a deliberately wrong decision |
| --- | --- | --- |
