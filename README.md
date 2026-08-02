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

## Current state: M5 — hidden information (in progress)

**There is a match.** Two crews of three, two banners, melee, scruffing, respawns, a clock,
and bots that play the objective rather than each other. M3 answered its question — *is the
flag run tense?* Yes, and it's the **chase** that does it.

**And now they follow you down.** Bots path through tunnels: an `AStar3D` graph over the dug
cells, joined to the surface navmesh at the shaft mouths, so a defender meets an intruder three
planes down instead of standing on the lawn above them. That was M4's centre of gravity — until
it held, a tunnel wasn't a route anyone contested, it was somewhere the AI could not go.

**And there are classes.** Four of them, as `Resource` files you can edit in the inspector —
walk into your own nest and press **C** to cycle. The spread is real: a Sneak is fast, fragile and
whips around; a Brute is a wall that commits to a heading. **Nobody is slowed underground** — the
Brute's 0.35 tunnel speed was reverted, because a class that crosses its own tunnel slower than
everyone else crosses the lawn above it isn't a cork, it's a class locked out of the map. **Everyone can
dig, and the Engineer is about three times faster at it** — a deliberate revision of GDD §4's
"nobody else alters terrain", because exclusivity turns one seat into a requirement and locks a
crew out of three planes the moment its Engineer goes down.

**And the Engineer can bring a tunnel down.** `Q`, on the cell you're pointing at, one at a
time, at arm's length — sealing a corridor behind you as you go. It's aimed rather than
automatic on purpose: the cursor is the steering wheel, so looking at what you're sealing means
not running for a moment. Anyone standing in the cell is scruffed. Shaft cells are refused —
either end of a ladder would be left starting in solid earth.

**And the earth has rock in it.** Seeded seams on every plane, with a **different layout on each**
— getting past one may mean going down a layer, round, and back up, which is what turns digging
into a three-dimensional routing problem instead of a flat maze drawn three times. A seam is
invisible until you dig up against it and the corridor ends in grey stone: you learn where the
rock is by paying for the knowledge. The dig cursor goes grey and stops pulsing over one, because
otherwise "this is rock" looks exactly like "out of reach".

**And the Engineer can put a rock in your way.** `X`, on the open cell beside you: a boulder that
blocks the corridor physically *and* leaves the routing graph, so bots plan around it rather than
grinding against it. **Only a Brute can shift one** — three swings, and the third breaks it into
pieces of itself that scatter, settle and fade — which finally gives the Brute a reason to be
underground that isn't fighting. **The corridor reopens on the swing that breaks it**, not when
the last piece stops rolling. It costs no cheese; the limits are **ten seconds
between placements and three standing at once**, and a cleared barricade gives the slot back.

**And the ground looks like ground.** Every earth surface — the lawn, the trench floors, the walls,
the lids — carries the same world-mapped dirt grain, so they read as one material rather than as
four coloured cards. The rocks and grass on the lawn now **disappear the moment you are under
them**: they sit a metre above the floor you are reading and land on it from this angle, so a
corridor was filling up with scenery that looked like it was in the tunnel and wasn't.

**And the rock you've found stays found.** Dig into a seam — or just open the cell beside it and
expose its stone face — and your crew learns the **whole connected vein**, drawn from then on as a
cool grey sheet on the ground above your corridor and marked on the minimap for the plane you're
standing on. **Your crew only**: the other side still
has to pay for its own copy of the map. The cell you spent is the price; the shape of the vein is
what you bought. This is the first knowledge in the game one crew has and the other doesn't, which
is M5's whole job — doing it first on rock, which never moves, is deliberate.

**And there are boulders on the lawn.** Seeded lumps snapped to the dig grid, one to four cells
each: they block movement up top and shut the earth directly under them on **plane 1 only**, so the
way past one is to go under it. Both crews know what a boulder is sitting on from the first second
— it's standing there in daylight — which makes it the exact counterweight to the seams, where the
knowledge has to be bought. **A Brute breaks them, five swings per cell**, so a four-cell rock is
twenty swings and comes apart **a quarter at a time**: you decide whether you want a gap to dig
through or the whole thing gone. Bots re-path as soon as one falls.

