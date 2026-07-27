# Codename: Mouse — Game Design Document

> The **what**. Systems, rules, numbers. Numbers marked `[ASSUMED]` are starting
> values chosen to be tuned, not defended. `[DECIDE]` marks a real open question.
>
> Read [`00-intent.md`](00-intent.md) first — it settles arguments this doc starts.

---

## 1. Match at a glance

| | |
|---|---|
| Format | 4v4 `[ASSUMED]` — smallest count that supports role variety, fills at low population |
| Match length | 8 minutes, or first to 3 captures `[ASSUMED]` |
| Camera | Fixed orthographic isometric, ~45° yaw / ~40° pitch, slight follow with lookahead |
| Control | Mouse-aimed. `[DECIDE]` WASD movement + cursor aim, or click-to-move. See §7. |
| Win condition | Most flag captures at time, or first to cap limit |
| Death | **Scruffed** — 6s respawn at nest, drops everything carried |

---

## 2. The two objective layers

This is the central design bet of the game, so it goes first.

### Layer 1 — The Flag (win condition)

Classic CTF, deliberately unmodified:

- Each nest has a **team banner**. Steal the enemy's, carry it to your nest, score.
- Your own banner must be **at home** to score `[ASSUMED]` — the standard rule that
  creates the defend/attack tension.
- A dropped banner sits on the ground for **20s**, then auto-returns `[ASSUMED]`.
- Touching your own dropped banner returns it instantly.
- **Flag carriers are visible to everyone**, always, on the minimap. No hiding.
- Flag carriers **cannot use their class's mobility ability** `[ASSUMED]` — the
  carrier is a slow, loud problem that the team has to solve *for* them.

### Layer 2 — Cheese (economy)

Cheese is the resource layer that makes the map worth fighting over between flag runs.

- Cheese wedges spawn at fixed **cache points** around the map and respawn on a timer.
- The best caches are **guarded by the Backyard faction** (§5) — ants, a rat, a wasp
  nest. High-value cheese always costs a PvE fight.
- Mice carry cheese back to their nest, adding to **Cheese Stores** (the HUD counter).
- Cheese is dropped on being scruffed, and can be picked up by anyone.
- **Enemy stores are raidable** — you can steal from their nest stockpile.

### How the layers interact (the important part)

Cheese must **enable flag play**, not compete with it for attention. Cheese Stores are
spent by the *team*, not hoarded for a score:

| Spend | Cost `[ASSUMED]` | Effect |
|---|---|---|
| **Respawn skip** | 3 | A scruffed teammate returns instantly |
| **Field upgrade** | 5 | One class ability upgraded for the rest of the match |
| **Fortify nest** | 4 | Deploy a barricade / trap at your nest |
| **Bait the cat** | 6 | Drop scent that pulls the cat toward a location you pick |

> `[DECIDE]` **Who spends the cheese?** Options: (a) any player spends from a shared
> pool, (b) a designated role, (c) automatic thresholds. (a) is simplest and most
> readable; (c) removes a decision layer but avoids griefing. I'd start with (a).

> `[DECIDE]` **Does cheese contribute to winning directly?** Current design says **no**
> — cheese is purely an enabler, flags decide the match. The alternative (cheese as a
> secondary score) risks two games fighting each other. Recommend keeping it at no
> until the prototype proves the loop.

**Prototype note:** this entire layer is *deliberately cut* from Milestone 1. We prove
the flag loop first, then add cheese and check whether the game got better or just busier.

---

## 3. Map anatomy

Every map is a real human place at mouse scale. The first map is **The Backyard**,
matching the concept art.

### Required elements per map

- **Two nests** — team-colored, contains the banner spawn and the Cheese Stores stockpile
- **A contested middle** — open ground, dangerous, the default fight
- **At least two flanking routes** — a drainpipe, a gap under the fence, a gutter
- **Mouse holes** — one-way or size-gated shortcuts only small classes fit through (§4)
- **Verticality** — the top of the cardboard box, the woodpile, the flowerpot rim.
  Iso 3D earns its keep here; ramps and levels create real positional play.
