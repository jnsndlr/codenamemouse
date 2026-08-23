extends SceneTree
## Visual regression for the stone that breaks a plane's dirt. (GDD section 3)
##
##   godot --path . --resolution 1400x900 --script tools/rock_surface_shot.gd
##
## Needs a real renderer. Writes /tmp/rock_surface.png and /tmp/rock_lawn.png.
##
## `[REPLACES rock_top_probe.gd]`, which photographed the cap sheet -- a flat plate of whole metre
## squares drawn over the cells a crew had learned held rock. There is no such sheet any more and no
## such knowledge: a rock either stands out of the dirt where anybody can see it or it is buried.
## So the two shots are the two things worth looking at, and between them they catch the failures a
## headless check cannot.
##
##   UNDERGROUND  A corridor driven at a big lump. The lid must be plain dirt all the way to the
##                trench, the wall must WRAP the stone in its own colour, and the part of the rock
##                standing above the dirt must line up with the face below it. Two descriptions of
##                one rock disagreeing is exactly what this is here to catch.
##
##   FROM THE LAWN  Plane 1's tall rocks coming through the grass. These have to read as different
##                objects from the angular scatter props lying about, or the surface stops telling
##                you anything about the earth.

func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	var network := scene.get_node("Tunnels") as TunnelNetwork
	root.add_child(scene)
	await process_frame
	await process_frame

	var thickness := TunnelNetwork.SPACING
	var tallest: RockBody = null
	var up := 0
	for entry: Variant in network.rock_bodies(1):
		var rock := entry as RockBody
		if not rock.breaks_surface(thickness):
			continue
		up += 1
		if tallest == null or rock.rise_above(thickness) > tallest.rise_above(thickness):
			tallest = rock
	if tallest == null:
		print("no rock on plane 1 breaks the surface -- nothing to photograph")
		quit(1)
		return
	print("plane 1: %d rocks break the dirt; tallest stands %.2fm proud (%s)" % [
		up, tallest.rise_above(thickness), "breakable" if tallest.breakable else "bedrock"
	])

	var player := scene.get_node("Player") as Mouse
	player.global_position = Vector3(tallest.centre.x - 3.0, 0.2, tallest.centre.y + 3.0)
	player.velocity = Vector3.ZERO
	for i in range(60):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/rock_lawn.png")

	# And the same rock from underneath, with a corridor run at it.
	var start := tallest.centre + Vector2(-6.0, 0.8)
	for i in range(10):
		var id := TunnelNetwork.segment_id(start, 0)
		if not network.dig_segment(1, start, 0, Team.BLUE):
			break
		start = TunnelNetwork.segment_end(id)
	player.global_position = Vector3(
		tallest.centre.x - 2.0, network.plane_y(1) + 0.2, tallest.centre.y + 0.8
	)
	player.set_plane(1)
	player.velocity = Vector3.ZERO
	for i in range(60):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("/tmp/rock_surface.png")
	print("wrote /tmp/rock_lawn.png and /tmp/rock_surface.png")
	quit()
