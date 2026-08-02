extends SceneTree
## Headless measurement of the grass paint mask (scripts/maps/grass_patch.gd).
##
## Reports what the exported knobs actually produce: blade counts, where those blades sit on the
## density ramp, and -- the number the knobs do not tell you -- how many METRES wide the feathered
## edge of a grass shape is. That last one is why the curve changed: a fixed band of noise VALUE is
## a wildly variable distance on the ground, so shapes had no dense interior left.
##
##   godot --headless --script res://tools/grass_probe.gd

const HALF_EXTENT := 34.0
const CLEAR_RADIUS := 4.0
const GRADIENT_STEP := 0.05

var field_frequency := 0.055
var detail_frequency := 0.19
var detail_influence := 0.22
var coverage_threshold := 0.49
var grass_seed := 20260731

## What grass_patch.gd used to do: a second threshold, feathered in noise-value space.
var old_dense_threshold := 0.66
## What it does now: feathered in metres.
var edge_feather := 0.6
var cover_feather := 1.4

var _field: FastNoiseLite
var _detail: FastNoiseLite


## Quit after one iteration -- see the note in grass_cull_probe.gd.
func _process(_delta: float) -> bool:
	return true


## `_initialize`, not `_init`, matching tools/match_audit.gd.
func _initialize() -> void:
	_field = _make_noise(grass_seed, field_frequency, 4)
	_detail = _make_noise(grass_seed + 7919, detail_frequency, 3)

	print("=== OLD: value-space band %.2f -> %.2f ===" % [coverage_threshold, old_dense_threshold])
	_report(_old_density)
	_measure_feather()

	print("\n=== NEW: %.2f m metric rim ===" % edge_feather)
	_report(_new_density)

	print("\n=== bake cost of the metric rim ===")
	for spacing: float in [0.15, 0.12, 0.10]:
		_time_paint(spacing)

	quit()


func _make_noise(s: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = s
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_gain = 0.52
	noise.fractal_lacunarity = 2.0
	return noise


func _noise_01(noise: FastNoiseLite, at: Vector2) -> float:
	return clampf(noise.get_noise_2d(at.x, at.y) * 0.5 + 0.5, 0.0, 1.0)


func _painted(at: Vector2) -> float:
	var broad := _noise_01(_field, at)
	var detail := _noise_01(_detail, at) - 0.5
	return broad + detail * detail_influence


func _old_density(at: Vector2) -> float:
	var high := maxf(old_dense_threshold, coverage_threshold + 0.001)
	return pow(smoothstep(coverage_threshold, high, _painted(at)), 1.25)


## Mirrors grass_patch.gd's `_edge_distance`.
func _edge_distance(at: Vector2) -> float:
	var above := _painted(at) - coverage_threshold
	if above <= 0.0:
		return -1.0
	var gx := (_painted(at + Vector2(GRADIENT_STEP, 0.0))
		- _painted(at - Vector2(GRADIENT_STEP, 0.0))) / (2.0 * GRADIENT_STEP)
	var gz := (_painted(at + Vector2(0.0, GRADIENT_STEP))
		- _painted(at - Vector2(0.0, GRADIENT_STEP))) / (2.0 * GRADIENT_STEP)
	var slope := sqrt(gx * gx + gz * gz)
	if slope < 0.0001:
		return edge_feather
	return above / slope


func _new_density(at: Vector2) -> float:
	return smoothstep(0.0, edge_feather, _edge_distance(at))


func _allowed(spot: Vector2) -> bool:
	if absf(spot.x) > HALF_EXTENT or absf(spot.y) > HALF_EXTENT:
		return false
	return spot.length() >= CLEAR_RADIUS


func _report(curve: Callable) -> void:
	var buckets := PackedInt32Array()
	buckets.resize(10)
	var total_samples := 0
	var covered := 0
	var density_sum := 0.0
	var cover_sum := 0.0

	var step := 0.25
	var count := int(HALF_EXTENT * 2.0 / step)
	for z in range(count):
		for x in range(count):
			var spot := Vector2(-HALF_EXTENT + x * step, -HALF_EXTENT + z * step)
			if not _allowed(spot):
				continue
			total_samples += 1
			var d: float = curve.call(spot)
			density_sum += d
			cover_sum += smoothstep(0.0, cover_feather, _edge_distance(spot))
			if d > 0.0:
				covered += 1
				buckets[mini(int(d * 10.0), 9)] += 1

	print("ground inside a grass shape: %.1f%%" % (100.0 * covered / float(total_samples)))
	print("mean blade density over the arena: %.3f" % (density_sum / float(total_samples)))
	print("share of GRASSED ground in each density band:")
	for i in range(10):
		var share := 100.0 * buckets[i] / float(maxi(covered, 1))
		print("  %.1f-%.1f  %5.1f%%  %s" % [
			i * 0.1, (i + 1) * 0.1, share, "#".repeat(int(share * 0.6))
		])
	print("mean concealment over the arena: %.3f" % (cover_sum / float(total_samples)))
	for spacing: float in [0.15, 0.12, 0.10]:
		var per_m2 := 1.0 / (spacing * spacing)
		print("  blades at spacing %.2f (%.0f/m^2): ~%d" % [
			spacing, per_m2, int(density_sum * step * step * per_m2)
		])


## How wide the OLD value-space band actually was on the ground, shape by shape.
func _measure_feather() -> void:
	var widths: Array[float] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var high := maxf(old_dense_threshold, coverage_threshold + 0.001)
	var tries := 0
	while widths.size() < 4000 and tries < 400000:
		tries += 1
		var spot := Vector2(
			rng.randf_range(-HALF_EXTENT, HALF_EXTENT),
			rng.randf_range(-HALF_EXTENT, HALF_EXTENT)
		)
		if not _allowed(spot):
			continue
		var here := _painted(spot)
		if here < coverage_threshold or here > high:
			continue
		var gx := (_painted(spot + Vector2(GRADIENT_STEP, 0.0))
			- _painted(spot - Vector2(GRADIENT_STEP, 0.0))) / (2.0 * GRADIENT_STEP)
		var gz := (_painted(spot + Vector2(0.0, GRADIENT_STEP))
			- _painted(spot - Vector2(0.0, GRADIENT_STEP))) / (2.0 * GRADIENT_STEP)
		var grad := sqrt(gx * gx + gz * gz)
		if grad < 0.0001:
			continue
		widths.append((high - coverage_threshold) / grad)

	if widths.is_empty():
		return
	widths.sort()
	print("that band's width ON THE GROUND, over %d samples:" % widths.size())
	print("  p10 %.2f m   median %.2f m   p90 %.2f m" % [
		widths[int(widths.size() * 0.1)],
		widths[widths.size() / 2],
		widths[int(widths.size() * 0.9)],
	])


## The paint loop as grass_patch.gd runs it: mask first, then the density with its gradient.
func _time_paint(spacing: float) -> void:
	var start := Time.get_ticks_usec()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var count := int(HALF_EXTENT * 2.0 / spacing)
	var accepted := 0
	for z in range(count):
		for x in range(count):
			var spot := Vector2(-HALF_EXTENT + x * spacing, -HALF_EXTENT + z * spacing)
			if not _allowed(spot):
				continue
			if rng.randf() > _new_density(spot):
				continue
			accepted += 1
	print("spacing %.2f: %d candidates -> %d blades, %.0f ms" % [
		spacing, count * count, accepted, (Time.get_ticks_usec() - start) / 1000.0
	])
