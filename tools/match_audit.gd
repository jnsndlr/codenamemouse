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
##   BOT_BLIND       Concealment works on the AI too. A bot does not face, chase or hit an enemy
##                   its crew cannot see -- which through M7 it did, because bot.gd scanned the
##                   scene tree instead of reading the contact book. This is the failure GDD
##                   section 8 is written to prevent and the one the player FEELS: you do
##                   everything the grass asks, go still, and get walked at anyway.
##   BOT_ROUTES      A crew's routes are built only from entrances that crew knows about. A bot
##                   walking into an enemy shaft it has never seen is acting on hidden information
##                   as surely as one reading their minimap, and it is the same leak wearing
##                   walking boots.
##   BOT_CHEESE      Bots play the economy on purpose: a poor crew sends raiders to fetch wedges,
##                   and a wedge in the paws gets banked rather than carried around the match. The
##                   refill decision LATCHES, so a crew commits to regrouping instead of flipping
##                   every time a wedge lands.
##   GEARS           The speed ladder belongs to every mouse, not just a driven one. Sprint burns
##                   a tank and is refused on fumes; Slow is free and beats Sprint. A bot climbs
##                   the same ladder a player does -- until M8 it had one gear, so a human could
##                   outrun any defender forever and hide from an AI that could not hide back.
##   SPOTTING        What the minimap is allowed to show. An enemy your crew can see appears;
##                   one behind a prop, one on another plane, and one nobody has laid eyes on do
##                   not. A contact goes stale where it was last seen and is forgotten on time.
##                   This is hidden information (GDD section 3) and every failure of it leaks
##                   the wrong way -- silently, and in the direction of knowing too much.
##   SECOND_WIND     The Generalist heals through being hit, and only the Generalist. The passive
##                   regeneration looks exactly like the ability from the outside, so the trial
##                   stops the clock that drives it and takes every reading inside the regen delay.
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

## A stand-in for grass_camouflage.gd that reports exactly the opacity a check tells it to.
##
## The grass is stripped from every arena here, so the real one has nothing to read and answers
## "fully visible" for everybody. Dictating the number instead is what lets `bot_blind` change one
## thing and nothing else -- see the argument there.
const FAKE_CAMOUFLAGE: String = """
extends Node

## mouse -> how visible it is. Anyone not in it is in the open.
var opacity: Dictionary = {}
## How much concealment the ground offers, everywhere at once. The real one reads a noise field;
## a check that had to hunt for a dense patch would be testing where the noise happened to be thick.
var cover: float = 0.0

func opacity_of(mouse: Node) -> float:
	return opacity.get(mouse, 1.0)

func cover_at(_at: Vector3) -> float:
	return cover
"""

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
		["respawn_cooldowns", _check_respawn_clears_cooldowns],
		["match_end", _check_match_end],
		["bots_move", _check_bots_move],
		["spotting", _check_spotting],
		["bots_follow", _check_bots_follow],
		["bot_blind", _check_bot_blind],
		["bot_routes", _check_bot_routes],
		["bot_cheese", _check_bot_cheese],
		["gears", _check_gears],
		["classes", _check_classes],
		["cave_in", _check_cave_in],
		["stomp", _check_stomp],
		["slam", _check_slam],
		["second_wind", _check_second_wind],
		["cork", _check_cork],
		["tremor", _check_tremor],
		["barricade", _check_barricade],
		["shore_up", _check_shore_up],
		["banner_toss", _check_banner_toss],
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


