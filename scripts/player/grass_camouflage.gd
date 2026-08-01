extends Node
## The other half of the grass tell: in cover, moving slowly makes you HARD TO SEE.
##
## GDD section 8 describes grass as concealment and the bend as what gives you away, but a
## mouse that stays fully opaque in a patch isn't concealed by anything -- the bending would
## be a tell about someone you could already see perfectly well, which is no tell at all. The
## trade only exists if being still buys you something, and this is what it buys.
##
## SAME CURVE AS THE BEND, on purpose. The grass reads speed through `quiet_speed` to
## `loud_speed` and so does this, so the two can never disagree about which rung you're on:
## you cannot be invisible while tearing a wake, or visible while leaving the grass untouched.
## One number decides both, which is what makes the mechanic teachable -- what you see happen
## to the grass IS what is happening to you.
##
## EVERY MOUSE, not just the player. It was the player's alone through M2.5 because there was
## nobody else in the arena; the moment bots exist, a mechanic that only conceals you is not a
## mechanic, it's a cheat. It also means the thing you're looking for while crossing a lane is
## exactly the thing they're looking for -- which is the whole reason the tell is worth reading.
##
## Deliberately NOT the Sneak's camouflage (GDD section 4). That is a class ability that stacks
## on top of this and needs its own shader. This is the floor everybody stands on.

## How much of your own colour survives when perfectly still in deep cover. Not zero: hidden
## information (GDD section 3) is about not being FOUND, never about being unhittable once you
## have been, and a shape nobody can resolve at all is a bug report rather than a mechanic.
@export_range(0.0, 1.0, 0.01) var hidden_opacity: float = 0.10
## Opacity at a full sprint through cover. High, because sprinting is meant to give you away
## -- this is the same rung that tears the loudest wake.
@export_range(0.0, 1.0, 0.01) var moving_opacity: float = 0.80
## Opacity while spending cheese to move (Scurry, GDD section 9). Fully visible: the boost is
## a burst of speed bought with a life, and buying speed should never also buy stealth.
@export_range(0.0, 1.0, 0.01) var boosted_opacity: float = 1.0

## How fast the fade follows the speed that drives it. Smoothed rather than instant, because
## the input is a measured velocity that jitters against walls and over rocks -- and a mouse
## that flickers is far more visible than one that is simply there.
@export var fade_speed: float = 6.0

@export var grass_path: NodePath

var _grass: Node3D
## mouse -> its current opacity, so each fades on its own clock.
var _opacity: Dictionary = {}


func _ready() -> void:
	_grass = get_node_or_null(grass_path) as Node3D
	if _grass == null or not _grass.has_method("concealment_at"):
		push_warning("grass camouflage: no grass at %s -- concealment is off" % grass_path)
		set_process(false)


## How visible this mouse is right now, 0..1 -- the smoothed figure actually on screen, not the
## target. Exposed because spotting.gd decides what reaches the minimap with it: what your crew
## can pick out has to be the same thing your eyes can pick out, or concealment means two
## different things and neither is teachable.
func opacity_of(mouse: Mouse) -> float:
	return _opacity.get(mouse, 1.0)


func _process(delta: float) -> void:
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null:
			continue
		var material := mouse.get_body_material()
		if material == null:
			continue

		var now: float = _opacity.get(mouse, 1.0)
		now = lerpf(now, _wanted_opacity(mouse), 1.0 - exp(-fade_speed * delta))
		_opacity[mouse] = now

		# Straight alpha. The two predecessors of this line -- a dither, then a blend toward the
		# grass colour -- both existed only to stay out of the transparent queue, because the
		# pixel pass used to erase whatever was in it. It runs after transparency now, so the
		# honest version works and fades correctly against whatever is actually behind the mouse.
		var colour := mouse.team_color
		colour.a = now
		material.albedo_color = colour


## How visible this mouse should be, before smoothing.
##
## Concealment scales the whole effect rather than gating it, so standing in the fringe of a
## patch hides you PARTLY. A yes-or-no test would make the rim of every patch a hard line to
## sit exactly on, and the rim is meant to be a risk, not a hiding place.
func _wanted_opacity(mouse: Mouse) -> float:
	# CARRIERS ARE ALWAYS VISIBLE (GDD section 2). No hiding with the flag -- the rule exists so
	# a steal has to be run home rather than parked in a bush until the coast clears, and it is
	# the same rule that floats the banner above the carrier's head where everyone can see it.
	if mouse.is_carrying() or mouse.is_scruffed():
		return 1.0

	var cover: float = _grass.concealment_at(mouse.global_position)
	if cover <= 0.0:
		return 1.0

	# Scurry is not built yet -- it needs the cheese economy, which is M6. Asking the mouse
	# rather than assuming false means this starts behaving correctly the day it lands, and the
	# question is worth asking now because the ANSWER is a design decision: buying speed must
	# not also buy stealth.
	var exposed := mouse.is_boosting()
	var moving: float = _grass.speed_tell(mouse) if _grass.has_method("speed_tell") else 1.0
	var in_cover := lerpf(hidden_opacity, moving_opacity, moving)

	# Full cover reaches the concealed value; no cover is fully visible.
	return lerpf(1.0, boosted_opacity if exposed else in_cover, cover)
