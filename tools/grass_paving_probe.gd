extends SceneTree
## Does grass respect the paving?
##
## The rule already existed -- grass_patch.gd asks NoSurfaceZone.seals for every candidate -- but
## it was asking a group nothing had joined yet, because zones registered in `_ready` and the Grass
## node's own `_ready` runs first (it is the earlier sibling). So the patio was carpeted.
##
## DOES NOT READ THE MULTIMESHES BACK. The obvious check -- walk every instance transform and test
## it against the footprint -- passes vacuously under `--headless`: instance data lives in the
## RenderingServer, the dummy driver has none, and every blade reads as the origin. This asks the
## same question through `concealment_at`, which runs the identical `_grass_allowed` mask on the
## CPU, and cross-checks the blade count against the density integral over the slab.
##
##   godot --headless --script res://tools/grass_paving_probe.gd

const STEP := 0.25


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	# A scene added from `_initialize` has not run `_ready` yet -- the tree does that on its first
	# frame, and the whole bug under test is about what has run by then.
	await process_frame
	await process_frame

	var zones := get_nodes_in_group(NoSurfaceZone.GROUP)
	print("no-surface zones registered: %d" % zones.size())
	if zones.is_empty():
		print("FAIL -- nothing joined the group, the rule cannot apply")
		quit()
		return

	var grass: GrassPatch = scene.get_node("Surface/Grass")
	var ok := _check_planted(grass)
	for node in zones:
		ok = _check(grass, node as NoSurfaceZone) and ok
	print("PASS" if ok else "FAIL")
	quit()


## Does the number of blades planted match the mask that was supposed to govern them?
##
## THE ONLY CHECK THAT CATCHES THE ORIGINAL BUG. Sampling the mask after the fact always passes:
## by the time anything can ask, every zone has registered and `_grass_allowed` cheerfully refuses
## the patio. What was wrong was the mask AT PAINT TIME, and the only surviving trace of it is that
## more blades exist than the mask allows for.
##
## Acceptance is a coin flip per candidate, so the count is a binomial draw around the density
## integral -- roughly 300 wide at this lattice. A slab's worth of grass is 7,000, so a tolerance
## of a few thousand separates the two without ever firing on sampling noise.
func _check_planted(grass: GrassPatch) -> bool:
	var spacing: float = grass.sample_spacing
	var expected := 0.0
	var x := -grass.half_extent
	while x <= grass.half_extent:
		var z := -grass.half_extent
		while z <= grass.half_extent:
			expected += grass.density_at(grass.to_global(Vector3(x, 0.0, z)))
			z += STEP
		x += STEP
	expected *= (STEP * STEP) / (spacing * spacing)

	var planted := grass.blade_count()
	var drift := absf(planted - expected)
	print("planted %d blades; the mask allows for ~%d (drift %d)" % [planted, int(expected), int(drift)])
	if drift > 3000.0:
		print("   FAIL -- more grass exists than the mask permits, so it was painted against a different one")
		return false
	print("   ok -- what was planted matches the mask")
	return true


func _check(grass: Node3D, zone: NoSurfaceZone) -> bool:
	print("\n-- %s at %.1f,%.1f, half-extents %.1f x %.1f" % [
		zone.name, zone.global_position.x, zone.global_position.z, zone.extents.x, zone.extents.y
	])

	# 1. Nothing may be concealed by grass standing on the slab. `concealment_at` runs the same
	#    `_grass_allowed` mask the painter runs, so a non-zero reading here is a blade there.
	var on_slab := 0
	var samples := 0
	var worst := 0.0
	var x := -zone.extents.x
	while x <= zone.extents.x:
		var z := -zone.extents.y
		while z <= zone.extents.y:
			var at: Vector3 = zone.to_global(Vector3(x, 0.0, z))
			var cover: float = grass.concealment_at(at)
			samples += 1
			if cover > 0.0:
				on_slab += 1
				worst = maxf(worst, cover)
			z += STEP
		x += STEP
	print("   %d points sampled on the slab, %d with cover (worst %.3f)" % [samples, on_slab, worst])

	# 2. And the clearing must stop AT the slab. A rule that also wiped a wide ring around it would
	#    pass the test above while looking nothing like paving set into a lawn.
	var ring := 0
	var ring_samples := 0
	for band: float in [0.3, 0.6, 1.0]:
		for side: int in range(4):
			var along := -zone.extents.x
			while along <= zone.extents.x:
				var out := zone.extents.y + band if side < 2 else -(zone.extents.y + band)
				var local := Vector3(along, 0.0, out) if side < 2 else Vector3(out, 0.0, along)
				var at: Vector3 = zone.to_global(local)
				if absf(at.x) < 33.0 and absf(at.z) < 33.0:
					ring_samples += 1
					if grass.concealment_at(at) > 0.0:
						ring += 1
				along += STEP
	print("   %d points sampled just outside, %d with cover" % [ring_samples, ring])

	if on_slab > 0:
		print("   FAIL -- grass is growing on the paving")
		return false
	if ring == 0:
		print("   FAIL -- the slab has cleared its surroundings too, not just itself")
		return false
	print("   ok")
	return true
