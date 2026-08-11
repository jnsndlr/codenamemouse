extends SceneTree
## Photographs the player's own bars at full health, so "always visible" can be looked at rather
## than asserted. Two frames: untouched and at rest, then mid-sprint with stamina part spent.
##
## THE FIRST FRAME IS THE ONE THAT MATTERS. A stamina bar that hid itself while full only ever
## appeared once you were already spending it, so the shot that proves the fix is the boring one
## -- a mouse standing still, unhurt, with a full bar under its chin and no health bar above it.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/vitals_shot.gd

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var player := scene.get_node("Player") as Mouse
	# Close enough to read four pixels of bar. Set on the RIG: it drives `Camera3D.size` off the
	# player's speed every tick and would overwrite the camera within a frame.
	var rig: Node3D = scene.get_node("CameraRig")
	rig.set("zoom_idle", 4.5)
	rig.set("speed_zoom", false)

	player.revive_at(Vector3.ZERO, 0.0)
	for i in range(30):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(OUT + "vitals_full.png")
	print("full: health %.2f, stamina %.2f" % [
		player.get_health_ratio(), player.get_stamina_ratio()
	])

	# Now spend some of it, which is the only state the bar used to have.
	#
	# DRIVEN AS A REMOTE SEAT rather than by calling `request_sprint` directly, because the tank is
	# `Mouse`'s and only the keyboard reading is `Player`'s -- setting the flag by hand tests a rung
	# of the ladder nobody climbs. `set_remote` is the supported way in: without it `Player.input()`
	# recaptures this machine's keyboard on the first ask of every tick and drops the frame handed
	# to it, so the sprint ends the same tick it started and the bar never moves.
	player.set_remote(true)
	for i in range(420):
		var frame := InputFrame.new()
		frame.move = Vector2(0.0, 1.0)
		frame.set_held(InputFrame.Action.SPRINT, true)
		frame.set_pressed(InputFrame.Action.SPRINT, i == 0)
		player.drive(frame)
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(OUT + "vitals_sprinting.png")
	print("sprinting: health %.2f, stamina %.2f" % [
		player.get_health_ratio(), player.get_stamina_ratio()
	])

	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()