**And some ground you can tunnel under but not come up through.** The patio slab, the concrete
path (GDD §3): a no-surface zone refuses a shaft that would touch the lawn and refuses nothing
else, so a corridor runs the whole length of the paving and you simply cannot surface until you
are clear of it. That makes a slab a **long committed crossing** — the enemy under it has to come
up somewhere, and you know where the somewheres are. Refused in different words from the top and
from underneath, and while you're under one the prompt above your head says so, because finding
out you're committed at the moment you wanted out is finding out too late. The arena has a
placeholder patio in it; the zone is a rectangle and a rule, so real paving parents underneath it
later and nothing about the rule changes. **Nothing grows through paving either** — grass asks the
same zones, with half a blade's width of margin so a root just off the edge doesn't put half its
base on the concrete.

**And your map is yours now.** A crew sees the cells and shaft mouths it cut; the enemy route is
absent, even where the two networks meet. The intersection is real floor in the world, but it does
not donate the connected enemy floor plan. This is the first half of M5's visibility boundary.

**And the Sneak can sound out what lies below.** Press **Q** to pulse through exactly one layer.
Nearby tunnel cells shimmer briefly on the ground above, then resolve to one persistent piece of
thieves' cant in the world and on your crew's minimap. An enemy Generalist cannot read it; an enemy
Sneak can, and can rub it out with **Q** from arm's reach. A mark gives away a place, never the route.

**And an enemy corridor is a dark hole you brought no lamp into.** Lamps are crew property now:
your own network is warm and readable far ahead, and theirs simply has no light in it. Nothing is
occluded or faded — the earth is exactly where it was, there is just nothing lighting it. Daylight
falling down a shaft is deliberately exempt, because a beam is the sun rather than a lamp: an enemy
mouth still announces itself from the dark, which is the one thing an intruder gets for free and
the way back out of a corridor you can't read.

**And what you see in there goes onto your map, then goes stale.** A cell of an enemy network one
of your crew can actually see is added to your map and starts ageing the moment nobody can see it —
the same fifteen seconds and the same fade curve `spotting.gd` already uses for mice, because the
staleness rule should be learned once. Line of sight is the grid itself: a cell is visible when
every cell between here and there is open, so a corridor bending away stops at the bend. A breach
tells you where you are, never where the route goes. Enemy shaft mouths work the same way from the
lawn — walk past one and it's on your map, thinning out.

**The same rule cuts the ground itself.** The lid you look down into a trench through is punched by
a mask, and that mask is now crew knowledge rather than a picture of the earth — your cells, plus
whatever you can currently make out. Enemy ground reads as solid earth until somebody looks at it,
and closes over again when the sighting is forgotten: **the fog is the ground healing.** Built from
every dug cell instead, it drew the enemy's entire floor plan into the world in front of you before
you had been near it, which made the carefully filtered minimap beside it decorative.

**Crews are five, and the bots use all four classes.** Every seat has a role and a class it wants
(`MatchDirector.SEATS`), and a bot *acquires* that class by standing in its own nest, through the
same rule the player's **C** key obeys — so almost every swap happens on respawn, which is exactly
where GDD §4 says a free switch belongs.

**Engineer bots dig, and they build one network rather than a field of pits.** An Engineer walks to
its crew's existing mouth if there is one and only cuts a fresh entrance when there isn't; underground
it walks to the head of its own corridor **using the route planner** and cuts only when it is
standing at solid earth. When a seam blocks all three ways forward it sinks a shaft and carries on
underneath — which is what the per-plane rock layouts were always for, and the first thing in the
game to do it on purpose. Each tile costs the same half-second a player pays.

That is what makes M5 testable at all: before it, no enemy had ever dug anything for you to be
frightened of.

