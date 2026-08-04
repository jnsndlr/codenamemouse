# Codename: Mouse — Implementation Plan

> The **how**. Tech decisions, architecture, and a milestone path that front-loads the
> risky questions and defers everything else.
>
> Read [`00-intent.md`](00-intent.md) and [`01-gdd.md`](01-gdd.md) first.

---

## Guiding principle

**Every milestone must answer a question we can't answer by thinking.**

The failure mode for a project like this is building infrastructure for a game that
turns out not to be fun. Order accordingly: prove movement → prove digging is *legible*
→ prove the loop → prove digging is *fun* → then everything else.

Corollary: **grey boxes and capsules are correct, not a compromise.** We are not making
do until art arrives. We are removing every variable except whether the systems are good.

---

## Tech decisions

| Decision | Choice | Why |
|---|---|---|
| Engine | **Godot 4.x** | Full engine: navmesh, physics, animation, headless server export, editor |
| Language | **GDScript** first | Fastest iteration. C#/GDExtension is the escape hatch if sim gets hot. |
| Camera | `Camera3D`, `projection = ORTHOGONAL` | ~45° yaw, ~40° pitch. "Isometric" is a camera setting, not a feature. |
| **Tunnel storage** | **One `GridMap` per plane** | See below — this is the key technical insight |
| **Tunnel pathing** | **`AStar3D` over dug cells** | Graph traversal, not dynamic navmesh |
| Surface pathing | `NavigationServer3D` navmesh | Standard, baked once per map |
| Target (dev) | **Desktop** | Fast iteration, real UDP, no browser constraints during design |
| Target (later) | **Web export, decided at M9** | Same project either way. An export target, not an architecture. |
| Netcode (v1) | **Listen server** | One client hosts, authoritative. Zero infrastructure. |
| Netcode (v2) | **Headless dedicated** | Same codebase, `--headless` export, ~$5/mo VPS when needed |
| Transport | **Behind an interface from day one** | The one piece of early architecture worth building |

### The tunnel system is a GridMap problem, not a geometry problem

This is the most important technical decision in the project, and it's what makes the
GDD's dig system tractable:

- Each of the **4 planes is a `GridMap`** — Godot's built-in 3D tile grid.
- A **MeshLibrary** holds the tunnel chunk pieces (straight, corner, T, ramp, entrance).
- **Digging = setting a cell.** Godot handles instancing, batching, and culling for free.
- **Collapse = clearing cells.** No mesh surgery.
- **Intersection detection is trivial** — check whether the target cell is already set
  by the other team, which gives you the GDD's "networks join" rule for free.
- **Pathing is `AStar3D` over set cells**, with ramp cells linking planes. Godot ships
  `AStar3D`; no custom graph code needed.
- **Bots traverse the same graph players do**, so there's one source of truth.

No runtime mesh deformation. No dynamic navmesh rebaking. No Red Faction engineering.
The chunk-based, plane-limited design isn't a compromise — it's what makes a solo
project able to build this at all.

**Organic feel without free-form geometry.** GridMap supports 8-way (45°) connections
via diagonal tiles in the MeshLibrary. Combined with irregular chunk meshes and per-chunk
placement jitter, that should read as organic rather than boxy. If it doesn't after M2,
the escalation is **free-angle segment placement** — instanced meshes on a graph instead
of a GridMap. Notably, `AStar3D` accepts arbitrary 3D points, so **pathing, networking,
and visibility code are unchanged by that swap.** Only storage and rendering change,
which makes this a genuinely reversible decision.

### Rendering the planes

- Each plane is a `Node3D` at a fixed Y offset, containing its GridMap.
- The surface uses a material whose **alpha is driven by the local player's depth** —
  descend, and the surface ghosts out.
- The **active plane renders solid with an emissive edge material**; other planes dim
  or hide entirely.
