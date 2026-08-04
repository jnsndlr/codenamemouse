class_name MouseControls
extends RefCounted
## The set of controls a driven mouse carries, and the one place that says what they are.
##
## FITTED IN CODE RATHER THAN AUTHORED IN A SCENE, and that is forced rather than preferred. Most
## of the mice in a match do not exist when the arena is saved: bots are spawned a frame after
## `_ready`, and a remote human's mouse is built the moment somebody joins and destroyed the moment
## they leave. A control wired up in `arena.tscn` can only ever be fitted to the one mouse the
## scene already contains, which is precisely the assumption this step exists to remove.
##
## NOTHING HERE IS TUNED, WHICH IS WHY THIS IS A LIST AND NOT A SCENE. Every one of the five
## exposes its dials -- dig time, reach, cooldown, how many boulders you may hold open -- and
## `arena.tscn` set exactly none of them: the five nodes carried two node paths each and defaults
## for the rest. So there is no authored balance to lose. The day one of these wants a number that
## differs per map, it wants a resource, not a node in a scene.
##
## BOTS DO NOT GET A SET, and that is a rule rather than an oversight. A control reads the mouse's
## [InputFrame] and a bot's is always empty -- fitting five nodes that can never fire to six of the
## ten mice in a match would be five nodes' worth of tick for nothing. Bots reach the same rules by
## their own road: `bot_digger.gd` cuts earth, and a bot changes class through `ClassSwap.allowed`,
## which is deliberately the same predicate the C key asks and deliberately static so there is one
## copy of *where* a swap is legal.

## What a person's mouse carries. Named here because the names are what the audits reach for --
## `player.get_node("CaveIn")` -- and a set built out of anonymous nodes would make every suite
## search for its subject by class.
const CONTROLS: Dictionary = {
	"DigController": "res://scripts/tunnels/dig_controller.gd",
	"ClassSwap": "res://scripts/classes/class_swap.gd",
	"CaveIn": "res://scripts/classes/cave_in.gd",
	"Sonar": "res://scripts/classes/sonar.gd",
	"Barricade": "res://scripts/classes/barricade.gd",
}


## Give this mouse its controls. Called by [Player], once, from `_ready`.
##
## BY PATH RATHER THAN BY CLASS NAME, which is the one thing here worth defending. `ClassSwap`
## names `MatchDirector`, `MatchDirector` names `Player`, and `Player` is what calls this -- so
## referencing the five global classes from a file on that road closes a cycle, and this project
## already has a scar about GDScript's temper over those (see the scene-before-script note in the
## plan). Loading them keeps the graph a line. `tools/net_audit.gd` walks every script in
## `res://scripts` and asserts each one loads, so a path that goes stale is caught by the dullest
## check in the project rather than by a control that silently stops existing.
static func fit(mouse: Mouse) -> void:
	if mouse == null:
		return
	for control_name: String in CONTROLS:
		var script := load(CONTROLS[control_name]) as GDScript
		if script == null:
			push_warning("controls: %s would not load -- the mouse is missing one" % control_name)
			continue
		var control := script.new() as Node
		control.name = control_name
		mouse.add_child(control)
