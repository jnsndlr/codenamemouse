extends SceneTree
## Regression checks for state retained across peer churn and unchanged tunnel lighting.
var failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _run() -> void:
	var arena := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(arena)
	await process_frame
	await process_frame
	arena.process_mode = Node.PROCESS_MODE_DISABLED
	var net_match: Node = arena.get_node("NetMatch")
	var view: TunnelView = net_match.get("_view")
	var started: Dictionary = net_match.get("_started")
	var told: Dictionary = view.get("_told")
	var transport: NetTransport = net_match.get("_transport")
	started[987654] = true
	told[987654] = {"old terrain": 3}
	told[987655] = {"still connected": 3}
	transport.peer_left.emit(987654)
	_check(not started.has(987654) and not told.has(987654), "departed peer releases terrain cursor and start history")
	_check(told.has(987655), "departure preserves other peers")
	told.erase(987655)

	var bot: Bot
	for mouse in get_nodes_in_group(Mouse.MOUSE_GROUP):
		if mouse is Bot:
			bot = mouse
			break
	var spotting := get_first_node_in_group(Spotting.SPOTTING_GROUP) as Spotting
	var ghost := Mouse.new()
	var cleared: Dictionary = bot.get("_cleared")
	cleared[ghost] = true
	spotting.contacts_for(bot.team)[ghost] = {"age": 0.0}
	ghost.free()
	# Shared contacts may remove the dead mouse before the bot gets its next turn.
	spotting.call("_forget", 0.1)
	bot.call("_seen_within", Vector3.ZERO, 1.0, false)
	_check(cleared.is_empty(), "bot prunes ghosts already removed by spotting")

	var network := arena.get_node("Tunnels") as TunnelNetwork
	for i in range(20):
		network.dig_segment(1, Vector2(-12.0 + i, -14.0), 0, Team.BLUE)
	network.set_focus_plane(1)
	var lamps: Node = network.get("_lamp_roots")[1]
	var existing := lamps.get_children()
	network.call("_relight", 1)
	_check(not existing.is_empty() and existing == lamps.get_children(), "unchanged lighting reuses nodes")
	for side in [Team.RED, Team.BLUE, -1]:
		network.show_crew_knowledge(side)
		var cached := _lighting(lamps)
		(network.get("_lamp_layouts") as Dictionary).clear()
		network.call("_relight", 1)
		_check(cached == _lighting(lamps), "crew %d lighting matches uncached rebuild" % side)
	network.lamp_energy += 0.5
	network.call("_relight", 1)
	var energy_ok := false
	for child in lamps.get_children():
		if child is OmniLight3D:
			energy_ok = is_equal_approx(child.light_energy, network.lamp_energy)
			break
	_check(energy_ok, "appearance changes invalidate lighting")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var uploaded := network.dug_mask(1).get_image().get_data()
		var cpu: Image = network.get("_mask_images")[1]
		_check(uploaded == cpu.get_data(), "batched GPU mask matches completed CPU image")
	arena.queue_free()
	await process_frame
	await process_frame
	print("LIFETIME failures=%d" % failures)
	quit(1 if failures else 0)

func _lighting(lamps: Node) -> Array:
	var result: Array = []
	for child in lamps.get_children():
		var entry: Array = [child.get_class(), child.position]
		if child is Light3D:
			entry.append(child.light_color)
			entry.append(child.light_energy)
		result.append(entry)
	return result
