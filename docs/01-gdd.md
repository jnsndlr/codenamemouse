# Codename: Mouse — Game Design Document

> The **what**. Systems, rules, numbers. Values marked `[ASSUMED]` are starting points
> chosen to be tuned, not defended. `[DECIDE]` marks a real open question.
>
> Read [`00-intent.md`](00-intent.md) first — it settles arguments this doc starts.

---

## 1. Match at a glance

| | |
|---|---|
| Players | **One player = one mouse.** 5v5 `[ASSUMED]` — raised from 4v4 at M5: five is the smallest crew that carries a full-time Engineer *and* a Sneak without giving up the defender or the raid, and the two specialists are what the hidden-information layer is made of |
| Match length | 8 minutes, or first to 3 captures `[ASSUMED]` |
| Camera | Fixed orthographic isometric, ~45° yaw / ~40° pitch, follow with lookahead |
| Control | **Cursor steers**, W/S/A/D move relative to facing, hotkey abilities (§9) |
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
| Brute | -30% (already slow; the flag adds less proportionally) |
| Sneak | **-40%** (tiny mouse, big flag) |

> **The handoff play falls out of these numbers.** The Sneak is the best class at
> *stealing* the flag and the worst at *carrying* it — a fleeing Sneak is slower than a
> chasing Generalist. So the natural play becomes: Sneak breaks in and grabs it,
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
| **Scurry** | 1 | ~2s burst of real speed, well above sprint. Personal cooldown ~15s. |
| **Hire a Rat** | 5 | Respawn as the Juggernaut for one life (§4) |
| **Barricade** | ~~2~~ **0** | Engineer wedges a boulder across a tunnel. `[REVISED]` **Built free at M4**, priced in cooldown and supply instead — see §4 for why an ability should not be priced against a resource that has no sinks yet. |

**Scurry is the interesting one.** Sprint is free and every mouse has it (§9) — Scurry is
the one you *buy*. A single button that turns a losing chase into a won one, paid for with
a teammate's respawn. Everyone sees the number drop the instant you press it, and everyone
knows who pressed it.

- Available to **every class**. It's a spend, not an ability.
- **Multiplies your current speed** rather than setting a flat one — so it does *not*
  erase the flag carry penalty, and a Scurrying Sneak is still a worse carrier than a
  Scurrying Generalist. The handoff play survives contact with the boost button. This is
  the important constraint on Scurry; don't relax it.
- **Refills sprint stamina** on use, which is what makes it feel like a second wind rather
  than a stat buff.
- `[DECIDE]` The name. "Scurry" is the working title; "Super Scurry" also on the table.

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

| Plane | Dig time | Collapse (Brute) | Flooding (water) |
|---|---|---|---|
| **0 — Surface** | — | — | Puddles, slows |
| **1 — Shallow** | Fast | **Vulnerable** | Drains fast |
| **2 — Mid** | Slower | Harder | Moderate |
| **3 — Deep** | Slowest | **Immune** | **Floods worst — water pools here** |

**Every plane has a threat, so no depth is strictly best.** Shallow tunnels are fast to
build and vulnerable to collapse. Deep tunnels are slow investments, safe from the
Brute — but water runs downhill, and the deep network is the sump. It floods hardest
and drains slowest.

That inversion is the balance backbone of the whole system: the Engineer's answer to
the Brute (dig deeper) is itself answered by the world (deep floods). Neither answer
is free, and neither is permanent.

### Digging mechanics

- Tunnels are built from **discrete chunks**. Each new segment **pivots off the end of
  the previous one** — pick a direction, dig, repeat. Snake-like, not free-form carving.
- Digging is **interruptible** and leaves the Engineer stationary and vulnerable.
- **Shafts** connect adjacent planes, and are the only vertical transit. An Engineer sinks
  one downward (**F**) or breaks one upward (**R**) on the tile they're standing on, and
  **E** takes whichever shaft the tile has. `[REVISED]` — this was ramps, which were the
  only vertical transit precisely so you *couldn't* dig straight down.
- **A tile can't have a shaft up and a shaft down**, so E always has exactly one
  destination and no modifier key.
- **Shafts keep an exclusion radius of one cell. `[DECIDED]`** No shaft may go in any of the
  eight cells touching an existing one, diagonals included, and the rule reaches across
  adjacent planes — a shaft is a hole in one plane's floor *and* in the ceiling below it, so
  a floor hole beside a ceiling hole is still two mouths a stride apart in one corridor.
  Together with the rule above, this is what keeps the old constraint's intent: you can't
  drill a well from the lawn to the deep plane, and you can't get around that by walking it
  down a 2×2 staircase either. To go deeper you tunnel sideways first, in the open, where it
  costs time and can be seen — **depth stays a horizontal investment**. It is also what keeps
  each beam of daylight legible: two mouths a cell apart merge into one bright patch, and the
  thing that is supposed to announce *the way out is here* stops saying where.

  > **Why shafts replaced ramps.** A ramp was sloped, oriented and two cells long, and hung
  > down through the whole headroom of the plane below — so digging under one was a trap,
  > turning one across your own corridor sealed the tunnel off, and the world had to be deep
  > enough for a walkable slope, which made tunnels too deep to see into from above. A shaft
  > is a flag on a flat tile. It takes no walkable space away and occupies nothing below, so
  > digging can only ever *add* connectivity. See the M2 findings in the implementation plan.
