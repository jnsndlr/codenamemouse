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

## Current state: M3 — the core loop

**There is a match.** Two crews of three, two banners, melee, scruffing, respawns, a clock,
and bots that play the objective rather than each other. Digging is still there and still
works; the banner simply cannot go underground.

M3 exists to answer one question: *is the flag run tense?* Short answer: yes, and it's the
**chase** that does it — getting scruffed two strides from your own nest with the banner over
your head. See the findings in the implementation plan.

### The rules

- Steal **their** banner, carry it home, score. First to **3**, or most captures at **8:00**.
- **Your own banner must be home** for a capture to count — so a double steal is a standoff.
- A dropped banner returns itself after **20s**, or instantly if its own crew touches it.
- **Scruffed, not killed** — you drop what you're carrying where you fall, and you're back at
  your nest in 6 seconds. (It'll cost the team a cheese once the economy lands at M6.)
- **The flag cannot enter a tunnel.** Tunnels move mice, never objectives.
- **Carriers can't hide.** The banner floats above your head and grass concealment switches off.

### The HUD

GDD §10's furniture, built now that there are systems behind it.

- **Score bug, top centre** — both scores, the clock, both banners and **both crews' cheese**,
  as one object. Cheese is lives, so "how are we doing" is one question about all of them.
  A banner glyph per crew: solid is home, pulsing is stolen, dim is dropped. A strip appears
  under the bug with the return countdown, and only while something is actually away.
- **Minimap, bottom left** — the yard, the tunnels on every plane, the nests, both banners
  and your crew. **It turns with the view**, so up on the map is up the screen; at the fixed
  45° yaw that draws the yard as the diamond the concept art has.
- **Crew roster, bottom right** — name, class, health, and whose banner they are carrying.
  Your own row is flagged gold; a scruffed one shows its respawn clock.
- **Event feed, bottom centre-left**, next to the map, stacking upward so the newest line is
  always at the same height.

**Enemies appear on the map only once your crew has seen them** — same range, same line of
sight, and the same concealment number the grass fades you with, so sneaking past a defender
keeps you off the map for exactly the reason it keeps you off the screen. A contact is held
for 15s after they break away, **frozen where they were last seen** and fading, so an old
marker reads as the guess it is. Carriers are always visible (§2). See
[`scripts/game/spotting.gd`](scripts/game/spotting.gd).

Two things on screen are ahead of their systems, deliberately, and both are honest:
**cheese** is a real ledger (20 per crew, −1 per respawn) but nothing yet depends on running
out — caches, spending and the zero-cheese respawn are M6, and they have to land together or
empty is a death spiral. **Class** is a name only; the stats and abilities are M4, and every
mouse today genuinely is a Generalist.

### Running it

Open the project in Godot 4.7+ and press F5, or:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

### Controls

| Input | Action |
|---|---|
| **Mouse** | **Steers.** The mouse turns to face the cursor at a capped rate. |
| **W / S / A / D** | Forward / backpedal / sidestep — all relative to *facing*, not the camera |
| **Double-tap W** | Sprint (personal stamina) |
| **Shift** | Slow — the quiet tier. Bends no grass. |
| **Left click** | Attack — a short cone in front of you |
| **Right click** | Dig: point at a tile next to your tunnel and hold |
| **E** | Take the shaft under or over you |
| **F / R** | Sink a shaft down / break one up |
| **Arrows** | Turn the view a quarter at a time |

**The cursor is the steering wheel, not a crosshair.** Movement is derived from facing, so the
two can never disagree; the turn-rate cap is where the weight comes from. Left click attacks
because that's what GDD §9 always said — digging is the Engineer's ability, so it lives on the
ability button.

The camera pulls back as you move faster, driven by your *actual* speed rather than by the
sprint key — so carrying the banner tightens the view without a special case. It **cuts** rather
than flies when you respawn.

### What to fiddle with

On **MatchDirector**: `crew_size` (3), `capture_limit` (3), `match_seconds` (480),
`respawn_seconds` (6), `pickup_radius`, `starting_cheese` (20). On a **Nest**: `radius` — how
generous a capture is. On a **Banner**: `return_seconds` (20).

On **Spotting**: `sight_range` (14), `memory_seconds` (15 — how long a contact outlives the
sighting), `reveal_opacity` (0.35 — how visible you must be to register at all), `interval`
(0.25, which doubles as reaction time).

On **Player** (and every mouse, via the shared base): `speed` (3), `acceleration` (30),
`turn_speed` (10 — the main weight dial), `carry_penalty` (0.25 — per-class at M4, and the whole
handoff play falls out of the spread), `attack_damage` / `attack_reach` / `attack_knockback`.

On a **Bot**: `role` (raider or defender), `defend_radius` (9 — measured from the *nest*, so a
defender can't be lured off its post), `engage_radius` (4.5 — who it squares up to, never where
it goes; conflating those two produced bots that brawled in the midfield and never scored).

On **CameraRig**: `pitch_degrees` (48), `zoom_idle` / `zoom_run` / `zoom_sprint`, `follow_speed`.

### Audits

Two headless invariant suites. Both must pass; both exit non-zero if they don't.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/tunnel_audit.gd
```

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/match_audit.gd
```

The first builds eighteen awkward tunnel networks and asserts you cannot fall out of any of
them. The second plays out the flag rules — steal, capture, drop, return, respawn, the flag
underground, who a swing may hit — checks the bots can path between the nests at all, and
checks **who may appear on the minimap**: not through a prop, not through a plane, not without
being seen, and forgotten on time.

## Layout

```
docs/           design documents
art/            Blender source files and shaders, imported directly by Godot
scenes/         player, bots, maps
scripts/actors/ the mouse itself — locomotion, health, melee, carrying
scripts/game/   teams, nests, banners, the match rules, who can see whom
scripts/ai/     bots
scripts/ui/     score bug, minimap, roster, feed, and the skin they share
scripts/        player, camera, tunnels, maps, input setup
tools/          headless audits
```

## Art pipeline

Godot imports `.blend` files **directly** — edit in Blender, hit save, and Godot
re-imports. There is no export step and no second copy of the model to drift out of sync.

This requires two settings, already configured on this machine:

- **Editor Settings → FileSystem → Import → Blender → Blender Path**
  = `/Applications/Blender.app/Contents/MacOS/Blender` (the binary inside the bundle —
  pointing at the `.app` itself fails, which is why macOS auto-detection doesn't work)
- **Project Settings → Filesystem → Import → Blender → Enabled**

Consequence: building this project requires Blender installed. Fine for solo work, worth
remembering if CI ever appears.

### Two gotchas, both already hit

**The whole .blend imports, not just what you'd export.** Cameras, lights, and any
scaffolding come through as real nodes. `mouse.blend` keeps preview scaffolding in a
`_preview` collection that's excluded from the view layer, and the import is set to
visible-only.

**That visible-only setting is per-asset and defaults to "All."** Any *new* `.blend` you
add will import everything until you select it in the FileSystem dock and set
**Import → Nodes → Visible** to `Visible Only`, then Reimport. Expect to do this once per
asset.

Input actions are registered at runtime in [`scripts/input_setup.gd`](scripts/input_setup.gd)
rather than in `project.godot`, because that file serializes input bindings as one
unreadable line. Move them into Project Settings > Input Map when you want in-editor
rebinding.

## Next: M4 — digging in the game

Is digging *fun*, not just legible? The centre of gravity is **bots pathing through tunnels**
(`AStar3D` over the same dug cells the player digs), because until a defender can follow you
down there, taking the tunnel isn't a decision — it's an exploit. Then the Engineer class,
per-plane rock obstructions, and a dig-controls pass. See the implementation plan.
