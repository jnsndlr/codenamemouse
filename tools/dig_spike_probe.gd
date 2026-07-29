extends SceneTree
## M2 verification harness. Builds a three-plane network, then photographs it from the
## game camera at each focus depth so the legibility question can be looked at rather than
## argued about.
##
##   godot --path . --resolution 1100x760 --script tools/dig_spike_probe.gd
##
## Writes PNGs to user:// (on macOS, ~/Library/Application Support/Godot/app_userdata/).
## Also asserts the thing that silently broke once already: that every plane's floor
## actually exists in the physics world, rather than only in the render.

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/tunnels/dig_spike.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	var network: TunnelNetwork = scene.get_node("Tunnels")
	var player: Node3D = scene.get_node("Player")

	# Entrance at the origin heading +Z, which digs the plane-1 landing for us.
	network.dig_ramp(0, Vector2i(0, -2), Vector2i(0, 1))

	# Plane 1: an L running east then north.
	for z in range(0, 6):
		network.dig(1, Vector2i(0, z))
	for x in range(1, 8):
		network.dig(1, Vector2i(x, 5))
	for z in range(4, -3, -1):
		network.dig(1, Vector2i(7, z))

	# Down to plane 2 at the far end, then a corridor running back underneath plane 1.
	network.dig_ramp(1, Vector2i(7, -3), Vector2i(0, -1))
	for x in range(7, -4, -1):
		network.dig(2, Vector2i(x, -5))
	for z in range(-4, 4):
		network.dig(2, Vector2i(-3, z))

	# Down to plane 3 and a small chamber.
	network.dig_ramp(2, Vector2i(-3, 4), Vector2i(0, 1))
	for x in range(-5, 0):
		for z in range(5, 9):
			network.dig(3, Vector2i(x, z))

	var counts := []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		counts.append(network.cell_count(plane))
	print("cells per plane 1/2/3: ", counts)

	# Photograph from the game camera, parking the player over each plane in turn so the
	# focus logic runs exactly as it would in play.
	# Does the physics world actually have a floor where the mesh says there is one?
	var space := scene.get_viewport().world_3d.direct_space_state
	var probe := PhysicsRayQueryParameters3D.create(
		Vector3(0.0, network.plane_y(1) + 1.0, 2.0),
		Vector3(0.0, network.plane_y(1) - 1.0, 2.0)
	)
	var hit := space.intersect_ray(probe)
	if hit.is_empty():
		push_error("plane 1 floor has no collision -- the player will fall through it")
	print("floor collision at (0,2): ", hit.get("position", "MISSING"))

	var shots := [
		["surface", Vector3(4.0, 0.4, -2.0)],
		["plane1", Vector3(0.0, network.plane_y(1) + 0.2, 2.0)],
		["plane2", Vector3(-3.0, network.plane_y(2) + 0.2, -5.0)],
		["plane3", Vector3(-3.0, network.plane_y(3) + 0.2, 6.0)],
	]
	for shot: Array in shots:
		player.global_position = shot[1]
		player.velocity = Vector3.ZERO
		for i in range(45):
			await process_frame
		RenderingServer.force_draw()
		var image: Image = root.get_texture().get_image()
		image.save_png(OUT + "dig_" + shot[0] + ".png")
		print("wrote %s: spawned y=%.2f landed y=%.2f on_floor=%s focus=%d" % [
			shot[0], (shot[1] as Vector3).y, player.global_position.y,
			player.is_on_floor(), network.get_focus_plane()])

	# Pull the camera right back so the whole three-plane network is in one frame. This is
	# the shot that answers "can you understand its shape", rather than "can you see the
	# bit you're standing in".
	var rig: Node3D = scene.get_node("CameraRig")
	rig.zoom_idle = 30.0
	rig.zoom_run = 30.0
	rig.zoom_sprint = 30.0
	for overview: Array in [["over1", 1, Vector3(0, 0, 2)], ["over2", 2, Vector3(-3, 0, 0)]] as Array[Array]:
		var spot: Vector3 = overview[2]
		player.global_position = Vector3(spot.x, network.plane_y(overview[1]) + 0.2, spot.z)
		for i in range(70):
			await process_frame
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png(OUT + "dig_" + overview[0] + ".png")
		print("wrote ", overview[0], " focus=", network.get_focus_plane())

	quit()
