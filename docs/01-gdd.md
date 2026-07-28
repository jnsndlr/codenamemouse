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
- **Carrying slows you**, by an amount that depends on your size. The flag is a fixed
  size, so it's proportionally more of a burden to a small mouse:

| Class | Flag carry penalty `[ASSUMED]` |
|---|---|
| **Generalist** | **-10%** — the designated runner |
| Engineer | -25% |
| Bruiser | -30% (already slow; the flag adds less proportionally) |
| Scout | **-40%** (tiny mouse, big flag) |

> **The handoff play falls out of these numbers.** The Scout is the best class at
> *stealing* the flag and the worst at *carrying* it — a fleeing Scout is slower than a
> chasing Generalist. So the natural play becomes: Scout breaks in and grabs it,
> Generalist meets them and runs it home. That's genuine teamwork emerging from a
> stat table rather than from a designed "handoff mechanic." Preserve it.
>
> Note that even the Generalist loses 10%, so a good pursuit line can always catch a
> carrier. Nobody outruns the chase for free.

> **The flag cannot enter a tunnel.** `[DECIDED]` Otherwise tunnels become the dominant
> escape route and surface defense stops mattering. Tunnels move *mice*, not objectives —
> they get you into position, they don't get you home.

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

| Plane | Dig time | Collapse (Bruiser) | Flooding (water) |
|---|---|---|---|
| **0 — Surface** | — | — | Puddles, slows |
| **1 — Shallow** | Fast | **Vulnerable** | Drains fast |
| **2 — Mid** | Slower | Harder | Moderate |
| **3 — Deep** | Slowest | **Immune** | **Floods worst — water pools here** |

**Every plane has a threat, so no depth is strictly best.** Shallow tunnels are fast to
build and vulnerable to collapse. Deep tunnels are slow investments, safe from the
Bruiser — but water runs downhill, and the deep network is the sump. It floods hardest
and drains slowest.

That inversion is the balance backbone of the whole system: the Engineer's answer to
the Bruiser (dig deeper) is itself answered by the world (deep floods). Neither answer
is free, and neither is permanent.

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
  detected.

### Breaching enemy networks `[DECIDED]`

**Accidental unless you have detection.** You can't deliberately target an enemy tunnel
you haven't revealed — running into one is a discovery, and a memorable one. Once Scout
sonar has marked a segment, an Engineer *can* aim for it.

When two networks meet:

- The shared cell becomes a **junction** belonging to both teams.
- **Vision changes at the junction.** Your own-network wide awareness extends up to the
  junction and stops there. Past it you're in their network: line of sight and fog only.
  The junction is the boundary between knowing and not knowing.
- **You can branch your own tunnel off theirs.** An Engineer standing in an enemy tunnel
  can dig new segments that belong to *your* team. Networks interleave.
- **Breaches leave a tell** — rubble and a visible scar at the junction. The defending
  team discovers the break-in if anyone passes through. Breaching is not silent.

> This makes the underground **contested territory** rather than two private mazes,
> which is a much better fit for a game about map control. The best tunnel network in
> the match may end up being a patchwork both teams built pieces of.

### Obstructions

Two distinct kinds, and the distinction matters:

**No-surface zones** — the patio slab, the concrete path, the flagstones. You **can
tunnel underneath them**, you just **cannot place an entrance or exit** there. A tunnel
can run beneath the whole patio; it simply can't surface in the middle of it. These
create long committed crossings where you know exactly where the enemy has to come up.

**Rock obstructions** — solid blocks that stop horizontal digging, scattered across
depth planes. Critically, **each plane has its own layout**: plane 2 may be blocked
where plane 1 is open, and vice versa.

> **Why per-plane obstructions are the good idea here.** They turn digging into a real
> 3D routing problem rather than a flat maze repeated three times. Sometimes the only
> way past an obstruction is to ramp down, go around on a different plane, and ramp back
> up — which makes ramps meaningful, gives each plane its own character, and means map
> knowledge extends *downward*. Learning a map means learning four floors of it.

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
| **Unique capability** | **Carries the flag at near-full speed** (-10% vs -25/30/40%) |
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

**Concealment model `[DECIDED]`: camouflage while stationary.** Octopus-style — a shader
samples the surrounding terrain and blends the Scout into it. Effectiveness scales with
cover quality: strongest in shadow and tall grass, weak in open dirt. **Moving breaks it.**

This makes the Scout an *ambush* class rather than a roaming invisible threat: stop,
blend, wait, burst. It's fair to play against (a stationary enemy is findable, and
movement always reveals) and it rewards map knowledge — knowing which patches of shadow
are worth waiting in.

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

### Water — flowing, not binary

Sprinklers, a spilled drink, rain, a kicked-over bucket. Fixed cycle, visible timer.

Water is **simulated as flow from a source**, not as a flooded/not-flooded flag. This is
more work than a binary state and it's worth it — it's the difference between a hazard
and a set piece.

**How it works:**

- **Source points** are fixed per map (the sprinkler line, a drain, a gap under the door).
- Water **spreads outward from the source through connected cells**, in a rough circle
  with noise on the frontier so it reads as natural rather than geometric.
- Each flooded cell carries a **current vector** pointing away from the source. It pushes
  mice along it.
- Water **cascades downward through ramps.** Flooding plane 1 eventually feeds plane 2,
  then plane 3. Deep tunnels are the sump: last to fill, last to drain.

**What happens to you:**

- You can **swim**, and you can **hold your breath** — a breath meter, not an instant
  verdict. Getting caught is a problem to solve, not a coin flip.
- The **current fights you**, pushing you away from the source.
- **Ride the current to a ramp and you auto-pop up one level.** The map offers you an
  escape if you swim the right way — which rewards knowing your own network.
