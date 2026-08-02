extends SceneTree
## Photographs the lawn so the grass can be looked at rather than argued about.
##
## Shots: the patio edge (paving should be bare, grass should crowd right up to it) and a mouse
## standing in cover with the bend running, which is where a blade that stretches instead of
## bending gives itself away.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/grass_shot.gd

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var player: Node3D = scene.get_node("Player")
	var rig: Node3D = scene.get_node("CameraRig")
	var camera := rig.find_child("*Camera*", true, false) as Camera3D

	for shot: Array in [
		# Straddling the patio's north edge, so bare slab and dense lawn are in the same frame.
		["patio_edge", Vector3(0.0, 0.0, -2.0), 16.0],
		["patio_corner", Vector3(-10.0, 0.0, -12.0), 16.0],
		# Deep lawn, close in, where a single blade is several pixels tall.
		["lawn_close", Vector3(14.0, 0.0, 6.0), 6.0],
		["lawn_wide", Vector3(14.0, 0.0, 6.0), 22.0],
	]:
		player.global_position = shot[1]
		if camera != null:
			camera.size = shot[2]
		# Several frames: the rig eases toward the player and the grass shader needs a TIME step
		# for the wind to be anywhere but its starting phase.
		for i in range(30):
			await process_frame
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png(OUT + "grass_" + shot[0] + ".png")
		print("shot: %s" % shot[0])

	await _bend_shots(scene, player, camera)

	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()


## The same patch of grass with the bend off and then hard on, from a fixed camera.
##
## The influences are written by hand, because the tell is driven by MEASURED speed and there is
## no way to make a parked mouse sprint. Taking the patch's `_process` off first is what makes
## that stick -- it rewrites the uniform from the live actor list every frame otherwise.
func _bend_shots(scene: Node, player: Node3D, camera: Camera3D) -> void:
	var grass: GrassPatch = scene.get_node("Surface/Grass")
	var stand := Vector3(14.0, 0.0, 6.0)
	player.global_position = stand + Vector3(0.0, 0.0, 6.0)
	if camera != null:
		camera.size = 4.0
	for i in range(30):
		await process_frame

	grass.set_process(false)
	var material: ShaderMaterial = grass.get_material()
	var slots := PackedVector4Array()
	slots.resize(48)

	for shot: Array in [["bend_off", 0.0], ["bend_full", 1.0]]:
		slots[0] = Vector4(stand.x, 0.0, stand.z, shot[1])
		material.set_shader_parameter("influences", slots)
		material.set_shader_parameter("influence_count", 1)
		await process_frame
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png(OUT + "grass_" + shot[0] + ".png")
		print("shot: %s" % shot[0])
