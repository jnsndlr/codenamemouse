extends SceneTree
## Controlled underground growth and repeated match teardown.
## godot --headless --path . --script tools/long_session_probe.gd -- 3 240
## Omit --headless for rendered frame timings. VSync is disabled; resolution is 1280x720.
## Gameplay is frozen so every cycle cuts the same ground and cannot quietly end the match.
## Frame timings include one carve/commit per frame, not just an idle finished network.

var _failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var cycles := maxi(2, int(args[0])) if args.size() > 0 else 3
	var strokes := maxi(40, int(args[1])) if args.size() > 1 else 240
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		DisplayServer.window_set_size(Vector2i(1280, 720))
	var clean_nodes := -1
	var clean_orphans := -1
	var clean_resources := -1
	for cycle in range(cycles):
		var arena := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
		root.add_child(arena)
		await process_frame
		await process_frame
		arena.process_mode = Node.PROCESS_MODE_DISABLED
		var network := arena.get_node("Tunnels") as TunnelNetwork
		network.profile_rebuilds = true
		var player := arena.get_node("Player") as Mouse
		player.set_plane(1)
		player.global_position = Vector3(-4.0, -TunnelNetwork.SPACING, -9.0)
		(arena.get_node("CameraRig") as Node3D).global_position = player.global_position
		# Settle underground dimming without advancing gameplay or moving the camera.
		for frame in range(90):
			arena.get_node("DepthFocus").call("_process", 1.0 / 60.0)
			await process_frame
		network.set_focus_plane(1)
		var frames: Array[float] = []
		var operations: Array[float] = []
		var replaced := 0
		for stroke in range(strokes):
			var from := Vector2(float(stroke % 24) * 1.05 - 12.0,
				float(stroke / 24) * 1.3 - 14.0)
			var id := TunnelNetwork.segment_id(from, 0)
			for step in range(1, 9):
				var began := Time.get_ticks_usec()
				if step == 8:
					network.dig_segment(1, from, 0, Team.BLUE)
				else:
					network.carve(1, id, float(step) * TunnelContour.TEXEL, Team.BLUE)
				operations.append(float(Time.get_ticks_usec() - began) / 1000.0)
				await process_frame
				frames.append(float(Time.get_ticks_usec() - began) / 1000.0)
			if (stroke + 1) % 40 == 0:
				var lamps: Node3D = network.get("_lamp_roots")[1]
				var previous := lamps.get_children()
				network.call("_relight", 1)
				if previous != lamps.get_children():
					replaced += 1
				print("GROW cycle=%d strokes=%d segments=%d operation_%s frame_%s nodes=%d resources=%d static_mb=%.1f lights=%d" % [
					cycle, stroke + 1, network.segment_count(1), _stats(operations), _stats(frames),
					int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
					int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
					Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
					lamps.get_child_count()])
				print("STAGES cycle=%d strokes=%d total_usec=%s draws=%d primitives=%d" % [
					cycle, stroke + 1, network.rebuild_profile,
					int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
					int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))])
				network.rebuild_profile.clear()
				operations.clear()
				frames.clear()
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("/tmp/mouse-long-session-%d.png" % cycle)
		print("RELIGHT unchanged_layout_replacements=%d" % replaced)
		if replaced > 0:
			_failures += 1
		arena.queue_free()
		for frame in range(8):
			await process_frame
		var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var orphans := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
		var resources := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
		print("CLEAN cycle=%d nodes=%d orphans=%d resources=%d static_mb=%.1f" % [cycle,
			nodes, orphans, int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
			Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0])
		if clean_nodes >= 0 and (nodes != clean_nodes or orphans != clean_orphans or resources > clean_resources):
			push_error("Scene teardown did not return to the warmed node/orphan/resource baseline")
			_failures += 1
		if clean_nodes < 0:
			clean_nodes = nodes
			clean_orphans = orphans
			clean_resources = resources
	print("LONG SESSION failures=%d renderer=%s" % [_failures, DisplayServer.get_name()])
	quit(1 if _failures > 0 else 0)

func _stats(values: Array[float]) -> String:
	values.sort()
	var sum := 0.0
	for value in values:
		sum += value
	return "mean=%.2f/p95=%.2f/p99=%.2f/max=%.2fms" % [sum / values.size(),
		values[int((values.size() - 1) * 0.95)], values[int((values.size() - 1) * 0.99)], values[-1]]