- **Entrances** are on the surface and are visually subtle to the enemy.
- **Intersecting tunnels connect.** If your segment runs into an enemy tunnel, the
  networks join. That's a designed feature — accidentally breaking into their highway
  is a great moment, and it means deep enemy networks can be invaded rather than only
  detected.

### Breaching enemy networks `[DECIDED]`

**Accidental unless you have detection.** You can't deliberately target an enemy tunnel
you haven't revealed — running into one is a discovery, and a memorable one. A Sneak sonar mark
is the location a later targeted breach can use; it does not reveal the connected route.

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
**Built (M4)** — an authored footprint (`scripts/maps/no_surface_zone.gd`) that refuses
a shaft touching plane 0 and nothing else: digging along under the paving, and sinking
deeper beneath it, are both untouched, which is what makes it a no-*surface* zone rather
than a wall. Refused from the lawn and from underneath in different words, and while you
are under one the prompt above your head says so, because finding out you are committed
at the moment you wanted out is finding out too late.

> **The rule is a rectangle, not the slab.** The paving it draws is a grey box standing in
> for real geometry, so the day a map has a modelled patio the model parents underneath and
> nothing that enforces the rule changes. It also means the zones can be laid before the
> map is designed, which is the order these two things actually got built in.

**Rock obstructions** — solid blocks that stop horizontal digging, scattered across
depth planes. Critically, **each plane has its own layout**: plane 2 may be blocked
where plane 1 is open, and vice versa. **Built (M4)** — seeded seams in
`tunnel_network.gd`, laid as random walks rather than discs so the edges are ragged, at
9% of plane 1 rising to 16% of plane 3. A seam refuses the dig *and says so*, a shaft
refuses to sink onto one, and the face where a corridor meets one is drawn in stone, so
you learn where the rock is by paying for the knowledge rather than by being told.

> **Deeper is rockier, which is a second dial pointing the same way as dig time.** §3
> already makes the deep planes slower to cut; making them more obstructed as well is what
> keeps plane 1 worth using once you know the map. If the two ever need to disagree, this
> is the one to move — dig time is felt every cell, rock only at the moment it stops you.

> **Nests keep a clear radius.** A seeded layout that walled a crew in would do it in
> exactly the same place every single match, which reads as the map being broken rather
> than as a hard start.

**What a seam teaches you, once you've hit it. `[DECIDED]`** Running into rock reveals the
**whole connected vein** — not the one cell — and reveals it **to your crew only**. From then
on it is drawn in its own colour on the ground above it, and it appears on the minimap for
the plane you're standing on. The cell you spent is the price; the shape of the vein is what you
bought, and the other crew still has to pay for its own copy.

> **Two ways to hit it, and the quiet one is the one that matters.** Swinging the cursor at a
> seam and being refused counts — but so does simply **opening the cell beside it**, which draws
> its face in stone. That is what actually happens in play, and it has to count: the cursor greys
> out over rock specifically to tell you not to hold the button there, so a rule that waited for
> the head-on version would almost never fire.

> **Why the vein and not the cell.** A seam is one object — it was grown as one — and chipping
> along a wall a tile at a time to map something you can already see the shape of is bookkeeping,
> not discovery. What you actually learn when the shovel rings is *"this seam is here"*.

> **Why per crew, and why this one first.** This is the first knowledge in the game that one crew
> has and the other doesn't, and it is deliberately the small one: rock never moves, so getting
> the shape of per-team knowledge right here is free rehearsal for M5, which has to do it for
> tunnels and sightings where the answer changes every second.

> **The minimap shows one plane, not four.** Stacked, the layouts smear into "there is rock
> somewhere", which is the one thing you already knew. The value of per-plane layouts is that
> they *differ*, so the panel answers "what is in my way, here" and the answer changes as you
> climb.

**Boulders** — rock you can see. Lumps lying on the lawn that block movement above ground and
shut the cells directly beneath them on **plane 1 only**, so the way past one is to go *under*
it. **Built (M4)** — `boulder_field.gd` scatters them from a seed, snapped to the dig grid, one
to four cells each. Both crews know what a boulder is sitting on from the first second, because
it is standing there in daylight.

> **They are the counterweight to the seams, which is the whole reason they exist.** A seam
> charges you to find out where it is; a boulder tells you for free. Having only the first makes
> "where is the rock" one question with one answer, and makes the surface tell you nothing about
> the earth under it.

