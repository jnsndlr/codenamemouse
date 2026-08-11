class_name ClassDefinition
extends Resource
## What being a Brute actually means, as numbers you can edit in the inspector.
##
## A RESOURCE RATHER THAN A TABLE IN CODE, per the implementation plan: classes are the thing
## most likely to be tuned, and tuning should be an inspector edit and a reload, not a recompile.
## Four .tres files in resources/classes/, one per class, and mouse_class.gd is the registry that
## maps the enum the rest of the game uses onto them.
##
## APPLIED TO A MOUSE, NEVER READ THROUGH. `Mouse.set_class` copies these onto the mouse's own
## exported properties, and everything downstream keeps reading the mouse. That means every
## system already written -- grass, combat, carrying, the HUD -- gets per-class behaviour without
## learning what a class is, and a mouse with no definition at all still works, which is what the
## headless audits build.
##
## ONLY WHAT SOMETHING READS. A number nobody reads is a number that is quietly wrong by the time
## it is first used, so each of these arrives with the system that consumes it and not before.
## `carry_capacity` is the worked example: the plan's sketch listed it from the start, this header
## held it out until there was cheese for it to be about, and it went in the day the director began
## asking how much a mouse could hold.

## For the roster and the swap prompt.
@export var display_name: String = "GENERALIST"
## Three letters, for a HUD row with a health bar to fit on it as well.
@export var tag: String = "GEN"

@export_group("Body")
## How wide this class is, as the radius of its capsule in metres. **This is the cork** (GDD
## sections 3 and 4), and it is the one stat here whose value is decided by arithmetic rather
## than by feel.
##
## A CORRIDOR IS ONE CELL WIDE -- `TunnelChunks.CELL` is 1.0, with walls on the cell boundaries --
## so a mouse of radius `r` may stand anywhere in `|z| <= 0.5 - r`, and a mouse of radius `R`
## standing at `b` denies the band `b +/- (R + r)`. Work the two together and a corridor is sealed
## only while
##
##     0.5 - 2r - R  <=  b  <=  R + 2r - 0.5
##
## which is an empty range -- no seal at any position -- unless `R >= 0.5 - 2r`. At everyone's
## 0.16 that floor is **0.18**, and every mouse in the game has been 0.16 since M1. THE CORK HAS
## NEVER WORKED. Not "worked badly": two mice pass each other in a corridor with 2cm to spare,
## which is also why a crowd of bots stands in one another's laps on the lawn.
##
## THE BRUTE'S 0.30 IS THAT FLOOR PLUS A BAND YOU CAN AIM FOR. It seals while the Brute is within
## 12cm of the corridor's centre line, out of the 20cm of room it has -- so *standing in the
## middle* is the skill, and a Brute shoved against a wall leaves a gap somebody quick can take.
## 0.34 would make it unconditional at any position; that number is deliberately not the one
## chosen, because a wall that cannot be beaten is a door that is shut rather than a fight.
##
## AND THE OTHER THREE MUST STAY AT 0.16, which the same arithmetic forces: two mice of radius r
## can pass each other only while `3r <= 0.5`, so anything above 0.167 makes EVERY class a cork
## and takes the Brute's whole capability away by making it universal.
##
## IT IS A CYLINDER, NOT A CAPSULE, and that is forced by this number rather than chosen. Godot
## clamps a capsule's height to twice its radius, so a 0.30 capsule is 0.60 tall against a plane's
## 0.53 of headroom -- the first Brute built this way could not move underground at all. See
## `Mouse._fit_body`.
@export_range(0.08, 0.45, 0.01) var body_radius: float = 0.16
## How wide this class is DRAWN. Usually the same number; the Brute is drawn at 0.24 against a
## body of 0.30, because the width the corridor needs and the width that reads as a mouse turned
## out not to be the same width. `Mouse.model_radius` carries the argument and the caveat.
@export_range(0.08, 0.45, 0.01) var model_radius: float = 0.16
@export var max_health: float = 100.0
@export var speed: float = 3.0
## Radians per second of turn. The weight dial (GDD section 4): the Sneak whips around, the
## Brute commits to a heading.
@export var turn_speed: float = 10.0
## Seconds of sprint at full stamina. Sprint SPEED is uniform across classes; duration is what
## differs (GDD section 9).
@export var sprint_seconds: float = 4.0

