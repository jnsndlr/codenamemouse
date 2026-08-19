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

## How far the TOP of an earth face leans back from the outline it stands on, in metres.
##
## THE 90-DEGREE LIP IS THE THING THAT READS AS A BOX. A wall that meets the ground dead square
## announces that the trench was stamped out rather than dug -- the reference art has none of it,
## and neither does anything anybody has ever cut into soil. Leaning the last handspan of the face
## back over a quarter turn puts a rounded shoulder where that corner was, and the light does the
## rest: the bevel catches the sky at a different angle from both the flat ground and the wall
## below it, so a corridor reads as a cut in the earth from directly above, where before it read as
## a dark slot.
##
## THE GROUND ABOVE HAS TO OPEN BY EXACTLY THIS MUCH OR THE BEVEL IS DRAWN AND NEVER SEEN. The lid
## discards against the dug field at the OUTLINE, so the shoulder -- which lies outside that line,
## in the earth -- sits under solid ground with the sharp lid edge still standing over it. That is
## why `dug_grow` exists in dug_field.gdshaderinc and why it is fed from here (see
## [method wall_bevel]): one number, spent once on the geometry and once on the hole above it.
##
## THE TWO AGREE BECAUSE THE FIELD IS A TRUE DISTANCE. Stepping every point of the outline out
## along its own normal by `b` lands on the set of points `b` from the tunnel, which is exactly
## what the shader's shifted threshold cuts -- so the rim of the hole and the top of the bevel are
## the same curve, at any angle and around any bend.
##
## THEY PART COMPANY IN EARTH THINNER THAN TWO BEVELS, which at this size is any two corridors
## running closer than half a metre apart -- not a rare case, so it is worth saying exactly what
## happens. The ground above has closed over entirely by then: the grown cut eats a wall that thin
## from both sides at once. The two shoulders meanwhile cross rather than meet, and what you get is
## a low ridge of earth between the two trenches with a hairline where the crossing is. That is a
## seam on a surface, which the eye forgives; the alternative -- backing the bevel off where the
## earth is thin, so the geometry stops short of a hole that has already opened -- is a slot
## straight through to nothing, which it does not.
const WALL_BEVEL: float = 0.25

## Ceiling on the bevel as a fraction of the wall's own height, so a shortened wall gets a
## shoulder in proportion rather than a wall that is nothing BUT shoulder. It also collapses the
## whole profile to nothing on plane 0, whose "wall" is zero high and must stay invisible.
##
## IT HAS TO CLEAR THE BEVEL ABOVE AT THE DEFAULT WALL HEIGHT or the constant next door is a lie:
## a ceiling below it does not read as a cap, it reads as the number having no effect. At 0.65m of
## wall this leaves 40cm of straight face under a 25cm shoulder.
const BEVEL_HEIGHT_FRACTION: float = 0.4

## How deep the gouging in the flat of a wall goes, in metres.
##
## OUTWARD ONLY, NEVER INTO THE CORRIDOR. The noise is added along the outward normal as a 0..1
## depth, so the drawn face is always at or BEHIND the outline the collision barrier stands on. A
## two-sided wobble would look the same and would put earth a couple of centimetres inside the
## space a mouse is entitled to walk through, which is the sort of mismatch that gets reported as
## the controls sticking.
const WALL_ROUGHNESS: float = 0.07

## Metres per feature of that gouging, and the fraction of its true size the HEIGHT is fed in at --
## so a gouge comes out a bit over twice as tall as it is wide. Stretched upward because that is
## what a tool working a face leaves: unstretched noise reads as lumpy plaster, and the stretch
## also covers how few rows a face this short can afford to be built out of.
const ROUGH_SCALE: float = 0.38
const ROUGH_STRETCH: float = 0.45
## Fixed, so two machines drawing the same tunnel gouge it in the same places. Nothing about the
## walls is on the wire -- both ends contour the same strokes -- and this is the one part of their
## shape that is not implied by those strokes.
const ROUGH_SEED: int = 8_512

