extends SceneTree
## How much of the painted field the camera actually pays for, per chunk size and cull margin.
##
## The camera is ORTHOGRAPHIC and tightly zoomed (camera_rig.gd: size 7.5 idle -> 10.75 sprint,
## pitch 48, yaw 45), so the visible ground is a small rotated rectangle inside a 68 m arena.
## Chunk granularity, not blade count, is what decides how much of the field is vertex-shaded.
##   godot --headless --script res://tools/grass_cull_probe.gd

const HALF_EXTENT := 34.0
const ASPECT := 1280.0 / 720.0
const PITCH_DEGREES := 48.0
const YAW_DEGREES := 45.0


## Quit after one iteration. `quit()` from a SceneTree script's `_init` or `_initialize` sets a
## flag before there is a loop to read it, so the process prints everything and then sits there --
## which looks exactly like a hang in whichever measurement happened to be last.
func _process(_delta: float) -> bool:
	return true


## `_initialize`, not `_init`, matching tools/match_audit.gd.
func _initialize() -> void:
	for zoom: float in [7.5, 10.75]:
		print("\n=== ortho size %.2f ===" % zoom)
		var half_across := zoom * 0.5 * ASPECT
		var half_along := zoom * 0.5 / sin(deg_to_rad(PITCH_DEGREES))
		var area := half_across * 2.0 * half_along * 2.0
		print("visible ground: %.1f m across x %.1f m deep = %.0f m^2 (%.1f%% of the arena)" % [
			half_across * 2.0, half_along * 2.0, area, 100.0 * area / (HALF_EXTENT * 2.0 * HALF_EXTENT * 2.0)
		])
		# 4 m is left out of the sweep on purpose: the SAT pass is quadratic in chunk count, and it
		# buys about a point and a half over 6 m for more than double the draw calls.
		for chunk: float in [8.0, 6.0]:
			for margin: float in [2.0, 0.35]:
				var share := _measure(half_across, half_along, chunk, margin)
				print("  chunk %.0f m, margin %.2f m: %5.1f%% of blades drawn (%.1fx the ideal), ~%d chunks" % [
					chunk, margin, share.x * 100.0, share.x / (area / (HALF_EXTENT * 2.0 * HALF_EXTENT * 2.0)), int(share.y)
				])


## Average, over many camera positions, of the fraction of chunk area that overlaps the view.
func _measure(half_across: float, half_along: float, chunk: float, margin: float) -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var chunk_count := ceili(HALF_EXTENT * 2.0 / chunk)
	var total_chunks := chunk_count * chunk_count
	# Enough camera placements to average out where the chunk grid happens to fall. The SAT test
	# runs against every chunk, so this is quadratic in chunk count -- keep it small.
	var trials := 12
	var hit_sum := 0.0

	var forward := Vector2(cos(deg_to_rad(YAW_DEGREES)), sin(deg_to_rad(YAW_DEGREES)))
	var side := Vector2(-forward.y, forward.x)

	for t in range(trials):
		var eye := Vector2(rng.randf_range(-20.0, 20.0), rng.randf_range(-20.0, 20.0))
		# The four corners of the visible ground rectangle, IN ORDER. Walking sx then sy in nested
		# loops emits them as a bowtie, and SAT on a self-intersecting polygon takes its edge
		# normals off the crossing diagonals -- so it answers a question about a different shape.
		var across := side * half_across
		var along := forward * half_along
		var corners := PackedVector2Array([
			eye - across - along,
			eye + across - along,
			eye + across + along,
			eye - across + along,
		])
		var hits := 0
		for z in range(chunk_count):
			for x in range(chunk_count):
				var lo := Vector2(-HALF_EXTENT + x * chunk, -HALF_EXTENT + z * chunk) - Vector2(margin, margin)
				var hi := lo + Vector2(chunk + margin * 2.0, chunk + margin * 2.0)
				if _overlaps(corners, lo, hi):
					hits += 1
		hit_sum += float(hits)

	var mean_hits := hit_sum / float(trials)
	return Vector2(mean_hits / float(total_chunks), mean_hits)


## Separating-axis test between the rotated view rectangle and an axis-aligned chunk box.
func _overlaps(corners: PackedVector2Array, lo: Vector2, hi: Vector2) -> bool:
	# Almost every chunk in the arena is nowhere near the view. Reject those on the view's own
	# bounding box before building arrays and projecting onto eight axes.
	var view_lo := corners[0]
	var view_hi := corners[0]
	for point: Vector2 in corners:
		view_lo = view_lo.min(point)
		view_hi = view_hi.max(point)
	if view_hi.x < lo.x or hi.x < view_lo.x or view_hi.y < lo.y or hi.y < view_lo.y:
		return false

	var box := PackedVector2Array([lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)])
	for shape: PackedVector2Array in [corners, box]:
		for i in range(shape.size()):
			var edge := shape[(i + 1) % shape.size()] - shape[i]
			var axis := Vector2(-edge.y, edge.x)
			if axis.length_squared() < 0.0001:
				continue
			var a := _project(corners, axis)
			var b := _project(box, axis)
			if a.y < b.x or b.y < a.x:
				return false
	return true


func _project(shape: PackedVector2Array, axis: Vector2) -> Vector2:
	var lo := INF
	var hi := -INF
	for point: Vector2 in shape:
		var d := point.dot(axis)
		lo = minf(lo, d)
		hi = maxf(hi, d)
	return Vector2(lo, hi)
