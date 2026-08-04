extends SceneTree
## Invariant audit for the flag game. The same bargain tools/tunnel_audit.gd struck, applied to
## the rules instead of the geometry.
##
##   godot --headless --path . --script tools/match_audit.gd
##
## The tunnel audit exists because every "I fell out of the world" bug was found by playing
## until it happened. The rules of a capture-the-flag match fail the same way and worse: a
## capture that counts while your own banner is away, a banner that returns while somebody is
## holding it, a mouse that respawns still carrying the thing it dropped. Every one of those
## needs a specific sequence to expose, none of them will happen in the first ten matches, and
## all of them are trivially checkable if you just say what must be true.
##
## The invariants, and what each one is really protecting:
##
##   NAV_PATH        A navigation path exists between the two nests. If this fails, bots stand
##                   still and it looks like the AI is broken rather than the navmesh.
##   STEAL           Touching THEIR banner takes it; touching your own at home does nothing.
##   CAPTURE         A capture needs their banner in your paws, you at home, AND your own
##                   banner home. The third condition is what makes defence matter.
##   SCRUFF_DROPS    A scruffed carrier drops the banner where they fell -- not at their nest,
##                   not into the void.
##   RETURN_CLOCK    A dropped banner goes home by itself, and instantly if its own crew
##                   touches it first.
##   NO_UNDERGROUND  The flag cannot enter a tunnel (GDD section 2). Checked at BOTH gates: the
##                   dig controller's refusal, and the director's backstop.
##   MELEE           A swing hits enemies in front, and nothing else -- not behind you, not
##                   your own crew, and not somebody on another plane standing under your feet.
##   RESPAWN         Scruffed mice come back, at their own nest, whole.
##   MATCH_END       The cap ends the match; the clock names the leader.
##   BOTS_MOVE       Bots actually leave the nest. Covers the whole chain -- navmesh, agent,
##                   director, control loop -- with one number that cannot be argued with.
##   BOTS_FOLLOW     A defender goes down a shaft after an intruder, and comes out on the right
##                   plane. This is M4's whole claim: until it holds, a tunnel is not a route
##                   anyone contests, it is a place the AI cannot reach. Checked end to end --
##                   decision, route, walk, transit -- because every part of that chain fails the
##                   same way, by the bot standing on the lawn looking fine.
##   SPOTTING        What the minimap is allowed to show. An enemy your crew can see appears;
##                   one behind a prop, one on another plane, and one nobody has laid eyes on do
##                   not. A contact goes stale where it was last seen and is forgotten on time.
##                   This is hidden information (GDD section 3) and every failure of it leaks
##                   the wrong way -- silently, and in the direction of knowing too much.
##   SONAR           A crew maps only the cells and mouths it cut. A Sneak sounds exactly one
##                   layer below, leaves one shared cant mark, and only an enemy Sneak can see
##                   and erase it.
##
## TIMED RULES ARE TESTED SHORT. The audit sets the return clock and the respawn to fractions
## of a second rather than waiting the real twenty and six. Those numbers are balance dials
## (GDD section 2) and will be tuned; what must not break is the mechanism, and a test that
## takes half a minute to prove a countdown counts is a test nobody runs.
##
## Exit code is non-zero if any invariant fails, so this can gate a commit.

## Everything with nothing to say about the rules. The rock and grass scatters are the
## expensive ones -- 760 bodies and 63000 blades rebuilt for every scenario -- and the camera
## and HUD only exist to be looked at.
const STRIP: Array[String] = [
	"CameraRig", "HUD", "LookPanel", "Surface/Rocks", "Surface/Grass", "FallGuard"
]

var _scene: Node
var _director: MatchDirector
var _findings: Array[String] = []
var _total_failures: int = 0


func _initialize() -> void:
	var checks: Array = [
		["nav_path", _check_nav_path],
		["steal", _check_steal],
		["capture", _check_capture],
		["scruff_drops", _check_scruff_drops],
		["return_clock", _check_return_clock],
		["no_underground", _check_no_underground],
		["melee", _check_melee],
		["respawn", _check_respawn],
		["match_end", _check_match_end],
		["bots_move", _check_bots_move],
		["spotting", _check_spotting],
		["bots_follow", _check_bots_follow],
		["classes", _check_classes],
		["cave_in", _check_cave_in],
		["barricade", _check_barricade],
		["sonar", _check_sonar],
		["tunnel_sight", _check_tunnel_sight],
		["engineer_bot", _check_engineer_bot],
		["boulder", _check_boulder],
		["controls", _check_controls],
	]

	for check: Array in checks:
		_findings.clear()
		await (check[1] as Callable).call()
		_report(check[0] as String)

	print("")
	print("=".repeat(78))
	if _total_failures == 0:
		print("ALL MATCH INVARIANTS HOLD across %d checks." % checks.size())
	else:
		print("%d failures across %d checks." % [_total_failures, checks.size()])
	print("=".repeat(78))
	quit(1 if _total_failures > 0 else 0)


# ------------------------------------------------------------------------------ the checks


## Can a bot get from one nest to the other at all?
##
## Asked of the navigation server rather than by watching a bot walk, so a failure says
## "there is no path" instead of "a bot didn't arrive", which are very different bugs with the
## same symptom.
func _check_nav_path() -> void:
	await _arena(1)
	# The bake is a frame late (the lawn is CSG and does not exist before then) and the server
	# then syncs the region into the map on the next physics frame. Ask too early and you get an
	# empty path from a navmesh that is perfectly fine.
	await _advance(0.3)
	var region := _scene.get_node("Navigation") as NavigationRegion3D
	_expect(region.navigation_mesh.get_polygon_count() > 0, "the navmesh baked at all")

	var blue := _director.nest_of(Team.BLUE).global_position
	var red := _director.nest_of(Team.RED).global_position
	var path := NavigationServer3D.map_get_path(region.get_navigation_map(), blue, red, true)
	_expect(path.size() >= 2, "a path exists between the nests")
	if path.size() >= 2:
		_expect(
			path[path.size() - 1].distance_to(red) < 2.0,
			"the path actually reaches the far nest (ends %.1fm short)" % (
				path[path.size() - 1].distance_to(red)
			)
		)


## Theirs is a steal. Yours, sitting at home, is nothing at all.
func _check_steal() -> void:
	await _arena(1)
	var theirs := _director.banner_of(Team.RED)
	var ours := _director.banner_of(Team.BLUE)

	var friend := _puppet(Team.BLUE, ours.global_position)
	await _advance(0.2)
	_expect(not friend.is_carrying(), "a mouse cannot pick up its own banner at home")
	_expect(ours.state == Banner.AT_NEST, "an untouched banner stays home")

	var thief := _puppet(Team.BLUE, theirs.global_position)
	await _advance(0.2)
	_expect(thief.is_carrying(), "touching the enemy banner takes it")
	_expect(theirs.state == Banner.CARRIED, "the banner knows it is carried")
	_expect(theirs.carrier == thief, "the banner knows who has it")

	# It rides above the carrier rather than staying where it was picked up.
	await _advance(0.1)
	thief.global_position = Vector3(4.0, 0.2, -3.0)
	await _advance(0.2)
	_expect(
		Vector2(theirs.global_position.x - 4.0, theirs.global_position.z + 3.0).length() < 0.5,
		"the banner follows its carrier"
	)


## The three conditions, checked one at a time.
func _check_capture() -> void:
	await _arena(1)
	var ours := _director.banner_of(Team.BLUE)
	var theirs := _director.banner_of(Team.RED)
	var home := _director.nest_of(Team.BLUE).global_position

	# Our banner is away: a carrier standing in our own nest must NOT score.
	var raider := _puppet(Team.RED, ours.global_position)
	await _advance(0.2)
	_expect(raider.is_carrying(), "the enemy took our banner")
	raider.global_position = Vector3(0.0, 0.2, 0.0)

	var runner := _puppet(Team.BLUE, theirs.global_position)
	await _advance(0.2)
	runner.global_position = home + Vector3(0.0, 0.2, 0.0)
	await _advance(0.3)
	_expect(_director.score_of(Team.BLUE) == 0, "no capture while our own banner is away")
	_expect(runner.is_carrying(), "and the carrier keeps hold of it")

	# Bring ours home, and the same standing position becomes a capture.
	ours.send_home()
	await _advance(0.3)
	_expect(_director.score_of(Team.BLUE) == 1, "capture counts once our banner is home")
	_expect(not runner.is_carrying(), "the carrier hands it over on scoring")
	_expect(theirs.state == Banner.AT_NEST, "the captured banner goes back to its own nest")


## Dropped where they fell, which is the whole point of the rule.
func _check_scruff_drops() -> void:
	await _arena(1)
	var theirs := _director.banner_of(Team.RED)
	var runner := _puppet(Team.BLUE, theirs.global_position)
	await _advance(0.2)

	var where := Vector3(-6.0, 0.2, 8.0)
	runner.global_position = where
	await _advance(0.2)
	runner.take_hit(9999.0, Vector3(0.0, 0.0, 0.0), 0.0)
	await _advance(0.2)

	_expect(runner.is_scruffed(), "a big enough hit scruffs")
	_expect(not runner.is_carrying(), "a scruffed mouse is not carrying anything")
	_expect(theirs.state == Banner.DROPPED, "the banner is dropped, not returned")
	_expect(
		Vector2(theirs.global_position.x - where.x, theirs.global_position.z - where.z).length()
			< 1.0,
		"the banner lands where the carrier fell"
	)


