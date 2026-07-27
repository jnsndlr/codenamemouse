# Codename: Mouse — Intent

> This doc is the **why**. It is short on purpose. When a design argument comes up
> and the GDD doesn't settle it, this doc is the tiebreaker.
>
> Conventions: `[DECIDE]` marks a call that is genuinely yours and hasn't been made yet.
> `[ASSUMED]` marks a default I picked so we could keep moving — overwrite freely.

---

## Pitch

A team of mice raids the neighbor's backyard for cheese and glory. Two crews, two
nests, one fence, and a cat who doesn't care whose side you're on.

**Codename: Mouse** is a top-down isometric, class-based capture-the-flag game where
the map itself is hostile. You are four inches tall in a world built for something a
hundred times your size, and every advantage you get comes from knowing the terrain
better than the other crew does.

---

## The fantasy

The feeling we are selling is **small and clever in a big dangerous place.**

Not "soldier." Not "hero." *Vermin with a plan.* You win by knowing that the gap
under the fence board comes out behind their nest, that the sprinkler kills the open
lawn every ninety seconds, and that the cat patrols the patio at dusk. Mastery is
map literacy and crew coordination, not aim.

The tone is warm, not grim. Mice get **scruffed** — dazed, knocked flat, sent home —
they don't die. The stakes are cheese and bragging rights. A match should feel like a
heist that went sideways and got funny.

---

## Design pillars

Each pillar states what we do, what it costs us, and what it rules out. A pillar that
rules nothing out isn't a pillar.

### 1. Small world, big stakes

Everyday human objects are the level geometry. A cardboard box is a fortress. A
coiled hose is a wall. A drainpipe is a flanking route. Scale is the core joke and
the core level-design vocabulary.

- **Therefore:** every map is a real place — backyard, garage, kitchen, shed, car
  interior. Never an abstract arena.
- **Not this:** fantasy dungeons, sci-fi corridors, or anything a mouse wouldn't
  plausibly be standing in.

### 2. The backyard fights back

PvE is not a mode you queue into. It is **ambient pressure inside the PvP match.**
The cat, the birds, the sprinkler, the ants guarding the good cheese — these are live
during competitive play and they are nobody's ally.

- **Therefore:** the environment gets a real AI budget and real design attention,
  and map control means controlling *hazards*, not just lanes.
- **Not this:** a separate co-op mode bolted on, or PvE mobs that are just XP piñatas.

### 3. Roles that need each other

No class can run the flag, survive the trip, and hold the nest alone. A successful
capture should be legible afterwards as *a play three mice made together.*

- **Therefore:** every class gets one thing **no other class can do at all** — not a
  stat advantage, a capability gate.
- **Not this:** a solo-carry class, or "flex" classes that are 80% of everyone else.

### 4. Readable at a glance

Fixed isometric camera. You can read the whole fight from above: who has the flag,
where the cat is, which lane is collapsing.

- **Therefore:** silhouettes over detail, bold team color, generous telegraphs on
  everything dangerous.
- **Not this:** free camera, fog-of-war that hides the fun, or visual noise that
  makes a 4-inch character illegible at iso distance.

### 5. Charming, not grim

- **Therefore:** scruffed instead of killed, comedic failure states, chat that reads
  like a crew, cheese as currency and punchline.
- **Not this:** blood, gore, or a grimdark reskin. If a mechanic only works if it's
  brutal, cut it.

---

## What this is not

Being explicit here saves months.

- **Not a twitch shooter.** Netcode precision and aim skill are not the mastery axis.
- **Not an MMO.** No persistent world, no open-world hub, no economy between matches.
- **Not a live-service game.** No battle pass, no seasons, no daily login treadmill.
- **Not free-to-play monetized.** Scope and cost assumptions in the implementation
  plan assume a hobby project, not a business. `[DECIDE]` if this ever changes.

---

## Audience and reality check

This is a solo project with AI assistance, built in evenings and weekends, by someone
doing their first game. That is not a disclaimer — it is a **design constraint with
teeth**, and it shapes real decisions:

- **Small player counts per match.** 4v4 fills a lobby at 20 concurrent players.
  10v10 does not. Design for the population we'll actually have.
- **Bots are load-bearing, not a nice-to-have.** If a match can't start with humans,
  it starts with mice-shaped AI. This also happens to serve Pillar 2.
- **Content must be cheap to author.** Modular household props, grey-boxable maps,
  data-driven classes. Anything requiring bespoke animation per item is suspect.
- **Systems over content.** The game must be interesting because of how its rules
  interact, not because there are 40 maps. We will never have 40 maps.

---

## Prototype success criteria

The prototype is **not** trying to be a game. It is trying to answer questions that
fifteen years of thinking cannot answer from the inside. It has succeeded when we can
honestly answer these:

1. **Is the flag run tense?** Does carrying cheese home with 20% health and a scout on
   your tail produce a story you want to tell afterward?
2. **Does the cheese economy add or distract?** Does the second objective layer make
   decisions richer, or does it just split attention and dilute the CTF?
3. **Does the environment as a third faction work?** When the cat shows up, does the
   match get *better*? Or does it feel like random interference?
4. **Do two classes feel genuinely different?** Not statistically — do they want
   different things from the same map?
5. **Is it fun with capsules?** If grey capsules sliding around grey boxes is already
   a little bit fun, the art will make it great. If it isn't, art will not save it.

**Any of these answering "no" is a success.** It's information bought cheap, before
art, before netcode hardening, before a year of work.

---

## Known risks

| Risk | Why it's real | Mitigation |
|---|---|---|
| Two objective layers dilute each other | Flag + cheese may split focus | Prototype cheese as an *enabler* of the flag play, not a parallel score. Cut it fast if it doesn't earn its place. |
| PvE pressure reads as randomness | Competitive players hate uncontrolled variance | Hazards must be **predictable and learnable** — fixed timers, clear telegraphs, no dice rolls |
| Scope creep via classes | Five classes is 5× the balance surface | Ship the prototype with **two**. Add a third only after those two are genuinely distinct. |
| Never finding players | No marketing, not a full-time job | Bots must make a 1-human match fun. Treat "solo vs bots" as a first-class mode, not a fallback. |
| Netcode rabbit hole | Easy to spend a year here and ship nothing | Listen-server first, transport behind an interface, do not optimize before there is a game to optimize |

---

## Related docs

- [`01-gdd.md`](01-gdd.md) — the **what**: systems, classes, rules
- [`02-implementation-plan.md`](02-implementation-plan.md) — the **how**: tech, architecture, milestones
