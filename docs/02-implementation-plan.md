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

- Engineer class: dig, ramp, barricade
- **Bots path through tunnels** via `AStar3D` over dug cells — this is now the milestone's
  centre of gravity, since M3 already ships digging and the flag map together. Until bots
  can follow, digging isn't a decision, it's an exploit.
- Dig controls pass (GDD §9 open question)
- No-surface zones and per-plane rock obstructions

**Done when:** you'd rather take the tunnel than the surface route — and the choice
feels like a real decision rather than an obvious one.

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
- **`tunnel_speed` is where the classes first feel different.** Size matters underground (§3),
  and it applies *only* below the surface — which is what makes a slow Brute read as a cork in
  a corridor rather than as lag on the lawn.
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

- Server-filtered per-team tunnel visibility
- Own-tunnel wide awareness vs. enemy-tunnel line-of-sight + fog
- Sneak class with sonar
- Minimap layer rendering

**Done when:** crawling into an enemy tunnel is *frightening*.

---

### M6 — Cheese is lives (1 week)

**Question:** does the economy create real decisions?

- Caches, carrying, team stores, respawn cost
- Zero-cheese slow-respawn state
- Sprint drain
- **Watch specifically for the bankruptcy play** (GDD §2) — does anyone ever choose to
  concede a capture to go refill? If nobody does, the economy isn't tuned right.

**Done when:** you've agonized over a cheese decision at least once.

---

### M7 — Real multiplayer (1–2 weeks)

**Question:** does it survive contact with a second human?

- `NetTransport` + `ENetTransport`, listen server, server-authoritative
- Client interpolation; prediction only if it feels bad without
- Bots fill empty slots

**Done when:** you and a friend play a full match over the internet and it's playable.
Not perfect — playable.

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

Next is **M4 — digging in the game**, and its centre of gravity has already shifted, exactly as
this plan predicted: M3 ships digging and the flag map together, so the question is no longer
"can we integrate them" but **"can a bot follow you down there?"** Until it can, the tunnel is an
exploit rather than a decision — the one residual cost M3 knowingly accepted.
