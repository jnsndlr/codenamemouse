extends SceneTree
## Visual M5 regression: does the GROUND keep the same secret the minimap does?
##
##   godot --path . --resolution 1100x760 --script tools/cutaway_probe.gd
##
## Needs a real renderer. Writes /tmp/cutaway_blue.png and /tmp/cutaway_red.png.
##
## Two photographs of one piece of earth, from the same camera, differing only in which crew is
## looking. Blue stands in a blue corridor with a red corridor running parallel three cells north.
## **In cutaway_blue.png that strip must be unbroken earth. In cutaway_red.png it must be an open
## trench.** Same geometry, same frame, same everything else.
##
## WHY A PICTURE AS WELL AS AN ASSERTION. match_audit.gd checks this against `is_cut_away`, which
## reads the mask texture itself -- the right thing to assert, and one step short of the truth. The
## lid is discarded in a shader that samples that mask with its own idea of where a cell is, and
## earth_cutaway.gdshader says so out loud: "Matches TunnelNetwork.world_to_cell exactly ... If
## these two ever disagree the holes land half a cell off the tunnels they belong to." A mask that
## is perfectly correct and sampled half a cell out passes every headless check in the project and
## still shows you the enemy's corridor. Only a photograph closes that gap.
##
## The bug this exists to stop shipping twice: the mask was built from every dug cell, so standing
## in your own tunnel cut the whole enemy network out of the earth in front of you, complete,
## before you had been anywhere near it -- while the minimap beside it kept the secret perfectly.


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	var network := scene.get_node("Tunnels") as TunnelNetwork
	# Nothing generated in the way. This is a photograph of ONE rule, and a seeded seam or a
	# boulder across the strip would make the picture ambiguous in exactly the place it has to be
	# read -- is that earth because the rule works, or because it was never diggable?
	network.rock_density = 0.0
	var boulders := scene.get_node_or_null("Surface/Boulders")
	if boulders != null:
		boulders.free()
	# The bots would dig their own corridors through the shot.
	(scene.get_node("MatchDirector") as MatchDirector).crew_size = 1
	root.add_child(scene)
	await process_frame
	await process_frame

	var player := scene.get_node("Player") as Mouse

	# Two parallel corridors three cells apart: near enough to be in frame together, far enough
	# that they are plainly two separate things rather than one wide trench.
	for x in range(-7, 8):
		network.dig(1, Vector2i(x, 0), Team.BLUE)
		network.dig(1, Vector2i(x, 3), Team.RED)

	# EACH CREW STANDS IN ITS OWN. Photographing both crews from the same spot looks tidier and
	# asks a muddier question: the second viewer is then standing INSIDE the enemy corridor, which
	# grants it line of sight down that corridor and is supposed to cut the earth away. The picture
	# comes back with two trenches, correctly, and proves nothing about the rule under test.
	await _shoot(player, network, Team.BLUE, Vector2i(0, 0), "/tmp/cutaway_blue.png")
	await _shoot(player, network, Team.RED, Vector2i(0, 3), "/tmp/cutaway_red.png")

	print("")
	print("wrote /tmp/cutaway_blue.png and /tmp/cutaway_red.png")
	print("each shot: the viewer stands in its OWN corridor, the other crew's runs 3 cells away.")
	print("   exactly ONE open trench, and it is lit      -- the crew's own")
	print("   unbroken earth where the other corridor is  -- theirs")
	print("two trenches in either shot is the M5 leak this file exists to catch.")
	quit()


## One crew's view of the same ground. The team is set on the MOUSE rather than on the network,
## because depth_focus.gd is what tells the network who is looking -- driving it directly here
## would photograph a path the game never takes.
##
## PHYSICS frames, not process frames, and enough of them to matter. camera_rig.gd follows on the
## physics tick with an exponential lerp, so a teleported player is chased rather than jumped to --
## photograph it too early and you get a beautifully correct picture of a patch of lawn forty
## metres from the thing you were testing, which is exactly what the first run produced.
func _shoot(player: Mouse, network: TunnelNetwork, side: int, at: Vector2i, path: String) -> void:
	player.set_team(side)
	player.global_position = network.cell_to_world(1, at) + Vector3.UP * 0.1
	player.velocity = Vector3.ZERO
	player.set_plane(1)
	for i in range(90):
		await physics_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(path)
