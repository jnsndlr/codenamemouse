extends SceneTree
## The Brute's cave-in mark, hot and cooling.
##
##   godot --path . --resolution 1100x760 --script tools/collapse_cursor_shot.gd
##
## Needs a real renderer. Writes /tmp/collapse_ready.png and /tmp/collapse_cooling.png.
##
## WHY THIS ONE EXISTS AT ALL, given no audit was failing. The mark it photographs replaced a
## wireframe cube that was *correct* and still wrong: it was the same cube digging drew, so a Brute
## aiming underground read as a dig cursor stuck to the screen. Nothing headless can catch that,
## because the bug is not that the wrong thing was drawn -- it is that two right things looked
## identical. A picture is the only check that can fail on it.
##
## What to look for: a torn outline lying flat on the floor of ONE cell, orange when the ability is
## up and cold blue while it cools, with the corridor and the mouse plainly visible through it. If
## it reads as a cube, or as a neat rectangle, it has regressed to the thing it replaced.

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
	# A corridor to stand in, running north from the shaft landing.
	var at := Vector2(-6.0, 8.0)
	var north := TunnelNetwork.ANGLE_STEPS / 4
	for i in range(4):
		var id := TunnelNetwork.segment_id(at, north)
		if not network.dig_segment(PLANE, at, north, Team.BLUE):
			break
		at = TunnelNetwork.segment_end(id)

	# A BRUTE, because the cursor is gated on the class and a Generalist would photograph an empty
	# corridor -- which is a pass-looking picture of the feature being switched off.
	player.set_class(MouseClass.BRUTE)
	# STOOD WELL BACK OF WHAT IT IS AIMING AT, within the ability's 1.6-cell reach but far enough
	# that the mouse is not lying on top of the mark. The first framing put the two in the same
	# place and photographed a mark half-hidden behind a mouse, which is a bad picture of a good
	# feature -- and this file exists precisely because a picture is the only check here.
	player.global_position = Vector3(at.x, network.plane_y(PLANE) + 0.1, at.y - 2.0)
	player.velocity = Vector3.ZERO
	player.set_plane(PLANE)

	var cave_in: Node = player.get_node("CaveIn")
	var aim := Vector3(at.x, network.plane_y(PLANE), at.y - 0.7)

	for shot: Array in [[true, "ready"], [false, "cooling"]]:
		# Driven straight at the cursor rather than through the ability, so the cooling half does
		# not have to be produced by actually spending a cave-in and waiting out its cooldown.
		cave_in.set("_cooldown_left", 0.0 if shot[0] else 4.0)
		for i in range(50):
			await physics_frame
			var frame := InputFrame.new()
			frame.aim_point = aim
			player.drive(frame)
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png("/tmp/collapse_%s.png" % shot[1])

	print("")
	print("wrote /tmp/collapse_ready.png and /tmp/collapse_cooling.png")
	print("a torn outline flat on one cell's floor -- orange when it will fire, cold while it cools.")
	quit()
