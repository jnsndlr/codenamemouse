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
│   ├── maps/               # backyard_bbq.tscn + greybox
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

### M3 — The core loop (1 week)

**Question:** is the flag run tense?

Surface only — tunnels are switched off for this milestone.

- Two nests, two banners, pickup / carry / drop / capture / return
- Melee combat, health, scruffed state, respawn
- Score, timer, win condition
- **Two bots** using navmesh + a simple state machine

**Done when:** you can play a full match against bots and it produces a moment worth
describing to someone.

**Not in scope:** cheese, tunnels, real classes, multiplayer, art.

---

### M4 — Digging in the game (1–2 weeks)

**Question:** is digging *fun*, not just legible?

- Engineer class: dig, ramp, barricade
- Tunnels integrated with the flag map
- **Bots path through tunnels** via `AStar3D` over dug cells
- Dig controls pass (GDD §9 open question)
- No-surface zones and per-plane rock obstructions

**Done when:** you'd rather take the tunnel than the surface route — and the choice
feels like a real decision rather than an obvious one.

---

### M5 — Hidden information (1 week)

**Question:** does the vision asymmetry create the tension we're betting on?

- Server-filtered per-team tunnel visibility
- Own-tunnel wide awareness vs. enemy-tunnel line-of-sight + fog
- Scout class with sonar
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

### M8 — Bruiser and the world (2 weeks)

**Question:** do the counterplay web and the PvE faction pay off?

Two experiments, added **separately** so you can tell which did what:

**8a — Bruiser:** collapse (planes 1–2), corking, Slam. Completes the counterplay web.
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
- **Tall grass bending** (GDD §8) — a shader problem, not a systems problem. Post-M9.
- **Scout camouflage shader** — placeholder transparency until then
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
| Scope creep via classes | Two classes through M5. Bruiser at M8. Generalist and Juggernaut at M9. |
| Art paralysis | Capsules through M8. No art decisions until systems are proven. |
| Motivation over a long solo project | Every milestone is 1–2 weeks and ends in something playable |

---

## Immediate next step

**M0, then M1.** A capsule moving around an isometric grey-box backyard.

Then **M2** — the dig spike — because that's the question that decides what this game
actually is, and it's answerable in five evenings.
