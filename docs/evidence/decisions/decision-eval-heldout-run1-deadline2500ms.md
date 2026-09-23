# Decision evaluation — heldout split

Generated 2026-09-23T18:53:53.729Z. 52 cases. Decision config decisions-2026-09-24.2.

**Jev: real calls via openrouter to typesafe/jev-1.13-20260917 (answered by typesafe/jev-1.13-20260917)**

| Metric | Existing detector | Jev |
| --- | --- | --- |
| Cases scored / total | 52 / 52 | 47 / 52 |
| Question precision | 100.0% | 100.0% |
| Question recall | 94.7% | 92.1% |
| Role accuracy (collapsed: new / attach / no request / unclear) | 88.5% | 100.0% |
| Role accuracy (six roles) | cannot express | 100.0% |
| Parent / grouping accuracy | 91.2% (n=34) | 100.0% (n=31) |
| Correction and narrowing accuracy | 100.0% (n=4) | 100.0% (n=3) |
| Answer-need accuracy | not produced | 88.4% (n=43) |
| Transcription-ambiguity accuracy | not produced | 62.5% (n=8) |
| Lost utterances | 2 | 3 |
| Incorrectly consumed utterances | 0 | 0 |
| Duplicate question events | 0 | 0 |
| Fallback rate (failed calls) | 0.0% | 9.6% |
| Timeout rate | 0.0% | 9.6% |
| Decision latency, median | 660 ms | 434 ms |
| Decision latency, p95 | 780 ms | 2434 ms |
| Inference cost (reported usage × published price) | not reported | $0.002295 |

Latency for the detector is measured at the client, round trip through the backend; for Jev, the adapter's own call time.
Confidence values are recorded per case in the JSON. They are **not** calibrated accuracies and no threshold is derived from them here.

## Complete answer requests

| Case | Decisions off | Shadow with a deliberately wrong decision |
| --- | --- | --- |
| en-frag-01 | complete | complete |
| en-corr-01 | complete | complete |
| en-frag-02 | complete | complete |
| en-topic-01 | complete | complete |
| en-imper-01 | complete | complete |
| en-multi-01 | complete | complete |
| en-multi-03 | complete | complete |
| fr-frag-01 | complete | complete |
| fr-multi-01 | complete | complete |