The Backyard BBQ layout and the dig-controls pass are deliberately deferred. That leaves M4's
surface-versus-tunnel *verdict* unanswered, but its core systems are stable; level design can test
that question after the core visibility and economy details exist.

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
- **Minimap, bottom left** — the yard, **your crew's tunnels** on the plane you occupy, sonar cant,
  the nests, both banners and your crew. Enemy routes stay hidden until somebody *sees* them, and
  then they show faintly and fade back out. **It turns with the view**, so up on the map is up the
  screen; at the fixed 45° yaw that draws the yard as the diamond the concept art has.
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

**Bots respect it too.** A defender picks its target through the same `reveal_opacity` the
minimap uses, so a mouse gone still in deep grass is not a destination — the grass either hides
you from both crews or it is scenery. Carriers are pinned at full opacity, so the rule that sends
a bot after its stolen banner needs no exception. `tools/grass_hiding_probe.gd` parks an enemy in
cover inside a defender's patch and asks the bot's own target picker, then repeats it on bare
ground so a gate that is simply always on fails.

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
| **Q** | **Cave-in** (Engineer) — bring down the tunnel cell you are pointing at. The cell is boxed while you aim, warm when it will fire and cold while it cools. |
| **X** | **Barricade** (Engineer) — wedge a boulder into the open cell you are pointing at |
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

On **Tunnels**: `rock_density` (0.09 — the fraction of plane 1 that is rock), `rock_density_deeper`
(+0.035 per plane below it), `rock_seam_cells` (3–11 per seam), `rock_nest_clearance` (6m of soft
ground around every nest), `rock_seed`. Setting `rock_density` to 0 turns obstructions off
entirely, which is what both audits do to every check that isn't about them.

On **Barricade**: `cooldown` (10s), `max_standing` (3), `reach_cells` (1.6). On a placed boulder:
`hits_to_clear` (3 Brute swings), `fill`, `height_fraction`.

On **Surface/Grass**: `blade_width` (0.12m at the base), `blade_height` (0.44–0.68m), and
`sample_spacing` (0.15m at maximum density). Grass is painted continuously across the yard:
`field_noise_frequency` controls broad growing regions and `detail_noise_frequency` breaks their
edges up. `coverage_threshold` (0.49) is the outline — where grass starts — and the taper in from
it is measured in **metres**, not in noise: `edge_feather` (0.6m) for the blades and `cover_feather`
(1.4m) for concealment, deliberately wider so the edge of a patch is partial cover you can feel
yourself entering rather than a line you cross in a seventh of a second. Feathering by a second
noise threshold instead spans whatever distance the local slope happens to give — 2.4m to 11m on
this map — which left shapes with no dense interior; `tools/grass_probe.gd` prints both curves.
`render_chunk_size` (6m) affects culling only and never defines a visible or gameplay footprint;
`cast_shadows` is off, which is the cheapest large saving here and the one to flip first if the
lawn looks flat. The shared grass shader's `tip_taper` is 0.7, leaving the tip at 30% of the base
width.

On **Surface/Boulders**: `count` (14), `spans` (the footprints on offer and their weighting — a
repeated entry is a heavier weight), `hits_per_section` (5 Brute swings per cell), `height`
(0.75–1.15m), `spacing_cells` (3 clear cells between boulders), `boulder_seed`. On **Tunnels**,
`rock_top_color` is the pale stone cap drawn across the top of every found, undiggable cube; on
the **minimap**, `rock_color` is the same information on the panel and `mouth_color` is a shaft
entrance seen from the lawn. Unknown seams still receive no cap, so the brighter top does not leak
their position.

**The minimap draws one layer — the one you're standing on**, tunnels and rock alike, the same rule
the world follows. Stacked, four planes aren't a map of anything: two corridors a plane apart cross
on the panel without touching in the world. On the surface it shows grass, substantial rocks,
every remaining boulder section, paving, props, and the **shaft mouths**. Below ground, the focused
layer takes over; plane 1 still shows a boulder's cells as known rock.

**Whenever a new surface object is added, put it in the `surface_clutter` group.** Ordinary 3D
geometry then gets an automatic minimap footprint and disappears from the tunnel view. A generator
should implement `minimap_shapes()` so it can collapse its children into useful circles or polygons
instead of dumping decorative detail onto the panel.