@export_group("Combat")
@export var attack_damage: float = 26.0

@export_group("Carrying")
## What the banner costs you, as a fraction of your speed. THE Generalist's whole identity
## (GDD section 2 and 4): they are not "balanced", they are the one who can actually run the
## flag, and the spread across these four numbers is where the handoff play comes from.
@export_range(0.0, 0.8, 0.01) var carry_penalty: float = 0.10
## How many wedges of cheese this class can hold at once (GDD section 2).
##
## `[ARRIVED]` THIS FILE'S OWN HEADER SAID THIS FIELD DID NOT BELONG HERE YET, on the rule that a
## number nobody reads is a number that is quietly wrong by the time it is first used. The system
## that needs it is here now: `MatchDirector._check_cheese` reads it on every pickup, so it arrives
## with the thing that consumes it exactly as that rule asks.
##
## THE SPREAD IS THE POINT, AND IT IS NOT A REWARD FOR BEING BIG. Sneak 1, Engineer 2, Generalist
## 3, Brute 5. What it does is stop cheese being a job any mouse can do equally well, which is what
## it was while everyone carried one: hauling was a walk, the walk was the mechanic, and the only
## question was who happened to be nearest. Now the crew's respawn supply is *the Brute's errand*,
## and it is an errand the Brute is bad at in every other respect -- slowest in the game, worst
## turn rate, and the one class an ambush is guaranteed to catch. A Sneak can carry one wedge and
## should be doing something else.
##
## IT ALSO GIVES THE SCATTER SOMETHING TO SCATTER. A mouse going down with five wedges on it is a
## real loss and a real prize, which is what makes escorting a hauler a thing worth doing -- see
## `MatchDirector._scatter_cheese`.
##
## AND IT DOES NOT COST SPEED. Cheese has no carry penalty; the banner does. Two stacking speed
## taxes would be a second tuning axis on a speed ladder GDD section 13 already calls an open
## playtest question, and the pickup cooldown is the pacing dial that was actually wanted.
@export_range(1, 8, 1) var carry_capacity: int = 3

@export_group("Underground")
## Speed underground, as a multiplier. **A BONUS ONLY: this cannot go below 1.0.**
##
## `[REVISED]` GDD section 3 had speed scale inversely with size -- Sneak 1.25, Generalist 0.9,
## Brute 0.35 -- on the theory that a Brute in a corridor is a cork. In play it is not a cork, it
## is a player who has been quietly removed from a third of the map: at 0.35 a Brute crossing its
## own tunnel is slower than everyone else is on the lawn ABOVE it, so the tunnel stops being a
## route it can use and becomes a place it gets caught. A class tax on using the game's signature
## system is the wrong shape of trade -- the Brute already pays for its bulk in turn rate, sprint
## and carry penalty, all of which apply everywhere and none of which take a map away.
##
## Every class is 1.0 now, and `Mouse.move_speed` floors this at 1.0 so a stale resource cannot
## reintroduce a penalty by accident. The range keeps the dial for the case the design might still
## want -- a class that is genuinely FASTER underground -- because that reads as a strength rather
## than as lag.
@export_range(1.0, 2.0, 0.05) var tunnel_speed: float = 1.0
## How fast this class opens a tile, as a multiplier on the dig controller's own timing.
##
## EVERYBODY CAN DIG, and the Engineer is simply the one who is good at it. GDD section 4 made
## digging the Engineer's exclusive capability; this is a deliberate revision (see the note in
## that section). A dig you can manage in a pinch keeps the tunnel a tool the whole crew shares
## and stops a crew without an Engineer being locked out of a third of the map -- and it costs
## the Engineer nothing, because what makes them the digger is being three times faster at it
## and, shortly, being the only one who can bring a tunnel down.
@export_range(0.05, 2.0, 0.01) var dig_speed: float = 0.35
## Whether this class fits down a shaft at all. The Juggernaut (GDD section 4) will not: "too
## big" is a hard, thematic constraint and it is the one line of this file the hired rat needs.
@export var can_enter_tunnels: bool = true
