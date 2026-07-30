extends CSGCombiner3D
## Punches a hole in the surface wherever an entrance ramp is cut.
##
## The ground is CSG purely so this is possible. A plain mesh with a box collider would
## let you cut a perfectly good ramp and then stand on the grass unable to reach it --
## the geometry says there's a way down and the physics says there isn't.
##
## Not how the real game should do it. Per-entrance CSG subtraction on a 40x40 slab is
## fine when entrances are rare and the map is a test arena; a real map wants the surface
## authored with its own collision holes, or built from tiles that can be cleared the same
## way tunnel cells are. Revisit at M4 when entrances stop being a spike curiosity.

@export var network_path: NodePath
## Sideways inset from the ramp's width. Tiny and deliberately non-zero: the ground should
## overlap the ramp by a hair rather than risk a float-precision lip the capsule can catch,
## and it must never be NEGATIVE -- an oversized hole leaves ground missing with nothing
## beneath it, which is a hole you fall through rather than walk down.
@export var side_inset: float = 0.01
## How far past the ramp's bottom the cut runs, in cells. The mouse is nearly a whole plane
## tall, so it's still poking up through the slab as it reaches the ramp's end; without some
## overrun it clips the slab edge and stops dead halfway down.
@export var overrun_cells: float = 0.5

var _holes: int = 0


func _ready() -> void:
	use_collision = true
	var network := get_node_or_null(network_path) as TunnelNetwork
	if network != null:
		network.entrance_cut.connect(_on_entrance_cut)


## ONE continuous cut along the whole ramp, not one box per cell.
##
## Per-cell boxes each inset from their own edges leave a thin wall of slab standing in the
## seam between them -- 0.04 units of ground across the middle of the ramp, invisible, and
## exactly enough to stop the capsule dead halfway down. A single box has no seam to leave
## a wall in.
func _on_entrance_cut(cell: Vector2i, step: Vector2i) -> void:
	var cellsize := TunnelNetwork.CELL
	var travel := Vector3(step.x, 0.0, step.y)
	var start := Vector3(cell.x * cellsize, 0.0, cell.y * cellsize) - travel * (cellsize * 0.5)
	var length := cellsize * (2.0 + overrun_cells)

	var across := absf(travel.z) * (cellsize - side_inset * 2.0) + absf(travel.x) * length
	var along := absf(travel.z) * length + absf(travel.x) * (cellsize - side_inset * 2.0)

	var hole := CSGBox3D.new()
	hole.operation = CSGShape3D.OPERATION_SUBTRACTION
	hole.size = Vector3(across, 4.0, along)
	hole.position = start + travel * (length * 0.5)
	hole.name = "Hole%d" % _holes
	_holes += 1
	add_child(hole)
