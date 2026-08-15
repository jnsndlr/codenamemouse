class_name TunnelContour
extends RefCounted
## Marching squares over a chunk of the dug field: floor, walls and collision, from one array
## of samples.
##
## WHY THE GEOMETRY IS CONTOURED RATHER THAN EMITTED PER SEGMENT. A tunnel is now a chain of
## overlapping capsules at free angles, and two overlapping capsules that each emit their own
## side walls leave those walls standing INSIDE the corridor -- a fin across the tunnel at every
## joint, which is the one artifact that would make the whole idea look broken. Contouring the
## union has no interior to leave behind: the isoline is by definition the boundary between dug
## and undug, so a face exists exactly where earth meets air and nowhere else.
##
## THE FIELD IS A SIGNED DISTANCE, not a set of flags, and that is what makes the walls smooth.
## A binary mask marched at this resolution gives edges that are axis-aligned or exactly 45
## degrees, so a corridor running at 20 degrees comes out as a staircase with smaller steps --
## which is the thing we are trying to get rid of, merely at 12.5cm instead of a metre. Storing
## distance and interpolating the crossing point along each cell edge puts the wall where the
## wall actually is, at any angle.
##
## UNION IS `min`, which is the other reason for distance. Overlapping capsules combine by taking
## the nearest surface, so a chain of segments has one continuous outline for free -- no polygon
## boolean, no seam handling, no special case where three segments meet.
##
## SAMPLES ARE PASSED IN rather than sampled through a callback. A chunk is 33x33 samples and a
## dig dirties up to four chunks; a `Callable` per sample is four thousand call frames per dig in
## a language that charges for every one. The caller builds the array in one tight loop over the
## segments it already has in hand, and this class stays pure enough to test on a hand-written
## array.

## Texels per metre in the dug field. 12.5cm -- fine enough that the interpolated contour is
## smooth at any angle, coarse enough that a plane's field is a megabyte rather than sixteen.
const TEXELS_PER_METRE: int = 8
const TEXEL: float = 1.0 / float(TEXELS_PER_METRE)

## Side of one rebuild chunk, in texels. 4m, so a 1m segment with a 0.5m radius dirties one chunk
## and at worst four. Small enough that a dig rebuilds a few thousand marching-squares cells;
## large enough that a big network is a few dozen mesh instances rather than a few thousand.
const CHUNK_TEXELS: int = 32
const CHUNK_METRES: float = float(CHUNK_TEXELS) * TEXEL

## Metres of distance the byte spans either side of the surface. The field is stored in an R8
## image, so this is the whole dynamic range: 1m each way at 1/256 gives 8mm of precision on the
## crossing point, well under what the eye can find on a wall.
const SDF_RANGE: float = 1.0

## The encoded value at the surface. Inside the tunnel reads higher, earth reads lower -- the same
## sense the old binary mask had, so `earth_cutaway.gdshader` keeps discarding on `> 0.5` and the
## shader change is about filtering rather than about meaning.
const SURFACE: float = 0.5

## Triangles, ready for a SurfaceTool. Filled by [method build], cleared on each call.
var floors := PackedVector3Array()
var walls := PackedVector3Array()
var collision := PackedVector3Array()


## Signed distance in metres, as the 0..1 the field stores. Negative distance -- inside the
## tunnel -- comes back above [constant SURFACE].
static func encode(distance: float) -> float:
	return clampf(SURFACE - distance / (SDF_RANGE * 2.0), 0.0, 1.0)


static func decode(value: float) -> float:
	return (SURFACE - value) * SDF_RANGE * 2.0


## Signed distance from `point` to a segment of tunnel: a capsule of `half_width` about the line
## from `a` to `b`.
##
## A CAPSULE RATHER THAN A RECTANGLE, and it is worth saying why given that a segment is specified
## as a fixed width and a fixed length. Round ends are what make a bend read as a bend: two
## rectangles meeting at 30 degrees leave a notch on the outside of the turn that has to be filled
## by something, and every way of filling it is a special case. Two capsules meeting at any angle
## are already one smooth shape. The length and width the player is spending are unchanged -- this
## is only what the ends look like.
static func segment_distance(point: Vector2, a: Vector2, b: Vector2, half_width: float) -> float:
	var along := b - a
	var length_squared := along.length_squared()
	# A zero-length segment is a disc, and dividing by its length is how you get a NaN into a mesh
	# and spend an afternoon looking at a hole in the floor.
	if length_squared <= 0.000001:
		return point.distance_to(a) - half_width
	var t := clampf((point - a).dot(along) / length_squared, 0.0, 1.0)
	return point.distance_to(a + along * t) - half_width


