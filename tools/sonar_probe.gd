extends SceneTree
## Visual M5 smoke test. Builds an enemy tunnel one layer below a surface Sneak, fires sonar,
## and photographs both the temporary echo and the persistent cant mark.
##
##   godot --path . --resolution 1100x760 --script tools/sonar_probe.gd
##
## Needs a real renderer. Writes sonar_echo.png, sonar_wave.png and sonar_mark.png to /tmp.
##
## IT WAITS FOR THE CAMERA BEFORE IT FIRES, and that is not a nicety. The rig eases toward its
## target over about a second (`follow_speed`), so a probe that scans on the frame after it
## teleports the player photographs the yard the camera was flying over -- which is what the echo
## shot was for a long time, and it was impossible to tell from a picture that plainly contained
## grass, rocks and HUD. A screenshot probe whose subject is off screen is the same failure as an
## audit check that cannot fail, and it hides just as well.


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
	# TWO CREWS' CORRIDORS UNDER ONE SCAN, which is the whole thing this probe now exists to
	# photograph. The echo colours each answering cell by whose tunnel it is, and a picture
	# containing only one crew cannot tell a working colour rule from a hardcoded tint -- the same
	# reason the audits insist a filter be shown a case it should let through.
	for x in range(-3, 4):
		network.dig(1, Vector2i(x, 0), Team.RED)
	for z in range(1, 4):
		network.dig(1, Vector2i(-3, z), Team.RED)
	# The Sneak's own crew, running the other way from under its feet.
	for z in range(2, 6):
		network.dig(1, Vector2i(3, z), Team.BLUE)

	# Let the rig catch up with the mouse it was just teleported away from. See the header.
	await create_timer(1.4).timeout

	sonar.scan()
	# THE WAVE FIRST, because it is over in about half a second and the echo outlives it -- one
	# shot taken late enough to show the outlines would never contain the pulse at all.
	for i in range(6):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/sonar_wave.png")

	for i in range(20):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/sonar_echo.png")

	await create_timer(2.1).timeout
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/sonar_mark.png")

	# AND THEN THE OTHER GLYPH. The mark always lands on the NEAREST answer, so one scan can only
	# ever photograph one of the two -- and the pair is the whole point: a rune over your own
	# corridor, a reticle over theirs. Walking the Sneak over to the red branch and sounding again
	# is what makes this probe show the distinction rather than merely one side of it.
	sonar.set("_cooldown_left", 0.0)
	player.global_position = network.cell_to_world(0, Vector2i(0, 1)) + Vector3.UP * 0.2
	player.velocity = Vector3.ZERO
	await create_timer(1.4).timeout
	sonar.scan()
	await create_timer(2.1).timeout
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/sonar_target.png")

	print(
		"wrote /tmp/sonar_wave.png, /tmp/sonar_echo.png, /tmp/sonar_mark.png"
		+ " and /tmp/sonar_target.png"
	)
	quit()
