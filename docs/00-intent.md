# Codename: Mouse — Intent

> This doc is the **why**. It is short on purpose. When a design argument comes up
> and the GDD doesn't settle it, this doc is the tiebreaker.
>
> Conventions: `[DECIDE]` marks a call that is genuinely yours and hasn't been made yet.
> `[ASSUMED]` marks a default chosen so we could keep moving — overwrite freely.

---

## Pitch

Two crews of mice fight over cheese in the places people leave behind — a backyard
BBQ, an abandoned picnic, an alleyway. They dig tunnels, build barricades, steal each
other's flags, and try not to get caught in the open when something much larger
wanders through.

**Codename: Mouse** is a top-down isometric, class-based capture-the-flag game about
playground rules at mouse scale: simple enough to explain in twenty seconds, deep
enough to argue about for years.

---

## The fantasy

**Playground games, played by mice, for real.**

The feeling is tag and capture-the-flag — the games that show up independently on
every playground on earth — given weight, terrain, and consequence. You are small and
clever in a world built for something a hundred times your size, and your advantages
come from knowing the ground better than the other crew: which tunnel comes out behind
their nest, which lane the sprinkler kills, where the ants are guarding the good cheese.

**You are one mouse.** Never a squad, never a commander. Everything you accomplish
beyond your own four paws happens because you coordinated with someone else — which is
what makes Pillar 4 load-bearing rather than decorative.

It's **martial, not military.** Claws, tails, thrown acorns, slings, teeth. No guns.
A fight between mice should read as a scrap, not a firefight.

The tone is **light**. Mice get **scruffed** — dazed, knocked flat, sent home — they
don't die. The stakes are cheese and bragging rights. A good match ends with someone
laughing about the tunnel collapse that took out three mice at once.

---

## Influences

Useful shorthand for "what are we actually making":

| Source | What we're taking |
|---|---|
| **RuneScape: Castle Wars** | The skeleton — two bases, flag capture, tunnels, barricades, casual-friendly |
| **Team Fortress 2** | Class identity: distinct silhouettes, distinct jobs, readable at a glance |
| **Red Faction** | Terrain you dig through. The map is not a fixed given. |
| **Tooth and Tail** | Tone and register — animals at war, stylized, charming, legible from above |
| **Lemmings Paintball** | The 2.5D isometric read |
| **Playground tag & CTF** | The real north star: universal rules, instantly understood, endlessly replayed |

---

## Design pillars

Each pillar states what we do and what it rules out. A pillar that rules nothing out
isn't a pillar.

### 1. Playground rules

A new player should understand the goal in twenty seconds: *take their flag, bring it
home, don't get caught.* All depth comes from how systems interact during play — never
from rules you must read to understand.

- **Therefore:** the core loop stays brutally simple. Complexity lives in classes,
  terrain, and timing, not in the rulebook.
- **Not this:** stacking mechanics, tutorials that take longer than a match, or any
  system that needs a paragraph to explain its purpose.

### 2. The map is a weapon

Terrain is not a fixed backdrop — it is created, contested, and destroyed during the
match. Tunnels get dug, barricades get built, sections collapse. Combined with mouse
scale, this is the game's signature: everyday human places, remade under the surface
by whoever's winning.

- **Therefore:** every map is a real place (backyard BBQ, picnic, alleyway, field) with
  **fixed bones and shuffled details** — learnable across matches, never memorized flat.
- **Not this:** abstract arenas, fantasy dungeons, or static geometry that plays
  identically every time.

### 3. Cheese is lives

Cheese is the team's **respawn supply**. Every advantage — a boost, a special class, a
faster return to the fight — is paid for out of the team's ability to keep fighting.

- **Therefore:** spending is always a real decision with a visible cost, and a team's
  cheese count is a legible read on how the match is going.
- **Not this:** cheese as a second score, an abstract currency, or a resource you
  accumulate without tension.

### 4. Crews, not heroes

No class can run the flag, survive the trip, and hold the nest alone. Every class has
one thing **no other class can do at all** — not a stat advantage, a capability gate.
A capture should be legible afterwards as *a play three mice made together.*

- **Therefore:** team composition is a strategic layer, and counterplay is
  class-shaped (the Tunneler digs, the Stealth sniffs it out, the Bruiser collapses it).
- **Not this:** a solo-carry class, or flex classes that are 80% of everyone else.

### 5. The place fights back — and feeds you

PvE is not a separate mode. The world is a **third faction**: hostile to both crews,
allied to neither. It threatens, it interrupts, and critically it also **gives** —
cheese caches appear, creatures haul cheese away, hazards force a truce.

- **Therefore:** PvE controls the *pacing* of a match. It creates pressure, and it
  creates moments of respite where two exhausted crews briefly have a common problem.
- **Not this:** PvE as pure threat, as XP piñatas, or as random uncontrollable variance.
  Hazards must be **learnable** — fixed timers, clear telegraphs, no dice rolls.

### 6. Good with nobody else online

