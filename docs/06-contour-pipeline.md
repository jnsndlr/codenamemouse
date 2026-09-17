# Contour pipeline — September 16, 2026

Contour rebuilds now spatially index unfinished digs, reuse unchanged chunk results, and combine
consecutive segment updates within a received terrain packet. These changes reduce redundant
work and slow-frame spikes; active contour extraction remains a significant cost.

## Implementation

- Optional profiling separates committed-field composition, partial-carve composition, cache
  checks/reuse, rock subtraction, thinning, island filtering, visibility, triangulation, normals
  and mask blitting. The parent `contour` timer includes its children: do not sum both levels.
  Profiling remains disabled during normal gameplay.
- Unfinished strokes occupy 4m spatial buckets. Indexing their full potential segment keeps
  resumed tips discoverable without reindexing every step. Chunk queries include the sampling
  margin and retain the exact partial-stroke bounds check. Commit and collapse remove entries
  and empty buckets, so distant abandoned digs no longer require a whole-history scan per chunk.
- Each chunk retains its raw shape/visibility fields, relevant settings, rock revision and
  final mask. Exact input matches skip rock/filter/triangle/normal generation and preserve mesh
  resources. Mask texels are still restored after a full image clear; pending collision updates
  still flush. Rock and runtime shape-setting changes invalidate reuse. This adds one current
  record per chunk, not one record per operation. Existing committed-field caching is retained;
  a separate rock-field cache was not necessary for this pass.
- `adopt_segments` applies consecutive packet segment edits before rebuilding each changed
  plane once. Non-segment entries end a batch, preserving packet ordering. Collision and routing
  updates finish synchronously before returning. Live actor digging remains immediate because
  deferring across physics callbacks could change movement/collision ordering.

## Measurements

Rendered before/after runs both include regional meshes and earlier lifetime fixes. Same Godot
4.7.1 debug build, Apple M5 Pro, Forward+/Metal, 1280×720, VSync off, deterministic terrain
sequence, two arena lifecycles with 480 attempted strokes each. Runs were sequential without
concurrent audits. Each window contains 40 strokes / 320 attempted operations.

| Window ending at | Metric | Before | After |
| --- | --- | ---: | ---: |
| 240 strokes | Frame p99 | 18.11 ms | 12.12 ms |
| 480 strokes | Frame p99 | 22.06 ms | 15.94 ms |
| 480 strokes | Digging operation mean | 5.51 ms | 5.47 ms |

Percentiles above average the two cycles' separate window percentiles, not pooled samples.
The late-window p99 improved about 28%, while mean digging time barely changed. Occasional
frames still reached 22.53 ms. Gameplay callbacks are frozen in this terrain stress test;
these results do not establish full multiplayer FPS or an hour-long endurance guarantee.
Draw calls/primitives remained 1,501/131,216 in the final sample. Live tracked static memory
was about 1 MiB higher with caching. Both cycles returned to 6 nodes, 0 orphans, 110 resources
and approximately 83.5 MiB tracked static memory after teardown.

The isolated abandoned-dig probe forces 64 identical local rebuilds at each history size.
Construction is outside timing. It intentionally measures unchanged-input reuse together
with lookup scaling, rather than active digging FPS:

| Distant partial strokes | Before mean | After mean |
| --- | ---: | ---: |
| 0 | 2.429 ms | 0.727 ms |
| 128 | 2.658 ms | 0.755 ms |
| 512 | 4.235 ms | 0.759 ms |
| 1,024 | 4.347 ms | 0.744 ms |

A separate 48-stroke fixture took 52.71 ms batched versus 157.36 ms sequential with the same
caches and settings (about 67% less total time). The uncached reference took 173.14 ms.
This is one isolated bulk-update sample, not per-frame latency: large synchronous packets
can still stall, even though batching reduces their aggregate work.

Raw samples: [rendered before](performance-contour-before.txt),
[rendered after](performance-contour-after.txt), [abandoned before](performance-abandoned-before.txt),
[abandoned after](performance-abandoned-after.txt).

## Validation and remaining work

The contour audit compares against full-scan, uncached, sequential execution: 96 partial strokes,
negative/positive bucket boundaries, tip extension, commits, fog, mask clearing, pending collision,
mesh identity, runtime settings, collapse, index cleanup, batch geometry and reachable routing,
rock addition/removal, and mixed segment/forget/re-add packet ordering. Zero failures.

Also passing: 17 regional checks, all 15 tunnel scenarios plus subsystems, 64 field comparisons,
5 fog comparisons, 26 remote-state checks, 33 match checks, rendered lifecycle assertions and
the actual two-process replication audit. Rendered screenshots show consistent terrain and
lighting without visible region seams in the sampled view.

Triangle generation remains the largest individual contour stage: about 469 ms of the final
cycle's 1,336 ms contour total across 320 attempted operations. The next measured target is
extraction/triangle allocation, with geometry-equivalence checks retained. These changes do
not promise constant-time digging or that every frame meets the 16.67 ms budget.

```sh
godot --headless --log-file /tmp/contour-audit.log --path . --script tools/contour_pipeline_audit.gd
godot --headless --log-file /tmp/abandoned-probe.log --path . --script tools/abandoned_carve_probe.gd
godot --log-file /tmp/contour-growth.log --path . --script tools/long_session_probe.gd -- 2 480
```
