extends SceneTree
## Do bots refuse to walk at a mouse the grass is hiding?
##
## Concealment that the AI ignores is worse than no concealment, because it still LOOKS like it
## works: the human goes still, watches the blades settle, and gets walked at anyway. This parks an
## enemy in deep cover inside a defender's patch and asks the bot's own target picker what it sees,
## then moves the same mouse onto bare ground and asks again -- so a gate that is simply always on
## fails the second half.
##
## `[REVISED at M8]` WHAT IS ASSERTED IS A **LIVE FIX**, not the absence of any contact at all, and
## the distinction is the design rather than a loosening. A bot that has lost you is supposed to
## walk to where it last saw you and have a look; that is the search behaviour the contact book
## buys, and it is what makes breaking line of sight feel like something you did. What the grass has
## to prevent is a bot that knows where you are RIGHT NOW -- which is what `_pick_quarry` demands
## before it will turn and swing, and what a player experiences as being hunted.
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

	# AN ACTUAL DEFENDER, not merely the first blue bot, and that stopped being a detail at M8.
	# While the picker scanned the scene tree it measured from the NEST and did not care where the
	# bot itself was standing, so any blue mouse could answer the question. Perception is the crew's
	# contact book now -- somebody has to be close enough to SEE the intruder -- and seat 4 is a
	# raider halfway across the yard, which reports "nothing" for both halves of the trial and fails
	# the one that was supposed to prove the gate is not simply always on.
	var defender: Bot = null
	var intruder: Mouse = null
	for node in get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null:
			continue
		var bot := mouse as Bot
		if bot != null and bot.team == Team.BLUE and bot.role == Bot.DEFENDER and defender == null:
			defender = bot
		elif mouse.team == Team.RED and intruder == null:
			intruder = mouse
	if defender == null or intruder == null:
		print("FAIL -- need a blue bot and a red mouse, got %s / %s" % [defender, intruder])
		quit()
		return

	var nest := director.nest_of(Team.BLUE)
	var deep := _cover_near(grass, defender, nest.global_position, defender.defend_radius)
	if deep == Vector3.INF:
		print("FAIL -- no deep grass inside the defender's patch to hide in")
		quit()
		return
	print("defender %s, nest at %.1f,%.1f" % [defender.name, nest.global_position.x, nest.global_position.z])
	print("cover found at %.1f,%.1f (concealment %.2f)" % [deep.x, deep.z, grass.concealment_at(deep)])

	var ok := await _trial(scene, spotting, defender, intruder, nest, deep, "hidden in deep grass", true)
	# Bare ground, the same distance out, so the only thing that changed is the cover.
	var open := _open_near(grass, defender, nest.global_position, defender.defend_radius)
	ok = await _trial(scene, spotting, defender, intruder, nest, open, "standing in the open", false) and ok
	ok = await _underground(scene, spotting, intruder, scene.get_node("Tunnels"), deep) and ok
	print("\nPASS" if ok else "\nFAIL")
	quit()


