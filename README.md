# Codename: Mouse

Top-down isometric, class-based capture the flag at mouse scale.

Two crews of mice fight over cheese in a backyard, digging tunnels beneath it, while
something much larger wanders through.

## Design docs

Read these in order — they're the source of truth for what we're building and why.

| Doc | What it settles |
|---|---|
| [`docs/00-intent.md`](docs/00-intent.md) | The **why** — pillars, tone, influences, what this is not |
| [`docs/01-gdd.md`](docs/01-gdd.md) | The **what** — digging, cheese-as-lives, classes, the world |
| [`docs/02-implementation-plan.md`](docs/02-implementation-plan.md) | The **how** — tech, architecture, milestones M0–M9 |

## Current state: M1 — a mouse that moves

A capsule you can drive around a grey-box yard under a fixed isometric camera.
That's it, and that's the point — M1 exists to answer one question: *does isometric
movement feel good?*

### Running it

Open the project in Godot 4.7+ and press F5, or:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

### Controls

| Input | Action |
|---|---|
| **WASD** | Move (camera-relative — W is always up-screen) |
| **Shift** | Sprint |
| **Mouse** | Aim. The snout follows your cursor. |

The camera pulls back as you move faster — tight when still, wider at a run, widest at
a sprint. It's driven by your *actual* speed rather than by the sprint key, so later on
carrying the flag or wading through a flooded tunnel will tighten the view automatically
without a special case.

### What to fiddle with

Select **CameraRig** in the scene tree and tune these live while the game runs:

- **`pitch_degrees`** (default 40) — true isometric is 35.264, but most games that call
  themselves isometric are steeper because it reads better. The single biggest lever on
  how the game feels to look at.
- **`zoom_idle` / `zoom_run` / `zoom_sprint`** (7.5 / 9 / 10.75) — the three anchors
- **`zoom_out_speed` / `zoom_in_speed`** (3.5 / 1.8) — deliberately asymmetric so
  tapping movement keys doesn't pump the view in and out
- **`aim_lead`** (0.22) — how far the camera leads toward your cursor
- **`follow_speed`** (8) — how tightly the camera tracks

On **Player**: `speed`, `sprint_speed`, `acceleration`, `friction`.

## Layout

```
docs/           design documents
scenes/         player, maps
scripts/        player, camera, maps, input setup
```

Input actions are registered at runtime in [`scripts/input_setup.gd`](scripts/input_setup.gd)
rather than in `project.godot`, because that file serializes input bindings as one
unreadable line. Move them into Project Settings > Input Map when you want in-editor
rebinding.

## Next: M2 — the dig spike

Four planes, chunk-based tunnels, surface ghosting. No game around it — it exists purely
to answer whether a player can look at a tunnel network from above and understand its
shape. See the implementation plan.
