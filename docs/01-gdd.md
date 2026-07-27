# Codename: Mouse — Game Design Document

> The **what**. Systems, rules, numbers. Values marked `[ASSUMED]` are starting points
> chosen to be tuned, not defended. `[DECIDE]` marks a real open question.
>
> Read [`00-intent.md`](00-intent.md) first — it settles arguments this doc starts.

---

## 1. Match at a glance

| | |
|---|---|
| Players | **One player = one mouse.** 4v4 `[ASSUMED]` |
| Match length | 8 minutes, or first to 3 captures `[ASSUMED]` |
| Camera | Fixed orthographic isometric, ~45° yaw / ~40° pitch, follow with lookahead |
| Control | WASD movement, cursor aim, hotkey abilities |
| Combat | Martial — claws, tails, thrown acorns, slings. **No guns.** |
| Win condition | Most flag captures at time, or first to cap limit |
| Death | **Scruffed** — knocked flat, costs the team 1 cheese, respawn at nest |
| World | 4 horizontal planes: surface + 3 dig depths |
| Solo play | Identical match, AI in every other seat |

---

## 2. The two layers

### Layer 1 — The Flag (how you win)

Deliberately unmodified playground CTF (Pillar 1):

- Each nest has a **team banner**. Steal theirs, carry it home, score.
- Your own banner must be **at home** to score `[ASSUMED]`.
- A dropped banner sits for **20s**, then auto-returns. Touching your own returns it instantly.
- **Carriers are always visible** to everyone on the minimap. No hiding with the flag.
- **Carrying slows you** — except the Generalist (§4). The single most important rule
  in the game; see the Generalist entry for why.

> `[DECIDE]` **Can the flag go into tunnels?** Allowing it makes tunnels the dominant
> escape route and makes surface defense feel pointless. Recommend **no** — the flag
> cannot enter a tunnel, forcing carriers onto the surface where they can be contested.
> Tunnels move *mice*, not objectives.

### Layer 2 — Cheese (how you survive)

**Cheese is the team's respawn supply.** Not a second score — the team's health bar.

- Every respawn costs **1 cheese** from the team pool `[ASSUMED]`.
- At **zero cheese, respawns take 20s instead of 6s** `[ASSUMED]`. Not a death sentence,
  but a team at zero gets overrun fast.
- Cheese is gathered from **caches** on the map, carried home one wedge at a time.
- Scruffed mice **drop carried cheese** where they fall.
- **The world takes cheese too** — crows raid your stores, ants haul caches away (§7).
- Enemy stores are **raidable**.

> **The bankruptcy play (intended, not incidental).** Because zero cheese is survivable,
> a team that's ahead on captures can deliberately **trade score for economy** — concede
> a capture, pull everyone off defense, and go raid cheese to refill the pool. This is a
> real strategic option and one of the best things about cheese-as-lives. Don't tune it away.

### Spending cheese

Every spend is paid in future deaths. That's the whole tension.

| Spend | Cost `[ASSUMED]` | Effect |
|---|---|---|
| **Respawn** | 1 | Baseline. Automatic, not a choice. |
| **Sprint** | ~1 per 4s while held | Personal speed boost, toggled on |
| **Hire a Rat** | 5 | Respawn as the Juggernaut for one life (§4) |
| **Barricade** | 2 | Engineer deploys a defensive barrier |

**Sprint is the interesting one.** A tap you leave open, not a purchase. It drains the
*team's* pool, and everyone sees the number dropping. The teammate burning your respawns
to get somewhere fast had better be right about it.

> `[DECIDE]` **Second currency?** Recommend **no**. Cheese-as-lives works *because*
> everything trades against one pool — a second currency lets you buy power without
> paying in survival. Revisit only if the tension flattens in play.

---

## 3. Digging — the signature system

The centerpiece. Designed first, prototyped early.

The model is **layered Dig Dug**, not Red Faction. Discrete tunnel segments chained
across a few flat depth planes — expressive to play with, and a *graph* rather than a
deformable mesh, which keeps it buildable.

### The planes

| Plane | Dig time | Collapsible from surface? |
|---|---|---|
| **0 — Surface** | — | — |
| **1 — Shallow** | Fast | Yes |
| **2 — Mid** | Slower | Yes, harder `[DECIDE]` |
| **3 — Deep** | Slowest | **No — immune** |

This is the core risk curve: **shallow tunnels are fast and fragile, deep tunnels are
slow investments that become permanent infrastructure.** An Engineer choosing depth is
choosing between tempo and durability.

### Digging mechanics

- Tunnels are built from **discrete chunks**. Each new segment **pivots off the end of
  the previous one** — pick a direction, dig, repeat. Snake-like, not free-form carving.
