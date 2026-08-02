extends SceneTree
## Where the cheese actually ended up.
##
## The cache ring is authored in angles and read as a picture, which is the combination that
## hides mistakes: the first pass fanned out from the wrong origin and put a wedge five metres
## from the red nest, well inside a defender's post, and it still looked like a ring. This
## prints the distances instead -- to each nest, to the arena centre, and between caches.
##
##   godot --headless --script res://tools/cache_layout_probe.gd


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(4):
		await process_frame

	var field: Node3D = scene.get_node("Surface/Cheese")
	var caches: Array[CheeseCache] = []
	for node in get_nodes_in_group(CheeseCache.GROUP):
		var cache := node as CheeseCache
		if cache != null:
			caches.append(cache)

	var nests: Array[Nest] = []
	for node in get_nodes_in_group(&"nest"):
		var nest := node as Nest
		if nest != null:
			nests.append(nest)

	print("%d caches, %d wedges total" % [caches.size(), caches.size() * field.wedges_each])
	var failures := 0
	var closest_nest := INF
	for cache in caches:
		var at := cache.global_position
		var line := "  (%6.1f,%6.1f)  centre %5.1f" % [at.x, at.z, Vector2(at.x, at.z).length()]
		for nest in nests:
			var gap := Vector2(at.x - nest.global_position.x, at.z - nest.global_position.z).length()
			closest_nest = minf(closest_nest, gap)
			line += "   %s %5.1f" % [Team.name_of(nest.team), gap]
		print(line)

	print("\nnearest any cache gets to a nest: %.1f m (floor is %.1f)" % [
		closest_nest, field.nest_clear
	])
	if closest_nest < field.nest_clear:
		print("FAIL -- a cache is inside a nest's keep-out")
		failures += 1

	# The two crews must have the same walk. Each cache should have a mirror through the origin.
	var worst_mirror := 0.0
	for cache in caches:
		var mirrored := -Vector2(cache.global_position.x, cache.global_position.z)
		var best := INF
		for other in caches:
			best = minf(best, mirrored.distance_to(
				Vector2(other.global_position.x, other.global_position.z)
			))
		worst_mirror = maxf(worst_mirror, best)
	print("worst mirror mismatch: %.2f m" % worst_mirror)
	if worst_mirror > 0.01:
		print("FAIL -- the map is not symmetric, one crew has a shorter walk")
		failures += 1

	# And nothing may sit on the nest-to-nest diagonal, which is the lane everyone runs anyway.
	var closest_to_lane := INF
	for cache in caches:
		var at := Vector2(cache.global_position.x, cache.global_position.z)
		# Distance from the 45-degree line through the origin.
		closest_to_lane = minf(closest_to_lane, absf(at.x - at.y) / sqrt(2.0))
	print("nearest any cache gets to the nest-to-nest lane: %.1f m" % closest_to_lane)
	if closest_to_lane < 4.0:
		print("FAIL -- cheese is on the lane, so nobody ever detours for it")
		failures += 1

	print("\nPASS" if failures == 0 else "\n%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)