On **Surface/Patio** (a `NoSurfaceZone`): `extents` — half-width and half-depth in metres, so the
placeholder's 10 × 5 is a 20 × 10 slab. Move it, resize it, rotate it, or add a second node for a
path; the rule follows the rectangle. `show_paving` turns off the grey box for a map whose paving
is real geometry parented underneath.

On **Spotting**: `sight_range` (14), `memory_seconds` (15 — how long a contact outlives the
sighting), `reveal_opacity` (0.35 — how visible you must be to register at all), `interval`
(0.25, which doubles as reaction time).

**Classes live in [`resources/classes/`](resources/classes)** — four `.tres` files, one per
class. `dig_speed` (Engineer 1.0, everyone else 0.35), `carry_penalty`, health, speed, turn rate,
sprint duration. `tunnel_speed` is **1.0 for everybody** — nobody is slowed underground, and the
multiplier is floored at 1.0 in code so a resource edit can't reintroduce a penalty; see GDD §3
for why the Brute's 0.35 had to go. Editing one and pressing play is the whole tuning loop; nothing is in code.

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
network, the graph and the physics all noticed. Its last check is the only one that runs against a
**generated** layout rather than a hand-built one: that rock exists, that it is laid differently on
every plane, that no nest is walled in, that a seam refuses a dig *out loud* and refuses a shaft
sunk onto it, and that nothing routes through one. It then checks what a crew *knows* about that
rock: that nobody knows anything until somebody digs into a seam, that doing so reveals the whole
connected vein and draws it, and — the assertion the feature exists for — that **the other crew
still knows nothing**, checked through the real dig controls as well as through the rule. Then it
lays a patio of its own and asserts the
other kind of obstruction from both sides at once: no entrance through the paving from above, none
broken out from below, a corridor that runs the whole way under it regardless, a shaft to the plane
*below* that still works, and a mouth one clear metre past the edge that still works — because a
seal that refuses everything and a seal that refuses nothing each pass half these lines.

The second plays out the flag rules — steal, capture, drop, return, respawn, the flag
underground, who a swing may hit — checks the bots can path between the nests at all, checks a
**defender actually goes down a shaft after an intruder**, checks the class spread reaches the
mouse and the swap point has a place and a price, checks **only the Engineer can cave a tunnel
in** (and on whom, and how often), checks a **barricade blocks the routing graph and only a Brute
shifts it** (and the supply, and the cooldown, and that the cell comes back afterwards), checks a
**Sneak sounds exactly one layer down, leaves crew-readable cant, and a rival Sneak can erase it**,
checks tunnel cells and mouths never leak from one crew's map to the other's, checks that
**standing in an enemy corridor reveals what you can see and not the leg round the corner** — and
that what you saw goes stale and is forgotten on time, and never becomes a cell you own, **and that
the ground itself stays shut over a corridor you have never seen**, asked of the real cutaway mask
rather than of the rule that fills it — checks
**bots swap into their seats and an Engineer bot opens earth on its own**, into its own crew's map
rather than into both — and that what it opens is a **corridor rather than a scatter of stubs**,
measured as cells per mouth — checks a **boulder shuts the earth under it on plane 1 and not on plane 2**
and that five Brute swings free one cell of it and leave the rest of the rock standing, and checks
**who may appear on the minimap**: not through a prop, not through a plane, not without being seen,
and forgotten on time.

> **The sight check was built wrong first, in the way this project has now been bitten by twice.**
> The corner it asserts you cannot see round was 8.1 cells away with sight set to 7 — so it was
> testing the *radius*, and it passed happily with the line-of-sight test stubbed out to
> `return true`. The far leg is 6.7 cells out now: in range, and behind solid earth. Both halves of
> the check were then verified by breaking them — disabling the line test fails the corner
> assertion, and stopping the ageing fails the two staleness assertions.

