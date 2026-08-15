class_name TunnelChunks
extends RefCounted
## The dimensions every part of the underground agrees on, and the marks laid on its floor.
##
## `[REVISED]` THE TILES ARE GONE, and with them the MeshLibrary this file used to build. Tunnels
## are no longer a set of square cells: a segment is a capsule at a free angle, and the floor and
## walls are contoured out of the union of them (see [TunnelContour]). There is no per-cell slab
## left to instance, so what remains here is the numbers -- [constant CELL],
## [constant PLANE_SPACING] -- and the two flat marks that still sit at a POINT rather than
## filling a square.
##
## [constant CELL] outliving the tiles is not an oversight. The coarse cell survives as the unit
## the game's *knowledge* is kept in -- who has seen what, what the minimap draws, what sonar
## pings -- and as the index that finds which segments are near a spot. It stopped being the unit
## the world is SHAPED in, which is the whole of the change.
##
## A shaft is NOT a hole. The floor stays solid and simply carries a mark, because falling down a
## shaft you meant to walk past is not a mechanic anyone asked for and a real hole in the
## collision mesh is how you end up outside the world.

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


## The mark inlaid on the floor where a shaft goes down, as a mesh of its own.
##
## A MESH RATHER THAN A MeshLibrary ITEM, since the floor stopped being tiles. The tunnel floor is
## now contoured out of the dug field (see [TunnelContour]), so there is no per-cell slab left to
## hang a second surface off -- and a shaft is in any case a thing at a POINT rather than a
## property of a square. One of these is instanced per shaft and parked at its centre.
static func shaft_mark(material: Material) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_marker(mesh, MARKER_LIFT)
	mesh.surface_set_material(0, material)
	return mesh


## The same, for the mouth seen from the lawn.
##
## STILL A MARK ONLY, with no slab under it. Plane 0's floor height is exactly the lawn's, so
## anything with thickness would z-fight the grass across its whole face. It also happens to be
## what GDD section 3 asks for -- entrances should be subtle to the enemy, and a scuff in the turf
## is a great deal subtler than a doorway.
static func entrance_mark(material: Material) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_marker(mesh, ENTRANCE_LIFT)
	mesh.surface_set_material(0, material)
	return mesh


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