- Two visibility masks: **your network** (fully mapped) and **enemy segments** (only
  what's been revealed by sonar or line of sight). This is a per-team visibility set on
  the client, driven by server state.

### Design decisions that are secretly netcode decisions

Already in the GDD, worth naming so they don't get casually reversed:

- **Projectiles, never hitscan** — tolerates latency; hitscan demands server rewind
- **No random damage, no crits** — deterministic sim is far easier to reconcile
- **Displacement over damage** — knockback forgives small desyncs that HP thresholds don't
- **4v4** — 8 entities is a trivial state payload
- **Tunnels are discrete cells** — replicating "cell (3,7) on plane 2 is now dug" is a
  tiny message. Free-form digging would have been a replication nightmare.

### The transport interface (cheap now, valuable later)

Browsers can't do raw UDP. Rather than deciding the web question now, wrap it:

```
NetTransport (interface)
  ├── ENetTransport       # desktop, UDP, ships first
  ├── WebSocketTransport  # web, TCP, adequate for a prototype
  └── WebRTCTransport     # web, UDP-ish, only if competitive play demands it
```

Game code talks to `NetTransport` and never touches a peer class. Costs a day now,
preserves the browser option indefinitely.

---

## Architecture

### Server-authoritative from the start

Even in listen-server mode, the host runs the authoritative sim and clients send
**inputs**, not positions. More work in week one, saves a rewrite later, and makes the
move to a dedicated server a deployment change rather than a redesign.

```
Client                          Server (authoritative)
  ├── input capture       ──▶     simulation tick (30Hz)
  ├── local prediction              ├── movement + collision
  ├── interpolation       ◀──       ├── combat resolution
  ├── per-team visibility           ├── tunnel graph state
  └── presentation                  ├── objective + cheese
                                    └── world faction AI
```

Prediction and reconciliation are **deferred**. Start naive, add prediction when it
actually hurts.

**Tunnel visibility must be server-filtered.** If the client receives the full tunnel
graph and just doesn't draw the enemy's, that's trivially cheatable — and the entire
hidden-information pillar dies. The server sends each client only what their team has
revealed. Build it this way from the start; retrofitting it is painful.

### Data-driven from the start

Classes, abilities, world creatures, and tunnel chunk types live in **Godot `Resource`
files, not code** — inspector-editable and hot-reloadable.

```
ClassDefinition (Resource)
  health, speed, tunnel_speed_mult, carry_capacity
  can_enter_tunnels: bool
  abilities: Array[AbilityDefinition]

AbilityDefinition (Resource)
  cooldown, cast_time, range, damage, knockback, cheese_cost, effect
```

You have fifteen years of ideas and will want to try them fast. Tuning should be an
inspector edit, not a recompile.

### Project structure

```
codenamemouse/
├── docs/
├── scenes/
│   ├── game/               # match, spawn, objective, economy managers
│   ├── entities/           # mouse, flag, cheese, world creatures
│   ├── tunnels/            # GridMaps, chunk MeshLibrary, dig controller
│   ├── maps/               # arena.tscn — one world, not a copy per milestone
│   └── ui/                 # HUD, minimap, depth indicator
├── scripts/
│   ├── net/                # NetTransport + implementations
│   ├── sim/                # authoritative simulation
│   ├── tunnels/            # graph, pathing, visibility, collapse
│   ├── classes/            # class + ability logic
│   └── ai/                 # bots and world faction
├── resources/
│   ├── classes/            # ClassDefinition .tres
│   ├── abilities/          # AbilityDefinition .tres
│   └── world/              # PvE creature definitions
└── assets/                 # placeholder now, real later
```

---

## Milestones

Each has a **question**, a **done-when**, and a hard scope boundary.

### M0 — Spike (½ day)

**Question:** does the toolchain work end to end?

- Godot 4 installed, project created, git initialized
- A cube on a plane under an orthographic iso camera
- **Web export smoke test** — deploy to Cloudflare Pages, confirm it loads

**Done when:** you've seen your cube in a browser tab. Then ignore web until M9.

---

### M1 — A mouse that moves (2–4 evenings)

**Question:** does isometric movement feel good?

- `CharacterBody3D` capsule, WASD movement, cursor aim
- Camera follow with slight lookahead
- Grey-box arena: flat plane, boxes, a ramp

**Done when:** moving the capsule around is *pleasant*. This is a real bar — if
movement is unsatisfying, nothing built on it will be fun.

**Not in scope:** combat, classes, digging, networking.

---

### M2 — Dig spike (3–5 evenings) ← **first real risk**

**Question:** can a player see and understand a tunnel from a top-down view?

Deliberately **no game around it** — this is a legibility experiment, not a feature.

- 4 planes as GridMaps, one chunk MeshLibrary (straight, corner, ramp, entrance)
- Dig a segment, pivot off the end, build a ramp, descend a plane
- Surface ghosting, emissive tunnel edges, depth indicator
- Move a capsule through the result

**Done when:** you can dig a three-plane network, look at it, and **immediately
understand its shape.** If you can't, iterate here until you can — or discover that the
depth count needs to drop from 3 to 2.

**This milestone can save you a year.** The GDD's signature system lives or dies on
this question, and it's answerable in under a week.

#### What the spike found

**Verdict: yes, three planes read — but only because of colour, not depth.**

- **Vertical separation does almost nothing.** Planes are one `SPACING` apart, which at a
  40° pitch projects to a handful of screen pixels. Rendered in one colour, three stacked
  networks land nearly on top of each other and are genuinely indistinguishable — you can
  see there's a network and not what shape it is. Dimming the unfocused planes did **not**
  fix this on its own.
- **Per-depth rim hue fixed it outright.** Cyan / amber / magenta for depths 1–3. With hue
  carrying identity, dimming only has to carry *focus*, and the two jobs stop fighting.
  This is the single most important finding of the milestone and it's a five-line change.
- **The bright rim does the work, not the floor.** A thin emissive band capping each wall
  outlines the network far more legibly than lit floor tiles ever did.
- **"Underground" needs something behind it.** Ghosting the surface at first revealed the
  *sky*, and the whole network read as floating in mid-air. An opaque earth backdrop below
  the deepest plane fixed it. Ghosting alone is not enough — there has to be earth.
- **Zoom matters more than expected.** Close in, one plane dominates and reads easily.
  Pulled back to see a whole network, everything above depends on the hue coding.

> Three depths survive. The plan's escape hatch — dropping 3 to 2 — was **not** needed.

#### Superseded: the rim-hue finding answered the wrong question

Per-depth rim hue is **gone**, and with it the emissive rim entirely. It was the right answer
to "how do you read four stacked networks at once" — and nobody needs to. What a player wants
to see is *their own tunnel, on the layer they are in*.

So each layer is now drawn as an open **trench cut through solid earth**. A lid sits one plane
spacing above every floor with that layer's tunnels punched out of it, walls run the full
height from floor to lid, and only the focused layer — plus its neighbour above, floors only —
is drawn at all. You cannot see the layers below, so they cannot be confused with yours.

- **The cut is a shader, not geometry.** `art/shaders/earth_cutaway.gdshader` discards against a
  one-texel-per-cell mask. Digging writes a texel; there is no mesh to rebuild, no CSG to
  recombine, and critically **the collision mesh never changes** — the ground stays solid, so
  entering a tunnel stays an interaction rather than a hole you fall down.
- **Layering is luminance, not alpha.** Nothing is transparent any more, which structurally
  eliminates the entire class of bugs that dogged M2: flickering rims, the focused plane having
  to be forced opaque, the 80×80 slab painting over all 760 rocks in the depth-write-off pass.
- **The ground closes up when you stand on it.** An early build left it permanently cut and the
  whole network read as a black trench drawn across the lawn from a surface view — giving away
  for free the hidden information the game is built on (§3).
- **Sky ambient drops underground** so the lamps have something to be brighter than.

> **Walls went from 0.26 to a full plane spacing**, reversing the other M2 look decision. That
> cap existed because a tall wall standing on a ghosted surface was just an occluder. With a lid
> overhead the wall is the *side of a trench*, which is what makes it read — and it retires the
> containment risk noted below, since the mouse can no longer be lifted over a 0.26 lip.

#### Then the mouse vanished, and the fix was `PLANE_SPACING`

Walls at a full spacing made the trench read and made the player invisible. The camera looks
down at 40°, so a wall of height *D* hides a strip of floor `D / tan(pitch)` wide behind it:

| Trench depth | Blind strip | Visible in a 1-cell corridor |
|---|---|---|
| 1.5 | 1.79 | **none — geometrically impossible** |
| 0.65 | 0.77 | most of it |

At 1.5 the floor of a corridor could not be seen at any zoom or angle, and the mouse's head sat
1.1 below the rim. **`PLANE_SPACING` was 1.5 for exactly one reason** — it's the drop a ramp must
cover over two cells, set as high as `floor_max_angle` would take. Nothing about looks. Dropping
it to 0.65 makes ramps *gentler* (16° against 37°) and every trench shallow enough to see into.
Camera pitch also went 40° → 48°, which shrinks every blind strip by a fifth for free.

- **Its floor is mouse headroom.** Spacing must exceed `0.4 + FLOOR_THICKNESS` or a mouse on
  plane N+1 can't stand under plane N's slab. 0.65 leaves 0.13 of margin.
- **The lawn had to get thinner too.** At 0.5 thick it left 0.15 of air above plane 1's floor —
  the whole layer was unplayable, and nothing about that reads as a hole or a fall.
- **New invariant: `HEADROOM`.** The mouse must fit, standing, in every cell it can dig. This is
  the exact failure lowering the spacing invites and it's invisible to every other check.

> **Invisible barriers don't have anywhere to go.** The plan was to draw low walls and collide
> tall ones — right in principle, impossible here: the only thing above a wall is the floor of
> the plane above, one spacing up. Set to 1.4 against a 0.65 spacing, every barrier grew through
> that floor and became an invisible wall on the layer above; the audit caught plane 1's barriers
> standing 0.75 proud of the lawn and fencing off the entrance. Collision height is now equal to
> the wall, which is fine while nothing can lift a mouse. When displacement lands the answer is
> **per-plane collision layers**, not taller barriers — and burrowing makes that easy, because
> plane transitions stop being a continuous walk.

> **Arrow keys swivel the view in quarter turns.** A trench running across the view is hidden
> behind its own near wall for its whole length; the same trench pointed at the camera is open
> end to end. Lower walls and a turnable camera are the same fix from two directions.

#### Ramps replaced by shafts, and most of the system went with them

**F** sinks a shaft down, **R** breaks one up, **E** drives a horizontal tunnel *or* takes
whichever shaft the tile has. The cell disambiguates E, not press length, so there's no
tap-versus-hold guessing — and the tile is marked (dark for down, bright for up) so you can
see which before you press. A tile may not have both, which is what gives E one destination
and stops a well being drilled straight from the lawn to the bottom.

The floor stays solid. A shaft is a mark, not a hole — you enter a tunnel because you chose
to, never by walking over the wrong tile, and nothing can fall down one.

**What this deleted**, all of which existed to serve sloped two-cell geometry: `RAMP_UPPER` /
`RAMP_LOWER` and the two-cell split, `_ramp_steps`, `_orientation_facing`, `_ramp_edge_height`,
`_ramp_geometry`, `_open_faces` and its cross-plane wall suppression, `_blocked_by_step`,
`is_ramp_shadowed`, `dig_ramp`/`_ramp_refusal`, `surface_holes.gd` with its CSG entirely — and
**the reachability guard with its snapshot and rollback**. A shaft takes no walkable space
away and occupies nothing on the plane below, so digging can only ever *add* connectivity and
there is nothing left to strand. Four invariants retired with them: `RAMP_PAIRS`, `RAMP_ENDS`,
`OPEN_FACES` and `VERTICAL`. They weren't fixed; they became unrepresentable.

Three replaced them — `SHAFT_ENDS`, `NO_STACK`, `PLANE_LAYERS` — and all three were
teeth-tested by forcing the failures past the guards.

> **Per-plane collision layers.** Each plane's geometry is on its own layer and a mouse
> collides only with the layer it's standing on. That's what makes an invisible barrier
> possible at last: `barrier_height` is now double the spacing and overshoots into the plane
> above freely, where before it fenced off whoever was up there. It's the answer for GDD §6
> displacement, and burrowing is what made it easy — plane transitions stopped being a
> continuous walk, so there's no moment where a mouse needs two layers at once.

> **The plane is state, not a measurement.** `plane_at_height` was read every frame and
> flipped under the player halfway down a ramp. The controller now knows which layer it put
> you on. It still resyncs if your height stops explaining it — `fall_guard` respawns you on
> the lawn without telling anyone, and stale state means digging into a plane you aren't on.

#### Digging became aiming

Point at a tile, hold **LMB**, watch it open — 0.5s for now, and per-plane dig time is already
a GDD §3 balance dial. The hovered tile is outlined on hover with no button pressed, which is
what makes the reach and adjacency rules learnable: you find out a tile is out of range by
pointing at it, not by holding a button and being told nothing.

Drive-forward extrusion put the tunnel wherever you walked — fast, but with no way to say
*that one*, and it shared its key with the shaft, so the tile you most wanted to dig away from
was the tile that had already claimed the button. **E is now only the way into a shaft.**

- **The dig target must touch the tunnel you already have** and be within `dig_reach`.
  Otherwise you could stand in one corridor and carve an unconnected room across the arena.
- **New check: `DIG_FLOW`.** Every other invariant inspects a network built by calling `dig()`
  directly, so none would notice if the *controls* were broken — a reach test that rejects
  everything, progress that never accumulates. That's half the feature, and it's the half the
  player touches. Teeth-tested by shrinking `dig_reach` until it failed.

> **Shafts are round now, and the way up is a beam.** The hole is a jittered, smoothed ring
> rather than a square — jitter alone gives a star, since each vertex is independent of its
> neighbours; one averaging pass turns spikes into the lobes a scraped hole actually has. And
> the painted square marking a shaft *above* you is gone in favour of a light ray falling out
> of it. A mark can only say "something is here"; a beam says where it comes from, lights the
> floor it lands on, and reads as a way out with nothing to teach.

> **The layer above is no longer drawn at all.** Showing its floors dimly was meant to help you
> orient; in a corridor it did the opposite, because its tunnels lie on the lid you're trying
> to look through and read as marks on your own floor. The lid stays solid over them, and where
> the layers join is announced by the light.

#### Tunnels need placement rules, and they need to be checked, not reasoned about

A second pass over the spike went hunting for edge cases instead of waiting to fall through
one. `tools/tunnel_audit.gd` builds eighteen deliberately awkward networks and asserts eight
invariants over each — matched ramp halves, both ramp ends having somewhere to stand, honest
cross-plane openings, no ramp descending through the plane below, every dug cell reachable
from an entrance, cells inside the arena, floors that exist in the physics world, and a
**containment probe** that walks the player's own capsule eight ways out of every cell and
every ramp surface, checking that everywhere it can reach has ground under it.

It found four families of bug, three of which the spike had been shipping:

- **A ramp claims more space than it draws.** Its lower half finishes *below* the floor of
  the plane beneath, so the two cells a ramp occupies are filled, not shared — the physics
  probe can't find a pose for the mouse in there at all. Digging a corridor under a ramp
  (or a ramp over a corridor) produced tunnel that looked continuous and could not be
  entered, and nothing could clear it because the obstruction lived on another plane's grid.
  Both directions are now refused.
- **`plane_at_height` flips halfway down a slope**, so holding dig while descending cut floor
  cells on the lower plane *at the ramp's own coordinates*. Digging is now suppressed while
  on a ramp: a ramp is transit, not a dig site.
- **A ramp anchored underfoot puts its arrival floor behind you.** Run to the end of a
  corridor, turn ninety degrees, ramp down — and the ramp, its landing and every plane below
  were sealed off from the tunnel that paid for them. Anchoring the slope to the cell *ahead*
  makes the top of the ramp the cell you're already standing in, which fixes it by
  construction. The most ordinary action in the game was the worst bug.
- **Ramps at the arena boundary walked you out of the world.** Wall generation deliberately
  leaves a ramp's uphill face open — it's the way on — so a ramp whose arrival floor fell
  outside the arena opened onto neither floor nor wall.

> **The general guard beat the structural rules.** Successive "ramps only from a corridor
> end"-shaped rules each missed a case, and a chamber-wide dig has no corridor end at all. So
> `dig_ramp` now applies the edit to the cell data, walks the graph, and rolls back if
> anything that was reachable no longer is. One question asked directly, instead of a growing
> pile of approximations — and it permits the chamber case the blunt rules forbade.

> **Refusals need a voice.** Placement rules mean keypresses that legitimately do nothing, and
> a silent refusal is indistinguishable from a broken control — which the entrance key had
> already taught us once. The network emits `dig_refused(reason)` and the HUD says why.

> **`WALL_HEIGHT` when displacement arrives — since resolved.** At 0.26 against a 0.4 capsule the
> mouse was contained only because nothing could lift it, with a 1.0-tall void between the
> surface slab and plane 1. The trench rendering above raised walls to a full plane spacing for
> unrelated reasons and closed it.

> **Deferred, and honest about it:** `GridMap`'s MeshLibrary collision shapes are set and
> valid but no body ever appears in the physics world, so the player fell through every
> floor. `tunnel_network` generates its own collision trimesh from the same cell data. It
> works and it's verifiable, but it's a workaround for something not yet understood, and
> it costs the free batching the storage decision was partly chosen for. Worth a proper
> diagnosis before M4 leans on tunnels for real.

---

### M2.5 — Reactive grass (2–4 evenings)

**Question:** does bending grass read as a *tell* — can you look across a lane and know
someone is there, and roughly how fast they're moving?

This is inserted ahead of M3, and it **reverses this plan's own deferral** of tall grass to
post-M9 (see *What we deliberately don't build yet*). That deferral called it "a shader
problem, not a systems problem," which was wrong on the second half. GDD §8 is explicit that
it is the best system in the document, and for a systems reason: **it is hidden information
that isn't a class ability.** Every class makes the stealth/speed trade, everyone can read the
tell, and it costs no cooldown and no resource. That is a mechanic, and mechanics get tested.

- A reactive grass shader, ported and hooked to player position and velocity
- A few grass patches in the arena — patches, not a lawn; this is cover, not decoration
- The **speed ladder (§9) drives the bend**, which is the whole point of the milestone

**Done when:** standing still in grass, you feel hidden — and you can spot someone else
crossing a patch without seeing the mouse itself.

**Not in scope:** actual concealment rules (does grass really break line of sight?), Sneak
camouflage stacking, grass on any map but this one, tuning the stealth balance. This
milestone answers whether the *tell* reads. Whether it's fair is M5's problem, when hidden
information gets built for real.

> **Transparency and the pixel pass are not independent, and finding that out cost a bug.**
> The pixel pass repaints the whole frame by resampling a screen texture captured after the
> **opaque** pass. Anything in the transparent queue is therefore absent from that capture
> and gets erased — so the first concealment build made the mouse invisible everywhere, at
> every opacity including fully solid. Dithered transparency (`TRANSPARENCY_ALPHA_HASH`)
> stays in the opaque pass and fixes it, and also keeps the mouse in the depth buffer so the
> pass still finds its silhouette. **Anything added later that wants to fade must dither**,
> or it will disappear rather than fade.

> **Why it goes before M3 rather than after.** The flag run is a chase across open ground, and
> M3's question is whether that chase is tense. Grass changes what the surface *is* — it turns
> a flat lane into cover and sightline. Building the loop on bare ground and adding cover after
> means tuning the chase twice, and the second tune invalidates the first verdict.

> **The bend should be CONTINUOUS in speed, not four discrete tiers**, and this resolves a
> real inconsistency between the two documents. GDD §8's table lists Sprint / Run / Walk /
> Slow, but §9's ladder is Slow / Run / Sprint / Scurry — there is no "Walk" tier on a
> keyboard, and §9 says so itself: the stick gives a Slow-to-Run *continuum* while the
> keyboard gets discrete keys. Driving the bend from `get_horizontal_speed()` makes both fall
> out of one curve, and it means Scurry (§9, and absent from §8's table) is loudest for free
> when the economy lands at M6.

---

### M3 — The core loop (1 week)

**Question:** is the flag run tense?

- Two nests, two banners, pickup / carry / drop / capture / return
- Melee combat, health, scruffed state, respawn
- Score, timer, win condition
- **Two bots** using navmesh + a simple state machine

**Done when:** you can play a full match against bots and it produces a moment worth
describing to someone.

**Not in scope:** cheese, real classes, multiplayer, art.

> **Tunnels stay on, reversing the original "surface only".** M2 didn't leave a prototype
> to be integrated later — it left a working dig system in the shipping arena. Switching it
> off would mean maintaining a disabled path and paying the integration cost anyway at M4,
> which is the same drift that killed the second scene. Digging is simply available.
>
> **GDD §2 already contains the guard that makes this safe.** *The flag cannot enter a
> tunnel* — so the carry home is surface by rule, and no amount of digging can shortcut the
> run M3 exists to evaluate. Tunnels move mice into position; they never move the objective.
> The milestone's question stays readable.
>
> **The residual cost, stated anyway:** bots don't path through tunnels until M4, so a human
> can approach the enemy nest underground against defenders who structurally cannot follow.
> That skews the *steal*, not the *run*. Judge tension by the trip home.

#### What the milestone found

**The loop closes, and it produces a story without being told to.** Three bots a side, left alone
for three minutes: a steal at 22s, scruffed on the way home at 31s, the banner recovered by its
own crew, a capture at 48s, a counter-steal, a chase that ended two strides from the nest. Final
2–1. Nothing in that sequence is scripted — it's four rules and a navmesh — and it is the first
thing this project has produced that is recognisably *a match* rather than a demonstration.

- **Bots that fight are bots that never play.** The first version ranked "an enemy is nearby"
  alongside the banner rules, which made a nearby enemy a *destination*. Four bots then spent an
  entire ninety-second soak brawling in the middle of the yard: sixteen scruffs, one steal, zero
  captures. The milestone's own question was unanswerable because there were no flag runs to
  judge. The fix is to split the decision in two — **where it is going** and **who it is squaring
  up to** — and let only the banner rules move a bot. A raider now swings at whatever it brushes
  past and keeps walking.
- **A defended nest is what makes a run worth measuring**, which is why crews are three and not
  the plan's "two bots". Three is the smallest crew that fields a defender and still has someone
  raiding. With nobody home a steal is a walk, and a walk tells you nothing about tension.
- **Everyone chases the thief**, raiders included — not out of loyalty but because GDD §2's rule
  that your own banner must be home means a crew whose banner is away *cannot score at all*.
  There is nothing else worth doing. A rule written for tension turned out to also be the AI's
  priority function.
- **The banner rides above the carrier's head.** GDD §2 says carriers are always visible on the
  minimap; there is no minimap yet, so the rule became a world object instead — a pole a
  body-length above the grass line. Concealment reads the same fact and switches itself off for a
  carrier, so you cannot steal the flag and then hide in a bush with it.

> **Left click is the attack; digging moved to right click.** GDD §9's table always said so, but
> through M2 there was nothing to fight, so the dig hold took the primary button unopposed and
> would quietly have become the convention. Digging is the Engineer's *ability* (§4), and right
> click is the ability button in that same table. The milestone didn't decide this — it was the
> first one with a reason to care.

> **The flag cannot enter a tunnel, and it's enforced at two gates.** The dig controller refuses
> to take a carrier down a shaft *and says why*, which is where a player meets the rule; the
> director drops the banner if a carrier is found underground by any other means. The second gate
> exists because every future way of being moved somewhere you didn't choose — Slam, a cave-in, a
> current — routes around the first.

> **One mouse, two drivers.** `mouse.gd` now owns locomotion, health, the swing and the team
> colour; `player.gd` and `bot.gd` are the halves that read a keyboard and a navigation path.
> This wasn't tidiness: the grass tell (§8) only works if a bot bends grass exactly as hard as a
> player moving at the same speed, and two movement implementations would have drifted apart on
> the first tuning pass.

> **The camera cuts on respawn rather than flying.** A respawn puts you at your own nest, most of
> an arena away, and easing after it costs several seconds in which you can neither see your
> mouse nor read the fight you just lost. The rig snaps whenever its target emits `revived`. The
> follow speed also went from 1.0 to 6.0 — the slow follow was an M2 setting for looking at
> tunnels while standing still, and a chase needs the mouse near the middle of the screen.

**Two bugs worth remembering, both invisible to every rule-level check:**

- **The navmesh has to bake a frame late.** A CSG shape builds its mesh the frame *after* it
  enters the tree, so baking in `_ready` parsed no ground at all — six polygons floating on top
  of the props. Every bot found no path, stood still, and looked exactly like broken AI. It's why
  `match_audit` asserts a nest-to-nest path directly of the navigation server: the failure and
  the symptom are in different files.
- **Two mice at one point don't stand on each other, they launch.** A zero-length separation
  vector resolves in whatever direction the solver picks, usually straight up. Respawns and bot
  spawns are now fanned around a small ring. The same physics ate an afternoon in the audit
  harness, where a body added at the origin and moved afterwards fired the mouse standing there
  clear across the arena — which looked precisely like a teleport bug in the director.

> **`tools/match_audit.gd` is the tunnel audit's bargain applied to the rules.** Ten invariants:
> nav path, steal, capture (all three conditions), scruff-drops, the return clock, the flag
> underground at both gates, melee (in front only — not behind you, not your own crew, not
> someone standing on another plane beneath your feet), respawn, both ways a match can end, and
> a check that bots actually leave the nest. Rule bugs fail the same way geometry bugs do: they
> need a specific sequence, they won't happen in the first ten matches, and they are trivial to
> check once stated. Timed rules are tested at fractions of a second — the twenty and the six are
> balance dials, the mechanism is what must not break.

**Deliberately still absent:** a scruff costs no cheese (that's the economy, M6), bots cannot
follow you underground (M4), there are no classes, and the swing is a cone with no animation
behind it.

---

> **The honest verdict on "is the flag run tense?" is: yes, and it is the chase that does it,
> not the fight.** Getting scruffed two strides from your own nest with the banner over your head
> is the moment the milestone was looking for, and it happens on its own. What is *not* tense is
> the middle of the yard, which is eighty metres of open dirt with three rocks in it — the
> arena was built to look at tunnels from above, not to be run across. That is a map problem
> rather than a systems one, and it belongs to whichever milestone first has a reason to lay out
> a real Backyard BBQ (GDD §8).

---

### M4 — Digging in the game (1–2 weeks)

**Question:** is digging *fun*, not just legible?

- ~~Engineer class: dig, ramp, barricade~~ **done** — dig speed, cave-in, barricade
- ~~**Bots path through tunnels** via `AStar3D` over dug cells~~ **done** — this was the
  milestone's centre of gravity, since M3 already ships digging and the flag map together.
  Until bots can follow, digging isn't a decision, it's an exploit.
- Dig controls pass (GDD §9 open question) — **deferred with level design**
- ~~per-plane rock obstructions~~ **done**, and ~~no-surface zones belong with the patio they are
  a rule about, which makes them part of the Backyard BBQ layout~~ — **reversed, and they are done
  too.** A zone is a footprint and a refusal; the patio is a thing you can see. Only the second
  one is level design, and holding the first hostage to it meant the map would have arrived with
  an untested rule bolted to it.

**Done when:** you'd rather take the tunnel than the surface route — and the choice
feels like a real decision rather than an obvious one.

> **Sequencing decision: the M4 systems are closed and its verdict is deferred.** The real
> Backyard BBQ layout is still required to answer the done-when honestly, but level design is no
> longer a gate in front of M5. Visibility and economy are core rules that can land against the
> greybox; the map and dig-controls pass return after them, when routes can be laid out and tuned
> once around the systems they will actually carry.

#### In progress — the Engineer, and classes that mean something (landed)

Four `ClassDefinition` resources in `resources/classes/`, per this plan's own data-driven
section, copied onto a mouse by `set_class` rather than read through a reference — so grass,
combat, carrying, the HUD and the bots all get per-class behaviour without one of them learning
what a class is. Swap point at your own nest, **C**, cycling.

- **Everyone digs; the Engineer is three times faster.** A deliberate revision of GDD §4's
  exclusivity, recorded there. Exclusivity makes one seat a *requirement* — lose your Engineer
  and the crew is locked out of three planes until it respawns. Speed carries the identity
  instead, and the Engineer's Pillar-4 exclusive moves to **un**-digging: caving in behind you,
  and barricades. That collides with the Brute's Collapse and the split is written up as a
  `[DECIDE]` in §4 rather than quietly resolved here.
- ~~**`tunnel_speed` is where the classes first feel different.**~~ **Reverted later in M4, and
  the Brute is why.** The theory was that size should matter underground (§3) and that a slow
  Brute would read as a cork rather than as lag, because it applied only below the surface. It
  read as neither: at 0.35 a Brute crossing its own tunnel was slower than everyone else on the
  lawn above it, which is a class quietly locked out of the game's signature system. Every class
  is 1.0 now and the multiplier is floored at 1.0 in code. The cork survives as geometry — a
  one-cell corridor plus body-blocking (§6) — which is where it always really lived.
- **The swap rule is asked of the nest, not of a prop.** `Nest.contains` is already the capture
  disc and the respawn point; a hand-placed swap-point object would drift away from both, and a
  swap zone that isn't quite the capture zone is a bug you only find by playing. It also means
  §4's "free on respawn" needs no second mechanism — you come back standing where swapping works.
- **The dig-flow audit failed the moment classes landed, correctly.** It encoded "everyone digs
  at one speed". It now asserts the *spread* in both directions: a Generalist must not open a
  tile in the time an Engineer does, and must open it eventually.

**The Engineer's capability landed too: the cave-in** (`scripts/classes/cave_in.gd`, `Q`).
`TunnelNetwork.collapse` is the first and only operation that makes the network *smaller*, which
matters more than it sounds — the routing graph, the dug mask, the wall mesh and the lamps are
all caches over the cell dictionary, and every one of them had been written assuming growth.
`AStar3D.remove_point` took its own edges with it, which is the second time picking a real graph
structure over a hand-rolled adjacency list has paid for itself.

- **Aimed, not automatic.** The obvious build is "seal the cell you just left, free, while
  fleeing". Aiming it means turning to look, which means not running for a moment — the trade §9
  already asks for around throwing while fleeing, and the thing that stops this being a free
  escape button.
- **A shaft cell is refused.** Either end of a shaft would leave a ladder starting or finishing
  in solid earth — SHAFT_ENDS catches it in the audit, and in play it is a mouse pressing E and
  arriving inside the ground.
- **Stranding is allowed and REACHABLE had to be re-scoped to say so.** Sealing a corridor cuts
  off everything past it; that is the mechanic. The invariant is now explicitly a rule about
  what *digging* may leave behind, with the stranding case asserted on its own terms.
- **The selector bar** (`scripts/ui/class_bar.gd`) appears on the same condition the swap does,
  and the contextual hint was cut back to just the key — the bar already shows the four cards
  and a pointer at the one you are, and saying it twice would put the smaller copy above your
  head. Icons are drawn rather than imported, like the rest of this HUD.
- **Scout → Sneak, Bruiser → Brute**, from the mockup, everywhere including the docs.
- **The HUD scales with the window.** It was written in raw pixels, which is correct at exactly
  one window size and wrong everywhere else — at 1080p the score bug had shrunk to a strip you
  had to lean in to read. One multiplier (`HudSkin.scale_for`, the smaller of the two ratios,
  clamped) applied to every size in every HUD file. Deliberately *not* Godot's `canvas_items`
  stretch mode: it would do the same job for free and also render the 3D at the base resolution
  and upscale it, which would quietly undo the pixel pass the look is built on. The HUD is drawn,
  so the HUD can scale itself and leave the renderer alone.
- **Roster portraits, one per class, placeholder.** A list of four names is a list you read; a
  row of four faces is one you recognise. The headgear tells the classes apart rather than the
  face — four differently-shaped mice would be four sets of proportions to get wrong. All of it
  behind `_portrait`, so real art is a texture lookup and the file changes in no other way.

**Bots are all Generalists for now**, deliberately. A Brute bot without Slam is just a slow
mouse, and a Sneak without sonar is just a fragile one — class variety for the AI is worth
having the day the abilities exist and not before.

#### In progress — bots path through tunnels (landed)

The centre of gravity is done. An `AStar3D` graph mirrors the dug cells (`tunnel_graph.gd`),
kept current incrementally off two new signals rather than rebuilt; `route_planner.gd` stitches
it to the surface navmesh; `tunnel_transit.gd` is the one door between the two, shared by the
player's controller and the AI so the rule that *the banner cannot go down* cannot exist in two
versions. A defender now meets you three planes down. The Engineer class, the dig-controls pass
and per-plane obstructions are still to come.

- **Four-way, and that isn't a simplification.** Walls are built on the four faces of a cell,
  so two diagonally touching cells have no gap between them. The obvious eight-way graph routes
  straight through that corner and into earth — invisible from above, and indistinguishable
  from a bot clipping a wall. The graph's connectivity is the geometry's, exactly, and the audit
  builds a diagonal staircase specifically to assert nothing routes along it.
- **Plane 0 exists in the graph only at shaft mouths.** The surface is a navmesh, not a grid;
  the mouths are the only place the two systems touch. A graph that connected two mouths
  directly would be inventing a straight line across ground it knows nothing about — so it
  refuses, and crossing the lawn stays the planner's job, because the planner is the only thing
  that can see the props.
- **"Go down the nearest hole" is wrong, and the audit caught it the first time it ran.** The
  nearest entrance may open onto a corridor that goes nowhere near your destination — which
  strands a bot on the lawn directly above its quarry, the exact failure this milestone exists
  to remove. The few nearest mouths at each end are now tried and the cheapest connecting route
  wins.
- **Measure the lawn with the navmesh, not with a straight line.** The first version compared
  the tunnel against the crow-flies distance, which is optimistic in precisely the case tunnels
  exist for: a patio in the way makes the real walk far longer than the line, so the planner
  would conclude the surface was fine and never go under anything. It would have made the
  milestone's question unanswerable by construction.

> **Bots never take a tunnel when both ends are above ground, and that is the correct answer to
> a map problem.** No route under this arena is shorter than the straight line over the top of
> it, because the yard is eighty metres of open dirt — M3 said the same thing about the midfield
> from the other direction. Nothing in the router is disabled or biased off; it simply keeps
> answering "walk". The comparison starts choosing tunnels the day the map has something in the
> way, which makes **laying out a real Backyard BBQ (GDD §8) a prerequisite for M4's own
> question**, not a polish task for later.

#### In progress — obstructions, the barricade, and earth you can see (landed)

Three of M4's four bullets are done. What is left is the **dig-controls pass** — and the
**Backyard BBQ layout**, which this plan promoted from polish to prerequisite below.

**Per-plane rock obstructions (GDD §3).** Seeded seams, laid as random walks rather than discs so
the edges are ragged, at 9% of plane 1 rising to 16% of plane 3. A rock cell is *not a new kind of
thing* — it is earth that can never open, so it is drawn by the same wall, collides as the same
wall, and is invisible until somebody digs up against it. That last part is the design: you learn
where the rock is by paying for the knowledge.

- **The refusal has a voice and a cursor.** The dig cursor goes grey and stops pulsing over a
  seam, and pressing on it says why. Without that, "this is rock" looks identical to "out of
  reach", "not adjacent" and "already dug" — the cursor simply vanishes for all four.
- **Deeper is rockier, which is the same direction §3 already sends dig time.** Two dials pushing
  the same way rather than cancelling: it is what keeps the shallow planes worth using once you
  know the map.
- **Nests keep a clear radius**, because a seeded layout that walls a crew in does it identically
  every match, and that reads as the map being broken rather than as a hard start.
- **The audits turn rock OFF by default**, set before the scene enters the tree because the seams
  are laid in `_ready`. Every scenario digs at hand-picked coordinates; a seam across one of them
  would fail a geometry invariant for a reason that is not about geometry — identically every run,
  which is the most convincing kind of wrong answer. One new check turns it back on, and it is the
  only check in the file that runs against a *generated* layout rather than a hand-built one.

**The Engineer's Barricade.** `X`, aimed at the open cell beside you: a boulder, seeded off the
cell so the same spot always grows the same rock. **No cheese** — ten seconds between placements,
three standing at once, and **only a Brute can shift one**. The cheese price GDD §2 pencilled in
is deferred rather than dropped, and the reasoning is in §4: the economy has no sinks until M6, so
pricing against it now means tuning the ability twice.

- **Three things have to agree, and two of them are silent when they don't.** The rock is
  physical (a collider on its own plane's layer), it is *routed* (the cell leaves the `AStar3D`
  graph), and it is removable (Brute swings only). The routing half is the one that would be easy
  to forget and impossible to see: a bot pathing into a cell it cannot enter does not error, it
  stands there grinding, which reads as broken AI rather than as the map having changed.
- **Blocking is not collapsing**, and they are deliberately different operations. A barricade
  leaves the cell dug — floor, walls, lamps and cutaway mask all unchanged and none of them
  rebuilt. Folding it into `collapse` would have rebuilt a plane's geometry every time a boulder
  moved, and made putting one down indistinguishable from digging a fresh corridor.
- **It breaks into pieces of itself** (`rock_debris.gd`): the shell is cut into wedges by
  bucketing its triangles around a handful of seed directions, and they scatter, land, settle and
  fade over about a second. Grouping *consecutive* triangles was the obvious thing and was wrong —
  the shell is generated ring by ring, so a run of triangles is a band that goes all the way round
  and every shard came out a curl of orange peel. **The debris is its own node**, not an animation
  the barricade plays before freeing itself, because the cell has to be walkable and out of the
  blocked set on the swing that breaks it: a Brute who has just earned the corridor must not be
  held up by a rock that is visibly in bits, and a bot re-planning mid-animation must not be told
  a visibly clear route is shut. The rule and the picture have different lifetimes, so they are
  different objects — and the audit asserts the cell is open *before* it advances a frame.
- **The audit's first version of the class gate was vacuous, and caught itself.** "A Generalist
  swinging at a barricade achieves nothing" was asserted by checking the rock was still standing —
  which is true whether the swing was ignored, missed, or landed and left two hits to go. Deleting
  the Brute check did not fail the test. It counts the hits now, and deleting the check fails two
  assertions. Same lesson as the untyped-array bug below, from a different direction: a test that
  cannot fail is worse than no test.

**Earth you can see, and a lawn you can't see through.** Two look changes that are really one
complaint — the trench read as a coloured card with the garden hovering in it.

- **Every earth surface carries a dirt grain now** (`dirt_texture.gd`): a broad mottle, fine sand
  and speckle, generated seamlessly by construction and mapped in *world* space, so the lawn, the
  trench floor and the wall between them share one continuous speckle instead of three that stop
  at each other's edges. Greyscale, so it multiplies each surface's own tint rather than replacing
  it. Generated rather than imported because at this stage the grain size is a number you want to
  change and press play; Godot's `NoiseTexture2D` was the obvious tool and is the wrong one, since
  it generates on a thread and hands back an empty texture for the first few frames.
- **The rocks and grass vanish the moment you are under them**, one layer sooner than the ground
  they stand on. The ground has to stay — it is plane 1's lid. What sits on top of it does not: a
  rock and a tuft of grass drawn over an open trench are a metre above the floor you are reading
  and, at this camera angle, land on it. Dimming them to 20% was never going to fix that, because
  the problem was not brightness.

**And the cave-in shows where it lands** — the aimed cell in the dig cursor's own box, warm when
the ability will fire and cold while it cools, so the cooldown lives in the world rather than only
in a line of HUD text.

> **It also outlined every cell in reach, for about an hour.** The argument was that "which ones
> could I have picked" is worth answering alongside "which one am I on", and in a corridor it read
> fine. In a chamber it is a bright frame around every tile on screen, and the grid it draws pulls
> harder than the mouse standing in the middle of it. The box answers the question that matters, in
> the one place you are already looking; the rest was noise dressed up as help.

#### In progress — no-surface zones (landed)

The second kind of obstruction (GDD §3), and the one the plan had filed under level design.
`NoSurfaceZone` is an authored rectangle on the lawn; `TunnelNetwork.is_sealed` asks the map
whether a cell is under one, and the only thing that ever acts on the answer is the shaft
refusal at **plane 0**. Everything else — digging along under the paving, sinking from plane 1
to plane 2 beneath it — passes straight through untouched, which is the difference between a
no-surface zone and a wall.

- **It is a rule, not a prop, and that is why it could be built before the map.** What the zone
  owns is a footprint and a refusal. The paving it draws is a grey box; a modelled patio becomes
  a child of it later and `show_paving` goes off. Waiting for the Backyard BBQ layout would have
  meant the map arriving with an untested rule attached, and the rule is the part with edge cases.
- **Plane 0 is the only place the check belongs.** A shaft is recorded once, at its upper plane,
  whichever end it was cut from — so one test in `_shaft_refusal` covers pressing F on the patio
  and pressing R underneath it, and there is no second copy to drift. The two get different words
  anyway (`dig_shaft_up` says its own, the way rock overhead already does), because "you can't dig
  through this" and "keep going until you're clear" are different pieces of advice.
- **A mouth is a cell wide, so the seal is asked with half a cell of margin.** Without it a shaft
  whose centre just clears the slab still takes a bite out of its edge, and the hole you are
  refused and the hole you are allowed end up drawn a centimetre apart with nothing to tell them
  apart. The audit's footprint is deliberately laid so its edges fall *between* cell centres, and
  the two cells either side of the line are named rather than swept.
- **The tell is above your head, and it is the one refusal in that slot.** The contextual hint is
  otherwise a list of offers — `[E] climb up` — and this is "no way up". It belongs there anyway:
  a committed crossing is only a decision if you know you are on one, and the information is the
  moment it *clears*, because that is where you can surface.
- **Nothing in the routing changed, and that is the check that it is designed right.** A rule that
  can only stop a mouth from being created cannot invalidate a route, because the graph is built
  from mouths that exist. Compare the barricade, which had to be physical, routed and removable in
  three places at once.
- **Both halves are asserted against each other.** A seal that refused everything would pass every
  "was it refused?" line in the audit and be a slab of rock with better prose; a seal that refused
  nothing would pass every "does it still work?" line. Verified by breaking it in both directions:
  disabling the refusal fails six assertions, sealing the whole arena fails three here and
  twenty-one elsewhere — the latter being the useful surprise, since it shows every entrance in the game now
  goes through this test.
- **The audits strip authored zones by type**, not by path, for the same reason they turn rock off:
  fifteen scenarios sink shafts at hand-picked coordinates, and a patio authored across one of them
  would fail a geometry invariant for a reason that is not about geometry. `_check_seal` places its
  own where it wants it, so it cannot be broken by dragging the map's patio.
- **A placeholder patio sits in the arena** at (0, −7), 20×10 metres, and the grass and rock
  scatters now leave paving alone. It is a fixture, not a layout decision — one node to move or
  delete when the real yard gets designed.

> **The dig-controls pass is tabled, not done.** Point-and-hold works well enough to keep playing
> with, and the map is still what will tell us whether it is the friction or the fun.

#### In progress — veins you can see, and rock you can break (landed)

Rock was legible at the moment it stopped you and invisible before and after. Two changes, and
they are opposite halves of one idea: **a seam you have hit is remembered and drawn, and a boulder
tells you what is under it before you dig at all.**

- **Running into a seam reveals the whole connected vein, to your crew only.** Four-way flood fill,
  matching the walls and the routing graph — an eight-way one would join two seams that touch at a
  corner, and a corner is precisely where a mouse cannot get through. The cell you spent is the
  price; the shape of the vein is what you bought.
- **This is the game's first per-team knowledge, and that is why it was worth doing on rock.** Rock
  never moves, so the shape of "what does this crew know" gets settled against something static
  before M5 has to do it for tunnels and sightings, where the answer changes every second. It is
  stored as a bit mask per cell rather than two dictionaries, so a boulder — which everybody can
  see — is one entry and not the same cell recorded twice.
- **Drawn as a sheet ABOVE the lid, in its own colour, unshaded.** The seam *face* is lit stone you
  are standing in front of; the top is rock read through a layer of earth, so drawing them the same
  grey would say the ceiling had been cut away. Unshaded because the sheet sits under a lid lit by
  almost nothing and a shaded one came back black — it is a piece of knowledge laid over the world,
  which is the same argument the dig cursor makes for ignoring depth.
- **The network is TOLD who is looking rather than going to find out.** `depth_focus.gd` already
  owns "what the local player can see of the layers"; a renderer that went hunting for "the player"
  would be reaching into the match to ask whose side it is on, and at M7 that question has no
  single answer on a server.
- **Boulders are the counterweight, and they only block plane 1.** A seam charges you to find out
  where it is; a boulder is lying in the open, so the way past it — go under — is knowledge the map
  hands out for free. Blocking every plane would have made it a wall, and a wall you can see from
  the lawn is just a smaller arena.
- **A boulder is registered as ordinary rock, not as a second kind of obstruction.** Digging,
  shafts, the wall mesh and the routing graph already refuse rock in all the right places; a
  parallel mechanism would have had to be taught to each of them separately, which is four chances
  to miss one. It also means the tunnel-side of a boulder needed no new code at all.
- **Five swings per cell, and each cell is its own object.** A four-cell boulder is twenty swings
  and opens a quarter at a time, so clearing one is a decision about how much you want rather than
  a countdown. That fell out of giving `Breakable` the hit pool instead of the boulder — and the
  branches and sticks that come later now arrive as objects rather than as rules.
- **One swing pass for everything breakable.** There used to be a second pass written specifically
  against barricades; boulders would have made a third, at which point every new destructible thing
  costs an edit to `mouse.gd` and the edit most likely to be forgotten is the one that makes it
  hittable at all.
- **The navmesh rebakes when a boulder goes**, threaded, which `nav_surface.gd`'s own comment had
  already asked for ("revisit if the map ever rebakes mid-match"). Leaving it stale is not neutral:
  bots would keep walking around a rock a Brute spent twenty swings removing, which reads as the AI
  refusing to use the thing you just made for it.

> **The bug that cost the most was not a design question.** A `const GROUP` on `BarricadeRock`
> shadowing the same name on its new base class made every *other* file that read
> `BarricadeRock.GROUP` fail to parse, with "Could not resolve external class member" reported
> against whichever file happened to touch it. It reads exactly like a cyclic-dependency error, and
> an hour went into restructuring a dependency that was never the problem. Both files now say so.

> **Node order bit too, and the fix is worth copying.** Godot readies depth-first, so everything
> under `Surface` — including the boulders, which claim cells the moment they exist — runs before
> the network's own `_ready`. The cell dictionaries moved to `_init`, where they cost nothing and
> cannot be raced: they are plain dictionaries and had no reason to wait for a renderer.

> **The minimap draws one layer now, the one you are standing on** — the same rule the world
> itself follows. Four planes stacked on a 200-pixel square are not a map of anything: two
> corridors a plane apart cross on the panel without touching in the world, so the picture asserts
> junctions that do not exist, and a deep network fills the yard with routes you cannot take from
> where you are. The depth tint stays and now means something on its own: it says how deep the
> corridors you are looking at are. On the surface, where there are no dug cells to draw, it shows
> the **shaft mouths** — the only part of the network that means anything from the grass.

> **Two bugs the screenshot found that the audit could not, and they were the same mistake twice:
> testing the rule and not the picture.** The sheet was drawn just *under* the lid, which is where
> a seam's top surface really is and where it is permanently invisible — the only thing that ever
> cuts a hole in a lid is a cell being dug, and a rock cell is never dug. And the reveal hung off
> deliberately pressing dig *into* rock, which is the one action the interface talks you out of:
> the cursor greys and stops pulsing over a seam precisely to say holding the button will achieve
> nothing. So a player could dig a corridor along a seam, stand there looking at its stone face,
> and have found nothing. Digging a cell that exposes a face now reveals it too, and both halves
> are asserted — the audit had happily checked that the mesh existed, which it did, under a metre
> of earth.

> **One bug found by reading, then pinned by a test.** The pieces a section throws off were
> parented to the boulder, which frees itself once its last section is gone — so the final quarter
> of every rock vanished instead of breaking, one time in four, in the only case that ends the
> object. A check that stops after "break a section" never reaches it; the boulder check now breaks
> a whole rock and asserts the debris outlives it.

> **Both new checks were verified by breaking them.** A reveal that leaks to both crews fails four
> assertions; one that reveals only the cell you hit fails three; a boulder that blocks nothing
> underneath fails three per cell. The leak case is the one that matters — hidden information fails
> silently and always in the direction of knowing too much, so every assertion has a mirror asking
> what the *other* crew still must not know.

> **The tunnel audit had been passing without testing anything.** `const STRIP: Array[String] =
> [...] + STRIP_MATCH` yields an *untyped* array in GDScript; passed to a parameter declared
> `Array[String]` it aborts the call at runtime, so `_arena` returned null, every check no-opped
> on a null network, and all fourteen scenarios reported `ok`. Only the dig-flow check, which
> passes `STRIP_MATCH` directly, was ever real. The geometry turned out to be sound when the
> scenarios finally ran — luck, not vindication. **Both halves are fixed:** the type, and a
> harness that reports `BROKEN` and fails the run when it cannot build its own subject. The
> lesson generalises past this file: a test that cannot fail loudly when its own scaffolding
> breaks is worse than no test, because it also stops anyone looking.

---

### M5 — Hidden information (1 week)

**Question:** does the vision asymmetry create the tension we're betting on?

- **Per-team tunnel visibility data** — **landed**; server filtering attaches at M7
- **Own-tunnel wide awareness** — **landed**, as lamplight: you lit your network, so you read it
- **Enemy-tunnel line of sight + fog** — **landed** (`tunnel_sight.gd`)
- **Sneak class with sonar** — **landed**, including contestable cant marks
- **Minimap layer rendering** — **landed**, filtered to the local crew, with seen enemy ground
  drawn faintly and fading

**Done when:** crawling into an enemy tunnel is *frightening*. — **MET. M5 is closed.**

> **The verdict: the tunnels feel good.** Played, and the vision asymmetry does the work it was
> bet on — an enemy corridor is unlit, its layout is not yours, and what you can make out arrives
> one cell at a time and then goes stale. No retuning was needed: `lamp_*`, `sight_cells`,
> `memory_seconds` and `enemy_seen_alpha` all shipped at their first-pass values.
>
> Worth recording *because* it was the milestone most likely to come back a map problem. M3 and M4
> both concluded the midfield needed level design rather than tuning; M5 did not. The thing that
> made the difference was Engineer bots building a network per crew, so the yard fills with
> corridors somebody else made — the condition the question could not be asked without.

#### In progress — a map is knowledge, and knowledge leaves marks (landed)

Every dug cell and shaft now carries a two-bit knowledge mask, parallel to the rock knowledge M4
proved out. Live digging grants the cell to the digger's crew only. If blue and red corridors meet,
the physical intersection opens exactly as before, but neither side receives the connected enemy
route on its minimap: the map shows what your crew made, not everything the shared `AStar3D` graph
can traverse. Authored and audit geometry defaults to both crews so test fixtures remain neutral.

The Sneak's **Q** sounds a five-cell radius on exactly one plane below. Every nearby tunnel cell
answers as a brief outline on the floor above; when the echo fades, only the nearest answer remains
as one persistent piece of thieves' cant in the world and on the crew's minimap. That is the
information bargain: a scan proves *there is a route here* without handing over its shape.

The cant belongs to the crew, but it is not secret from the class that speaks it. An enemy
Generalist cannot see the mark at all; an enemy Sneak can see it in the world and on the minimap,
and pressing **Q** from arm's reach erases it before attempting another scan. Clearing ignores the
scan cooldown because it is counterplay, not a second use of the information ability.

`match_audit` now mirrors every knowledge assertion across both teams: cells and mouths do not
leak, sonar ignores the plane two layers down, one scan leaves one mark, the owning crew can read
it regardless of class, an enemy Generalist cannot, and an enemy Sneak can both read and erase it.

#### The dark, and what you can make out in it (landed)

**Lamps are crew property.** Lighting every cell of a layer made an enemy corridor a warm,
inhabited room, and it quietly undid the map rule beside it: the minimap could keep a floor plan
secret all it liked while the world drew the whole route out in lamplight the moment you dropped
into it. Now a lamp is a thing your crew hung there. Nothing is occluded, faded or fogged — the
earth is exactly where it was and there is simply no light in it, which is a systems answer rather
than a shader one and costs one condition instead of a fog volume. **Shaft daylight is exempt on
purpose:** a beam is the sun, not a lamp, so an enemy mouth still shows from the dark. That is the
one thing an intruder should get free, and it is the counterplay — the way out of a corridor you
cannot read is to head for the light.

**Sight grants, and time takes it back.** A cell of an enemy network that a crew member can
actually see goes onto that crew's map and begins ageing the moment nobody can see it. The memory
is `spotting.gd`'s to the letter — same seconds, same fade fraction, same confidence curve —
because a player should learn the staleness rule once, and two decay models on one minimap would
look like a bug in whichever one they noticed second. Line of sight is the grid rather than a
raycast: underground the walls *are* the undug cells, so "can I see that" is exactly "is every cell
between here and there open", answerable without a physics server, deterministically, in a headless
audit, and identically on a server at M7. A corridor bending away stops at the bend. Enemy shaft
mouths are learnt the same way from the lawn, and forgotten the same way.

Seeing a cell never makes it yours. It ages out, and the crew is back to knowing what it dug.

**And the fog is the ground itself.** The lid a trench is cut through is punched by a mask, and that
mask is crew knowledge now rather than a picture of the earth: your cells, plus what you can
currently make out. Built from every dug cell — which is how it shipped — it drew the enemy's whole
floor plan into the world in front of you, complete, before you had been anywhere near it. **The
minimap was carefully filtered and the world was not**, and the world is the one the player
believes; the filtered minimap beside it was decorative. This is the more important half of the
boundary and it was the half with no assertion on it, which is why there is one now, asked of the
real mask rather than of the rule that fills it.

#### Somebody had to have dug one (landed)

M5's question cannot be asked of an empty yard. Through M4 nothing in a match ever cut a tunnel
except the human, so "is an enemy tunnel frightening" had no enemy tunnel in it.

**Crews are five**, past the GDD's four, and the extra seat is bought rather than scaled: five can
carry a full-time Engineer and a Sneak without giving up the defender or the raid. Every seat is a
row in `MatchDirector.SEATS` — a role and a class — replacing two independent `seat % 2`
alternations that made a crew's composition an emergent property of an arithmetic expression.
Written down, it can be argued with. The Engineer raids and the Sneak defends, both deliberately:
an Engineer only digs somewhere worth digging *to*, and sonar under your own banner is how a crew
finds out it is being tunnelled under.

**Bots acquire their class rather than being born in it**, through `ClassSwap.allowed` — the same
predicate the player's **C** key is gated on. So a bot spawns a Generalist standing in its own nest
and is an Engineer a third of a second later, almost every swap happens on respawn (exactly where
GDD §4 puts a free switch), and the swap point stops being machinery exercised by one human
occasionally.

> **A cover rule was tried here and removed.** Bots would take the Engineer seat when their crew had
> none *standing*, on the theory that a digger is a capability rather than a preference. The theory
> is fine; the behaviour was not. Engineers are scruffed constantly, so "standing" flips several
> times a minute — every mouse that happened to be home flipped to Engineer, cut a stub, and flipped
> back. It made composition jitter and the yard worse. **The second Engineer seat went the same
> way**, and for a related reason: two of them raid, get interrupted and respawn independently, so a
> crew ended up with two half-corridors instead of one that arrived somewhere. One Engineer that
> reuses its own mouth builds a network. The fifth seat is a second Generalist raider.

**And Engineer bots dig** (`bot_digger.gd`). It replaces exactly one rule in `bot.gd`'s ranking —
the last one, going for their banner — because everything above that is a banner in play and a
tunnel is a twenty-second investment. It comes up *short* of the objective so a tunnel is not a
teleport, and when something urgent happens mid-corridor it stops driving and `route_planner.gd`
walks the bot out through the mouth it came in by.

Three rules make it build a network rather than make a mess, and all three were learnt from soaks
rather than from thinking about it:

- **Use a door before making one.** A raid is interrupted constantly, and a digger that cut a fresh
  hole wherever it stood produced twenty-eight cells across *eleven* mouths in a minute — a yard of
  three-tile pits. It now walks to its crew's nearest useful mouth, scored as the whole detour, and
  only cuts a new one when there isn't a good one.
- **Walk with the planner; dig at a face.** `_choose` returns solid earth only. When the way ahead
  is already open there is nothing for a digger to decide, and saying so hands the bot to the
  routing that can actually follow a corridor with a bend in it. A greedy one-cell stepper doing
  the navigating walks into the outside of the first corner and oscillates, which is precisely what
  two Engineers spent a soak doing.
- **Go under it.** Stone ahead and stone to both sides is not a dead end, it is the wrong plane.
  The bot sinks a shaft and carries on beneath — the behaviour the per-plane rock layouts were
  designed for (GDD §3: go round it, or go under it) and the first thing in the game to do it on
  purpose. Without it both crews' corridors stopped at the same midfield seam and the bots paced in
  front of it.

Plus stuck detection, a no-backtracking rule and a rest timer, because "the cell is open so I can
walk into it" is very nearly true and fails often enough to deadlock a bot permanently.

> **Two of those three bugs were invisible to the audit and obvious in a sixty-second soak.** The
> check asserted that an Engineer opens earth, which a bot punching stubs all over the lawn passes
> comfortably. What tells a corridor from a scatter is **cells per mouth**, and that assertion now
> exists. The general lesson is about what a rule check can see: correctness questions belong in the
> audit, and *quality of behaviour* questions need a soak that prints numbers you can look at.

> **The sight check was built so it could not fail, and that is the second time.** The corner it
> asserts you cannot see round was 8.1 cells away with sight set to 7 — so it tested the *radius*,
> and passed cheerfully with the line-of-sight test stubbed to `return true`. The far leg is 6.7
> cells out now: in range, and behind earth. Both halves were then verified by breaking them.
> The tunnel audit taught this lesson once already (below); the shape of the mistake was different
> and the moral was identical. **A test whose subject is arranged so the rule can't bite is not a
> weak test, it is a green light with nothing behind it.**

---

### M6 — Cheese is lives (1 week)

**Question:** does the economy create real decisions?

- Caches, carrying, team stores, respawn cost
- Zero-cheese slow-respawn state
- ~~Sprint drain~~ — **already landed at M4**, and not against cheese. GDD §9 split sprint off
  the economy onto per-class stamina, and `player.gd` has held it since: `sprint_seconds` comes
  off the class definition, with a regen delay and a re-engage floor. Left struck through rather
  than deleted, because the line is a trap — anyone reading the milestone list would build it a
  second time, against the wrong resource.
- **Watch specifically for the bankruptcy play** (GDD §2) — does anyone ever choose to
  concede a capture to go refill? If nobody does, the economy isn't tuned right.

**Done when:** you've agonized over a cheese decision at least once. — **MET. M6 is closed.**

> **The verdict: the economy holds, and dropped cheese turned out to be the best part of it.**
> The last change before closing was to take the clock off dropped wedges. A pile now waits where
> somebody fell until somebody comes for it, and that one edit changed what the map is: this game
> had exactly **one** place both crews were obliged to care about, and now every fight that
> happens leaves another. They are small, they are temporary in the sense that somebody will take
> them, and nobody chose where they go — which is the useful kind of objective, because it is not
> authored. Merging nearby drops into one growing pile is what makes that read as a place rather
> than as litter.
>
> Recorded because the reasoning ran backwards from the obvious one. A timer looks like it
> creates urgency; what it actually creates is a pile you can win by ignoring.

#### What was already standing

Worth being precise about, because it is most of the ledger and none of the loop. The pool, its
signal and its readout have been in since M3, and **the respawn cost has been charged all along**
— `_on_scruffed` spends a cheese at the moment the mouse hits the dirt, so the counter has always
ticked down. What has never existed is any way to put one *back*, or any way to spend one *by
choice*. An economy that only drains is a countdown, not a decision, and the milestone's question
cannot be asked of a countdown.

So M6 is four things: **caches** to gather from, **carrying** and a **deposit** that puts a wedge
in the crew's pile, a **zero state that bites without ending you**, and **Scurry** — the one spend
you choose. `Mouse.is_boosting()` has returned `false` since M2.5 waiting for the last of those,
and `grass_camouflage.gd` already reads it, so a Scurrying mouse is fully visible the day it lands.

#### In progress — the wedge loop (landed)

`cheese_cache.gd` is a pile with a count on it and `cache_field.gd` puts six of them out. A mouse
with free paws walks into one and takes **one wedge**; it banks at its own nest's **store**, and
that walk is the whole mechanic. Scruffed mice drop what they were hauling where they fell, which
is the same rule the banner already obeys and for the same reason. A dropped wedge is not a new
kind of object — it is a cache with one wedge and a clock, which is also the honest description
of what it is.

Enemy stores are raidable (§2), and making that work moved the furniture. The stores used to be
"the nest", which meant a raider standing in one **picked up the banner instead, every time**,
because `_check_pickup` runs first and a banner is worth more. Raiding would have existed only in
the case where their banner was already out and you had better things to do. So a nest now has a
**store saucer** offset from its banner stand — a second thing inside it worth standing on, and a
second thing a defender has to cover. The audit found this, not a playtest.

> **The cache ring shipped 45 degrees wrong and looked fine.** The layout fans caches either side
> of the perpendicular to the nest-to-nest diagonal, so going for cheese is a decision to be
> somewhere other than where the flag is. The first pass walked the arc from the wrong origin and
> put a cache **five metres from the red nest**, inside a defender's post, on the lane everyone
> already runs — and it still rendered as a tidy ring. `tools/cache_layout_probe.gd` now prints
> the distances instead of trusting the picture, and there is a `nest_clear` floor behind the
> angles: geometry authored in angles is easy to get subtly wrong, and a distance is not.

#### In progress — Scurry, and a zero that bites (landed)

Space, one cheese, ~2s, 15s personal cooldown. It **multiplies** current speed rather than setting
one (§2, marked *don't relax it*), so a Scurrying carrier is a fast carrier and not a mouse that
stopped carrying — the audit checks exactly that, because a flat top speed would quietly delete
the handoff play. The director owns it: `try_scurry` checks the pool, then the mouse, then charges,
so a refusal never bills anyone. Firing refills sprint stamina, which is what makes it a second
wind rather than a stat buff.

Respawns are 6s while you can pay and **20s while broke**, read at the moment of the scruff and
before the charge — a crew on its last cheese gets the short wait, because it could afford the
death it just took. The pool has a ceiling, so a crew cannot win by hauling cheese instead of
fighting.

Caches are on the minimap **for both crews**, which is a deliberate exception to M5's instinct
that information should be earned. The bankruptcy play is a *plan*: disengage, concede a capture,
go and refill. A plan has to be makeable from the nest before you commit, and a cheese hunt you
can only run by remembering where the wedges were is homework, not a decision. What stays hidden
is how much is left in any one of them.

**Bots do not Scurry yet.** They gather, bank, raid and pay for their respawns like everyone else,
but the one spend that is a *choice* is the player's alone for now — which is fine for asking the
milestone's question and wrong for M7, where the other side is a human doing it to you.

#### In progress — dropped cheese stays dropped (landed)

Drops have no clock. A pile waits until somebody takes it, and drops within `drop_merge_radius`
of an existing pile **join it** rather than starting their own — permanent drops without merging
turn a contested corridor into a scatter of single wedges, and a scatter is litter where one
growing pile is a landmark. Every pile is on the minimap for both crews, authored and dropped
alike.

That combination is what makes the economy generate objectives instead of just accounting for
them. The map ships with six caches; by the tenth minute it has however many places two crews
have killed each other while carrying, and each of those is somewhere with a reason to go.

`tools/cheese_audit.gd` holds 37 invariants over the loop: wedges are conserved between cache and
pile, a raid is a transfer rather than a spawn, banking happens once, paws hold one thing, drops
persist and merge, and every refusal is free.

---

### M6.5 — A build you can hand to somebody (3–5 evenings)

**Question:** can someone who has never seen this play a full match without you in the room?

- A title screen, a pause menu, and a way back out of a match
- Every binding visible in-game, generated from the bindings themselves
- Fullscreen, a version label, an icon
- Dev tooling gated out of a release build
- A signed-enough `.app` that opens on a MacBook that is not this one

**Done when:** a friend on another Mac has played a full match, and you have their log file.
— **Portability half MET. M6.5 is closed for the purpose it was inserted for.**

> **The verdict: the build runs on other Macs, including a five-year-old one.** Tested on a 2020
> MacBook Air and a 2026 MacBook Pro. That is the risk this milestone was pulled forward to retire,
> and it is retired: the universal binary, the ad-hoc signature, the resolution scaling and — the
> one genuinely uncertain item — the `RenderingDevice` compute pass all survive contact with
> hardware that is not the development machine. **The 2020 Air is the useful data point**, because
> it is the one that could plausibly have said no.
>
> **Being precise about what that does not answer:** the done-when asks for a *friend*, and a
> second machine you own is not one. The portability question is closed; the onboarding question —
> can somebody who has never seen this find `E`, and therefore ever see a tunnel — needs a person
> who is not you. That is worth doing and it is **no longer a gate in front of M7**, because M7's
> blocker was never onboarding: it was never having shipped a build at all, and now one has
> shipped, twice, onto hardware five years apart.

> **Why a milestone and not a chore list.** M7's last checkpoint is "over the internet, with a
> friend, for a full match" — which requires handing someone a build, something this project has
> never once done. Discovering how macOS feels about unsigned binaries *while* also debugging
> interpolation is how a two-week milestone becomes four. This pulls the distribution half
> forward so it can fail on its own, and the failures are cheap and boring when they are alone.
>
> The title screen earns its place the same way. Nothing in `scripts/` calls `change_scene`,
> `quit`, or touches `paused`: the arena is the main scene and that is the entire application.
> Making the match a thing you can enter and leave is the **seat and lobby skeleton M7 needs
> anyway**, so Play gets built as one entry beside a Host and Join that do not exist yet.

#### The question is onboarding, and that is a choice

The alternative question was stability — does it run for an hour without falling over — and the
bot soak already answers that better than a guest could. What no tool in `tools/` can answer is
whether the game **explains itself**, and there are fifteen bindings including four that are
each a whole subsystem: `E` burrows, `F` and `R` are shafts, `Q` is a class ability whose meaning
changes with the class. A tester who never finds `E` never sees tunnels, and tunnels are the game.

That choice sets the scope. Controls legibility and the first thirty seconds are the milestone;
a volume slider is not. **There is no audio in the project at all** — no `.wav`, no `.ogg`, no
`AudioStream` anywhere — so a volume control would be a slider wired to nothing, which is worse
than its absence because it reads as a promise.

#### Credits are fifteen minutes, because there is nothing to credit

Worth writing down so nobody budgets a day for it. The repo contains **zero third-party assets**:
no fonts, no textures, no images, no sounds. The look is `art/shaders/` and one `.blend`, and
`HudSkin.font()` takes Godot's built-in. So the licensing pass is an `ATTRIBUTIONS.md` carrying
the engine's MIT notice, and it is done.

#### Gatekeeper is the item that eats the evening

The obvious checklist for this milestone is a Windows checklist — a path with spaces, a non-admin
account, Program Files. None of those are the target. On macOS the equivalent is **quarantine**:
an unsigned or ad-hoc-signed `.app` that arrives by AirDrop, browser or Messages gets the
attribute, and recent macOS refuses to open it outright — the old right-click-to-open bypass is
gone, so the tester has to find Privacy & Security and choose Open Anyway.

For an alpha of one the dodge is to **transfer by a channel that does not set the attribute** —
`rsync`, `scp`, a USB stick — rather than to buy a certificate. Developer ID signing and
notarization is $99/yr and it buys nothing until the build goes to somebody you cannot text.

Also Mac-shaped, and each a one-line decision in the export preset: universal versus `arm64`, and
a minimum macOS version. The one genuinely uncertain item is **the compute pass**:
`pixel_edges_effect.gd` dispatches through `RenderingDevice`, and a compute shader is exactly the
thing that behaves differently on another GPU. It gets verified on the target machine, not here.

> **The HUD already survives the resolution question, which was the surprise.** `HudSkin` is
> written as proportions against a 1280×720 `REFERENCE` and multiplied by `scale_for`, and
> `contextual_hint.gd` and `match_hud.gd` both go through it — so a Retina panel scales the
> furniture rather than halving it. What does *not* scale by construction is the pixel pass,
> whose entire look is a function of framebuffer size. Check it at 2×; do not assume it.

#### The audits cannot run against the binary, and saying so is the point

The instinct is "run the existing audits against the exact release build". They cannot: exported
release templates do not take `--script`, so `tunnel_audit.gd`, `match_audit.gd` and
`cheese_audit.gd` only ever run against the project. The honest procedure is to **run them on the
same tagged commit the export is built from**, then smoke-test the `.app` by hand — because a
build that inherits confidence the audits did not actually give it is the failure mode this whole
document keeps warning about.

The corresponding gap is that **one playtest produces one set of evidence and then it is gone**.
File logging goes on, a screenshot key gets bound, and both locations get written down, or the
report is "it broke at some point" and the evening bought nothing.

#### Dev tooling that is actually reachable

`tools/` is all `--script` runners a release export never reaches, and `greybox.tscn` is an
export-filter line. But `look_panel.gd` is **a live shader-tuning slider panel bound to F1 and
wired into `arena.tscn`**, and F1 is a key people press. It goes behind `OS.is_debug_build()`.

#### In progress — a game you can enter and leave (landed)

`title.tscn` is the main scene now; `arena.tscn` is somewhere you go. `routes.gd` owns both moves
and exists for M7 rather than for the title screen — joining a server, leaving a match and being
handed back to a lobby are all "swap the scene under the player", and until this milestone that had
**never once happened in this project**. Play sits where Host and Join will sit.

`pause_menu.gd` freezes the tree and keeps itself running (`PROCESS_MODE_WHEN_PAUSED`), which is the
whole trick — the pause has to stop the sim rather than hide it, or a tester who steps away comes
back scruffed. `settings.gd` persists fullscreen to `user://settings.cfg`, deliberately as a static
class and not an autoload. Both menus are built in code, like `look_panel.gd`, because a column of
buttons is a hundred lines of unreadable scene diff. `menu_skin.gd` is a Theme rather than
`HudSkin`'s immediate-mode drawing, and its header argues why that inverts here: a menu is static,
is entirely interaction, and has a container doing its layout.

**`controls_panel.gd` reads the live `InputMap` instead of a list of strings**, so what lives in it
is order, names and grouping and nothing else. It also **fails loud**: `_unlisted()` diffs the
actions it groups against the actions that exist and draws anything ungrouped at the bottom under
its raw name. A new binding shows up ugly rather than absent, which is the right way round — the
milestone's question is whether somebody can play without you in the room, and a control that
silently never reaches the controls screen is the one failure that looks like success.

#### In progress — the build keeps its own evidence (landed)

The gap named above, closed. File logging is on, **P takes a screenshot**, and the shots land in
`user://screenshots/` — next to Godot's own `user://logs/`, so what comes back from a playtest is
**one folder to zip** rather than two places to go looking. The controls sheet names that folder on
screen, which is where you find out before pressing the key rather than after.

- **P, and not F2, and that is a Mac decision rather than a taste one.** macOS maps the top row to
  brightness and volume unless the tester has enabled "Use F1, F2, etc. as standard function keys" —
  off by default — so F2 on somebody else's machine dims their display and photographs nothing.
  Survivable for `look_panel` on F1, which is dev-only and never leaves this machine; not survivable
  for the one key whose whole job is to work in a stranger's hands on the first press.
- **An autoload, reversing `settings.gd`'s argument on purpose.** That file says two keys read on
  demand are a static function and an autoload would be "a node in every scene tree for the sake of
  a boolean". Both halves invert here: this has to *be* a node in every tree, and it has to survive
  `change_scene`, because the title screen, the controls sheet and the match are three scenes and
  all three are worth photographing.

> **The probe caught a bug that destroyed half the evidence and reported success while doing it.**
> The filename was a timestamp, the system clock reads to the second, and a tester photographing a
> thing from two angles does it in well under one — so the second shot silently overwrote the first.
> The key worked, the toast confirmed, a file existed. `tools/screenshot_probe.gd` asserts the
> *artefact* rather than the call: a file that did not exist before exists after, it decodes at the
> window's size, and it has more than one colour in it — because a blank capture is the failure that
> writes a perfectly valid file. It also asserts the toast is **not in its own successor**, verified
> by deleting the dismissal and watching that one assertion fail.

> **`user://logs/` is not `~/Library/Logs/Godot/`, and this file said otherwise.** The latter is
> where the *editor* keeps its log. A milestone whose deliverable is a bug report cannot name the
> wrong folder, so it was checked against the engine rather than remembered.

#### In progress — the export preset (landed; the build itself is not)

`export_presets.cfg` exists, validates, and **excludes `tools/*` and `scenes/maps/greybox.tscn`** —
the export-filter line this plan already promised. **Universal rather than `arm64`**, because the
one thing this milestone is buying is that the build opens on a machine we cannot inspect, and an
architecture guess is a whole class of "it doesn't open" for a few dozen megabytes. Minimum macOS
stays at the engine defaults (10.13 / 11.00), and signing is **ad-hoc** — Developer ID is $99/yr and
buys nothing until the build goes to somebody you cannot text.

> **The exporter refuses arm64 or universal outright without ETC2 ASTC**, which is how the setting
> was found: not as a texture-quality choice but as a hard configuration error with the template
> error beside it. `rendering/textures/vram_compression/import_etc2_astc` is on, and stated in
> `project.godot` with the reason, because it looks like a rendering preference and is not one.

> **`--export-pack` needs no export template, and that is worth knowing.** The section above is
> right that the *audits* can never run against a release build. The **packaging** is a different
> question and does not have to wait for a 1 GB download: `--export-pack` writes the `.pck` alone,
> and the filter was checked against the real artefact rather than against the config file — zero
> `res://tools/` entries, no `greybox.tscn`, and 65 script paths still present, because "excluded
> everything" and "excluded nothing" both pass a filter you only read. 9.3 MB.

`ATTRIBUTIONS.md` is written and the fifteen-minute estimate held. It records that the repo contains
no third-party assets — **verified rather than asserted**, by searching for fonts, audio and
`addons/` rather than by remembering — and carries the engine's MIT notice. The 102 third-party
components Godot bundles are *not* copied in: that list goes stale the first time the engine is
updated, and the engine already answers it at runtime through `Engine.get_copyright_info()`.

#### In progress — the first `.app`, and what building one taught (landed)

176 MB, universal (`x86_64 arm64`), ad-hoc signed, `com.jnsndlr.codenamemouse`. It boots: Metal 4.0
Forward+, 760 rocks, 88,806 grass blades, 14 boulders, 6 caches and a 361-polygon navmesh, into a
running match, with **no errors** — which is also the compute pass answering for itself, since a
`RenderingDevice` shader that failed to compile would say so loudly.

> **`user://` shipped to the wrong folder, and only building the thing could show that.** The
> default puts an exported app's data in `~/Library/Application Support/Godot/app_userdata/`, so
> the evidence this milestone exists to collect landed under a directory named after an engine the
> tester does not have installed and has never heard of — and mixed the shipped build's log in with
> every editor run. `use_custom_user_dir` moves it to `~/Library/Application Support/Codename
> Mouse/`. **Nothing in the project could have caught this**: in the editor the path is
> `app_userdata` too and looks entirely reasonable, because in the editor it *is*.

> **The log now says which build it came from.** The engine writes its own version and renderer
> line; what it cannot know is the *game's* version, which is the number a bug report has to carry.
> A one-line banner adds that plus the GPU, the resolution, the date, and whether it is a debug or
> release build. That last field is worth having twice over — it is how the dev-tooling gate got
> verified rather than assumed, since `release build` in the log **is** `OS.is_debug_build()`
> returning false, which is the exact condition `look_panel.gd` frees itself on.

> **A force-quit loses the log's tail, and this cost an hour of chasing.** Four consecutive runs
> produced a zero-byte log and looked like file logging silently not working in a release build.
> It was `pkill` — Godot's file logger buffers, and SIGTERM takes the buffer with it. Run to a
> clean exit, everything is there. Errors and warnings are not affected. Worth knowing before
> reading a tester's empty log as evidence of anything: **ask how they closed it.** `--quit-after`
> works in release templates, which is what pinned it down and is the way to smoke-test one.

**Still open: the part that needs hands.** Everything above was verified from a terminal, which
cannot press a key or see the screen. The pause menu, fullscreen, the screenshot key in the shipped
build, the look at 2× on a Retina panel, and Gatekeeper's opinion of the bundle after it has
travelled — all of those are a person sitting in front of it, and then the milestone's real
question: a friend, another Mac, a full match, and their log file.

#### The web build is not part of this, and here is the number

Self-hosting is genuinely free and genuinely easy — a directory of static files on Cloudflare
Pages, with `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` set so the threaded
build boots. The hosting was never the obstacle. **The renderer is.** Godot's web export runs
Compatibility only, Compatibility has no `RenderingDevice`, and `PixelEdgesEffect` is a
`CompositorEffect` built on one — so the pass that *is* this game's look cannot run in a browser
at all. Its own class comment records that the fragment-shader version was tried and abandoned,
because a full-screen quad in the transparent queue erased anything translucent, which is the
mouse's grass concealment.

So web is not a build target, it is a rendering decision, and it stays at M9 where §"Tech
decisions" already put it. M0's cube loaded in a browser; nothing since M2.5 would.

---

### M7 — Real multiplayer (1–2 weeks)

**Question:** does it survive contact with a second human?

- `NetTransport` + `ENetTransport`, listen server, server-authoritative
- Client interpolation; prediction only if it feels bad without
- Bots fill empty slots

**Done when:** you and a friend play a full match over the internet and it's playable.
Not perfect — playable.

#### The survey — what six milestones of "secretly netcode decisions" actually bought

Worth doing before any of it, because the answer changes the size of the milestone. The
architecture notes above made promises in week one; this is the audit of which ones held.

**Held, and they are the expensive ones:**

- **`Mouse._control(delta)` is already the driver seam.** `Player` overrides it and reads the
  keyboard; `Bot` overrides it and reads the AI. A third override that reads a replicated input
  frame slots in beside them **without the base class changing**. This is the single most
  valuable thing in the codebase for M7 — the thing most projects rewrite is already a two-line
  virtual with two implementations.
- **`MatchDirector` is already the sim.** Every rule that matters — pickup, capture, scruff,
  respawn, the whole cheese loop — resolves in one `_physics_process` on one node that owns the
  state. That *is* the server tick. It does not need to be found and gathered from nine places
  first, which is the usual week-one tax.
- **Per-crew knowledge is already stored per crew.** `tunnel_network.gd` keeps `_known`,
  `_tunnel_known` and `_shaft_known` as team bit masks, and `spotting.gd` keeps a contact book
  per side. The hidden-information pillar does *not* need retrofitting — filtering is a
  serialization concern over data that is already partitioned. The plan warned that retrofitting
  this would be painful; M5 built it correctly instead.
- **The state payload is genuinely tiny.** Eight mice, two banners, a score, two cheese counters,
  and dug cells as discrete `(plane, cell)` messages. 4v4 and grid tunnels were chosen for this
  and they deliver.

**Did not hold, and these are the actual work:**

- **Input is read where it is used, not captured as data.** They read `Input` *at the moment of
  acting*, which is the thing that has to change: an intent has to become a value that can travel.

  > **Re-counted at the start of M7, and the survey was wrong.** It said three files touched
  > `Input.`, two of them gameplay. It is **six gameplay files**, in two different shapes, and the
  > shapes matter more than the count:
  >
  > | File | How it reads | Actions |
  > |---|---|---|
  > | [`player.gd`](scripts/player/player.gd) | polls `Input.` | move, attack, scurry, slow, sprint |
  > | [`dig_controller.gd`](scripts/tunnels/dig_controller.gd) | polls `Input.` | dig, burrow, shaft up/down |
  > | [`cave_in.gd`](scripts/classes/cave_in.gd) | `_unhandled_input` | ability |
  > | [`sonar.gd`](scripts/classes/sonar.gd) | `_unhandled_input` | ability |
  > | [`barricade.gd`](scripts/classes/barricade.gd) | `_unhandled_input` | barricade |
  > | [`class_swap.gd`](scripts/classes/class_swap.gd) | `_unhandled_input` | swap_class |
  >
  > The four ability files arrived with M4 and M5, *after* the survey was written, and each one
  > subscribed to the event stream directly because that was the cheapest thing to do at the time
  > and nothing was wrong with it. **Four of six are the event-driven shape**, which the survey did
  > not anticipate at all: a polled read becomes "read the frame instead", but an
  > `_unhandled_input` handler has to stop being an input handler entirely. `camera_rig.gd` is the
  > seventh and stays local forever, along with the menus and the screenshot key.
  >
  > The general lesson is the one this document keeps relearning: **a survey is a measurement, and
  > measurements go stale.** This one was taken before two milestones landed on the exact surface
  > it was measuring.
- **Actions call the rules directly.** `player.gd` calls `director.try_scurry(self)`;
  `class_swap.gd` acts on `_unhandled_input`; `dig_controller.gd` drives the network on a held
  button. On a client every one of those is a **request**, not an act. This is the same edit
  repeated four or five times, and it is the edit that makes cheating structurally impossible
  rather than merely discouraged.
- **"The player" is singular, and this is the survey's second bad count.** It said eleven places,
  "all but one in `scripts/ui/`", i.e. a presentation question with a different answer per client.
  The real figure is **31 references across 11 files, and only three of those files are
  `scripts/ui/`** — `class_bar.gd`, `contextual_hint.gd`, `depth_indicator.gd`. The rest are
  gameplay: the four ability scripts, `dig_controller.gd`, `fall_guard.gd`, `depth_focus.gd` and
  the director itself.

  That reclassification is the important part, not the number. "Whose eyes am I behind" really is
  presentation and really does become `local_player()`. **"Which mouse is this ability attached
  to" is not the same question** — it is a rule about an actor, it has to resolve on the server for
  every seat including bots, and answering it with "the player" is precisely the assumption that
  breaks the moment there are two. The three UI files are cheap; the eight gameplay ones are the
  same edit as making actions into requests, and should be done in the same pass rather than
  counted as a separate cheap one.
- **Bots assume they are on the machine that owns the world.** `_spawn_bots` already does the
  right shape — the player takes blue seat 0, bots fill the rest — but bots must run on the
  server only, and `crew_size` becomes *seats minus humans* rather than a constant.

#### The shape of the work

1. **`NetTransport` + `ENetTransport`.** The wrapper the architecture notes asked for, so the
   browser question stays open. A day, and it is the first day.
2. **Input becomes a frame.** A small struct — wish direction, aim point, and a bitfield of
   pressed/just-pressed actions — produced by a local capture node and consumed by
   `Mouse._control`. Single-player then runs through the identical path, which is what stops the
   networked path from being the one nobody tests.
3. **Seats, not scenes.** A seat is a team, an index, and an occupant that is either a peer id or
   a bot. Joining takes a seat; leaving hands it back to a bot mid-match. `SEATS` already exists
   and already carries class and role.
4. **State out at 30Hz.** Mice as transform + a small state byte; banners, score and cheese on
   change; tunnel cells as discrete events. Clients interpolate between snapshots.
5. **Per-crew filtering at the serializer.** The masks exist; the rule is that the filter lives
   where the packet is built and never anywhere else, so there is exactly one place to audit for
   "did we just send them the enemy's floor plan".
6. **Prediction only if it hurts.** Deferred on purpose. Displacement-over-damage, projectiles
   over hitscan and no crits were all chosen so that naive interpolation is survivable — find out
   whether it is before spending a week on reconciliation.

#### In progress — the wire (landed)

Step 1 is done. [`net_transport.gd`](scripts/net/net_transport.gd) is the interface the *Tech
decisions* section has been promising since week one, and
[`enet_transport.gd`](scripts/net/enet_transport.gd) is its only implementation. Nothing above this
layer will ever name ENet, which is the entire point: whether this is a web build is an M9 question,
and the price of keeping it open is this file.

- **The interface is shaped like `MultiplayerPeer`, deliberately.** All three candidate backends
  are `MultiplayerPeer` subclasses with identical packet APIs, so an interface in that shape makes
  the swap genuinely one class rather than aspirationally one class.
- **Godot's RPCs and `MultiplayerSynchronizer` are not used, for a reason specific to this game.**
  Every client is owed a *different* payload — that is M5's pillar, and step 5 below says the filter
  lives in one place so there is one place to audit. A synchronizer replicates a property to
  everyone by construction; making it lie to one peer is fighting the tool.
- **`OFFLINE` is a mode, not an error.** `is_server()` is true offline, so a single-player match
  takes the same branch a host does. That is what stops the authoritative path being the one nobody
  plays.
- **The roster is kept by hand, because the peer does not keep one.** `get_peers()` is a
  `MultiplayerAPI` method, not a `MultiplayerPeer` one — assumed otherwise, and the audit said no.

> **`tools/net_audit.gd` is written BEFORE anything consumes the transport**, which reverses this
> project's usual order and is the right way round here: a wrapper with one implementation and no
> callers is at its least trustworthy, and by the time it has callers, five files have been written
> against whatever it actually does. It stands up a real server and **two** real clients on a real
> socket. Two, not one — with a single client every packet came from the only peer there is, so
> attribution is right by luck.

> **It caught two bugs on its first run, and the second is the one worth remembering.**
> `get_peers()` not existing was a five-minute fix. The other: `_ready` called `set_process(false)`
> unconditionally, and `_ready` does **not** run inside `add_child` when the parent is not yet in
> the tree — it is deferred a frame. So `add_child(t); t.host(port)` turned the pump on and then
> `_ready` turned it back off. The socket opened, the client connected, the status read CONNECTED,
> and **nothing was ever polled or delivered.** A transport that is silently deaf, in the most
> natural three-line call sequence there is, and indistinguishable from a network problem from
> above. It is now derived (`set_process(_peer != null)`) rather than set.

> **The attribution check was verified by breaking it**, by swapping `get_packet_peer` after
> `get_packet` — which pops the packet and then reports the *next* sender. Both attribution
> assertions fail and **every other check still passes**, which is the argument for two clients
> stated as a result rather than as a worry. In a match that bug reads as one player's inputs
> driving another player's mouse: a gameplay bug that isn't one.

#### In progress — intent became a value (landed)

Step 2 is done. [`input_frame.gd`](scripts/net/input_frame.gd) is one tick of what a player meant:
`move`, `aim_point`, `look`, and two twelve-bit masks for held and pressed. **Six gameplay files
read `Input` before this and one does now** — `input_capture.gd`, which is the only place in the
game that asks a keyboard anything on a gameplay path. `camera_rig.gd`, the menus and the
screenshot key still do and always will; they are presentation and permanently local.

The four ability scripts stopped being input handlers, which was the half the survey missed.
`_unhandled_input` fires on *this* machine's event stream and a server has none for a peer three
hundred miles away, so there was no version of those four that could have worked over a wire.

- **Two fields are resolved rather than raw**, and that is the design decision inside the type.
  `aim_point` is a world position, not a cursor; `look` is a direction, not a stick deflection.
  Both depend on the camera, the camera is permanently local, and **a frame carrying screen
  coordinates is a frame the server cannot interpret**.
- **Captured lazily, at most once per physics tick.** Six nodes read the intent and they are spread
  across the scene tree with their own `_physics_process`. Capturing inside `_control` would hand
  last tick's frame to whichever of them Godot happens to tick first — a one-frame lag that is
  invisible in single-player, changes with scene layout, and would have been blamed on the network
  later. Keyed on the frame counter, nobody has to be ordered.
- **The abilities read on the physics tick, never on an idle one.** The pressed bits are latched
  for the whole tick, and idle frames outnumber physics frames on a fast display — so the same
  keypress would fire a cave-in twice at 120Hz and once at 60Hz.
- **`Player.drive()` marks the tick as spoken for**, which is what stops a lazily-capturing player
  overwriting a handed-in frame the instant anything asks. Not a test seam: it is the shape a
  replay needs, and the shape a host needs the day it drives a seat whose player has dropped.

> **Naming the enum `Button` silently retyped every call site.** `Button` is a Godot built-in — the
> UI node — so `func is_pressed(button: Button)` typed the parameter as *that class* rather than as
> the enum, and eight call sites failed with "argument 1 should be Button but is
> `InputFrame.Button`", which reads like a compiler bug and is not one. It is `Action` now. The
> trap generalises: `Key`, `MouseButton`, `JoyButton` and `Error` are all taken too, and an enum
> named after any of them fails this way rather than by saying the name is in use.

> **`tools/input_audit.gd` asserts the two claims nothing else can see:** that every field survives
> `to_bytes`/`from_bytes` — the other suites build frames in-process, so a serializer that dropped
> `look` would pass all nineteen match invariants and then disable pad aiming for every remote
> player on the first packet — and that a driven frame actually drives.

> **Its first version could not fail, which is the third time this project has caught that and the
> first time it was caused by another assertion.** The driving check passed with the whole
> mechanism deleted, because the "an untouched keyboard produces nothing" line immediately above it
> called `input()` and *captured the tick* — so the driven frame was returned by the cache
> regardless. The fix is one `await physics_frame` between them, and the lesson is new: it was not
> a weak assertion or a subject arranged so the rule could not bite. **It was a good assertion
> whose side effect disarmed the next one.** Verified by breaking `drive` and watching two lines
> fail.

> **`Input.action_press` cannot be used to drive a test**, which is worth writing down because it
> is the obvious approach. Its pressed-frame bookkeeping does not line up with `await
> physics_frame`, so `is_action_just_pressed` is already false by the time the next physics frame
> runs — measured, not assumed. `match_audit` therefore hands mice frames directly, which also
> replaced its ten `set("_aim_point", ...)` pokes: aim travels in the frame now, and a frame driven
> earlier in the same tick is still what `input()` returns, so setting the private field alone read
> back as whatever the previous check had aimed at.

#### In progress — seats (landed)

Step 3 is done. [`seats.gd`](scripts/net/seats.gd) is ten chairs — five a crew — each holding
either a peer id or a bot, and [`net_session.gd`](scripts/net/net_session.gd) is the one object
that owns a transport and a roster. `MatchDirector` asks it questions; nothing else in the game has
heard of a socket.

- **Occupancy is a table now, not an emergent property of a `for` loop.** It used to be
  `range(first, crew_size)` with `first` being 1 when a player happened to exist — a perfectly good
  line that cannot answer *"seat 3 just disconnected mid-match, whose bot is that now"*.
- **The occupant is a peer id and `BOT` is zero**, because `NetTransport` already promises ids start
  at 1. So "is this seat human" is `> 0` rather than a parallel boolean nobody keeps in step — and
  **offline needs no special case at all**: it is the same table with peer 1 in blue seat 0 and
  bots everywhere else. Single player is a listen server with no clients. The phrase "single
  player" does not appear in the director and should not start now.
- **Joiners balance by human count, not by free seats.** Every seat is always occupied by
  somebody, so "which crew has room" is meaningless; the question is which has fewer *people*,
  since a bot is not the opponent anyone came for.
- **Leaving hands the chair to a bot and the seat never disappears.** The alternative is that
  quitting hands your opponents a numbers advantage — a crew that loses a human must not lose a
  mouse.

> **`crew_size` would have become a dial that does nothing**, which is the worst kind of broken
> setting because it still looks adjustable. The roster was built to its own default of five, the
> director asks `roster.crew_size()`, and the `@export` the README tells you to fiddle with would
> have been silently ignored. `ensure_crew_size` reconciles them, and refuses once anybody else is
> seated — resizing crews mid-match either strands a peer in a chair that no longer exists or
> invents chairs nobody is in.

**`--host [port]` and `--join <address[:port]>` exist before any Host button**, and that is a
testability decision rather than a shortcut. Checkpoint 1 is *two windows on one machine*; with
flags a tool can launch both and assert what happened, and with buttons only it can be demonstrated
and never checked. The plan's own warning about this milestone is that the failures that matter
still look right from inside a match.

> **`tools/seat_audit.gd` launches two real Godot processes** and reads what each concluded about
> its own seating. Slower and uglier than anything else in `tools/`, and the only kind of test that
> can see the failures this step can have: a client that connects but is never seated, a host that
> seats it and spawns a bot in the same chair, a disconnect that deletes the chair instead of
> handing it over. Verified by breaking the balancing — five assertions fail, and **the socket half
> catches it as well as the table half**, which is the argument for the expensive test arriving as
> a result rather than as a hope.

> **`--quit-after` counts FRAMES, not seconds, and that cost the first run of the audit.** At 1200
> the host had already exited before the client was launched twenty-five seconds later, and the
> symptom was an unconnectable socket — which reads as a broken transport rather than as a process
> that is no longer running.

> **And then the audit found a real one: quitting behaved exactly like crashing.** The departure
> checks failed once the waits were tightened, because the test killed its client outright and ENet
> only learns about a hard kill when the peer timeout expires — five to thirty seconds, during
> which the crew is a mouse short and the chair is still nominally occupied. That is *correct* for
> a crash and was hiding the fact that the ordinary case, a person quitting, was no better.
> `NetSession._exit_tree` now closes the socket, so leaving says so and the host reseats at once.
> The audit was changed to let its client end itself rather than be killed, which is both the case
> worth asserting and the reason the fix exists.

> **Two smaller traps, both about evidence.** `OS.create_process` hands back no pipe and both
> processes share one `user://logs/` that they would clobber, hence `--audit-log <path>`; and the
> command line is acted on only *after* the whole line is parsed, because `--audit-log` may follow
> `--host` and starting the socket first would send the interesting lines to stdout alone. Also,
> **`timeout` discards a windowed run's stdout** — the same SIGTERM-loses-the-buffer finding M6.5
> made about the log file, met again from the other direction, and worth remembering as a property
> of the tooling rather than of either subsystem.

#### In progress — mice on a wire (landed)

Step 4's first half is done, and it is the first half of this milestone a person can look at.
[`snapshot.gd`](scripts/net/snapshot.gd) is where every mouse is thirty times a second,
[`net_message.gd`](scripts/net/net_message.gd) is what may travel and how reliably, and
[`net_match.gd`](scripts/net/net_match.gd) is the two ends of the pipe. Two windows, one seat each,
bots in the other eight — checkpoints 1 and 2, met.

Score, cheese, health and the tunnel network are **not** in it. That is the "on change" half and
step 5's filtered half; the file says so out loud rather than shipping a stub that looks like a
feature.

- **The snapshot is seat-indexed, and that is what step 3 bought.** There are no spawn messages in
  this protocol and there do not need to be: the roster says which chairs exist, so a client builds
  its ten mice from the seating and every packet afterwards only says *"chair 7 is here now"*.
  Spawn/despawn replication is one of the fiddliest parts of any netcode and this design does not
  have one. A key is `team * crew_size + seat`, one byte.
- **A puppet is a flag on `Mouse`, not a subclass.** What changes is one branch in the tick; the
  model, the grass bend, the banner and the swing arc all have to keep working identically, and a
  `PuppetMouse` would have to re-inherit them from whichever of `Player` or `Bot` it was replacing.
  Authority also *changes mid-match* — somebody disconnects and a bot takes their chair — which a
  class cannot do and a flag can.
- **Snapshots are unreliable and inputs are reliable, and both are decisions.** A resent snapshot
  describes a world that has moved on and holds the queue up while doing so; a lost keypress is a
  swing that never happened. The arguable one is input, which can head-of-line block — the trigger
  to revisit is a playtest with real loss, not a hunch.
- **The seat lookup is the security boundary.** A packet cannot name the mouse it wants to drive;
  it drives whichever chair its sender is sitting in. Cheating becomes structurally impossible
  rather than merely discouraged, and it costs one line.
- **The swing replicates as an edge, not a state.** Assigning a bool at 30Hz would restart the arc
  a dozen times across one swipe. The damage is not replicated at all and must not be — it resolved
  on the server, and the client is drawing what already happened.

> **A host logging 285 inputs a second while the mouse stood perfectly still.** The seat held a
> `Bot`, and a bot's `_control` reads a navigation path — so a received frame arrived, was applied,
> and did nothing. Every count on both ends was healthy. A seat with a human in it gets a `Player`
> marked remote instead, so a networked player runs the *identical* code a local one does, stamina
> and speed ladder included. **The lesson is the general one for this milestone**: the pipe moving
> bytes and the pipe moving the right mouse are different claims that look the same from inside.

> **A client that guessed its seat mirrored the host.** The director's fallback is blue seat 0,
> which is right for a host and wrong for everybody else, and registering that guess made
> `adopt_seating` see a table already filled and decline to correct it. The client then listened to
> blue 0's poses for the whole match: **its own body stood exactly where the host's was standing**
> while its keys moved a mouse somewhere else entirely. It reads as "no input is getting through"
> and is nothing of the kind.

> **`as Mouse` throws on a freed object, so three guards were written the right way round and
> evaluated the wrong way round.** `is_instance_valid(mouse)` cannot save a cast that already
> happened on the line above it. Nothing had ever exercised it: through M6 a mouse was scruffed and
> respawned but never *freed*, and M7 frees one every time somebody joins and a bot gives up its
> chair — the first mid-match free in the game's history. It turned up in `spotting.gd`,
> `vitals.gd` and the director's own seat lookup, which is asked ten times per snapshot.

> **Being online and being through the door are different, and sending into the gap costs one ENet
> error per physics tick.** `join()` returns the instant the socket exists; the handshake finishes
> later, and on a cold start "later" is several seconds of arena loading. Hence `is_established()`
> alongside `is_connected_up()` — the default is honest about not knowing, and `ENetTransport`
> overrides it because it can tell.

> **`tools/replication_audit.gd` is the seat audit's question one step on**: two real processes, in
> a *real arena*, one of them driven by `--autopilot` — the multiplayer equivalent of
> `bot_soak.gd`, and there for the same reason. A headless client has no keyboard, so without it
> every automated test watches a mouse stand still and cannot tell a working input path from a
> broken one. Both ends log **positions**, not just counts, and the tool compares the two logs:
> that the client's mouse went somewhere, that it is not the host's mouse, that nobody drove the
> host's mouse, and that the two ends agree which mouse is whose. Compared as averages rather than
> instant-for-instant, because the logs are written on unsynchronised five-second timers in
> different processes — a limit worth stating, since it is the reason the tolerance is metres.

> **And it found one on its first honest run: a client that connects before it enters a match is
> never told its seat.** The seating was sent when the roster changed, which is a moment on the
> *server's* clock — a client sitting on the title screen, or one that quit to the menu and came
> back, has no arena and nothing listening, so the one message telling it who it is went into a
> process that could not use it. **Snapshots then arrived at a healthy rate and zero of them were
> applied**, while the host walked a mouse around a yard its owner could not see. There is a
> `HELLO` now, sent until answered.

> **The first version of the audit passed, and it passed by luck.** A client launched straight into
> a match blocks its own main loop long enough loading the arena that the seating always arrives
> afterwards. `--play [seconds]` exists so the gap between connecting and entering can be made to
> happen on purpose — the delay is not a convenience, it is the only reason the suite tests a
> design rather than a coincidence. This is the fourth time this project has caught a test that
> could not fail, and the first time the cause was **timing that happened to be favourable**.

#### In progress — a match, not just mice (landed)

Step 4's second half, and checkpoint 3. [`match_state.gd`](scripts/net/match_state.gd) carries
everything on the HUD that is not a mouse — score, both cheese pools, the clock, the verdict, ten
respawn countdowns and both banners — and health rides in the pose, where it belongs, because it
moves every tick and belongs to a mouse.

**No HUD file was touched, and that is the milestone's survey being right twice.** `score_bug`,
`match_hud` and `roster` ask `MatchDirector` for these numbers; a client whose director holds the
right numbers therefore has a correct HUD, and the wire writes them through one deliberate door
(`adopt_state`) rather than through a setter per field.

- **The plan said "on change" and it is periodic instead**, which is a reversal worth defending.
  The instinct was bandwidth, and the numbers do not support it: the entire scoreboard is smaller
  than one snapshot, and snapshots go out thirty times a second. What periodic buys is that it
  **cannot get stuck wrong** — an on-change scheme is wrong for the rest of the match if a change
  is ever missed, if a listener attaches late, or if some new rule mutates a field without
  announcing it, and a full state four times a second heals all three by existing. Idempotent beats
  incremental until bandwidth objects, and here it has nothing to say.
- **The `CARRYING` flag was deleted, because it was the same fact twice.** `MatchState` says which
  banner is on whose head — strictly more information, since it also says *which* — and two
  encodings of one fact are two things that can disagree. The client sets up the real carry
  relationship instead, so `is_carrying()` is true on a puppet for the ordinary reason and the
  grass camouflage and the roster keep working without hearing that a network exists.
- **A puppet banner still runs its clock and never acts on it.** Both crews are making a decision
  off the twenty-second return countdown, so it has to keep counting on every machine; what a
  client must not do is *send the banner home* when it reaches zero. It would agree with the server
  for exactly as long as the two clocks did.
- **A puppet does not heal.** Health arrives with every pose, and a local regeneration on top of it
  is a second opinion: the bar creeps up between snapshots and jerks back down on each one, which
  reads as packet loss and is a client quietly disagreeing about how hurt somebody is.
- **The feed travels as text, on a condition.** Every event in the game today is public — a score,
  a steal, a scruff, a spend, a whistle — so text costs a dozen lines a match and keeps the wording
  in one place. The moment an event says something only one crew should know, it becomes a leak
  with a broadcast in front of it and has to move behind step 5's filter.
- **Bots Scurry now, which the risk list called blocking and was right to.** They spend on the two
  moments the ranking already cares about: getting away with their banner, and catching whoever has
  yours. There is deliberately no "hurt, break off" rule — nothing in the ranking retreats, so a
  burst bought to escape would be spent closing the last metre on the thing that is killing you.
  It is asked of the director exactly as a key press is, so there is no AI-flavoured Scurry with
  its own opinion about the ledger.

> **A parse error in the entire multiplayer match failed no suite.** `net_match.gd` was left with a
> call whose signature had changed under it; all five in-process suites passed. They build arenas,
> the arena's `NetMatch` node failed to load, Godot printed one line and carried on without it, and
> every invariant about tunnels and cheese and mice was still perfectly true. **Nothing in `tools/`
> had ever needed to assert that the code exists**, because until M7 every file was on a path some
> suite walked. `net_audit` now loads every scene and every script and asserts none of them is
> null — the dullest check in the project, and the only one that would have caught this.

> **Scenes before scripts, and the order is load-bearing.** `bot.gd` reaches `MatchDirector`, which
> preloads `bot.tscn`, which points back at `bot.gd`: an ordinary cycle the engine resolves quietly
> when the scene is what is being loaded and complains about when the script is. Walking the scenes
> first leaves them all in the cache. The alternative was a suite that printed a scary error while
> passing, which is its own kind of broken.

> **The audit's new checks were verified by deleting the broadcast**, and five of the seven failed
> — including the one that matters most: a client that is sent no scoreboard **sits at the full
> eight minutes forever** while the host counts down. The clock is the only field in that packet
> guaranteed to move, which is what makes an agreement check on it bite when an agreement check on
> the score does not.

> **Two of the seven passed while broken, and they are labelled in the file rather than deleted.**
> Nobody scores in twenty-five seconds of autopilot and nothing hits it, so score and health read
> the same on both ends whether or not a packet arrived. They stay because they catch a *different*
> failure — a field read at the wrong offset, which shows up as a score of 71 beside a perfectly
> sensible clock — and the comment says which failure each one is for. A check that cannot fail is
> only a lie when nobody has written down what it is doing there.

#### In progress — the earth, one crew at a time (landed)

Step 5, and checkpoint 4 — the one the risk register said could silently fail.
[`tunnel_view.gd`](scripts/net/tunnel_view.gd) is the filter, and it is the only place in the game
that decides what a client may know about the earth. `TUNNELS` is addressed to a
single client on purpose: **two clients on opposite crews are owed different worlds**, so there is
no packet that is correct for both of them. Barricades later reuse the same predicate and
addressed boundary in a complete-state payload.

- **The predicate already existed, and using it was the whole design.**
  `TunnelSight.knows(side, plane, cell)` was written at M5 for the minimap — "does this crew have
  this cell on its map at all, by either route", with the ownership rule folded in *so that neither
  the minimap nor an audit could forget it*. Writing a second, network-flavoured version of that
  question would have been building a way for the two to disagree, and on the day they disagreed
  the wire would have been the one that was wrong.
- **A client's network contains only what its crew has cut or can currently see, and that is not a
  reduced copy of the world — it is M5's pillar expressed as geometry.** It works visually for a
  reason that is not luck: `tunnel_sight.gd` defines line of sight as *every cell between here and
  there is open*, so the set a crew can see is very nearly the set it could have drawn anyway.
  What is missing was behind a bend, or behind earth.
- **The guard against a client cutting earth is on the network, not on the five things that cut
  it.** The dig controller, the cave-in, the barricade, a bot's digger and anybody taking a shaft
  all end up in the same three mutators, so refusing there is structural; guarding each caller is
  five chances to miss one and a sixth the day somebody adds a rule.
- **The fog closes, and that half is the one that is easy to leave out.** A client that keeps every
  cell it ever glimpsed ends up with a map more complete than the rules allow — a slow leak rather
  than a loud one, and nothing looks wrong while it happens. Cells are taken back when a crew stops
  being allowed to know them, through `forget_cell` rather than `collapse`, because forgetting a
  shaft you glimpsed has to work and collapsing one must not.
- **The plane moved into the pose**, packed into the spare bits of the flag byte. Without it a
  client's own mouse has no layer, and the cutaway shows a lawn to somebody standing three planes
  under it. Inferring it from the y it was sent would be wrong for the whole of a fall and for
  every frame of a shaft — the same distinction `mouse.gd` already carries a scar about.
- **Rock is never sent.** It is laid from `rock_seed` at startup, so both ends generate identical
  stone without a byte crossing the wire; only *who has run into it* is knowledge, and only
  knowledge is per-crew.

> **The leak check failed on its first run, and it was the check that was wrong.** Six cells the
> client held were not in the host's permitted set — and all six had been permitted earlier: red
> had glimpsed a corridor and the fog had closed over it in the five seconds between the client's
> last report and the host's. **The two processes were being compared as though their logs were
> simultaneous.** They report on their own timers and one started fourteen seconds before the
> other. `log_line` stamps wall-clock milliseconds now, and the audit compares the client's
> snapshot against what the host permitted *around that moment*. A false alarm on an invariant is
> worse than a missing one: it is the thing that gets the invariant relaxed.

> **Then it was verified by deleting the filter**, which is the only way to trust a check whose
> subject is invisible. One line — send every dug cell instead of every permitted one — and the
> audit named twelve of the leaked cells by coordinate and failed twice: once for the leak, once
> because a filter that sends everything never takes anything back.

> **`--autopilot` walks in a circle and cannot dig, so the earth in this test is bots' work.** Both
> crews field an Engineer, both cut corridors, and the suite refuses to pass if blue never cut
> anything red is forbidden — reporting *"the leak check had nothing to catch"* rather than a green
> tick. That is the same discipline as the two scoreboard checks that cannot fail: say what the run
> actually exercised.

> **What a client still cannot do is dig.** The dig controller, the cave-in, the barricade, the
> sonar and the class swap are arena-level singletons wired to `../Player` — *the* player, from
> when there was one — so a remote human's DIG bits arrive at a server with nothing to consume
> them. The intent has crossed the wire since step 2; what is missing is that these five are still
> the local player's controls rather than any mouse's. That is the next piece, and it is a
> refactor rather than a netcode problem.

#### In progress — any mouse's controls (landed)

The piece the note above named, and it was a refactor rather than a netcode problem exactly as
predicted. [`mouse_control.gd`](scripts/actors/mouse_control.gd) is the half the dig controller and
the four abilities have in common, [`mouse_controls.gd`](scripts/actors/mouse_controls.gd) is the
set, and `Player._ready` fits one. **A client can dig now**, and the audit that says so watched a
headless client sink a shaft, climb down it and open four cells of earth on a machine fifty
milliseconds away.

- **The two questions were one question, and separating them is the whole file.** `acts()` is
  *does this machine decide what happens to this mouse*; `watched()` is *is this the mouse this
  machine is looking at*. They had the same answer for six milestones because there was one player
  on one machine. A host now runs the rules for four people and draws a cursor for one; a client
  draws a cursor for a mouse whose rules resolve three hundred miles away. **Rules run where the
  simulation is, presentation runs where the eyes are** — and a remote player's refusal printed on
  the host's HUD is the same species of bug as their dig cursor lit in the host's yard.
- **A puppet runs its cooldowns and never acts on them.** Not prediction — the same shape
  checkpoint 3 already settled for the banner's return clock. Every check above the mutation is a
  rule both machines can evaluate off state both machines have, so the person pressing Q gets a
  HUD that greys out and a reason when it refuses. What they do not get is the hole in the ground.
- **The sonar's marks did not come with it, and that split is the interesting part.** The ability
  belongs to a Sneak; a mark is a scratch on the floor of the world. With one sonar per mouse a
  private `_marks` array would have meant an enemy could only rub out cant its own node happened
  to have drawn — so marks are read from the group they were already in.
- **Bots carry none of the five**, because a bot's input frame is always empty and five nodes that
  can never fire on six of ten mice is six mice of wasted tick. They reach the same rules by their
  own road, which is why `ClassSwap.allowed` was written static in the first place.
- **Class moved into the pose**, two bits of a flag byte that was already going out. Class was
  never replicated because it never changed — both ends build their ten mice from the same `SEATS`
  table — and the swap point being one of the five is precisely what breaks that. It has to arrive
  *with* the health rather than near it: health travels as a fraction of a per-class maximum, so a
  pose carrying a Sneak's ratio and a Brute's class reads as a mouse that just lost forty points.

> **A parse error failed no suite at checkpoint 3; this time a signature change failed no suite for
> two milestones.** `tunnel_audit.gd` drove the dig controller with `_update_dig(delta)`. Step 2
> gave that function a second parameter — the intent has to be a value that can travel — and
> nothing told the two callers. **A GDScript runtime error aborts the function it happens in and
> lets the caller carry on**, so the dig-flow and reveal checks stopped part way through, printed
> nothing, and the file went on announcing *"ALL INVARIANTS HOLD … plus dig flow … and reveal"*
> over two checks that had not run a single assertion. This is the fifth test-that-cannot-fail this
> project has caught and the cause is new every time: not a weak assertion, not a subject arranged
> so the rule could not bite, not favourable timing — **a caller left behind by a signature, in a
> suite whose failure mode is to go quiet.** There is a tripwire now: a check arms itself on entry
> and disarms at its own report line, and anything still armed is reported BROKEN.

> **The first version of the new "a client cannot cut earth" check was verified twice and passed
> the second time.** Deleting the network's guard failed it correctly. Deleting the *controller's*
> guard did not — and of course it did not: with the network still refusing, a controller that
> reaches for the earth and one that does not are indistinguishable from outside. **Two guards need
> two subjects.** The controller's is now asserted on the BAR rather than on the ground: a puppet
> whose hold completes sits at full and waits for the server's cut, where the alternative — call,
> be refused, zero — fills the bar twice during the round trip and reads as a dig that did not take.

> **`--autopilot` digs now, and getting it to took three wrong versions, each of which was a real
> property of the control rather than a quirk of the harness.** Aiming a metre along the facing
> lands on the boundary of the cell you are already standing in, and an already-dug cell is not a
> target. Rotating the aim once a second finishes nothing, because progress belongs to the tile you
> are *pointing at* — so does walking, which moves the cell the aim is measured from. And holding E
> while waiting for the pose that says "you are underground now" walks the mouse down the shaft and
> straight back up it, because E takes whichever shaft the cell has. A person holding that key
> learns all three in one corridor.

> **The leak check failed again, and again it was the check.** The grace window added at step 5
> handles a host picture that is a little *stale*; it does nothing for a host picture that does not
> exist. Both processes are killed at the same instant and the host starts fourteen seconds
> earlier, so its report timer is permanently out of phase and its log routinely ends a second or
> two *before* the client's — which makes everything the client legitimately learnt in that last
> second a cell nobody ever said it could have. Thirteen of them, named by coordinate, looking
> exactly like the thing the check exists for. The invariant is only asked where the two logs
> overlap now. **A false alarm on an invariant is worse than a missing one**, for the second time.

> **The cheese share of runtime replication is closed.** Every pile now travels as part of a small
> complete world picture: position, wedge count and visual spread, twice a second. Reconciliation
> makes spawning, merging, depletion and removal one idempotent operation, and means a lost packet
> or a client entering late heals without replaying events. `cheese_audit.gd` checks creation,
> update and removal; `replication_audit.gd` makes a drop before the client has an arena and proves
> it appears after the client enters.
>
> **The barricade share is closed too, behind the tunnel boundary rather than in public.** Each
> peer receives a complete picture only of barricades in cells `TunnelSight.knows` for its crew:
> plane, cell, owner seat, remaining hits and total hits. It also privately carries only the
> receiving player's standing count, preserving their three-rock budget when fog hides an old
> coordinate without disclosing enemy activity. A client replica carries the collider, seeded rock
> shape and damage shrink, but is removed from `Breakable.GROUP` and never blocks its puppet route
> graph. Placement, Brute hits and obstruction remain server decisions; loss, removal, cave-in,
> fog and late joining converge through the next full picture.
>
> The late-join audit exposed a terrain cursor bug beside it. `TunnelView` had remembered cells
> sent while a connected peer was still on the title screen, so its later arena was never offered
> them again. `HELLO` now means “this peer has an arena now”: it resets that peer's delivery cursor
> before the permitted earth is replayed. The audit creates a damaged red-owned rock and a
> blue-only control before the client arena exists, proves owner/hits arrive for the first, follows
> it through another damage stage and removal, and proves the second never crosses the visibility
> boundary.
>
> **Cant marks remain as the last runtime-spawned replication gap.**

#### Sequencing — five checkpoints, each playable

Ordered so that something is testable at every stage and the risky part is not last.

1. **Two windows on one machine, one seat each, no bots.** Movement and melee only. This is where
   the input-frame refactor lands and where it either holds or does not. **Met** — and it held:
   the frame refactor needed no revision, and every bug found at this checkpoint was about seating
   or about who owns a mouse, not about the intent type.
2. **Bots fill the empty seats.** Proves seat ownership and that the server is the only thing
   thinking. **Met** — ten mice, one simulation, and a client whose bots are pictures of bots.
   Except that they still do not Scurry, which the risk below says is now blocking and is right.
3. **The objective loop over the wire** — banner, capture, scruff, respawn, cheese. All of it is
   already in one node; this is mostly proving that. **Met, including the world caches**: the
   scoreboard is one message, the HUD needed no changes at all, and the caches are a separate
   complete public picture so authored and dropped piles converge after loss or a late join.
4. **Tunnels and the visibility filter.** The riskiest checkpoint, and deliberately not last:
   add an assertion that a client's received tunnel set is a subset of its own crew's mask, and
   run it in the audits. **Met** — the assertion exists, it is in `replication_audit.gd`, it is
   checked against `TunnelSight.knows` rather than against the sender's own record, and it has
   been verified by deleting the filter and watching it name the leaked cells. Digging *from* a
   client landed after it, as predicted, as a refactor of five singletons rather than anything to
   do with the wire — the suite now watches a headless client sink a shaft and open four cells.
   Barricade boulders now use the same visibility predicate in a complete per-peer picture, and
   the two-process suite proves a blue-only boulder is not leaked to its red client. What is left
   is runtime replication for cant marks.
5. **Over the internet, with a friend, for a full match.** The milestone's actual question.

#### Risks

- **The visibility filter is the one that can silently fail.** A leak looks like nothing at all
  from inside a match — the game plays fine and the pillar is gone. It needs an invariant in
  `tools/`, not a playtest. This is the same lesson `cheese_audit.gd` and `cache_layout_probe.gd`
  both taught at M6: the failures that matter here are the ones that still look right.
- **Bots not Scurrying is now blocking.** It was acceptable at M6, where the point was whether a
  human agonizes over a spend. M7 is about a *second human*, and a crew whose AI seats never
  spend cheese is a crew that plays the economy differently from the one across the yard. Fix it
  in checkpoint 2.
- **Listen-server host advantage** is real and unfixable at this scale. Name it, measure it, and
  decide whether it matters before building anything to hide it.
- **The scope trap is prediction.** Every deferred-prediction plan gets talked into it early by a
  single laggy playtest. The deferral is a decision already taken; reversing it needs evidence
  from checkpoint 5, not from checkpoint 1.

---

### M8 — Brute and the world (2 weeks)

**Question:** do the counterplay web and the PvE faction pay off?

Two experiments, added **separately** so you can tell which did what:

**8a — Brute:** collapse (planes 1–2), corking, Slam. Completes the counterplay web.
Does the Engineer actually start digging deeper in response? That behavioral change is
the proof the web works.

**8b — The world:** the Cat first, on a fixed schedule. Then the Crow. Does the match
get better when they show up — as threat *and* as respite?

**8c — Water, binary version:** flooded/not-flooded segments on a timer. Proves whether
water-as-a-threat is fun *before* building the flow simulation.

**Done when:** you have an honest verdict on each.

> **Flowing water is deliberately not here.** The full system (GDD §7 — sources, spread
> with noise, current vectors, breath meter, cascade through ramps, ride-the-current-to-a-
> ramp escapes) is a cellular automaton over the tunnel graph. It's tractable and it's the
> best set piece in the design, but it is a **post-M9 upgrade**. Build binary flooding
> first. If binary water isn't fun, flowing water won't rescue it.

---

### M9 — Decide what this is (open)

With M2–M8 answered, the real decisions become answerable: web or desktop, dedicated
server or not, Generalist and Juggernaut, more maps or better feel, and the first
non-capsule mouse.

---

## What we deliberately don't build yet

- Matchmaking, lobbies, parties — friends use a direct connect code
- Accounts, persistence, stats, leaderboards
- Anti-cheat beyond server authority and visibility filtering
- Multiple maps — one map, iterated, beats three mediocre ones
- Procedural map variation (GDD §8) — one hand-built layout until the systems are proven
- Free-form digging and free-angle placement — snapped chunks only
- **Flowing water** — binary flooding at M8c, flow simulation post-M9
- ~~**Tall grass bending** (GDD §8) — a shader problem, not a systems problem. Post-M9.~~
  **Reversed — it is M2.5**, ahead of the core loop. It is a systems problem: the bend is
  hidden information every class can produce and read, which makes it a mechanic, not a
  finish. Building the flag chase on bare ground and adding cover afterwards would mean
  tuning the chase twice.
- **Sneak camouflage shader** — placeholder transparency until then
- The Juggernaut and Generalist — M9 at the earliest
- Audio beyond crude placeholders
- Client prediction — until it demonstrably hurts

## A note on art

The docs say capsules through M8, and that's still right for **maps and props** — art
paralysis is a real risk and grey boxes keep you honest.

**One low-poly mouse is the exception, and it's worth making early.** Reasons:

- **It tests a real design question.** Pillar 4 says silhouettes must be readable at
  isometric distance. A capsule can't tell you whether that's true; a mouse can.
- **Class differentiation is silhouette + color + one prop**, TF2-style. Making one mouse
  and then scaling/tinting/hatting it covers all four classes cheaply.
- **Motivation matters on a fifteen-year project.** Seeing an actual mouse move around
  your yard is worth more than the hours it costs.

**Timebox it.** One mouse, ~500 tris, no rig at first (a static mesh that slides around is
fine at M1). Do not model four classes. Do not model props. If it takes more than an
evening, stop and go back to systems.

---

## Cost model

| Phase | Infrastructure | Cost |
|---|---|---|
| M0–M6 | Local only | **$0** |
| M7–M8 | Listen server, direct connect | **$0** |
| Post-M9, if there are players | 1× Hetzner CX22 (2 vCPU / 4GB / 20TB) | **~€4.50/mo** |
| Web build hosting | Cloudflare Pages free tier | **$0** |
| Domain | | **~$12/yr** |

At 1000 monthly players (10–30 peak concurrent), one small VPS is comfortably enough.
**Do not host game traffic on AWS/GCP** — egress at ~$0.09/GB would cost more than the
entire server.

---

## Risk register

| Risk | Mitigation |
|---|---|
| **Tunnels don't read on screen** | M2 answers this in under a week, before anything depends on it |
| **Digging is legible but boring** | M4 is the second gate. Be willing to hear "no." |
| Tunnel visibility is cheatable | Server-filtered from the start (§Architecture) — not retrofittable |
| Bot pathing through tunnels | `AStar3D` over the same graph players use; one source of truth |
| M3 isn't fun | That's what M3 is for. The answer is worth more than the code. |
| Netcode rabbit hole | Listen server, no prediction until it hurts, transport behind an interface |
| Scope creep via classes | Two classes through M5. Brute at M8. Generalist and Juggernaut at M9. |
| Art paralysis | Capsules through M8. No art decisions until systems are proven. |
| Motivation over a long solo project | Every milestone is 1–2 weeks and ends in something playable |

---

## Immediate next step

**M0–M3 are done.** There is a match: two crews, two banners, melee, scruffing, respawns, a
clock, and bots that play the objective. Both audits pass (`tools/tunnel_audit.gd`,
`tools/match_audit.gd`).

**M4's systems are done; its level-design verdict is deferred.** Classes, the cave-in, tunnel bots,
per-plane rock, barricades, no-surface zones, per-crew vein knowledge and breakable surface
boulders are stable. The Backyard BBQ layout and dig-controls pass return after the core rules.

**M5's systems are all built.** Per-team tunnel and shaft maps, sonar and its contestable cant,
crew-owned lamplight, line-of-sight-with-fog into enemy corridors, and a lid cutaway that keeps the
same secret the minimap does. Crews of five, bots that acquire their class at the nest, and Engineer
bots that build one network per crew — going under the midfield rock rather than stopping at it —
mean there are enemy tunnels to be frightened of in the first place. Both audits pass: fifteen
tunnel scenarios and nineteen match rule groups.

**M5 is closed, and its answer was yes.** Crawling into an enemy corridor is frightening: unlit,
not yours, and legible one cell at a time before it goes stale. Nothing needed retuning — every
dial shipped at its first-pass value. It is the first milestone since M2 whose verdict did *not*
come back as a map problem.

**M6 is closed.** Six caches on a ring off the nest-to-nest lane; wedges carried one at a time and
banked at a store saucer that is its own spot inside a nest rather than the banner's feet; enemy
stores raidable; 20-second respawns while broke; and Scurry on Space at one cheese, multiplying
your current speed for two seconds. Dropped cheese **never rots** — a pile waits where somebody
fell until somebody comes for it, and nearby drops merge into one growing pile. That last change
is the one that mattered: it makes the map grow objectives the designer never placed, which this
game had exactly one of before. Three audits pass: 15 tunnel scenarios, 19 match rule groups,
37 cheese invariants.

**M6.5 is nearly closed, and one item is left.** The title screen, pause menu, the bindings drawn
from the live `InputMap`, fullscreen, the version label, the icon, file logging, the screenshot key,
`ATTRIBUTIONS.md`, the F1 tuning panel gated behind `OS.is_debug_build()` and a validated macOS
export preset are all in. Four suites pass: 15 tunnel scenarios, 19 match rule groups, 37 cheese
invariants and the screenshot probe.

**M6.5 is closed for the purpose it was inserted for.** The `.app` builds — 176 MB, universal,
ad-hoc signed — and **runs on a 2020 MacBook Air and a 2026 MacBook Pro**. The compute pass, the
resolution scaling and the signature all survive hardware that is not the development machine, and
the five-year-old Air is the data point that could have said no. Still outstanding, and no longer a
gate: a *friend*, which is the onboarding half rather than the portability half.

**Immediate next: M7 — real multiplayer.** *Does it survive contact with a second human?*

**Step 1 is done: `NetTransport` + `ENetTransport`, with `tools/net_audit.gd` connecting a real
server and two real clients over a real socket.** Written before anything consumes it, which is the
opposite of this project's usual order and correct for a wrapper with no callers yet. It caught a
transport that opened its socket, accepted connections, reported CONNECTED, and silently never
polled — in the most natural three-line call sequence there is.

**Step 2 is done: intent is a value.** The survey was re-measured first and was wrong twice — two
input files became six, four of them event handlers; "the player" in eleven mostly-presentational
places became 31 references across 11 files of which only three are UI. Neither changes the plan's
*shape*: `Mouse._control` is still the driver seam and `MatchDirector` is still the sim.

`InputFrame` now carries a tick of intent, `InputCapture` is the only gameplay code that reads a
keyboard, and `Mouse.drive()` is the door a packet will come through. Single-player runs the
identical path. Five suites pass — 15 tunnel scenarios, 19 match groups, 37 cheese invariants, 22
wire checks, 18 intent checks — and a 30-second soak still builds 73 cells across 2 mouths with
nothing wedged.

**Step 3 is done: seats.** Ten chairs, each holding a peer id or a bot, owned by a `NetSession`
autoload that is the only thing in the game with a socket. Joining takes a chair on the emptier
crew; leaving hands it back to a bot without the chair disappearing. Offline is the same table with
one human in it, so there is no second code path. `--host` and `--join` exist before any button, so
`tools/seat_audit.gd` can launch **two real processes** and assert the seating rather than a human
having to watch it. Six suites pass.

**Step 4's first half is done: mice on a wire.** Poses at 30Hz, seat-indexed so the protocol needs
no spawn messages at all; clients interpolate, puppets simulate nothing, and a remote human's chair
holds a `Player` rather than a `Bot` — which is a distinction that cost a real bug to learn. That
is **checkpoints 1 and 2 met**: two windows, one seat each, bots in the other eight, movement and
melee crossing the wire both ways. `tools/replication_audit.gd` puts two real processes in a real
arena and compares what each says about where the same mouse is; it found that a client which
connects *before* it enters a match was never told its seat, and that the first version of itself
had been passing on favourable timing. Seven suites pass.

**Step 4 is done, and checkpoint 3 with it.** The scoreboard is one message carrying the whole
state four times a second rather than a stream of changes — the plan said "on change" and the
numbers said otherwise, and a full state cannot get stuck wrong. Health rides in the pose. **No HUD
file was touched**, because the HUD already asked `MatchDirector` and the wire writes what the
rules would have. Bots Scurry, which the risk list called blocking. `net_audit` now also asserts
that every scene and script in the game loads, after a parse error in the entire multiplayer match
failed no suite at all. Seven suites pass, nineteen checks in the replication audit alone.

**Step 5 is done: the earth is filtered per crew.** `tunnel_view.gd` is the only place that decides
what a client may know about the ground, `TUNNELS` is addressed to one client because two crews are
owed different worlds, and a client's network holds only what its crew cut or can see — M5's pillar
expressed as geometry rather than as a minimap rule. The fog closes: cells are taken *back* when a
crew stops being allowed to know them. **Verified by deleting the filter**, which is the only way
to trust a check whose subject is invisible from inside a match. Seven suites pass; twenty-three
checks in the replication audit.

**Next: the five singletons become per-mouse controls.** The dig controller, the cave-in, the
barricade, the sonar and the class swap are still wired to `../Player` — *the* player, from when
there was one — so a remote human's dig arrives at a server with nothing to consume it. The intent
has crossed the wire since step 2; what has not happened is these five ceasing to be *the local
player's* controls. It is a refactor rather than a netcode problem, and it is the last thing
between here and checkpoint 5.

> **What a client still cannot do:** dig, cave in, barricade, sonar, or swap class — and the cheese
> lying in the yard is not replicated either, because a dropped wedge is the first object in this
> game that is spawned at runtime rather than seated or authored. Mac only — the web build is a rendering decision, not an export target, and stays at M9.

**Then M7 — real multiplayer.** *Does it survive contact with a second human?* The
survey above is the important part: `Mouse._control` is already the driver seam, `MatchDirector`
is already the sim, and per-crew tunnel knowledge is already stored per crew. The work is turning
input into data, turning direct rule calls into requests, making "the player" plural in the eleven
places that assume otherwise, and filtering what each client is sent. Five checkpoints, each
playable, with the visibility filter deliberately not last.

**Fix in checkpoint 2:** bots still do not Scurry. Acceptable at M6, where the question was
whether a human agonizes over a spend. Blocking at M7, where the other side is a human and a crew
whose AI seats never spend cheese is playing a different economy from the one across the yard.
