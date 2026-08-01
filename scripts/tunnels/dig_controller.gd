extends Node
## Digging and vertical transit (GDD section 9). Point at a tile, hold the dig button, and it
## opens. E takes whichever shaft the tile you're standing on has; F sinks one down, R breaks
## one up.
##
## POINT AND HOLD, rather than the drive-forward extrusion this replaced. Extruding meant the
## tunnel went wherever you were walking, which is fast but gives you no way to say "that one"
## -- and it shared its key with the shaft, so the tile you most wanted to dig away from was
## the tile that had already claimed the button. Aiming at a tile is slower per cell and much
## more deliberate, and it costs the player nothing to learn because the cursor is already the
## steering wheel.
##
## THE PLANE IS STATE, not a reading taken off the player's height. It used to be derived every
## frame, which was fine until the player was halfway down a ramp and the answer flipped under
## them mid-dig. Nothing walks between planes now -- you are on the layer this controller last
## put you on.

@export var network_path: NodePath
@export var player_path: NodePath

@export_group("Digging")
## Seconds of held input to open one tile. Deliberately brisk for testing; the real number is
## a per-plane balance dial (GDD section 3 gives deeper planes longer dig times).
@export var dig_seconds: float = 0.5
## How far from the mouse a tile can be and still be diggable, in cells. Stops you reaching
## across the map with the cursor -- you dig at arm's length, which is also what keeps the
## Engineer stationary and vulnerable while they work.
@export var dig_reach: float = 2.6

@export_group("Transit")
## How far above the destination floor the mouse is placed when it moves between layers.
@export var arrival_lift: float = 0.05

var _network: TunnelNetwork
var _player: Node3D
var _plane: int = 0
var _target: Vector2i = Vector2i.MAX
var _progress: float = 0.0
var _cursor: DigCursor


func _ready() -> void:
	_network = get_node_or_null(network_path) as TunnelNetwork
	_player = get_node_or_null(player_path) as Node3D
	if _network == null:
		return
	_apply_plane()
	_cursor = DigCursor.new()
	_network.add_child(_cursor)


func get_plane() -> int:
	return _plane


## 0..1 while a tile is being opened, for anything that wants to draw it.
func get_dig_progress() -> float:
	return _progress


func _physics_process(delta: float) -> void:
	if _network == null or _player == null:
		return

	_resync_plane()
	var standing := _network.world_to_cell(_player.global_position)

	if Input.is_action_just_pressed("shaft_down"):
		_network.dig_shaft_down(_plane, standing)
	if Input.is_action_just_pressed("shaft_up"):
		_network.dig_shaft_up(_plane, standing)
	if Input.is_action_just_pressed("burrow"):
		_take_shaft(standing)
		return

	_update_dig(delta)


## Aim, hold, open. The target is re-chosen every frame from where the cursor is, and moving
## off a tile abandons it -- progress is a property of the tile you are pointing at, not of how
## long the button has been down.
func _update_dig(delta: float) -> void:
	var wanted := _aimed_cell()
	if wanted != _target:
		_target = wanted
		_progress = 0.0

	var held := Input.is_action_pressed("dig") and not _pointer_over_ui()

	# ROCK GETS ITS OWN CURSOR (GDD section 3). A seam is refused by the network, so without this
	# the cursor simply vanishes over it -- which is what "out of reach" and "not adjacent" and
	# "already dug" all look like, and the player is left to guess which of the four they have hit.
	# Pressing on it says so out loud, once per press, through the network's own refusal.
	if _target == Vector2i.MAX:
		var rock := _blocked_cell()
		if rock != Vector2i.MAX:
			if held and Input.is_action_just_pressed("dig"):
				_network.dig(_plane, rock)
				_learn_vein(rock)
			_cursor.show_blocked(_network, _plane, rock)
			_progress = 0.0
			return

	var digging := _target != Vector2i.MAX and held
	if digging:
		_progress += delta * _dig_rate() / maxf(dig_seconds, 0.01)
		if _progress >= 1.0:
			_network.dig(_plane, _target)
			_progress = 0.0
			# Re-aim immediately: the cell just opened, so it is no longer a valid target and
			# holding the button should move on to the next one rather than stall.
			_target = _aimed_cell()
	elif not held:
		_progress = 0.0

	_cursor.show_at(_network, _plane, _target, _progress, _target != Vector2i.MAX and held)


## Running into a seam teaches your crew where it goes (GDD section 3).
##
## HERE RATHER THAN IN `dig()`, because the network knows what the rock is and this knows who hit
## it. Passing a team down into every dig and shaft call would put a parameter that only rock cares
## about on four functions that mostly don't, and bots -- which never dig -- would have to supply it
## anyway. The dig controller is already the one object that pairs a player with a cell.
##
## ON THE PRESS, not on the hover. The cursor already goes grey over rock you are pointing at, and
## that is the right amount to give away for free: one cubic metre, while you look at it. Learning
## the shape of the whole vein costs an action -- you swing at it and find out it rings.
func _learn_vein(cell: Vector2i) -> void:
	if _player == null:
		return
	# Asked of the node rather than typed, like `get_dig_speed` above it: this controller is pointed
	# at a Node3D on purpose, so a map can drive it with something that is not a Mouse.
	var side: Variant = _player.get("team")
	if side == null:
		return
	_network.reveal_vein(_plane, cell, int(side))