> **A Brute breaks them, five swings per cell.** A four-cell boulder is twenty swings and can be
> opened **a quarter at a time**, which makes clearing one a decision about how much you want — a
> gap to dig through, or the rock gone — rather than a countdown you either finish or waste. It
> also gives the Brute a second job that isn't fighting, above ground this time, and it is the
> first of the destructible clutter (branches, sticks) the world is meant to be full of.

> **Why per-plane obstructions are the good idea here.** They turn digging into a real
> 3D routing problem rather than a flat maze repeated three times. Sometimes the only
> way past an obstruction is to ramp down, go around on a different plane, and ramp back
> up — which makes ramps meaningful, gives each plane its own character, and means map
> knowledge extends *downward*. Learning a map means learning four floors of it.

### Vision — the hidden information layer

The asymmetry here is the best thing in the system:

| Situation | What you see |
|---|---|
| **In your own tunnel** | **Lit far ahead** — your crew hung the lamps, and the map shows the whole floor plan |
| **In an enemy tunnel** | **Unlit**, and mapped by direct line of sight only. You are crawling blind. |
| **On the surface** | Nothing underground, unless revealed — except a shaft mouth, which is a hole in the lawn |
| **Sneak sonar active** | **Q** briefly traces nearby geometry exactly one layer below, then leaves one shared cant mark |

**The darkness is the fog** `[DECIDED]`. Rather than occluding an enemy corridor or veiling it,
nothing lights it: a lamp is a thing a crew hung in its own network, so theirs is a hole you
brought no lamp into. **Daylight down a shaft is exempt** — a beam is the sun, not a lamp. An enemy
mouth therefore announces itself from the dark, which is the one thing an intruder gets for free
and the way back out of a corridor you cannot read.

**Sight puts enemy ground on your map, and time takes it off again.** A cell one of your crew can
actually see is added and starts ageing the moment nobody can see it — the same memory as a spotted
mouse, so the staleness rule is learned once. A corridor bending away stops at the bend: a breach
tells you where you *are*, never where the route *goes*. Seeing a cell never makes it yours.

**Sonar is a glimpse followed by a point, not permanent geometry.** It sounds a five-cell radius
on the plane directly below the Sneak. The answering cells show through the floor for a moment;
the nearest answer remains as a small thieves'-cant rune in the world and on the crew minimap.
The mark says *a tunnel is here* without saying where it goes.

Cant has class counterplay. Everyone on the owning crew can read its marks. On the enemy crew,
only a Sneak can see them; from arm's reach that Sneak presses **Q** to erase one instead of
scanning. Marks persist until cleared.

Raiding an enemy network should feel genuinely frightening — you don't know what's
around the corner and they do.

### Movement — size matters `[REVISED]`

~~Speed underground scales **inversely with class size**.~~ **Everyone moves at their own
surface speed underground (M4).** Size still decides who *fits* — the Juggernaut cannot enter at
all, which is the one hard, thematic constraint left here.

| Class | Tunnel speed | Effect |
|---|---|---|
| Sneak / Generalist / Engineer / Brute | **Normal** | The tunnel is a route, not a class tax |
| Juggernaut | **Cannot enter** | Too big. A hard, thematic constraint. |

> **Why the penalty went, and it was the Brute that killed it.** At 0.35 a Brute crossing its own
> tunnel was slower than everyone else was on the lawn *above* it. That does not read as a cork,
> it reads as a class quietly locked out of a third of the map: the tunnel stops being a route it
> can use and becomes a place it gets caught. Digging is the signature system, and a class tax on
> using it is the wrong shape of trade — the Brute already pays for its bulk in turn rate, sprint
> duration and carry penalty, and every one of those applies *everywhere* rather than taking a
> map away.
>
> **The cork survives, as geometry rather than as speed.** A corridor is one cell wide and mice
> body-block the other crew (§6), so a Brute standing in one is still a plug — it just gets to
> arrive at the plug in a reasonable amount of time. `Mouse.move_speed` floors the multiplier at
> 1.0, so a class can still be made *faster* underground if that ever earns its keep; it cannot be
> made slower by editing a resource.

### Collapse — the counter

> **The Engineer has its own, opposite version of this, and it is built (M4).** One cell, at
> arm's length, from *inside* the tunnel — sealing the way you came. The Brute's is the one
> described below: from above, at range, on somebody else's network. See the `[DECIDE]` in §4.

- A **Brute collapses a tunnel from the surface** by slamming the ground above a
  known segment.
- Mice caught inside are **scruffed** by the cave-in.
- The segment is destroyed and must be re-dug.
- **Only works on planes 1–2.** Deep tunnels are immune (see table above).
- **Requires knowing where the tunnel is** — which is why Sneak sonar feeds directly
  into Brute collapse. Two classes, one combo.

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

### Brute — the wall

