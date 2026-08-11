extends SceneTree
## Photographs the two things this pass added that can only be judged by looking: an Engineer's
## timbers standing in a corridor, and the carried-cheese counter under your own bars.
##
## THE AUDITS PROVE THE RULES AND CANNOT PROVE THE PICTURE. `tunnel_audit` knows a shored cell
## absorbs exactly one collapse; nothing in it knows whether the timbers read as *holding a roof up*
## or as *a barricade you cannot walk through*, which is the one confusion this prop must never
## cause -- the Engineer now has two abilities that put an object in a corridor and only one of them
## is a wall. Same for the wedge counter: an audit can say a Brute is carrying five, and only a
## screenshot can say whether five wedges and a stow clock are legible under a health bar.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/shore_shot.gd

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var network := scene.get_node("Tunnels") as TunnelNetwork
	var player := scene.get_node("Player") as Mouse
	var rig: Node3D = scene.get_node("CameraRig")
	rig.set("zoom_idle", 5.5)
	rig.set("speed_zoom", false)

	# A straight corridor with a way in, so the shot has walls and a lamp in it rather than the
	# timbers floating in a void.
	var start := Vector2i(-14, -14)
	network.dig_shaft_down(0, start)
	for x in range(-14, -7):
		network.dig(1, Vector2i(x, -14))
	for i in range(20):
		await process_frame

	var stood := Vector2i(-11, -14)
	player.set_class(MouseClass.ENGINEER)
	player.global_position = network.cell_to_world(1, stood) + Vector3.UP * 0.05
	player.set_plane(1)
	network.set_focus_plane(1)
	for i in range(20):
		await process_frame

	# HOW MUCH A MOUSE STANDING STILL ACTUALLY DRIFTS, printed rather than assumed. `ShoreUp.drift`
	# cancels a cast at 22cm, and the whole ability is worthless if ordinary settling against a wall
	# spends that on its own. This is the number that says whether the tolerance is right, and it is
	# measured with physics LIVE -- the audits switch it off, which is exactly what would hide this.
	var settled := player.global_position
	for i in range(180):
		await process_frame
	print("drift while standing still for 3s: %.3fm" % player.global_position.distance_to(settled))

	# ---- mid-cast, which is the frame that says whether the progress read is legible at all.
	#
	# HELD THROUGH THE REAL INPUT MAP RATHER THAN BY HANDING OVER A FRAME, which is the opposite of
	# what the audits do and is right for a *screenshot* for two reasons.
	#
	# The first is that it works. A driven [InputFrame] does not outlive its physics tick -- that is
	# deliberate, and `input_audit` asserts it -- so a hand-built frame plus an `await` is a frame
	# the next tick wipes, and the cast abandons itself. Stepping the ability by hand instead avoids
	# that and then loses to the same rule from the other side: `force_draw` runs a physics tick, so
	# the cast is abandoned *between* the last manual step and the picture. Every reading printed
	# below said the ability was working perfectly and the bar was missing from every frame.
	#
	# The second is that this is what a player does. `match_audit` notes that `Input.action_press`
	# is no good for pressed-edge bookkeeping, and that is true -- but this ability reads a HELD
	# bit, held is exactly what this reproduces, and the frame reaching the ability comes off the
	# real capture path rather than out of this file.
	var shore := player.get_node_or_null("ShoreUp") as ShoreUp
	if shore != null:
		Input.action_press(&"ability")
		for i in range(100):
			await process_frame
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png(OUT + "shore_casting.png")
		print("casting: progress %.2f, target %s, plane %d" % [
			shore.progress(), shore.target(), player.get_plane()
		])
		Input.action_release(&"ability")
		await process_frame

	# ---- and the finished timbers, from a step back down the corridor.
	network.shore(1, stood + Vector2i(1, 0))
	Shoring.place(network, 1, stood + Vector2i(1, 0))
	network.shore(1, stood + Vector2i(2, 0))
	Shoring.place(network, 1, stood + Vector2i(2, 0))
	for i in range(20):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(OUT + "shore_standing.png")
	print("standing: %d shored cells on plane 1" % network.shored_cells(1).size())

	# ---- the wedge counter, on a Brute with a part-full load and the stow clock running.
	player.set_class(MouseClass.BRUTE)
	player.set("_wedges", 3)
	player.set("_wedge_wait", player.wedge_cooldown * 0.55)
	player.take_hit(40.0, player.global_position + Vector3(0.0, 0.0, 1.0), 0.0)
	for i in range(6):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(OUT + "wedges_carried.png")
	print("wedges: %d of %d, %.1fs to the next" % [
		player.get_carried_cheese(), player.carry_capacity, player.wedge_wait()
	])

	print("wrote shore_casting.png, shore_standing.png and wedges_carried.png to %s"
		% ProjectSettings.globalize_path(OUT))
	quit()