func _check_return_clock() -> void:
	await _arena(1)
	var theirs := _director.banner_of(Team.RED)
	# Short, on purpose. See the note at the top: this proves the countdown runs, not that 20
	# is the right number.
	theirs.return_seconds = 0.4

	var runner := _puppet(Team.BLUE, theirs.global_position)
	await _advance(0.2)
	runner.global_position = Vector3(3.0, 0.2, 3.0)
	await _advance(0.1)
	runner.take_hit(9999.0, Vector3.ZERO, 0.0)
	await _advance(0.2)
	_expect(theirs.state == Banner.DROPPED, "dropped after a scruff")
	_expect(theirs.return_countdown() > 0.0, "the return clock is running")

	await _advance(0.5)
	_expect(theirs.state == Banner.AT_NEST, "an abandoned banner returns itself")

	# Now the other half: its own crew touching it sends it straight home.
	var owner := _puppet(Team.RED, Vector3(10.0, 0.2, 10.0))
	theirs.drop()
	theirs.global_position = Vector3(10.0, 0.0, 10.0)
	await _advance(0.2)
	_expect(theirs.state == Banner.AT_NEST, "its own crew returns it instantly")
	_expect(not owner.is_carrying(), "and does not pick it up")


## THE FLAG CANNOT ENTER A TUNNEL, at both gates.
func _check_no_underground() -> void:
	await _arena(1)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	var player := _scene.get_node("Player") as Mouse
	# ON THE MOUSE, NOT ON THE ARENA (M7): the five controls are children of whoever is driving.
	var controller := player.get_node("DigController")
	var theirs := _director.banner_of(Team.RED)

	# Gate one: the dig controller refuses to take a carrier down a shaft.
	var cell := Vector2i(0, 0)
	network.dig_shaft_down(0, cell)
	await _advance(0.1)

	player.set_physics_process(false)
	controller.set_physics_process(false)
	player.global_position = network.cell_to_world(0, cell) + Vector3.UP * 0.2
	theirs.take(player)
	await _advance(0.1)

	controller._take_shaft(cell)
	_expect(controller.get_plane() == 0, "a carrier is refused entry to a shaft")
	_expect(player.is_carrying(), "and keeps the banner rather than dropping it down the hole")

	# Gate two: the director's backstop, for every other way of ending up underground.
	player.set_plane(1)
	await _advance(0.2)
	_expect(not player.is_carrying(), "a carrier found underground drops the banner")
	_expect(theirs.state == Banner.DROPPED, "and the banner is left where it was")


## Hits what is in front of you, and nothing else.
func _check_melee() -> void:
	await _arena(1)
	var attacker := _puppet(Team.BLUE, Vector3(0.0, 0.2, 0.0))
	# facing 0 means forward is -Z, per the model's own convention.
	attacker.revive_at(Vector3(0.0, 0.2, 0.0), 0.0)

	# Spread out, because two capsules sharing a spot shove each other hard enough to leave the
	# cone before the swing lands -- and every one of these is inside the arc and the reach, so
	# the only thing that can excuse a miss is the rule being tested.
	var ahead := _puppet(Team.RED, Vector3(0.0, 0.2, -0.6))
	var behind := _puppet(Team.RED, Vector3(0.0, 0.2, 0.75))
	var friend := _puppet(Team.BLUE, Vector3(-0.4, 0.2, -0.4))
	var below := _puppet(Team.RED, Vector3(0.4, 0.2, -0.4))
	below.set_plane(1)
	await _advance(0.1)

	_expect(attacker.swing(), "a swing starts")
	await _advance(attacker.attack_swing + 0.1)

	_expect(ahead.get_health_ratio() < 1.0, "an enemy in front is hit")
	_expect(behind.get_health_ratio() >= 1.0, "an enemy behind you is not")
	_expect(friend.get_health_ratio() >= 1.0, "your own crew is never hit")
	_expect(below.get_health_ratio() >= 1.0, "nobody on another plane is hit")

	# Displacement, not just damage (GDD section 6): the hit has to move them.
	_expect(
		ahead.global_position.z < -0.65,
		"the hit knocks them back (they are at z=%.2f, from -0.60)" % ahead.global_position.z
	)


func _check_respawn() -> void:
	await _arena(1)
	_director.respawn_seconds = 0.4
	var nest := _director.nest_of(Team.RED)

	var mouse := _puppet(Team.RED, Vector3(12.0, 0.2, -12.0))
	await _advance(0.1)
	mouse.take_hit(9999.0, Vector3.ZERO, 0.0)
	await _advance(0.1)
	_expect(mouse.is_scruffed(), "scruffed")
	_expect(_director.respawn_left(mouse) > 0.0, "the respawn clock is running")
	_expect(mouse.collision_layer == 0, "a scruffed mouse stops body-blocking")

	await _advance(0.6)
	_expect(not mouse.is_scruffed(), "back on its feet")
	_expect(mouse.get_health_ratio() >= 1.0, "at full health")
	_expect(
		mouse.global_position.distance_to(nest.spawn_point()) < 1.0,
		"at its own nest, not where it fell"
	)
	_expect(mouse.collision_layer != 0, "and solid again")


func _check_match_end() -> void:
	await _arena(1)
	_director.capture_limit = 1
	var theirs := _director.banner_of(Team.RED)
	var runner := _puppet(Team.BLUE, theirs.global_position)
	await _advance(0.2)
	runner.global_position = _director.nest_of(Team.BLUE).global_position + Vector3.UP * 0.2
	await _advance(0.3)

	_expect(_director.score_of(Team.BLUE) == 1, "the capture landed")
	_expect(not _director.is_playing(), "reaching the cap ends the match")
	_expect(_director.get_winner() == Team.BLUE, "and names the winner")

	# The clock, on a fresh arena: whoever is ahead when it runs out wins.
	await _arena(1)
	_director._score = [0, 2]
	_director._clock = 0.05
	await _advance(0.3)
	_expect(not _director.is_playing(), "the clock ends the match")
	_expect(_director.get_winner() == Team.RED, "and the leader wins it")


## Full crews, left alone for three seconds. Anything wrong anywhere in the chain -- navmesh,
## agent, director, control loop -- shows up as a bot that hasn't moved.
##
## The seats are held to different bars on purpose, because "went somewhere" is the wrong test
## for most of them. A defender's job is to stand near its own nest, and a defender that sprinted
## off across the arena would be the bug. An ENGINEER raider is measured in cells rather than
## metres: it walks clear of the nest, cuts a mouth and then stands at a face for half a second a
## tile, so the correct behaviour and a bot frozen by a broken control loop look identical from a
## tape measure. Only a raider with no other errand has to cover real ground.
func _check_bots_move() -> void:
	await _arena(3)
	await _advance(0.5)

	var bots: Array[Bot] = []
	var starts: Array[Vector3] = []
	for node in root.get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var bot := node as Bot
		if bot != null:
			bots.append(bot)
			starts.append(bot.global_position)

	# Three seats a crew, minus the one the player is holding on blue.
	_expect(bots.size() == 5, "every empty seat was filled (found %d bots)" % bots.size())
	var raiders := 0
	for bot: Bot in bots:
		if bot.role == Bot.RAIDER:
			raiders += 1
	_expect(raiders > 0 and raiders < bots.size(), "the crews are a mix of roles")

	await _advance(3.0)

	for i in range(bots.size()):
		var bot := bots[i]
		var home := _director.nest_of(bot.team).global_position
		var moved := bot.global_position.distance_to(starts[i])
		if bot.role == Bot.RAIDER:
			# Either it covered ground or it went under it. Both are "on its way over"; standing
			# on the lawn where it started is the only answer that is not.
			_expect(
				moved > 3.0 or bot.get_plane() > 0,
				"%s is on its way over (moved %.1fm, plane %d, intent: %s)" % [
					bot.name, moved, bot.get_plane(), bot.get_intent()
				]
			)
			continue
		# A defender is judged on where it IS, not on how far it went. It walks to its post in
		# the first second and then stands there, which is the job -- an early version of this
		# check asked every bot to keep covering ground and failed the one behaving correctly.
		_expect(
			home.distance_to(bot.global_position) <= bot.defend_radius,
			"%s is holding its nest (%.1fm out, intent: %s)" % [
				bot.name, home.distance_to(bot.global_position), bot.get_intent()
			]
		)