### The behaviour soak

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/bot_soak.gd -- 90
```

**The audits ask whether the rules hold. This asks whether the bots are any good** — and the two
questions need different tools, because almost every way an AI can be bad is perfectly legal. An
Engineer that punches a three-tile pit, wanders off, respawns and punches another one breaks no
rule at all: every dig is valid, every cell is correctly attributed, and the audit's "an Engineer
bot opens earth on its own" passes comfortably. It was also, for a while, exactly what they did.

It runs a real match and prints a table every five seconds — cells per plane, **cells per mouth**,
and every bot's class, plane, distance travelled and current intent. It fails on the two things
that are unambiguous rather than merely worse than last time: a bot **frozen** in place for fifteen
seconds while trying to go somewhere (a scruffed mouse and a defender at its post are excused), and
a network that is all entrances and no tunnel.

> **Four bot bugs came out of the first two runs, three of them invisible from reading the code:**
> the digger read its own steering back as its destination and dug at a fourteenth speed; it started
> a fresh hole every time a raid was interrupted; a greedy stepper was doing the corridor
> navigation and oscillated at every bend; and the frontier it walked to could be the cell it was
> already standing in. The first soak measured 28 cells across **11** mouths. It now reaches ~108
> cells across **2**, on two planes, having gone under the midfield rock.
>
> The general shape: **correctness belongs in an audit; quality of behaviour needs numbers you
> look at.** The one assertion that would have caught the pits — cells per mouth — now exists in
> `match_audit.gd` too.

### Visual probes

These need a real renderer, so no `--headless`. Each writes PNGs to `/tmp` for you to eyeball.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . --resolution 1100x760 --script tools/cutaway_probe.gd
```

Photographs one piece of earth twice, changing only which crew is looking: each viewer stands in
its own corridor with the other crew's running three cells away. **Exactly one open trench per
shot, and it is lit.** Two trenches in either shot is the M5 leak — the one that shipped, where the
lid cutaway was built from every dug cell and drew the enemy's whole floor plan into the ground in
front of you while the minimap beside it kept the secret perfectly.

`match_audit.gd` asserts this against the mask texture, which is one step short of the truth: the
lid is discarded in a shader that samples that mask with its own idea of where a cell is, and
`earth_cutaway.gdshader` warns that if the two ever disagree "the holes land half a cell off the
tunnels they belong to". A mask that is perfectly correct and sampled half a cell out passes every
headless check in the project and still shows you their tunnel. Only a photograph closes that gap.

`sonar_probe.gd`, `rock_top_probe.gd` and `arena_probe.gd` work the same way for the sonar echo and
cant mark, revealed rock caps, and the arena at large.

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
scripts/game/   teams, nests, banners, the match rules, who can see whom and what
scripts/ai/     bots, and the Engineer's raid
scripts/ui/     score bug, minimap, roster, feed, and the skin they share
scripts/tunnels/the network, the routing graph, shaft transit, digging
scripts/        player, camera, maps, input setup
tools/          headless audits, a behaviour soak, and visual probes needing a real renderer
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

## Next: play M5 and give it a verdict

**M5's systems are all in.** Tunnel cells and mouths are per-crew map knowledge; the Sneak's sonar
turns a glimpse of the layer below into one contestable cant mark; lamps belong to the crew that
hung them, so an enemy corridor is unlit; and sight into an enemy network grants cells one line of
open floor at a time and forgets them on a clock. Crews of five with class-swapping bots and
digging Engineers mean the yard fills with corridors somebody else made, which is the condition the
milestone needed to be answerable at all.

**What's left is not code — it's the answer.** M5 asks whether crawling into an enemy tunnel is
*frightening*. Go and find out, in a full match, from inside one. If it isn't, the dials are
`lamp_*` on the network, `sight_cells` and `memory_seconds` on `TunnelSight`, and `enemy_seen_alpha`
on the minimap — but be willing to hear that the answer is a map problem rather than a tuning one,
which is what M3 and M4 both said about the midfield.

Then **M6 — cheese is lives**: caches, carrying, team stores, respawn cost, and the bankruptcy play.
The Backyard BBQ layout and the dig-controls pass still stand behind it.

The Backyard BBQ layout still matters, but it is no longer the sequencing gate. It and the
dig-controls pass return after the core systems, when the surface and tunnel routes can be laid
out and tuned once rather than repeatedly around unfinished information rules.