| | |
|---|---|
| Fantasy | The big one who says "not through here" |
| Stats | High health, slow, heavy damage |
| **Unique capability** | **Brings tunnels down.** `[REVISED]` **Built** — the whole of un-digging, in two postures: **`Q` underground** caves in the one cell you are pointing at, at arm's length; **`Q` on the lawn** is a **stomp** that drops a small patch of the layers beneath your feet (planes 1–2 only). |
| Ability | *Slam* — short-range knockback; **makes carriers drop the flag**. Still to build. |
| **Shifts rock** | **Built (M4)** — the only class that breaks a barricade (3 swings) or a boulder (**5 per cell**, so a four-cell rock is 20 and comes apart a quarter at a time). Anyone else may swing at one all day. |
| Underground | Very slow, but **plugs a tunnel completely** |
| Weakness | Cannot chase, cannot flank, exposed in open ground |
| Role | Nest defense, chokepoints, tunnel denial, sabotage |

> `[REVISED]` **The cave-in moved here from the Engineer, and that closes the `[DECIDE]` this
> section has carried since M4.** The two classes were written with the same verb pointed at each
> other — the Engineer sealing from inside as an escape, the Brute collapsing from the surface as
> denial — on the theory that *where you are standing* was difference enough to make them separate
> capabilities. It is not. They are one mechanic in two postures, and a mechanic split across two
> classes is a mechanic neither of them owns, which is the exact opposite of what Pillar 4 asks
> for. So the Brute takes all of it, and **both postures survive as the two forms of one key** —
> which is the better outcome anyway, because the split was always the interesting part of the
> design and it turned out not to need two classes to express it.

> **The stomp is not aimed, and that is what makes the Sneak worth fielding.** The cave-in is
> aimed because you can see the corridor you are sealing. On the lawn you can see nothing, so
> aiming would be pointing at grass and hoping — the stomp is centred on the Brute's own feet
> instead. That makes the answer to *where do I stomp* a **cant mark on the minimap**: a Sneak
> finds the tunnel, and the Brute walks over and puts a foot through it. §5's web has been a
> diagram with a missing middle since M5; this is the link.

> **A stomp over nothing still goes off, and still costs the cooldown.** A stomp that refused
> when it found no tunnel would answer *"is there something under me?"* for free, anywhere, on
> demand — a Brute could pace the yard tapping `Q` and read the enemy's whole network off which
> presses bounced. That is §3's pillar leaking through a guard clause, and it would be invisible
> from inside a match. Ten seconds is what the knowledge costs a crew that has no Sneak to tell
> them.

> **The patch tapers with depth, and the floor is a design number rather than a consequence.**
> Full radius on the layer directly below, one cell narrower for each layer under that: five
> cells on plane 1, one cell on plane 2, nothing on plane 3. A foot through a roof does not shake
> the cellar evenly. And **plane 3 is out of reach no matter how the radius is tuned**, because
> "dig deeper" is the Engineer's whole answer to a Brute and the web is only a loop while that
> answer exists.

> **Paving stops a stomp.** You cannot stamp through a slab, so the earth under the patio is the
> one earth a Brute cannot reach from above — which quietly makes a no-surface zone (§3) a thing
> the Engineer routes *toward* rather than only a thing that refuses it a way out.

> **Breaking things is a role, not a one-off.** Barricades and boulders share one interface
> (`scripts/classes/breakable.gd`), so the branches, sticks and other destructible clutter the
> yard is meant to be full of arrive as new objects rather than as new rules — and the swing that
> resolves them is already written. Each object carries its own hit pool, which is what lets a
> big thing come apart in pieces instead of on one long timer.

### Engineer — the digger

| | |
|---|---|
| Fantasy | The one who changes the map |
| Stats | Low damage, medium health, medium speed |
| **Unique capability** | **Puts barriers up.** `[REVISED]` **Built (M4)** — the *Barricade* row below is now the whole of it. Un-digging has gone to the Brute. |
| Digging | **~3× faster than anyone else.** Others can manage it in a pinch. `[REVISED]` |
| Ability | *Barricade* — a boulder heaved across a tunnel. `[REVISED]` **Built (M4)** — `X`, aimed at the open cell beside you. **No cheese**: ten seconds between placements, three standing at once, and **only a Brute can shift one**. |
| Weakness | Weakest attack in the game. Cannot win a fight, only shape one. |
| Role | Map control, route creation, fortification |

