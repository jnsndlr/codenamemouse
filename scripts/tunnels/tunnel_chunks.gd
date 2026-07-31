class_name TunnelChunks
extends RefCounted
## Builds the tunnel MeshLibrary at runtime.
##
## Built in code rather than authored as a .tres because at M2 the chunk shapes are the
## thing under test -- see the implementation plan. Changing a tunnel's proportions should
## be editing a constant here and pressing play, not round-tripping through the editor.
## Once the shapes settle, bake this to a real MeshLibrary asset and delete the generator.
##
## THREE TILES, and all three are flat. Ramps are gone: vertical transit is now a shaft you
## step into with a keypress, so no tile ever has to be walked up. That deleted the entire
## sloped-geometry problem -- the two-cell split, the orientation index, the flank walls, the
## per-face height arithmetic -- and with it every bug that came from a floor that wasn't level.
##
## A shaft is NOT a hole. The floor stays solid and the tile just carries a mark, because
## falling down a shaft you meant to walk past is not a mechanic anyone asked for and a real
## hole in the collision mesh is how you end up outside the world.

## Only DOWN gets a tile. A shaft you can climb is announced by the shaft of daylight falling
## out of it instead -- see TunnelNetwork's light rays. A second painted square could only ever
## say "something is here"; a beam says where it comes from and lights the floor it lands on.
enum { FLOOR, SHAFT_DOWN, ENTRANCE }

const CELL: float = 1.0
## Vertical gap between planes, and therefore HOW DEEP EVERY TRENCH IS -- a layer's floor
## sits one spacing below the earth you look down through, so this number alone decides
## whether you can see your own mouse.
##
## At 1.5 you could not. The camera looks down at 48 degrees, so a wall of height D hides a
## strip of floor D / tan(pitch) wide behind it; at D = 1.5 that was wider than a corridor,
## and the mouse's head sat a full 1.1 below the rim.
##
## It used to be 1.5 because that was the steepest drop a two-cell ramp could cover without
## exceeding floor_max_angle. Nothing walks between planes any more, so that constraint is
## simply gone and the only remaining floor is MOUSE HEADROOM: a mouse standing on plane N+1
## must clear the underside of plane N's slab, so spacing must exceed 0.4 + FLOOR_THICKNESS.
## 0.65 leaves 0.13 of margin. The audit's HEADROOM check enforces it.
const PLANE_SPACING: float = 0.65
const FLOOR_THICKNESS: float = 0.12

## Radius of the hole inlaid on a shaft tile, as a fraction of the cell.
const MARKER_SIZE: float = 0.30
## How many segments the hole's rim is built from. Enough to read as round, few enough that
## the wobble between them is legible as a dug edge rather than as tessellation.
const MARKER_SEGMENTS: int = 18
## How far each segment's radius is allowed to stray. A mouse scrapes a hole out of soil; a
## perfect circle reads as machined and is the one shape earth never makes.
const MARKER_WOBBLE: float = 0.22
## How far the mark floats above the floor. Just enough to beat depth precision.
const MARKER_LIFT: float = 0.006
## The same, for a mark laid straight onto the lawn rather than onto a tile of its own. A
## little more, because it is fighting a large slab the renderer has no reason to sort behind.
const ENTRANCE_LIFT: float = 0.02


## One library PER PLANE, each with its own material instances. GridMap is a plain Node3D
## with no material_override, so giving each plane a separately dimmable look means handing
## each one its own copy of the meshes. Three copies of three small meshes is nothing.
static func build(floor_material: Material, down_material: Material) -> MeshLibrary:
	var library := MeshLibrary.new()
	_add(library, FLOOR, "floor", _slab(), floor_material, null)
	_add(library, SHAFT_DOWN, "shaft_down", _slab(), floor_material, down_material)

	# The surface entrance is a MARK ONLY, with no slab under it. Plane 0's floor height is
	# exactly the lawn's, so a tile with a slab would z-fight the grass across its whole face.
	# It also happens to be what GDD section 3 asks for -- entrances should be subtle to the
	# enemy, and a scuff in the turf is a great deal subtler than a doorway.
	var mark := ArrayMesh.new()
	_marker(mark, ENTRANCE_LIFT)
	mark.surface_set_material(0, down_material)
	library.create_item(ENTRANCE)
	library.set_item_name(ENTRANCE, "entrance")
	library.set_item_mesh(ENTRANCE, mark)
	return library