## The Engineer's capability: who may use it, on what, and to whom. (M4)
##
## The geometry side of a collapse is tools/tunnel_audit.gd's; this is the ABILITY -- the class
## gate, the reach, the cooldown and the mouse standing in the wrong place. All four are design
## rather than plumbing, and the class gate especially: it is the whole of Pillar 4 for this
## class, and a gate that silently lets everyone through is indistinguishable from one that works.
func _check_cave_in() -> void:
	await _arena(1)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	var player := _director.get_player()
	# ON THE MOUSE, NOT ON THE ARENA (M7): the five controls are children of whoever is driving.
	var cave: CaveIn = null
	if player != null:
		cave = player.get_node_or_null("CaveIn") as CaveIn
	if cave == null or player == null:
		_expect(false, "the arena has a cave-in and a player")
		return

	# A corridor to stand in, and the player in the middle of it as an Engineer.
	network.dig_shaft_down(0, Vector2i(-17, -17))
	for x in range(-17, -10):
		network.dig(1, Vector2i(x, -17))
	await _advance(0.2)

	# The player recomputes its aim from the real cursor every physics frame, so it comes off
	# physics before the aim is set from here -- the same reason the dig-flow audit does it.
	player.set_physics_process(false)
	player.global_position = network.cell_to_world(1, Vector2i(-14, -17)) + Vector3.UP * 0.05
	player.set_plane(1)
	player.set_class(MouseClass.GENERALIST)
	_aim(player, network.cell_to_world(1, Vector2i(-13, -17)))

	# NOT THE GENERALIST. Everyone digs; only the Engineer un-digs.
	_fire(cave)
	_expect(
		network.is_dug(1, Vector2i(-13, -17)),
		"a Generalist cannot bring a tunnel down"
	)

	# The Engineer can, and takes whoever is standing there with it (GDD section 3).
	player.set_class(MouseClass.ENGINEER)
	var caught := _puppet(Team.RED, network.cell_to_world(1, Vector2i(-13, -17)) + Vector3.UP * 0.05)
	caught.set_plane(1)
	await _advance(0.2)
	_fire(cave)
	_expect(not network.is_dug(1, Vector2i(-13, -17)), "an Engineer brings the cell down")
	_expect(caught.is_scruffed(), "and scruffs whoever was standing in it")
	_expect(not player.is_scruffed(), "without burying the Engineer as well")

	# And then has to wait. A second one on the same breath would make a corridor disappear
	# faster than anyone could react to it.
	_aim(player, network.cell_to_world(1, Vector2i(-15, -17)))
	_fire(cave)
	_expect(
		network.is_dug(1, Vector2i(-15, -17)),
		"a second cave-in is refused while the first is on cooldown"
	)

	# Never the cell you are standing in. Burying yourself is not a mechanic anyone asked for.
	cave._cooldown_left = 0.0
	_aim(player, network.cell_to_world(1, Vector2i(-14, -17)))
	_expect(cave.target() == Vector2i.MAX, "you cannot target the cell under your own feet")
	_fire(cave)
	_expect(network.is_dug(1, Vector2i(-14, -17)), "and it survives if you try")

	# Nor anything out of arm's reach: this removes ground with people on it.
	_aim(player, network.cell_to_world(1, Vector2i(-11, -17)))
	_expect(cave.target() == Vector2i.MAX, "a cell three along is out of reach")
	_fire(cave)
	_expect(network.is_dug(1, Vector2i(-11, -17)), "and stays up")


## Press the ability key, the way the game now delivers it (M7).
##
## This used to build an `InputEventAction` and call `_unhandled_input` directly. Abilities are no
## longer input handlers -- they read the mouse's [InputFrame] on the physics tick, because an
## event handler fires on *this* machine's event stream and a server has none for a remote peer.
## So the audit hands the player a frame and ticks the ability, which is precisely what a received
## packet will do.
##
## Driving through `Input.action_press` was tried and does not work: the pressed-frame bookkeeping
## does not line up with `await physics_frame`, so `is_action_just_pressed` is already false by the
## time the next physics frame runs.
func _fire(cave: CaveIn) -> void:
	_intend(cave.get("_player"), InputFrame.Action.ABILITY)
	cave._physics_process(0.0)


## Point a mouse's aim at a world position.
##
## AS AN INTENT, not by poking `_aim_point`. Aim travels in the [InputFrame] now, and a frame
## driven earlier in the same physics tick is still what `input()` returns -- so setting the field
## alone reads back as whatever the previous `_fire` was aimed at, which is how two refusal checks
## started passing for the wrong reason and then failing for the right one.
func _aim(who: Node, at: Vector3) -> void:
	var frame := InputFrame.new()
	frame.aim_point = at
	who.call("drive", frame)


## Hand a mouse a one-tick intent: one action pressed and held, aimed wherever the check last put
## the aim point. `Player.drive` marks the tick as spoken for, so the real keyboard does not
## capture over the top of it before the ability reads it.
func _intend(who: Node, action: int) -> void:
	var frame := InputFrame.new()
	frame.aim_point = who.get("_aim_point")
	frame.set_pressed(action, true)
	frame.set_held(action, true)
	who.call("drive", frame)