The game must be genuinely fun with **zero other humans**. This is not a fallback for
an empty lobby — it is a primary way the game is played.

Solo play is **the same match with AI in every other seat.** You are still one mouse;
bots fill your crew and the enemy crew. There is no separate campaign, no separate
mode logic, no bespoke single-player content.

- **Therefore:** bots get a real engineering budget. AI teammates and opponents must
  be good enough that a solo match is worth playing on purpose — and every improvement
  to them improves the multiplayer game too.
- **Not this:** designing anything that only works at 8 human players, treating
  single-player as a tutorial, or building a campaign as a second game.

---

## What this is not

Being explicit here saves months.

- **Not a shooter.** Martial combat, no guns. Aim is not the mastery axis.
- **Not a squad game.** One player controls one mouse. No unit selection, no commander
  layer, no switching between mice mid-match.
- **Not a campaign.** Solo is the multiplayer match with bots, not separate content.
- **Not an MMO.** No persistent world, no hub, no between-match economy.
- **Not live-service.** No battle pass, no seasons, no daily login treadmill.
- **Not grim.** No blood, no death. If a mechanic only works if it's brutal, cut it.
- **Not free-to-play monetized.** Scope assumes a hobby project. `[DECIDE]` if that changes.

---

## Casual first, deep underneath

When a balance decision forces a choice between *fair and legible for a new player* and
*deep and rewarding at 200 hours*, **the new player wins by default.**

Depth is still real, it just isn't front-loaded. It lives in:

- **Map knowledge** — the fixed bones, the shuffled details, the tunnel routes
- **Team composition** — reading the enemy's classes and answering them
- **Evolving meta** — strategies that shift within a match and across a season of play
- **Timing** — heroic pushes, well-timed defensive collapses, sabotage

A great player is one who **reads the match and responds as a team**: scouting, calling
the composition, knowing when the tunnel under their nest is worth collapsing.

---

## Reality check

Solo project, AI assistance, evenings and weekends, first game. That is not a
disclaimer — it's a **design constraint with teeth**:

- **Small matches.** 4v4 `[ASSUMED]` fills a lobby at 20 concurrent players. 10v10
  does not. Design for the population we'll actually have — which may be zero.
- **Bots are load-bearing** (Pillar 6). This is the mitigation for "no marketing, not
  a full-time job," and it happens to serve Pillar 5.
- **Content must be cheap to author.** Modular household props, grey-boxable maps,
  data-driven classes, procedural variation over hand-built map count. We will never
  have 40 maps.
- **Systems over content.** The game is interesting because of how its rules interact.

---

## Prototype success criteria

The prototype is **not** trying to be a game. It's trying to answer questions that
fifteen years of thinking cannot answer from the inside:

1. **Is the flag run tense?** Does hauling the flag home at low health with someone on
   your tail produce a story you want to tell afterward?
2. **Do tunnels carry the game?** Digging, using, finding, and collapsing tunnels is
   the signature system. Is it as good in play as it is on paper?
3. **Does "cheese is lives" create real decisions?** Do players agonize over spending,
   or does it become automatic?
4. **Does the world-as-third-faction work?** When something interrupts the match, does
   it get *better* — as threat and as respite?
5. **Do two classes want different things from the same map?** Not statistically —
   genuinely different goals.
6. **Is it fun with capsules?** If grey capsules sliding around grey boxes is already a
   little bit fun, art will make it great. If it isn't, art will not save it.

**Any of these answering "no" is a success.** Information bought cheap, before art,
before netcode hardening, before a year of work.

---

## Known risks

| Risk | Why it's real | Mitigation |
|---|---|---|
| Tunnels are hard to build | Dynamic navmesh, dug geometry, and 3D readability all at once | Prototype the *simplest possible* version — predefined tunnel nodes that unlock, not free-form digging. Prove the play before the tech. |
| Tunnels are hard to read | Underground play in a top-down view is a real UX problem | Solve legibility in grey-box, early. If players can't tell what's happening below, the signature system fails. |
| PvE reads as randomness | Casual players tolerate it; competitive ones hate it | Fixed timers, clear telegraphs, learnable behavior. Never random. |
| Bots are underestimated | Pillar 6 makes them mandatory, and good bots are genuinely hard | Budget for them explicitly. Dumb-but-fair beats clever-but-erratic. |
| Scope creep via classes | Each class multiplies the balance surface | Prototype ships with **two**. Add a third only once those two are genuinely distinct. |
| Cheese spending is fiddly | Multiple sinks (respawn, boosts, special classes) could overwhelm | Ship respawn-only first. Add one sink at a time and check it earns its place. |
| Netcode rabbit hole | Easy to spend a year here and ship nothing | Listen-server first, transport behind an interface, no optimization before there's a game |

---

## Related docs

- [`01-gdd.md`](01-gdd.md) — the **what**: systems, classes, rules
- [`02-implementation-plan.md`](02-implementation-plan.md) — the **how**: tech, architecture, milestones