> **`[REVISED]` Everyone digs; the Engineer is simply good at it.** This entry used to read
> *"Digs tunnels and builds ramps. Nobody else alters terrain."* Exclusivity turned out to be
> the wrong lever: it makes one seat a **requirement** rather than a choice, and a crew that
> loses its Engineer is locked out of a third of the map — three whole planes — until it
> respawns. Now the dig speed carries the identity instead. An Engineer opens a tile in about
> half a second; everyone else takes roughly three times as long, which is slow enough that you
> would never *choose* to tunnel as a Generalist and fast enough that you can when it's the only
> way through. Tuned in `resources/classes/*.tres` (`dig_speed`), not in code.
>
> ~~**Pillar 4 still holds, but it now rests on the other half of the fantasy.** The Engineer's
> one-thing-nobody-else-can-do moves from *making* tunnels to **unmaking** them.~~ `[RESOLVED]`
> **The `[DECIDE]` that used to sit here is settled, and it went the Brute's way.** The collision
> was real: §3 gave *Collapse* to the Brute as **its** unique capability, and the split being
> worked to — the Brute from the surface as denial, the Engineer from inside as escape — was one
> verb held by two classes. A verb two classes share is a verb neither owns, so un-digging is now
> entirely the Brute's, in both postures, on one key. This entry's own fallback line is what
> happened: **the Engineer's exclusive is *Barricade* alone.**
>
> **What the Engineer keeps is making and shaping, and that is a cleaner line than the one that
> ran through the middle of a verb.** Three times the dig speed, and the one thing that can stand
> in a corridor without destroying it. The class that **builds** the map and the class that
> **unbuilds** it are two different people now.
>
> **The cost is real and is worth naming: the Engineer has lost its escape button.** A corridor
> it dug is no longer a corridor it can close behind itself, so fleeing down your own tunnel is
> now a matter of geometry and head start rather than a key. The barricade is a *delay* in the
> same situation, not a seal — you buy seconds and the chaser gets them back. **This is the open
> question the change creates**, and it is a playtest question rather than a design one: if the
> Engineer turns out to be uncatchable without it, the answer is a barricade tuned to buy longer,
> not the cave-in coming back.
>
> `[REVISED]` **Barricade costs no cheese, and the price is cooldown and supply instead.** This
> entry, and §2's spending table, put it at 2 cheese. The economy does not exist until M6 and the
> cheese ledger currently has nothing that spends it, so pricing an ability against it now would
> mean tuning the ability twice — once against a resource with no sinks, and again when the sinks
> arrive and the number turns out to mean something else. **Ten seconds between placements and
> three standing at once** are limits you feel in the moment rather than in an account balance,
> and they are what shape the play: an Engineer working against a Brute has a live budget rather
> than an ammunition count, because a cleared barricade gives the slot back. When M6 lands, cheese
> can be added on top if the ability turns out to be too cheap — that is a much easier
> conversation than unpicking a price nobody has ever paid.
>
> **The Brute is the counter, and this is where §5's web gets its second real edge.** Nobody else
> shifts a barricade, which gives the Brute a reason to be underground that is not fighting, and
> makes an Engineer's seal something the other crew answers with a *class choice* rather than with
> patience. It is also the first thing in the game one class builds and another removes.
>
> **A barricade is not a cave-in, and the difference is the point** — and now the two are held by
> opposite crews' answers rather than by one class's hands, which sharpens it. A cave-in is
> permanent, instant, kills the corridor and buries whoever is standing there. A barricade is a
> delay: the corridor still exists, you can see down it, and it comes back. **Denial and tempo,
> and neither class can do the other's.**

> **Aimed, not automatic, and that is the load-bearing detail** — of the *underground* form,
> wherever it lives. "Cave in behind you" reads as something that should happen to the cell you
> just left, for free, while running. It is aimed with the cursor instead — which, since the
> cursor is the steering wheel (§9), means turning to look at what you're sealing and therefore
> not running for a moment. That is the same trade §9 asks for around throwing while fleeing.
> Written for the Engineer, and it survived the move to the Brute unchanged, which is the
> strongest evidence the reasoning was about the *verb* rather than about the class.

### Sneak — the glass cannon

| | |
|---|---|
| Fantasy | The one you don't see until it's too late |
| Stats | **Lowest health**, fastest, **highest burst damage** |
| **Unique capability** | **Sonar** — briefly sounds one layer below and leaves contestable thieves' cant for the team |
| Ability | *Fade* — hard to see while moving slowly; broken by attacking or sprinting |
| Weakness | Dies to anything that touches them. Loses every fair fight. |
| Role | Scouting, assassin, counter-Engineer, cache raider |

**Concealment model `[DECIDED]`: camouflage while stationary.** Octopus-style — a shader
samples the surrounding terrain and blends the Sneak into it. Effectiveness scales with
cover quality: strongest in shadow and tall grass, weak in open dirt. **Moving breaks it.**

This makes the Sneak an *ambush* class rather than a roaming invisible threat: stop,
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
| **Constraint** | **Cannot enter tunnels.** Surface only. **Cannot sprint** (§9). |
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

> **Built (M4).** `scripts/classes/class_swap.gd`. **C** at your own nest cycles to the next
> class, with the prompt above your head saying what you'd become. The rule is asked of the
> **nest itself** rather than of a swap-point prop, so it is automatically the same disc a
> capture needs and the same one a respawn puts you on — three things that would otherwise
> drift apart. That also means the respawn case above needs no second mechanism: you come back
> standing in the place where swapping works. **Not while scruffed** — lying on your own nest
> for six seconds shouldn't double as shopping time.