## The cross-section of one earth face, from the floor up. Per ring: how far up the straight part
## of the wall it sits, how far round the quarter-turn of the bevel, and how much of
## [constant WALL_ROUGHNESS] it carries.
##
## THE ENDS CARRY NO ROUGHNESS AT ALL, and both zeroes are load-bearing. The bottom ring is welded
## to the floor, which is contoured on the outline itself -- move it and the wall lifts off its own
## floor and you can see under it. The top ring is welded to the rim of the hole in the ground
## above, which is a shader cutting a smooth curve and cannot be told about a gouge; a wall that
## fell 2cm short of it would leave a slot straight through to nothing, all the way along the
## corridor.
##
## FIVE ROWS RATHER THAN THE ONE QUAD THIS REPLACES, weighted toward the bevel because that is
## where the silhouette is. It costs about as many wall triangles as a chunk has floor triangles;
## the flat of the wall is the part you see least of and gets two. The whole change -- rows,
## gouging and the normals it is all pointed along -- puts a stroke up from 5.2ms to 6.5ms on
## `carve_probe.gd`'s scale, about a fifth, spread over the nine rebuilds a held dig makes.
const WALL_RINGS: Array = [
	[0.0, 0.0, 0.0],
	[0.5, 0.0, 1.0],
	[1.0, 0.0, 0.9],
	[1.0, 0.45, 0.6],
	[1.0, 0.8, 0.3],
	[1.0, 1.0, 0.0],
]

## Triangles, ready for a SurfaceTool. Filled by [method build], cleared on each call.
var floors := PackedVector3Array()
var walls := PackedVector3Array()
var collision := PackedVector3Array()

## The samples [method build] was given, with one ring of margin round them, and its row stride.
## The margin is what makes the outward normal a central difference at EVERY sample including the
## outermost -- see [method _outward_at].
var _field := PackedFloat32Array()
var _field_stride: int = 0

## [constant WALL_RINGS] worked out against the wall height in hand: height, outward offset and
## roughness depth, all in metres. Rebuilt once per [method build] rather than per face.
var _rings := PackedVector3Array()

## The gouging. Static because a contour is a per-chunk object and this is a per-project fact.
static var _grain: FastNoiseLite = null


## Signed distance in metres, as the 0..1 the field stores. Negative distance -- inside the
## tunnel -- comes back above [constant SURFACE].
static func encode(distance: float) -> float:
	return clampf(SURFACE - distance / (SDF_RANGE * 2.0), 0.0, 1.0)


static func decode(value: float) -> float:
	return (SURFACE - value) * SDF_RANGE * 2.0


## How far the top of a wall of this height leans back, in metres. The one number the geometry and
## the hole cut in the ground above it both have to be built from.
static func wall_bevel(wall_top: float) -> float:
	return minf(WALL_BEVEL, maxf(0.0, wall_top) * BEVEL_HEIGHT_FRACTION)


## Vertices one earth face is made of. Anything walking [member walls] a face at a time -- the rock
## split, the audits -- has to step by this rather than by the 6 of the single quad it used to be.
static func face_verts() -> int:
	return (WALL_RINGS.size() - 1) * 6


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
##
## `margined` is the same samples with one extra ring all round, `(n + 3)` square, starting a texel
## before `origin`. Only the wall's shape reads it, and only for the direction "away from the
## tunnel" (see [method _outward_at]) -- but that direction has to be the SAME on both sides of a
## chunk border or every seam in the world opens by the width of the bevel, and a central
## difference at the outermost sample cannot be taken from samples that stop there. Left out, the
## edge samples fall back to a one-sided difference, which is fine for a lone chunk and is what the
## probes hand over.
func build(
	samples: PackedFloat32Array,
	n: int,
	origin: Vector2,
	wall_top: float,
	barrier_top: float,
	margined: PackedFloat32Array = PackedFloat32Array()
) -> void:
	floors.clear()
	walls.clear()
	collision.clear()

	var stride := n + 1
	if samples.size() < stride * stride:
		return

	_field_stride = n + 3
	_field = (
		margined if margined.size() == _field_stride * _field_stride
		else _widen(samples, n)
	)
	_shape_rings(wall_top)
	_rough_grain()

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
				[
					_outward_at(i, j),
					_outward_at(i + 1, j),
					_outward_at(i + 1, j + 1),
					_outward_at(i, j + 1),
				],
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
	outward: Array,
	wall_top: float,
	barrier_top: float
) -> void:
	if inside == 5 or inside == 10:
		var centre: float = (values[0] + values[1] + values[2] + values[3]) * 0.25
		if centre <= SURFACE:
			# Two corners, each its own little triangle, and the earth stays joined between them.
			for corner in range(4):
				if (inside >> corner) & 1:
					_emit_polygon(
						_corner_lobe(corner, values, points, outward), wall_top, barrier_top
					)
			return

	var polygon: Array[Vector2] = []
	## Parallel to `polygon`: true where the vertex is a crossing rather than a corner. An edge
	## between two crossings is the isoline and therefore a wall; every other edge runs along the
	## cell border, where the neighbouring cell either continues the floor or raises its own wall.
	var crossed: Array[bool] = []
	## Parallel to `polygon` too: which way the earth lies from that vertex. Only the wall reads it.
	var normals: Array[Vector2] = []

	for corner in range(4):
		var next := (corner + 1) % 4
		if (inside >> corner) & 1:
			polygon.append(points[corner])
			crossed.append(false)
			normals.append(outward[corner])
		var here_in := ((inside >> corner) & 1) != 0
		var there_in := ((inside >> next) & 1) != 0
		if here_in != there_in:
			var t := _crossing_t(values[corner], values[next])
			polygon.append((points[corner] as Vector2).lerp(points[next], t))
			crossed.append(true)
			normals.append(_blend(outward[corner], outward[next], t))

	_emit(polygon, crossed, normals, wall_top, barrier_top)


