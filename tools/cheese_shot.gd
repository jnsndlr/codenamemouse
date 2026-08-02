extends SceneTree
## Photographs M6's new objects so the economy can be looked at rather than argued about: a
## cache out on the ring, and a nest with its store saucer beside the banner stand.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/cheese_shot.gd

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var player: Node3D = scene.get_node("Player")
	var rig: Node3D = scene.get_node("CameraRig")
	var camera := rig.find_child("*Camera*", true, false) as Camera3D

	var director := get_first_node_in_group(MatchDirector.DIRECTOR_GROUP) as MatchDirector
	var cache := CheeseCache.nearest(self, Vector3.ZERO)

	var shots: Array = [
		["nest_stores", director.nest_of(Team.BLUE).stores_point(), 7.0],
		["nest_wide", director.nest_of(Team.BLUE).global_position, 13.0],
	]
	if cache != null:
		shots.append(["cache", cache.global_position, 6.0])
		shots.append(["cache_wide", cache.global_position, 18.0])

	for shot: Array in shots:
		player.global_position = shot[1] + Vector3(0.0, 0.0, 1.2)
		if camera != null:
			camera.size = shot[2]
		for i in range(30):
			await process_frame
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png(OUT + "cheese_" + shot[0] + ".png")
		print("shot: %s" % shot[0])

	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()