- **2–3 hazard zones** — sprinkler, patio (cat patrol), open lawn (bird strike)
- **3–5 cheese caches** — at least one guarded by the Backyard faction

### The Backyard (map 1) — from concept art

| Feature | Role |
|---|---|
| Blue nest (doghouse, NW) / Red nest (SE) | Bases, banner spawns, stockpiles |
| Cardboard box (center) | Central high ground, climbable, sightline control |
| Metal drainpipe (N) & log tunnel (W) | Covered flank routes, no ranged fire inside |
| Tree stump (SW) | Mid-height platform, mid-lane cover |
| Brick piles | Low cover, breaks sightlines |
| Trash can + flowerpot (E) | Vertical cluster, high cheese cache, hard to hold |
| Garden hose (E) | Wall / ramp, soft-blocks the east lane |
| Open dirt paths | Fast movement, fully exposed — the risk/reward lanes |
| Fence line | Map boundary, with **one gap** as a deep flank |

---

## 4. Classes

Design rule from Pillar 3: **every class has one capability no other class has.** Not
a better stat — a thing others literally cannot do.

> **Prototype ships with Scurry and Bruiser only.** The rest are designed here so the
> systems are built general enough, but they are not implemented until those two are
> proven genuinely different.

### Scurry — the runner `[PROTOTYPE]`

| | |
|---|---|
| Fantasy | The fast one who gets in and out |
| Health | Low (60) `[ASSUMED]` |
| Speed | Fastest (1.3×) |
| **Unique capability** | **Fits through mouse holes.** Whole routes exist only for Scurry. |
| Ability | *Dart* — short burst of speed, no i-frames |
| Weakness | Loses almost every straight fight; cannot carry cheese while sprinting |
| Role | Primary flag runner, harasser, cache scout |

### Bruiser — the wall `[PROTOTYPE]`

| | |
|---|---|
| Fantasy | The big one who says "not through here" |
| Health | High (160) `[ASSUMED]` |
| Speed | Slowest (0.8×) |
| **Unique capability** | **Body-blocks.** Cannot be pushed past; occupies a lane. |
| Ability | *Slam* — short-range knockback that **makes carriers drop the flag** |
| Weakness | Cannot chase. Cannot flank. Irrelevant in open ground. |
| Role | Nest defense, chokepoint hold, carrier escort |

### Tinker — the engineer

| | |
|---|---|
| **Unique capability** | **Builds terrain.** Popsicle-stick ramps that create routes that didn't exist. |
| Ability | *Snap Trap* — a deployable mousetrap; stuns and drops carried items |
| Role | Map control, nest fortification, opening new lanes mid-match |

### Forager — the support

| | |
|---|---|
| **Unique capability** | **Carries 3 cheese at once** (everyone else carries 1). |
| Ability | *Share* — heals and grants a brief speed boost to a nearby ally |
| Role | Economy engine, carrier escort, sustain |

### Slinger — the ranged threat

| | |
|---|---|
| **Unique capability** | **The only class with real range** (seed slingshot). |
| Ability | *Pin* — a slow, high-arc shot that briefly roots |
| Weakness | Very low health, useless in melee, slow projectiles that can be dodged |
| Role | Zoning, punishing open ground, contesting high cheese caches |

> `[DECIDE]` Five classes is a big balance surface. An alternative is **three classes
> with two loadout variants each** — same expressive range, much less to tune.

---

## 5. The Backyard (PvE faction)

Pillar 2 made concrete. These are **neutral hostiles** — hostile to both teams,
allied to neither, and *predictable*.

The critical constraint: **learnable, never random.** Fixed timers, clear telegraphs,
consistent behavior. Players should be able to say "the cat comes at 5:30" and be right.

### The Cat — apex pressure

- Enters the map on a **fixed schedule** (e.g. 6:00, 3:00, 0:45) with a loud audio and
  visual telegraph ~8 seconds before arrival
- Patrols a set route, one-shot-scruffs any mouse it catches in the open
- **Ignores mice under cover** (in pipes, under the box, in tall grass)
- Creates forced truces, route changes, and comedy
- Can be **manipulated** — the `Bait the cat` cheese spend pulls it toward a location.
  This turns a hazard into a weapon, which is the most interesting thing about it.

