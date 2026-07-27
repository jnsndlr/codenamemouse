# Codename: Mouse — Implementation Plan

> The **how**. Tech decisions, architecture, and a milestone path that front-loads
> the risky questions and defers everything else.
>
> Read [`00-intent.md`](00-intent.md) and [`01-gdd.md`](01-gdd.md) first.

---

## Guiding principle

**Every milestone must answer a question we can't answer by thinking.**

The failure mode for a project like this is building infrastructure for a game that
turns out not to be fun. So the order is: prove the loop with capsules → prove the
classes → prove multiplayer → prove PvE → *then* build anything that looks like
production tech.

Corollary: **grey boxes and capsules are correct, not a compromise.** We are not
"making do until we get art." We are deliberately removing every variable except
whether the systems are good.

---

## Tech decisions

| Decision | Choice | Why |
|---|---|---|
| Engine | **Godot 4.x** | Full engine: navmesh, animation state machines, physics, headless server export, and an editor a designer can build maps in. See conversation rationale. |
| Language | **GDScript** first | Fastest iteration by far. C# or a C++ GDExtension is the escape hatch if simulation gets hot — we will know, and it will be contained. |
| Camera | `Camera3D`, `projection = ORTHOGONAL` | "Isometric" is a camera setting in 3D, not a feature. ~45° yaw, ~40° pitch. |
| Target (dev) | **Desktop** | Fast iteration, real UDP, no browser constraints while the game is being designed. |
| Target (eventual) | **Web export, decided later** | Same Godot project either way. This is an export target, not an architecture. |
| Netcode (v1) | **Listen server** | One client hosts and is authoritative. Zero infrastructure, real multiplayer. |
| Netcode (v2) | **Headless dedicated server** | Same codebase, `--headless` export. ~$5/mo VPS when needed. |
| Transport | **Behind an interface from day one** | The one piece of architecture worth doing early. See below. |

### The transport interface (do this early, it's cheap)

Browsers can't do raw UDP, so a future web build needs WebSocket or WebRTC while
desktop uses ENet. Rather than deciding now, wrap it:

```
NetTransport (interface)
  ├── ENetTransport       # desktop, UDP, ships first
  ├── WebSocketTransport  # web, TCP, adequate for prototype
  └── WebRTCTransport     # web, UDP-ish, only if competitive play demands it
```

Game code talks to `NetTransport` and never touches a peer class directly. This costs
maybe a day now and preserves the browser option indefinitely. **This is the only
piece of speculative architecture worth building before it's needed.**

### Design decisions that are secretly netcode decisions

Worth naming explicitly, because they're already in the GDD and they're load-bearing:

- **Projectiles, never hitscan** (GDD §6) — projectiles tolerate latency gracefully;
  hitscan demands lag compensation and server-side rewind.
- **No random damage, no crits** — deterministic simulation is dramatically easier to
  reconcile between client and server.
- **Displacement over damage** — knockback is forgiving of small desyncs in a way that
  precise HP thresholds are not.
- **4v4** — 8 entities is a trivially small state payload.

These weren't chosen *for* netcode, but they make the hard part much easier, and we
should avoid casually reversing them later.

---

## Architecture

### Server-authoritative from the start

Even in listen-server mode, the host runs the authoritative simulation and clients send
*inputs*, not positions. This is more work in week one and saves a rewrite later. It
also means the leap to a dedicated server is a deployment change, not a redesign.

```
Client                          Server (authoritative)
  ├── input capture       ──▶     simulation tick (30Hz)
  ├── local prediction              ├── movement + collision
  ├── interpolation       ◀──       ├── combat resolution
  └── presentation                  ├── objective state
                                    └── PvE AI
```

Prediction and reconciliation are **deferred**. Start with naive
send-input/receive-state and see how it feels on LAN. Add prediction when it actually
hurts, not before.

### Data-driven from the start

Classes, abilities, and PvE behaviors live in **resource files, not code**. Godot's
custom `Resource` types are ideal — they're editable in the inspector and hot-reloadable.

```
ClassDefinition (Resource)
  health, speed, carry_capacity
  abilities: Array[AbilityDefinition]
  unique_capability: enum

AbilityDefinition (Resource)
  cooldown, cast_time, range, damage, knockback, effect
```

Rationale: you have fifteen years of ideas and you'll want to try them fast. Tuning
should be an inspector edit, not a code change and recompile.

### Project structure

```
codenamemouse/
├── docs/                   # these documents
├── scenes/
│   ├── game/               # match, spawn, objective managers
│   ├── entities/           # mouse, flag, cheese, PvE creatures
│   ├── maps/               # backyard.tscn + greybox
│   └── ui/                 # HUD, minimap, feed
├── scripts/
│   ├── net/                # NetTransport + implementations
│   ├── sim/                # authoritative simulation
│   ├── classes/            # class + ability logic
│   └── ai/                 # bots and Backyard faction
├── resources/
│   ├── classes/            # ClassDefinition .tres files
│   ├── abilities/          # AbilityDefinition .tres files
│   └── pve/                # Backyard faction definitions
└── assets/                 # placeholder now, real later
```

---

## Milestones

Each has an explicit **question**, a **done-when**, and a hard scope boundary.

### M0 — Spike (½ day)

