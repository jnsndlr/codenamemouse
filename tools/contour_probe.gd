extends SceneTree
## Does [TunnelContour] produce the shape it claims to?
##
##   godot --headless --path . --script tools/contour_probe.gd
##
## Headless and self-contained: it builds sample arrays by hand rather than standing up an arena,
## so a failure here is unambiguously the contouring rather than anything the network did.
##
## WHY THIS EXISTS SEPARATELY FROM tunnel_audit.gd. Every visual bug in the organic-tunnel work
## lands in one routine -- a wall facing the wrong way, a hole at a chunk seam, a fin left standing
## across a corridor -- and all three look the same from the outside: "the tunnel renders wrong".
## Checking the geometry against arithmetic anybody can do on paper (a capsule's area, a capsule's
## perimeter, whether the outline closes) says which of the three it is before the renderer is
## involved at all.

## Half the tunnel width, and the value the network will pass. A segment is 1m wide.
const HALF_WIDTH: float = 0.5
const WALL_TOP: float = 0.65
const BARRIER_TOP: float = 1.30

var _failures: int = 0


func _initialize() -> void:
	_check_single_segment()
	_check_wall_faces_inward()
	_check_no_interior_faces()
	_check_chunk_seam()
	_check_angled_wall_is_straight()
	_check_wall_is_welded()
	_check_rim_stands_back()

	if _failures == 0:
		print("CONTOUR OK -- area, winding, closure, seams, straightness, weld and rim all hold.")
	else:
		print("CONTOUR: %d failure(s)." % _failures)
	quit(1 if _failures > 0 else 0)


func _fail(label: String, detail: String) -> void:
	_failures += 1
	printerr("  %s: %s" % [label, detail])


## Sample the field of one capsule over a grid of `n + 1` points starting at `origin`.
func _samples(n: int, origin: Vector2, a: Vector2, b: Vector2) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize((n + 1) * (n + 1))
	for j in range(n + 1):
		for i in range(n + 1):
			var at := origin + Vector2(float(i), float(j)) * TunnelContour.TEXEL
			var d := TunnelContour.segment_distance(at, a, b, HALF_WIDTH)
			out[j * (n + 1) + i] = TunnelContour.encode(d)
	return out


