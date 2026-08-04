extends SceneTree
## Visual M5 smoke test. Builds an enemy tunnel one layer below a surface Sneak, fires sonar,
## and photographs both the temporary echo and the persistent cant mark.
##
##   godot --path . --resolution 1100x760 --script tools/sonar_probe.gd
##
## Needs a real renderer. Writes sonar_echo.png and sonar_mark.png to /tmp.


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	(scene.get_node("Tunnels") as TunnelNetwork).rock_density = 0.0
	var boulders := scene.get_node_or_null("Surface/Boulders")
	if boulders != null:
		boulders.free()
	root.add_child(scene)
	await process_frame
	await process_frame

	var network := scene.get_node("Tunnels") as TunnelNetwork
	var player := scene.get_node("Player") as Mouse
	# ON THE MOUSE, NOT ON THE ARENA (M7): every driven mouse carries its own controls.
	var sonar := player.get_node("Sonar") as Sonar
	player.set_class(MouseClass.SNEAK)
	player.global_position = network.cell_to_world(0, Vector2i(2, 2)) + Vector3.UP * 0.2
	player.velocity = Vector3.ZERO
	for x in range(-3, 4):
		network.dig(1, Vector2i(x, 0), Team.RED)
	for z in range(1, 4):
		network.dig(1, Vector2i(-3, z), Team.RED)

	sonar.scan()
	for i in range(20):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/sonar_echo.png")

	await create_timer(2.1).timeout
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/sonar_mark.png")
	print("wrote /tmp/sonar_echo.png and /tmp/sonar_mark.png")
	quit()
