extends SceneTree
## A stroke caught part-way through being cut.
##
##   godot --path . --resolution 1100x760 --script tools/carve_shot.gd
##
## Needs a real renderer. Writes /tmp/carve_quarter.png, /tmp/carve_half.png and
## /tmp/carve_done.png.
##
## THE ONE THING A HEADLESS CHECK CANNOT ANSWER. carve_probe.gd proves the earth comes out as far as
## it has been cut and that nothing else moved with it; it says nothing about whether the trench
## READS as a trench at forty centimetres. The failure worth photographing is a corridor that grows
## as a floor with no sides, or one whose end face pops in and out as the tip crosses a texel --
## either of which would be worse than the tiles it replaced.
##
## What to look for: three frames of one stroke, all from the same camera. The corridor should reach
## further in each, its walls should close round its end in all three, and the earth ahead of the
## tip should be flat undisturbed ground rather than a stub of wall standing in the open.

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

	# A short run of finished corridor to stand in, then one more stroke cut slowly out of its end.
	var at := Vector2(-6.0, 8.0)
	var north := TunnelNetwork.ANGLE_STEPS / 4
	for i in range(4):
		if not network.dig_segment(PLANE, at, north, Team.BLUE):
			break
		at = TunnelNetwork.segment_end(TunnelNetwork.segment_id(at, north))

	var stand := Vector2(-6.0, at.y - 1.5)
	var id := TunnelNetwork.segment_id(at, north)

	for shot: Array in [[0.25, "quarter"], [0.55, "half"], [1.0, "done"]]:
		if (shot[0] as float) >= 1.0:
			network.dig_segment(PLANE, at, north, Team.BLUE)
		else:
			network.carve(PLANE, id, shot[0] as float, Team.BLUE)
		await _shoot(player, network, stand, "/tmp/carve_%s.png" % shot[1])

	print("")
	print("wrote /tmp/carve_quarter.png, /tmp/carve_half.png and /tmp/carve_done.png")
	print("one stroke, three moments. The trench should have sides at every one of them.")
	quit()


## PHYSICS frames, and enough of them: camera_rig.gd follows on the physics tick with an
## exponential lerp, so a teleported player is chased rather than jumped to.
func _shoot(player: Mouse, network: TunnelNetwork, at: Vector2, path: String) -> void:
	player.global_position = Vector3(at.x, network.plane_y(PLANE) + 0.1, at.y)
	player.velocity = Vector3.ZERO
	player.set_plane(PLANE)
	for i in range(60):
		await physics_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(path)