**Question:** does the toolchain work end to end?

- Godot 4 installed, project created, git initialized
- A cube on a plane under an orthographic iso camera
- **Web export smoke test** — deploy the cube to Cloudflare Pages, confirm it loads

**Done when:** you've seen your cube in a browser tab. Then forget about web entirely
until M5.

---

### M1 — A mouse that moves (2–4 evenings)

**Question:** does isometric movement feel good?

- Capsule with a `CharacterBody3D`, WASD movement, cursor aim (GDD §7 Option A)
- Camera follows with slight lookahead
- Grey-box arena: a flat plane, some boxes, a ramp
- Spend one hour trying click-to-move, then commit to one

**Done when:** moving the capsule around is *pleasant*. This is a real bar. If
movement is unsatisfying, nothing built on it will be fun.

**Not in scope:** combat, classes, networking, animation.

---

### M2 — The core loop (1 week) ← **the most important milestone**

**Question:** is the flag run tense?

- Two nests, two banners, pickup / carry / drop / capture / return
- Basic melee, health, scruffed state, 6s respawn
- Score, match timer, win condition
- **Two bots** that will chase you and take your flag — dumb bots, navmesh + state machine

**Done when:** you can play a full match against bots, alone, and it produces a
moment you want to describe to someone.

**This is the milestone that decides whether the project continues.** Everything
before it is setup; everything after it is elaboration. Be honest here.

**Not in scope:** cheese, real classes, multiplayer, PvE faction, art.

---

### M3 — Two classes (1 week)

**Question:** do capability gates create real role identity?

- Scurry and Bruiser from GDD §4, built on the `ClassDefinition` resource system
- Implement the **unique capabilities**, not just the stats: mouse holes that only
  Scurry fits through; Bruiser body-blocking and Slam knocking the flag loose
- Class select before match

**Done when:** playing Scurry and playing Bruiser make you want *different things from
the same map.* If they're just fast-squishy and slow-tanky, the capability gates
aren't strong enough — fix that before adding a third class.

---

### M4 — Real multiplayer (1–2 weeks)

**Question:** does it survive contact with a second human?

- `NetTransport` interface + `ENetTransport`
- Listen server, server-authoritative movement and combat
- Client interpolation; prediction only if it feels bad without
- Bots fill empty slots

**Done when:** you and a friend play a full match over the internet and it's playable.
Not perfect — playable.

---

### M5 — Cheese and the Backyard (2 weeks)

**Question:** do the two big design bets pay off?

Two experiments, added **separately** so you can tell which one did what:

**5a — Cheese economy.** Caches, carrying, stores, and *one* spend (respawn skip).
Play five matches. Did decisions get richer or just noisier? **Be genuinely willing to
cut this.**

**5b — The Backyard faction.** The cat only, on a fixed schedule. Play five matches.
Did the match get better when it showed up?

**Done when:** you have an honest verdict on each. "We cut cheese" is a completely
successful outcome for this milestone.

---

### M6 — Decide what this is (open)

With M2–M5 answered, the real decisions become answerable:

- Web export or desktop? (Now an informed choice, not a guess.)
- Dedicated server? (Only if humans are actually playing together.)
- More classes, more maps, or better feel on what exists?
- Art direction and the first non-capsule mouse.

---

## What we deliberately don't build yet

Named explicitly so they don't sneak in:

- Matchmaking, lobbies, party system — friends use a direct connect code
- Accounts, persistence, stats, leaderboards
- Anti-cheat — server authority is enough at this scale
- Multiple maps — one map, iterated on, beats three mediocre ones
- Audio beyond crude placeholders
- Animation blending — capsules don't animate
- Anything in GDD §9 (progression)
- Client prediction — until it demonstrably hurts

---

## Cost model

| Phase | Infrastructure | Cost |
|---|---|---|
| M0–M3 | None — local only | **$0** |
| M4 | Listen server; friends direct-connect | **$0** |
| M5 | Same | **$0** |
| Post-M6, if there are players | 1× Hetzner CX22 (2 vCPU / 4GB / 20TB) | **~€4.50/mo** |
| Web build hosting | Cloudflare Pages free tier | **$0** |
| Domain | | **~$12/yr** |

At 1000 monthly players (10–30 peak concurrent, 1–3 concurrent matches), one small VPS
is comfortably sufficient. **Do not host game traffic on AWS/GCP** — egress at
~$0.09/GB would cost more than the entire server.

---

## Risk register

| Risk | Mitigation |
|---|---|
| M2 isn't fun | That's the point of M2. Cheap to learn, and the answer is worth more than the code. |
| Netcode rabbit hole | Listen server, no prediction until it hurts, transport behind an interface |
| Scope creep via classes | Hard cap at two until M3's question is honestly answered |
| Cheese dilutes the CTF | Added separately in M5a specifically so it can be cut cleanly |
| Art paralysis | Capsules through M5. No art decisions until the systems are proven. |
| Motivation over a long solo project | Milestones are 1–2 weeks and each ends in something playable |

---

## Immediate next step

**M0, then M1.** Get a capsule moving around an isometric grey-box backyard and see
whether it feels good.

Fifteen years of thinking has produced a design worth building. The fastest way to
learn whether it's *right* is to move a capsule around a box.