---

## 5. The counterplay web

Every class answers another, and the answers route through the dig system:

```
  Engineer digs a route (shallow = fast, deep = safe)
        │
        ▼
  Sneak sonar finds it ──────▶ reveals geometry to their team
        │                              │
        │                              ▼
        │                    Brute collapses it (planes 1–2 only)
        │                              │
        ▼                              ▼
  Engineer digs deeper (plane 3)  Mice inside scruffed
        │
        ▼
  Brute corks the tunnel ◀──── Sneak can't get past
        │
        ▼
  Generalist takes the surface route with the flag
```

No hard counters — every answer costs position, cheese, time, or exposure. Note how
**depth is the Engineer's answer to the Brute**, paid for in dig time.

> **The middle of this diagram is now built, and it is the first time the web has been a loop
> rather than a wish.** *Sneak sonar finds it → Brute collapses it → Engineer digs deeper* was
> three boxes with only the first one implemented: sonar has left cant marks since M5, and there
> was nobody who could act on one. The **stomp** is the second box (§4), and the plane-3 floor is
> what keeps the third box a real answer rather than a delaying tactic.
>
> Two properties of the stomp exist purely to serve this diagram, and both are worth reading as
> web decisions rather than as ability decisions. It is **unaimed**, so a Brute needs to be told
> where to stand — which is the arrow from sonar, and the only thing in the game that makes one
> class's information another class's action. And it **never refuses for finding nothing**, so a
> Brute cannot substitute for a Sneak by probing; the arrow points one way.

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

> `[DECIDE]` Team collision? Enemy collision makes Brute body-blocking work. Ally
> collision would apply it to teammates too — interesting but frustrating.
> Recommend: enemies collide, allies pass through. **Exception:** in tunnels, the
> Brute cork should probably block allies too, or corking is meaningless.

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

- **Sprinting** (§9) tears a loud, unmistakable wake — visible clear across a lane
- **Running** through grass leaves an obvious, fast-moving wake
- **Walking** bends it subtly
- **Moving slowly** bends nothing at all

> The bottom tier is **Shift/Slow** (§9). Without it the quietest thing a keyboard player
> could do is Run, and half this table would only exist for controller players feathering
> the stick.

**How visible you are while in it** `[DECIDED]` — the other half, and the half that makes
the bending worth reading. A mouse that stays fully drawn in a patch isn't concealed by
anything, and the wake would then be a tell about someone you could already see:

| In cover, moving at | Opacity |
|---|---|
| **Still, or Slow** | **10%** |
| Run | ~50% |
| **Sprint** | **80%** |
| **Scurry** (§9, costs cheese) | **100%** |

**Ten percent in thick grass is basically invisible — but it gives some chance.** That is
the intended reading, not a number to be talked upward later. Someone who stops moving in
deep cover should be genuinely lost, and finding them should feel like catching a flicker
rather than like spotting a target. It is never zero, because hidden information (§3) is
about not being *found*, never about being unhittable once you have been.

> **Scurry is fully visible on purpose.** Buying speed with cheese must not also buy
> stealth, or the economy becomes the strictly-best way to move unseen and Slow stops being
> the stealth tier at all.

> **One curve drives both the bend and the opacity.** The rung you are on decides how hard
> the grass moves *and* how solid you are, from the same number — so you can never be
> invisible while tearing a wake, or exposed while leaving the grass untouched. That
> equivalence is what makes the system teachable without a tutorial: what you see happen to
> the grass **is** what is happening to you.

> **Concealment fades at the patch rim** rather than switching on at a boundary. A hard edge
> makes the rim a line to sit exactly on; a soft one makes it a real place with real risk.

This is the best system in the doc for one reason: **it's hidden information that isn't
a class ability.** Every class gets to make the stealth/speed tradeoff, everyone can read
the tell, and it costs no cooldowns or resources. The Sneak is simply *better* at it
(camouflage stacks with grass), rather than being the only participant.

> **Implementation:** a vertex shader displacing grass blades from nearby character
> positions and velocities. Standard technique, cheap, and it looks great in motion.
> Concealment is **plain transparency** — the mouse fades against whatever is actually behind
> it. Getting there meant moving the pixel pass to run *after* the transparent pass; before
> that it repainted the frame from an opaque-only capture and erased anything translucent, and
> the two workarounds for it (dithering, recolouring toward the grass) both looked worse than
> the thing they replaced. **Grass is worth the render-pipeline work.** Fading is now available
> to anything that wants it, which the Sneak's camouflage (§4) will.

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

## 9. Controls and movement

### The scheme `[DECIDED]`

**The cursor is the steering wheel.** Your mouse always faces it. W drives you that way.
W/S/A/D are relative to **your facing**, not to the camera.