- Digging is **interruptible** and leaves the Engineer stationary and vulnerable.
- **Ramps** connect adjacent planes. An Engineer builds a ramp to descend or ascend.
  Ramps are the only vertical transit — you can't dig straight down.
- **Entrances** are on the surface and are visually subtle to the enemy.
- **Intersecting tunnels connect.** If your segment runs into an enemy tunnel, the
  networks join. That's a designed feature — accidentally breaking into their highway
  is a great moment, and it means deep enemy networks can be invaded rather than only
  detected. `[DECIDE]` Should the Engineer be able to *choose* to breach, or only
  discover it by accident?

### Vision — the hidden information layer

The asymmetry here is the best thing in the system:

| Situation | What you see |
|---|---|
| **In your own tunnel** | Wall outlines extend **far ahead** — you know your network intimately |
| **In an enemy tunnel** | **Direct line of sight only**, fog of war beyond. You are crawling blind. |
| **On the surface** | Nothing underground, unless revealed |
| **Scout sonar active** | A pulse reveals tunnel geometry in a radius **through earth**, shared with the team |

Raiding an enemy network should feel genuinely frightening — you don't know what's
around the corner and they do.

### Movement — size matters

Speed underground scales **inversely with class size**:

| Class | Tunnel speed | Effect |
|---|---|---|
| Scout | Fastest | Tunnels are their highway |
| Generalist | Fast | Comfortable |
| Engineer | Normal | Lives down here |
| Bruiser | **Very slow** | Barely moves — but **plugs the tunnel completely** |
| Juggernaut | **Cannot enter** | Too big. A hard, thematic constraint. |

A Bruiser in a tunnel is a **cork**. Nobody gets past. Real defense at a real cost:
slow, out of position, and blind to the surface.

### Collapse — the counter

- A **Bruiser collapses a tunnel from the surface** by slamming the ground above a
  known segment.
- Mice caught inside are **scruffed** by the cave-in.
- The segment is destroyed and must be re-dug.
- **Only works on planes 1–2.** Deep tunnels are immune (see table above).
- **Requires knowing where the tunnel is** — which is why Scout sonar feeds directly
  into Bruiser collapse. Two classes, one combo.

### Rendering and legibility `[RISK]`

The biggest open UX question in the project.

- When underground, the **surface ghosts to high transparency**; your current plane
  renders solid with **brightly highlighted tunnel edges**.
- Other planes render dim or hidden — one plane in focus at a time.
- A **depth indicator** on the HUD: am I at 1, 2, or 3?
- Surface players see **dust puffs and rumbling** above active digging — a subtle,
  learnable tell that rewards attention without giving the route away.
- The minimap shows **your full network plus any revealed enemy segments**, by depth.

**Solve this in grey-box, early.** If players can't read what's happening below, the
signature system fails — and that needs discovering in week three, not month eight.

### Why this is buildable

Worth stating plainly, because it drives the implementation plan:

- Segments are **discrete instanced chunks on a graph** — no runtime mesh deformation
- Bot pathing is **graph traversal**, not dynamic navmesh rebuilding
- Each plane is a **flat layer**, so no true 3D volumetric problem
- Collapse is **removing a node**, not carving geometry

---

## 4. Classes

Pillar 4: every class has one thing **no other class can do at all.**

**These four are the core set.** Other class ideas exist, but the game is not itself
without these.

### Generalist — the runner

| | |
|---|---|
| Fantasy | The reliable one. The one who actually scores. |
| Stats | Balanced — medium health, medium speed, medium damage |
| **Unique capability** | **Carries the flag at full speed.** Everyone else is slowed. |
| Ability | *Second Wind* — brief self-heal, long cooldown |
| Role | Primary flag runner, on-ramp class |

> **The Generalist problem, and the fix.** "Balanced" classes usually feel bad, because
> average-at-everything means never-the-right-answer. The fix is to give the Generalist
> the most important job in a game called capture the flag: **they are the only class
> that runs the flag well.** Not average — the one who wins matches. That makes the
> beginner-friendly class genuinely prestigious, which is what casual-first needs.

### Bruiser — the wall

| | |
|---|---|
| Fantasy | The big one who says "not through here" |
| Stats | High health, slow, heavy damage |
| **Unique capability** | **Collapses tunnels** from the surface (planes 1–2) |
| Ability | *Slam* — short-range knockback; **makes carriers drop the flag** |
| Underground | Very slow, but **plugs a tunnel completely** |
| Weakness | Cannot chase, cannot flank, exposed in open ground |
| Role | Nest defense, chokepoints, tunnel denial, sabotage |

### Engineer — the digger

