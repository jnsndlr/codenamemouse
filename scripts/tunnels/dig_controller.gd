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
	if Input.is_action_just_pressed("ramp_up"):
		_cut_ramp_up(plane, cell)

	# Starting a dig from the surface has to be the SAME key as continuing one. Requiring
	# ramp-first meant holding dig on the surface did nothing whatsoever, with no feedback
	# -- the control simply appeared broken until you happened to discover the other key.
	# One press, on the frame it goes down, so holding it doesn't carve a row of entrances.
	if Input.is_action_just_pressed("dig") and plane <= 0:
		_cut_ramp(plane, cell)

	if Input.is_action_pressed("dig"):
		_extrude(plane, cell)
	else:
		_last_cell = Vector2i.MAX
		_last_plane = -1


## Open the cell AHEAD of the player, not the one they are standing in.
##
## Digging only where the player already is deadlocks instantly: a cell is dug when they
## walk into it, but they cannot walk into solid earth, and the tunnel wall stops them at
## the face. You burrow in, take two cells, and stop forever. The tunnel has to open in
## front of you so there is somewhere to walk to -- which is also what "continuous drive"
## in GDD section 9 actually means in the hands. It's Dig Dug: you push, and the ground
## gives way ahead of you.
func _extrude(plane: int, cell: Vector2i) -> void:
	if plane <= 0:
		return

	if plane != _last_plane:
		_last_cell = Vector2i.MAX
		_last_plane = plane

	# Always keep the cell underfoot, so descending a ramp into a fresh plane is solid.
	_network.dig(plane, cell)

	if FILL_DIAGONAL_CORNERS and _last_cell != Vector2i.MAX:
		var walked := cell - _last_cell
		if walked.x != 0 and walked.y != 0:
			_network.dig(plane, Vector2i(cell.x, _last_cell.y))
	_last_cell = cell

	var ahead := _octant(_facing())
	if ahead == Vector2i.ZERO:
		return
	# A diagonal push needs its corner opened too, or the two cells touch only at a point
	# and the player is walled out of the very cell they just dug.
	if FILL_DIAGONAL_CORNERS and ahead.x != 0 and ahead.y != 0:
		_network.dig(plane, cell + Vector2i(ahead.x, 0))
	_network.dig(plane, cell + ahead)


func _facing() -> Vector3:
	if _player.has_method("get_facing_direction"):
		return _player.call("get_facing_direction")
	return Vector3.FORWARD


## Eight-way, per GDD section 9. Anything within 22.5 degrees of an axis snaps to it.
func _octant(direction: Vector3) -> Vector2i:
	var flat := Vector2(direction.x, direction.z)
	if flat.length_squared() < 0.0001:
		return Vector2i.ZERO
	var angle := flat.angle()
	var sector := wrapi(roundi(angle / (PI / 4.0)), 0, 8)
	return [
		Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
		Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	][sector]


## Ramps run along a cardinal direction because GridMap orientations are orthogonal. The
## facing gets snapped to the nearest of the four, which in practice is invisible -- you
## point roughly where you want to go and it commits.
func _cut_ramp(plane: int, cell: Vector2i) -> void:
	var step := _cardinal(_facing())
	if step == Vector2i.ZERO:
		return

	# From the surface this is an entrance; from underground it's a descent.
	if _network.dig_ramp(plane, cell, step):
		_last_cell = Vector2i.MAX


## Cut a ramp that RISES ahead of you, to the plane above.
##
## Same geometry as a descent, just authored from the bottom: a ramp is always stored on the
## upper of the two planes it joins, so ascending from plane N means cutting a descent on
## plane N-1 whose landing is the cell in front of you. From plane 1 that's an exit to the
## surface, which is simply an entrance built from underneath.
func _cut_ramp_up(plane: int, cell: Vector2i) -> void:
	if plane <= 0:
		return
	var step := _cardinal(_facing())
	if step == Vector2i.ZERO:
		return

	# Landing sits one cell ahead; the sloped pair runs on beyond it, descending back toward
	# us, so walking forward takes us up.
	if _network.dig_ramp(plane - 1, cell + step * 3, -step):
		_last_cell = Vector2i.MAX


func _cardinal(direction: Vector3) -> Vector2i:
	if absf(direction.x) < 0.0001 and absf(direction.z) < 0.0001:
		return Vector2i.ZERO
	if absf(direction.x) > absf(direction.z):
		return Vector2i(signi(roundi(signf(direction.x))), 0)
	return Vector2i(0, signi(roundi(signf(direction.z))))
