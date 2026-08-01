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
## ONLY WHAT SOMETHING READS. The plan's sketch also lists `carry_capacity`, which belongs to
## cheese and is M6's. A number nobody reads is a number that is quietly wrong by the time it is
## first used -- so it arrives with the system that needs it, not before.

## For the roster and the swap prompt.
@export var display_name: String = "GENERALIST"
## Three letters, for a HUD row with a health bar to fit on it as well.
@export var tag: String = "GEN"

@export_group("Body")
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
