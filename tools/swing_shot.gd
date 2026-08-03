extends SceneTree
## Photographs a swing frame by frame so the swipe (swing_arc.gd) can be looked at rather than
## described, and so the thing it promises -- "this is the cone that will hit you" -- can be
## checked against a mouse standing just inside and just outside it.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/swing_shot.gd

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var player := scene.get_node("Player") as Mouse
	# Closer than the match ever gets. Set on the RIG, not the camera -- the rig drives
	# `Camera3D.size` off the player's speed every tick and would overwrite it within a frame.
	var rig: Node3D = scene.get_node("CameraRig")
	rig.set("zoom_idle", 4.5)
	rig.set("speed_zoom", false)

	# Somewhere flat and empty, facing +X, with two targets: one inside the reach and one a
	# whisker outside it. The swipe should sweep through the first and stop short of the second.
	var spot := Vector3(0.0, 0.0, 0.0)
	var facing := Vector3(1.0, 0.0, 0.0)
	player.revive_at(spot, atan2(-facing.x, -facing.z))
	for i in range(30):
		await process_frame
	# The player turns toward the cursor every tick and there is no cursor here, so freeze the
	# controller. The swipe runs on its own `_process` clock and draws regardless.
	player.set_physics_process(false)
	player.revive_at(spot, atan2(-facing.x, -facing.z))

	var marks: Array[Vector3] = [
		spot + facing * (player.attack_reach - 0.15),
		spot + facing * (player.attack_reach + 0.65),
	]
	for place in marks:
		var pip := MeshInstance3D.new()
		var ball := SphereMesh.new()
		ball.radius = 0.08
		ball.height = 0.16
		pip.mesh = ball
		scene.add_child(pip)
		pip.global_position = place + Vector3.UP * 0.2

	# The swipe lasts a quarter of a second and saving a PNG per frame costs more than that, so
	# slow the clock rather than the effect: the same curve, sampled often enough to look at.
	Engine.time_scale = 0.2
	player.swing()
	for frame in range(20):
		await process_frame
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png(OUT + "swing_%02d.png" % frame)

	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()
