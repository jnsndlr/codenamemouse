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
	network.reveal_vein(1, Vector2i(0, 0), Team.BLUE)

	player.global_position = network.cell_to_world(1, Vector2i(4, 4)) + Vector3.UP * 0.2
	player.set_plane(1)
	player.velocity = Vector3.ZERO
	for i in range(45):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/rock_top.png")
	print("wrote /tmp/rock_top.png")
	quit()