static func _add(
	library: MeshLibrary, id: int, name: String, mesh: ArrayMesh,
	floor_material: Material, marker: Material
) -> void:
	mesh.surface_set_material(0, floor_material)
	if marker != null:
		_marker(mesh, MARKER_LIFT)
		mesh.surface_set_material(1, marker)
	library.create_item(id)
	library.set_item_name(id, name)
	library.set_item_mesh(id, mesh)
	# Deliberately NO item shapes. Setting them produced valid shapes that never became
	# bodies in the physics world -- a raycast at a placed floor cell hit nothing, and the
	# player fell straight through. tunnel_network generates collision itself from the same
	# cell data. Leaving shapes here too would risk doubling up if that ever starts working.


## A flat slab whose top sits exactly at the plane's own Y, hanging FLOOR_THICKNESS below.
##
## The top being exactly at the plane coordinate is load-bearing: depth readouts, cell
## lookups, wall bases and the lid above all assume the walkable surface and the plane
## number are the same height.
static func _slab() -> ArrayMesh:
	var t := SurfaceTool.new()
	t.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half := CELL * 0.5
	var top := [
		Vector3(-half, 0.0, -half), Vector3(half, 0.0, -half),
		Vector3(half, 0.0, half), Vector3(-half, 0.0, half),
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


## The square inlaid on a shaft tile, added as a second surface so it can carry its own
## colour. Which colour is the whole message: dark means the way down, bright means the way
## up. The tile has to say which, because E does one thing or the other depending on the cell
## you are standing in and there is no other way to know before you press it.
static func _marker(mesh: ArrayMesh, lift: float) -> void:
	var t := SurfaceTool.new()
	t.begin(Mesh.PRIMITIVE_TRIANGLES)

	# A ring of radii, jittered and then smoothed against their neighbours. Jitter alone gives
	# a star, because each vertex is independent of the ones beside it; one pass of averaging
	# turns the spikes into lobes, which is what a scraped-out hole actually looks like.
	# Seeded, so the shape is identical every run and a screenshot is comparable to the last.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED
	var radii: Array[float] = []
	for i in range(MARKER_SEGMENTS):
		radii.append(1.0 + rng.randf_range(-MARKER_WOBBLE, MARKER_WOBBLE))
	var smoothed: Array[float] = []
	for i in range(MARKER_SEGMENTS):
		var before: float = radii[(i - 1 + MARKER_SEGMENTS) % MARKER_SEGMENTS]
		var after: float = radii[(i + 1) % MARKER_SEGMENTS]
		smoothed.append((before + radii[i] * 2.0 + after) * 0.25)

	var radius := CELL * MARKER_SIZE
	var centre := Vector3(0.0, lift, 0.0)
	for i in range(MARKER_SEGMENTS):
		var j := (i + 1) % MARKER_SEGMENTS
		for vertex: Vector3 in [
			centre, _rim(smoothed[i], i, radius, lift), _rim(smoothed[j], j, radius, lift)
		]:
			t.add_vertex(vertex)

	t.generate_normals()
	t.commit(mesh)


static func _rim(scale: float, index: int, radius: float, lift: float) -> Vector3:
	var angle := TAU * float(index) / float(MARKER_SEGMENTS)
	return Vector3(cos(angle) * radius * scale, lift, sin(angle) * radius * scale)


static func _quad(t: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for vertex: Vector3 in [a, b, c, a, c, d]:
		t.add_vertex(vertex)