## The Engineer's other capability: a boulder in the way, and the Brute who shifts it. (M4)
##
## THREE SEPARATE THINGS HAVE TO AGREE and the audit exists because two of them are silent when
## they don't. The rock is visible, so a placement bug is obvious; the ROUTING BLOCK is not -- a
## barricade that fails to leave the graph produces a bot walking into a rock forever, which reads
## as broken AI -- and neither is the CLASS GATE on clearing it, which is the whole reason the
## Brute wants to be underground at all.
func _check_barricade() -> void:
	await _arena(1)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	var player := _director.get_player()
	var wall: Barricade = null
	if player != null:
		wall = player.get_node_or_null("Barricade") as Barricade
	if wall == null or player == null:
		_expect(false, "the arena has a barricade ability and a player")
		return

	# A straight corridor with an entrance at one end, so a route through it has no way round.
	network.dig_shaft_down(0, Vector2i(-17, -17))
	for x in range(-17, -9):
		network.dig(1, Vector2i(x, -17))
	await _advance(0.2)

	player.set_physics_process(false)
	player.global_position = network.cell_to_world(1, Vector2i(-14, -17)) + Vector3.UP * 0.05
	player.set_plane(1)
	player.set_class(MouseClass.GENERALIST)
	_aim(player, network.cell_to_world(1, Vector2i(-13, -17)))

	# NOT THE GENERALIST. Everyone digs; only the Engineer shapes.
	_place(wall)
	_expect(
		not network.is_blocked(1, Vector2i(-13, -17)),
		"a Generalist cannot set a barricade"
	)

	player.set_class(MouseClass.ENGINEER)
	_place(wall)
	await _advance(0.1)
	_expect(network.is_blocked(1, Vector2i(-13, -17)), "an Engineer can")
	_expect(
		network.is_dug(1, Vector2i(-13, -17)),
		"and the cell is still dug -- a barricade is not a cave-in"
	)
	_expect(
		network.graph().route(1, Vector2i(-17, -17), 1, Vector2i(-11, -17)).is_empty(),
		"nothing routes through it"
	)

	# And then a wait. Without it an Engineer could wall a corridor end to end in one breath, and
	# three barricades in a row is a door rather than a delay.
	_aim(player, network.cell_to_world(1, Vector2i(-15, -17)))
	_place(wall)
	_expect(
		not network.is_blocked(1, Vector2i(-15, -17)),
		"a second barricade is refused while the first is on cooldown"
	)

	# Never a shaft cell: the mouth of a ladder has to stay usable, and the beam of daylight would
	# go on advertising a way out that nobody could take.
	wall._cooldown_left = 0.0
	player.global_position = network.cell_to_world(1, Vector2i(-16, -17)) + Vector3.UP * 0.05
	_aim(player, network.cell_to_world(1, Vector2i(-17, -17)))
	_expect(wall.target() == Vector2i.MAX, "the cell under an entrance is not a barricade spot")

	# Nor on top of somebody. A cave-in buries whoever is standing there; this is a rock being
	# pushed, and you cannot push a rock through a mouse.
	player.global_position = network.cell_to_world(1, Vector2i(-14, -17)) + Vector3.UP * 0.05
	var bystander := _puppet(Team.RED, network.cell_to_world(1, Vector2i(-15, -17)) + Vector3.UP * 0.05)
	bystander.set_plane(1)
	await _advance(0.1)
	_aim(player, network.cell_to_world(1, Vector2i(-15, -17)))
	_place(wall)
	_expect(not network.is_blocked(1, Vector2i(-15, -17)), "a barricade cannot land on a mouse")
	bystander.queue_free()
	await _advance(0.1)

	# THE SUPPLY IS THREE STANDING, not three ever. Placed one at a time down the corridor, the
	# fourth has to be refused however long you wait.
	for x in [-15, -12, -11]:
		wall._cooldown_left = 0.0
		player.global_position = network.cell_to_world(1, Vector2i(x + 1, -17)) + Vector3.UP * 0.05
		_aim(player, network.cell_to_world(1, Vector2i(x, -17)))
		_place(wall)
		await _advance(0.1)
	_expect(wall.in_hand() == 0, "three standing is the whole supply")
	wall._cooldown_left = 0.0
	player.global_position = network.cell_to_world(1, Vector2i(-17, -17)) + Vector3.UP * 0.05
	_aim(player, network.cell_to_world(1, Vector2i(-16, -17)))
	_place(wall)
	_expect(not network.is_blocked(1, Vector2i(-16, -17)), "and a fourth is refused")

	# ONLY A BRUTE SHIFTS IT. The swing is the real one -- started, wound up and resolved through
	# the physics tick -- because the thing most likely to break here is the plumbing between a
	# melee cone and an object that is not a mouse, and calling the rock's own method directly
	# would test everything except that.
	var rock := _standing_at(1, Vector2i(-13, -17))
	if rock == null:
		_expect(false, "the barricade at (-13,-17) is still standing to be cleared")
		return
	# A stub off the corridor to swing from, so the Brute has floor under it. Standing in mid-air
	# would still resolve the cone -- the check ignores height -- but a puppet falling through the
	# world for the rest of the check is a second variable nobody asked for.
	network.dig(1, Vector2i(-13, -16))
	var hitter := _puppet(Team.RED, network.cell_to_world(1, Vector2i(-13, -16)) + Vector3.UP * 0.05)
	hitter.set_plane(1)
	hitter.set_class(MouseClass.GENERALIST)
	await _advance(0.1)
	var full := rock.hits_left()
	hitter.swing()
	await _advance(0.6)
	# COUNTED, NOT LOOKED AT. "The rock is still standing" is true whether the swing was ignored,
	# missed entirely, or landed and left two hits to go -- so the first version of this check
	# passed with the class gate deleted, which is exactly the kind of test that stops anyone
	# looking. The count separates all three.
	_expect(rock.hits_left() == full, "a Generalist swinging at a barricade achieves nothing")

	# Long enough for the previous swing to finish AND its recovery to expire (0.4 + 0.28), or
	# `swing()` refuses and the next assertion fails for a reason that has nothing to do with rock.
	await _advance(0.4)
	hitter.set_class(MouseClass.BRUTE)
	_expect(hitter.swing(), "the Brute's swing actually starts")
	await _advance(0.6)
	_expect(rock.hits_left() == full - 1, "a Brute's swing lands, through the ordinary melee cone")
	_expect(is_instance_valid(rock), "and one swing is not enough")
	for i in range(rock.hits_to_clear):
		if is_instance_valid(rock):
			rock.hit_by(hitter)
	# BEFORE advancing a frame. The rock frees itself deferred and its pieces fly for most of a
	# second afterwards, so the corridor has to reopen on the swing that broke it -- otherwise the
	# Brute who just earned the way through is held up by debris, and a bot re-planning during the
	# animation is told a route that is visibly clear is still shut.
	_expect(
		not network.is_blocked(1, Vector2i(-13, -17)),
		"the cell is walkable the moment the rock breaks, not when the pieces finish falling"
	)
	await _advance(0.2)
	_expect(not is_instance_valid(rock), "a Brute shifts it in the end")
	_expect(not network.is_blocked(1, Vector2i(-13, -17)), "and the cell stays walkable")
	_expect(
		not network.graph().route(1, Vector2i(-14, -17), 1, Vector2i(-13, -17)).is_empty(),
		"and routes through it again -- the graph got the cell back"
	)
	_expect(wall.in_hand() == 1, "and the Engineer gets the slot back")

	# THE CLIENT'S VERSION IS A PICTURE, NOT A SECOND ROCK WITH OPINIONS. First prove the compact
	# picture preserves signed cells, ownership, and damage, and rejects a partial replacement.
	var state := BarricadeState.new()
	state.revision = 71
	var supplies := PackedByteArray()
	supplies.resize(10)
	supplies[5] = 2
	state.set_standing(supplies)
	state.add(2, Vector2i(-123, 321), 5, 2, 3)
	var bytes := state.to_bytes()
	var decoded := BarricadeState.from_bytes(bytes)
	_expect(decoded != null and decoded.revision == 71 and decoded.rocks.size() == 1,
		"a complete barricade picture survives bytes")
	_expect(decoded != null and decoded.rocks[0].plane == 2
		and decoded.rocks[0].cell == Vector2i(-123, 321)
		and decoded.rocks[0].owner == 5
		and decoded.standing.size() == 10 and decoded.standing[5] == 2
		and decoded.rocks[0].hits_left == 2 and decoded.rocks[0].hits_total == 3,
		"and carries signed place, owner, supply, and remaining hits")
	_expect(BarricadeState.from_bytes(bytes.slice(0, bytes.size() - 1)) == null,
		"a truncated barricade picture is refused")
	var padded := bytes.duplicate()
	padded.append(0)
	_expect(BarricadeState.from_bytes(padded) == null,
		"a padded barricade picture is refused")

	# A reproduced rock looks damaged and counts against the correct Engineer's supply, while
	# leaving both the route graph and the local melee rules untouched.
	var replica := BarricadeRock.reproduce(
		network, 1, Vector2i(-10, -17), player, 2, 3
	)
	_expect(replica.hits_left() == 2 and replica.scale.x < 1.0,
		"a client rock adopts its damage state")
	_expect(not network.is_blocked(1, Vector2i(-10, -17)),
		"but a client rock never edits the routing graph")
	_expect(not replica.is_in_group(Breakable.GROUP),
		"and is not a local melee target")
	var before_replica_hit := replica.hits_left()
	_expect(not replica.hit_by(hitter) and replica.hits_left() == before_replica_hit,
		"even a direct local Brute hit cannot damage it")
	_expect(wall.in_hand() == 0,
		"its replicated owner makes the Engineer's supply agree")
	replica.discard_replica()
	_expect(wall.in_hand() == 1,
		"and removing the picture gives that owner's slot back")
	wall.adopt_standing(3)
	player.set_puppet(true)
	_expect(wall.in_hand() == 0,
		"a hidden owned rock can still consume replicated supply")
	player.set_puppet(false)
	_expect(wall.in_hand() == 1,
		"while the authority continues deriving supply from real rocks")
	await _advance(0.1)


## Hidden tunnel knowledge and the Sneak's way of sampling it. (M5)
##
## Every assertion has a mirror for the other crew. A visibility feature that leaks is much
## easier to ship than one that does nothing: from the blue seat, both look like "my map works".
func _check_sonar() -> void:
	await _arena(1)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	var player := _director.get_player()
	var sonar: Sonar = null
	if player != null:
		sonar = player.get_node_or_null("Sonar") as Sonar
	if sonar == null or player == null:
		_expect(false, "the arena has sonar and a player")
		return

	var blue_cell := Vector2i(-16, -16)
	var red_cell := Vector2i(7, 6)
	var red_beside := Vector2i(8, 6)
	var deeper := Vector2i(7, 7)
	_expect(network.dig(1, blue_cell, Team.BLUE), "blue can cut a known cell")
	_expect(network.dig(1, red_cell, Team.RED), "red can cut its own hidden cell")
	_expect(network.dig(1, red_beside, Team.RED), "red can extend its hidden route")
	_expect(network.dig(2, deeper, Team.RED), "there is also a deeper route to ignore")
	_expect(network.is_tunnel_known(1, blue_cell, Team.BLUE), "blue maps the cell it cut")
	_expect(not network.is_tunnel_known(1, blue_cell, Team.RED), "red does not get blue's cell")
	_expect(network.is_tunnel_known(1, red_cell, Team.RED), "red maps the cell it cut")
	_expect(not network.is_tunnel_known(1, red_cell, Team.BLUE), "blue does not get red's cell")
	var junction := blue_cell + Vector2i(1, 0)
	var red_after := blue_cell + Vector2i(2, 0)
	_expect(network.dig(1, junction, Team.RED), "red can break into blue's route")
	_expect(
		network.is_tunnel_known(1, junction, Team.BLUE)
		and network.is_tunnel_known(1, junction, Team.RED),
		"the intersecting cell is the one shared junction"
	)
	_expect(network.dig(1, red_after, Team.RED), "red can continue past the junction")
	_expect(
		not network.is_tunnel_known(1, red_after, Team.BLUE),
		"but the connected enemy route does not leak past it"
	)

	# Mouths obey the same boundary. Kept far apart so the shaft exclusion rule is not the reason
	# one side fails to receive one.
	_expect(network.dig_shaft_down(0, Vector2i(-18, -18), Team.BLUE), "blue cuts a mouth")
	_expect(network.dig_shaft_down(0, Vector2i(18, 18), Team.RED), "red cuts another mouth")
	_expect(
		network.known_shaft_cells(0, Team.BLUE).has(Vector2i(-18, -18)),
		"blue maps its own mouth"
	)
	_expect(
		not network.known_shaft_cells(0, Team.BLUE).has(Vector2i(18, 18)),
		"and not red's mouth"
	)

	player.set_physics_process(false)
	player.set_class(MouseClass.GENERALIST)
	player.global_position = network.cell_to_world(0, Vector2i(7, 6)) + Vector3.UP * 0.2
	player.set_plane(0)
	_expect(sonar.scan() == 0, "a Generalist cannot sound through the floor")

	player.set_class(MouseClass.SNEAK)
	var heard := sonar.scan()
	_expect(heard == 2, "a Sneak hears the two cells exactly one layer below, not the deeper one")
	var blue_marks := sonar.marks_for(Team.BLUE, MouseClass.GENERALIST, 0)
	_expect(blue_marks.size() == 1, "one scan leaves one cant mark for the crew")
	if blue_marks.is_empty():
		return
	var mark := blue_marks[0]
	_expect(mark.target_plane == 1, "the mark says the answer is one layer down")
	_expect(
		not sonar.marks_for(Team.RED, MouseClass.GENERALIST, 0).has(mark),
		"an enemy Generalist cannot read the cant"
	)
	_expect(
		sonar.marks_for(Team.RED, MouseClass.SNEAK, 0).has(mark),
		"an enemy Sneak can read it"
	)

	# The rival Sneak has to stand at the mark and spend Q. Clearing is allowed even while the
	# scan cooldown is running; it is counterplay, not another scan.
	player.set_team(Team.RED)
	player.set_class(MouseClass.SNEAK)
	player.global_position = mark.global_position + Vector3.UP * 0.2
	_intend(player, InputFrame.Action.ABILITY)
	sonar._physics_process(0.0)
	_expect(sonar.marks_for(Team.BLUE, MouseClass.GENERALIST, 0).is_empty(), "the rival Sneak erases it")


