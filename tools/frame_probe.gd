extends SceneTree
## Where the frame actually goes. Measured by turning one system off, not by reading.
##
##   godot --path . --script tools/frame_probe.gd -- baseline
##   for s in baseline hud grass rocks boulders pixel ai; do godot ... -- $s; done
##
## Needs a real renderer -- do NOT add --headless, there is nothing to measure without one.
##
## ONE SCENARIO PER PROCESS, which is the whole design and was learned the hard way. The first
## version toggled all six systems inside a single run, and measured a live match evolving
## underneath it: over the thirty seconds the seven scenarios took, mice moved, tunnels got dug
## and the camera followed the player somewhere else, and those changed what was on screen far
## more than the toggles did. It reported the HUD as costing 1500 draw calls of 3D geometry.
##
## A fresh process per scenario costs ninety seconds of wall clock and buys the only thing that
## matters: every row starts from the same frame of the same match.
##
## MEASURED EARLY, right after warmup, for the same reason -- the further into a match the sample
## is taken, the less it is a measurement of the scenario and the more it is a measurement of
## whatever the bots happened to do.
##
## VSYNC OFF and rendered at 2560x1440, because at the window size everything cheap reads as
## exactly the refresh interval and the probe reports that all six systems are free.

const WARMUP: int = 120
const SAMPLES: int = 240
const SIZE: Vector2i = Vector2i(2560, 1440)


func _initialize() -> void:
	var scenario: String = "baseline"
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		scenario = args[0]

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED, DisplayServer.MAIN_WINDOW_ID)
	Engine.max_fps = 0
	DisplayServer.window_set_size(SIZE)
	root.content_scale_size = SIZE

	var arena: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(arena)
	for i in range(WARMUP):
		await process_frame

	_apply(scenario, arena)
	for i in range(30):
		await process_frame

	var row := await _sample()
	print("ROW\t%s\t%.2f\t%.2f\t%.2f\t%d\t%d\t%.2f" % [
		scenario, row["ms"], row["process"], row["physics"],
		int(row["draws"]), int(row["prims"]), row["worst"],
	])
	quit()


func _apply(scenario: String, arena: Node) -> void:
	match scenario:
		"baseline":
			pass
		"hud":
			(arena.get_node("HUD") as CanvasLayer).visible = false
		"minimap":
			(arena.get_node("HUD/Minimap") as Control).visible = false
		"grass":
			(arena.get_node("Surface/Grass") as Node3D).visible = false
		"rocks":
			(arena.get_node("Surface/Rocks") as Node3D).visible = false
		"boulders":
			(arena.get_node("Surface/Boulders") as Node3D).visible = false
		"pixel":
			var camera := arena.get_node("CameraRig/Pitch/Camera3D") as Camera3D
			if camera.compositor != null and not camera.compositor.compositor_effects.is_empty():
				camera.compositor.compositor_effects[0].enabled = false
		"ai":
			for node: Node in get_nodes_in_group(Mouse.MOUSE_GROUP):
				if node.name != "Player":
					node.process_mode = Node.PROCESS_MODE_DISABLED
		_:
			push_error("frame_probe: unknown scenario '%s'" % scenario)


func _sample() -> Dictionary:
	var worst: float = 0.0
	var total: float = 0.0
	var last := Time.get_ticks_usec()
	for i in range(SAMPLES):
		await process_frame
		var now := Time.get_ticks_usec()
		var ms := float(now - last) / 1000.0
		last = now
		total += ms
		worst = maxf(worst, ms)

	return {
		"ms": total / float(SAMPLES),
		"worst": worst,
		"process": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"prims": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
	}
