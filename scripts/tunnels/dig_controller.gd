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
	if _player is CollisionObject3D:
		_network.apply_plane_collision(_player as CollisionObject3D, _plane)
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

	var digging := _target != Vector2i.MAX and Input.is_action_pressed("dig")
	if digging:
		_progress += delta / maxf(dig_seconds, 0.01)
		if _progress >= 1.0:
			_network.dig(_plane, _target)
			_progress = 0.0
			# Re-aim immediately: the cell just opened, so it is no longer a valid target and
			# holding the button should move on to the next one rather than stall.
			_target = _aimed_cell()
	elif not Input.is_action_pressed("dig"):
		_progress = 0.0

	_cursor.show_at(
		_network, _plane, _target, _progress,
		_target != Vector2i.MAX and Input.is_action_pressed("dig")
	)


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

	for side: Vector2i in TunnelNetwork.SIDES:
		if _network.is_dug(_plane, cell + side):
			return cell
	return Vector2i.MAX


## Step into the shaft under or over you.
##
## No hole is opened and nothing is dropped through: the floor stays solid and the mouse is
## placed on the layer it arrived at. That keeps the ground something you can always run over
## -- you enter a tunnel because you chose to, not because you walked across the wrong tile.
func _take_shaft(cell: Vector2i) -> void:
	var target := _network.shaft_target(_plane, cell)
	if target < 0:
		return

	_plane = target
	_player.global_position = (
		_network.cell_to_world(target, cell) + Vector3.UP * arrival_lift
	)
	if _player is CharacterBody3D:
		(_player as CharacterBody3D).velocity = Vector3.ZERO
	if _player is CollisionObject3D:
		_network.apply_plane_collision(_player as CollisionObject3D, target)
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
	if _player is CollisionObject3D:
		_network.apply_plane_collision(_player as CollisionObject3D, _plane)
	_target = Vector2i.MAX
	_progress = 0.0