| Input | Does |
|---|---|
| **Mouse** | **Steers.** Facing follows the cursor at a capped turn rate. Also aims thrown weapons, barricades, and dig direction. |
| **W** | Forward, toward the cursor |
| **S** | Backpedal — still facing forward |
| **A / D** | Sidestep left/right — still facing forward |
| **Double-tap W** | **Sprint** (below). Hold on the second tap. |
| **Left click** | Primary attack, in the direction you're facing |
| **Right click / Q, E, F, X** | Abilities. `[REVISED]` **X was added at M4** — Q is the cave-in and E and F both turned out to be shafts, so the table had run out of seats for the Engineer's second capability. |
| **Space** | **Scurry** — the cheese boost (§2) `[ASSUMED]` |
| **Shift (hold)** | **Slow** — the quiet tier. Minecraft's crouch, and it should feel like it. |
| **Tab** | Scoreboard / cheese ledger |

Nine times out of ten you are holding W and moving the mouse. S and A/D are situational —
circling someone in a scrap, peeling off from the cat, backing out of a tunnel.

> **Why the cursor steers, reversing the earlier call.** Cursor *aiming* was tried at M1
> alongside WASD movement and read as twitchy — but that was a cursor with no job except
> pointing the body, so every idle wrist flick spun the mouse for no reason. Making the
> cursor the *steering wheel* fixes that: a wrist flick is now a deliberate turn, because
> turning is the only thing it does. It also puts steering and sprinting under one hand
> and leaves the left hand for abilities, which is the actual ergonomic win.
>
> The old scheme's weight came from facing lagging behind travel, which meant the mouse
> visibly crabbed sideways during direction changes. Here movement is *derived from*
> facing, so the two can never disagree — and the turn-rate cap still supplies the weight,
> now as a body that takes a moment to swing around rather than one pointing the wrong way.

> **Turn rate is per-class, and it's free characterisation.** The Sneak whips around; the
> Brute commits to a heading. Costs one number per class and does real work — it's why
> you can juke a Brute and can't juke a Sneak.

> **Double-tap W over hold-shift `[DECIDED]`.** Minecraft's approach. No extra finger, no
> stretch, no key held for thirty seconds at a time.

> **Shift is Slow `[DECIDED]`.** Also Minecraft's paradigm — crouch — and worth taking the
> whole way: a held key, a visibly lowered posture, and a deliberate, careful feel. It's
> the quiet tier tall grass (§8) needs, it's how a Sneak sets up an ambush, and it's the
> only way a keyboard player gets under the Run noise floor.
>
> Slow overrides Sprint while held, so you can't be quiet and fast. That's the point.

> **Controller is the same scheme, not a port.** Left stick = W/S/A/D with analog in
> between. Right stick = the mouse. Sprint on **L3**, Scurry on a bumper. One set of rules
> across both devices, one code path, nothing to re-learn. The analog stick gets the
> walk/run continuum for free; keyboard needs a discrete key for it.

> **The backpedal-and-throw is a skill, not a problem.** The cursor steers *and* aims, so
> you cannot wind up a thrown acorn at someone behind you while running away — unless you
> swing the cursor round and switch to S. That's a real thing to learn, it looks great when
> someone pulls it off mid-chase, and it's exactly the kind of earned mastery that costs
> nothing to design. Keep the coupling; don't add a separate aim modifier to "fix" it.

### The speed ladder `[DECIDED]`

Three tiers, and they are three different systems on purpose:

| Tier | How | Costs | Feels like |
|---|---|---|---|
| **Slow** | Hold Shift | Nothing but time | Careful. Crouched. Setting something up. |
| **Run** | Default. Just press W. | Nothing | Your normal speed |
| **Sprint** | Double-tap W | **Personal stamina** | A short push you can spend freely |
| **Scurry** | Space | **1 team cheese** (§2) | A real boost. A decision. |

On a controller the bottom two tiers are one input — feather the left stick and you get the
whole Slow-to-Run continuum for free. Keyboard needs the discrete key, which is what Shift
is for.

**Sprint is per-class stamina, not economy.** Every mouse has it. What differs is how long
you can hold it and how fast it comes back — small quick mice run far, big ones don't.

| Class | Sprint duration `[ASSUMED]` | Regen delay | Full refill |
|---|---|---|---|
| **Sneak** | **6.0s** | 1.5s | 4s |
| Generalist | 4.0s | 2.0s | 6s |
| Engineer | 3.0s | 2.5s | 7s |
| Brute | **1.5s** | 4.0s | 10s |
| **Juggernaut** | **Cannot sprint** | — | — |

- **Sprint speed is a uniform multiplier** (~+40% `[ASSUMED]`) for everyone. The class dial
  is **duration**, not speed — one number per class, and it stacks with base speed so the
  Sneak ends up far and away the best sprinter without a second knob.
- **Stamina is personal and visible only to you.** It is not a team resource and never
  appears on the enemy's screen.
