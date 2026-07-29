extends Node
## Continuous drive digging (GDD section 9): hold dig and steer, the tunnel extrudes
## behind you. Press ramp to cut a descent to the next plane down.
##
## Continuous input, discrete state. The player moves smoothly and steers with the cursor;
## what gets stored is whichever grid cell they crossed into. That's the compromise the
## implementation plan is built on -- replication stays one small message per cell, while
## the hands feel like they're drawing rather than clacking between eight directions.

## Cutting diagonally leaves two cells touching only at a corner, which is a pinch the
## player cannot walk through. Digging one orthogonal filler turns it into an L. Without
## this the tunnel looks continuous from above and isn't.
const FILL_DIAGONAL_CORNERS: bool = true

@export var network_path: NodePath
@export var player_path: NodePath

var _network: TunnelNetwork
var _player: Node3D
var _last_cell: Vector2i = Vector2i.MAX
var _last_plane: int = -1


func _ready() -> void:
	_network = get_node_or_null(network_path) as TunnelNetwork
	_player = get_node_or_null(player_path) as Node3D


func _physics_process(_delta: float) -> void:
	if _network == null or _player == null:
		return

	var plane := _network.plane_at_height(_player.global_position.y)
	var cell := _network.world_to_cell(_player.global_position)

	if Input.is_action_just_pressed("ramp"):
		_cut_ramp(plane, cell)

	if Input.is_action_pressed("dig"):
		_extrude(plane, cell)
	else:
		_last_cell = Vector2i.MAX
		_last_plane = -1


## Dig whatever cell the player has walked into. Only meaningful underground -- on the
## surface there is nothing to extrude into, so the way down is a ramp.
func _extrude(plane: int, cell: Vector2i) -> void:
	if plane <= 0:
		return

	if plane != _last_plane:
		_last_cell = Vector2i.MAX
		_last_plane = plane

	if cell == _last_cell:
		return

	if FILL_DIAGONAL_CORNERS and _last_cell != Vector2i.MAX:
		var step := cell - _last_cell
		if step.x != 0 and step.y != 0:
			_network.dig(plane, Vector2i(cell.x, _last_cell.y))

	_network.dig(plane, cell)
	_last_cell = cell


## Ramps run along a cardinal direction because GridMap orientations are orthogonal. The
## facing gets snapped to the nearest of the four, which in practice is invisible -- you
## point roughly where you want to go and it commits.
func _cut_ramp(plane: int, cell: Vector2i) -> void:
	var step := _cardinal(_player.get_facing_direction() if
		_player.has_method("get_facing_direction") else Vector3.FORWARD)
	if step == Vector2i.ZERO:
		return

	# From the surface this is an entrance; from underground it's a descent.
	if _network.dig_ramp(plane, cell, step):
		_last_cell = Vector2i.MAX


func _cardinal(direction: Vector3) -> Vector2i:
	if absf(direction.x) < 0.0001 and absf(direction.z) < 0.0001:
		return Vector2i.ZERO
	if absf(direction.x) > absf(direction.z):
		return Vector2i(signi(roundi(signf(direction.x))), 0)
	return Vector2i(0, signi(roundi(signf(direction.z))))
