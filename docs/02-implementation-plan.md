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
- Bedrock zones

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

**Done when:** you have an honest verdict on each.

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
- Procedural map variation (GDD §8) — fixed layout until the systems are proven
- Free-form digging — chunks only
- The Juggernaut and Generalist — M9 at the earliest
- Audio beyond crude placeholders
- Animation blending — capsules don't animate
- Client prediction — until it demonstrably hurts

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
