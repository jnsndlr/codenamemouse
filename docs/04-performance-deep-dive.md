# Performance and lifetime review — September 15, 2026

The reviewed build has real late-network frame spikes. Repeated scene teardown was stable in
these runs, but that does not establish flat performance for a long, continuously growing match.
Four fixes were implemented in this review. The subsequent regional rendering change and
its measured results are documented in [Regional tunnel meshes](05-regional-tunnel-meshes.md).

## Fixes

- **Disconnected-peer history:** `NetMatch` now listens for transport departures and drops
  `_started` and `TunnelView._told` entries. Previously every new peer ID could leave its
  terrain-delivery dictionary behind until the arena was destroyed.
- **Bot contact history:** bots prune their own `_cleared` dictionary against current contacts.
  Previously, once Spotting removed a dead/expired contact, the bot's cleanup loop could never
  visit that key again. This matters when seats replace bots/players during a match.
- **Light churn:** tunnel lighting caches one layout per plane, including crew-filtered lamp
  positions, shaft positions, and appearance settings. Unchanged carving no longer frees and
  recreates every lamp and shaft beam. Changed layouts still use the original placement rules.
- **Mask uploads:** dirty chunks still update the CPU image immediately, but each rebuild batch
  uploads its completed 1024×1024 R8 texture once. Previously N chunks caused N full 1 MiB
  uploads. This is synchronous batching, with no added fog or collision latency. Single-chunk
  diagnostic calls retain their immediate upload behavior.

The two retention checks failed before their fixes and passed afterward. The light identity
check failed before caching and passed afterward. No before/after FPS improvement is claimed:
headless timing cannot price GPU transfers, and the baseline runs were not a controlled rendered
comparison of both versions.

## Measurements

Godot 4.7.1 debug build, Forward+, Metal 4.0, Apple M5 Pro, 1280×720, VSync disabled.
`tools/long_session_probe.gd -- 2 240` ran two complete arena lifecycles. Each forced 240 stroke
attempts / 1,920 carve-or-commit frames on plane 1; 238 strokes committed. Gameplay was frozen,
the camera faced the dug area, underground dimming was settled, and digging continued throughout
measurement. These are controlled terrain-growth results, **not a complete multiplayer FPS
benchmark**: bot thinking, moving HUD, effects, and network traffic must be measured separately.

The second rendered cycle:

| Stroke attempts | Operation mean | Operation p99 | Frame p99 | Frame maximum |
| --- | ---: | ---: | ---: | ---: |
| 40 | 3.19 ms | 8.15 ms | 9.05 ms | 9.65 ms |
| 80 | 4.89 ms | 11.28 ms | 12.31 ms | 12.75 ms |
| 160 | 6.44 ms | 14.54 ms | 15.51 ms | 16.46 ms |
| 240 | 6.90 ms | 18.32 ms | 19.25 ms | 19.76 ms |

Each row covers the preceding 40 strokes, with seven growing carve steps and one commit per
stroke. Terrain differs between rows, so this is a growth stress test, not proof that every
increase is caused solely by segment count. The first cycle's final frame p99 was 19.04 ms.
Both late windows exceed the 16.67 ms total frame budget for 60 FPS on this machine, before
adding active gameplay. Average FPS alone would hide this.

Both rendered teardowns returned to **6 nodes, 0 orphan nodes, 110 resources, 83.1 MiB of tracked
static memory**. At identical growth stages, counts and memory matched between cycles. A prior
three-cycle headless run with light caching also returned to 6 nodes / 0 orphans / 110 resources,
with tracked static memory around 58.6 MiB. This is evidence against scene-owned accumulation
in these scenarios, not a driver-memory, particle-lifetime, or hour-long endurance guarantee.
Headless frame intervals include engine pacing and must not be read as GPU performance.

## Remaining priorities

