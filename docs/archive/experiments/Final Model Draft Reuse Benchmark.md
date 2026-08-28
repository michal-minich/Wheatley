# Final-model draft reuse benchmark

Date: 2026-08-02

## Decision

Do not replace the current small preview model with continuous large-v3 drafts,
and do not skip final full-recording transcription yet.

The direction was reasonable to test: a persistent large-v3 worker removes
model startup from each draft, and reusing its last cumulative result could
save 1–11 seconds at the endpoint in this sample. It does not currently meet
the correctness or compute criteria, however. The last preview prefix is not
necessarily the full accepted recording, and large-v3 can revise earlier text
when given the final tail.

Wheatley also does not concatenate independently transcribed sections. Each
preview run retranscribes the cumulative recording prefix. The relevant test is
therefore the last cumulative prefix versus the complete recording.

## Result

Six existing English turns were sampled across 7–167 seconds, using both Primary
and Wheatley recordings. Each turn's last actual preview cutoff was rerun with
the persistent large-v3 model and compared with a full-recording run through
the same loaded model and settings. The complete benchmark was repeated; both
runs produced identical comparison metrics.

|    Audio | Unseen tail | Existing preview runs | Exact match | Token edit distance | Large final time |
| -------: | ----------: | --------------------: | ----------: | ------------------: | ---------------: |
|   7.39 s |      0.08 s |                     9 |         yes |               0.00% |           1.24 s |
|  13.31 s |      0.32 s |                    16 |          no |               6.45% |           1.56 s |
|  31.63 s |     0.00 s* |                    39 |          no |               2.90% |           3.44 s |
|  74.27 s |      0.24 s |                    72 |          no |               5.33% |           6.62 s |
| 142.25 s |      0.74 s |                   110 |          no |              14.43% |           9.25 s |
| 166.53 s |      0.56 s |                   119 |          no |               1.20% |          11.27 s |

Only 1/6 normalized drafts matched the final text exactly. Mean token edit
distance was 5.05%; mean sequence similarity was 97.38%. The starred cutoff is
equal only at the stored 10 ms metric precision; the converted prefix may
still exclude a fractional tail.

Continuous large-v3 drafting at the existing preview cadence is also unlikely
to keep up. The current small-model draft runs consumed 412 seconds across 435
seconds of audio. Scaling from measured persistent large-v3 prefix inference,
the same cumulative schedule projects to about 1,253 seconds—2.88 times audio
duration—before the separate final run. This projection is approximate, but
the margin is too large to justify implementation without a different draft
schedule.

## Guidance

Keep the small preview model for responsive UI and endpoint evidence, then run
large-v3 once on all accepted samples. The subsequent
[segmented live-draft benchmark](Segmented%20Draft%20Benchmark.md) replaced the
small model's cumulative schedule with a confirmed stable prefix plus mutable
tail; it did not change this benchmark's conclusion about independent final
STT. A large-v3 draft should be considered reusable only when its audio sample
count exactly equals the committed sample count and a conservative reliability
gate passes. A slower periodic large-model cadence alone is insufficient
because its last draft becomes stale by design.

This is a model-to-model consistency benchmark, not an accuracy benchmark: no
human reference transcript was produced. The report stores metrics and source
turn identifiers, not private transcript text. Reproduction script:
`scripts/benchmarks/final-model-draft-reuse.py`.
