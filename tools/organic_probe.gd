extends SceneTree
## Does a curved tunnel actually come out curved?
##
##   godot --path . --resolution 1100x760 --script tools/organic_probe.gd
##
## Needs a real renderer. Writes /tmp/organic_curve.png and /tmp/organic_branch.png.
##
## THE ONE THING NO HEADLESS CHECK CAN ANSWER. tunnel_audit.gd proves the geometry is sound -- the
## index is exact, no wall stands inside a corridor, the cutaway agrees with the floor -- and every
## one of those would pass just as happily against a tunnel that still looked like a staircase.
## The whole point of the change is how it READS, and reading it needs an eye.
##
## What to look for:
##   organic_curve.png  -- a corridor sweeping through roughly ninety degrees. The walls should be
##                         smooth curves. Any hint of a step pattern, at any scale, is the failure
##                         this work exists to remove.
##   organic_branch.png -- three passages leaving one corridor at angles that are not right angles,
##                         each joining it without a notch on the outside of the turn and without a
##                         fin standing across the junction.

const PLANE: int = 1


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	var network := scene.get_node("Tunnels") as TunnelNetwork
	# Nothing generated in the way: a seam across the curve would break it for a reason that has
	# nothing to do with what is being looked at.
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

	# A quarter turn, laid the way the player lays one: each stroke starts at the end of the last
	# and points a little further round. Sixteen strokes over ninety degrees is 5.6 degrees apiece
	# -- exactly one step of the angle quantisation, so this is also the tightest curve the format
	# can express, and the harshest test of whether the joints read as smooth.
	var at := Vector2(-6.0, -4.0)
	var path: Array[Vector2] = [at]
	for i in range(16):
		var angle := TunnelNetwork.ANGLE_STEPS / 4 + i
		if not network.dig_segment(PLANE, at, angle, Team.BLUE):
			printerr("curve refused at stroke %d" % i)
			break
		at = TunnelNetwork.segment_end(TunnelNetwork.segment_id(at, angle))
		path.append(at)
	# STOOD ON THE CURVE ITSELF, worked out from the strokes rather than guessed. Guessing put the
	# mouse in solid earth, where it fell through and fall_guard respawned it on the lawn -- so the
	# first run of this produced a flawless photograph of some grass.
	await _shoot(player, network, path[path.size() / 2], "/tmp/organic_curve.png")

	# A straight run with three side passages leaving it at angles a grid could not express.
	var spine := Vector2(2.0, -6.0)
	for i in range(12):
		if not network.dig_segment(PLANE, spine, TunnelNetwork.ANGLE_STEPS / 4, Team.BLUE):
			break
		spine = TunnelNetwork.segment_end(
			TunnelNetwork.segment_id(spine, TunnelNetwork.ANGLE_STEPS / 4)
		)
	for branch: Array in [[-4.0, 6], [-1.0, 52], [2.0, 9]]:
		var root_at := Vector2(2.0, branch[0] as float)
		var angle: int = branch[1]
		for i in range(4):
			if not network.dig_segment(PLANE, root_at, angle, Team.BLUE):
				break
			root_at = TunnelNetwork.segment_end(TunnelNetwork.segment_id(root_at, angle))
	await _shoot(player, network, Vector2(2.0, -1.0), "/tmp/organic_branch.png")

	# TWO CORRIDORS JOINED, which is the thing that was quietly impossible. The joining stroke ends
	# inside the corridor it is reaching for, and an aim that refused a stroke on those grounds
	# meant two tunnels a metre apart could never be connected -- so this is worth a photograph as
	# well as an invariant.
	var left := Vector2(-2.0, 10.0)
	var right := Vector2(-2.0, 14.0)
	for i in range(10):
		network.dig_segment(PLANE, left, 0, Team.BLUE)
		network.dig_segment(PLANE, right, 0, Team.BLUE)
		left = TunnelNetwork.segment_end(TunnelNetwork.segment_id(left, 0))
		right = TunnelNetwork.segment_end(TunnelNetwork.segment_id(right, 0))
	# Across the gap at a slant, finishing well inside the far corridor.
	#
	# A REFUSAL PARTWAY ALONG IS NOT A FAILURE. The last stroke of a join lies wholly inside the
	# corridor it has just reached, so `opens_ground` correctly declines it -- there is no earth
	# left. What matters is whether the two corridors ended up connected, so that is what is
	# asked, rather than counting how many strokes landed.
	var joiner := Vector2(3.0, 10.0)
	var middle := joiner
	for i in range(5):
		if not network.dig_segment(PLANE, joiner, 10, Team.BLUE):
			break
		joiner = TunnelNetwork.segment_end(TunnelNetwork.segment_id(joiner, 10))
		if i == 1:
			middle = joiner
	if network.graph().route(PLANE, Vector2i(0, 10), PLANE, Vector2i(0, 14)).is_empty():
		printerr("THE CONNECT BUG IS BACK: the two corridors are still not joined")
	await _shoot(player, network, middle, "/tmp/organic_join.png")

	print("")
	print("wrote /tmp/organic_curve.png, /tmp/organic_branch.png and /tmp/organic_join.png")
	print("curve:  walls should sweep. ANY step pattern is the failure this exists to catch.")
	print("branch: three passages at non-right angles, no notch outside a turn, no fin across one.")
	print("join:   two parallel corridors linked by a slanted passage, open end to end.")
	quit()


## PHYSICS frames, and enough of them: camera_rig.gd follows on the physics tick with an
## exponential lerp, so a teleported player is chased rather than jumped to -- photograph it too
## early and you get a correct picture of a patch of lawn forty metres from the subject.
func _shoot(player: Mouse, network: TunnelNetwork, at: Vector2, path: String) -> void:
	player.global_position = Vector3(at.x, network.plane_y(PLANE) + 0.1, at.y)
	player.velocity = Vector3.ZERO
	player.set_plane(PLANE)
	for i in range(90):
		await physics_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(path)