- Sprint **breaks Sneak camouflage** and leaves the loudest wake in tall grass (§8).
- `[DECIDE]` Can you sprint in a tunnel? Tight quarters argue no, and it would give the
  underground its own tempo. Cheap to try either way at M2.

> **Why splitting sprint off cheese is the right correction.** Sprint-as-cheese made the
> most common movement input in the game an economic decision, which meant either you felt
> guilty for moving or you stopped noticing the cost — and both of those are worse than
> having no cost. Moving fast should be free and constant; *beating someone who is already
> moving fast* is what's worth a life. Pillar 3 is intact — cheese still buys advantage —
> it just buys a moment instead of a movement key.

### Dig controls `[DECIDED]`

**Continuous drive.** Hold the dig key and steer with the cursor; the tunnel extrudes
behind you as you go. It's Dig Dug, and it should feel good in the hands.

> Cursor steering (§9) matters more here than anywhere else in the game. Drawing a curve
> with the mouse produces a tunnel that reads as *dug*; stair-stepping one out of eight
> keyboard directions produces a staircase. The scheme change makes the 8-way snapping
> below far more likely to survive — you're aiming at a heading, not clacking between them.

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
- **Sprint stamina** — personal, near the mouse rather than parked in a corner, so you
  read it without looking away from the chase. Yours only; never shown for anyone else.
- **Contextual control hints — above the mouse's head. `[DECIDED]`** This is the one place
  they go. A prompt that is true only right here and right now (`[E] climb up` on a shaft,
  and whatever follows: opening a cache, hauling a body, boarding a rat) is the same kind of
  information as stamina — personal, momentary, needed without looking away — so it lives in
  the same place, screen-space text projected just above the mouse. Permanent bindings are
  the opposite kind of information and stay in the corner. Mixing them is what made the first
  E prompt invisible: a hint true on one tile in a thousand cannot share a line with six that
  are always true, or it reads as background text and you walk over the hole. One line at a
  time, so two contextual actions at once resolve by urgency rather than stacking.
  Implemented in `scripts/ui/contextual_hint.gd`.
- **Scurry ready/cooldown** — and a hard, unmissable tick on the team cheese counter the
  moment anyone spends one. The whole point of Scurry costing a life is that the team sees
  it happen (§2).
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

1. **Engineer + Sneak** — proves digging, sonar, and the hidden-information layer.
   The riskiest and most valuable pair. If this isn't fun, nothing else matters.
2. **Brute** — completes the counterplay web with collapse and corking.
3. **Generalist** — simplest and best-understood; add once there's a flag game worth running.

> **The order held, and step 2 is where the design moved.** The Engineer and Sneak went first and
> the Brute followed, exactly as written — but building it in that order is what revealed that
> "the Engineer un-digs" and "the Brute collapses" were the same capability described twice. That
> is the argument for this ordering restated as evidence: the collision was invisible while only
> one half existed, and it was obvious the moment the second class needed its own reason to exist.
> Corking is still geometry rather than code (§4), and *Slam* is still to build.

---

## 13. Open questions, ranked by leverage

1. **Does digging read on screen?** (§3) Answered by building, not deciding — see M2.
2. **Does 8-way snapping feel organic enough?** (§9) If not, escalate to free-angle.
3. **Water timings** — source duration, spread rate, drain rate, breath length. All
   playtest values; the system is decided, the numbers are not. (§7)
4. **World event density** (§7) — pure playtest.
5. **Is the Generalist's -10% the right gap?** (§2)
6. **Do class-specific carry penalties make Sneak-steals-Generalist-runs *mandatory*
   rather than *natural*?** Watch for it. (§2)
7. **Sprint stamina numbers** (§9) — the spread between Sneak and Brute is the real
   question, not the absolute values. Pure playtest.
8. **Is Scurry at 1 cheese too cheap?** (§2) It should feel like a decision, not a
   cooldown. If people press it on reflex, raise the cost before touching the effect.

**Resolved:** cursor steers and W/S/A/D move relative to facing · sprint is free,
per-class stamina · sprint on double-tap W, Shift is Slow · cheese buys Scurry, not
sprint · Scurry multiplies speed so it can't erase the flag carry penalty ·
flag cannot enter tunnels · dig via continuous drive on a snapped grid ·
primary attack on left click, digging moved to the ability button (right click) ·
carriers are visible because the banner rides above their head, and concealment switches off ·
breaching is accidental unless sonar-marked · networks interleave at junctions · water
flows from sources with current and breath · Sneak camouflages while stationary ·
tall grass bends to movement · per-class flag carry penalties · obstructions are
per-plane · maps are seeded from fixed anchors · shared + signature world events ·
class switching free at own nest · zero cheese = 20s respawn · one currency ·
**un-digging is the Brute's alone, cave-in underground and stomp from the surface, and the
Engineer's exclusive is Barricade** (§4)