## Sight into an enemy tunnel, and the clock that takes it back. (M5, GDD section 3)
##
## THE ASSERTIONS ARE ARRANGED AROUND ONE SHAPE OF FAILURE. A leak here is silent, always in the
## direction of knowing too much, and looks from the blue seat exactly like the feature working --
## so every claim about what blue learnt is paired with one about what blue must still not know,
## and the corridor is built with a bend in it precisely so there is something on the far side
## that sight must not reach.
##
## THE BEND IS THE WHOLE TEST, AND IT HAS TO BE INSIDE THE RADIUS. A straight corridor would pass
## with no line-of-sight code at all, because "everything in range" and "everything in range you
## can see" are the same set down a pipe. The first version of this check had the far leg 8.1
## cells away with sight set to 7, so it was asserting the RANGE and passed cheerfully with the
## line test stubbed out to `return true` -- a check that could not fail, which is the failure mode
## the tunnel audit already taught this project once. The corner cell is 6.7 cells out now:
## comfortably in range, and behind solid earth.
func _check_tunnel_sight() -> void:
	await _arena(1)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	var sight := _scene.get_node_or_null("TunnelSight") as TunnelSight
	if sight == null:
		_expect(false, "the arena has a tunnel sight")
		return
	# Short memory, so the fade can be watched inside an audit rather than over fifteen seconds.
	sight.memory_seconds = 1.0
	sight.fade_fraction = 1.0

	# Red cuts an L: a run east along z = 20, then a turn north. Nothing of the second leg is on
	# the line of the first, which is what makes it unseeable from inside the first.
	var mouth := Vector2i(10, 20)
	for x in range(10, 17):
		_expect(network.dig(1, Vector2i(x, 20), Team.RED), "red cuts its corridor at x=%d" % x)
	for y in range(19, 16, -1):
		_expect(network.dig(1, Vector2i(16, y), Team.RED), "red turns the corner at y=%d" % y)

	var lit := Vector2i(12, 20)
	var round_the_bend := Vector2i(16, 17)
	_expect(
		Vector2(round_the_bend - mouth).length() < float(sight.sight_cells),
		"the far leg is inside sight range, so only the line test can hide it (%.1f cells)" % (
			Vector2(round_the_bend - mouth).length()
		)
	)
	_expect(not sight.knows(Team.BLUE, 1, lit), "blue starts knowing none of it")
	_expect(sight.knows(Team.RED, 1, lit), "and red knows its own without looking")

	# Blue drops into the near end of it.
	var scout := _puppet(Team.BLUE, network.cell_to_world(1, mouth) + Vector3.UP * 0.2)
	scout.set_plane(1)
	await _advance(0.4)

	_expect(sight.knows(Team.BLUE, 1, lit), "standing in an enemy corridor reveals what it can see")
	_expect(
		not sight.knows(Team.BLUE, 1, round_the_bend),
		"but not the leg round the corner -- sight does not flood-fill"
	)
	# THE CELL IS NOT ADOPTED. Seeing a cell must not make it blue's own, or the crew would keep
	# it forever and the fog below would never get a chance to fail.
	_expect(
		not network.is_tunnel_known(1, lit, Team.BLUE),
		"and a cell you merely saw is not a cell you cut"
	)
	_expect(
		sight.knows(Team.RED, 1, round_the_bend),
		"and red still holds the whole of its own route while being looked at"
	)

	# Not "exactly 1". A cell in view is refreshed once a SWEEP and ages every frame in between,
	# so its confidence saws between full and one interval's worth of decay -- and with the memory
	# compressed to a second for this check, one interval is a quarter of it. The claim worth
	# making is that a cell being looked at stays near the top of the range; the claim that it is
	# never a hair under 1.0 would be a claim about the sweep rate.
	var fresh: Dictionary = sight.seen_cells(Team.BLUE, 1)
	_expect(
		fresh.get(lit, 0.0) > 1.0 - sight.interval / sight.memory_seconds - 0.01,
		"a cell in view stays at full confidence between sweeps (%.2f)" % fresh.get(lit, 0.0)
	)

	# Sight breaks: the scout is scruffed where it stands. Lying on your back is not looking.
	scout.global_position = network.cell_to_world(1, mouth) + Vector3.UP * 0.2
	scout.take_hit(9999.0, Vector3.ZERO, 0.0)
	await _advance(0.5)
	var stale: Dictionary = sight.seen_cells(Team.BLUE, 1)
	_expect(
		stale.get(lit, 1.0) < 0.9,
		"and starts going stale the moment nobody can see it (%.2f)" % stale.get(lit, 1.0)
	)
	await _advance(1.0)
	_expect(not sight.knows(Team.BLUE, 1, lit), "and is forgotten outright on time")
	_expect(sight.knows(Team.RED, 1, lit), "while red still has its own corridor")

	# AND THE SAME RULE HOLDS IN THE WORLD, which is the half that was shipped broken. The lid
	# cutaway is drawn from a mask keyed on every dug cell, so an enemy corridor was punched out of
	# the earth in front of you -- whole, and before you had been anywhere near it. A leak here is
	# far worse than one on the minimap: it is the picture the player actually believes.
	network.show_crew_knowledge(Team.BLUE)
	_expect(
		not network.is_cut_away(1, lit),
		"blue's earth stays shut over a corridor blue has never seen"
	)
	network.show_crew_knowledge(Team.RED)
	_expect(network.is_cut_away(1, lit), "and red can see into the corridor red dug")
	_expect(network.is_cut_away(1, round_the_bend), "all of it, including round its own corner")


## Bots put a class on at their nest, and an Engineer uses it. (M5)
##
## TWO RULES THAT ARE EASY TO SHIP BROKEN AND IMPOSSIBLE TO SEE BROKEN. A bot that never swaps
## looks like a crew of Generalists, which is what it looked like before this existed and nobody
## noticed for four milestones. A digger that never digs looks like a bot walking to the banner,
## which is also what it looked like before. Neither failure raises anything.
##
## The soak is long because a corridor is: five metres of walking to clear the nest, then half a
## second a tile. Judged on whether the earth changed at all, not on how far it got -- how far is
## a balance number and this is a wiring check.
func _check_engineer_bot() -> void:
	await _arena(5)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	await _advance(0.5)

	var engineers: Array[Bot] = []
	var classes: Dictionary = {}
	for node in root.get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var bot := node as Bot
		if bot == null:
			continue
		classes[bot.mouse_class] = true
		if bot.mouse_class == MouseClass.ENGINEER:
			engineers.append(bot)

	# The director hands out a WANT, not a costume -- a bot acquires its class by standing in its
	# own nest. If this comes back as one entry, the swap never happened and every seat below is
	# a Generalist wearing a different name.
	_expect(classes.size() >= 3, "bots swapped into their seats (found %d classes)" % classes.size())
	_expect(not engineers.is_empty(), "a crew of five fields an Engineer")
	if engineers.is_empty():
		return
	for bot: Bot in engineers:
		_expect(bot.role == Bot.RAIDER, "%s digs toward somewhere worth digging to" % bot.name)

	var before := network.cell_count(1)
	var mouths_before := network.shaft_cells(0).size()
	await _advance(14.0)
	var after := 0
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		after += network.cell_count(plane)
	_expect(after > before, "an Engineer bot opens earth on its own (%d -> %d cells)" % [before, after])

	# CORRIDORS, NOT STUBS, and this is the assertion the first version needed and did not have.
	# A digger that starts a fresh hole every time its raid is interrupted still passes "opens
	# earth" -- it opens plenty. What it does not do is build anything: the first soak produced
	# twenty-eight cells spread over ELEVEN mouths, a yard full of three-tile pits that went
	# nowhere. Cells per mouth is the number that tells those two apart, and it is the only number
	# here that would have caught it.
	var mouths := network.shaft_cells(0).size() - mouths_before
	_expect(
		mouths <= 4,
		"and reuses its way in rather than starting again (%d new mouths)" % mouths
	)
	_expect(
		mouths == 0 or float(after - before) / float(mouths) >= 6.0,
		"so a mouth leads to a corridor (%.1f cells per mouth)" % (
			float(after - before) / float(maxi(mouths, 1))
		)
	)

	# AND THE CELLS ARE ITS CREW'S. A bot digging with team -1 would quietly hand every corridor
	# to both sides and make the whole of M5's boundary a fact about the human's digging only.
	var owned := 0
	var leaked := 0
	for side in [Team.BLUE, Team.RED]:
		for cell: Vector2i in network.known_tunnel_cells(1, side):
			owned += 1
			if network.is_tunnel_known(1, cell, Team.other(side)):
				leaked += 1
	_expect(owned > 0, "the cells a bot cut are on somebody's map")
	# A junction is legitimately shared, so this is not "zero" -- it is "not all of them". Two
	# crews digging from opposite corners cannot have met everywhere.
	_expect(leaked < owned, "and not on both crews' maps (%d of %d shared)" % [leaked, owned])


