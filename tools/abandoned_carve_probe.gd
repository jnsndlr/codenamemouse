extends SceneTree
## Fixed local rebuild against a growing history of distant, genuinely cut partial strokes.
## Run headless to isolate contour CPU time; construction is outside the measured samples.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var network := TunnelNetwork.new()
	network.rock_density = 0.0
	network.rock_density_deeper = 0.0
	root.add_child(network)
	var local := Vector2(0.0, 20.0)
	network.carve(1, TunnelNetwork.segment_id(local, 0), 0.5, Team.BLUE)
	var built := 0
	for target in [0, 128, 512, 1024]:
		while built < target:
			var from := Vector2(-32.0 + float(built % 32) * 2.0, -34.0 + float(built / 32))
			network.carve(1, TunnelNetwork.segment_id(from, built % 8), 0.375, built % 2)
			built += 1
			if built % 32 == 0:
				await process_frame
		network.profile_rebuilds = true
		network.rebuild_profile.clear()
		var samples: Array[float] = []
		for repeat in range(64):
			network.call("_touch_span", 1, local, local + Vector2(0.5, 0.0), false)
			var began := Time.get_ticks_usec()
			network.call("_rebuild_walls", 1, false)
			samples.append(float(Time.get_ticks_usec() - began) / 1000.0)
		samples.sort()
		var total := 0.0
		for sample in samples:
			total += sample
		print("ABANDONED distant=%d mean=%.3f p99=%.3f ms stages=%s" % [target,
			total / samples.size(), samples[62], network.rebuild_profile])
		network.profile_rebuilds = false
	network.queue_free()
	await process_frame
	quit()