## The same deep cover, one plane down: does the lawn still hide a mouse who is under it?
##
## THE FIELD HAS NO DEPTH, which is the bug this guards. `concealment_at` takes a Vector3 and
## throws the height away, so a tunnel running beneath a thick patch used to read as thick patch
## -- the mouse faded to a tenth opacity in a corridor with nothing growing in it, and `hidden`
## says the same thing to the enemy's sweep, so the one crew that could have seen them (the one
## on that plane) could not.
##
## Asked WITHOUT a bot, unlike the two trials above. A defender on the lawn is supposed to miss
## someone a plane down whatever the grass does -- spotting.gd rejects the pair on the plane test
## before opacity is ever consulted -- so a picker that reports nothing here would prove nothing.
## The claim is about the concealment number itself.
func _underground(
	scene: Node, spotting: Spotting, intruder: Mouse, tunnels: TunnelNetwork, under: Vector3
) -> bool:
	var at := Vector3(under.x, tunnels.plane_y(1), under.z)
	intruder.set_plane(1)
	for i in range(120):
		intruder.global_position = at
		intruder.velocity = Vector3.ZERO
		await process_frame

	var opacity: float = scene.get_node("GrassCamouflage").opacity_of(intruder)
	var hidden := spotting.hidden(intruder)
	print("\n-- one plane down, under that same deep grass")
	print("   opacity %.3f, spotting.hidden = %s" % [opacity, hidden])
	intruder.set_plane(0)

	if hidden or opacity < 0.99:
		print("   FAIL -- the lawn is hiding a mouse standing in a bare tunnel")
		return false
	print("   ok")
	return true


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
	# THROUGH THE CONTACT BOOK SINCE M8, and asked in two ways that both had to change.
	#
	# A LIVE FIX, NOT ANY CONTACT AT ALL. Bots now investigate a contact that has gone stale --
	# walking to where somebody was last seen is the search behaviour, and it is meant to happen.
	# What concealment must prevent is a bot that KNOWS where you are right now, which is a live
	# contact, and is exactly what `_pick_quarry` requires before it will square up to you.
	#
	# AND CENTRED ON THE SPOT RATHER THAN ON THE NEST. Scoped to the whole patch, this returns the
	# nearest contact of any enemy in it -- and the yard has four other red mice wandering about, so
	# the trial was reporting whichever one happened to be closest and calling it the intruder.
	var seen: Dictionary = defender.call("_seen_within", at, 1.5, true)
	var picked: Mouse = null if seen.is_empty() else seen["mouse"]

	print("\n-- %s" % label)
	print("   opacity %.3f, spotting.hidden = %s" % [opacity, hidden])
	print("   defender's live fix on that spot: %s" % ("nothing" if picked == null else str(picked.name)))

	if hidden != expect_hidden:
		print("   FAIL -- expected hidden=%s" % expect_hidden)
		return false
	if expect_hidden and picked == intruder:
		print("   FAIL -- the bot has a live fix on a mouse it cannot see")
		return false
	if not expect_hidden and picked != intruder:
		print("   FAIL -- the bot ignores an intruder standing in plain sight")
		return false
	print("   ok")
	return true


## Every spot worth trying: inside `reach` of the nest, and where the defender can actually see it.
##
## TWO CONSTRAINTS THE FIRST VERSION OF THIS PROBE DID NOT HAVE, both of which quietly broke it the
## moment perception stopped being a scene-tree scan.
##
## IT SEARCHED A SQUARE. Offsets ran from `-reach` to `+reach` on each axis independently, so a
## corner candidate sits `reach * 1.41` away -- and the deep-cover spot it picked was 11.0m from a
## nest the defender only patrols 9.0m of. The bot was right to ignore it. A test whose "hidden"
## case is out of range is not testing concealment, it is testing arithmetic, and it passed for
## three milestones.
##
## AND IT NEVER ASKED ABOUT LINE OF SIGHT, which matters here in a way that is specific to this map:
## grass does not grow hard against a boulder, so the open ground nearest a nest is very often the
## ground tucked behind one. The control case -- *the same mouse, the same distance out, and only
## the cover changed* -- was differing in visibility as well, which is the one thing it must not do.
func _spots(grass: GrassPatch, from: Mouse, of: Vector3, reach: float) -> Array[Vector3]:
	var found: Array[Vector3] = []
	var step := 0.5
	var offset := -reach
	while offset <= reach:
		var other := -reach
		while other <= reach:
			var at := of + Vector3(offset, 0.0, other)
			# The circle, not the square. Kept a little inside so a candidate on the rim is not
			# decided by floating point.
			if Vector2(offset, other).length() <= reach - 0.75 and _in_view(from, at):
				found.append(at)
			other += step
		offset += step
	return found


## Can this mouse actually see that spot? spotting.gd's own question, asked the same way -- the
## world bit plus the viewer's plane, from an eye a quarter of a metre up.
func _in_view(from: Mouse, at: Vector3) -> bool:
	var space := from.get_world_3d().direct_space_state
	if space == null:
		return true
	var eye := Vector3.UP * 0.25
	var query := PhysicsRayQueryParameters3D.create(
		from.global_position + eye,
		at + eye,
		TunnelNetwork.WORLD_BIT | TunnelNetwork.plane_bit(from.get_plane())
	)
	return space.intersect_ray(query).is_empty()


func _cover_near(grass: GrassPatch, from: Mouse, of: Vector3, reach: float) -> Vector3:
	var best := Vector3.INF
	var best_cover := 0.9
	for at: Vector3 in _spots(grass, from, of, reach):
		var cover: float = grass.concealment_at(at)
		if cover > best_cover:
			best_cover = cover
			best = at
	return best


func _open_near(grass: GrassPatch, from: Mouse, of: Vector3, reach: float) -> Vector3:
	for at: Vector3 in _spots(grass, from, of, reach):
		if grass.concealment_at(at) <= 0.0:
			return at
	return of