1. **Whole-plane mesh assembly/upload — addressed September 16.** See
   [regional rendering results](05-regional-tunnel-meshes.md). The original finding was: `_rebuild_walls` contours only dirty
   chunks, but still concatenates every cached chunk and recreates four plane-wide meshes on
   each carve. Work and allocation therefore grow with explored terrain. Profile assembly,
   field rules, mesh upload, and collision separately before choosing chunk instances or larger
   regional mesh batches. Preserve focus, material assignment, fog, and stable collision shapes;
   measure the draw-call/culling tradeoff in a rendered build. The timing above establishes a
   problem; it does not establish that mesh assembly is the sole bottleneck.
2. **Index unfinished carves spatially.** `_rebuild_chunk` scans every entry in `_carving[plane]`
   to reject distant strokes. Partial cuts intentionally persist, so repeated starts/stops can
   make this history large even without many committed tunnels. Preserve persistent geometry;
   do not “fix” it by expiring excavated ground. Add a many-abandoned-strokes scenario first.
3. **Keep multiplayer terrain work proportional to changes.** `TunnelView.batch` rebuilds wanted
   state over known terrain for each peer at 2 Hz. Packets are capped at 96 entries, but CPU work
   is not capped by that packet limit. Measure four clients on a mature network, including a
   late join, before considering per-team dirty sets or revision-based caches.
4. **Profile navigation rebakes after boulder destruction.** `rebake()` requests background
   baking but scene parsing can still require GPU mesh readback; startup-only measurements do
   not cover it. Coalesce requests and investigate collision/procedural source geometry if
   measured spikes justify changing the authored CSG ground path.
5. **Broaden the endurance matrix.** Run 30–60 minutes with active bots and repeated effects,
   partial digging, collapse/re-dig, depth changes, class swaps, peer reconnects, and match
   restarts. Track frame p95/p99/max, native physics peaks, objects/resources/orphans, process
   resident memory, GPU memory, and bytes per peer. Expected world-state growth must be
   distinguished from history that should have expired. Repeat on the lowest supported GPU
   and in an exported release build.

Existing useful practices include chunk-local collision updates, bounded dig-dust puff counts,
shared effect textures, explicit rendering-device RID cleanup, fog-only geometry reuse,
phase-staggered bot decisions, and bounded terrain packet payloads. Keep those properties
covered while optimizing the remaining expensive paths. Pool effects only if measurements
show allocation spikes; pooling everything would obscure lifetime ownership without proving a win.

## Regression tools

Run from the repository root (substitute the Godot executable path locally):

```sh
godot --headless --log-file /tmp/mouse-lifetime.log --path . --script tools/lifetime_audit.gd
godot --headless --log-file /tmp/mouse-long.log --path . --script tools/long_session_probe.gd -- 3 240
godot --log-file /tmp/mouse-rendered.log --path . --script tools/long_session_probe.gd -- 3 240
```

The lifetime audit checks peer cleanup through the transport signal, dead contact cleanup,
unchanged lighting identity, crew-view equivalence to fresh lighting, and appearance invalidation.
With a renderer it also compares the uploaded mask against the CPU image. The growth probe
fails on unchanged-layout light replacement or post-warmup node/orphan/resource accumulation;
timings and memory are reported, not enforced as machine-independent thresholds. Rendered runs
save `/tmp/mouse-long-session-<cycle>.png` for checking the camera/view. Run timing probes alone.

Passing validation: 9 rendered lifetime checks (8 headless), 33 match checks, all 15 tunnel
scenarios plus subsystem checks, 64 cached-field comparisons, and 5 fog repaint comparisons.
The short rendered screenshot pass also completed two clean lifecycles; the frozen HUD retains
its initial surface labels, while the network and camera render plane 1. Numeric output from the measured rendered run is preserved in
`docs/performance-rendered-growth.txt`.

The measurement-first approach and CPU/GPU separation follow Godot's
[general optimization guidance](https://github.com/godotengine/godot-docs/blob/master/tutorials/performance/general_optimization.rst)
and [GPU optimization documentation](https://docs.godotengine.org/en/stable/tutorials/performance/gpu_optimization.html).
