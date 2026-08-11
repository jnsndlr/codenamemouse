extends SceneTree
## Photographs a scruffed carrier's cheese and banner leaving them, a few frames apart, so the
## bounce can be looked at rather than inferred from a resting position.
##
## THE AUDITS CANNOT SEE MOTION. `cheese_audit` knows four wedges went up and four wedges came
## down in more than one place; `match_audit` knows the banner ends within a tumble of where its
## carrier fell. Neither of them can tell the difference between a proper arc and a teleport with
## a two-frame delay, and "it happens too quickly" is exactly the kind of complaint that only a
## strip of frames answers.
##
## FRAMES RATHER THAN A RESULT, which is what makes this different from every other `*_shot.gd`
## here: they photograph a state, this photographs a sequence. Six pictures across about a second,
## at a fixed interval, so the shape of the arc is readable as a flip-book.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/drop_shot.gd

const OUT := "user://"
## Physics frames between pictures. Ten is about a sixth of a second, which is short enough that
## a single bounce spans several frames and long enough that six of them cover the whole fall.
const GAP: int = 10
const SHOTS: int = 6


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(60):
		await process_frame

	var director := scene.get_node("MatchDirector") as MatchDirector
	var player := scene.get_node("Player") as Mouse
	var rig: Node3D = scene.get_node("CameraRig")
	rig.set("zoom_idle", 6.5)
	rig.set("speed_zoom", false)

	# Open lawn, well clear of the nests and of every authored cache -- a drop that merges into a
	# pile that was already lying there is the one case where nothing visibly flies.
	var here := Vector3(6.0, 0.05, 6.0)
	player.set_class(MouseClass.BRUTE)
	player.revive_at(here, 0.0)
	for i in range(30):
		await process_frame

	# A full load and their banner, so both halves of the drop are in the same picture.
	player.set("_wedges", 5)
	var theirs := director.banner_of(Team.other(player.team))
	theirs.take(player)
	for i in range(10):
		await process_frame

	player.take_hit(9999.0, here + Vector3(1.0, 0.0, 0.6), 0.0)
	for shot in range(SHOTS):
		for i in range(GAP):
			await process_frame
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png(OUT + "drop_%d.png" % shot)
		print("frame %d: %d wedges still up, banner at y=%.2f, moving %s" % [
			shot, get_nodes_in_group(FlyingWedge.FLYING_GROUP).size(),
			theirs.global_position.y, theirs.is_airborne()
		])

	# Where it all ended up, which is the number the design cares about.
	var piles := 0
	var wedges := 0
	for node in get_nodes_in_group(CheeseCache.GROUP):
		var pile := node as CheeseCache
		if pile == null or pile.global_position.distance_to(here) > 8.0:
			continue
		if pile.wedges > 0:
			piles += 1
			wedges += pile.wedges
	print("settled: %d wedges across %d piles, banner %.2fm from the body" % [
		wedges, piles, Vector2(theirs.global_position.x - here.x,
			theirs.global_position.z - here.z).length()
	])
	print("wrote drop_0..%d.png to %s" % [SHOTS - 1, ProjectSettings.globalize_path(OUT)])
	quit()
