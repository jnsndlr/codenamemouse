class_name TunnelChunks
extends RefCounted
## Builds the tunnel MeshLibrary at runtime.
##
## Built in code rather than authored as a .tres because at M2 the chunk shapes are the
## thing under test -- see the implementation plan. Changing a tunnel's proportions should
## be editing a constant here and pressing play, not round-tripping through the editor.
## Once the shapes settle, bake this to a real MeshLibrary asset and delete the generator.
##
## Ramps span TWO cells rather than one. A single-cell ramp would have to drop a whole
## plane spacing over one cell width, which at any sane spacing is far too steep for
## CharacterBody3D's floor_max_angle -- the player would slide back down it.

enum { FLOOR, RAMP_UPPER, RAMP_LOWER }

const CELL: float = 1.0
## Vertical gap between planes. Also the drop a ramp has to cover across two cells, so
## raising it makes ramps steeper.
const PLANE_SPACING: float = 1.5
const FLOOR_THICKNESS: float = 0.12


## One library PER PLANE, each with its own material instance. GridMap is a plain Node3D
## with no material_override, so giving each plane a separately dimmable look means
## handing each one its own copy of the meshes. Three copies of three small meshes is
## nothing, and it's what makes the depth-focus rendering in tunnel_network possible.
static func build(material: Material) -> MeshLibrary:
	var library := MeshLibrary.new()
	var half := CELL * 0.5

	_add(library, FLOOR, "floor", _slab(-half, half, -half, half, 0.0, 0.0), material)
	# Split across two cells: 0 -> -half spacing, then -half spacing -> -spacing.
	_add(library, RAMP_UPPER, "ramp_upper",
		_slab(-half, half, -half, half, 0.0, -PLANE_SPACING * 0.5), material)
	_add(library, RAMP_LOWER, "ramp_lower",
		_slab(-half, half, -half, half, -PLANE_SPACING * 0.5, -PLANE_SPACING), material)

	return library


static func _add(
	library: MeshLibrary, id: int, name: String, mesh: ArrayMesh, material: Material
) -> void:
	mesh.surface_set_material(0, material)
	library.create_item(id)
	library.set_item_name(id, name)
	library.set_item_mesh(id, mesh)
	# Deliberately NO item shapes. Setting them produced valid shapes that never became
	# bodies in the physics world -- a raycast at a placed floor cell hit nothing, and the
	# player fell straight through. tunnel_network generates collision itself from the same
	# cell data. Leaving shapes here too would risk doubling up if that ever starts working.


## A slab whose TOP surface runs from height `y_near` at -Z to `y_far` at +Z, hanging
## FLOOR_THICKNESS below. Equal heights give a flat floor; unequal give a ramp.
##
## The top sits exactly at the plane's own Y so the walkable surface and the plane
## coordinate are the same number -- depth readouts and cell lookups both depend on it.
static func _slab(
	x0: float, x1: float, z0: float, z1: float, y_near: float, y_far: float
) -> ArrayMesh:
	var t := SurfaceTool.new()
	t.begin(Mesh.PRIMITIVE_TRIANGLES)

	var top := [
		Vector3(x0, y_near, z0), Vector3(x1, y_near, z0),
		Vector3(x1, y_far, z1), Vector3(x0, y_far, z1),
	]
	var bottom := []
	for corner: Vector3 in top:
		bottom.append(corner - Vector3(0.0, FLOOR_THICKNESS, 0.0))

	_quad(t, top[0], top[1], top[2], top[3])
	_quad(t, bottom[3], bottom[2], bottom[1], bottom[0])
	for i in range(4):
		var j := (i + 1) % 4
		_quad(t, top[j], top[i], bottom[i], bottom[j])

	t.generate_normals()
	return t.commit()


static func _quad(t: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for vertex: Vector3 in [a, b, c, a, c, d]:
		t.add_vertex(vertex)