## How fast whoever is driving opens a tile, as a multiplier on `dig_seconds`.
##
## THE ENGINEER IS THE DIGGER, BUT NOT THE ONLY ONE. GDD section 4 made terrain alteration the
## Engineer's exclusive capability; this is a deliberate revision, recorded in that section. An
## Engineer opens a tile in `dig_seconds`; everyone else takes about three times as long, which
## is slow enough that you would not choose to tunnel as a Generalist and fast enough that you
## CAN when it is the only way through. The alternative -- nobody else digs at all -- makes a
## crew that has lost its Engineer unable to use a third of the map, and turns one seat into a
## requirement rather than a choice.
##
## Asked of the mouse rather than looked up here, so the number arrives with whoever the
## controller is pointed at and a mouse with no class still answers 1.0.
func _dig_rate() -> float:
	if _player != null and _player.has_method("get_dig_speed"):
		return maxf(0.01, _player.call("get_dig_speed"))
	return 1.0


## Whether the cursor is over a piece of UI rather than over the world.
##
## Digging reads the mouse button by POLLING rather than from an input event, which is right
## for a hold-to-act control but means it never sees the UI consume a click. Without this you
## dig a tile every time you drag a slider on the look panel -- tuning the picture by editing
## the level. Asking the viewport who is hovered covers any future UI for free, and the HUD
## labels don't count because Label ignores the mouse by default.
func _pointer_over_ui() -> bool:
	var viewport := get_viewport()
	return viewport != null and viewport.gui_get_hovered_control() != null


## The cell under the cursor, if it is one this player could legally open.
##
## Must touch the tunnel you already have. Without that you could stand in one corridor and
## carve an unconnected room across the arena, which is neither snake-like (GDD section 3) nor
## something the reachability of the network could survive.
func _aimed_cell() -> Vector2i:
	if _plane <= 0 or not _player.has_method("get_aim_point"):
		return Vector2i.MAX

	var aim: Vector3 = _player.call("get_aim_point")
	var cell := _network.world_to_cell(aim)
	if _network.is_dug(_plane, cell) or not _network.in_bounds(cell):
		return Vector2i.MAX

	var here := _network.world_to_cell(_player.global_position)
	if Vector2(cell - here).length() > dig_reach:
		return Vector2i.MAX

	if _network.is_rock(_plane, cell):
		return Vector2i.MAX

	for side: Vector2i in TunnelNetwork.SIDES:
		if _network.is_dug(_plane, cell + side):
			return cell
	return Vector2i.MAX


## The cell under the cursor when it is rock you could otherwise have dug.
##
## Everything `_aimed_cell` asks except "is it soft", so the cursor only calls a seam out where the
## alternative really was a dig. A grey box lighting up over rock across the arena would say the
## seam mattered from there, and it doesn't -- you cannot reach it.
func _blocked_cell() -> Vector2i:
	if _plane <= 0 or not _player.has_method("get_aim_point"):
		return Vector2i.MAX

	var aim: Vector3 = _player.call("get_aim_point")
	var cell := _network.world_to_cell(aim)
	if not _network.is_rock(_plane, cell) or not _network.in_bounds(cell):
		return Vector2i.MAX

	var here := _network.world_to_cell(_player.global_position)
	if Vector2(cell - here).length() > dig_reach:
		return Vector2i.MAX

	for side: Vector2i in TunnelNetwork.SIDES:
		if _network.is_dug(_plane, cell + side):
			return cell
	return Vector2i.MAX


## Step into the shaft under or over you.
##
## No hole is opened and nothing is dropped through: the floor stays solid and the mouse is
## placed on the layer it arrived at. That keeps the ground something you can always run over
## -- you enter a tunnel because you chose to, not because you walked across the wrong tile.
func _take_shaft(_cell: Vector2i) -> void:
	if TunnelTransit.destination(_network, _player, _plane) < 0:
		return

	# THE FLAG CANNOT ENTER A TUNNEL (GDD section 2, decided). The rule itself lives in
	# TunnelTransit, which is the one door between the surface and the network and refuses
	# everybody equally. Said out loud HERE, though, and only here: this is where a player meets
	# it, and a refusal you can hear is a rule you can learn. A bot hitting the same wall says
	# nothing, or the one channel that explains the controls fills up with AI chatter.
	var why := TunnelTransit.refusal(_player)
	if why != "":
		_network.dig_refused.emit(why)
		return

	var arrived := TunnelTransit.take(_network, _player, _plane, arrival_lift)
	if arrived < 0:
		return
	_plane = arrived
	_target = Vector2i.MAX
	_progress = 0.0


## Keep the remembered plane honest if the player ends up somewhere it doesn't explain.
##
## Holding the plane as state is what removed the mid-transit ambiguity, but state can go stale
## in ways a derived value never could: fall_guard respawns you on the lawn without telling
## anyone, and the controller would go on believing you were three layers down -- masked to a
## collision layer you had left, digging into a plane you were not on.
func _resync_plane() -> void:
	var expected := _network.plane_y(_plane)
	if absf(_player.global_position.y - expected) <= TunnelNetwork.SPACING * 0.5:
		return
	_plane = _network.plane_at_height(_player.global_position.y)
	_apply_plane()
	_target = Vector2i.MAX
	_progress = 0.0


## Tell the body which layer it is on.
##
## Asks the MOUSE first, because a mouse's collision mask carries a second thing this controller
## knows nothing about: the crew layers that make enemies body-block and allies pass through
## (GDD section 6). Setting the mask straight from the network would wipe them, and the bug that
## produces -- teammates suddenly solid, enemies suddenly not -- looks nothing like a digging
## bug and would be hunted for in the wrong file.
func _apply_plane() -> void:
	if _player.has_method("set_plane"):
		_player.call("set_plane", _plane)
	elif _player is CollisionObject3D:
		_network.apply_plane_collision(_player as CollisionObject3D, _plane)
