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

## Current state: M7 — real multiplayer (in progress)

**M6.5 is closed.** The `.app` runs on a 2020 MacBook Air and a 2026 MacBook Pro — the compute
pass, the resolution scaling and the ad-hoc signature all survive hardware that isn't the
development machine, and the five-year-old Air is the one that could have said no.

**The wire is up.** [`NetTransport`](scripts/net/net_transport.gd) is the interface the tech
decisions have promised since week one; [`ENetTransport`](scripts/net/enet_transport.gd) is the only
implementation, and nothing above it will ever name ENet — that's what keeps the browser question
open for M9 at the cost of one file. Godot's RPCs and `MultiplayerSynchronizer` are deliberately
unused: **every client is owed a different payload**, because a crew sees the tunnels it dug and not
the ones it didn't, and a synchronizer replicates to everyone by construction.

`OFFLINE` is a real mode — `is_server()` is true offline, so a single-player match takes the same
branch a host does, which is what stops the authoritative path being the one nobody plays.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/net_audit.gd
```

Stands up a real server and **two** real clients on a real socket. Two, not one: with a single
client every packet came from the only peer there is, so attribution is right by luck. It caught a
transport that opened its socket, accepted connections, reported CONNECTED and **silently never
polled** — `_ready` doesn't run inside `add_child` when the parent isn't in the tree yet, so
`add_child(t); t.host(port)` switched the pump on and a deferred `_ready` switched it back off.

**And intent is a value now.** An [`InputFrame`](scripts/net/input_frame.gd) is one tick of what a
player meant — movement, aim, and two masks of held and pressed actions —
and [`InputCapture`](scripts/net/input_capture.gd) is **the only place in the game that reads a
keyboard on a gameplay path**. Six files did before this. The four ability scripts stopped being
`_unhandled_input` handlers, which was never going to survive a wire: an event handler fires on
*this* machine's event stream, and a server has none for a peer three hundred miles away.

Aim and look travel *resolved* — a world position and a direction, not a cursor and a stick —
because both depend on the camera, the camera is permanently local, and a frame carrying screen
coordinates is one the server can't interpret. Single-player runs the identical path, which is what
stops the networked one being the path nobody tests.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/input_audit.gd
```

Round-trips every field through bytes, and checks a driven frame actually drives. Its first version
**passed with the mechanism deleted** — the assertion immediately above it called `input()` and
captured the tick, so the cache returned the driven frame regardless. Not a weak assertion: a good
assertion whose side effect disarmed the next one.

**And there are seats.** Ten chairs, five a crew, each holding either a peer id or a bot.
[`Seats`](scripts/net/seats.gd) is the table and [`NetSession`](scripts/net/net_session.gd) owns it
alongside the transport — the only object in the game with a socket. Joining takes a chair on the
crew with fewer *people* (every chair is always occupied, so counting free ones is meaningless);
leaving hands it straight back to a bot, and **the chair never disappears**, because a crew that
loses a human must not lose a mouse.

Offline is the same table with peer 1 in blue seat 0 and bots everywhere else. Single player is a
listen server with no clients, and there's no second code path to keep alive.

```bash
godot --path . -- --host 47800
godot --path . -- --join 127.0.0.1:47800
```

Flags before buttons, deliberately: checkpoint 1 is *two windows on one machine*, and
`tools/seat_audit.gd` launches two real Godot processes and asserts the seating out of their logs.
With a Host button alone it could be demonstrated and never checked — and the failures that matter
here are the ones that still look right from inside a match.

**And two people can now meet in a yard.** Mice go out as poses at 30Hz — position, facing and a
byte of state — and clients interpolate between them. The snapshot is **indexed by seat**, which is
what makes the protocol have no spawn messages at all: the roster already says which ten chairs
exist, so a client builds its mice from the seating and every packet afterwards just says *chair 7
is here now*. A client simulates nothing; a puppet is a flag on `Mouse`, not a subclass, because
authority changes hands mid-match when somebody disconnects.

```bash
godot --path . -- --host 47800 --play
godot --path . -- --join 127.0.0.1:47800 --play
```

**A host logging 285 inputs a second while the mouse stood still** is what that cost to learn: the
seat held a `Bot`, and a bot's controller reads a navigation path, so the frames arrived, applied,
and did nothing. Every count on both ends looked healthy. A remote human's chair holds a `Player`
now, so a networked player runs the identical code a local one does.

`tools/replication_audit.gd` puts two real processes in a **real arena**, drives one with
`--autopilot`, and compares the two logs: the client's mouse went somewhere, it isn't the host's
mouse, nobody drove the host's mouse, and both ends agree which mouse is whose. It found that a
client connecting *before* it enters a match was never told its seat — snapshots arriving at a
healthy rate, **zero applied** — and that the first version of the audit had been passing on
favourable timing rather than on design.