| | |
|---|---|
| Fantasy | The one who changes the map |
| Stats | Low damage, medium health, medium speed |
| **Unique capability** | **Digs tunnels and builds ramps.** Nobody else alters terrain. |
| Ability | *Barricade* — destructible barrier, 2 cheese |
| Weakness | Weakest attack in the game. Cannot win a fight, only shape one. |
| Role | Map control, route creation, fortification |

### Scout — the glass cannon

| | |
|---|---|
| Fantasy | The one you don't see until it's too late |
| Stats | **Lowest health**, fastest, **highest burst damage** |
| **Unique capability** | **Sonar** — pulses to reveal enemy tunnel geometry through earth, shared with the team |
| Ability | *Fade* — hard to see while moving slowly; broken by attacking or sprinting |
| Weakness | Dies to anything that touches them. Loses every fair fight. |
| Role | Scout, assassin, counter-Engineer, cache raider |

`[DECIDE]` **Concealment model:** full invisibility (frustrating), a shimmer/distortion
at distance (readable — recommended), or concealment only while stationary.

### Juggernaut — the hired rat `[SPECIAL]`

Not a class you pick — one you **buy**.

| | |
|---|---|
| Cost | **5 cheese** — five respawns |
| Duration | **One life.** When scruffed, back to your normal class. |
| Fantasy | You bribed a rat from the alley to fight for your crew |
| Stats | Very high health, high damage, slow |
| **Constraint** | **Cannot enter tunnels.** Surface only. |
| Role | A committed push. A gamble the whole team pays for. |

> **Why a hired rat:** it explains the cost diegetically, ties the economy to the PvE
> faction (§7 — rats are neutral creatures you bribe), and gives a silhouette that reads
> instantly as *not a mouse*.

> `[DECIDE]` You mentioned 2–3 special unlockables. Recommend shipping **one** and
> seeing whether the "spend 5 lives on a big swing" moment lands before designing more.

### Switching class

- **On respawn** — free, always available. Supports composition-as-strategy.
- **While alive** — return to **your own nest** and use the swap point. Free, but costs
  **time and position** rather than cheese. Walking home mid-match is the price.

This is a good structure: adaptation is always possible, never resource-gated, but
always costs tempo.

---

## 5. The counterplay web

Every class answers another, and the answers route through the dig system:

```
  Engineer digs a route (shallow = fast, deep = safe)
        │
        ▼
  Scout sonar finds it ──────▶ reveals geometry to their team
        │                              │
        │                              ▼
        │                    Bruiser collapses it (planes 1–2 only)
        │                              │
        ▼                              ▼
  Engineer digs deeper (plane 3)  Mice inside scruffed
        │
        ▼
  Bruiser corks the tunnel ◀──── Scout can't get past
        │
        ▼
  Generalist takes the surface route with the flag
```

No hard counters — every answer costs position, cheese, time, or exposure. Note how
**depth is the Engineer's answer to the Bruiser**, paid for in dig time.

---

## 6. Combat

Simple by design (Pillar 1). Simple combat also keeps netcode sane.

- **Martial only.** Claws, tail-whips, thrown acorns, slings, teeth. No firearms.
- **Melee is primary** — short cursor-aimed cone, ~0.4s swing, generous hitbox.
- **Thrown weapons are slow arcing projectiles**, never hitscan. Dodgeable on reaction.
- **Health**, no armor, no shields. Regenerates after 5s out of combat `[ASSUMED]`.
- **Scruffed, not killed** — drops flag and cheese, costs the team 1 cheese.
- **Displacement matters more than damage.** Slam, cave-ins, and hazards move mice around.
- **Fully deterministic.** No crits, no random damage, no headshots.

> `[DECIDE]` Team collision? Enemy collision makes Bruiser body-blocking work. Ally
> collision would apply it to teammates too — interesting but frustrating.
> Recommend: enemies collide, allies pass through. **Exception:** in tunnels, the
> Bruiser cork should probably block allies too, or corking is meaningless.

---

## 7. The world (PvE faction)

Pillar 5 made concrete. Neutral hostiles: allied to nobody, **predictable always**.
Fixed timers, loud telegraphs, learnable behavior. Never random.

The world both **gives and takes**.

### The Cat — apex threat, forced respite

- Arrives on a **fixed schedule** (6:00, 3:00, 0:45), ~8s audio/visual telegraph
- Patrols a set route; catches any mouse in the open
- **Ignores mice under cover** — in tunnels, under the box, in tall grass
- **Function:** hard stop on surface PvP. Both crews go to ground — often *literally*,
  into the tunnels, which is where the interesting version of this happens.

### The Crow — steals your cheese

- Periodically lands at a nest and hauls cheese away
- Takes **two mice** to drive off `[ASSUMED]`
- **Function:** pulls players off the front line, creates a PvP lull, and makes the
  economy feel alive. It's stealing your *lives*.

### Ants — cache guards

