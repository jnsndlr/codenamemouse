extends SceneTree
## What the two field rules do, each photographed with itself off and on.
##
##   godot --path . --resolution 1100x760 --script tools/island_shot.gd
##
## Needs a real renderer. Writes four files to /tmp.
##
## THE SAME TUNNEL, PHOTOGRAPHED TWICE. island_probe.gd proves the earth is found and opened out;
## it cannot say whether what is left reads as a room. Each pair is the same strokes from the same
## camera with one setting changed between them, so anything that differs is that setting and
## nothing else.
##
## What to look for:
##   island_before.png -- a nub of earth standing inside a loop, full wall height, too small to aim
##                        a stroke at.
##   island_after.png  -- the same loop, open. No nub, no stub of wall where it stood, and no seam
##                        across the floor where the chunk borders run.
##   sliver_before.png -- two passes cut 1.2m apart at a 0.50m minimum: the 20cm divider between
##                        them does not survive, and what should be two corridors is one room.
##   sliver_after.png  -- the same two passes at the shipped minimum. The divider stands. This pair
##                        is the setting rather than the rule: see TunnelNetwork.earth_min_thickness
##                        for why the ceiling is set by what the field can see and not by taste.

const PLANE: int = 1


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	var network := scene.get_node("Tunnels") as TunnelNetwork
	network.rock_density = 0.0
	var boulders := scene.get_node_or_null("Surface/Boulders")
	if boulders != null:
		boulders.free()
	(scene.get_node("MatchDirector") as MatchDirector).crew_size = 1
	root.add_child(scene)
	await process_frame
	await process_frame

	var player := scene.get_node("Player") as Mouse

	# THE THICKNESS RULE HELD OFF WHILE THE ISLAND PAIR IS TAKEN, since it would open the scrap out
	# first and there would be nothing to photograph. Each pair changes one setting and leaves the
	# other where it was.
	var shipped := network.earth_min_thickness
	network.earth_min_thickness = 0.0

	# A ring tight enough to close on itself: five-ish sides of a pentagon, each stroke starting
	# where the last ended. The middle is what gets pinched off.
	var at := Vector2(-14.0, 12.0)
	var turn := TunnelNetwork.ANGLE_STEPS / 5
	var angle := 0
	var path: Array[Vector2] = [at]
	for i in range(6):
		if not network.dig_segment(PLANE, at, angle % TunnelNetwork.ANGLE_STEPS, Team.BLUE):
			break
		at = TunnelNetwork.segment_end(
			TunnelNetwork.segment_id(at, angle % TunnelNetwork.ANGLE_STEPS)
		)
		path.append(at)
		angle += turn

	var scrap := _first_island(network)
	if scrap == Vector2.INF:
		printerr("the ring closed without pinching anything off -- nothing to photograph")
		quit(1)
		return
	print("scrap at %v" % scrap)

	# STOOD ON THE RING, NOT ON THE SCRAP. The spot the scrap occupies is solid earth in the first
	# shot: put the mouse there and it falls through to the respawn, and the photograph is of a lawn.
	var stand := path[path.size() / 2]

	network.island_max_span = 0.0
	network._rebuild_mask(PLANE)
	await _shoot(player, network, stand, "/tmp/island_before.png")

	network.island_max_span = 0.75
	network._rebuild_mask(PLANE)
	await _shoot(player, network, stand, "/tmp/island_after.png")

	# TWO PASSES, CUT JUST TOO CLOSE TOGETHER: a metre of tunnel at 1.2m spacing leaves twenty
	# centimetres of earth standing between them. Whether that divider is debris or a wall is the
	# whole of what `earth_min_thickness` decides, and it is a decision a player will make by
	# accident dozens of times a match, so it is worth two photographs.
	var north := TunnelNetwork.ANGLE_STEPS / 4
	var first := Vector2(6.0, -14.0)
	var second := Vector2(7.2, -14.0)
	for i in range(10):
		network.dig_segment(PLANE, first, north, Team.BLUE)
		network.dig_segment(PLANE, second, north, Team.BLUE)
		first = TunnelNetwork.segment_end(TunnelNetwork.segment_id(first, north))
		second = TunnelNetwork.segment_end(TunnelNetwork.segment_id(second, north))
	# Stood in the left-hand pass: the divider itself is solid earth in the second shot, and a mouse
	# put there falls through to the respawn and photographs a lawn.
	var along := Vector2(6.0, -9.0)

	network.earth_min_thickness = 0.5
	network._rebuild_mask(PLANE)
	await _shoot(player, network, along, "/tmp/sliver_before.png")

	network.earth_min_thickness = shipped
	network._rebuild_mask(PLANE)
	await _shoot(player, network, along, "/tmp/sliver_after.png")

	print("")
	print("wrote island_before/after.png and sliver_before/after.png in /tmp")
	print("island: a nub standing inside the loop, then the same loop open.")
	print("sliver: a 20cm divider eaten at a 0.50m minimum, then standing at the shipped %.3fm." % [
		shipped
	])
	quit()


## The middle of the first scrap the cull found, or INF if it found none.
func _first_island(network: TunnelNetwork) -> Vector2:
	for key: int in network._chunk_cache[PLANE]:
		var boxes: PackedFloat32Array = network._chunk_cache[PLANE][key]["islands"]
		if boxes.size() >= 4:
			return Vector2((boxes[0] + boxes[2]) * 0.5, (boxes[1] + boxes[3]) * 0.5)
	return Vector2.INF


## PHYSICS frames, and enough of them: camera_rig.gd follows on the physics tick with an
## exponential lerp, so a teleported player is chased rather than jumped to.
func _shoot(player: Mouse, network: TunnelNetwork, at: Vector2, path: String) -> void:
	player.global_position = Vector3(at.x, network.plane_y(PLANE) + 0.1, at.y)
	player.velocity = Vector3.ZERO
	player.set_plane(PLANE)
	for i in range(90):
		await physics_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(path)