## Dropped where they fell -- give or take the skid, which is the whole point of the rule.
##
## `[REVISED]` THE TOLERANCE IS THE ASSERTION NOW. This used to demand the banner land within a
## metre of the fallen carrier, which was a fine way of saying "it did not go home" back when a
## drop was exact. A scruffed carrier's banner now skids up to `banner_scatter`, so the invariant
## has to be stated as the band it was always really about: **near where they fell, and nowhere
## else.** Both halves matter and the old check only tested one of them -- a banner that quietly
## returned to its nest and a banner flung across the yard would both have failed it, and a banner
## that stopped skidding at all would now pass it silently, which is why the lower bound is here.
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
	# LOOSE AND STILL MOVING IS ITS OWN MOMENT, and asserting it before waiting is what stops the
	# check below from passing against a banner that never tumbled at all.
	_expect(theirs.is_airborne(), "and it is thrown clear rather than set down on the spot")
	_expect(not theirs.may_take(runner), "nobody may take it while it is still bouncing")

	await _advance(2.5)
	_expect(not theirs.is_airborne(), "it comes to rest")
	var skid := Vector2(
		theirs.global_position.x - where.x, theirs.global_position.z - where.z
	).length()
	_expect(
		skid <= _director.banner_scatter + BANNER_FLOP,
		"the banner comes to rest within a tumble of where the carrier fell (%.2fm)" % skid
	)
	# ON THE FLOOR RATHER THAN STOPPED IN MID-AIR. Measured against the idle bob rather than against
	# zero: a banner at rest has always floated a few centimetres and back again (`idle_bob`), and
	# it picks that up again the moment the tumble hands control back. What this rules out is the
	# real failure -- a settle test that fires at the top of an arc and leaves the banner hanging.
	var floor_height := maxf(theirs.get_home().y, 0.0) + theirs.idle_bob + 0.01
	_expect(
		theirs.global_position.y <= floor_height,
		"and on the floor rather than stopped in mid-air (y=%.3f, floor %.3f)"
			% [theirs.global_position.y, floor_height]
	)
	_expect(
		theirs.global_position.distance_to(theirs.get_home()) > 1.0,
		"and did not simply go home"
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


## Every cooldown is off the clock when you get up, on both machines.
##
## `[ADDED]` WHY THIS IS ITS OWN CHECK RATHER THAN THREE LINES ON THE RESPAWN ONE ABOVE. That check
## is about the director -- where you come back and in what state -- and this is about nine nodes
## hanging off the mouse that the director has never heard of. They came back on their own clocks
## until now, so a mouse scruffed halfway through a Second Wind stood up at its nest and waited out
## the rest of forty seconds on top of the six it had already served: the same setback charged
## twice, hardest on the mouse having the worst time.
##
## EVERY ABILITY, NOT JUST THE ONES THIS CLASS CAN FIRE, and that is the reason the counters here
## are set by hand rather than by pressing keys. You may change class at your own nest -- which is
## exactly where you respawn -- so a Sneak that comes back and immediately becomes a Brute must not
## inherit a stranger's cooldown. Firing only what the current class owns would leave the other six
## nodes untested, which is precisely where a missed reset would hide.
##
## BOTH PATHS, because they are genuinely different code. A host respawns through `revive_at`; a
## client is never told to do anything of the kind and learns it from the SCRUFFED bit going out in
## a pose. The counters run on both machines by design, so a reset that only happened on one would
## leave somebody looking at a grey chip for an ability that is actually ready.
func _check_respawn_clears_cooldowns() -> void:
	await _arena(1)
	_director.respawn_seconds = 0.4
	# THE PLAYER, because it is the one mouse that carries a control set -- bots do not get one
	# (see [MouseControls]), so a puppet built by `_puppet` has no cooldowns to clear.
	var mouse := _scene.get_node("Player") as Mouse
	var abilities := _abilities_of(mouse)
	_expect(abilities.size() == 9, "the player carries all nine abilities (found %d)" % abilities.size())

	# -- the host's road: down, and up again by the director's clock.
	_charge(abilities, 30.0)
	_expect(_still_cooling(abilities).size() == abilities.size(), "the counters were set to begin with")
	mouse.take_hit(9999.0, Vector3.ZERO, 0.0)
	await _advance(0.7)
	_expect(not mouse.is_scruffed(), "the mouse came back")
	var warm := _still_cooling(abilities)
	_expect(warm.is_empty(), "every cooldown cleared on respawn (still cooling: %s)" % ", ".join(warm))

	# -- the client's road: no revive call anywhere, just the bit going out in a pose.
	_charge(abilities, 30.0)
	var here := mouse.global_position
	var down := Snapshot.Flag.SCRUFFED | (mouse.mouse_class << Snapshot.CLASS_SHIFT)
	mouse.apply_pose(here, 0.0, down, 255)
	await _advance(0.05)
	_expect(mouse.is_scruffed(), "a pose can put a puppet down")
	_expect(
		_still_cooling(abilities).size() == abilities.size(),
		"and going down does not clear anything by itself"
	)
	mouse.apply_pose(here, 0.0, mouse.mouse_class << Snapshot.CLASS_SHIFT, 255)
	await _advance(0.05)
	var warm_puppet := _still_cooling(abilities)
	_expect(
		warm_puppet.is_empty(),
		"a pose that stands a puppet up clears them too (still cooling: %s)" % ", ".join(warm_puppet)
	)

	# -- and the counters still count, or the check above would pass on an ability that had simply
	# stopped working.
	_charge(abilities, 0.2)
	await _advance(0.5)
	var stuck := _still_cooling(abilities)
	_expect(stuck.is_empty(), "and a cooldown still runs down on its own (stuck: %s)" % ", ".join(stuck))


## Every control on this mouse that has a cooldown, by name.
func _abilities_of(mouse: Mouse) -> Dictionary:
	var out: Dictionary = {}
	for name: String in ["SecondWind", "ShoreUp", "Sonar", "CaveIn", "BannerToss", "Fade", "Slam",
			"Barricade", "DustKick"]:
		var node := mouse.get_node_or_null(NodePath(name))
		if node != null:
			out[name] = node
	return out


## Put every one of them on the clock.
##
## SET RATHER THAN PRESSED, for the reason the header gives: nine nodes, one class, and the six this
## mouse cannot fire are the six a missed reset would hide in. `_cooldown_left` lives on
## [MouseControl] now, so this reaches all of them the same way.
func _charge(abilities: Dictionary, seconds: float) -> void:
	for name: String in abilities:
		abilities[name].set("_cooldown_left", seconds)


func _still_cooling(abilities: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for name: String in abilities:
		if float(abilities[name].call("cooldown_left")) > 0.0:
			out.append(name)
	return out


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


## The Brute's capability, aimed form: who may use it, on what, and to whom. (M4, moved M8)
##
## The geometry side of a collapse is tools/tunnel_audit.gd's; this is the ABILITY -- the class
## gate, the reach, the cooldown and the mouse standing in the wrong place. All four are design
## rather than plumbing, and the class gate especially: it is the whole of Pillar 4 for this
## class, and a gate that silently lets everyone through is indistinguishable from one that works.
##
## THE GATE IS NOW THE ENGINEER'S TOO, in the negative. Un-digging moved from the Engineer to the
## Brute, and the class that used to own it is the single most useful thing to assert against: a
## default left pointing at the old owner would leave both classes able to do it, and a suite that
## only ever tried a Generalist would pass.
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

	# A corridor to stand in, and the player in the middle of it.
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

	# NOT THE GENERALIST. Everyone digs; only the Brute un-digs.
	_fire(cave)
	_expect(
		network.is_dug(1, Vector2i(-13, -17)),
		"a Generalist cannot bring a tunnel down"
	)

	# NOR THE ENGINEER, ANY MORE. The class that used to own this is the one worth naming: it kept
	# the barricade and gave up the cave-in, and a stale default would leave it holding both.
	player.set_class(MouseClass.ENGINEER)
	_fire(cave)
	_expect(
		network.is_dug(1, Vector2i(-13, -17)),
		"an Engineer no longer brings a tunnel down -- un-digging is the Brute's"
	)

	# The Brute can, and takes whoever is standing there with it (GDD section 3).
	player.set_class(MouseClass.BRUTE)
	var caught := _puppet(Team.RED, network.cell_to_world(1, Vector2i(-13, -17)) + Vector3.UP * 0.05)
	caught.set_plane(1)
	await _advance(0.2)
	_fire(cave)
	_expect(not network.is_dug(1, Vector2i(-13, -17)), "a Brute brings the cell down")
	_expect(caught.is_scruffed(), "and puts whoever was standing in it down")
	_expect(not player.is_scruffed(), "without burying the Brute as well")

	# BURIED IS ITS OWN WORD, and the pair of checks is the point: the flag has to be true here and
	# false for an ordinary scruffing, or it is not distinguishing anything. A `was_buried` that
	# simply returned `is_scruffed` would pass the first line on its own.
	_expect(caught.was_buried(), "and the cause is BURIED -- it was the roof, not a paw")
	var struck := _puppet(Team.RED, player.global_position + Vector3(2.0, 0.0, 0.0))
	struck.take_hit(9999.0, struck.global_position, 0.0, player)
	_expect(
		struck.is_scruffed() and not struck.was_buried(),
		"while a mouse simply beaten down is scruffed, not buried"
	)

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


## The Brute's capability, surface form: the stomp, its footprint, its floor, and its silence.
##
## THE PATCH IS THE EASY HALF AND THE SILENCE IS THE HARD ONE. A stomp that finds nothing must
## still go off and must still spend the cooldown, because a stomp that refused would answer "is
## there a tunnel under me?" for nothing -- the Brute could walk the lawn tapping Q and read the
## enemy's whole network off which presses bounced. That is M5's pillar leaking through a guard
## clause, it is invisible from inside a match, and it is exactly the class of bug the plan says
## belongs in tools/ rather than in a playtest. So the last block here is the important one.
##
## THE FLOOR IS THE OTHER DESIGN ASSERTION. Section 5's counterplay web is a loop only because the
## Engineer's answer to a Brute is to dig BELOW it -- if a stomp reached plane 3 there would be no
## answer, and the web would be a line ending at the Brute.
func _check_stomp() -> void:
	await _arena(1)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	var player := _director.get_player()
	var cave: CaveIn = null
	if player != null:
		cave = player.get_node_or_null("CaveIn") as CaveIn
	if cave == null or player == null:
		_expect(false, "the arena has a cave-in and a player")
		return

	# A patch under the surface, deliberately spread over three planes and out past the radius so
	# the footprint has edges to be wrong about in every direction.
	#
	# `corner` IS THE TAPER'S WHOLE TEST, and it is one offset asked twice. At radius 2.2 a diagonal
	# neighbour is 1.41 away and inside the shock on plane 1; one layer down the radius is 1.2 and
	# the same offset is outside it. So the same cell coordinate must come down on one plane and
	# survive on the next, which no single-plane assertion could have caught.
	var here := Vector2i(-17, -17)
	var neighbour := here + Vector2i(1, 0)
	var corner := here + Vector2i(1, 1)
	# 2.236 away -- a hair outside 2.2, which is where a radius that had been rounded or compared
	# with `<` instead of `<=` would show up.
	var edge := here + Vector2i(2, 1)
	var far := here + Vector2i(3, 0)
	for cell in [here, neighbour, corner, edge, far]:
		network.dig(1, cell)
	network.dig(2, here)
	network.dig(2, neighbour)
	network.dig(2, corner)
	network.dig(3, here)
	await _advance(0.2)

	player.set_physics_process(false)
	player.global_position = network.cell_to_world(0, here) + Vector3.UP * 0.05
	player.set_plane(0)

	# NOT THE GENERALIST, and not on the surface either -- the class gate is asked in both forms.
	player.set_class(MouseClass.GENERALIST)
	_fire(cave)
	_expect(network.is_dug(1, here), "a Generalist stomping the lawn does nothing")

	# A mouse in the patch goes down with it, the same as one caught by the aimed form.
	var caught := _puppet(Team.RED, network.cell_to_world(1, neighbour) + Vector3.UP * 0.05)
	caught.set_plane(1)
	await _advance(0.2)

	player.set_class(MouseClass.BRUTE)
	_fire(cave)
	_expect(not network.is_dug(1, here), "a Brute's stomp takes the cell under its feet")
	_expect(not network.is_dug(1, neighbour), "and its neighbours on the layer below")
	_expect(not network.is_dug(1, corner), "and the diagonals, at the widened radius")
	_expect(caught.is_scruffed(), "and puts whoever was standing in them down")
	_expect(caught.was_buried(), "BURIED rather than scruffed -- it was the roof, not a paw")
	_expect(not player.is_scruffed(), "without hurting the Brute up on the lawn")

	# THE EDGE OF THE PATCH, asked at 2.236 against a radius of 2.2. The nearest cell that must
	# survive, so a radius quietly rounded up has somewhere to be caught.
	_expect(network.is_dug(1, edge), "a cell a hair outside the radius survives")
	_expect(network.is_dug(1, far), "and so does one three along")

	# THE PATCH TAPERS, asked with one offset on two planes -- see the note where `corner` is dug.
	_expect(not network.is_dug(2, here), "the cell directly beneath goes two layers down")
	_expect(not network.is_dug(2, neighbour), "with its own neighbours")
	_expect(
		network.is_dug(2, corner),
		"but not the diagonal that fell on plane 1 -- the shock narrows with depth"
	)
	_expect(network.is_dug(3, here), "and plane 3 is under the floor -- dig deeper is the answer")

	# THE FLOOR IS THE CAP, NOT THE TAPER, and asked separately because at the shipped radius the
	# two agree and the assertion above would pass either way -- which is this project's recurring
	# failure (a check that cannot fail) in its most flattering disguise. Widened past where the
	# taper would have run out, plane 3 has to stay out of reach on the strength of `stomp_max_plane`
	# alone, because that is the number section 5's counterplay web actually rests on.
	var wide := cave.stomp_radius_cells
	cave.stomp_radius_cells = 4.0
	var deepest := 0
	for entry: Array in cave.stomp_cells(here):
		deepest = maxi(deepest, int(entry[0]))
	cave.stomp_radius_cells = wide
	_expect(deepest > 0, "a widened stomp still finds ground -- the probe is looking at something")
	_expect(deepest <= 2, "and no radius reaches plane 3, however wide the patch is set")

	# And then it has to wait, like the aimed form.
	network.dig(1, here)
	await _advance(0.1)
	_fire(cave)
	_expect(network.is_dug(1, here), "a second stomp is refused while the first is on cooldown")

	# THE ONE THAT MATTERS. Somewhere with nothing underneath it at all: the stomp still fires and
	# still pays, because a refusal here would be a free sonar sweep of the entire yard.
	cave._cooldown_left = 0.0
	var bare := Vector2i(12, 12)
	player.global_position = network.cell_to_world(0, bare) + Vector3.UP * 0.05
	_expect(
		cave.stomp_cells(bare).is_empty(),
		"there is genuinely nothing under the bare patch"
	)
	_fire(cave)
	_expect(
		cave.cooldown_left() > 0.0,
		"a stomp over nothing still spends the cooldown -- refusing would leak where the tunnels are"
	)

	# Paving is the one refusal, and it leaks nothing: the slab is authored, visible, and standing
	# in front of everybody. Skipped rather than faked on a map that has no zone.
	var zone := _scene.get_tree().get_first_node_in_group(NoSurfaceZone.GROUP) as NoSurfaceZone
	if zone != null:
		var paved := network.world_to_cell(zone.global_position)
		network.dig(1, paved)
		await _advance(0.1)
		cave._cooldown_left = 0.0
		player.global_position = network.cell_to_world(0, paved) + Vector3.UP * 0.05
		_fire(cave)
		_expect(network.is_dug(1, paved), "you cannot stamp through paving")
		_expect(cave.cooldown_left() == 0.0, "and it costs nothing to find that out")

	# THE ENTRANCE, WHICH IS WHAT THE ABILITY IS FOR. A stomp has no plane-0 patch of its own --
	# there is nothing up there to collapse but grass -- so it reaches a mouth through the LANDING
	# underneath it, which is an ordinary cell in an ordinary patch. Stand on the hole, put a foot
	# through the cell below, and the shaft goes with it.
	#
	# SKIPPED RATHER THAN FAKED if the map will not give us a mouth at this spot. Nest clearance and
	# shaft spacing are generation rules, and forcing a shaft past them would be asserting against
	# an arena nobody plays -- the same reasoning as the paving block above.
	cave._cooldown_left = 0.0
	var mouth := Vector2i(-17, -10)
	if network.dig_shaft_down(0, mouth):
		player.global_position = network.cell_to_world(0, mouth) + Vector3.UP * 0.05
		await _advance(0.1)
		_fire(cave)
		_expect(not network.has_shaft_down(0, mouth), "a Brute stomping an entrance fills it in")
		_expect(not network.is_dug(1, mouth), "and takes the cell it landed on down with it")
		# AND SURVIVES DOING IT, which is not a formality. A shaft collapse names both of its ends,
		# and the upper end of an entrance is plane 0 -- the exact cell the Brute is standing on to
		# reach it. The first build of this buried the Brute in its own stomp every single time.
		_expect(not player.is_scruffed(), "and the Brute is not buried by the hole under its feet")


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


## The same, for the Brute's other key.
func _fire_slam(slam: Slam) -> void:
	_intend(slam.get("_player"), InputFrame.Action.SLAM)
	slam._physics_process(0.0)


## And for the Generalist's Q, which shares the key with the cave-in and the sonar.
func _fire_wind(wind: SecondWind) -> void:
	_intend(wind.get("_player"), InputFrame.Action.ABILITY)
	wind._physics_process(0.0)


## The cork, and the collision rule underneath it. (M8)
##
## THIS IS A GEOMETRY CHECK AND IT HAD TO BE, because the claim it tests was made in prose and was
## false for five milestones. The GDD retired the Brute's underground speed penalty on the grounds
## that "the cork survives, as geometry rather than as speed -- a corridor is one cell wide and
## mice body-block". Both halves were wrong at the time: allies did not collide at all, and every
## class was a 0.16 capsule in a 1.0 corridor, which two mice clear with 2cm to spare. Nothing
## failed, nothing errored, and a documented capability simply did not exist.
##
## SO IT IS ASKED BY WALKING INTO IT. A mouse is driven at a corridor with somebody standing in
## the middle, for a second and a half, and the question is whether it got past -- not whether a
## number in a resource is what it should be. A cork that a physics quirk lets people through is
## exactly as broken as one that was never built, and only one of those two is visible in the
## arithmetic.
##
## AND THE CONTROL IS THE SAME TRIAL AGAINST A SNEAK, because a corridor that nobody can pass is
## not a cork either -- it is a corridor that does not work. Pillar 4 says the Brute has one thing
## no other class can do at all, and half of that sentence is about the other three.
func _check_cork() -> void:
	await _arena(1)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	# A straight run, one cell wide, well clear of the patio and both nests.
	var row := -17
	for x in range(-17, -9):
		network.dig(1, Vector2i(x, row))
	await _advance(0.2)

	# Standing in the middle of the corridor, and in the middle of its WIDTH -- the seal band is
	# +/-12cm of the centre line and a plug parked against a wall is meant to be beatable.
	var plug := _puppet(Team.BLUE, network.cell_to_world(1, Vector2i(-13, row)) + Vector3.UP * 0.05)
	plug.set_plane(1)

	# DOES IT FIT? Asked before anything else, because a Brute that seals a corridor by being
	# jammed in it is not a cork, it is a stuck mouse -- and the two are indistinguishable from
	# every other assertion in this check. The first wide Brute was built on a capsule, whose
	# height Godot clamps to twice its radius: 0.60 of mouse under 0.53 of headroom, wedged into
	# the floor and the ceiling at once, unable to move in any direction. Everything below passed.
	plug.set_class(MouseClass.BRUTE)
	await _advance(0.2)
	for slot: Node in plug.find_children("*", "CollisionShape3D", true, false):
		var shape: Shape3D = (slot as CollisionShape3D).shape
		var tall := float(shape.get("height")) if shape.get("height") != null else 0.0
		_expect(
			tall > 0.0 and tall <= TunnelChunks.PLANE_SPACING - TunnelChunks.FLOOR_THICKNESS,
			"a Brute fits under a plane's floor (%.2f tall, %.2f of headroom)" % [
				tall, TunnelChunks.PLANE_SPACING - TunnelChunks.FLOOR_THICKNESS
			]
		)
		# AND IS AS WIDE AS IT ASKED TO BE, which is the same bug seen from the other side. A
		# capsule refuses to be both 0.30 wide and 0.40 tall, and which of the two it throws away
		# depends only on the order the two lines happen to be written in: set the radius last and
		# the body grows too tall for the corridor, set the height last and the radius is quietly
		# clamped to 0.20 -- still sealing, so every other assertion here passes, and the Brute is
		# a third narrower than the resource says. One of these two lines fires for either mistake.
		var wide := float(shape.get("radius")) if shape.get("radius") != null else 0.0
		_expect(
			is_equal_approx(wide, plug.body_radius),
			"and is as wide as its class asked for (%.2f, wanted %.2f)" % [wide, plug.body_radius]
		)

	# And it can actually walk down the corridor it fits in. Driven along its own axis, away from
	# anything to bump into -- a mouse that is stuck reports zero here whatever the reason.
	plug.set_physics_process(false)
	var from := plug.global_position
	for i in range(45):
		plug.velocity = Vector3(2.4, 0.0, 0.0)
		plug.move_and_slide()
		await physics_frame
	_expect(
		plug.global_position.distance_to(from) > 1.0,
		"and can move along it (travelled %.2fm in 0.75s)" % plug.global_position.distance_to(from)
	)
	plug.set_physics_process(true)

	for kind: int in [MouseClass.SNEAK, MouseClass.BRUTE]:
		plug.set_class(kind)
		await _advance(0.2)
		plug.global_position = network.cell_to_world(1, Vector2i(-13, row)) + Vector3.UP * 0.05
		plug.velocity = Vector3.ZERO

		# A runner three cells back and OFF THE CENTRE LINE, which is the only version of this
		# trial that means anything. Driven straight at the plug it stops dead against anybody --
		# what a player actually does is come down one side, and against a mouse its own size that
		# works: the probe measured a 0.16 plug passed by 1.7m at every lane but the head-on one.
		# A check that walked into the middle would report SEALED for all four classes and call
		# the cork built.
		var runner := _puppet(
			Team.BLUE,
			network.cell_to_world(1, Vector2i(-16, row)) + Vector3(0.0, 0.05, 0.18)
		)
		runner.set_plane(1)
		runner.set_class(MouseClass.GENERALIST)
		await _advance(0.2)

		# ON THE BODY, NOT THROUGH `_wish`. `Mouse._physics_process` clears `_wish` at the top of
		# every tick and fills it from `_control`, which a bare fixture does not implement -- so a
		# wish poked in from here is gone before anything reads it, and the first build of this
		# check watched a runner stand perfectly still for a second and a half and recorded that
		# as a corking. Driving the body is also the honest question: this is about whether one
		# capsule fits past another, not about the movement controller.
		runner.set_physics_process(false)
		for i in range(90):
			runner.velocity = Vector3(2.4, 0.0, 0.0)
			runner.move_and_slide()
			plug.global_position = (
				network.cell_to_world(1, Vector2i(-13, row)) + Vector3.UP * 0.05
			)
			plug.velocity = Vector3.ZERO
			await physics_frame

		var past := runner.global_position.x > plug.global_position.x + 0.2
		if kind == MouseClass.BRUTE:
			_expect(not past, "a Brute plugs a one-cell corridor -- nobody walks past it")
			_expect(
				runner.global_position.x < plug.global_position.x,
				"and the runner is stopped SHORT of it rather than squeezed through"
			)
		else:
			_expect(past, "a Sneak does not plug it -- a corridor you cannot pass is not a cork")
		runner.queue_free()
		await _advance(0.1)

	# The two widths, stated so a failure above says which half moved. MEASURED RATHER THAN
	# DERIVED: the arithmetic puts the seal floor at 0.18 for a centred plug, and driving mice at
	# each other agrees exactly -- 0.16 is passed, 0.18 is not. The standard mouse is therefore
	# sitting 2cm from being a cork itself, which is worth an assertion rather than a comment: a
	# tuning pass that nudged it to 0.18 would take the Brute's whole capability away by giving it
	# to everybody, and nothing else in the project would notice.
	plug.set_class(MouseClass.BRUTE)
	_expect(
		plug.body_radius >= 0.24,
		"the Brute is wide enough to seal with margin, not on the boundary (%.2f)" % plug.body_radius
	)
	plug.set_class(MouseClass.SNEAK)
	_expect(
		plug.body_radius <= 0.16,
		"and the other three stay narrow enough to pass each other (%.2f)" % plug.body_radius
	)


## The Brute's second key: a shove with no damage in it, and what it does to a carrier. (M8)
##
## THE ASSERTION THAT MATTERS IS THE LAST ONE, and it is about a number rather than a rule. A
## dropped banner has no grace period -- `_check_pickup` hands it to whoever is nearest, at
## `pickup_radius` -- so a Slam that pushes a carrier less than 0.85m drops the banner INTO THEIR
## OWN HANDS on the next tick, and every rule above it still passes. It looks exactly like a
## working ability from inside the code and like a key that does nothing from outside, which is
## this project's most-repeated bug wearing its newest costume. So the check does not merely watch
## the banner leave; it waits half a second and asks whether it came back.
##
## THE CIRCLE IS THE OTHER HALF. Slam is the only attack in the game with no arc, because the
## situation it exists for -- somebody already past you -- is behind you by definition. A cone
## would pass every other check here, so the mouse standing at the Brute's back is the one that
## proves the shape.
func _check_slam() -> void:
	await _arena(1)
	var player := _director.get_player()
	var slam: Slam = null
	if player != null:
		slam = player.get_node_or_null("Slam") as Slam
	if slam == null or player == null:
		_expect(false, "the arena has a slam and a player")
		return

	# Off physics so the Brute stays where it is put -- it recomputes aim and heading every tick
	# otherwise, the same reason the cave-in check does this.
	player.set_physics_process(false)
	player.revive_at(Vector3.ZERO, 0.0)

	# Spread around the Brute rather than in front of it, because the shape is the point. The two
	# that get shoved are on the z axis and the out-of-range one is off to the side: a shove is
	# 2.5m and a mouse parked in the flight path is a wall, which is how the first run of this
	# check measured a quarter of a metre and blamed the ability.
	var ahead := _puppet(Team.RED, Vector3(0.0, 0.2, -0.9))
	var behind := _puppet(Team.RED, Vector3(0.0, 0.2, 1.1))
	var away := _puppet(Team.RED, Vector3(2.9, 0.2, 0.0))
	var friend := _puppet(Team.BLUE, Vector3(0.9, 0.2, 0.4))
	var below := _puppet(Team.RED, Vector3(-0.9, 0.2, 0.3))
	below.set_plane(1)
	await _advance(0.2)

	# NOT EVERY CLASS. A gate that silently lets everyone through is indistinguishable from one
	# that works, so the negative is asked first and of the class most likely to be handed it.
	player.set_class(MouseClass.GENERALIST)
	var was := ahead.global_position
	_fire_slam(slam)
	await _advance(0.4)
	_expect(
		ahead.global_position.distance_to(was) < 0.3,
		"a Generalist cannot slam -- it is the Brute's"
	)

	player.set_class(MouseClass.BRUTE)
	var before: Dictionary = {}
	for mouse: Mouse in [ahead, behind, away, friend, below]:
		before[mouse] = mouse.global_position
	_fire_slam(slam)
	await _advance(0.5)

	# WELL PAST A SWING'S 0.75m, which is the number this has to beat rather than zero. A threshold
	# of "it moved at all" would pass on the knockback a punch already had and prove nothing about
	# the ability -- and it is the distance, not the shove, that the banner rule below depends on.
	_expect(
		ahead.global_position.distance_to(before[ahead]) > 1.5,
		"an enemy in front is shoved clear (moved %.2fm)" % (
			ahead.global_position.distance_to(before[ahead])
		)
	)
	_expect(
		behind.global_position.distance_to(before[behind]) > 1.5,
		"an enemy BEHIND you is shoved too -- the slam is a circle, not a cone (moved %.2fm)" % (
			behind.global_position.distance_to(before[behind])
		)
	)
	_expect(
		away.global_position.distance_to(before[away]) < 0.3,
		"an enemy out of reach is left alone"
	)
	_expect(
		friend.global_position.distance_to(before[friend]) < 0.3,
		"your own crew is never shoved"
	)
	_expect(
		below.global_position.distance_to(before[below]) < 0.3,
		"nobody on another plane is shoved -- not through a floor"
	)

	# NO DAMAGE AT ALL, which is the whole of what makes this ability what it is (GDD section 6).
	_expect(
		ahead.get_health_ratio() >= 1.0 and behind.get_health_ratio() >= 1.0,
		"a slam takes no health off anybody -- it is displacement, not damage"
	)

	# The cooldown, asked the way the stomp's is: fire again at once and watch nothing happen.
	var settled := ahead.global_position
	_fire_slam(slam)
	await _advance(0.4)
	_expect(
		ahead.global_position.distance_to(settled) < 0.3,
		"a second slam is refused while the first is on cooldown"
	)

	# ---- the carrier, and the number the whole ability is set against.
	await _arena(1)
	player = _director.get_player()
	slam = player.get_node_or_null("Slam") as Slam
	if slam == null:
		_expect(false, "the arena has a slam")
		return
	player.set_physics_process(false)
	player.set_class(MouseClass.BRUTE)

	var ours := _director.banner_of(Team.BLUE)
	var thief := _puppet(Team.RED, ours.global_position)
	await _advance(0.3)
	if not thief.is_carrying():
		_expect(false, "the trial needs a carrier to slam")
		return

	# CARRIED OUT TO OPEN GROUND FIRST, and staging it anywhere else silently tests nothing. Run
	# at the nest where the steal happens, the banner is dropped onto its own home tile -- so the
	# other half of `_check_pickup` sends it straight back where it belongs, which clears the
	# fumble and leaves it AT_NEST for the same thief to steal a second time. Every assertion below
	# then reads exactly as it would if the recovery rule did not exist. Two frames of banner state
	# machine, both correct, adding up to a check that cannot fail.
	thief.global_position = Vector3(6.0, 0.2, 6.0)
	await _advance(0.2)

	# AT ARM'S LENGTH RATHER THAN ON TOP OF THEM, and the distance is chosen against a rule in the
	# director rather than for comfort: a BLUE mouse within `pickup_radius` of its OWN banner sends
	# it straight home. Standing closer than 0.85m, this Brute would collect the banner it had just
	# knocked loose and the final assertion would pass because the flag had gone home -- which is
	# not the thing being tested, and would keep passing with the knockback set to nothing.
	player.revive_at(thief.global_position + Vector3(1.4, 0.0, 0.0), 0.0)
	await _advance(0.1)
	_fire_slam(slam)
	_expect(not thief.is_carrying(), "a slam makes a carrier drop the banner")
	_expect(ours.state == Banner.DROPPED, "the banner is on the floor where they were standing")

	# AND IT STAYS DOWN. Without enough knockback to clear `pickup_radius`, the same mouse takes it
	# straight back and every assertion above this line still passes.
	await _advance(0.5)
	_expect(
		not thief.is_carrying(),
		"the shove clears the pickup radius -- they do not simply pick it up again"
	)


## The Generalist's Q: the only health in the game you can collect while somebody is hitting you.
##
## THE CHECK IS BUILT AROUND ONE PROBLEM -- THE PASSIVE LOOKS EXACTLY LIKE THE ABILITY. Every mouse
## regenerates 18 a second after five seconds of quiet, which is very close to what [SecondWind]
## hands over and arrives through the same field. A check that pressed Q and watched health rise
## would pass with the ability deleted, and it would keep passing for as long as nobody thought to
## ask why. So the trial takes the passive off the table twice over: the player's own physics is
## stopped, which is what ticks `_since_damage` and therefore the regeneration, AND every reading is
## taken inside five seconds of a blow. Any health that appears here can only have come from the Q.
##
## AND THE BLOW IN THE MIDDLE IS THE POINT OF THE ABILITY, not staging. Damage resets the regen
## clock, so a heal that flinched at being interrupted would be a heal you may only use when nothing
## is happening -- which is the exact situation the free passive already covers. The mouse is hit
## while the wind is running, and the wind is expected not to care.
func _check_second_wind() -> void:
	await _arena(1)
	var player := _director.get_player()
	var wind: SecondWind = null
	if player != null:
		wind = player.get_node_or_null("SecondWind") as SecondWind
	if wind == null or player == null:
		_expect(false, "the arena has a second wind and a player")
		return

	# Off physics so the mouse stays put and, more importantly, stops regenerating -- see above.
	player.set_physics_process(false)
	player.revive_at(Vector3.ZERO, 0.0)
	await _advance(0.1)

	# NOT EVERY CLASS, asked first and of a class that has no Q of its own, so a gate that silently
	# lets everyone through cannot hide behind another ability firing instead.
	player.set_class(MouseClass.ENGINEER)
	player.take_hit(50.0, Vector3(0.0, 0.0, -1.0), 0.0)
	var hurt := player.get_health_ratio()
	_fire_wind(wind)
	await _advance(0.6)
	_expect(
		is_equal_approx(player.get_health_ratio(), hurt),
		"an Engineer gets no second wind -- it is the Generalist's"
	)
	_expect(wind.cooldown_left() <= 0.0, "and a refused wind costs no cooldown")

	# ---- the wind itself, taken while being hit.
	player.set_class(MouseClass.GENERALIST)
	player.revive_at(Vector3.ZERO, 0.0)
	player.set("_stamina", 0.0)
	player.take_hit(70.0, Vector3(0.0, 0.0, -1.0), 0.0)
	var floor_health := player.get_health_ratio()
	_fire_wind(wind)

	# THE LEGS ARRIVE AT ONCE, which is the half of the ability the name comes from (GDD section 2)
	# and the half a health bar cannot show.
	_expect(
		player.get_stamina_ratio() > 0.99,
		"the wind refills the sprint tank on the keypress, not over the two seconds"
	)
	_expect(wind.wind_left() > 0.0, "and the healing is still to come")

	await _advance(0.4)
	var partway := player.get_health_ratio()
	_expect(
		partway > floor_health,
		"health is coming back before the wind has finished -- it is not a lump sum at the end"
	)

	# HIT MID-WIND. Nothing about the ability is allowed to notice.
	player.take_hit(10.0, Vector3(0.0, 0.0, -1.0), 0.0)
	await _advance(2.0)
	_expect(wind.wind_left() <= 0.0, "the wind runs out on its own clock")
	# 30 health at the start, 45 back, 10 taken off in the middle: 65 out of a hundred, and the
	# threshold is set below that rather than at it so a tuning change to `heal_amount` does not fail
	# a check about a rule. What it must beat is the 30 it would be if the blow had cancelled it.
	_expect(
		player.get_health_ratio() > 0.55,
		"you heal through being hit, which no other health in this game does (ended at %d%%)" % (
			roundi(player.get_health_ratio() * 100.0)
		)
	)
	_expect(
		player.get_health_ratio() < 1.0,
		"and it is a heal rather than a revive -- a wind does not make you whole"
	)

	# ---- the cooldown, asked the way the slam's is: press again at once and watch nothing happen.
	var settled := player.get_health_ratio()
	player.take_hit(10.0, Vector3(0.0, 0.0, -1.0), 0.0)
	var after_blow := player.get_health_ratio()
	_expect(after_blow < settled, "the trial's second blow landed")
	_fire_wind(wind)
	await _advance(0.6)
	_expect(
		is_equal_approx(player.get_health_ratio(), after_blow),
		"a second wind is refused while the first is on cooldown"
	)

	# ---- nothing to give back. The narrow rule: whole AND rested, not merely whole.
	wind.set("_cooldown_left", 0.0)
	player.revive_at(Vector3.ZERO, 0.0)
	player.refill_stamina()
	_expect(not wind.take_breath(), "a whole, rested mouse is refused")
	_expect(wind.cooldown_left() <= 0.0, "and that refusal costs no cooldown either")
	player.set("_stamina", 0.0)
	_expect(
		wind.take_breath(),
		"but a whole mouse with an empty tank may still take one -- the legs are half the ability"
	)

	# ---- going down ends it. The one thing that does.
	wind.set("_cooldown_left", 0.0)
	player.revive_at(Vector3.ZERO, 0.0)
	player.take_hit(60.0, Vector3(0.0, 0.0, -1.0), 0.0)
	_fire_wind(wind)
	await _advance(0.2)
	_expect(wind.wind_left() > 0.0, "the trial has a wind running to interrupt")
	player.take_hit(999.0, Vector3(0.0, 0.0, -1.0), 0.0)
	await _advance(0.1)
	_expect(
		wind.wind_left() <= 0.0,
		"being scruffed ends the wind -- it does not keep healing a mouse on the floor"
	)


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


## The near miss, and the leak it could have been. (M8a)
##
## THE TREMOR IS DECORATION AND THIS IS STILL AN M5 CHECK, which is the whole reason it exists.
## Ceiling dust is drawn over open corridor near a collapse -- so a Brute could stomp blindly at a
## wall and read the enemy's floor plan off where the dust landed, which is exactly the free sonar
## sweep the ability spends ten seconds refusing to be, arriving through a particle effect. A leak
## of this shape is invisible from inside a match and cannot fail any rule check that only looks at
## tunnels, because nothing about the tunnels is wrong.
##
## THE FILTER MUST BE SHOWN A CASE THE OTHER RULES WOULD HAVE PERMITTED, per the standing rule: a
## cell that IS dug, IS within the tremor radius, and is on the viewer's own plane -- everything
## except knowledge. Absence proves nothing otherwise, because a check that dug no enemy corridor
## at all would pass with the filter deleted.
func _check_tremor() -> void:
	await _arena(1)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	var player := _director.get_player()
	var cave: CaveIn = null
	if player != null:
		cave = player.get_node_or_null("CaveIn") as CaveIn
	if cave == null or player == null:
		_expect(false, "the arena has a cave-in and a player")
		return

	# The player's own corridor, and the enemy's running parallel a couple of cells over -- close
	# enough that both are inside the tremor and only knowledge separates them.
	var here := Vector2i(-17, -17)
	var mine := here + Vector2i(1, 0)
	var theirs := here + Vector2i(0, 2)
	network.dig_shaft_down(0, here)
	for cell in [here, mine]:
		network.dig(1, cell, player.team)
	network.dig(1, theirs, Team.other(player.team))
	await _advance(0.2)

	player.set_physics_process(false)
	player.global_position = network.cell_to_world(1, here) + Vector3.UP * 0.05
	player.set_plane(1)
	player.set_class(MouseClass.BRUTE)
	_aim(player, network.cell_to_world(1, mine))
	await _advance(0.3)

	var sight := _scene.get_tree().get_first_node_in_group(TunnelSight.SIGHT_GROUP) as TunnelSight
	_expect(
		sight != null and not sight.knows(player.team, 1, theirs),
		"the enemy corridor is genuinely unknown to this crew -- otherwise nothing below bites"
	)
	_expect(network.is_dug(1, theirs), "and it is genuinely there to be leaked")

	_fire(cave)
	await _advance(0.05)

	var dusted := _dusted_cells(network)
	_expect(dusted.has(mine) or dusted.has(here), "a collapse shakes dust out of nearby ceiling")
	_expect(
		not dusted.has(theirs),
		"but never over a corridor this crew has not found -- dust is not a sonar sweep"
	)


## Which cells currently have ceiling dust trickling into them, read back off the world.
##
## BY POSITION RATHER THAN BY ASKING THE ABILITY, deliberately. What leaks is what is *drawn*, so
## the check has to look at what was drawn -- a helper that reported which cells the ability
## intended to dust would agree with the ability by construction and prove nothing about the yard.
func _dusted_cells(network: TunnelNetwork) -> Dictionary:
	var found: Dictionary = {}
	for node: Node in network.get_children():
		var dust := node as CeilingDust
		if dust != null and not dust.is_queued_for_deletion():
			found[network.world_to_cell(dust.global_position)] = true
	return found


## A copy of `bytes` with its last byte replaced. For corrupting one field of a packet without
## changing its length -- which is what separates "the decoder validates this value" from "the
## decoder rejects anything the wrong size", a distinction every truncation check here already
## covers and none of them can make.
func _with_last_byte(bytes: PackedByteArray, value: int) -> PackedByteArray:
	var copy := bytes.duplicate()
	if not copy.is_empty():
		copy[copy.size() - 1] = value
	return copy


## The Engineer's other capability: a boulder in the way, and the Brute who shifts it. (M4)
##
## THREE SEPARATE THINGS HAVE TO AGREE and the audit exists because two of them are silent when
## they don't. The rock is visible, so a placement bug is obvious; the ROUTING BLOCK is not -- a
## barricade that fails to leave the graph produces a bot walking into a rock forever, which reads
## as broken AI -- and neither is the CLASS GATE on clearing it, which is the whole reason the
## Brute wants to be underground at all.
## Shore Up: the Engineer's Q, and the counterplay web's missing return edge (GDD sections 4, 5).
##
## THE ABILITY IS A TRADE OF TIME FOR ONE COLLAPSE, and every assertion here is about one side of
## that trade being real. The network's own rules -- absorbs exactly one, does not block, does not
## stack -- are asserted in `tools/tunnel_audit.gd` against the earth itself. What is checked here
## is that the ABILITY reaches them: the right class, the full three seconds, standing still, and
## the cell under your own feet rather than the one you are looking at.
##
## THE CANCEL IS THE ONE WORTH HAVING. Without it the three seconds are a formality you spend
## walking backwards out of a fight, which is the difference between a builder's ability and a
## retreat button -- and it is exactly the kind of rule that would be quietly lost to a refactor,
## because everything still *works* when a cast cannot be interrupted.
func _check_shore_up() -> void:
	await _arena(1)
	var network := _scene.get_node("Tunnels") as TunnelNetwork
	var player := _director.get_player()
	var shore: ShoreUp = null
	if player != null:
		shore = player.get_node_or_null("ShoreUp") as ShoreUp
	if shore == null or player == null:
		_expect(false, "the arena has a shore-up ability and a player")
		return

	var cell := Vector2i(-20, -20)
	network.dig_shaft_down(0, Vector2i(-22, -20))
	for x in range(-22, -17):
		network.dig(1, Vector2i(x, -20))
	await _advance(0.2)

	player.set_physics_process(false)
	var here := network.cell_to_world(1, cell) + Vector3.UP * 0.05
	player.global_position = here
	player.set_plane(1)

	# NOT EVERY CLASS, and asked of the Brute -- whose Q is the thing this ability exists to answer.
	# A gate that let everyone through would hand the counterplay to the class it counters.
	player.set_class(MouseClass.BRUTE)
	_hold_shore(shore, 3.5)
	_expect(not network.is_shored(1, cell), "a Brute cannot shore a tunnel")

	# NOT ON THE LAWN either. There is no roof up there to hold up.
	player.set_class(MouseClass.ENGINEER)
	player.global_position = Vector3(0.0, 0.05, 0.0)
	player.set_plane(0)
	_hold_shore(shore, 3.5)
	_expect(not network.is_shored(1, cell), "an Engineer on the surface shores nothing")

	# ---- the hold itself.
	player.global_position = here
	player.set_plane(1)
	_hold_shore(shore, 1.5)
	_expect(
		not network.is_shored(1, cell),
		"half the hold puts no timbers in -- the three seconds are the whole cost"
	)
	_expect(shore.progress() > 0.3, "but it is visibly under way")

	# LETTING GO ABANDONS IT, and starting again starts from nothing rather than from where the
	# last attempt got to. Otherwise the cast is three seconds of *total* attention rather than
	# three seconds of standing still, which is a different and much cheaper ability.
	_release(player)
	shore._physics_process(1.0 / 60.0)
	_expect(shore.progress() <= 0.0, "letting go abandons the hold")
	_hold_shore(shore, 1.5)
	_expect(not network.is_shored(1, cell), "and the next attempt does not resume it")

	# MOVING CANCELS IT. Driven by actually walking the mouse out of where it started, which is the
	# only version of this worth asserting -- a check that poked `_anchor` would pass against a
	# cancel rule that had been deleted.
	_release(player)
	shore._physics_process(1.0 / 60.0)
	for i in range(90):
		_intend(player, InputFrame.Action.ABILITY)
		player.global_position += Vector3(0.02, 0.0, 0.0)
		shore._physics_process(1.0 / 60.0)
	_expect(not network.is_shored(1, cell), "walking away cancels the cast")

	# ---- and the whole thing, done properly.
	player.global_position = here
	_hold_shore(shore, 3.2)
	_expect(network.is_shored(1, cell), "an Engineer standing still for three seconds shores it")
	_expect(
		Shoring.at(network, 1, cell) != null,
		"and the timbers are actually in the world, not merely in the book"
	)

	# NO COOLDOWN. The time IS the cost, so the next cell may be started the moment you reach it --
	# this is the one ability in the game with nothing to recharge, and a cooldown quietly added
	# later would price the same act twice.
	var next_cell := cell + Vector2i(1, 0)
	player.global_position = network.cell_to_world(1, next_cell) + Vector3.UP * 0.05
	_hold_shore(shore, 3.2)
	_expect(network.is_shored(1, next_cell), "and may start the next cell with no cooldown at all")

	# THE CELL YOU STAND IN, NOT THE ONE YOU AIM AT -- the deliberate difference from every other
	# aimed ability (see the header of `shore_up.gd`).
	var looked_at := cell + Vector2i(-2, 0)
	_aim(player, network.cell_to_world(1, looked_at))
	player.global_position = network.cell_to_world(1, cell + Vector2i(2, 0)) + Vector3.UP * 0.05
	_hold_shore(shore, 3.2)
	_expect(not network.is_shored(1, looked_at), "aiming elsewhere does not shore the cell you look at")
	_expect(network.is_shored(1, cell + Vector2i(2, 0)), "it shores the one under your feet")

	# ---- and the Brute spends a cooldown getting through it.
	var cave := player.get_node_or_null("CaveIn") as CaveIn
	if cave == null:
		_expect(false, "the arena has a cave-in")
		return
	player.set_class(MouseClass.BRUTE)
	player.global_position = network.cell_to_world(1, cell + Vector2i(1, 0)) + Vector3.UP * 0.05
	_aim(player, network.cell_to_world(1, cell))
	_fire(cave)
	_expect(network.is_dug(1, cell), "a cave-in on shored timbers takes no cell")
	_expect(not network.is_shored(1, cell), "but it does break the timbers")
	_expect(cave.cooldown_left() > 0.0, "and it still costs the Brute the cooldown")
	_expect(
		Shoring.at(network, 1, cell) == null,
		"and the timbers come out of the world with the book"
	)


## How far a banner is allowed to travel past the spot it first hits, in metres.
##
## THE ONE NUMBER THAT GUARDS THE TOSS'S RANGE. A thrown banner is ballistic to the cursor and then
## bounces (GDD section 4, and [method Banner.throw]), so the ability's four cells are four cells
## *plus a flop*. Stated here as a budget rather than folded into each tolerance, because the thing
## being protected is a design number: raise `Banner.bounce` and the effective range of the
## Generalist's whole ability grows, silently, and this is the only place that would object.
const BANNER_FLOP: float = 0.6


## The Generalist's banner toss: the first answer in the game to a Brute already in the doorway
## (GDD sections 4 and 5).
##
## THE ASSERTION THAT MATTERS IS THAT IT IS A PASS AND NOT A LEAP. Range and cooldown are numbers
## and will be tuned; the rule that keeps this from being a self-teleport for the banner is that
## nobody -- including the thrower -- may take it out of the air. Delete that and the ability is
## still a throw, still on ten seconds, still four cells, and quietly a completely different design.
func _check_banner_toss() -> void:
	await _arena(1)
	var player := _director.get_player()
	var throw: BannerToss = null
	if player != null:
		throw = player.get_node_or_null("BannerToss") as BannerToss
	if throw == null or player == null:
		_expect(false, "the arena has a banner toss and a player")
		return

	var theirs := _director.banner_of(Team.RED)
	player.set_physics_process(false)
	player.global_position = Vector3(0.0, 0.05, 0.0)
	player.set_plane(0)
	await _advance(0.1)

	# NOTHING IN YOUR PAWS. A key that fires on empty air would drop the banner's own state machine
	# into a throw from wherever the banner happened to be.
	player.set_class(MouseClass.GENERALIST)
	var was := theirs.global_position
	_toss(throw)
	_expect(theirs.global_position.is_equal_approx(was), "an empty-pawed toss moves nothing")
	_expect(throw.cooldown_left() <= 0.0, "and costs no cooldown")

	# NOT EVERY CLASS. Asked of the Brute, because V is the Brute's Slam key -- a gate that let it
	# through would mean every Brute shove also threw the banner it was carrying.
	theirs.take(player)
	player.set_class(MouseClass.BRUTE)
	var held_at := theirs.global_position
	_toss(throw)
	_expect(player.is_carrying(), "a Brute pressing V keeps hold of the banner")
	_expect(theirs.global_position.is_equal_approx(held_at), "and throws it nowhere")

	# ---- the throw.
	player.set_class(MouseClass.GENERALIST)
	_aim(player, player.global_position + Vector3(2.0, 0.0, 0.0))
	var from := player.global_position
	_toss(throw)
	_expect(not player.is_carrying(), "the throw takes the banner out of your paws")
	_expect(theirs.state == Banner.DROPPED, "and the banner is loose rather than in a fourth state")
	_expect(throw.cooldown_left() > 0.0, "and it costs the cooldown")

	# NOBODY CATCHES IT MID-AIR -- not the thrower, and not the Brute standing under it.
	_expect(theirs.is_airborne(), "it is in the air on the tick it was thrown")
	_expect(not theirs.may_take(player), "the thrower may not take it back out of the air")
	var waiting := _puppet(Team.BLUE, theirs.global_position)
	_expect(not theirs.may_take(waiting), "and neither may anybody else")

	await _advance(1.0)
	_expect(not theirs.is_airborne(), "it lands")
	_expect(theirs.may_take(waiting), "and is anybody's once it does")

	# SHORT OF THE CURSOR LANDS UNDER IT -- plus the flop.
	#
	# `[REVISED]` THE TOLERANCE IS ASYMMETRIC NOW, AND THAT IS THE ASSERTION. The banner is thrown
	# ballistically and then bounces, so the cursor is where it FIRST HITS and it keeps a little
	# after that (see [method Banner.throw]). A symmetric window around the aim point would either
	# have to be wide enough to hide a throw that undershot, or would fail on the flop it is
	# supposed to have. So: never short, and never more than a flop long.
	var flat := Vector2(theirs.global_position.x - from.x, theirs.global_position.z - from.z)
	_expect(
		flat.length() >= 1.9,
		"a throw inside the range reaches the cursor (%.2fm of 2.0m)" % flat.length()
	)
	_expect(
		flat.length() <= 2.0 + BANNER_FLOP,
		"and does not bounce halfway across the yard (%.2fm)" % flat.length()
	)

	# AND PAST IT IS CLAMPED RATHER THAN REFUSED, because a throw that failed for being aimed too
	# far would fail at exactly the moment somebody is panicking.
	theirs.take(player)
	throw.set("_cooldown_left", 0.0)
	_aim(player, player.global_position + Vector3(40.0, 0.0, 0.0))
	from = player.global_position
	_toss(throw)
	await _advance(1.0)
	flat = Vector2(theirs.global_position.x - from.x, theirs.global_position.z - from.z)
	var reach := throw.range_cells * TunnelNetwork.CELL
	_expect(
		flat.length() >= reach - 0.1,
		"a throw aimed past the range still goes the full range (%.2fm of %.2fm)"
			% [flat.length(), reach]
	)
	# THE FLOP IS CAPPED, and this is the line that keeps the range honest. Four cells is the
	# ability's number; if `Banner.bounce` were ever raised, the effective range would quietly grow
	# with it and nothing else in the project would notice.
	_expect(
		flat.length() <= reach + BANNER_FLOP,
		"and the bounce does not quietly extend it (%.2fm of at most %.2fm)"
			% [flat.length(), reach + BANNER_FLOP]
	)

	# THE COOLDOWN IS REAL, asked after a throw rather than by reading the field back.
	theirs.take(player)
	var parked := theirs.global_position
	_toss(throw)
	_expect(player.is_carrying(), "a second throw on cooldown is refused")
	_expect(theirs.global_position.is_equal_approx(parked), "and the banner has not moved")


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

	# The wire picture is deliberately stricter than the scene nodes: a partial complete-state
	# packet would turn absence into erasure, and owner team is part of identity because both crews
	# may scratch the same place.
	var picture := SonarState.new()
	picture.revision = 43
	# The two crews mark the same place, and each names a DIFFERENT corridor owner -- so a decoder
	# that read the owner crew twice, or defaulted the second field, has two ways to be caught.
	picture.add(Team.BLUE, 0, Vector2i(-321, 412), Team.RED)
	picture.add(Team.RED, 0, Vector2i(-321, 412), SonarMark.SHARED)
	var bytes := picture.to_bytes()
	var decoded := SonarState.from_bytes(bytes)
	_expect(
		decoded != null and decoded.revision == 43 and decoded.marks.size() == 2,
		"a complete cant picture survives its bytes"
	)
	if decoded != null and decoded.marks.size() == 2:
		_expect(
			decoded.marks[0].cell == Vector2i(-321, 412)
			and decoded.marks[0].owner_team == Team.BLUE,
			"cant keeps signed cells and its owner crew"
		)
		_expect(
			decoded.marks[1].owner_team == Team.RED,
			"opposing crews may mark the same place independently"
		)
		_expect(
			decoded.marks[0].tunnel_team == Team.RED
			and decoded.marks[1].tunnel_team == SonarMark.SHARED,
			"and each keeps whose corridor it names, separately from who scratched it"
		)
	_expect(
		SonarState.from_bytes(_with_last_byte(bytes, 7)) == null,
		"a cant picture naming an impossible corridor owner is rejected"
	)
	_expect(SonarState.from_bytes(bytes.slice(0, bytes.size() - 1)) == null,
		"a truncated cant picture is rejected rather than erasing a mark")
	var padded := bytes.duplicate()
	padded.append(0)
	_expect(SonarState.from_bytes(padded) == null,
		"and padding cannot disguise a malformed cant picture")
	var duplicate := SonarState.new()
	# The two differ in `tunnel_team` and are still the same mark, which is the point: whose
	# corridor a mark names is a property of it, not part of which mark it is.
	duplicate.add(Team.BLUE, 0, Vector2i(4, -9), Team.BLUE)
	duplicate.add(Team.BLUE, 0, Vector2i(4, -9), Team.RED)
	_expect(SonarState.from_bytes(duplicate.to_bytes()) == null,
		"one crew cannot send the same cant identity twice")
	var echo_cells: Array[Vector2i] = [Vector2i(-8, 13), Vector2i(9, -14)]
	# Two cells, two different owners. The echo's colours are read straight off this array, and it
	# is the one place a client CANNOT recompute them -- its own network has never heard of an
	# enemy corridor -- so a dropped field here would silently paint every enemy tunnel as neutral.
	var echo_owners: Array[int] = [Team.RED, SonarMark.SHARED]
	var echo := SonarState.echo_from_bytes(
		SonarState.echo_to_bytes(1, echo_cells, echo_owners)
	)
	_expect(
		not echo.is_empty() and echo["plane"] == 1 and echo["cells"] == echo_cells,
		"a private sonar shimmer keeps its plane and signed cells"
	)
	_expect(
		not echo.is_empty() and echo["owners"] == echo_owners,
		"and which crew each answering cell belongs to"
	)

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


## Hold Q for `seconds` of the ability's own clock. The one control in the game that reads a HELD
## bit rather than a pressed one, so it needs its own driver: `_fire` hands over a single tick, and
## a single tick of a three-second cast does nothing at all.
##
## TICKED IN SIXTIETHS AND NOT IN ONE LUMP, because the cancel rules are what this is really for --
## a cast fed its whole duration in a single call would never be given a chance to notice that the
## mouse moved.
func _hold_shore(shore: ShoreUp, seconds: float) -> void:
	var ticks := maxi(1, roundi(seconds * 60.0))
	for i in range(ticks):
		_intend(shore.get("_player"), InputFrame.Action.ABILITY)
		shore._physics_process(1.0 / 60.0)


## Let go of everything for one tick.
##
## AN EMPTY FRAME, NOT AN ABSENT ONE, and that distinction is what this helper exists to make. An
## [InputFrame] is state: it sits on the mouse until something replaces it, so simply *not* calling
## `_intend` leaves the last tick's keys still down. Every other ability in this file resolves on a
## pressed bit and never noticed; the shore-up hold reads a HELD bit, and a check that meant "the
## player let go" while handing it a frame with Q still down was asserting nothing.
func _release(who: Node) -> void:
	var frame := InputFrame.new()
	frame.aim_point = who.get("_aim_point")
	who.call("drive", frame)


func _toss(throw: BannerToss) -> void:
	_intend(throw.get("_player"), InputFrame.Action.TOSS)
	throw._physics_process(0.0)


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
##
## `[REVISED at M8]` THE INTRUDER IS NOW SEEN GOING DOWN, and it took a regression to notice that
## it had to be. This check used to drop the puppet straight into the corridor, having never been
## on the lawn at all -- and it passed, because bot.gd scanned the scene tree for enemies and
## ignored planes while doing it. The defender was not following anybody; it had X-ray vision
## through a metre of earth, which is the one thing `_check_spotting` asserts is impossible and the
## one thing the tunnel layer exists to prevent. Two milestones' invariants had been contradicting
## each other in the dark, and the bot's private perception model was what kept the argument quiet.
##
## So the puppet stands at the mouth in the open first, gets spotted like anything else, and then
## climbs in. What is asserted afterwards is unchanged -- the defender goes down and reaches them --
## but the knowledge now arrives by a route the game actually permits, which means this check can
## fail for the right reason. Verified by making the intruder skip the surface step and watching it
## go red.
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

	# A blue mouse ON THE LAWN, standing on the entrance, in the open and in plain view of the red
	# crew. This is the part that makes the follow legal: somebody has to watch them do it.
	var intruder := _puppet(Team.BLUE, network.cell_to_world(0, mouth))
	await _advance(0.5)
	_expect(
		_scene.get_node("Spotting").contacts_for(Team.RED).has(intruder),
		"the red crew sees the intruder before they go under"
	)

	# And down they go. The contact freezes on the mouth and starts ageing from there, which is
	# the whole of what the defender has to work with.
	intruder.global_position = network.cell_to_world(1, Vector2i(18, 20)) + Vector3.UP * 0.05
	intruder.set_plane(1)
	await _advance(0.3)
	_expect(intruder.get_plane() == 1, "the intruder is underground to begin with")
	_expect(
		not bool(
			_scene.get_node("Spotting").contacts_for(Team.RED).get(intruder, {}).get("live", false)
		),
		"and is no longer visible once they are"
	)

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


## Does the grass work on the AI? (M8)
##
## THE ONE THE PLAYER FEELS. Every other hidden-information check here is about a marker on a map;
## this is about being crouched in cover, doing everything the mechanic asks, and watching a
## defender turn round, walk over and hit you anyway. Through M7 that is exactly what happened:
## `_pick_quarry` scanned the scene tree with no concealment test of any kind, because the gate had
## been written once for the rule that produces a destination and never for the rule that produces
## a fight.
##
## STUBBED AT `opacity_of`, WHICH IS THE RIGHT SEAM. The arena's grass is stripped here (63000
## blades per scenario) and hunting for a patch dense enough to hide in would make this a test of
## where the noise field happens to be thick. What is under test is the BOT, given concealment --
## so concealment is dictated, and the grass's own job of turning stillness into opacity is left to
## grass_hiding_probe.gd where it can be looked at.
##
## SHOWN A CASE THE OTHER RULES WOULD HAVE PERMITTED, per the standing rule for anything that
## filters. The same puppet, in the same spot, on the same plane, in the open, with clear line of
## sight, is asserted to be engaged FIRST. Only opacity changes between the two halves, so a bot
## that had simply stopped noticing enemies -- or a check aimed at an empty patch of lawn -- cannot
## pass this.
func _check_bot_blind() -> void:
	await _arena(2)
	var eyes := _scene.get_node("Spotting") as Spotting
	eyes.interval = 0.05

	var veil := Node.new()
	var stub := GDScript.new()
	stub.source_code = FAKE_CAMOUFLAGE
	stub.reload()
	veil.set_script(stub)
	veil.name = "FakeCamouflage"
	_scene.add_child(veil)
	# The sweep resolves its camouflage once, in `_ready`, and this arena had none to resolve.
	eyes.set("_camouflage", veil)

	var defender := _bot(Team.RED, Bot.DEFENDER)
	if defender == null:
		_expect(false, "the red crew fielded a defender at all")
		return
	# Let it walk out to its post and settle, so the intruder is placed relative to where the bot
	# actually ends up rather than to where it spawned.
	await _advance(2.0)

	# SWINGS ARE COUNTED RATHER THAN HEALTH SAMPLED, and the difference is not pedantry. A swing
	# lands knockback, so a puppet that gets hit is a puppet that slides out of reach -- sampling
	# health at the end would show it stop dropping for the most ordinary reason in the world and
	# call that concealment. The signal fires wherever the mouse ends up.
	# IN AN ARRAY BECAUSE GDSCRIPT LAMBDAS CAPTURE LOCALS BY VALUE. A bare `int` incremented in
	# here counts perfectly, into a copy nobody reads, and the check reports zero swings forever --
	# which looks exactly like the bot correctly declining to swing.
	var swings := [0]
	defender.swung.connect(func(_who: Mouse) -> void: swings[0] += 1)

	# Right under its nose: inside the nest patch, inside STRIKE range, in the open.
	var seen := _puppet(Team.BLUE, defender.global_position + defender.get_facing_direction() * 0.45)
	await _held_in_reach(defender, seen, 1.2)
	_expect(
		eyes.contacts_for(Team.RED).has(seen),
		"the crew sees an intruder standing in the open"
	)
	_expect(defender.get("_quarry") == seen, "and the defender squares up to them")
	_expect(swings[0] > 0, "and actually swings at them (%d)" % swings[0])

	# Now the only thing that changes. Deep cover, perfectly still: a tenth of an opacity, well
	# under spotting.gd's `reveal_opacity`.
	#
	# HELD IN REACH FOR THIS HALF TOO. A bot that stopped hitting a mouse it can no longer reach
	# would prove nothing at all. Same offset, same plane, same clear line of sight -- opacity is
	# the only difference between the two halves.
	veil.set("opacity", {seen: 0.1})
	swings[0] = 0
	await _held_in_reach(defender, seen, 1.5)

	_expect(
		not bool(eyes.contacts_for(Team.RED).get(seen, {}).get("live", true)),
		"a concealed intruder stops being a live contact"
	)
	_expect(defender.get("_quarry") == null, "the defender stops squaring up to them")
	# THE ONE A PLAYER WOULD RECOGNISE. Everything above it is bookkeeping; this is whether you get
	# hit while you are hiding.
	_expect(swings[0] == 0, "and stops swinging at them (%d swings while concealed)" % swings[0])


## Can every mouse change gear? (M8)
##
## THE LADDER MOVED, AND THAT IS THE WHOLE OF THIS CHECK. Sprint and Slow lived on `Player`, so
## three quarters of the mice in any match ran at one fixed speed -- a human could outrun a
## defender indefinitely, and could crouch past an AI that had no concept of crouching. Asserted on
## a plain `Mouse` rather than through a bot's ranking, because what must hold is that the ladder is
## a property of a mouse; which rule climbs it is bot.gd's business and changes with tuning.
##
## THE REFUSAL IS THE PART WORTH ASSERTING. A sprint that never runs out is a different game, and
## an empty tank that still grants one is invisible from inside a match -- you would simply never
## notice you were not slowing down.
func _check_gears() -> void:
	await _arena(1)
	var mouse := _puppet(Team.BLUE, Vector3(0.0, 0.2, 0.0))
	mouse.set_class(MouseClass.GENERALIST)
	var walk := mouse.move_speed()

	mouse.request_sprint(true)
	_expect(mouse.is_sprinting(), "a mouse with a full tank may sprint")
	_expect(mouse.move_speed() > walk, "and sprinting is faster than walking")

	# SLOW BEATS SPRINT. You cannot be quiet and fast -- the tier says so, and grass_camouflage.gd
	# reads the resulting speed to decide how visible you are, so a mouse that could hold both would
	# be sprinting at a tenth opacity.
	mouse.set_creeping(true)
	_expect(mouse.move_speed() < walk, "slow beats sprint while both are set")
	mouse.set_creeping(false)

	# Run the tank dry. `_tick_stamina` is driven by the physics tick, so this is real seconds of
	# sprinting rather than a number poked into a field.
	var ran := 0.0
	for i in range(1200):
		mouse.request_sprint(true)
		await physics_frame
		ran += get_root().get_process_delta_time()
		if not mouse.is_sprinting():
			break
	_expect(not mouse.is_sprinting(), "a sprint ends when the tank runs out (after %.1fs)" % ran)
	_expect(
		mouse.get_stamina_ratio() < 0.01,
		"and the tank really is empty (%.2f)" % mouse.get_stamina_ratio()
	)

	# THE REFUSAL. Asking again on fumes must not grant it, or a mouse stutter-sprints forever.
	mouse.request_sprint(true)
	_expect(not mouse.is_sprinting(), "and asking again on an empty tank is refused")
	_expect(is_equal_approx(mouse.move_speed(), walk), "so it is back to a walk")

	# And it comes back after a quiet spell, or the mechanic is one-shot.
	for i in range(600):
		await physics_frame
		if mouse.get_stamina_ratio() > 0.5:
			break
	_expect(mouse.get_stamina_ratio() > 0.5, "stamina refills after a quiet spell")
	mouse.request_sprint(true)
	_expect(mouse.is_sprinting(), "and the mouse may sprint again")

	# PER CLASS, which is the reason the dial is on the definition at all (GDD section 9): sprint
	# SPEED is uniform and duration is what differs.
	mouse.set_class(MouseClass.SNEAK)
	var nimble := mouse.sprint_seconds
	mouse.set_class(MouseClass.BRUTE)
	_expect(
		nimble > mouse.sprint_seconds,
		"a Sneak sprints longer than a Brute (%.1fs vs %.1fs)" % [nimble, mouse.sprint_seconds]
	)

	# AND SOMEBODY ACTUALLY CLIMBS IT. The ladder existing on `Mouse` proves nothing on its own --
	# what was missing was a bot that uses it, and a refactor that moved the code without wiring the
	# rule would pass every assertion above.
	#
	# BOTH HALVES, because "slow" and "always slow" are very different bots and only one of them is
	# right. Slow that buys no concealment is just slow, so a raider on bare lawn must walk normally;
	# the same raider with cover under it must drop its pace. Only the ground changes between them.
	await _arena(2)
	var eyes := _scene.get_node("Spotting") as Spotting
	var veil := Node.new()
	var stub := GDScript.new()
	stub.source_code = FAKE_CAMOUFLAGE
	stub.reload()
	veil.set_script(stub)
	veil.name = "FakeCamouflage"
	_scene.add_child(veil)
	eyes.set("_camouflage", veil)

	var raider := _bot(Team.RED, Bot.RAIDER)
	if raider == null:
		_expect(false, "the red crew fielded a raider at all")
		return
	raider.think_seconds = 0.05

	veil.set("cover", 0.0)
	await _advance(0.5)
	_expect(not raider.is_creeping(), "a raider on open lawn walks at its normal pace")

	veil.set("cover", 1.0)
	await _advance(0.5)
	_expect(raider.is_creeping(), "and goes quiet once there is cover worth using")


## Do bots play the cheese economy on purpose? (M8)
##
## THEY DID NOT, AND IT WAS A REAL GAP RATHER THAN A MISSING FLOURISH. Cheese is the crew's lives
## (GDD section 2) and the whole of it is a walk: take a wedge, carry it home, put it in the pile.
## Bots picked wedges up by treading on them and never went to get any, never banked the ones they
## had, and dropped them again on the next scruffing -- so an AI crew played the economy entirely by
## accident, and a bot crew facing a human one was playing a different game with the same rules.
##
## THREE SEPARATE CLAIMS, because they fail separately: it FETCHES, it BANKS, and the decision
## LATCHES. The last is the one nothing else would catch -- a bot that re-reads a bare threshold
## banks one wedge, decides the crisis is over, walks off, and leaves the crew exactly where it
## started. It is the same jitter that killed the first dynamic class rule, and the only visible
## symptom is a crew that never quite recovers.
func _check_bot_cheese() -> void:
	await _arena(2)
	var raider := _bot(Team.RED, Bot.RAIDER)
	if raider == null:
		_expect(false, "the red crew fielded a raider at all")
		return
	raider.think_seconds = 0.05

	# The only pile on the map is the one this check places. The arena authors six of its own and a
	# bot walking to the nearest of THOSE would pass a check that had asserted nothing.
	for node in get_nodes_in_group(CheeseCache.GROUP):
		node.free()
	await _advance(0.1)

	# A crew that is not poor does not shop. Asserted FIRST, because every claim below is about a
	# bot leaving its errand, and one that had simply abandoned raiding would satisfy them all.
	await _advance(0.3)
	_expect(
		raider.get_intent() != "fetching cheese",
		"a crew with a full pile stays on the banner (%s)" % raider.get_intent()
	)

	# Now make it poor. The dial moves rather than the pile, so nothing has to reach inside the
	# director's ledger to set up the case.
	raider.forage_below = _director.cheese_of(Team.RED) + 5
	raider.forage_until = raider.forage_below + 10

	var pile := CheeseCache.new()
	pile.wedges = 4
	pile.position = raider.global_position + Vector3(3.0, 0.0, 0.0)
	_scene.add_child(pile)
	await _advance(0.3)
	_expect(raider.get_intent() == "fetching cheese", "a poor crew sends a raider shopping")

	# It gets there and picks one up.
	var fetched := false
	for i in range(600):
		await physics_frame
		if raider.get_carried_cheese() > 0:
			fetched = true
			break
	_expect(fetched, "and the raider reaches the pile and takes a wedge")

	# Lift the crew clear of the trigger while the wedge is still in its paws, so the two claims
	# below are made against a crew that a bare threshold would call recovered.
	_director.gain_cheese(Team.RED, 6)
	_expect(
		_director.cheese_of(Team.RED) > raider.forage_below,
		"the test really did lift the crew past the trigger"
	)

	# THE RANKING'S ORDER, not hysteresis: banking sits above shopping, so a full-pawed bot converts
	# what it has before starting anything else.
	await _advance(0.3)
	_expect(
		raider.get_intent() == "banking a wedge",
		"a raider holding a wedge banks it before anything else (%s)" % raider.get_intent()
	)

	# And the wedge actually lands in the pile, which is the only thing about any of this that
	# changes the score.
	var before := _director.cheese_of(Team.RED)
	var banked := false
	for i in range(900):
		await physics_frame
		if _director.cheese_of(Team.RED) > before:
			banked = true
			break
	_expect(banked, "and the wedge reaches the crew's stores")

	# HYSTERESIS, AND THIS IS THE ONLY PLACE THE TWO IMPLEMENTATIONS DISAGREE. Empty-pawed again,
	# with the crew now sitting ABOVE `forage_below` and still short of `forage_until`: a bot that
	# re-reads the threshold raw declares the crisis over and walks back to the banner, and a
	# latching one goes and gets another wedge.
	#
	# It has to be asserted here rather than while the bot was carrying, because banking outranks
	# shopping -- the earlier version of this check made the claim one rule too early and passed
	# against both implementations, which is the failure this file keeps naming.
	_expect(
		_director.cheese_of(Team.RED) > raider.forage_below,
		"the crew is past the trigger once the wedge is banked"
	)
	_expect(
		_director.cheese_of(Team.RED) < raider.forage_until,
		"and not yet at the point it is shopping toward"
	)
	# EITHER CHEESE INTENT COUNTS, because the pile is three metres away and a bot that kept going
	# may already be carrying the next wedge by the time this is read. Both mean "still on the
	# refill"; the implementation being ruled out says "going for their banner", which is neither.
	await _advance(0.4)
	var errand := raider.get_intent()
	_expect(
		errand == "fetching cheese" or errand == "banking a wedge",
		"a crew mid-refill keeps going rather than stopping at the first wedge (%s)" % errand
	)


## Whose holes may a crew's route use? (M8)
##
## THE SAME LEAK AS EVERY OTHER ONE IN THIS FILE, wearing walking boots. M5 spent a milestone
## making sure a crew's minimap, cutaway and sonar only ever show tunnels that crew has earned --
## and route_planner.gd was quietly building plans out of `graph.mouths()`, which is every entrance
## on the map. A bot could not SEE the enemy's shaft, and would walk into it anyway.
##
## SHOWN A CASE THE OTHER RULES WOULD HAVE PERMITTED, per the standing rule. The enemy shaft here
## is not merely unknown -- it is dug, open, connected, on the right plane, and lands the bot far
## nearer its errand than the surface walk does. Every reason to take it is present except the one
## that matters, so a planner that had simply stopped finding routes cannot pass: the crew's OWN
## mouth, set up identically, is asserted to be used.
##
## ASKED OF THE PLANNER RATHER THAN WATCHED IN A SOAK, deliberately. A bot declining to use a hole
## is indistinguishable from a bot that happened to prefer the grass that minute, and a leak that
## only shows up on the runs where the geometry lines up is one that passes review forever.
func _check_bot_routes() -> void:
	await _arena(2)
	var network := _scene.get_node("Tunnels") as TunnelNetwork

	# A corridor RED cut, running most of the way across the yard. Nothing blue did or saw.
	var theirs := Vector2i(6, 6)
	network.dig_shaft_down(0, theirs, Team.RED)
	for step in range(1, 14):
		network.dig(1, theirs + Vector2i(step, 0), Team.RED)
	network.dig_shaft_up(1, theirs + Vector2i(13, 0), Team.RED)
	await _advance(0.2)

	_expect(
		not network.known_shaft_cells(0, Team.BLUE).has(theirs),
		"the blue crew does not know about the red entrance"
	)
	_expect(
		network.known_shaft_cells(0, Team.RED).has(theirs),
		"and the red crew does"
	)

	var from := network.cell_to_world(0, theirs)
	var to := network.cell_to_world(0, theirs + Vector2i(13, 0))

	# The route red would take, and the same route asked for on blue's behalf.
	var red_plan := RoutePlanner.plan(network, from, 0, to, 0, 0.7, Team.RED)
	var blue_plan := RoutePlanner.plan(network, from, 0, to, 0, 0.7, Team.BLUE)

	_expect(not red_plan.is_empty(), "the crew that dug it routes through its own tunnel")
	_expect(
		blue_plan.is_empty(),
		"the other crew does not (got %d waypoints)" % blue_plan.size()
	)

	# AND THE MOMENT BLUE GENUINELY FINDS IT, IT MAY USE IT -- by the real mechanism, a mouse
	# walking within sight of the hole, not by a flag set in the test. Knowledge is the only thing
	# standing between the two answers above, so this check is worth nothing unless knowledge can
	# actually arrive: a filter that never opens is indistinguishable from routing being broken.
	var sight := _scene.get_node("TunnelSight") as TunnelSight
	sight.interval = 0.05
	var scout := _puppet(Team.BLUE, from + Vector3(2.0, 0.0, 0.0))
	await _advance(0.5)
	_expect(
		sight.seen_mouths(Team.BLUE).has(theirs),
		"a blue mouse standing next to the hole notices it"
	)
	_expect(
		not RoutePlanner.plan(network, from, 0, to, 0, 0.7, Team.BLUE).is_empty(),
		"and the crew may route through it once they have"
	)
	_expect(scout.get_plane() == 0, "the scout stayed on the lawn")


## Hold a puppet at arm's length in front of a bot, so what `bot_blind` measures is the swing GATE
## and never the geometry.
##
## A mouse that stands its ground next to a bot settles just OUTSIDE `strike_radius` -- 0.78m
## against a reach of 0.75 -- because the walker stops an `arrival_slack` short of its goal and the
## two collision capsules hold the rest. That is true of the real game and has nothing to do with
## concealment, but left alone it makes both halves of the check read "no swings" and pass for a
## reason the check is not about: the textbook version of an assertion that cannot fail.
func _held_in_reach(bot: Bot, puppet: Mouse, seconds: float) -> void:
	for i in range(maxi(1, int(ceilf(seconds * 60.0)))):
		puppet.global_position = bot.global_position + bot.get_facing_direction() * 0.45
		await physics_frame


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
	#
	# `[REVISED]` ASKED OF THE BRUTE'S CURSOR RATHER THAN THE DIGGER'S, because the digger no
	# longer has one: holding dig draws itself in the world now (the paws scrabble, the face sheds
	# earth) and the hover box was removed with it. Left pointed at `DigController` these two lines
	# did not fail loudly -- the first one did, and the SECOND would have gone on passing forever,
	# because a field that no longer exists reads as null on both mice. A check whose negative half
	# cannot fail is worse than no check, so the invariant moved to a control that still has a
	# per-viewer cursor rather than being quietly deleted with the thing it used to watch.
	#
	# [CaveIn] builds its cursor from `_process` on any watched mouse, before it looks at class or
	# plane, which is what makes it a fair subject here: nothing about this scenario has to be
	# arranged for it, exactly as nothing had to be for the dig.
	await _advance(0.4)
	var my_reach := player.get_node("CaveIn")
	var their_reach := remote.get_node("CaveIn")
	_expect(my_reach.get("_cursor") != null, "so a cursor is built for the mouse on screen")
	_expect(their_reach.get("_cursor") == null, "and never for the one that is not")


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
