extends SceneTree
## A mouse caught in the act of digging: the scrabble pose and the dust off the face.
##
##   godot --path . --resolution 1100x760 --script tools/dig_dust_shot.gd
##
## Needs a real renderer. Writes /tmp/dig_dust_kick.png (just after a stroke lands, the burst
## still in the air) and /tmp/dig_dust_hold.png (mid-recharge, the trickle and the pose).
##
## THE ONE THING THE AUDITS CANNOT ANSWER, again. tunnel_audit proves the strokes cut and the
## cooldown charges; nothing headless can say whether the dust reads as EFFORT at this zoom or as
## the beige weather [StompDust]'s own history warns about, or whether the scrabble reads as
## digging rather than as a mouse glitching into the floor.
##
## What to look for: the mouse nose-down at the corridor's end, small puffs coming off the face
## toward it, and the corridor and cursor still plainly visible THROUGH the dust. If the dust is
## the biggest thing in either frame, it is wrong.

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

	# A short run of corridor to stand in, dug straight through the network so the player's own
	# recharge starts the scene full.
	var at := Vector2(-6.0, 8.0)
	var north := TunnelNetwork.ANGLE_STEPS / 4
	for i in range(3):
		var id := TunnelNetwork.segment_id(at, north)
		if not network.dig_segment(PLANE, at, north, Team.BLUE):
			break
		at = TunnelNetwork.segment_end(id)

	# RIGHT AT THE FACE, which `dig_reach` now insists on: a stroke may only start within arm's
	# length of the mouse, so the body-length gap this used to stand off at is far enough to make
	# the whole shot a picture of a mouse failing to dig. It photographed as a tidy corridor and an
	# idle mouse, which is exactly what a reach bug looks like and nothing like an error.
	player.global_position = Vector3(at.x, network.plane_y(PLANE) + 0.1, at.y - 0.4)
	player.velocity = Vector3.ZERO
	player.set_plane(PLANE)
	for i in range(60):
		await physics_frame

	var aim := Vector3(at.x, network.plane_y(PLANE), at.y + 0.8)
	# The first press cuts instantly, so a handful of frames in, the burst is still airborne.
	await _dig(player, aim, 8)
	await _snap("/tmp/dig_dust_kick.png")
	# Mid-recharge: no stroke moving, only the trickle and the pose saying the work continues.
	await _dig(player, aim, 14)
	await _snap("/tmp/dig_dust_hold.png")

	print("")
	print("wrote /tmp/dig_dust_kick.png and /tmp/dig_dust_hold.png")
	print("nose down, small puffs off the face, and the corridor visible through all of it.")
	quit()


## Hold the dig button on `aim` for a stretch of real frames, through the player's own drive
## door -- the controller, the mouse's scrabble and the dust all run their ordinary processes.
func _dig(player: Mouse, aim: Vector3, frames: int) -> void:
	for i in range(frames):
		await physics_frame
		var frame := InputFrame.new()
		frame.aim_point = aim
		frame.set_held(InputFrame.Action.DIG, true)
		if i == 0:
			frame.set_pressed(InputFrame.Action.DIG, true)
		player.drive(frame)


func _snap(path: String) -> void:
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(path)