func _area_of(triangles: PackedVector3Array) -> float:
	var total := 0.0
	for t in range(0, triangles.size(), 3):
		var a := triangles[t]
		var b := triangles[t + 1]
		var c := triangles[t + 2]
		total += absf(
			(b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
		) * 0.5
	return total


## A 1m segment, 1m wide: a 1x1 rectangle with a half-disc on each end.
func _check_single_segment() -> void:
	var n := 48
	var origin := Vector2(-1.5, -1.5)
	var a := Vector2(0.0, 0.0)
	var b := Vector2(1.0, 0.0)
	var contour := TunnelContour.new()
	contour.build(_samples(n, origin, a, b), n, origin, WALL_TOP, BARRIER_TOP)

	var expected_area := 1.0 * (HALF_WIDTH * 2.0) + PI * HALF_WIDTH * HALF_WIDTH
	var area := _area_of(contour.floors)
	if absf(area - expected_area) > 0.02:
		_fail("AREA", "capsule floor is %.4f m2, expected %.4f" % [area, expected_area])

	# The wall is a closed loop around that outline, so its total length is the perimeter.
	var expected_perimeter := 2.0 * 1.0 + TAU * HALF_WIDTH
	var perimeter := 0.0
	# One face is a strip of rows now (TunnelContour.WALL_RINGS); the first two vertices of the
	# strip are its base edge, the only row that stands on the outline itself.
	for t in range(0, contour.walls.size(), TunnelContour.face_verts()):
		perimeter += contour.walls[t].distance_to(contour.walls[t + 1])
	if absf(perimeter - expected_perimeter) > 0.05:
		_fail("PERIMETER", "wall runs %.4f m, expected %.4f" % [perimeter, expected_perimeter])


## Every wall quad must present its front face to the inside of the tunnel, which is the only
## place anybody ever stands. A wall wound the other way is invisible and reads as a hole.
func _check_wall_faces_inward() -> void:
	var n := 48
	var origin := Vector2(-1.5, -1.5)
	var a := Vector2(0.0, 0.0)
	var b := Vector2(1.0, 0.0)
	var contour := TunnelContour.new()
	contour.build(_samples(n, origin, a, b), n, origin, WALL_TOP, BARRIER_TOP)

	var wrong := 0
	for t in range(0, contour.walls.size(), TunnelContour.face_verts()):
		var p := contour.walls[t]
		var q := contour.walls[t + 1]
		var normal := (q - p).cross(Vector3.UP).normalized()
		# A step from the middle of the edge along the normal should move toward the centreline.
		var mid := (p + q) * 0.5
		var here := TunnelContour.segment_distance(Vector2(mid.x, mid.z), a, b, HALF_WIDTH)
		var ahead := TunnelContour.segment_distance(
			Vector2(mid.x + normal.x * 0.05, mid.z + normal.z * 0.05), a, b, HALF_WIDTH
		)
		if ahead >= here:
			wrong += 1
	if wrong > 0:
		_fail("WINDING", "%d of %d wall quads face the earth instead of the corridor"
			% [wrong, contour.walls.size() / TunnelContour.face_verts()])


## Two segments crossing at an angle must leave no wall standing inside the tunnel they form.
## This is the artifact that per-segment geometry would produce and contouring is meant to avoid.
func _check_no_interior_faces() -> void:
	var n := 64
	var origin := Vector2(-2.0, -2.0)
	var a := Vector2(-1.0, 0.0)
	var b := Vector2(1.0, 0.0)
	var c := Vector2(0.0, -1.0)
	var d := Vector2(0.0, 1.0)

	var out := PackedFloat32Array()
	out.resize((n + 1) * (n + 1))
	for j in range(n + 1):
		for i in range(n + 1):
			var at := origin + Vector2(float(i), float(j)) * TunnelContour.TEXEL
			# Union of the two, which is the nearer surface of the pair.
			var dist := minf(
				TunnelContour.segment_distance(at, a, b, HALF_WIDTH),
				TunnelContour.segment_distance(at, c, d, HALF_WIDTH)
			)
			out[j * (n + 1) + i] = TunnelContour.encode(dist)

	var contour := TunnelContour.new()
	contour.build(out, n, origin, WALL_TOP, BARRIER_TOP)

	var interior := 0
	for t in range(0, contour.walls.size(), TunnelContour.face_verts()):
		var mid := (contour.walls[t] + contour.walls[t + 1]) * 0.5
		var at := Vector2(mid.x, mid.z)
		var dist := minf(
			TunnelContour.segment_distance(at, a, b, HALF_WIDTH),
			TunnelContour.segment_distance(at, c, d, HALF_WIDTH)
		)
		# A wall on the true outline sits at distance ~0. One standing inside the crossing would
		# be comfortably negative.
		if dist < -0.05:
			interior += 1
	if interior > 0:
		_fail("INTERIOR", "%d wall quads stand inside the crossing" % interior)


## The same tunnel contoured as two adjoining chunks must produce the same wall as one chunk does.
## A missing outer sample row would show up here as a gap along the join.
func _check_chunk_seam() -> void:
	var a := Vector2(0.0, 0.0)
	var b := Vector2(1.0, 0.0)

	var whole_n := 64
	var whole_origin := Vector2(-2.0, -2.0)
	var whole := TunnelContour.new()
	whole.build(_samples(whole_n, whole_origin, a, b), whole_n, whole_origin, WALL_TOP, BARRIER_TOP)

	var halves := 0.0
	for half in range(2):
		var n := 32
		var origin := whole_origin + Vector2(float(half) * 32.0 * TunnelContour.TEXEL, 0.0)
		var piece := TunnelContour.new()
		piece.build(_samples(n, origin, a, b), n, origin, WALL_TOP, BARRIER_TOP)
		halves += _area_of(piece.floors)

	# The split is only in x; the whole covers 64 texels of x against the two halves' 32 each.
	var whole_area := _area_of(whole.floors)
	if absf(halves - whole_area) > 0.005:
		_fail("SEAM", "two chunks floor %.4f m2 against one chunk's %.4f" % [halves, whole_area])


## The point of the whole exercise: a wall at an arbitrary angle must be straight, not stepped.
## Every vertex along one side of a 27-degree corridor should sit on one line.
func _check_angled_wall_is_straight() -> void:
	var n := 64
	var origin := Vector2(-2.0, -2.0)
	var angle := deg_to_rad(27.0)
	var a := Vector2(-1.2, 0.0)
	var b := a + Vector2(cos(angle), sin(angle)) * 2.4
	var contour := TunnelContour.new()
	contour.build(_samples(n, origin, a, b), n, origin, WALL_TOP, BARRIER_TOP)

	var direction := (b - a).normalized()
	var normal := Vector2(-direction.y, direction.x)
	# Walls on the flank -- away from the rounded ends -- must sit exactly half a width off the
	# centreline. A staircase would swing either side of it by half a texel or more.
	var worst := 0.0
	for t in range(0, contour.walls.size(), TunnelContour.face_verts()):
		var mid := (contour.walls[t] + contour.walls[t + 1]) * 0.5
		var point := Vector2(mid.x, mid.z)
		var along := (point - a).dot(direction)
		if along < 0.3 or along > (b - a).length() - 0.3:
			continue
		worst = maxf(worst, absf(absf((point - a).dot(normal)) - HALF_WIDTH))
	if worst > 0.02:
		_fail("STRAIGHTNESS", "angled wall wanders %.4f m off the true line" % worst)


## The wall is built out of one strip per isoline edge, each of them moved -- gouged outward,
## leaned back at the top -- and the strips are never told about each other. So the ONLY thing
## keeping them a surface rather than a heap of loose ribbons is that a vertex two strips share
## comes out of arithmetic that cannot tell which strip is asking.
##
## CHECKED AS A COUNT BECAUSE A CRACK IS AN ODD NUMBER. Every vertical column of a strip lies on
## the outline, which is a closed loop, so each column belongs to exactly two strips: once as one's
## right-hand edge, once as the next one's left. A column that turns up once has a strip beside it
## that put its own edge somewhere else -- which is a slot through the wall, the width of whatever
## the two disagreed by, running its full height. Both ends of the column are counted: the foot
## sits on the outline and can only agree, the head has the bevel and the gouging on it and is
## where a disagreement would actually land.
func _check_wall_is_welded() -> void:
	var n := 48
	var origin := Vector2(-1.5, -1.5)
	var a := Vector2(0.0, 0.0)
	var b := Vector2(1.0, 0.0)
	var contour := TunnelContour.new()
	contour.build(_samples(n, origin, a, b), n, origin, WALL_TOP, BARRIER_TOP)

	var seen := {}
	var stride := TunnelContour.face_verts()
	for t in range(0, contour.walls.size(), stride):
		# The two ends of the base row, and the two ends of the row at the top of the strip.
		for vertex: Vector3 in [
			contour.walls[t], contour.walls[t + 1],
			contour.walls[t + stride - 1], contour.walls[t + stride - 4]
		]:
			var key := "%.5f,%.5f,%.5f" % [vertex.x, vertex.y, vertex.z]
			seen[key] = (seen.get(key, 0) as int) + 1

	var lonely := 0
	for key: String in seen:
		if (seen[key] as int) != 2:
			lonely += 1
	if lonely > 0:
		_fail("WELD", "%d of %d wall vertices are not shared by exactly two faces"
			% [lonely, seen.size()])


## The rim of a wall stands back from the outline it grows out of by exactly the bevel -- no more,
## because the ground above is cut to that same number and any further would be a wall poking out
## from under it; no less, because any less is a slot straight through to nothing.
##
## MEASURED ON THE FLANK OF A STRAIGHT SEGMENT, where the answer is arithmetic anybody can do: the
## foot sits half a width off the centreline and the head sits half a width plus the bevel.
func _check_rim_stands_back() -> void:
	var n := 48
	var origin := Vector2(-1.5, -1.5)
	var a := Vector2(0.0, 0.0)
	var b := Vector2(1.0, 0.0)
	var contour := TunnelContour.new()
	contour.build(_samples(n, origin, a, b), n, origin, WALL_TOP, BARRIER_TOP)

	var bevel := TunnelContour.wall_bevel(WALL_TOP)
	var stride := TunnelContour.face_verts()
	var worst := 0.0
	var low := 0.0
	for t in range(0, contour.walls.size(), stride):
		var foot := contour.walls[t]
		var head := contour.walls[t + stride - 1]
		# Away from the rounded ends, where the wall runs parallel to the segment.
		if foot.x < 0.2 or foot.x > 0.8:
			continue
		if absf(head.y - WALL_TOP) > 0.0001:
			_fail("RIM", "wall tops out at %.4f m, expected %.4f" % [head.y, WALL_TOP])
			return
		low = maxf(low, absf(absf(foot.z) - HALF_WIDTH))
		worst = maxf(worst, absf(absf(head.z) - HALF_WIDTH - bevel))
	if low > 0.005:
		_fail("RIM", "wall foot sits %.4f m off the outline" % low)
	if worst > 0.005:
		_fail("RIM", "wall rim stands back %.4f m from the %.3f m it is cut for" % [worst, bevel])