## Contour one chunk.
##
## `samples` is `(n + 1) * (n + 1)` encoded values in row-major order, sample `(i, j)` taken at
## `origin + Vector2(i, j) * TEXEL`. One more sample than there are marching-squares cells,
## because a cell is the square BETWEEN four samples -- and because sharing the outer row with the
## neighbouring chunk is what stops a seam of missing wall appearing on every chunk border.
##
## `wall_top` is how far the drawn earth face rises; `barrier_top` how far the invisible one does.
## The two differ (see TunnelNetwork.barrier_height) and always have.
func build(
	samples: PackedFloat32Array,
	n: int,
	origin: Vector2,
	wall_top: float,
	barrier_top: float
) -> void:
	floors.clear()
	walls.clear()
	collision.clear()

	var stride := n + 1
	if samples.size() < stride * stride:
		return

	for j in range(n):
		var row := j * stride
		for i in range(n):
			# The four corners of this cell, in the order the polygon walk expects: bottom-left,
			# bottom-right, top-right, top-left, going anticlockwise in (x, z).
			var v00 := samples[row + i]
			var v10 := samples[row + i + 1]
			var v11 := samples[row + stride + i + 1]
			var v01 := samples[row + stride + i]

			var inside := 0
			if v00 > SURFACE:
				inside |= 1
			if v10 > SURFACE:
				inside |= 2
			if v11 > SURFACE:
				inside |= 4
			if v01 > SURFACE:
				inside |= 8
			if inside == 0:
				continue

			var at := origin + Vector2(float(i), float(j)) * TEXEL
			var p00 := at
			var p10 := at + Vector2(TEXEL, 0.0)
			var p11 := at + Vector2(TEXEL, TEXEL)
			var p01 := at + Vector2(0.0, TEXEL)

			# Wholly inside: no isoline crosses it, so it is floor and nothing else. Taken early
			# because it is much the most common case in any tunnel wider than the texel grid, and
			# it skips the whole polygon walk.
			if inside == 15:
				_add_floor_triangle(p00, p11, p10)
				_add_floor_triangle(p00, p01, p11)
				continue

			_walk_cell(
				inside,
				[v00, v10, v11, v01],
				[p00, p10, p11, p01],
				wall_top,
				barrier_top
			)


## The inside region of one partly-dug cell, as floor triangles plus the wall along its isoline.
##
## Corners are visited anticlockwise. A corner that is inside joins the polygon; between each pair
## of consecutive corners whose sign differs, the crossing point on that edge joins it too. That
## single rule produces the correct polygon for fourteen of the sixteen cases without enumerating
## any of them, which is worth a great deal in a routine where a wrong case is a hole in a wall
## that only appears at one angle.
##
## THE TWO SADDLES ARE THE EXCEPTION (opposite corners inside, the other two out). The rule above
## produces one hexagon joining all four crossings, which connects the two diagonal lobes through
## a pinch point -- geometrically it says the tunnel is continuous across a corner it is not.
## Resolved by the centre value, the standard answer: if the middle of the cell is inside, the
## lobes really are joined and the hexagon is right; if it is not, they are two separate triangles.
func _walk_cell(
	inside: int,
	values: Array,
	points: Array,
	wall_top: float,
	barrier_top: float
) -> void:
	if inside == 5 or inside == 10:
		var centre: float = (values[0] + values[1] + values[2] + values[3]) * 0.25
		if centre <= SURFACE:
			# Two corners, each its own little triangle, and the earth stays joined between them.
			for corner in range(4):
				if (inside >> corner) & 1:
					_emit_polygon(_corner_lobe(corner, values, points), wall_top, barrier_top)
			return

	var polygon: Array[Vector2] = []
	## Parallel to `polygon`: true where the vertex is a crossing rather than a corner. An edge
	## between two crossings is the isoline and therefore a wall; every other edge runs along the
	## cell border, where the neighbouring cell either continues the floor or raises its own wall.
	var crossed: Array[bool] = []

	for corner in range(4):
		var next := (corner + 1) % 4
		if (inside >> corner) & 1:
			polygon.append(points[corner])
			crossed.append(false)
		var here_in := ((inside >> corner) & 1) != 0
		var there_in := ((inside >> next) & 1) != 0
		if here_in != there_in:
			polygon.append(
				_crossing(points[corner], points[next], values[corner], values[next])
			)
			crossed.append(true)

	_emit(polygon, crossed, wall_top, barrier_top)


