# Segmented live-draft benchmark

Date: 2026-08-02

## Decision

The stable-prefix/mutable-tail preview passed the defined replay gates. Production keeps the small preview model and the independent full-recording large-v3 final pass.

## Policy selection

Two faster policies were rejected before this final run. The initial aggressive tail reduced inference by 62.04% but worsened final-draft micro WER by 4.43 points. A 15-second/25-word tail reduced inference by 30.75% but missed the predefined quality gate at +3.42 points on its corrected authoritative rerun. The final 20-second/35-word tail below was chosen only after it passed a separate same-corpus tuning sweep; this report is its fresh alternating-order replay.

## Headline totals

The corpus contains 8 turns, 698.10 seconds of speech, and 543 historical draft cutoffs.

| Measure | Cumulative prefix | Stable prefix + mutable tail | Change |
| --- | ---: | ---: | ---: |
| Executed preview runs | 543 | 543 | +0 |
| Audio submitted to preview | 28980.19 s | 15205.90 s | 47.53% less |
| Preview inference total | 475.15 s | 316.33 s | 33.43% less |
| Compute / source audio | 0.681× | 0.453× | — |
| Maximum preview window | 222.45 s | 71.97 s | — |
| Final-draft micro WER vs large-v3 | 11.82% | 13.94% | +2.12 points |

## Latency distribution

Wall time covers the local HTTP request and model inference through one persistent worker. Model startup and audio conversion are excluded.

| Implementation | Mean | Median | P90 | P95 | P99 | Minimum | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Cumulative prefix | 875.1 ms | 697.0 ms | 1945 ms | 2349 ms | 2749 ms | 159 ms | 3270 ms |
| Segmented tail | 582.6 ms | 578.0 ms | 890 ms | 979 ms | 1244 ms | 164 ms | 1291 ms |

### Latency as dictation grows

| Progress | Cumulative mean / P95 | Segmented mean / P95 |
| --- | ---: | ---: |
| First third | 443.6 / 847 ms | 434.6 / 804 ms |
| Middle third | 1013.9 / 1927 ms | 689.1 / 1157 ms |
| Last third | 1556.1 / 2746 ms | 738.9 / 1125 ms |

## Transcript quality

Quality is reference-relative, not human-ground-truth accuracy. The reference is one full-recording large-v3 transcript with timestamps. Partial comparisons use only reference tokens whose end timestamp is at or before that historical cutoff.

| Scope | Implementation | Comparisons | Exact | Macro WER | Micro WER | Macro CER | Micro CER | Mean similarity |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| All partial drafts | Cumulative | 543 | 18 | 14.51% | 12.44% | 10.57% | 8.28% | 89.76% |
| All partial drafts | Segmented | 543 | 20 | 18.36% | 17.28% | 13.37% | 11.78% | 86.72% |
| Last draft vs full final | Cumulative | 8 | 0 | 12.38% | 11.82% | 6.65% | 6.93% | 90.16% |
| Last draft vs full final | Segmented | 8 | 0 | 13.71% | 13.94% | 7.64% | 8.63% | 88.87% |

## Per-turn results

| Sample | Profile  |    Audio | Runs old/new | Preview input old/new | Inference old/new |  P95 old/new | Splits | Final WER old/new |
| -----: | -------- | -------: | -----------: | --------------------: | ----------------: | -----------: | -----: | ----------------: |
|      1 | secondary |   6.85 s |          8/8 |           29.0/29.0 s |         1.6/1.7 s |   253/269 ms |      0 |       18.8%/18.8% |
|      2 | secondary |  11.87 s |        14/14 |           84.7/84.7 s |         3.6/3.8 s |   344/375 ms |      0 |       12.5%/12.5% |
|      3 | primary   |  31.63 s |        39/39 |         632.3/613.3 s |       14.4/15.3 s |   699/628 ms |      2 |         7.1%/7.1% |
|      4 | primary   |  41.81 s |        48/48 |         966.7/873.2 s |       21.5/22.6 s |   818/802 ms |      1 |       14.8%/14.8% |
|      5 | primary   |  74.27 s |        72/72 |       2342.5/1663.8 s |       48.3/40.9 s |  1374/982 ms |      3 |         8.2%/9.9% |
|      6 | wheatley | 142.25 s |      110/110 |       6172.2/3342.2 s |       97.0/65.0 s |  1953/977 ms |      4 |        8.7%/15.1% |
|      7 | wheatley | 166.53 s |      119/119 |       7788.0/4449.6 s |      120.5/85.5 s | 2323/1244 ms |      4 |       11.7%/12.1% |
|      8 | wheatley | 222.89 s |      133/133 |      10964.8/4150.0 s |      168.2/81.5 s |  2747/958 ms |     20 |       17.3%/19.4% |

## Boundary and join evidence

- Confirmed splits: 34 (clause: 5, sentence: 28, word: 1).
- Detected repeated-word joins: 0.
- Empty mutable tails at a split: 0.
- Defined gates: `{"compute_materially_lower": true, "no_detected_join_duplicates": true, "no_empty_split_tails": true, "quality_not_materially_worse": true, "segmentation_exercised": true}`.

Each split required the same complete prefix in two consecutive results, at least 2.5 seconds and five words in the candidate stable chunk, at least 20 seconds and 35 words in the mutable tail, and a timed token boundary. Sentence punctuation was preferred; clause punctuation activated at 50 seconds and the timed word fallback at 70 seconds.

## Runtime end-to-end evidence

A separate real-runtime check streamed a saved 31.627-second Ogg/Opus recording through the console client and live WebSocket API. The D server recorded 37 preview runs, two confirmed sentence splits, three applied post-split runs, and a 28.57-second maximum draft window. It then ran the independent large-v3 final over the complete 31.627 seconds, persisted the turn, and delivered the fake persistent-Pi answer back to the console.

The first runtime attempt also caught an invalid-metrics defect: D floating-point locals default to `NaN`, so the new window total/max accumulators had to be explicitly initialized. The corrected run and a regression unit test cover that failure.

## Method and transparency limits

- Both implementations used the same small model, persistent worker, beam size 1, max context -1, source recordings, and historical cutoff schedule. Execution order alternated per sample to reduce thermal/order bias.
- The cumulative control used timestamps disabled, matching the former production request. Segmentation enabled timestamps because it requires the returned timed pieces.
- Replay is sequential. It measures request cost and quality at real saved cutoffs, but does not recreate live queue replacement, socket scheduling, or concurrent users.
- Large-v3 is a strong consistent reference, not a manually verified transcript. WER and CER therefore measure draft agreement with Wheatley's final model, not absolute speech-recognition accuracy.
- No private transcript text is included in this report or raw JSON. Raw data contains turn identifiers and numeric metrics only.

The raw numeric result is not included because its source corpus contains
private recorded speech.