- Static groups guarding the richest caches; weak alone, dangerous in numbers
- Slowly **haul cheese away** if left alone — caches decay
- **Function:** the best economy costs a PvE fight, and a team fighting ants is
  a team you can jump.

### Rats — neutral, and hireable

- Hold the single best cache; a real fight for two or three mice
- **Bribed with 5 cheese** to fight for you — this is the Juggernaut (§4)
- **Function:** connects PvE directly to the economy and the class system

### Sprinkler / hazards — the learnable clock

- Fixed cycle on a visible timer, floods a lane, pushes and slows
- `[DECIDE]` Does water **flood shallow tunnels**? Thematically perfect, mechanically
  a great reason to dig deep, and it makes plane 1 situationally worthless. Tempting.

> **Density rule:** at most **one major world event active at a time**, with deliberate
> quiet windows for clean PvP.

---

## 8. Maps

**Fixed bones, shuffled details.** Players master the skeleton across matches; variation
keeps it fresh.

| Fixed every match | Shuffled every match |
|---|---|
| Nest positions | Prop placement and cover |
| Major lanes and chokepoints | Which caches are rich vs. poor |
| Diggable regions and bedrock | Which cache the rats hold |
| Hazard locations | Hazard timing offsets |
| Cache point locations | Minor route blockages |

> **Not everything is diggable.** Bedrock zones (under the patio slab, the concrete
> path) are permanent constraints that give each map an underground personality and
> stop tunnels from becoming a featureless free-for-all.

### Planned maps

**Backyard BBQ** (first, matches the concept art) · **The Picnic** · **The Alleyway** ·
**The Field**

### Backyard BBQ — from concept art

| Feature | Role |
|---|---|
| Blue nest (NW) / Red nest (SE) | Bases, banner spawns, cheese stores |
| Cardboard box (center) | Central high ground, sightline control |
| Drainpipe (N) & log tunnel (W) | Surface-level covered flanks |
| Tree stump (SW) | Mid platform, mid-lane cover |
| Brick piles | Low cover, sightline breaks |
| Trash can + flowerpot (E) | Vertical cluster, rich cache, hard to hold |
| Garden hose (E) | Soft wall / ramp |
| Open dirt paths | Fast, fully exposed — where the cat and crow hunt |
| Patio slab | **Bedrock** — no digging, forces surface play in the east |
| Fence line | Boundary, with **one gap** as a deep flank |

---

## 9. Controls

- **WASD** — movement
- **Mouse cursor** — aim
- **Left click** — primary attack
- **Right click / Q, E, F** — abilities
- **Shift (hold)** — Sprint, draining team cheese (§2)
- **Tab** — scoreboard / cheese ledger
- `[DECIDE]` Dig controls — cursor-direction + hold? Discrete segment-by-segment commits?
  This is the Engineer's entire moment-to-moment experience and deserves its own pass.

---

## 10. HUD

From the concept art, which is already right:

- **Top left** — objective reminder
- **Top center** — team scores + match timer
- **Bottom left** — minimap (flags, cat, teammates, **all tunnel planes**)
- **Bottom center-left** — event feed + chat
- **Bottom center-right** — **Cheese Stores, both teams** — the second-most important
  number on screen, because it's lives
- **Bottom right** — flag carrier portraits with health

Additions needed beyond the art:

- **Depth indicator** — surface, 1, 2, or 3
- **Cheese drain warning** when Sprint is burning the pool
- **Telegraph banners** for world events ("THE CAT IS COMING")

---

## 11. Progression

**In-match only.** No meta-progression, no unlocks, no persistent stats. Cheese spending
(§2) is the entire progression system and it resets every match.

> `[DECIDE]` Cosmetic hats are the only meta system worth considering later — pure
> content, zero balance surface.

---

## 12. Prototype class order

All four are core, but they don't arrive at once. Recommended order:

1. **Engineer + Scout** — proves digging, sonar, and the hidden-information layer.
   The riskiest and most valuable pair. If this isn't fun, nothing else matters.
2. **Bruiser** — completes the counterplay web with collapse and corking.
3. **Generalist** — simplest and best-understood; add once there's a flag game worth running.

---

## 13. Open questions, ranked by leverage

1. **Does digging read on screen?** (§3) The signature system's biggest risk.
2. **Dig controls** — what does the Engineer actually *do* with their hands? (§9)
3. **Can the flag enter tunnels?** (§2) Recommend no.
4. **Does water flood shallow tunnels?** (§7) Tempting, big consequences for plane 1.
5. **Deliberate breaching** — can an Engineer choose to break into enemy tunnels? (§3)
6. **Scout concealment model** (§4)
7. **Is the Generalist's flag-carry gate too strong?** (§4)
8. **World event density** (§7)
