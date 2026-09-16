# Stabilization checks — September 15, 2026

The multiplayer bug fixes cover queued input edges, invalid input vectors, remote grass
concealment, DustScreen replication, and the local client's stamina display.

Snapshots now carry authoritative speed and boost state. Stamina is sent only to its owning
seat; other seats receive a neutral value. Dust uses periodic complete pictures filtered by
underground knowledge, with stable cloud IDs and age. The casting client reuses its immediate
prediction when the server picture arrives. All peers must use the updated build because the
snapshot wire format changed.

`tools/remote_state_audit.gd` passes 26 checks covering serialization, consumers, actual send
and receive handlers, server identity checks, prediction reconciliation, stale pictures, and
hidden underground clouds. Deliberately removing speed, stamina, dust sending, or the dust
knowledge filter made the corresponding regression check fail; all fixes were restored.

Additional passing coverage: input audit, 33 match checks, 41 Sneak checks, 15 tunnel scenarios
plus tunnel subsystem checks, contour geometry, fog repaint equivalence, network loading,
and the real two-process replication audit. The two-process run measured approximately
2.2 KB/s upstream and 8.2 KB/s downstream for the client.

Run the new regression audit from the repository root:

```sh
godot --headless --path . --script tools/remote_state_audit.gd
```

Performance changes merge fully interior floor cells into horizontal strips, avoid rebuilding
physical geometry for fog-only repainting, and stagger bot thinking. A controlled 238-segment
dig probe reduced the final measured commit from 15.56 to 13.41 ms and carve from 4.79 to
3.94 ms; these are individual local measurements, not a general frame-rate guarantee.

The previous probe mislabeled Godot's rolling physics maxima as average physics time.
`match_cost_probe.gd` now labels these as peaks and separately measures the distribution of
node physics callbacks. That separate timer excludes native physics/navigation work.

A headless fixed-60-FPS run completed 480 simulated seconds (28,801 measured ticks) without
script errors. Its largest measured callback tick was 28.53 ms, so frame spikes remain.
Later windows include settled/end-of-match activity and do not establish the cost of a
continuously growing tunnel network. Next performance work should measure a rendered,
actively digging late-match scenario and isolate the remaining spikes.
