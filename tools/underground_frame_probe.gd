extends SceneTree
## Where the frame goes when you are STANDING IN A TUNNEL, which is where the game is reported
## to slow down and is not where [code]frame_probe.gd[/code] looks.
##
##   for s in baseline hud grass rocks boulders pixel ai lamps beams lid surface; do \
##     godot --path . --script tools/underground_frame_probe.gd -- $s; done
##
## Needs a real renderer -- do NOT add --headless, there is nothing to measure without one.
##
## THE SAME ONE-SCENARIO-PER-PROCESS RULE AS `frame_probe`, and for the same reason it learned the
## hard way: a live match evolving underneath a run of toggles measures the match, not the toggles.
##
## WHAT IS DIFFERENT FROM `frame_probe` is only the vantage, and it is the whole point. The surface
## probe photographs a mouse standing on a lawn with an undug map below it, so every underground
## system -- the lamps, the shafts of light, the cutaway shader punching the lid, the plane's floor
## and wall meshes -- is either absent or off-screen, and reads as free. This one digs a corridor
## network of the size a match actually reaches, puts the player in it, waits for the focus to
## settle on plane 1, and only then samples.
##
## THE NETWORK IS DUG, NOT FAKED, because the cost being hunted is a function of how much has been
## dug: the plane's floor and wall meshes are one mesh each for the whole layer, so what they cost
## is what the whole layer holds and not what is in front of the camera.

const WARMUP: int = 120
const SAMPLES: int = 240
const SIZE: Vector2i = Vector2i(2560, 1440)
## Roughly what two crews reach by the middle of a match -- see `dig_cost_probe`, which walks the
## same corridors and prices the digging rather than the drawing.
const STROKES: int = 240


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
	await process_frame
	await process_frame

	var network := arena.get_node("Tunnels") as TunnelNetwork
	var here := _dig(network)

	# UNDERGROUND BEFORE THE WARMUP, so the focus fade, the cutaway repaint and the lamp rebuild
	# all land before anything is timed -- each of them is a one-off that would otherwise be
	# charged to whichever scenario happened to run first.
	var player := arena.get_node("Player") as Mouse
	player.set_plane(1)
	player.global_position = here
	network.set_focus_plane(1)

	for i in range(WARMUP):
		await process_frame

	_apply(scenario, arena, network)
	for i in range(30):
		await process_frame

	var row := await _sample()
	print("ROW\t%s\t%.2f\t%.2f\t%.2f\t%d\t%d\t%.2f\tplane=%d" % [
		scenario, row["ms"], row["process"], row["physics"],
		int(row["draws"]), int(row["prims"]), row["worst"], player.get_plane(),
	])
	quit()


## A corridor network of match size on plane 1, and a point standing in it.
func _dig(network: TunnelNetwork) -> Vector3:
	var last := Vector2.ZERO
	for total in range(STROKES):
		var row := float(total / 24) * 1.3 - 14.0
		var along := float(total % 24) * 1.05 - 12.0
		last = Vector2(along, row)
		network.dig_segment(1, last, 0, 0)
	var cell := network.world_to_cell(Vector3(last.x, 0.0, last.y))
	return network.standing_point(1, cell)


func _apply(scenario: String, arena: Node, network: TunnelNetwork) -> void:
	match scenario:
		"baseline":
			pass
		"hud":
			(arena.get_node("HUD") as CanvasLayer).visible = false
		"grass":
			(arena.get_node("Surface/Grass") as Node3D).visible = false
		"rocks":
			(arena.get_node("Surface/Rocks") as Node3D).visible = false
		"boulders":
			(arena.get_node("Surface/Boulders") as Node3D).visible = false
		"surface":
			# The whole world above, which underground is meant to be dimmed and mostly occluded.
			(arena.get_node("Surface") as Node3D).visible = false
		"pixel":
			var camera := arena.get_node("CameraRig/Pitch/Camera3D") as Camera3D
			if camera.compositor != null and not camera.compositor.compositor_effects.is_empty():
				camera.compositor.compositor_effects[0].enabled = false
		"ai":
			for node: Node in get_nodes_in_group(Mouse.MOUSE_GROUP):
				if node.name != "Player":
					node.process_mode = Node.PROCESS_MODE_DISABLED
		"lamps":
			# The plane's lamps AND its shafts of light -- see `_rebuild_lamps`, which hangs both
			# under one root, so this is the whole lit dressing of the layer at once.
			for child in (network.get("_lamp_roots")[1] as Node3D).get_children():
				(child as Node3D).visible = false
		"beams":
			for child in (network.get("_lamp_roots")[1] as Node3D).get_children():
				if child is MeshInstance3D:
					(child as Node3D).visible = false
		"lid":
			# The ground overhead with the cutaway shader punching it. Underground this is the one
			# thing between the camera and the sky, and it is a full-screen-ish surface running a
			# discard.
			(arena.get_node("Surface/Ground") as Node3D).visible = false
		_:
			push_error("underground_frame_probe: unknown scenario '%s'" % scenario)


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