**And there's a match around it.** [`MatchState`](scripts/net/match_state.gd) carries everything on
the HUD that isn't a mouse — score, both cheese pools, the clock, the verdict, ten respawn
countdowns and both banners — four times a second, **whole rather than as changes**. The plan said
"on change"; the numbers said otherwise (the entire scoreboard is smaller than one snapshot) and a
full state can't get stuck wrong the way a missed change can. Health rides in the pose, where it
belongs.

**No HUD file was touched.** `score_bug`, `match_hud` and `roster` already asked `MatchDirector`
for these numbers, so a client whose director holds the right numbers has a correct HUD — the wire
writes through one door and no UI file learns that a network exists.

**Bots Scurry now**, which the plan called blocking for this milestone: a crew whose AI seats never
spend cheese is playing a different economy from the crew across the yard. They spend on the two
moments the ranking already cares about — getting away with their banner, and catching whoever has
yours — by asking the director exactly as a key press does.

**A parse error in the entire multiplayer match failed no suite.** `net_match.gd` was left with a
call whose signature had changed under it and all five in-process suites passed: they build arenas,
the `NetMatch` node failed to load, Godot printed one line and carried on, and every invariant about
tunnels and cheese and mice was still true. `net_audit` now loads every scene and every script and
asserts none is null — the dullest check here, and the only one that catches that.

**What a client still can't see:** every tunnel in the arena, the cheese lying in the yard, and
anything an ability does. That's step 5, the visibility filter, and it's the risky one.

## M6.5 — a build you can hand to somebody (closed)

**There is a game you can enter and leave.** A title screen is the main scene now, the arena is
somewhere you go, and `Escape` pauses — freezing the sim rather than hiding it, so a tester who
steps away doesn't come back scruffed. Fullscreen persists between launches, the version sits in
the corner, and the F1 shader-tuning panel frees itself outside a debug build.

**The controls screen reads the live `InputMap` rather than a list of strings**, so it cannot go
stale, and anything nobody grouped is drawn at the bottom under its raw action name — a new binding
shows up ugly instead of absent.

**And the build keeps its own evidence.** File logging is on and **`P` takes a screenshot**; both
land in the same folder, which the controls screen names on screen, so what comes back from a
playtest is one directory to zip. `P` and not `F2` because macOS maps the top row to brightness
unless the tester has changed a setting they've never heard of — the one key whose whole job is to
work in a stranger's hands has to work on the first press.

