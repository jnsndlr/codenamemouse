extends SceneTree
## Photographs a Brute's stomp frame by frame, so the dust ([StompDust]) can be looked at rather
## than described -- and so the one rule the effect exists to obey can be checked by eye instead of
## taken on trust.
##
## THE RULE IS THAT IT MUST NOT SAY WHETHER IT WORKED. A stomp over a tunnel and a stomp over bare
## earth have to be indistinguishable on the surface, or a Brute can read the enemy's network off
## its own dust ([CaveIn] has the long version). That is exactly the kind of claim that stays true
## right up until somebody adds a nice touch, and it is invisible in an audit -- so this takes both
## shots, over a corridor and over nothing, at the same moment in the same place. Put them side by
## side; if you can tell which is which, the feature is broken.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --path . --resolution 1100x760 --script tools/stomp_shot.gd
##
## Writes stomp_over_tunnel_*.png and stomp_over_nothing_*.png to /tmp.

## Frames after the press, so the burst is caught leaving rather than after it has hung.
const AT_FRAMES: Array[int] = [3, 10, 22]


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	(scene.get_node("Tunnels") as TunnelNetwork).rock_density = 0.0
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var network := scene.get_node("Tunnels") as TunnelNetwork
	var player := scene.get_node("Player") as Mouse
	var cave := player.get_node("CaveIn") as CaveIn
	var rig: Node3D = scene.get_node("CameraRig")
	rig.set("zoom_idle", 5.5)
	rig.set("speed_zoom", false)
	player.set_class(MouseClass.BRUTE)

	# A corridor under the first spot and nothing at all under the second. Far enough apart that
	# neither stomp can reach the other's ground, and CLOSE ENOUGH THAT THE YARD LOOKS THE SAME --
	# the two shots are meant to be held side by side, so anything that differs between them other
	# than the ground underneath is a reason to think you can tell them apart. The first version of
	# this put the bare stomp at (22, 22), which is inside the red nest: one shot on plain grass and
	# one on a red disc surrounded by red mice, which compares nothing.
	var over_tunnel := Vector2i(2, 2)
	var over_nothing := Vector2i(12, 2)
	for x in range(0, 5):
		network.dig(1, Vector2i(x, 2), Team.RED)
	network.dig(2, over_tunnel, Team.RED)

	await _stomp_at(player, cave, network, over_tunnel, "stomp_over_tunnel")
	await _stomp_at(player, cave, network, over_nothing, "stomp_over_nothing")
	await _tremor(player, cave, network)

	print(
		"wrote /tmp/stomp_over_tunnel_*.png, /tmp/stomp_over_nothing_*.png"
		+ " and /tmp/tremor_*.png"
	)
	quit()


## The near miss, from underneath: a cave-in at arm's length, and the ceiling shedding over the
## corridor around it. The one part of the effect a player is meant to read as a *warning*, so it
## has to be legible from inside the tunnel rather than merely present in the scene graph.
func _tremor(player: Mouse, cave: CaveIn, network: TunnelNetwork) -> void:
	# A run of corridor with the mouse in the middle of it, so the dust has ceiling either side to
	# fall from -- a single cell would photograph one cell's worth and prove nothing about reach.
	#
	# WELL CLEAR OF THE PATIO. The first version of this dug at (-6, -6), which is under the paving:
	# the shaft was refused, the HUD filled up with "no digging through the patio", and the shot
	# came back with a no-surface warning across the middle of it. A probe photographing an
	# unrelated refusal is a probe you stop believing.
	var spine := Vector2i(-17, -17)
	network.dig_shaft_down(0, spine)
	for x in range(-17, -8):
		network.dig(1, Vector2i(x, -17), player.team)
	for x in range(-17, -8):
		network.dig(1, Vector2i(x, -16), player.team)
	await process_frame

	player.set_physics_process(true)
	player.global_position = network.cell_to_world(1, Vector2i(-13, -17)) + Vector3.UP * 0.05
	player.set_plane(1)
	player.velocity = Vector3.ZERO
	await create_timer(1.4).timeout
	player.set_physics_process(false)
	cave.set("_cooldown_left", 0.0)

	var target := Vector2i(-12, -17)
	var frame := InputFrame.new()
	frame.aim_point = network.cell_to_world(1, target)
	frame.set_pressed(InputFrame.Action.ABILITY, true)
	frame.set_held(InputFrame.Action.ABILITY, true)
	player.call("drive", frame)
	cave._physics_process(0.0)
	# Said out loud, because "the dust is in the picture" and "the collapse happened" are two
	# different claims and only one of them is visible in a screenshot of a corridor.
	print("tremor: cell %s came down: %s" % [target, not network.is_dug(1, target)])

	for step in range(AT_FRAMES.max() + 1):
		await process_frame
		if AT_FRAMES.has(step):
			RenderingServer.force_draw()
			root.get_texture().get_image().save_png("/tmp/tremor_%02d.png" % step)


func _stomp_at(
	player: Mouse, cave: CaveIn, network: TunnelNetwork, cell: Vector2i, tag: String
) -> void:
	player.global_position = network.cell_to_world(0, cell) + Vector3.UP * 0.2
	player.velocity = Vector3.ZERO
	player.set_plane(0)
	# Let the rig ease onto the mouse it was just teleported away from, or the burst is
	# photographed somewhere off to one side of the frame.
	await create_timer(1.4).timeout
	# The player recomputes its aim from the real cursor every physics frame, so it has to come
	# off physics before an intent is driven into it -- the same reason the audits do.
	player.set_physics_process(false)
	cave.set("_cooldown_left", 0.0)

	var frame := InputFrame.new()
	frame.aim_point = player.global_position
	frame.set_pressed(InputFrame.Action.ABILITY, true)
	frame.set_held(InputFrame.Action.ABILITY, true)
	player.call("drive", frame)
	cave._physics_process(0.0)

	var taken := 0
	for step in range(AT_FRAMES.max() + 1):
		await process_frame
		if AT_FRAMES.has(step):
			RenderingServer.force_draw()
			root.get_texture().get_image().save_png("/tmp/%s_%02d.png" % [tag, step])
			taken += 1
	player.set_physics_process(true)