## Boulders: the obstruction you can see, and the one a Brute can take apart. (M4, GDD section 3)
##
## THE POINT OF A BOULDER IS THAT IT IS TWO THINGS AT ONCE -- a lump on the lawn and a shut cell of
## plane 1 -- and the second one is invisible. Nothing errors when a boulder fails to block the
## earth beneath it; you simply dig a corridor through solid rock and never find out it should not
## have worked. So the digging half is asserted first and hardest.
##
## AND IT COMES APART A QUARTER AT A TIME, which is the reason sections have their own hit pools
## rather than the boulder having one big one. A check that only proved "twenty swings clears it"
## would pass just as well against a single pool, and the decision the design is actually offering
## -- open one corner, or remove the whole rock -- would quietly not exist.
func _check_boulder() -> void:
	await _arena(1, false, true)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	var boulder := _widest_boulder()
	if boulder == null:
		_expect(false, "the field scattered a boulder covering more than one cell")
		return

	var cells := Boulder.cells_for(boulder.origin_cell, boulder.size)
	for cell: Vector2i in cells:
		_expect(network.is_rock(1, cell), "the earth under a boulder is rock at %v" % cell)
		# KNOWN TO EVERYBODY, unlike a seam. The rock is standing in the open, so making a crew dig
		# into it to "discover" what it can already see would be a puzzle about the camera.
		_expect(
			network.is_rock_known(1, cell, Team.BLUE)
			and network.is_rock_known(1, cell, Team.RED),
			"both crews can see what a boulder is sitting on, at %v" % cell
		)
		# PLANE 1 ONLY. Going under it is the answer the whole design wants you to reach for, and a
		# boulder that blocked every layer would be a wall you can see from the lawn.
		_expect(not network.is_rock(2, cell), "the plane below a boulder is ordinary earth at %v" % cell)
		_expect(not network.dig(1, cell), "no corridor can be driven under a boulder at %v" % cell)

	var target := boulder.get_child(0) as BoulderSection
	if target == null:
		_expect(false, "the boulder is built out of sections")
		return
	_expect(target.plane == 0, "a boulder is hit from the lawn, not from a tunnel under it")

	# A swing from the wrong class, counted rather than looked at -- "the rock is still there" is
	# true whether the swing was ignored, missed, or landed and left four hits to go.
	var at := target.global_position
	var hitter := _puppet(Team.RED, at + Vector3(0.0, 0.05, TunnelNetwork.CELL))
	hitter.set_class(MouseClass.GENERALIST)
	await _advance(0.1)
	var full := target.hits_left()
	hitter.swing()
	await _advance(0.6)
	_expect(target.hits_left() == full, "a Generalist swinging at a boulder achieves nothing")
	_expect(full == 5, "a section takes five swings (it takes %d)" % full)

	# And one from the right one, through the real melee cone, because the plumbing between a swing
	# and a thing that is not a mouse is what is most likely to be broken.
	await _advance(0.4)
	hitter.set_class(MouseClass.BRUTE)
	_expect(hitter.swing(), "the Brute's swing actually starts")
	await _advance(0.6)
	_expect(target.hits_left() == full - 1, "a Brute's swing lands on a boulder")

	var cell := target.cell
	var others := boulder.sections_left()
	for i in range(full):
		if is_instance_valid(target):
			target.hit_by(hitter)
	# BEFORE advancing a frame, like the barricade: the section frees itself deferred and its pieces
	# fly for most of a second, and the ground it stood on has to be diggable on the swing that
	# broke it rather than when the debris settles.
	_expect(not network.is_rock(1, cell), "the cell is ordinary earth the moment the section breaks")
	await _advance(0.2)
	_expect(not is_instance_valid(target), "a Brute breaks a section in the end")
	_expect(
		boulder.sections_left() == others - 1,
		"and only that section -- the rest of the boulder stands"
	)
	for cell_left: Vector2i in cells:
		if cell_left != cell:
			_expect(
				network.is_rock(1, cell_left),
				"the earth under the standing sections is still shut, at %v" % cell_left
			)
	_expect(network.dig(1, cell), "and a corridor can be dug through where it stood")

	# THE LAST SECTION, which is a different case and was a different bug: the boulder frees itself
	# once it is empty, and the pieces of the final quarter were parented to it, so they went with
	# it instead of falling. One break in four, in the only case that ends the object -- which a
	# check that stops after "break a section" never reaches.
	var pieces := _scene.get_tree().get_nodes_in_group(Boulder.GROUP).size()
	for node in boulder.get_children():
		var section := node as BoulderSection
		if section == null:
			continue
		for i in range(section.hits_to_clear):
			if is_instance_valid(section):
				section.hit_by(hitter)
	await _advance(0.2)
	_expect(not is_instance_valid(boulder), "the boulder is gone once every section is broken")
	_expect(
		_scene.get_tree().get_nodes_in_group(Boulder.GROUP).size() == pieces - 1,
		"and only that boulder"
	)
	var debris := 0
	for node in _scene.get_node("Surface/Boulders").get_children():
		if node is RockDebris:
			debris += 1
	_expect(debris > 0, "the last section leaves pieces behind rather than vanishing with the rock")


## The boulder covering the most cells, so the per-section rules have something to be per. Sorted
## by name first: the field is seeded, so this picks the same rock every run and a failure is
## reproducible rather than whichever one the group happened to list first.
func _widest_boulder() -> Boulder:
	var found: Array[Boulder] = []
	for node in _scene.get_tree().get_nodes_in_group(Boulder.GROUP):
		var boulder := node as Boulder
		if boulder != null:
			found.append(boulder)
	found.sort_custom(func(a: Boulder, b: Boulder) -> bool: return a.name < b.name)
	var best: Boulder = null
	for boulder: Boulder in found:
		if best == null or boulder.size.x * boulder.size.y > best.size.x * best.size.y:
			best = boulder
	if best != null and best.size.x * best.size.y <= 1:
		return null
	return best


func _place(wall: Barricade) -> void:
	_intend(wall.get("_player"), InputFrame.Action.BARRICADE)
	wall._physics_process(0.0)


func _standing_at(plane: int, cell: Vector2i) -> BarricadeRock:
	for node in _scene.get_tree().get_nodes_in_group(BarricadeRock.BARRICADE_GROUP):
		var rock := node as BarricadeRock
		if rock != null and rock.plane == plane and rock.cell == cell:
			return rock
	return null