**And there's a `.app`.** 176 MB, universal, ad-hoc signed; it boots into a full match with no
errors, and the log names the build it came from — game version, GPU, resolution, and whether it's a
release build, which is how the F1-panel gate gets verified rather than assumed. `tools/` and
`greybox.tscn` are confirmed absent from the `.pck`.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release "macOS" "$PWD/build/Codename Mouse.app"
```

**What's left needs hands**: pause, fullscreen, the screenshot key in the shipped build, the look on
a Retina panel, and what Gatekeeper says once the bundle has travelled. Transfer by `rsync`, `scp`
or a USB stick — AirDrop and browsers set the quarantine attribute, and recent macOS refuses an
ad-hoc-signed app that carries it.

> **If a tester's log comes back empty, ask how they closed it.** Godot's file logger buffers, and a
> Force Quit takes the buffer with it; a normal quit flushes, and errors and warnings are written
> immediately either way. Four zero-byte logs looked exactly like file logging being broken in a
> release build, and it was `pkill`.

## What's built, M0 through M6

**M5 and M6 are both closed.** Crawling into an enemy tunnel is frightening — unlit because you
didn't hang the lamps, its layout was never yours, and what you can make out arrives a cell at a
time and then goes stale. No dial needed moving; the first milestone since M2 whose verdict didn't
come back as a level-design problem.

**And cheese is lives.** The economy runs both ways now — caches to gather, stores to bank and
raid, a 20-second respawn while broke, and Scurry as the one spend you choose. The best part
turned out to be the smallest change: **dropped cheese never rots.** A pile waits where somebody
fell until somebody comes for it, and nearby drops merge into one growing pile. This game had
exactly one place both crews were obliged to care about — the flag. Now every fight leaves
another, nobody chose where they go, and the map grows its own objectives as the match runs.

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
| **Space** | **Scurry** — spends **1 team cheese** for a ~2s burst. Multiplies your current speed, refills sprint stamina, and makes you fully visible. 15s personal cooldown; the wedge beside your health bar says when it's ready. |
| **Left click** | Attack — a short cone in front of you |
| **Right click** | Dig: point at a tile next to your tunnel and hold |
| **E** | Take the shaft under or over you |
| **F / R** | Sink a shaft down / break one up |
| **C** | Change class — **only while standing in your own nest**, selector slides up |
| **Q** | **Cave-in** (Engineer) — bring down the tunnel cell you are pointing at. The cell is boxed while you aim, warm when it will fire and cold while it cools. |
| **X** | **Barricade** (Engineer) — wedge a boulder into the open cell you are pointing at |
| **Arrows** | Turn the view a quarter at a time |
| **Escape** | Pause — freezes the match, not just the view |
| **P** | Screenshot, saved beside the log file. Not `F2`: macOS gives the top row to brightness and volume by default, so a function key photographs nothing on somebody else's Mac. |

Every one of these is on the in-game controls screen, generated from
[`scripts/input_setup.gd`](scripts/input_setup.gd) at runtime rather than typed out a second time —
move a key there and the screen moves with it.

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

**The economy** is spread across three places on purpose, since it is three different questions.
On **MatchDirector**: `starting_cheese` (20), `cheese_ceiling` (40 — so hauling can't win a match
on its own), `respawn_seconds` (6) and `broke_respawn_seconds` (20), and `drop_merge_radius` (2.2
— how close a fresh drop has to be to join an existing pile instead of starting its own). On
**Surface/Cheese** (a
`cache_field`): `per_side` (3, mirrored to 6), `wedges_each` (6), `ring_radius` (23),
`fan_degrees` (120 — how wide either side of the perpendicular) and `nest_clear` (11, a hard
floor behind the angles). On a **Mouse**: `scurry_seconds` (2.0), `scurry_cooldown` (15.0) and
`scurry_multiplier` (1.85, a real step above Sprint's 1.4). On a **Nest**: `stores_offset` and
`stores_reach` — where the crew's pile sits and how close you must be to bank or raid it.

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
applies when *both* ends are above ground, since following someone down is not a preference),
`scurry_pursuit` (7 — how close a chaser has to be before a carrying bot spends a life getting
away; a burst is for a chase, not for a commute) and `scurry_chase` (18 — how far off a thief can
be and still be worth catching).

On **CameraRig**: `pitch_degrees` (48), `zoom_idle` / `zoom_run` / `zoom_sprint`, `follow_speed`.

### Audits

**Seven** headless invariant suites — the three below plus `net_audit.gd`, `input_audit.gd`,
`seat_audit.gd` and `replication_audit.gd`, all documented under M7 above. All must pass; each
exits non-zero if it doesn't. The last two launch **real Godot processes** and take about a minute
between them, which is why they're listed last and not why they should be skipped.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/tunnel_audit.gd
```

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/match_audit.gd
```

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/cheese_audit.gd
```

**Run all seven before cutting a build.** An exported release template does not accept `--script`,
so none of them can ever run against the `.app` — the honest procedure is to run them on the same
commit the export is built from and then smoke-test the binary by hand. A build that inherits
confidence the audits didn't actually give it is the failure this whole project keeps warning about.

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

