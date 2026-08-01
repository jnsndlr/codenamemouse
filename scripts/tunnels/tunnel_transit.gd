class_name TunnelTransit
extends RefCounted
## Stepping into a shaft. One implementation, for everyone who can do it.
##
## THE SAME REASON `mouse.gd` EXISTS. Through M3 this lived inside dig_controller.gd, which is
## the player's script, because the player was the only thing that could go underground. M4 sends
## bots down the same holes, and a second implementation would mean the two could disagree about
## the one rule that matters here -- that the banner cannot go down (GDD section 2). A rule with
## two copies is a rule with an exception nobody wrote down.
##
## NO HOLE IS OPENED AND NOTHING FALLS. The floor stays solid and the mouse is placed on the
## layer it arrives at. Running over a shaft has to stay safe: you go underground because you
## chose to, never because you crossed the wrong tile at speed.
##
## The refusal is separate from the act, so the player's controller can say WHY out loud while a
## bot simply doesn't go. A refusal broadcast to the HUD every time an AI reconsiders would turn
## the one channel that explains the controls into noise.

## A carrier trying to take the objective out of play. The one rule this file exists to hold.
const CARRYING: String = "the banner will not go underground"
## Too big for the hole (GDD section 4). Nothing is, yet -- all four classes fit and the
## Juggernaut is the one that will not. Checked anyway, because the class data already carries
## the answer and the alternative is a hired rat that quietly walks down a shaft at M8.
const TOO_BIG: String = "too big for the tunnels"


## Which plane this mouse would arrive at, or -1 if the tile it is on has no shaft.
##
## A tile with no shaft is NOT a refusal -- it is simply a tile, and pressing the key there
## should do nothing rather than explain itself.
static func destination(network: TunnelNetwork, mouse: Node3D, plane: int) -> int:
	if network == null or mouse == null:
		return -1
	return network.shaft_target(plane, network.world_to_cell(mouse.global_position))


## Why this mouse may not take the shaft it is standing on, or "" if it may.
static func refusal(mouse: Node3D) -> String:
	if mouse == null:
		return ""
	if mouse.has_method("is_carrying") and mouse.call("is_carrying"):
		return CARRYING
	if mouse.has_method("can_enter_tunnels") and not mouse.call("can_enter_tunnels"):
		return TOO_BIG
	return ""


## Take it. Returns the plane the mouse ended up on, or -1 if it went nowhere.
##
## Checks the refusal itself rather than trusting the caller to have asked. This is the only
## door between the surface and the network, and a rule enforced at a door that can be walked
## around is decoration -- see the two gates the flag rule is held at (match_director.gd).
static func take(network: TunnelNetwork, mouse: Node3D, plane: int, lift: float = 0.05) -> int:
	var target := destination(network, mouse, plane)
	if target < 0 or refusal(mouse) != "":
		return -1

	var cell := network.world_to_cell(mouse.global_position)
	mouse.global_position = network.cell_to_world(target, cell) + Vector3.UP * lift
	if mouse is CharacterBody3D:
		(mouse as CharacterBody3D).velocity = Vector3.ZERO

	# Asks the MOUSE, because a mouse's collision mask carries something this file knows nothing
	# about: the crew layers that make enemies body-block and allies pass through (GDD section 6).
	# Writing the mask straight from the network would wipe them, and the bug that produces --
	# teammates suddenly solid, enemies suddenly not -- looks nothing like a digging bug.
	if mouse.has_method("set_plane"):
		mouse.call("set_plane", target)
	elif mouse is CollisionObject3D:
		network.apply_plane_collision(mouse as CollisionObject3D, target)
	return target