## Classes are numbers on a mouse, and the swap point has a place and a price. (M4)
##
## WHAT THIS IS REALLY GUARDING is that the definitions actually land. `set_class` copies a
## resource onto the mouse's own properties -- which is what lets every system written before
## classes existed get per-class behaviour for free -- and the failure mode of a copy is that it
## silently doesn't happen. A Sneak with 100 health looks exactly like a Sneak.
func _check_classes() -> void:
	await _arena(1)
	var player := _director.get_player()
	if player == null:
		_expect(false, "there is a player to give a class to")
		return

	# The spread reaches the mouse, and reaches the things that read the mouse.
	player.set_class(MouseClass.SNEAK)
	var sneak := MouseClass.definition_of(MouseClass.SNEAK)
	_expect(player.max_health == sneak.max_health, "a Sneak has the Sneak's health")
	_expect(player.speed == sneak.speed, "and the Sneak's speed")
	_expect(player.carry_penalty == sneak.carry_penalty, "and the Sneak's carry penalty")
	_expect(
		player.get("sprint_seconds") == sneak.sprint_seconds,
		"and the Sneak's sprint, which only a driven mouse has"
	)

	# Health does not refill on a swap, and does not survive one either. Swapping to a Brute
	# for sixty free health, or away from one while keeping it, would both make the swap point a
	# combat move rather than a tempo cost.
	player.set_class(MouseClass.BRUTE)
	player.take_hit(150.0, Vector3.ZERO, 0.0, null)
	var hurt := player.get_health_ratio() * player.max_health
	player.set_class(MouseClass.SNEAK)
	_expect(
		player.get_health_ratio() * player.max_health <= hurt + 0.01,
		"a swap does not heal you"
	)
	player.set_class(MouseClass.BRUTE)
	player.revive_at(Vector3(0.0, 0.2, 0.0))
	player.set_class(MouseClass.SNEAK)
	_expect(
		player.get_health_ratio() <= 1.0,
		"and a swap down cannot leave you above your own maximum"
	)

	# Underground, size matters (GDD section 3): the same mouse is slower as a Brute than as a
	# Sneak, and only below the surface.
	player.revive_at(Vector3(0.0, 0.2, 0.0))
	player.set_class(MouseClass.SNEAK)
	var sneak_surface := player.move_speed()
	player.set_plane(1)
	var sneak_deep := player.move_speed()
	player.set_class(MouseClass.BRUTE)
	var brute_deep := player.move_speed()
	player.set_plane(0)
	_expect(brute_deep < sneak_deep, "a Brute is slower underground than a Sneak")
	_expect(sneak_deep > sneak_surface * 0.5, "and a Sneak is not crippled by going down")

	# The swap point: your own nest, and nowhere else.
	var swap := player.get_node_or_null("ClassSwap") as ClassSwap
	if swap == null:
		_expect(false, "the arena has a swap point")
		return

	player.global_position = _director.nest_of(Team.BLUE).global_position
	await _advance(0.1)
	_expect(swap.available(), "you can swap standing in your own nest")
	_expect(not swap.prompt().is_empty(), "and are told so")

	player.global_position = _director.nest_of(Team.RED).global_position
	await _advance(0.1)
	_expect(not swap.available(), "but not in theirs")

	player.global_position = Vector3(0.0, 0.2, 0.0)
	await _advance(0.1)
	_expect(not swap.available(), "and not in the middle of the yard")

	# Flat on your back on your own nest is not shopping time. Six seconds down should cost you
	# the six seconds, not buy you a free look at the other three classes.
	player.global_position = _director.nest_of(Team.BLUE).global_position
	player.take_hit(999.0, Vector3.ZERO, 0.0, null)
	await _advance(0.1)
	_expect(player.is_scruffed(), "the player is scruffed for this part")
	_expect(not swap.available(), "and cannot swap class while flat on their back")

	# NOBODY IS SLOWED UNDERGROUND (GDD section 3, revised). Asked of `move_speed` on both sides of
	# the surface rather than of the resource, because the rule has to survive both a `.tres` edit
	# and the multiplier being reintroduced in code -- and because "slower underground" is
	# invisible in play until somebody plays the class that has it and quietly stops using tunnels.
	player.revive_at(Vector3(0.0, 0.2, 0.0))
	for kind in range(MouseClass.COUNT):
		player.set_class(kind)
		player.set_plane(0)
		var above := player.move_speed()
		player.set_plane(1)
		_expect(
			player.move_speed() >= above - 0.001,
			"a %s is no slower underground (%.2f vs %.2f)"
				% [MouseClass.name_of(kind), player.move_speed(), above]
		)
	player.set_plane(0)


## Does a defender actually come down after you? (M4)
##
## END TO END, ON PURPOSE. Every other way of testing this -- assert the graph has an edge,
## assert the planner returns waypoints -- passes happily while the bot stands on the grass,
## because the chain from "an intruder is in my patch" to "I am in the tunnel with them" runs
## through a ranking, a planner, a navmesh walk and a shaft transit, and any one of them can
## quietly decline. The only honest question is which plane the bot is standing on afterwards.
##
## The intruder is a puppet rather than a driven mouse: it has to STAY in the tunnel for the
## thing being measured to mean anything, and a bot that wandered off would turn a failed follow
## into a passed one.
func _check_bots_follow() -> void:
	await _arena(2)
	var network := _scene.get_node("Tunnels") as TunnelNetwork

	# An entrance just outside the red nest, and a short corridor away from it.
	var mouth := Vector2i(18, 18)
	network.dig_shaft_down(0, mouth)
	network.dig(1, Vector2i(18, 19))
	network.dig(1, Vector2i(18, 20))
	await _advance(0.2)

	var hole := _director.nest_of(Team.RED).global_position.distance_to(
		network.cell_to_world(0, mouth)
	)
	_expect(hole < 9.0, "the test's entrance is inside the defender's patch (%.1fm out)" % hole)

	# A blue mouse standing in that corridor, under the red crew's noses.
	var intruder := _puppet(Team.BLUE, network.cell_to_world(1, Vector2i(18, 20)) + Vector3.UP * 0.05)
	intruder.set_plane(1)
	await _advance(0.3)
	_expect(intruder.get_plane() == 1, "the intruder is underground to begin with")

	var defender := _bot(Team.RED, Bot.DEFENDER)
	if defender == null:
		_expect(false, "the red crew fielded a defender at all")
		return

	# WATCHED, NOT SAMPLED AT THE END, and that distinction cost an hour. The first version of
	# this check advanced eight seconds and then looked: the defender was back on the lawn at its
	# post and the check failed. It had gone down, scruffed the intruder, and walked home -- the
	# whole behaviour under test, finished and tidied away before anybody looked. What is being
	# asserted is that it HAPPENED, so the loop has to be watching while it does.
	var deepest := 0
	var closest := INF
	for i in range(600):
		await physics_frame
		deepest = maxi(deepest, defender.get_plane())
		if defender.get_plane() > 0:
			closest = minf(closest, _flat_gap(defender, intruder))
			if closest < 2.0:
				break

	_expect(deepest > 0, "the defender went down the shaft after the intruder")
	_expect(
		closest < 2.0,
		"and got to them down there rather than stopping at the bottom of the shaft (%.1fm)"
			% closest
	)

	# THE FLAG STILL CANNOT GO DOWN, by the same door and for everybody. The transit is shared
	# code now (tunnel_transit.gd), so this is the one place the rule is held for bots as well.
	var carrier := _puppet(Team.RED, network.cell_to_world(0, mouth))
	_director.banner_of(Team.BLUE).take(carrier)
	await _advance(0.2)
	_expect(carrier.is_carrying(), "the puppet is holding a banner")
	_expect(
		TunnelTransit.take(network, carrier, 0) < 0,
		"a carrier is refused the shaft"
	)
	_expect(carrier.get_plane() == 0, "and is still on the surface afterwards")


## Distance between two mice ignoring height, so a mouse one plane below another reads as being
## right there rather than as two thirds of a metre away.
func _flat_gap(a: Node3D, b: Node3D) -> float:
	return Vector2(
		a.global_position.x - b.global_position.x, a.global_position.z - b.global_position.z
	).length()


## The first bot on a crew with this role, or null. Bots are spawned by the director a frame
## late, so this is asked of the group rather than of a node path.
func _bot(side: int, role: int) -> Bot:
	for node in get_nodes_in_group(Mouse.MOUSE_GROUP):
		var bot := node as Bot
		if bot != null and bot.team == side and bot.role == role:
			return bot
	return null


