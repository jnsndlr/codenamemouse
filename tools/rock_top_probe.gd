extends SceneTree
## Visual regression for revealed rock. Builds a straight seam beside a corridor and photographs
## it from plane 1; both the vertical face and the horizontal cube tops must read as pale stone.
##
##   godot --path . --resolution 1100x760 --script tools/rock_top_probe.gd
##
## Needs a real renderer. Writes /tmp/rock_top.png.


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	var network := scene.get_node("Tunnels") as TunnelNetwork
	network.rock_density = 0.0
	var boulders := scene.get_node_or_null("Surface/Boulders")
	if boulders != null:
		boulders.free()
	root.add_child(scene)
	await process_frame
	await process_frame

	var player := scene.get_node("Player") as Mouse
	for x in range(-4, 5):
		network.add_rock(1, Vector2i(x, 0))
		network.dig(1, Vector2i(x, 1), Team.BLUE)
	for z in range(2, 6):
		network.dig(1, Vector2i(4, z), Team.BLUE)

	# A STROKE CUT AT AN ANGLE INTO THE SEAM'S EDGE, which is the case the cap sheet used to get
	# wrong. Digging is off-grid and rock is not: a capsule's rounded end reaches into a rock cell
	# without making any of it walkable, so the dig is allowed and the cell stays rock -- and a cap
	# built out of whole squares then hung its corner over the open trench. The sheet's edge here
	# must follow the corridor's curve, not the cell's corner.
	network.dig_segment(1, Vector2(-2.4, 1.4), 5, Team.BLUE)
	network.dig_segment(1, Vector2(-0.4, 1.4), 59, Team.BLUE)

	network.reveal_vein(1, Vector2i(0, 0), Team.BLUE)

	player.global_position = network.standing_point(1, Vector2i(-1, 1)) + Vector3.UP * 0.2
	player.set_plane(1)
	player.velocity = Vector3.ZERO
	for i in range(45):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/rock_top.png")
	print("wrote /tmp/rock_top.png")
	quit()
