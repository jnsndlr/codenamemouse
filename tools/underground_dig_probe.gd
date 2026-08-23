extends SceneTree
## The four states the player is actually ever in, measured on one map.
##
##   godot --path . --resolution 3840x2160 --script tools/underground_dig_probe.gd
##
## Needs a real renderer. Run it at a resolution the machine cannot hold at its refresh rate, or
## every row comes back as the vsync interval and the differences vanish -- this display is
## variable-refresh, so a mean of exactly 8.33 or 6.90 means the row measured nothing.
##
## THE CROSS IS THE POINT, and it is what "fine until I go under" turned out to mean. Digging costs
## the same rebuild wherever the camera is; being underground costs the same drawing whether or not
## anybody digs. Only the two together are bad, and reading either row on its own sends you after
## the wrong one -- which is exactly what happened, twice.

const WINDOW: int = 300


func _initialize() -> void:
	var arena: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	(arena.get_node("MatchDirector") as MatchDirector).crew_size = 1
	root.add_child(arena)
	for i in range(40):
		await process_frame
	var network := arena.get_node("Tunnels") as TunnelNetwork
	var player := arena.get_node("Player") as Mouse
	network.show_crew_knowledge(player.team)

	for i in range(160):
		var row := float(i / 13) * 1.3 - 8.0
		var along := float(i % 13) * 1.05 - 6.5
		network.dig_segment(1, Vector2(along, row), 0, player.team)
	for i in range(30):
		await process_frame

	print(await _row(network, "SURFACE  idle", false))
	print(await _row(network, "SURFACE  digging", true))

	var home := Vector2i.MAX
	for entry: Variant in network.dug_cells(1):
		var cell: Vector2i = entry
		if network.can_stand(1, cell):
			home = cell
			break
	player.global_position = network.standing_point(1, home) + Vector3.UP * 0.1
	player.set_plane(1)
	player.velocity = Vector3.ZERO
	for i in range(120):
		await physics_frame
	print("underground: y=%.2f focus=%d" % [player.global_position.y, network.get_focus_plane()])

	print(await _row(network, "UNDER    idle", false))
	print(await _row(network, "UNDER    digging", true))
	quit()


var _next: int = 400


func _row(network: TunnelNetwork, label: String, digging: bool) -> String:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED, DisplayServer.MAIN_WINDOW_ID)
	Engine.max_fps = 0
	for i in range(30):
		await process_frame

	var frames: Array[float] = []
	var prims := 0.0
	var last := Time.get_ticks_usec()
	var cut := TunnelContour.TEXEL
	var id := 0
	for i in range(WINDOW):
		if digging:
			# One mouse cutting a trench, at the rate a held button drives it: one carve step per
			# frame, committing and starting the next stroke when it lands.
			if cut >= TunnelNetwork.SEG_LENGTH or id == 0:
				if id != 0:
					network.dig_segment(1, TunnelNetwork.segment_origin(id), 0, 0)
				var row := float(_next / 13) * 1.3 - 8.0
				var along := float(_next % 13) * 1.05 - 6.5
				id = TunnelNetwork.segment_id(Vector2(along, row), 0)
				_next += 1
				cut = TunnelContour.TEXEL
			network.carve(1, id, cut, 0)
			cut += TunnelContour.TEXEL
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append(float(now - last) / 1000.0)
		last = now
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	frames.sort()
	var total := 0.0
	var over := 0
	for f: float in frames:
		total += f
		if f > 16.6:
			over += 1
	return "STATE\t%-18s\tmean=%.2f\tfps=%3.0f\tmedian=%.2f\tp95=%.2f\tp99=%.2f\tmax=%.2f\thitch=%d/%d\tprims=%d" % [
		label, total / float(WINDOW), 1000.0 / (total / float(WINDOW)), frames[WINDOW / 2],
		frames[int(WINDOW * 0.95)], frames[int(WINDOW * 0.99)], frames[WINDOW - 1],
		over, WINDOW, int(prims / float(WINDOW)),
	]
