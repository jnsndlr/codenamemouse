extends SceneTree
## Do bots refuse to walk at a mouse the grass is hiding?
##
## Concealment that the AI ignores is worse than no concealment, because it still LOOKS like it
## works: the human goes still, watches the blades settle, and gets walked at anyway. This parks an
## enemy in deep cover inside a defender's patch and asks the bot's own target picker what it sees,
## then moves the same mouse onto bare ground and asks again -- so a gate that is simply always on
## fails the second half.
##
##   godot --headless --script res://tools/grass_hiding_probe.gd


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(4):
		await process_frame

	var grass: GrassPatch = scene.get_node("Surface/Grass")
	var spotting := get_first_node_in_group(Spotting.SPOTTING_GROUP) as Spotting
	var director := get_first_node_in_group(MatchDirector.DIRECTOR_GROUP) as MatchDirector
	if spotting == null or director == null:
		print("FAIL -- no spotting or director in the arena")
		quit()
		return

	# Let the director seat its bots.
	for i in range(30):
		await process_frame

	var defender: Bot = null
	var intruder: Mouse = null
	for node in get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null:
			continue
		var bot := mouse as Bot
		if bot != null and bot.team == Team.BLUE and defender == null:
			defender = bot
		elif mouse.team == Team.RED and intruder == null:
			intruder = mouse
	if defender == null or intruder == null:
		print("FAIL -- need a blue bot and a red mouse, got %s / %s" % [defender, intruder])
		quit()
		return

	var nest := director.nest_of(Team.BLUE)
	var deep := _cover_near(grass, nest.global_position, defender.defend_radius)
	if deep == Vector3.INF:
		print("FAIL -- no deep grass inside the defender's patch to hide in")
		quit()
		return
	print("defender %s, nest at %.1f,%.1f" % [defender.name, nest.global_position.x, nest.global_position.z])
	print("cover found at %.1f,%.1f (concealment %.2f)" % [deep.x, deep.z, grass.concealment_at(deep)])

	var ok := await _trial(scene, spotting, defender, intruder, nest, deep, "hidden in deep grass", true)
	# Bare ground, the same distance out, so the only thing that changed is the cover.
	var open := _open_near(grass, nest.global_position, defender.defend_radius)
	ok = await _trial(scene, spotting, defender, intruder, nest, open, "standing in the open", false) and ok
	print("\nPASS" if ok else "\nFAIL")
	quit()


## Park the intruder, let the fade settle, then ask the bot's own picker what it found.
func _trial(
	scene: Node, spotting: Spotting, defender: Bot, intruder: Mouse,
	nest: Nest, at: Vector3, label: String, expect_hidden: bool
) -> bool:
	intruder.global_position = at
	intruder.velocity = Vector3.ZERO
	# grass_camouflage.gd eases opacity at `fade_speed`, so this needs real time, not one frame.
	for i in range(120):
		intruder.global_position = at
		intruder.velocity = Vector3.ZERO
		await process_frame

	var opacity: float = scene.get_node("GrassCamouflage").opacity_of(intruder)
	var hidden := spotting.hidden(intruder)
	var picked: Variant = defender.call("_nearest_enemy_within", nest.global_position, defender.defend_radius)

	print("\n-- %s" % label)
	print("   opacity %.3f, spotting.hidden = %s" % [opacity, hidden])
	print("   defender's target picker returned: %s" % ("nothing" if picked == null else str(picked.name)))

	if hidden != expect_hidden:
		print("   FAIL -- expected hidden=%s" % expect_hidden)
		return false
	if expect_hidden and picked != null:
		print("   FAIL -- the bot is steering at a mouse it cannot see")
		return false
	if not expect_hidden and picked == null:
		print("   FAIL -- the bot ignores an intruder standing in plain sight")
		return false
	print("   ok")
	return true


func _cover_near(grass: GrassPatch, of: Vector3, reach: float) -> Vector3:
	var best := Vector3.INF
	var best_cover := 0.9
	var step := 0.5
	var offset := -reach + 1.0
	while offset < reach - 1.0:
		var other := -reach + 1.0
		while other < reach - 1.0:
			var at := of + Vector3(offset, 0.0, other)
			var cover: float = grass.concealment_at(at)
			if cover > best_cover:
				best_cover = cover
				best = at
			other += step
		offset += step
	return best


func _open_near(grass: GrassPatch, of: Vector3, reach: float) -> Vector3:
	var step := 0.5
	var offset := -reach + 1.0
	while offset < reach - 1.0:
		var other := -reach + 1.0
		while other < reach - 1.0:
			var at := of + Vector3(offset, 0.0, other)
			if grass.concealment_at(at) <= 0.0:
				return at
			other += step
		offset += step
	return of
