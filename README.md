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

## Current state: M4 — digging in the game (in progress)

**There is a match.** Two crews of three, two banners, melee, scruffing, respawns, a clock,
and bots that play the objective rather than each other. M3 answered its question — *is the
flag run tense?* Yes, and it's the **chase** that does it.

**And now they follow you down.** Bots path through tunnels: an `AStar3D` graph over the dug
cells, joined to the surface navmesh at the shaft mouths, so a defender meets an intruder three
planes down instead of standing on the lawn above them. That was M4's centre of gravity — until
it held, a tunnel wasn't a route anyone contested, it was somewhere the AI could not go.

**And there are classes.** Four of them, as `Resource` files you can edit in the inspector —
walk into your own nest and press **C** to cycle. The spread is real: a Sneak is fast, fragile
and quick through a tunnel; a Brute is a wall that barely moves down there. **Everyone can
dig, and the Engineer is about three times faster at it** — a deliberate revision of GDD §4's
"nobody else alters terrain", because exclusivity turns one seat into a requirement and locks a
crew out of three planes the moment its Engineer goes down.

**And the Engineer can bring a tunnel down.** `Q`, on the cell you're pointing at, one at a
time, at arm's length — sealing a corridor behind you as you go. It's aimed rather than
automatic on purpose: the cursor is the steering wheel, so looking at what you're sealing means
not running for a moment. Anyone standing in the cell is scruffed. Shaft cells are refused —
either end of a ladder would be left starting in solid earth.

Still to come in M4: the Engineer's *Barricade*, a dig-controls pass, and per-plane rock
obstructions.

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
- **Crew roster, bottom right** — a portrait, a name, a class tag, and health in **segments**
  rather than as a sliding bar, because the question on a roster is "how many more hits", which
  is a number. Chunks are the crew's colour while everyone is fine and degrade through amber to
  red. Your own row is flagged gold; a scruffed one shows its respawn clock; a carrier flies a
  little flag in the crew colour of whatever they're holding.
- **Event feed, bottom centre-left**, next to the map, stacking upward so the newest line is
  always at the same height.
- **All of it scales with the window.** Every size is written against 1280×720 and multiplied by
  `HudSkin.scale_for` on the way to the screen, so the HUD is the same fraction of the display at
  any size — scaled by the *smaller* of the two ratios, or a short wide window grows the panels
  until they collide across the middle. Not Godot's `canvas_items` stretch mode, which would do
  this for free and would also drop the 3D render to the base resolution and scale it back up,
  quietly undoing the pixel pass the whole look is built on.

**The roster portraits are placeholders**, one per class — the headgear does the telling apart,
not the face. All the drawing is in `roster.gd:_portrait`, so real art is a texture lookup in one
function and nothing else in the file changes. Per-mouse customisation, if it happens, wants the
same seam (M10 idea).

**Enemies appear on the map only once your crew has seen them** — same range, same line of
sight, and the same concealment number the grass fades you with, so sneaking past a defender
keeps you off the map for exactly the reason it keeps you off the screen. A contact is held
for 15s after they break away, **frozen where they were last seen** and fading, so an old
marker reads as the guess it is. Carriers are always visible (§2). See
[`scripts/game/spotting.gd`](scripts/game/spotting.gd).

One thing on screen is ahead of its system, deliberately and honestly: **cheese** is a real
ledger (20 per crew, −1 per respawn) but nothing yet depends on running out — caches, spending
and the zero-cheese respawn are M6, and they have to land together or empty is a death spiral.

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
| **C** | Change class — **only while standing in your own nest**, selector slides up |
| **Q** | **Cave-in** (Engineer) — bring down the tunnel cell you are pointing at |
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

**Classes live in [`resources/classes/`](resources/classes)** — four `.tres` files, one per
class. `dig_speed` (Engineer 1.0, everyone else 0.35), `tunnel_speed` (Sneak 1.25, Brute 0.35
— and it applies *only* below the surface), `carry_penalty`, health, speed, turn rate, sprint
duration. Editing one and pressing play is the whole tuning loop; nothing is in code.

On **Player** (and every mouse, via the shared base): `acceleration` (30), `attack_reach`,
`attack_knockback`. Note `speed`, `max_health`, `turn_speed`, `attack_damage` and
`carry_penalty` are **overwritten from the class resource** on ready — set them there, not here.

On a **Bot**: `role` (raider or defender), `defend_radius` (9 — measured from the *nest*, so a
defender can't be lured off its post), `engage_radius` (4.5 — who it squares up to, never where
it goes; conflating those two produced bots that brawled in the midfield and never scored),
`tunnel_bias` (1.0 — how much a tunnel has to beat the surface by before a bot bothers; only
applies when *both* ends are above ground, since following someone down is not a preference).

On **CameraRig**: `pitch_degrees` (48), `zoom_idle` / `zoom_run` / `zoom_sprint`, `follow_speed`.

### Audits

Two headless invariant suites. Both must pass; both exit non-zero if they don't.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/tunnel_audit.gd
```

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/match_audit.gd
```

The first builds fifteen awkward tunnel networks and asserts you cannot fall out of any of
them, then checks the **routing graph agrees with the geometry** — no route through undug earth,
no diagonal shortcut through a corner you can't fit round, no crossing between planes without a
shaft, and no imaginary line drawn across the lawn — then brings a cell down and checks the
network, the graph and the physics all noticed.

The second plays out the flag rules — steal, capture, drop, return, respawn, the flag
underground, who a swing may hit — checks the bots can path between the nests at all, checks a
**defender actually goes down a shaft after an intruder**, checks the class spread reaches the
mouse and the swap point has a place and a price, checks **only the Engineer can cave a tunnel
in** (and on whom, and how often), and checks **who may appear on the
minimap**: not through a prop, not through a plane, not without being seen, and forgotten on
time.

> **The tunnel audit spent its whole life passing without testing anything, and that is worth
> knowing about.** `const STRIP: Array[String] = [...] + STRIP_MATCH` produces an *untyped*
> array in GDScript; passing it to a parameter declared `Array[String]` aborts the call at
> runtime, so `_arena` returned null, every check quietly did nothing to a null network, and all
> fourteen scenarios printed `ok`. Fixed on both counts — the type, and a harness that now
> reports `BROKEN` and fails the run when it cannot build its own subject. The geometry itself
> turned out to be fine, which is luck rather than vindication.

## Layout

```
docs/           design documents
art/            Blender source files and shaders, imported directly by Godot
scenes/         player, bots, maps
scripts/actors/ the mouse itself — locomotion, health, melee, carrying
scripts/game/   teams, nests, banners, the match rules, who can see whom
scripts/ai/     bots
scripts/ui/     score bug, minimap, roster, feed, and the skin they share
scripts/tunnels/the network, the routing graph, shaft transit, digging
scripts/        player, camera, maps, input setup
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

## Next: the rest of M4

Is digging *fun*, not just legible? Bots can follow you now, which was the precondition for
asking. What's left is the Engineer class (dig, ramp, barricade), a dig-controls pass, and
per-plane rock obstructions. See the implementation plan.

**One finding already, and it isn't a routing problem.** Bots never choose a tunnel when both
ends are above ground — because on this arena none is ever shorter. The yard is eighty metres of
open dirt, so no underground route can beat the straight line over the top of it, and the
planner correctly says so. Tunnels start winning that comparison the moment the map has
something in the way — which is exactly what M3 said about the midfield: **it's a map problem**
(GDD §8), and it belongs to whichever milestone first lays out a real Backyard BBQ. The
machinery is held under audit in the meantime, with the comparison forced by `tunnel_bias`.