The third holds 37 invariants over the cheese loop (M6): wedges are **conserved** between cache and
pile rather than spawned, raiding an enemy store is a transfer, banking happens once, a mouse's paws
hold one thing, Scurry **multiplies** your current speed rather than setting a flat one — so a
Scurrying carrier is a fast carrier and not a mouse that stopped carrying — drops persist and merge
into one growing pile, respawns cost what they should and take 20 seconds while broke, and **every
refusal is free**, so a rejected spend never bills anyone.

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
cant mark, revealed rock caps, and the arena at large. `menu_shot.gd` photographs the title screen,
the controls sheet and the pause menu at four window sizes, which is how "test common resolutions"
gets performed by somebody who would not resize a window twenty times.

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . --script tools/screenshot_probe.gd
```

Presses `P` and asserts the **artefact**, not the call: a file that wasn't there is, it decodes at
the window's size, and it has more than one colour in it — because a blank capture is the failure
that writes a perfectly valid file. It also checks the confirmation toast isn't in its own
successor. It exists because every way this can break looks identical to success from the tester's
chair, and it immediately earned its keep: the filename was a bare timestamp, the clock reads to
the second, and two shots taken in the same second silently overwrote each other.

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
scripts/game/   teams, nests, banners, the match rules, who can see whom and what,
                scene routing, settings, the screenshot key
scripts/ai/     bots, and the Engineer's raid
scripts/ui/     score bug, minimap, roster, feed, title and pause menus, the controls
                sheet, and the two skins they share
scripts/tunnels/the network, the routing graph, shaft transit, digging
scripts/        player, camera, maps, input setup
scripts/net/     transport, input frames, seats, snapshots, match state, and the session
                that owns them
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

## M6 — cheese is lives (closed)

**M5 got its verdict and it was yes**, at first-pass values, without a retune. That closes the
hidden-information layer and opens the economy.

**Most of the ledger was already standing, and none of the loop.** The pool, its signal and the
readout on the score bug have been in since M3, and the respawn cost has been charged the whole
time — `_on_scruffed` spends a cheese the moment you hit the dirt. What has never existed is a way
to put one *back*, or a way to spend one *by choice*. An economy that only drains is a countdown,
and you cannot ask a countdown whether it creates decisions.

So M6 is four things, and **they are all in**:

**Cheese you can go and get.** Six caches sit on a ring deliberately *off* the nest-to-nest lane,
mirrored so neither crew has a shorter walk. You take **one wedge at a time** and carry it home,
which makes refilling a series of trips across ground somebody else wants rather than a prize you
grab. Get scruffed and it lands where you fell, with a clock on it, for whoever wants it.

**A store you can raid.** Banking happens at a saucer inside your nest — its own spot, not the
banner's feet, and that detail is load-bearing: while the two shared a radius, a raider in an
enemy nest picked up the **banner** every time, because the banner is worth more. Enemy stores
are raidable (§2), so a nest now has two things worth standing on and a defender has two things
to cover.

**A zero that bites without ending you.** Respawns go 6s → **20s** while broke, read at the moment
you are scruffed and *before* the charge, so a crew on its last cheese still gets the short wait
for the death it could afford.

**Scurry.** Space, one cheese, ~2s, 15s personal cooldown. It **multiplies** your current speed
rather than setting one — so it does not erase the flag-carry penalty, and a Scurrying Sneak is
still a worse carrier than a Scurrying Generalist. It refills your sprint stamina, which makes it
a second wind rather than a stat buff, and it pins you at **full opacity**: buying speed with
cheese must never also buy stealth. Everyone sees the counter drop and everyone knows who pressed
it, which is most of what makes it a decision.

Sprint is *not* part of this: GDD §9 split sprint off the economy onto per-class stamina, and
`player.gd` has held it since M4.

Caches are on the minimap **for both crews** — a deliberate exception to M5's instinct that
information should be earned. The bankruptcy play is a *plan*, and a plan has to be makeable from
the nest before you commit; a cheese hunt you can only run from memory is homework. What stays
hidden is how much is left in any one pile.

**Dropped cheese never rots**, and that is the piece worth calling out. A pile waits where somebody
fell until somebody comes for it; drops close together merge into one growing pile. An earlier pass
gave drops a timer on the theory that a clock creates urgency — it does the opposite, because a
pile that expires is a pile you can win by ignoring. Left alone, they turn every fight that
happened into somewhere both crews have a reason to return to. Every pile is on the minimap for
both crews, authored and dropped alike.

## Next: M7 — real multiplayer

*Does it survive contact with a second human?* **Done when you and a friend play a full match over
the internet and it's playable.** Not perfect — playable.

The interesting part is how much of it is already built, because six milestones of "secretly
netcode decisions" were kept honest. **`Mouse._control()` is already the driver seam** — `Player`
overrides it and reads the keyboard, `Bot` overrides it and reads the AI, and a third override
reading a replicated input frame slots in beside them without the base class changing.
**`MatchDirector` is already the sim**: every rule resolves in one `_physics_process` on one node
that owns the state. And **per-crew knowledge is already stored per crew** — the tunnel network
keeps team bit masks, so the hidden-information pillar needs filtering, not retrofitting.

What is *not* built: input is read where it's used rather than captured as data (only three files
touch `Input.`, and one of them is the camera, which stays local forever); actions call the rules
directly, and on a client every one of those has to become a request; "the player" is singular in
eleven places, all but one of them presentation. Five checkpoints, each playable, with the
visibility filter deliberately not last — a leak there looks like nothing at all from inside a
match, which is exactly the kind of failure `tools/` exists to catch. See
[the plan](docs/02-implementation-plan.md) for the full survey and sequencing.

**Fix in checkpoint 2:** bots don't Scurry yet. Fine for M6's question, blocking for M7 — a crew
whose AI seats never spend cheese plays a different economy from the one across the yard. The
Backyard BBQ layout and the dig-controls pass still stand behind all of it.

The Backyard BBQ layout still matters, but it is no longer the sequencing gate. It and the
dig-controls pass return after the core systems, when the surface and tunnel routes can be laid
out and tuned once rather than repeatedly around unfinished information rules.