## One inside corner cut off by the isoline: the corner itself and the two crossings either side.
func _corner_lobe(corner: int, values: Array, points: Array) -> Array:
	var before := (corner + 3) % 4
	var next := (corner + 1) % 4
	return [
		_crossing(points[before], points[corner], values[before], values[corner]),
		points[corner],
		_crossing(points[corner], points[next], values[corner], values[next]),
	]


## A three-vertex lobe is all crossings but for its middle vertex.
func _emit_polygon(lobe: Array, wall_top: float, barrier_top: float) -> void:
	var polygon: Array[Vector2] = [lobe[0], lobe[1], lobe[2]]
	_emit(polygon, [true, false, true], wall_top, barrier_top)


## Where along an edge the surface sits. Linear in the stored value, which is linear in distance --
## so this is the real crossing point rather than the midpoint, and it is the whole reason a wall
## at an arbitrary angle comes out straight instead of stepped.
func _crossing(a: Vector2, b: Vector2, va: float, vb: float) -> Vector2:
	var span := vb - va
	if absf(span) < 0.000001:
		return (a + b) * 0.5
	return a.lerp(b, clampf((SURFACE - va) / span, 0.0, 1.0))


## Floor triangles for the polygon, and a wall on every edge that is part of the isoline.
##
## WOUND ANTICLOCKWISE FIRST, because both outputs depend on it. With the polygon anticlockwise in
## (x, z) the interior is to the left of every edge, which is what lets the wall quad be emitted
## facing INTO the corridor without any per-edge test -- and a wall facing the wrong way is
## invisible from the only place anybody stands to look at it.
func _emit(
	polygon: Array[Vector2], crossed: Array[bool], wall_top: float, barrier_top: float
) -> void:
	if polygon.size() < 3:
		return

	var area := 0.0
	for k in range(polygon.size()):
		var p: Vector2 = polygon[k]
		var q: Vector2 = polygon[(k + 1) % polygon.size()]
		area += p.x * q.y - q.x * p.y
	if area < 0.0:
		polygon.reverse()
		crossed.reverse()
		# Reversing puts each vertex's flag one place out of step with the edge it starts: the
		# edge that ran k -> k+1 now runs the other way round the array. Rotating the flags by one
		# puts them back on their own edges.
		if crossed.size() > 1:
			crossed.push_front(crossed.pop_back())

	for k in range(1, polygon.size() - 1):
		_add_floor_triangle(polygon[0], polygon[k], polygon[k + 1])

	for k in range(polygon.size()):
		var next := (k + 1) % polygon.size()
		if not (crossed[k] and crossed[next]):
			continue
		_add_wall(polygon[k], polygon[next], wall_top, barrier_top)


## A floor triangle, wound so it faces up. The polygon walk is anticlockwise in (x, z), which in
## Godot's left-handed world puts the front face DOWNWARD -- so the vertex order is flipped here,
## once, rather than at each of the three call sites.
func _add_floor_triangle(a: Vector2, b: Vector2, c: Vector2) -> void:
	var pa := Vector3(a.x, 0.0, a.y)
	var pb := Vector3(b.x, 0.0, b.y)
	var pc := Vector3(c.x, 0.0, c.y)
	floors.append(pa)
	floors.append(pc)
	floors.append(pb)
	collision.append(pa)
	collision.append(pc)
	collision.append(pb)


## The earth face standing on one isoline edge. Drawn to `wall_top`, collided to `barrier_top` --
## two heights for two jobs, exactly as the cell version did.
func _add_wall(a: Vector2, b: Vector2, wall_top: float, barrier_top: float) -> void:
	var base_a := Vector3(a.x, 0.0, a.y)
	var base_b := Vector3(b.x, 0.0, b.y)
	var top_a := Vector3(a.x, wall_top, a.y)
	var top_b := Vector3(b.x, wall_top, b.y)

	walls.append(base_a)
	walls.append(base_b)
	walls.append(top_b)
	walls.append(base_a)
	walls.append(top_b)
	walls.append(top_a)

	var bar_a := Vector3(a.x, barrier_top, a.y)
	var bar_b := Vector3(b.x, barrier_top, b.y)
	collision.append(base_a)
	collision.append(base_b)
	collision.append(bar_b)
	collision.append(base_a)
	collision.append(bar_b)
	collision.append(bar_a)