## One inside corner cut off by the isoline: the corner itself and the two crossings either side,
## as `[points, outward normals]`.
func _corner_lobe(corner: int, values: Array, points: Array, outward: Array) -> Array:
	var before := (corner + 3) % 4
	var next := (corner + 1) % 4
	var back := _crossing_t(values[before], values[corner])
	var on := _crossing_t(values[corner], values[next])
	return [
		[
			(points[before] as Vector2).lerp(points[corner], back),
			points[corner],
			(points[corner] as Vector2).lerp(points[next], on),
		],
		[
			_blend(outward[before], outward[corner], back),
			outward[corner],
			_blend(outward[corner], outward[next], on),
		],
	]


## A three-vertex lobe is all crossings but for its middle vertex.
func _emit_polygon(lobe: Array, wall_top: float, barrier_top: float) -> void:
	var points: Array = lobe[0]
	var outward: Array = lobe[1]
	var polygon: Array[Vector2] = [points[0], points[1], points[2]]
	var normals: Array[Vector2] = [outward[0], outward[1], outward[2]]
	_emit(polygon, [true, false, true], normals, wall_top, barrier_top)


## How far along an edge the surface sits. Linear in the stored value, which is linear in distance
## -- so this is the real crossing point rather than the midpoint, and it is the whole reason a
## wall at an arbitrary angle comes out straight instead of stepped.
##
## A FRACTION RATHER THAN A POINT, because the wall needs the same fraction to mix the two
## corners' outward normals with. Taking the point from one function and the direction from
## another is how the two end up disagreeing at a vertex two cells share, and a vertex two cells
## disagree about is a crack you can see the void through.
static func _crossing_t(va: float, vb: float) -> float:
	var span := vb - va
	if absf(span) < 0.000001:
		return 0.5
	return clampf((SURFACE - va) / span, 0.0, 1.0)


## Two outward normals mixed and renormalised. Falls back to whichever is real if they cancel --
## which they do at the tip of a scrap of earth, where "away from the tunnel" has no answer.
static func _blend(a: Vector2, b: Vector2, t: float) -> Vector2:
	var mixed := a.lerp(b, t)
	if mixed.length_squared() < 0.000001:
		return a if a.length_squared() > 0.0 else b
	return mixed.normalized()


## Which way the earth lies from sample `(i, j)`: the field's gradient, flipped, as a unit vector.
##
## THE FIELD RISES INTO THE TUNNEL (see [method encode]), so its gradient points down the corridor
## and the earth is the other way. Zero where the field is flat, which the wall reads as "do not
## move this vertex" -- the honest answer in the middle of a plateau the thinning rewrote.
##
## A CENTRAL DIFFERENCE, from the margined copy, and both halves of that matter. Central because a
## one-sided difference at a sample is a different direction from the one the sample on the far
## side of the same edge computes, and the two are averaged into the same vertex. Margined because
## the outermost samples of a chunk are the ones a neighbouring chunk also owns, and a vertex on
## that seam must come out identical in both -- which it does only if both take the difference
## across the same two samples.
func _outward_at(i: int, j: int) -> Vector2:
	var at := (j + 1) * _field_stride + (i + 1)
	var gradient := Vector2(
		_field[at + 1] - _field[at - 1],
		_field[at + _field_stride] - _field[at - _field_stride]
	)
	if gradient.length_squared() < 0.000000001:
		return Vector2.ZERO
	return -gradient.normalized()


## Samples with a ring of margin round them, made by repeating the edge. Only for callers that
## have no wider window to give -- see [method build].
static func _widen(samples: PackedFloat32Array, n: int) -> PackedFloat32Array:
	var stride := n + 1
	var wide := n + 3
	var out := PackedFloat32Array()
	out.resize(wide * wide)
	for j in range(wide):
		var row := clampi(j - 1, 0, n) * stride
		var target := j * wide
		for i in range(wide):
			out[target + i] = samples[row + clampi(i - 1, 0, n)]
	return out


