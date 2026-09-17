# Regional tunnel meshes — September 16, 2026

Local digging now rebuilds 8×8 metre render regions instead of four meshes spanning the entire
underground plane. In a rendered, growing-network benchmark this reduced the mesh stage by
about 95% in the largest window and average digging-operation time by about 41%. It improves
late-match scaling, but the remaining contour work still produces frames above 16.67 ms.

## What changed

Each region assembles at most four existing 4×4 metre contour chunks. Dirty chunk keys directly
identify the affected regions; the drawing path never scans every cached chunk on the plane.
Unchanged regions keep the same mesh resources. Floor, earth walls, stone and bedrock retain
separate materials under per-plane roots, so depth transforms and focus visibility still apply
together. Empty material regions release their mesh nodes, and wholly empty regions leave the
lookup table. Geometry remains opaque with shadow casting disabled, as before.

The contour algorithm, fog rules and chunk-local collision shapes are unchanged. A region
boundary only partitions existing triangles; it does not regenerate a seam or change normals.
The tunnel invariant suite now examines every regional wall mesh instead of a single parent mesh.

Optional `profile_rebuilds` instrumentation reports contour, mask upload, mesh assembly/upload,
collision and lighting time. It is disabled in normal gameplay; `long_session_probe.gd` enables
it and clears the counters after each sample window.

## Before/after measurements

Both versions include the earlier lifetime, light-reuse and batched-mask-upload fixes. Both use
the same profiling instrumentation and run sequentially, without concurrent test processes.
Godot 4.7.1 debug build, Forward+/Metal 4.0, Apple M5 Pro, 1280×720, VSync disabled. Each process
runs two complete arena lifecycles and 480 attempted strokes per cycle (465 committed), with
seven carve steps and one commit per stroke. The camera, frozen gameplay and terrain sequence
are identical. A sample window covers 40 strokes / 320 attempted operations.

Averages of the two cycles' reported windows:

| Window ending at | Metric | Whole-plane meshes | 8m regions |
| --- | --- | ---: | ---: |
| 240 strokes | Digging operation mean | 7.22 ms | 5.49 ms |
| 240 strokes | Frame p99 | 19.72 ms | 18.61 ms |
| 480 strokes | Digging operation mean | 9.57 ms | 5.67 ms |
| 480 strokes | Frame p95 | 17.73 ms | 13.54 ms |
| 480 strokes | Frame p99 | 25.78 ms | 22.67 ms |
| 480 strokes | Mesh stage total per window | 1,262.8 ms | 64.6 ms |
| 480 strokes | Final sampled draw calls | 1,478 | 1,501 |
| 480 strokes | Final sampled primitives | 172,331 | 131,216 |

These averaged p95/p99 values are averages of two separate window percentiles, not a pooled
percentile. Mesh-stage totals include CPU assembly and synchronous mesh creation/submission;
they do not isolate asynchronous GPU execution. The two regional late-window p99 values were
22.98 and 22.36 ms. The two baseline values were 25.69 and 25.86 ms.

Regional culling reduces drawn primitives, while separate regions add 23 draw calls in this
view. Both runs returned to 6 nodes, 0 orphans and 110 reported resources after each teardown.
Tracked static memory settled at 83.1 MiB before and 83.6 MiB afterward; within the regional run,
the warmed cleanup baseline remained stable. The live larger network added 56 nodes and about
0.8 MiB of tracked static memory relative to the baseline, rather than retaining one new set
per dig. This is a deliberate tradeoff for bounded mesh update work.

These measurements stress terrain updates, with one operation per frame. They are not a full
multiplayer FPS benchmark: gameplay and HUD callbacks are frozen. Desktop frame pacing also
varies between runs, so average frame interval is not used as the headline improvement.
Results support keeping the change on this hardware; lower-end GPU/release-build testing is
still needed. Two cycles are regression evidence, not an hour-long endurance guarantee.

Raw measurements: [before](performance-regions-before.txt), [after](performance-regions-after.txt).

## Validation

`tools/region_mesh_audit.gd` checks the emitted vertices and engine-packed normals against the
entire contour cache after initial digging, partial carving, collapse, re-digging, rock removal,
and client-style segment forgetting. Its deterministic fixture exercises all four materials.
It also checks material assignments, depth offsets, shadow flags, distant mesh identity after
a local dig, unchanged meshes after fog updates, focus on every plane and empty-region cleanup.

The 17 regional checks, all 15 tunnel scenarios plus subsystem checks, 64 field-equivalence
comparisons, 5 fog-equivalence comparisons, 33 match checks and 8 lifetime checks pass.
Repeated rendered lifecycles pass their
light-reuse and cleanup assertions. Before/after screenshots were inspected: corridor geometry,
rock faces and lighting remain consistent, with no visible region seams in the sampled view.

```sh
godot --headless --log-file /tmp/mouse-regions-audit.log --path . --script tools/region_mesh_audit.gd
godot --log-file /tmp/mouse-regions-growth.log --path . --script tools/long_session_probe.gd -- 2 480
```

## What remains

The largest window's contour stage still costs approximately 1.37 seconds across 320 attempted
operations, versus 0.065 seconds for regional mesh assembly. Lighting costs another 0.27 seconds.
The next investigation should split committed-field composition, rock subtraction, earth
thinning, island filtering and contour extraction to isolate the remaining expensive commit
frames. Persistent unfinished-carve history still deserves its own stress scenario. This change
does not claim that all digging is constant-time or that every frame now fits the 60 FPS budget.

Follow-up: [contour pipeline profiling, indexing, reuse and packet batching](06-contour-pipeline.md)
implements and measures that investigation. The figures above describe the earlier regional-mesh change.