- **Out of air = washed out.** Swept to the nearest exit, dropping carried cheese.
  Undignified, not fatal (Pillar 5).

**The chaos moment:** when a big source runs long enough to flood two or three planes at
once, the whole underground becomes a churning mess and everyone is swimming for a ramp.
That should happen occasionally and it should be the most memorable thirty seconds of
the match. Tune source duration so it happens rarely rather than never.

> **Implementation note:** this is a cellular automaton over the tunnel graph — a
> flood-fill with a rate and a per-cell flow vector. It runs on the server and replicates
> as a set of cell IDs plus water level. Tractable, but it is *not* M2 work. Ship binary
> flooding first, upgrade to flow later. See the implementation plan.

> **Density rule:** at most **one major world event active at a time**, with deliberate
> quiet windows for clean PvP.

### Shared events vs. map signatures

Every map runs the **shared set** — cat, crow, ants, rats, water — so the fundamentals
are learnable everywhere. Each map then adds **one or two signature events of its own**,
which is where map identity comes from:

| Map | Signature event `[ASSUMED]` |
|---|---|
| Backyard BBQ | The grill — heat and falling embers over the east lane |
| The Picnic | Wasps, and a picnic blanket that gets shaken out |
| The Alleyway | Rain runoff — the biggest water event in the game |
| The Field | The lawnmower. A moving, scheduled, map-wide catastrophe. |

---

## 8. Maps

**Seeded generation with fixed anchors.** Each map is a *recipe*, not a fixed layout.
A seed generates the match's version of it within authored parameters.

| Fixed every match (the anchors) | Generated per seed |
|---|---|
| The house, patio, fence line | Yard layout, open ground vs. cover |
| Nest positions | Rocks, logs, trees, grass patches |
| Water source points | Cache locations and richness |
| No-surface zones (patio, path) | Rock obstruction layout, **per plane** |
| Overall lane structure | Which cache the rats hold |

Players learn the **anchors and the vocabulary** — where the patio is, what a rock
obstruction means, how water moves — and then read the specific arrangement fresh each
match. Mastery is transferable without any single layout being memorized flat.

> **Cost note:** procedural layout means the navmesh must bake at runtime per seed
> (Godot supports this) and bots must handle layouts nobody authored. That's real work,
> which is why the implementation plan defers generation until the systems are proven on
> a single hand-built layout.

### Tall grass — environmental concealment

Grass patches conceal mice, but **movement bends the blades**, and the bending is
visible to everyone:

- **Running** through grass leaves an obvious, fast-moving wake
- **Walking** bends it subtly
- **Moving slowly** bends nothing at all

This is the best system in the doc for one reason: **it's hidden information that isn't
a class ability.** Every class gets to make the stealth/speed tradeoff, everyone can read
the tell, and it costs no cooldowns or resources. The Scout is simply *better* at it
(camouflage stacks with grass), rather than being the only participant.

> **Implementation:** a vertex shader displacing grass blades from nearby character
> positions and velocities. Standard technique, cheap, and it looks great in motion.

> **Each map is four floors.** No-surface zones and per-plane rock obstructions (§3)
> mean the underground has as much designed personality as the surface — and a map isn't
> learned until all four planes are.

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
| Patio slab | **No-surface zone** — tunnel under it, but you can't come up until you're clear |
| Sprinkler line | Floods the east lane on a timer, and everything beneath it |
| Fence line | Boundary, with **one gap** as a deep flank |

---

## 9. Controls

- **WASD** — movement
- **Mouse cursor** — aim
- **Left click** — primary attack
- **Right click / Q, E, F** — abilities
- **Shift (hold)** — Sprint, draining team cheese (§2)
- **Tab** — scoreboard / cheese ledger
### Dig controls `[DECIDED]`

**Continuous drive.** Hold the dig key and steer with WASD; the tunnel extrudes behind
you as you go. It's Dig Dug, and it should feel good in the hands.

Underneath, cells still **snap to a grid** — continuous input, discrete state. That keeps
replication trivial (one small message per cell) and rendering cheap.

**The grid must not look like a grid.** Organic feel comes from:

- **8-way snapping minimum** (45° increments), not 4-way
- **Irregular chunk meshes** — varied cross-sections, rough walls, no repeating box
- **Placement jitter** — small random rotation and scale per chunk

> `[DECIDE]` If 8-way still reads as rigid after M2, the escalation is **free-angle
> segment placement** instead of a GridMap. The pathing and network code don't change
> (`AStar3D` takes arbitrary points, not just grid cells) — only the storage does. So
> this is a reversible decision, which is why it's safe to start with the cheap version.

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

1. **Does digging read on screen?** (§3) Answered by building, not deciding — see M2.
2. **Does 8-way snapping feel organic enough?** (§9) If not, escalate to free-angle.
3. **Water timings** — source duration, spread rate, drain rate, breath length. All
   playtest values; the system is decided, the numbers are not. (§7)
4. **World event density** (§7) — pure playtest.
5. **Is the Generalist's -10% the right gap?** (§2)
6. **Do class-specific carry penalties make Scout-steals-Generalist-runs *mandatory*
   rather than *natural*?** Watch for it. (§2)

**Resolved:** flag cannot enter tunnels · dig via continuous drive on a snapped grid ·
breaching is accidental unless sonar-marked · networks interleave at junctions · water
flows from sources with current and breath · Scout camouflages while stationary ·
tall grass bends to movement · per-class flag carry penalties · obstructions are
per-plane · maps are seeded from fixed anchors · shared + signature world events ·
class switching free at own nest · zero cheese = 20s respawn · one currency