### Birds — area denial

- Periodically shadow-telegraph a circle on **open ground only**
- Swoop after ~2s; heavy damage in the circle
- Function: make the fast open lanes genuinely risky, push traffic into flank routes

### Ants / beetles — cache guards

- Static groups guarding high-value cheese caches
- Weak individually, dangerous in numbers
- Function: PvE tax on the best economy. A team fighting ants is a team you can jump.

### The Rat — mini-boss

- Holds the single best cache on the map
- Genuinely hard for one mouse; a real fight for two or three
- Function: creates a scripted "both teams want this and neither can solo it" moment

### Sprinkler / hose — environmental hazard

- Fixed cycle (e.g. 90s on a visible timer), floods a lane, pushes and slows mice
- Pure map-state timer; the most learnable hazard in the game

> `[DECIDE]` **How much PvE is too much?** If hazards fire constantly the CTF game
> can't breathe. Starting rule: **at most one major hazard active at a time**, with
> quiet windows for clean PvP. Tune aggressively in playtest.

---

## 6. Combat

Deliberately simple. Aim is not the mastery axis (Pillar 4, and it keeps netcode sane).

- **Health**, no armor, no shields. Regenerates after 5s out of combat `[ASSUMED]`.
- **Scruffed, not killed** — knocked flat, 6s respawn at nest, drops flag and cheese.
- **Melee is a short cone**, cursor-aimed, ~0.4s swing. Generous hitbox.
- **Ranged is projectile-based, slow, and dodgeable** — never hitscan. This is a
  deliberate netcode decision as much as a design one (§ implementation plan).
- **Knockback and displacement matter more than damage.** Slam, Pin, and the sprinkler
  all move mice around. Positioning is the skill.
- **No headshots, no crits, no random damage.** Fully deterministic.

> `[DECIDE]` Is there any friendly fire or team collision? Team collision would make
> Bruiser body-blocking apply to allies too, which is interesting but frustrating.
> Recommend: enemies collide, allies pass through.

---

## 7. Controls

> `[DECIDE]` — this is the single biggest feel question and I'd want to prototype both.

**Option A — WASD move + cursor aim** (recommended)
Direct, responsive, standard for iso action games (Hades, Diablo-likes with WASD).
Movement and aim are independent, which makes kiting and repositioning expressive.

**Option B — Click to move**
Classic iso/MOBA. Lower input burden, better for a casual audience, worse for the
dodge-and-reposition combat described in §6.

Given that combat is about displacement and positioning, **A fits the design better**.
Milestone 1 should implement A and try B for an hour before committing.

---

## 8. HUD

Directly from the concept art — it's already right.

- **Top left** — current objective reminder
- **Top center** — team scores + match timer
- **Bottom left** — minimap (flag positions, cat position, teammate pings)
- **Bottom center-left** — event feed (steals, drops, returns) + chat
- **Bottom center-right** — Cheese Stores, both teams
- **Bottom right** — flag carrier portraits with health, both teams

The carrier portraits are a genuinely good idea: **the two most important people in the
match are always on screen with their health visible.** Keep this.

---

## 9. Progression

**In-match only.** No meta-progression, no unlocks, no persistent stats for now.

- Cheese spends (§2) are the entire progression system, and they reset each match.
- Rationale: a hobby project cannot maintain a live progression economy, and unlocks
  actively hurt a game whose population is measured in dozens.

> `[DECIDE]` Cosmetics (hat variants for your mouse) are the only meta system worth
> considering later, and only because they're pure content with no balance surface.

---

## 10. Open questions, ranked by leverage

These change the shape of the game. Roughly in the order they need answering:

1. **Does cheese survive contact with the flag loop?** (§2) — biggest structural risk
2. **WASD or click-to-move?** (§7) — determines combat feel and everything downstream
3. **How many classes at ship?** (§4) — balance surface vs. expressive range
4. **Cheese spending: shared pool, designated role, or automatic?** (§2)
5. **PvE density** — how often is too often? (§5)
6. **Is there a solo-vs-bots mode as a first-class citizen?** (Intent: yes, probably)