## What one crew is allowed to know about the other.
##
## Every check here is about a NEGATIVE -- the enemy who must NOT appear on the map -- because
## that is the direction this system fails in. A spot that fails to register is visible the
## first time you play; a spot that registers when it shouldn't looks exactly like a spot that
## should, and quietly hands away the hidden information the tunnel layer is built on.
##
## Timings are shortened the same way the return clock is: the mechanism must work, and the
## fifteen seconds is a balance dial.
func _check_spotting() -> void:
	await _arena(1)
	var eyes := _scene.get_node("Spotting") as Spotting
	eyes.interval = 0.05
	eyes.memory_seconds = 0.8

	# In the open, in range, nothing in the way.
	var watcher := _puppet(Team.BLUE, Vector3(0.0, 0.2, 0.0))
	var seen := _puppet(Team.RED, Vector3(5.0, 0.2, 0.0))
	await _advance(0.2)
	var book: Dictionary = eyes.contacts_for(Team.BLUE)
	_expect(book.has(seen), "an enemy in the open is spotted")
	_expect(bool(book.get(seen, {}).get("live", false)), "and the contact is live while seen")
	# Both crews keep their own book, and it is the same rule twice -- red spots blue exactly as
	# blue spots red. It has to already be true for their side the day bots read this.
	_expect(eyes.contacts_for(Team.RED).has(watcher), "the other crew spots symmetrically")

	# Out of range: the contact must stay behind at the last place it was seen rather than
	# following them. A marker that tracks someone you cannot see is a lie the map is telling.
	seen.global_position = Vector3(0.0, 0.2, 30.0)
	await _advance(0.25)
	book = eyes.contacts_for(Team.BLUE)
	_expect(book.has(seen), "a contact is remembered after they break away")
	_expect(not bool(book.get(seen, {}).get("live", true)), "and is no longer live")
	var frozen: Vector3 = book.get(seen, {}).get("at", Vector3.ZERO)
	_expect(
		frozen.distance_to(Vector3(5.0, 0.2, 0.0)) < 1.0,
		"the marker stays where they were last seen (drifted %.1fm)" % frozen.distance_to(
			Vector3(5.0, 0.2, 0.0)
		)
	)
	# A fresh contact is worth as much as a live one -- the marker only thins out over the last
	# stretch of its memory, so "they were here a moment ago" reads as fact and "they were here a
	# while ago" reads as a guess. Checked in both halves, because a fade that started
	# immediately would make every contact look untrustworthy the instant it stopped being live.
	_expect(eyes.confidence(book[seen]) >= 1.0, "a just-lost contact is still fully trusted")
	await _advance(0.4)
	_expect(eyes.confidence(book[seen]) < 1.0, "an old contact fades before it goes")

	await _advance(0.4)
	_expect(not eyes.contacts_for(Team.BLUE).has(seen), "a contact is forgotten on time")

	# Behind a prop, and directly below. Neither is visible, and the second is the rule the whole
	# tunnel layer rests on.
	await _arena(1)
	eyes = _scene.get_node("Spotting") as Spotting
	eyes.interval = 0.05
	var blocked_watcher := _puppet(Team.BLUE, Vector3(11.0, 0.2, -12.5))
	var behind := _puppet(Team.RED, Vector3(11.0, 0.2, -5.5))
	var below := _puppet(Team.RED, Vector3(12.0, 0.2, -13.0))
	below.set_plane(1)
	await _advance(0.2)
	book = eyes.contacts_for(Team.BLUE)
	_expect(not book.has(behind), "an enemy behind a prop is not spotted")
	_expect(not book.has(below), "an enemy on another plane is not spotted")

	# And the same enemy, once they step out from behind it, is.
	behind.global_position = Vector3(14.0, 0.2, -12.0)
	await _advance(0.2)
	_expect(
		eyes.contacts_for(Team.BLUE).has(behind),
		"the same enemy is spotted once they step into the open"
	)
	_expect(blocked_watcher.get_plane() == 0, "the watcher stayed on the surface")

	# A carrier cannot hide, at any range, behind anything (GDD section 2).
	await _arena(1)
	eyes = _scene.get_node("Spotting") as Spotting
	eyes.interval = 0.05
	var thief := _puppet(Team.RED, _director.banner_of(Team.BLUE).global_position)
	await _advance(0.2)
	_expect(thief.is_carrying(), "the puppet took our banner")
	thief.global_position = Vector3(0.0, 0.2, 34.0)
	await _advance(0.2)
	_expect(
		eyes.contacts_for(Team.BLUE).has(thief),
		"a carrier is spotted wherever they are"
	)


## Who carries controls, and who gets a cursor drawn for them. (M7)
##
## TWO QUESTIONS THAT USED TO BE ONE, and the whole point of `mouse_control.gd` is that they are
## not the same. *Does this machine decide what happens to this mouse* is a rule; *is this the
## mouse this machine is looking at* is presentation. While there was one player on one machine
## every answer was "yes, the player" and nothing could tell them apart.
##
## THE CURSOR HALF IS THE ONE WITH NO OTHER WITNESS. A leaked rule shows up as a mouse doing
## something it should not; a cursor drawn for the wrong mouse shows up as a box of earth lit in a
## corridor across the map, which is invisible to every headless check in the project and reads, in
## a real match, as an enemy Engineer's position being given away for free. So it is asserted on
## the node rather than photographed: the watched mouse builds a cursor and a mouse nobody is
## behind never does.
func _check_controls() -> void:
	await _arena(5)
	var player := _director.get_player()
	if player == null:
		_expect(false, "there is a player to carry controls")
		return

	for control_name: String in MouseControls.CONTROLS:
		_expect(player.get_node_or_null(control_name) != null,
			"the local player carries its own %s" % control_name)

	# BOTS CARRY NONE, and that is a decision rather than an omission -- a bot's input frame is
	# always empty, so five nodes that can never fire would be five nodes' worth of tick on six of
	# the ten mice in a match. Bots reach the same rules by their own road: `bot_digger.gd` cuts
	# earth, and `ClassSwap.allowed` is deliberately static so there is one copy of the rule about
	# where a swap is legal.
	var bot := _director.seat_mouse(Team.BLUE, 1)
	if bot == null:
		_expect(false, "there is a bot to compare against")
		return
	_expect(bot.get_node_or_null("DigController") == null, "and a bot carries none of them")

	# A second human, in a chair a bot was holding. On a host this is what a remote player is: the
	# same `Player` scene, the same controls, driven by a packet instead of a keyboard.
	_director.seat_remote(Team.RED, 1, true)
	await _advance(0.2)
	var remote := _director.seat_mouse(Team.RED, 1)
	if remote == null or not (remote is Player):
		_expect(false, "a remote seat holds a driven mouse")
		return
	_expect(remote.get_node_or_null("DigController") != null,
		"a remote player carries its own controls too")

	var mine := player.get_node("DigController") as MouseControl
	var theirs := remote.get_node("DigController") as MouseControl
	_expect(mine.acts() and theirs.acts(), "the host decides for both of them")
	_expect(mine.watched(), "and is looking at its own mouse")
	_expect(not theirs.watched(), "and not at the other one")

	# The cursor follows the eyes, not the authority. Both mice are simulated here; only one of
	# them is being looked at, and only that one should be drawing a box on the ground.
	await _advance(0.4)
	_expect(mine.get("_cursor") != null, "so a cursor is built for the mouse on screen")
	_expect(theirs.get("_cursor") == null, "and never for the one that is not")


# ------------------------------------------------------------------------------ the harness


## A fresh arena per check, so nothing leaks from one to the next.
##
## The crew size is set BEFORE the scene enters the tree, because the director spawns bots from
## `_ready` -- afterwards is too late, and a check that meant to run with nobody else in the
## arena would quietly be sharing it with mice making their own decisions. `crew` of 1 leaves
## only the player, since the player holds blue's first seat.
func _arena(crew: int, rock: bool = false, boulders: bool = false) -> void:
	if _scene != null:
		_scene.free()
	_scene = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	for path: String in STRIP:
		var node: Node = _scene.get_node_or_null(path)
		if node != null:
			node.free()
	# NO BOULDERS UNLESS A CHECK ASKS, exactly like the rock below and for the same reason: a
	# boulder claims cells of plane 1, and every check here digs a corridor at a hand-picked
	# coordinate to stand things in. One seeded boulder across one of them would fail a rule check
	# for a reason that has nothing to do with the rule -- identically every run.
	if not boulders:
		var field: Node = _scene.get_node_or_null("Surface/Boulders")
		if field != null:
			field.free()

	_director = _scene.get_node("MatchDirector") as MatchDirector
	_director.crew_size = crew

	# NO ROCK UNLESS A CHECK ASKS FOR IT, and set before the scene enters the tree, because
	# generation happens in the network's `_ready`. Every check in this file digs a corridor at a
	# hand-picked coordinate to stand things in; a seeded seam through one of them would fail a
	# rule check for a reason that has nothing to do with the rule, and it would do it identically
	# every run, which is the most convincing kind of wrong answer.
	if not rock:
		(_scene.get_node("Tunnels") as TunnelNetwork).rock_density = 0.0

	root.add_child(_scene)
	await process_frame
	await physics_frame
	await physics_frame


## A mouse with nobody driving it. The base class with no `_control`, which is exactly what a
## test wants: it stands where it's put, and everything else about it -- health, carrying,
## collision layers, the swing -- is the real thing rather than a stand-in.
##
## PLACED BEFORE IT ENTERS THE TREE, and that ordering cost an afternoon. A body added at the
## origin and moved afterwards exists at the origin for one physics frame; anything standing
## there is overlapping it, and the depenetration that follows is computed from the overlap and
## applied against the NEW transform -- so the bystander is fired across the arena and lands on
## top of the newcomer. It looked exactly like a teleport bug in the director.
func _puppet(side: int, at: Vector3) -> Mouse:
	var mouse := Mouse.new()
	mouse.name = "Puppet%s%d" % [Team.name_of(side), randi() % 1000]
	mouse.team = side

	# Built before it enters the tree, because `@onready var _visual := $Visual` resolves the
	# instant it does.
	var visual := Node3D.new()
	visual.name = "Visual"
	mouse.add_child(visual)

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.16
	capsule.height = 0.4
	shape.shape = capsule
	shape.position.y = 0.2
	mouse.add_child(shape)

	mouse.position = at
	_scene.add_child(mouse)
	return mouse


func _advance(seconds: float) -> void:
	for i in range(maxi(1, int(ceilf(seconds * 60.0)))):
		await physics_frame


func _expect(condition: bool, what: String) -> void:
	if not condition:
		_findings.append(what)


func _report(label: String) -> void:
	print("")
	print("-- %s" % label)
	if _findings.is_empty():
		print("   ok")
		return
	for finding: String in _findings:
		print("   FAIL: %s" % finding)
	_total_failures += _findings.size()