## [constant WALL_RINGS] in metres, for a wall of this height.
func _shape_rings(wall_top: float) -> void:
	var bevel := wall_bevel(wall_top)
	var straight := maxf(0.0, wall_top - bevel)
	var rough := WALL_ROUGHNESS if wall_top > 0.0 else 0.0
	_rings.resize(WALL_RINGS.size())
	for k in range(WALL_RINGS.size()):
		var ring: Array = WALL_RINGS[k]
		# The bevel is a quarter turn: sine takes the ring up, cosine takes it back.
		var turn := (ring[1] as float) * PI * 0.5
		_rings[k] = Vector3(
			(ring[0] as float) * straight + bevel * sin(turn),
			bevel * (1.0 - cos(turn)),
			(ring[2] as float) * rough
		)


## The noise the flat of a wall is gouged with.
static func _rough_grain() -> FastNoiseLite:
	if _grain == null:
		_grain = FastNoiseLite.new()
		_grain.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_grain.seed = ROUGH_SEED
		_grain.frequency = 1.0 / ROUGH_SCALE
		# Two octaves: a broad swell for the shape of the cut and a finer one for the tool marks.
		_grain.fractal_octaves = 2
		_grain.fractal_gain = 0.45
	return _grain


## Floor triangles for the polygon, and a wall on every edge that is part of the isoline.
##
## WOUND ANTICLOCKWISE FIRST, because both outputs depend on it. With the polygon anticlockwise in
## (x, z) the interior is to the left of every edge, which is what lets the wall quad be emitted
## facing INTO the corridor without any per-edge test -- and a wall facing the wrong way is
## invisible from the only place anybody stands to look at it.
func _emit(
	polygon: Array[Vector2],
	crossed: Array[bool],
	normals: Array[Vector2],
	wall_top: float,
	barrier_top: float
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
		normals.reverse()
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
		_add_wall(polygon[k], polygon[next], normals[k], normals[next], wall_top, barrier_top)


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
##
## THE DRAWN FACE IS NO LONGER THE COLLIDED ONE, and that is the whole licence for what follows.
## The barrier is still the flat vertical quad standing on the outline, so the shape of the world
## a mouse walks into, a route is planned through and an audit measures is untouched by any of
## this. What the eye gets is a strip of [constant WALL_RINGS] instead: gouged outward through the
## flat of the wall, leaning back over a bevel at the top. Everything here moves earth AWAY from
## the corridor or leaves it where it was, so the drawn wall never crosses the barrier and there
## is nothing to walk into that you cannot see.
##
## THE VERTICES ARE A FUNCTION OF THE OUTLINE AND NOTHING ELSE -- the point, the height, and the
## normal mixed for that point -- so the two cells that share a vertex compute the same offset for
## it, whichever way their own isoline edges run. That is what keeps a wall built out of a few
## thousand independent strips watertight.
func _add_wall(
	a: Vector2, b: Vector2, na: Vector2, nb: Vector2, wall_top: float, barrier_top: float
) -> void:
	var rings := _rings.size()
	var side_a := PackedVector3Array()
	var side_b := PackedVector3Array()
	side_a.resize(rings)
	side_b.resize(rings)
	for k in range(rings):
		var ring := _rings[k]
		side_a[k] = _face_point(a, na, ring)
		side_b[k] = _face_point(b, nb, ring)

	for k in range(rings - 1):
		walls.append(side_a[k])
		walls.append(side_b[k])
		walls.append(side_b[k + 1])
		walls.append(side_a[k])
		walls.append(side_b[k + 1])
		walls.append(side_a[k + 1])

	var base_a := Vector3(a.x, 0.0, a.y)
	var base_b := Vector3(b.x, 0.0, b.y)
	var bar_a := Vector3(a.x, barrier_top, a.y)
	var bar_b := Vector3(b.x, barrier_top, b.y)
	collision.append(base_a)
	collision.append(base_b)
	collision.append(bar_b)
	collision.append(base_a)
	collision.append(bar_b)
	collision.append(bar_a)


## One vertex of a wall: a point on the outline, pushed back into the earth by the ring's own
## offset and by however deep the gouging is at that spot.
func _face_point(at: Vector2, outward: Vector2, ring: Vector3) -> Vector3:
	var back := ring.y
	if ring.z > 0.0:
		# Sampled at the point on the OUTLINE rather than at the moved one, so the depth of a gouge
		# does not depend on how deep the gouge came out. Height goes in as the noise's second
		# axis, stretched, which is what makes a face vary up its own height instead of being an
		# extrusion of one wobbly line.
		var grain := _grain.get_noise_3d(at.x, ring.x * ROUGH_STRETCH, at.y)
		back += ring.z * clampf(grain * 0.5 + 0.5, 0.0, 1.0)
	var point := at + outward * back
	return Vector3(point.x, ring.x, point.y)
