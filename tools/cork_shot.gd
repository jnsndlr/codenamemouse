extends SceneTree
## Photographs what a body radius actually looks like: the four classes side by side on the lawn,
## and a Brute plugging a corridor with a crew mate stopped behind it.
##
## THE SIZE IS THE ONE PART OF CORKING THAT ARITHMETIC CANNOT SETTLE. Whether 0.30 seals a 1.0m
## corridor is measurable and measured -- `match_audit`'s `cork` check drives a mouse at one and
## watches it fail to get through. Whether a Brute at 0.30 reads as *the big one who says not
## through here* or as a bug in the model scale is a question for eyes, and it is a number in
## `brute.tres` that anybody can move once they have seen it.
##
## THE SECOND SHOT IS THE ONE THAT MATTERS, and it is a shot of an ALLY being stopped. Enemies
## being solid was never in doubt; what M8 changed is that your own crew is solid too, which is
## what makes a cork a cork rather than a door with an invisible key. A picture of a blue mouse
## nose-to-nose with a blue Brute is the whole rule in one frame.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/cork_shot.gd

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	(scene.get_node("Tunnels") as TunnelNetwork).rock_density = 0.0
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var network := scene.get_node("Tunnels") as TunnelNetwork
	var player := scene.get_node("Player") as Mouse
	var rig: Node3D = scene.get_node("CameraRig")
	rig.set("zoom_idle", 5.0)
	rig.set("speed_zoom", false)

	await _line_up(scene, player)
	await _corked(scene, network, player)

	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()


## All four, in a row, on open lawn. The order is the swap bar's own: Generalist, Engineer,
## Sneak, Brute -- so the picture reads left to right as the class list does.
func _line_up(scene: Node, player: Mouse) -> void:
	var spot := Vector3(6.0, 0.2, 6.0)
	player.global_position = spot + Vector3(0.0, 0.0, -1.4)
	player.velocity = Vector3.ZERO
	player.set_class(MouseClass.GENERALIST)

	var kinds: Array[int] = [
		MouseClass.GENERALIST, MouseClass.ENGINEER, MouseClass.SNEAK, MouseClass.BRUTE
	]
	for index in range(kinds.size()):
		var mouse := _mouse(scene, Team.BLUE, spot + Vector3(float(index) * 1.1 - 1.65, 0.0, 0.6))
		mouse.set_class(kinds[index])
		print("%-10s radius %.2f, height x%.2f" % [
			MouseClass.name_of(kinds[index]), mouse.body_radius, mouse.height_ratio()
		])

	await create_timer(1.6).timeout
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(OUT + "cork_classes.png")


## The cork itself, from underground: a Brute across a one-cell corridor and a team mate walking
## into its back.
func _corked(scene: Node, network: TunnelNetwork, player: Mouse) -> void:
	var row := -17
	network.dig_shaft_down(0, Vector2i(-17, row))
	for x in range(-17, -9):
		network.dig(1, Vector2i(x, row), player.team)
	await process_frame

	# The player IS the Brute, so the camera is underground and looking at the plug -- the depth
	# focus hides every layer but the viewer's, so a shot taken from the lawn would photograph
	# grass over the top of the whole thing.
	player.set_physics_process(false)
	player.set_class(MouseClass.BRUTE)
	player.global_position = network.cell_to_world(1, Vector2i(-13, row)) + Vector3.UP * 0.05
	player.set_plane(1)
	player.velocity = Vector3.ZERO
	await create_timer(1.6).timeout

	var mate := _mouse(
		scene, Team.BLUE, network.cell_to_world(1, Vector2i(-16, row)) + Vector3(0.0, 0.05, 0.18)
	)
	mate.set_plane(1)
	mate.set_class(MouseClass.GENERALIST)
	mate.set_physics_process(false)

	# Driven on the body: `_wish` is cleared every tick by a controller a bare fixture has not got.
	for i in range(110):
		mate.set_physics_process(false)
		mate.velocity = Vector3(2.4, 0.0, 0.0)
		mate.move_and_slide()
		player.global_position = (
			network.cell_to_world(1, Vector2i(-13, row)) + Vector3.UP * 0.05
		)
		await process_frame

	var gap := player.global_position.x - mate.global_position.x
	print("corked: the crew mate stopped %.2fm short of its own Brute (negative means it got past)"
		% gap)
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(OUT + "cork_corridor.png")


func _mouse(scene: Node, side: int, at: Vector3) -> Mouse:
	var mouse := (load("res://scenes/actors/bot.tscn") as PackedScene).instantiate() as Mouse
	mouse.name = "Shown%d" % (randi() % 100000)
	mouse.team = side
	mouse.position = at
	scene.add_child(mouse)
	# FROZEN THE MOMENT IT EXISTS. `bot.tscn` is used because it is the only thing in the project
	# that carries the mouse model -- and it also carries the AI, so an unfrozen one walks out of
	# frame toward the enemy nest before the shutter opens. The first run of this photographed an
	# empty patch of lawn and a roster full of names.
	mouse.set_physics_process(false)
	return mouse
