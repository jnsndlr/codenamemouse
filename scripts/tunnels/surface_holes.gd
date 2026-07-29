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
## Wide enough for the mouse plus its collision radius, so the walls of the hole don't
## catch the capsule on the way down.
@export var hole_radius: float = 0.78

var _holes: int = 0


func _ready() -> void:
	use_collision = true
	var network := get_node_or_null(network_path) as TunnelNetwork
	if network != null:
		network.entrance_cut.connect(_on_entrance_cut)


## Both ramp cells get a hole. Only punching the first leaves a lip the player walks into
## halfway down.
func _on_entrance_cut(cell: Vector2i, step: Vector2i) -> void:
	for at: Vector2i in [cell, cell + step]:
		var hole := CSGCylinder3D.new()
		hole.operation = CSGShape3D.OPERATION_SUBTRACTION
		hole.radius = hole_radius
		hole.height = 4.0
		hole.sides = 12
		hole.position = Vector3(at.x * TunnelNetwork.CELL, 0.0, at.y * TunnelNetwork.CELL)
		hole.name = "Hole%d" % _holes
		_holes += 1
		add_child(hole)
