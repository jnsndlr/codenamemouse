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
	var controller := _scene.get_node("DigController")
	var player := _scene.get_node("Player") as Mouse
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
## The two roles are held to different bars on purpose, because "went somewhere" is the wrong
## test for a defender: its job is to stand near its own nest, and a defender that sprinted off
## across the arena would be the bug. A raider has to cover real ground.
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
		if bot.role == Bot.RAIDER:
			_expect(
				bot.global_position.distance_to(starts[i]) > 3.0,
				"%s is on its way over (moved %.1fm, intent: %s)" % [
					bot.name, bot.global_position.distance_to(starts[i]), bot.get_intent()
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
	var cave := _scene.get_node_or_null("CaveIn") as CaveIn
	var player := _director.get_player()
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
	player.set("_aim_point", network.cell_to_world(1, Vector2i(-13, -17)))

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
	player.set("_aim_point", network.cell_to_world(1, Vector2i(-15, -17)))
	_fire(cave)
	_expect(
		network.is_dug(1, Vector2i(-15, -17)),
		"a second cave-in is refused while the first is on cooldown"
	)

	# Never the cell you are standing in. Burying yourself is not a mechanic anyone asked for.
	cave._cooldown_left = 0.0
	player.set("_aim_point", network.cell_to_world(1, Vector2i(-14, -17)))
	_expect(cave.target() == Vector2i.MAX, "you cannot target the cell under your own feet")
	_fire(cave)
	_expect(network.is_dug(1, Vector2i(-14, -17)), "and it survives if you try")

	# Nor anything out of arm's reach: this removes ground with people on it.
	player.set("_aim_point", network.cell_to_world(1, Vector2i(-11, -17)))
	_expect(cave.target() == Vector2i.MAX, "a cell three along is out of reach")
	_fire(cave)
	_expect(network.is_dug(1, Vector2i(-11, -17)), "and stays up")


## Press the ability key, the way the input map would deliver it.
func _fire(cave: CaveIn) -> void:
	var press := InputEventAction.new()
	press.action = "ability"
	press.pressed = true
	cave._unhandled_input(press)


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
	var swap := _scene.get_node_or_null("ClassSwap") as ClassSwap
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


# ------------------------------------------------------------------------------ the harness


## A fresh arena per check, so nothing leaks from one to the next.
##
## The crew size is set BEFORE the scene enters the tree, because the director spawns bots from
## `_ready` -- afterwards is too late, and a check that meant to run with nobody else in the
## arena would quietly be sharing it with mice making their own decisions. `crew` of 1 leaves
## only the player, since the player holds blue's first seat.
func _arena(crew: int) -> void:
	if _scene != null:
		_scene.free()
	_scene = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	for path: String in STRIP:
		var node: Node = _scene.get_node_or_null(path)
		if node != null:
			node.free()

	_director = _scene.get_node("MatchDirector") as MatchDirector
	_director.crew_size = crew

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
