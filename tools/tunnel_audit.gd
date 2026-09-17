extends SceneTree
## Invariant audit for the tunnel network. Finds the holes instead of falling through them.
##
##   godot --headless --path . --script tools/tunnel_audit.gd
##
## Every "I fell out of the world" bug has been found by playing until it happened, then
## reasoning backwards about which face failed to get a wall. That doesn't scale: the network
## gains new ways to have gaps every time it grows, and the bad configurations are exactly the
## ones a human wouldn't think to try. So state the invariants once, build the awkward
## configurations deliberately, and let the machine check them.
##
## The invariants, and what each one is really protecting:
##
##   SHAFT_ENDS      Both ends of every shaft are somewhere you can stand.
##   NO_STACK        No cell has a shaft above AND below it. This is what keeps E a single
##                   key with a single destination, and what stops a well being drilled
##                   straight from the lawn to the bottom.
##   SHAFT_SPACING   No two shaft mouths within the exclusion radius of each other on the
##                   same plane. NO_STACK stops the well going straight down; this stops it
##                   going down a 2x2 staircase instead, and keeps each beam of daylight a
##                   distinct "the way out is HERE" rather than one merged bright patch.
##   PLANE_LAYERS    Each plane's collision is on its own layer, so a mouse only ever meets
##                   the geometry of the layer it's standing on.
##   REACHABLE       Every dug cell can be got to from a surface entrance. A rule about what
##                   DIGGING may leave behind, not about the network at all times: the Engineer's
##                   cave-in strands cells on purpose, which is asserted on its own terms in
##                   `_check_collapse` and kept out of the scenarios above.
##   BOUNDS          No cell outside the diggable arena.
##   FLOOR_PHYSICS   Something solid exists under every dug cell, at the height the renderer
##                   claims. Guards the render/collision split.
##   HEADROOM        The mouse fits, standing, in every cell it can dig.
##   CONTAINMENT     From every dug cell, anywhere the player's own capsule can actually
##                   slide to has ground under it. This is the fall-out-of-the-world check,
##                   and it is deliberately the one that asks the PHYSICS ENGINE rather than
##                   the cell data -- every other check can only find mistakes I already know
##                   how to describe.
##
## Four invariants RETIRED with ramps: RAMP_PAIRS, RAMP_ENDS, OPEN_FACES and VERTICAL. Each
## guarded a hazard that only sloped, two-cell, downward-hanging geometry could create. They
## weren't fixed, they became unrepresentable.
##
## Exit code is non-zero if any invariant fails, so this can gate a commit.

## Nodes stripped from the scene before auditing. The ground slab and the perimeter walls must
## stay -- they are load-bearing for containment. Everything else is either irrelevant or
## actively in the way: the rock scatter's colliders would BLOCK containment casts and quietly
## turn a real hole into a pass, and a live player wandering the arena makes it non-deterministic.
## WRITTEN OUT IN FULL, and it has to stay that way. This was `[...] + STRIP_MATCH`, and adding
## two `Array[String]`s in GDScript produces an UNTYPED `Array` -- which, passed to a parameter
## declared `Array[String]`, aborts the call at runtime. `_arena` then returned null, every check
## below quietly did nothing to a null network, and all fourteen scenarios reported "ok" while
## testing precisely nothing. The dig-flow check passed STRIP_MATCH directly and was the only
## honest line in the file.
##
## The type is half the fix. The other half is in `_fresh_network`: a harness that cannot build
## its subject must say so, not fall through to a clean bill of health.
##
## `DigController` LEFT THIS LIST AT M7 rather than being forgotten in it. The five controls are
## children of a mouse now, so stripping `Player` takes its dig controller, both Engineer abilities,
## the sonar and the swap point with it -- and a strip list naming a node that cannot exist is a
## line that looks like it is doing work.
const STRIP: Array[String] = [
	"Player", "CameraRig", "DepthFocus", "FallGuard", "HUD", "Surface/Rocks",
	"MatchDirector", "Navigation", "Nests"
]

## The flag game, stripped from every scenario including the dig-flow one. Bots would wander
## through the containment probes and make them non-deterministic, and the navmesh bake costs
## real time fifteen times over. None of it has anything to say about tunnel geometry --
## tools/match_audit.gd is where the match rules are checked.
const STRIP_MATCH: Array[String] = ["MatchDirector", "Navigation", "Nests"]

const REACH: float = 0.7
const MAX_DROP: float = TunnelChunks.PLANE_SPACING + 0.3
## How far ABOVE the landing spot to start the downward ray. Every floor is flush with every
## other now, so this only has to clear the capsule's own resting offset.
const RAY_RISE: float = 0.3
## Step along a containment path. Well under the capsule's 0.16 radius, so nothing thin can
## slip between two samples.
const STEP: float = 0.05
## A settled body rests a hair above the floor rather than embedded in it. Without this every
## cell reports as crushed, because a capsule whose lowest point is exactly on a zero-thickness
## trimesh quad counts as intersecting it.
const STAND_EPSILON: float = 0.02

var _findings: Array[String] = []
var _scene: Node
var _network: TunnelNetwork
var _space: PhysicsDirectSpaceState3D
var _total_failures: int = 0
## Checks that have started and not yet reported. A TRIPWIRE, and it exists because of a specific
## two-milestone silence.
##
## `_check_dig_flow` drove the dig controller by calling `_update_dig(delta)`.
## M7 step 2 gave that function a second parameter -- the intent has to be a value that can travel
## -- and nothing told the two callers. A GDScript runtime error ABORTS THE FUNCTION IT HAPPENS IN
## and lets the caller carry on, so both checks stopped part way through, printed nothing, and this
## file went on announcing *"ALL INVARIANTS HOLD ... plus dig flow ... and rock"* for two
## milestones over two checks that had not run a single assertion.
##
## Which is the fifth time this project has caught a test that could not fail, and a new cause each
## time. Not a weak assertion, not a subject arranged so the rule could not bite, not a favourable
## accident of timing: **a signature changed under a caller, in a suite whose failure mode is to go
## quiet.** `_fresh_network` already refuses to fall through to a clean bill of health when its own
## scaffolding breaks; this is the same idea one level up, for the checks that build their own.
var _running: Dictionary = {}


func _initialize() -> void:
	var scenarios: Array = [
		["entrance_and_corridor", _build_entrance_and_corridor],
		["descend_to_the_bottom", _build_descend_to_the_bottom],
		["climb_back_up", _build_climb_back_up],
		["stacked_shaft_refused", _build_stacked_shaft_refused],
		["shaft_without_floor", _build_shaft_without_floor],
		["shaft_from_deepest_plane", _build_shaft_from_deepest_plane],
		["corridor_under_own_entrance", _build_corridor_under_own_entrance],
		["stacked_corridors", _build_stacked_corridors],
		["shaft_over_existing_corridor", _build_shaft_over_existing_corridor],
		["corridor_to_every_boundary", _build_corridor_to_every_boundary],
		["shaft_at_boundary", _build_shaft_at_boundary],
		["wide_chamber", _build_wide_chamber],
		["two_entrances", _build_two_entrances],
		["crowded_entrances_refused", _build_crowded_entrances_refused],
		["collapsed_dead_end", _build_collapsed_dead_end],
	]

	for scenario: Array in scenarios:
		var label: String = scenario[0]
		if not await _fresh_network():
			_broken(label, "the arena would not build -- nothing in this scenario was tested")
			continue
		(scenario[1] as Callable).call()
		for i in range(3):
			await process_frame
			await physics_frame
		_audit(label)

	for label: String in [
		"dig_flow", "routing", "collapse", "shoring", "rock", "surfacing", "paving", "clutter"
	]:
		_running[label] = true
	await _check_dig_flow()
	await _check_routing()
	await _check_collapse()
	await _check_shoring()
	await _check_rock()
	await _check_surfacing()
	await _check_seal()
	await _check_clutter()

	# Anything still armed never reached its own report line. See `_running`.
	for label: String in _running.keys():
		_broken(label, "the check stopped part way -- look for a SCRIPT ERROR above")

	print("")
	print("=".repeat(78))
	if _total_failures == 0:
		print("ALL INVARIANTS HOLD across %d scenarios, plus dig flow, routing, collapse,"
			% scenarios.size() + " shoring, rock, surfacing, paving and clutter.")
	else:
		print("%d failures across %d scenarios plus dig flow, routing, collapse, shoring, rock,"
			% [_total_failures, scenarios.size()] + " surfacing, paving and clutter.")
	print("=".repeat(78))
	quit(1 if _total_failures > 0 else 0)


## A brand new scene per scenario. Sharing one would let an earlier scenario's cells leak into
## a later one's audit, and the whole point is knowing which build broke what.
##
## The REAL scene, not a bare TunnelNetwork. A bare network has no ground slab, so containment
## on the surface is meaningless and the lawn -- which is plane 1's ceiling, and once crushed
## the mouse flat -- would never be tested at all.
## Returns whether there is anything to audit. CHECKED BY EVERY CALLER, because the alternative
## is what this file did for its whole life so far: build nothing, check nothing, print ok.
## A test that cannot fail loudly when its own scaffolding breaks is worse than no test, since it
## also stops anyone looking.
func _fresh_network() -> bool:
	if _scene != null:
		_scene.free()
		_scene = null
	_scene = _arena(STRIP)
	if _scene == null:
		return false
	_network = _scene.get_node_or_null("Tunnels") as TunnelNetwork
	if _network == null:
		return false
	await process_frame
	await physics_frame
	_space = _scene.get_viewport().world_3d.direct_space_state
	return _space != null


## The arena, with the named nodes removed BEFORE it enters the tree.
##
## Before, not after, and that ordering is load-bearing now that there is a match in the scene:
## a node that has already readied has done whatever it does. The director spawns its bots as
## its own SIBLINGS, so freeing it afterwards leaves two mice wandering through every
## containment probe -- which is exactly the kind of non-determinism this file exists to avoid.
func _arena(strip: Array[String], rock: bool = false, obstructions: bool = false) -> Node:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	for path: String in strip:
		var node: Node = scene.get_node_or_null(path)
		if node != null:
			node.free()
	# ROCK OFF BY DEFAULT, and set before the scene enters the tree because the seams are laid in
	# the network's `_ready`. Every scenario below digs at hand-picked coordinates; a seeded seam
	# across one of them would fail a geometry invariant for a reason that is not about geometry.
	# `_check_rock` turns it back on and is the only place that wants it.
	if not rock:
		(scene.get_node("Tunnels") as TunnelNetwork).rock_density = 0.0
	# THE MAP'S OWN OBSTRUCTIONS GO TOO, always, for the same reason and with more force. Every
	# scenario below digs and sinks shafts at hand-picked coordinates; a patio authored across one
	# of them, or a boulder sitting on one, would fail SHAFT_ENDS or REACHABLE identically every
	# run, and the cause would be a level decision rather than anything about geometry. Stripped by
	# TYPE rather than by path, so a map that gains a second patio or moves its boulders cannot
	# quietly re-break fifteen scenarios. The checks that care place their own.
	#
	# `obstructions` KEEPS THEM, and exactly one check wants that: `_check_headroom`, whose whole
	# subject is the clutter everybody else removes. See its own header -- a suite that strips the
	# rock scatter fifteen times because its colliders get in the way is a suite that will never
	# notice those colliders are in the way of a tunnel.
	if not obstructions:
		for node in _obstructions(scene):
			node.free()
	root.add_child(scene)
	return scene


## Everything a MAP puts in the way, as opposed to everything a player does. Recursive and by type,
## because the alternative is a list of node paths that goes stale the first time somebody drags
## something into a different parent -- and goes stale silently, since a path that matches nothing
## is not an error here, it is fifteen scenarios quietly testing a different arena.
func _obstructions(node: Node) -> Array[Node]:
	var found: Array[Node] = []
	if node is NoSurfaceZone or node is BoulderField:
		found.append(node)
	for child in node.get_children():
		found.append_array(_obstructions(child))
	return found


## Does aiming at a tile and holding the button actually open it?
##
## Every other check in this file inspects a network somebody built by calling dig() directly.
## None of them would notice if the CONTROLS were broken -- if the reach test rejected every
## cell, or progress never accumulated, or the target reset each frame. That is a whole half of
## the feature living with no coverage at all, and it is the half the player touches.
##
## Driven by calling the controller's own update rather than by faking mouse input, because
## warping a cursor and unprojecting a camera in a headless run tests the harness more than the
## game. The aim point is set directly and the player and controller are taken off physics
## processing first, so nothing overwrites it behind us.
func _check_dig_flow() -> void:
	if _scene != null:
		_scene.free()
	_scene = _arena(STRIP_MATCH)
	await process_frame
	await physics_frame

	var network: TunnelNetwork = _scene.get_node("Tunnels")
	var player: Mouse = _scene.get_node("Player")
	# ON THE MOUSE, NOT ON THE ARENA (M7). The five controls are children of whoever is driving,
	# so that a remote human's chair carries its own -- see `mouse_controls.gd`.
	var controller: Node = player.get_node("DigController")
	network.dig_shaft_down(0, Vector2i(0, 0))
	await process_frame
	await physics_frame

	player.set_physics_process(false)
	controller.set_physics_process(false)
	player.global_position = network.cell_to_world(1, Vector2i(0, 0)) + Vector3.UP * 0.05
	controller._plane = 1

	_findings.clear()
	var neighbour := Vector2i(0, 1)
	var far := Vector2i(0, 9)

	# Adjacent, within reach, undug: ONE FRAME of a press opens it, for anybody.
	#
	# `[REVISED]` THE FIRST STROKE IS FREE AND INSTANT, AND THAT IS THE DESIGN RATHER THAN A HOLE IN
	# IT. Digging used to charge for a stroke before giving it -- hold for `dig_seconds`, receive a
	# metre -- so the class spread was visible in the very first tile and this check could read it
	# there. The press now cuts at once and the cost is the recharge afterwards, which moves the
	# spread from the first stroke to every stroke after it. Same ground per minute, same ratio
	# between the classes, asked one stroke further along.
	player.set_class(MouseClass.ENGINEER)
	_hold_dig(player, controller, network.cell_to_world(1, neighbour), 1)
	if not network.is_dug(1, neighbour):
		_fail("DIG_FLOW", "one press did not open the tile it was aimed at")

	# Out of reach: must stay shut no matter how long you hold.
	_hold_dig(player, controller, network.cell_to_world(1, far), 60)
	if network.is_dug(1, far):
		_fail("DIG_FLOW", "a tile %s cells away was diggable" % far.length())

	# Not holding: nothing opens however long you point at it.
	var another := Vector2i(1, 0)
	_hold_dig(player, controller, network.cell_to_world(1, another), 40, false)
	if network.is_dug(1, another):
		_fail("DIG_FLOW", "a tile opened without the dig button held")

	# A CLIENT CANNOT CUT EARTH, however hard it holds (M7). TWO GUARDS, ASSERTED SEPARATELY, and
	# that separation is the result of getting it wrong first: the original version made one claim
	# covering both, was verified by deleting the network's guard and failed correctly, and then
	# was verified by deleting the CONTROLLER's guard and passed. Of course it did -- with the
	# network still refusing, a controller that reaches for the earth and a controller that does
	# not are indistinguishable from the outside. Two guards need two subjects.
	var mine := Vector2i(-1, 0)
	player.set_class(MouseClass.ENGINEER)
	# CUMULATIVE, SO IT IS READ AS A DELTA. `cells_cut` counts everything this controller has opened
	# since the scene was built, and the checks above have opened plenty.
	var claimed: int = controller.cells_cut()
	player.set_puppet(true)
	network.set_puppet(true)
	_hold_dig(player, controller, network.cell_to_world(1, mine), 60)

	# The invariant itself. LABELLED AS UNABLE TO FAIL ON ITS OWN, because the guard that makes it
	# true is the network's and the line below tests that directly -- it stays because it is the
	# sentence the feature is about, and because it would catch a control that found some other
	# road to the cell books.
	if network.is_dug(1, mine):
		_fail("DIG_FLOW", "a client opened a cell of earth for itself")
	# One: the network refuses anyone who reaches for it. This is the guard that covers all five
	# things that cut earth and the only one that would stop a caller nobody has written yet, so
	# it is asked of the network rather than through a control.
	if network.dig(1, mine, Team.BLUE):
		_fail("DIG_FLOW", "the network let something cut earth on a client")
	# Two: the controller does not reach for the earth, which is visible in what it CLAIMS rather
	# than in the ground -- the network's refusal above would hide a controller that tried.
	if controller.cells_cut() != claimed:
		_fail("DIG_FLOW", "a client's controller counted a cut it cannot have made")

	# `[REVISED]` AND IT DOES NOT BANK STROKES WHILE IT WAITS. Under the held bar the invariant here
	# was the opposite one -- a puppet sat at FULL and waited, because zeroing would have re-filled
	# the bar during the round trip and read as a dig that did not take. A recharge has no such
	# problem and the honest rule is the simpler one: a client's controls work exactly like
	# everybody's, and only the earth is not its to move.
	#
	# READ ONE FRAME AFTER A PRESS, from a charge deliberately refilled first, because that is the
	# only moment the answer cannot be two things. Asked at the end of a long hold it depends on
	# whether the frame count happens to divide by the cooldown, which is a check that passes or
	# fails on arithmetic nobody meant to assert.
	_hold_dig(player, controller, network.cell_to_world(1, mine), 90, false)
	if controller.get_dig_charge() < 1.0:
		_fail("DIG_FLOW", "a client's recharge did not refill with the button up")
	_hold_dig(player, controller, network.cell_to_world(1, mine), 1)
	if controller.get_dig_charge() >= 1.0:
		_fail("DIG_FLOW", "a client's press cost no recharge -- it banks strokes while it waits")

	network.set_puppet(false)
	player.set_puppet(false)
	_hold_dig(player, controller, network.cell_to_world(1, mine), 60)
	if not network.is_dug(1, mine):
		_fail("DIG_FLOW", "and could not dig again once it was the authority")
	if controller.cells_cut() <= claimed:
		_fail("DIG_FLOW", "and the cut it made once it was the authority went uncounted")

	# THE SPREAD, WHICH IS THE WHOLE POINT OF THE CLASS. Everybody can dig; the Engineer is about
	# three times faster (GDD section 4, revised -- see the note there). Both halves are asserted
	# because both are design: a Generalist must NOT keep up with an Engineer, or the Engineer is
	# decorative -- and must get through eventually, or a crew that loses its Engineer is locked out
	# of a third of the map.
	#
	# MEASURED AS THE GAP BETWEEN TWO STROKES, which is where the spread lives now and the only
	# place it can be read from the ground.
	#
	# AND LAST IN THE CHECK, WHICH IS LOAD-BEARING. This is the only part that runs a CORRIDOR rather
	# than opening one tile, and a corridor claims a cell every metre of the way -- including, on any
	# heading, the ring of cells the checks above need to find as solid earth. Put in the middle it
	# turned "a tile opened without the dig button held" and "a client opened a cell for itself" into
	# passes for the wrong reason, both of them reporting a cell some earlier check had dug. Nothing
	# below reads the ground, so the scribbling belongs at the end.
	var fast := _stroke_gap(player, controller, network, MouseClass.ENGINEER, Vector3(1.5, 0.0, 1.5))
	var plodding := _stroke_gap(
		player, controller, network, MouseClass.GENERALIST, Vector3(-1.5, 0.0, -1.5)
	)
	if fast < 0 or plodding < 0:
		_fail("DIG_FLOW", "a held button did not produce two strokes: %d and %d" % [
			fast, plodding
		])
	elif plodding <= fast:
		_fail("DIG_FLOW", "a Generalist recharged as fast as an Engineer: %d frames against %d" % [
			plodding, fast
		])


	player.set_physics_process(true)
	controller.set_physics_process(true)

	print("")
	_running.erase("dig_flow")
	print("-- dig_flow")
	if _findings.is_empty():
		print("   ok")
		return
	for finding: String in _findings:
		print("   FAIL %s" % finding)
	_total_failures += _findings.size()


## Frames between one stroke and the next, for a class leaning on the dig button.
##
## THE COOLDOWN, MADE OBSERVABLE. The class spread used to show up in how long the FIRST tile took;
## the first stroke is instant for everybody now, so the only place left to read it from the ground
## is the gap to the second one.
##
## COUNTED FROM THE FIRST STROKE THIS CLASS CUTS, not from the first frame, because the recharge is
## the digger's and survives a class swap: the previous class may well have left one running, and
## the wait it bought is not this one's to be measured by.
func _stroke_gap(
	player: Mouse, controller: Node, network: TunnelNetwork, mouse_class: int, at: Vector3
) -> int:
	player.set_class(mouse_class)
	at.y = network.plane_y(1)
	var seen := network.segment_count(1)
	var first := -1
	for i in range(400):
		# THE DIGGER WALKS ITS OWN CORRIDOR, which it did not have to do when `dig_reach` was 2.6
		# and does now. A stroke may only start within arm's length of the mouse, and opening one
		# puts the next face a metre further on -- so a mouse rooted to the spot gets exactly one
		# stroke and then stands there holding a button at ground it can no longer touch. That is
		# the rule, not a fault, and it is what this loop was silently relying on the absence of:
		# it failed as "a held button did not produce two strokes", which sounds like a broken
		# repeat and was really a mouse standing too far back.
		#
		# Walked to the branch root rather than toward `at`, so the mouse follows the corridor it
		# is cutting instead of trying to walk through the earth ahead of it. What is being timed
		# is the GAP between strokes, which is the recharge and cares nothing for where the mouse
		# stands, so keeping it in reach measures the same thing it always did.
		var root := network.nearest_segment_point(1, Vector2(at.x, at.z), controller.aim_range)
		if not root.is_empty():
			var from: Vector2 = root[0]
			player.global_position = Vector3(from.x, network.plane_y(1) + 0.05, from.y)
		_hold_dig(player, controller, at, 1)
		var now := network.segment_count(1)
		if now <= seen:
			continue
		seen = now
		if first < 0:
			first = i
		else:
			return i - first
	return -1


## Hold the dig button at a world point for `frames` ticks of the controller's own update.
##
## THROUGH THE INPUT FRAME, WHICH IS THE ONLY WAY LEFT (M7). This used to press `Input.action_press`
## and poke `player._aim_point`, and it stopped working at step 2 without saying so -- see
## `_running`. Both halves had to change: intent is a value now, so aim travels IN the frame, and
## a `Player` that is handed one stops capturing over the top of it for that tick.
##
## The press bit is set on the first tick only and held for the rest, which is what a real button
## does and what the rock branch of `_update_dig` distinguishes.
func _hold_dig(
	player: Mouse, controller: Node, at: Vector3, frames: int, holding: bool = true
) -> void:
	for i in range(frames):
		var frame := InputFrame.new()
		frame.aim_point = at
		frame.set_held(InputFrame.Action.DIG, holding)
		frame.set_pressed(InputFrame.Action.DIG, holding and i == 0)
		player.drive(frame)
		controller._update_dig(frame, 1.0 / 60.0)


## Can something walk it? (M4)
##
## Every other check in this file asks whether the GEOMETRY is sound. This one asks whether the
## routing graph agrees with that geometry, which is a different question with the same failure
## mode -- silence. A graph that is missing an edge produces a bot that mills about on the lawn,
## and a graph with an edge too many produces one that walks into earth; neither says anything,
## and both look like the AI being stupid rather than the map being wrong.
##
## THE DIAGONAL CASE IS THE ONE TO KEEP. Walls are built on the four faces of a cell, so two
## cells touching at a corner have no gap between them -- and an eight-way graph, which is the
## obvious thing to write, would route straight through it. That failure is invisible from
## above and looks exactly like a bot clipping a wall.
func _check_routing() -> void:
	_findings.clear()

	# A corridor with a bend in it, from a mouth on the lawn.
	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 8)
	_drive(1, Vector2i(0, 7), Vector2i(1, 0), 6)
	var graph := _network.graph()

	if graph == null:
		_fail("ROUTING", "the network has no graph at all")
		_report_routing()
		return

	# The graph knows exactly what was dug, plus the mouths on the lawn -- no more, no less.
	var expected := _network.shaft_cells(0).size()
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		expected += _network.cell_count(plane)
	if graph.size() != expected:
		_fail("ROUTING", "graph holds %d cells, the network has %d" % [graph.size(), expected])

	var route := graph.route(0, Vector2i(0, 0), 1, Vector2i(5, 7))
	if route.is_empty():
		_fail("ROUTING", "no route from the entrance to the far end of its own corridor")
	_check_steps(route, "corridor")

	# Every step has to be somewhere you could actually stand.
	for step: Dictionary in route:
		var plane: int = step["plane"]
		var cell: Vector2i = step["cell"]
		if plane == 0:
			if not _network.has_shaft_down(0, cell):
				_fail("ROUTING", "route crosses the lawn at %v, which is not an entrance" % cell)
		elif not _network.is_dug(plane, cell):
			_fail("ROUTING", "route runs through undug earth at plane %d %v" % [plane, cell])

	# Two corridors that never meet must not be joined by a route, however close they pass.
	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(1, 0), 6)
	_descend(0, Vector2i(0, 4))
	_drive(1, Vector2i(0, 4), Vector2i(1, 0), 6)
	graph = _network.graph()
	if not graph.route(1, Vector2i(3, 0), 1, Vector2i(3, 4)).is_empty():
		_fail("ROUTING", "a route was found between two corridors that do not connect")

	# AND THEY CAN BE JOINED, which is the other half of the same rule and the half that was
	# broken. The joining stroke necessarily FINISHES inside the corridor it is reaching for, and
	# an earlier version of the aim refused a stroke on exactly that ground -- so two tunnels a
	# stroke apart could never be connected, at all. The symptom in play was a cursor that simply
	# vanished as you closed the last metre, with nothing said and nothing to be done about it.
	#
	# Driven through the NETWORK rather than the controls, because what is under test is the rule
	# about earth; `_check_dig_flow` is where the button is.
	#
	# `[REVISED]` STARTED ON THE CORRIDOR'S CENTRELINE, NOT AGAINST ITS WALL, and getting that wrong
	# here was hidden by the graph for four milestones. This used to begin the run at (3, 1) -- one
	# metre out from a corridor whose body ends at 0.5, so the first stroke's cap and the corridor
	# met at a single tangent point with a pinch of zero width between them. A four-way graph called
	# those two cells connected because they share a face, and the scenario passed. They are not: no
	# mouse fits through a tangent, and dig_controller.gd goes to some trouble to make sure the
	# controls cannot produce one ("the new capsule always overlaps the old one by half a width, so
	# the union is continuous by construction"). Digging the way the button digs is the fix, and the
	# rule under test -- two corridors a stroke apart CAN be joined -- is unchanged.
	var reach := TunnelNetwork.ANGLE_STEPS / 4
	var gap_from := Vector2(3.0, 0.0)
	var joined := false
	for i in range(5):
		if not _network.dig_segment(1, gap_from, reach, Team.BLUE):
			break
		gap_from = TunnelNetwork.segment_end(TunnelNetwork.segment_id(gap_from, reach))
		graph = _network.graph()
		if not graph.route(1, Vector2i(3, 0), 1, Vector2i(3, 4)).is_empty():
			joined = true
			break
	if not joined:
		_fail("ROUTING", "two corridors four cells apart could not be joined by digging between them")
	else:
		_check_steps(graph.route(1, Vector2i(3, 0), 1, Vector2i(3, 4)), "joined")

	# THE DIAGONAL, AND `[REVISED]` IT IS NOW THE OPPOSITE ASSERTION. This used to read *"a
	# staircase of corner-touching cells is not walkable and must not be routable"*, which was true
	# of the geometry that existed when it was written: walls were built on the four faces of a
	# cell, so two cells touching at a corner had a wall either side of it and no gap. The contour
	# retired that. Each cell's stroke is a capsule reaching half a metre past the square, so
	# consecutive strokes on a diagonal meet tangentially, and the thin-earth rule then shaves the
	# wedge either side of the tangent away and leaves a doorway. The capsule walks the whole
	# staircase without touching the sides -- measured, not assumed.
	#
	# So the honest test is that the graph SAYS SO, and the reason this is not simply a weakened
	# assertion is `_check_graph_edges`: every scenario in this file now has each of its edges
	# walked by the player's own capsule, in both directions. A graph joining eight neighbours
	# blindly no longer passes by getting this one case right.
	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	_descend(0, Vector2i(0, 0))
	for i in range(1, 5):
		_network.dig(1, Vector2i(i, i))
	graph = _network.graph()
	var staircase := graph.route(1, Vector2i(0, 0), 1, Vector2i(4, 4))
	if staircase.is_empty():
		_fail("ROUTING", "no route along a staircase the mouse can walk end to end")
	_check_steps(staircase, "staircase")

	# A CORRIDOR AT FORTY-FIVE DEGREES, which is the whole reason any of this changed. Its cells
	# touch at their corners and nowhere else, so a four-way graph holds every one of them as a
	# point and joins none of them -- a corridor a player can run down and a bot will not follow,
	# with nothing anywhere reporting a fault.
	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	_descend(0, Vector2i(0, 0))
	var slant := TunnelNetwork.ANGLE_STEPS / 8
	var tip := _drive_angled(1, Vector2.ZERO, slant, 8)
	graph = _network.graph()
	var far := _cell_behind(tip, slant)
	if not _network.is_dug(1, far):
		_broken("routing", "the slanted corridor did not reach %v" % far)
	else:
		var slanted := graph.route(1, Vector2i(0, 0), 1, far)
		if slanted.is_empty():
			_fail("ROUTING", "no route along a corridor dug at 45 degrees")
		_check_steps(slanted, "slanted")
		# PASSING FOR THE RIGHT REASON. A route made entirely of straight steps would mean the
		# corridor had been claimed two cells wide and the diagonal never tested.
		var corners := 0
		for i in range(1, slanted.size()):
			var gap: Vector2i = (slanted[i]["cell"] as Vector2i) - (slanted[i - 1]["cell"] as Vector2i)
			if gap.x != 0 and gap.y != 0:
				corners += 1
		if corners == 0:
			_fail("ROUTING", "a 45-degree corridor routed without a single diagonal step")

	# AND AT AN ANGLE THAT LINES UP WITH NOTHING. Seventeen degrees wanders across the grid,
	# claiming cells in ones and twos and clipping others it never makes walkable -- so this is
	# where a graph that trusts a shared face gets caught routing into earth. The capsule in
	# `_check_steps` is what catches it.
	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	_descend(0, Vector2i(0, 0))
	var shallow := 3
	var wander := _drive_angled(1, Vector2.ZERO, shallow, 10)
	graph = _network.graph()
	var end := _cell_behind(wander, shallow)
	if not _network.is_dug(1, end):
		_broken("routing", "the shallow corridor did not reach %v" % end)
	else:
		var wandered := graph.route(1, Vector2i(0, 0), 1, end)
		if wandered.is_empty():
			_fail("ROUTING", "no route along a corridor dug at a shallow angle")
		_check_steps(wandered, "wander")

	# Down two planes and back up a different shaft: the vertical edges are shafts and only
	# shafts, and a route may use them in either direction.
	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 5)
	_descend(1, Vector2i(0, 4))
	_drive(2, Vector2i(0, 4), Vector2i(1, 0), 5)
	graph = _network.graph()
	var deep := graph.route(0, Vector2i(0, 0), 2, Vector2i(4, 4))
	if deep.is_empty():
		_fail("ROUTING", "no route from the lawn down to the second plane")
	_check_steps(deep, "descent")

	# TWO CORRIDORS JOINED ONLY BY THE LAWN. Plane 1 has two of them here, each with its own
	# entrance, and a route between them would have to walk across the grass. The graph must
	# refuse: the surface is a navmesh, not a row of cells, and a graph that quietly connected
	# two mouths would be inventing a straight line over ground it knows nothing about. Crossing
	# the lawn is route_planner.gd's job, and it is the only thing that can see the props.
	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	# Every shaft here is kept clear of every other, on this plane and the ones next to it. Laid
	# out by hand and worth checking against the exclusion rule when you edit it: a refused shaft
	# leaves a plane of cells with nothing joining them, and the routing failure that produces
	# looks exactly like a bug in the graph.
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(1, 0), 6)
	_descend(0, Vector2i(0, 4))
	_drive(1, Vector2i(0, 4), Vector2i(1, 0), 4)
	_descend(1, Vector2i(3, 4))
	_drive(2, Vector2i(3, 4), Vector2i(1, 0), 5)
	graph = _network.graph()
	if not graph.route(2, Vector2i(7, 4), 1, Vector2i(5, 0)).is_empty():
		_fail("ROUTING", "the graph routed across the lawn between two separate networks")
	# Within one network, though, a route down and along must exist and be honest.
	_check_steps(graph.route(0, Vector2i(0, 4), 2, Vector2i(7, 4)), "descent_two")

	# THE MOUTH THAT DOESN'T WORK. The entrance nearest this starting point is (0,0), whose
	# corridor goes nowhere near the destination; the one that gets there is further away. A
	# planner that simply picks the closest hole strands a bot on the lawn above its quarry,
	# which is the exact failure this milestone exists to remove.
	var below := _network.cell_to_world(2, Vector2i(7, 4))
	var plan := RoutePlanner.plan(_network, Vector3(6.0, 0.2, -3.0), 0, below, 2)
	if not plan.is_empty() and (plan[0]["cell"] as Vector2i) != Vector2i(0, 4):
		_fail("ROUTING", "the planner went down a hole that does not lead to the destination")
	if plan.is_empty():
		_fail("ROUTING", "the planner found no way to a destination underground")
	elif (plan[plan.size() - 1]["at"] as Vector3).distance_to(below) > 0.01:
		_fail("ROUTING", "the plan does not end at the destination")
	elif int(plan[0]["plane"]) != 0:
		_fail("ROUTING", "the plan does not start on the surface")

	# LAWN TO LAWN, WHICH IS THE ONLY CASE WITH A CHOICE IN IT. A corridor between two entrances,
	# and two points that would otherwise be a walk across the top of it.
	#
	# Worth knowing why the bias is turned up to force the issue: on this arena a tunnel can never
	# win on merit, because the yard is eighty metres of open dirt and no underground route is
	# shorter than the straight line above it. That is a map problem, not a routing one (GDD
	# section 8, and M3 said the same thing about the midfield). The bias makes the machinery
	# testable today, and the day the yard has a patio in the middle of it the honest comparison
	# will start choosing tunnels on its own.
	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	_descend(0, Vector2i(-6, 0))
	_drive(1, Vector2i(-6, 0), Vector2i(1, 0), 13)
	_network.dig_shaft_up(1, Vector2i(6, 0))
	var across := RoutePlanner.plan(
		_network, Vector3(-7.0, 0.2, 0.0), 0, Vector3(7.0, 0.2, 0.0), 0, 0.2
	)
	if across.is_empty():
		_fail("ROUTING", "no tunnel route between two entrances even at a heavy bias")
	else:
		_check_steps(across.slice(0, across.size() - 1), "across")
		if int(across[0]["plane"]) != 0:
			_fail("ROUTING", "the crossing does not start at an entrance on the lawn")
		var surfaced := false
		for i in range(1, across.size()):
			if int(across[i]["plane"]) == 0 and int(across[i - 1]["plane"]) > 0:
				surfaced = true
		if not surfaced:
			_fail("ROUTING", "the crossing goes underground and never comes back up")
		if (across[across.size() - 1]["at"] as Vector3).distance_to(Vector3(7.0, 0.2, 0.0)) > 0.01:
			_fail("ROUTING", "the crossing does not end at the destination")

	# And with no thumb on the scale, the same two points are a walk. Nothing underground beats
	# open ground in a straight line, and a planner that thought otherwise would be sending bots
	# down holes for no reason.
	if not RoutePlanner.plan(
		_network, Vector3(-7.0, 0.2, 0.0), 0, Vector3(7.0, 0.2, 0.0), 0
	).is_empty():
		_fail("ROUTING", "a tunnel was preferred to walking straight across open ground")

	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	if not RoutePlanner.plan(
		_network, Vector3(-8.0, 0.2, -8.0), 0, Vector3(8.0, 0.2, 8.0), 0
	).is_empty():
		_fail("ROUTING", "the planner routed through a network with no tunnels in it")

	_report_routing()


## Bringing a tunnel down: what goes, what stays, and what is refused. (M4)
##
## Collapse is the only operation in the whole system that makes the network SMALLER, and a great
## deal of the code around it quietly assumes growth -- the routing graph, the dug mask, the wall
## mesh and the lamps are all caches over the cell dictionary. This is the check that they all
## heard about it.
func _check_collapse() -> void:
	_findings.clear()
	if not await _fresh_network():
		_broken("collapse", "the arena would not build")
		return

	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 8)
	var graph := _network.graph()
	var before := _network.cell_count(1)
	var points := graph.size()

	# The cell in the middle of the corridor goes.
	if not _network.collapse(1, Vector2i(0, 4)):
		_fail("COLLAPSE", "a plain corridor cell refused to come down")
	if _network.is_dug(1, Vector2i(0, 4)):
		_fail("COLLAPSE", "the cell is still dug afterwards")
	if _network.cell_count(1) != before - 1:
		_fail("COLLAPSE", "the cell count did not drop by exactly one")
	if graph.size() != points - 1:
		_fail("COLLAPSE", "the routing graph did not lose the cell")
	if graph.has(1, Vector2i(0, 4)):
		_fail("COLLAPSE", "the graph still thinks you can stand there")

	# AND EVERYTHING PAST IT IS CUT OFF. This is the mechanic, not a side effect: sealing a
	# corridor is how an Engineer stops something following them, and a route that still found a
	# way through would mean the seal did nothing.
	if not graph.route(0, Vector2i(0, 0), 1, Vector2i(0, 7)).is_empty():
		_fail("COLLAPSE", "a route still runs through the collapsed cell")
	if not graph.has(1, Vector2i(0, 7)):
		_fail("COLLAPSE", "the stranded cells were removed as well -- they should still exist")

	# Twice is a no-op rather than a second hole in the counting.
	if _network.collapse(1, Vector2i(0, 4)):
		_fail("COLLAPSE", "collapsing the same cell twice reported success")

	# A SHAFT COMES DOWN WHOLE, FROM EITHER END. This used to be a pair of refusals; it is now the
	# ability's headline (see [method TunnelNetwork.collapse_shaft]). What the old refusals were
	# protecting -- SHAFT_ENDS, which is a mouse pressing E and arriving inside solid ground -- is
	# protected instead by taking both ends at once, and that is what these check. The invariant
	# itself runs after every scenario and would catch a half-shaft anyway; these say WHICH call
	# left one, which is the difference between a two-minute fix and an afternoon.
	_descend(1, Vector2i(0, 6))
	if _network.collapse_footprint(1, Vector2i(0, 6)).size() != 2:
		_fail("COLLAPSE", "a cell with a shaft leading down claimed a one-cell footprint")
	if not _network.collapse(1, Vector2i(0, 6)):
		_fail("COLLAPSE", "a cell with a shaft leading down refused")
	if _network.has_shaft_down(1, Vector2i(0, 6)):
		_fail("COLLAPSE", "the shaft is still recorded after its cell came down")
	if _network.is_dug(2, Vector2i(0, 6)):
		_fail("COLLAPSE", "the landing a plane below stayed open")
	if graph.has(2, Vector2i(0, 6)):
		_fail("COLLAPSE", "the routing graph kept the landing of a filled shaft")

	# Now the other direction, and the one the Brute is actually for: an ENTRANCE, taken from its
	# landing on plane 1, closing the mouth on the lawn. Plane 0 is the only place a collapse
	# reaches a cell that was never dug, so it is the only place the tile and the graph point are
	# removed without a `_cells` entry to drive it.
	if _network.collapse_footprint(1, Vector2i(0, 0)).size() != 2:
		_fail("COLLAPSE", "the cell under an entrance claimed a one-cell footprint")
	if not _network.collapse(1, Vector2i(0, 0)):
		_fail("COLLAPSE", "the cell under an entrance refused to come down")
	if _network.has_shaft_down(0, Vector2i(0, 0)):
		_fail("COLLAPSE", "the entrance is still recorded after being filled in")
	if _network.is_dug(1, Vector2i(0, 0)):
		_fail("COLLAPSE", "the cell under the entrance stayed open")
	if graph.has(0, Vector2i(0, 0)):
		_fail("COLLAPSE", "the routing graph still offers a way down at a filled entrance")
	if not graph.mouths().is_empty():
		_fail("COLLAPSE", "a filled entrance is still listed as a mouth")

	# The surface is not diggable, and not collapsible on its own either: the lawn only comes down
	# as the upper half of a shaft, never as a cell somebody aimed at.
	if _network.collapse(0, Vector2i(0, 0)):
		_fail("COLLAPSE", "a piece of the lawn came down")

	print("")
	_running.erase("collapse")
	print("-- collapse")
	if _findings.is_empty():
		print("   ok")
	else:
		for finding: String in _findings:
			print("   FAIL %s" % finding)
		_total_failures += _findings.size()


## Shoring: the Engineer's timbers, and the one thing in this file that makes a cell HARDER to
## remove (GDD section 4).
##
## THE INVARIANT IS "ABSORBS EXACTLY ONE", and it has two failure modes that are opposites and
## equally invisible from inside a match. Shoring that absorbs *nothing* is three seconds an
## Engineer spent on a placebo, and it would look exactly like the Brute being good at its job.
## Shoring that absorbs *forever* is a corridor no Brute can ever answer -- which GDD section 5 is
## explicit that nothing in this game may be -- and it would look exactly like the Engineer being
## good at its job. Neither shows up as a bug; both show up as somebody complaining about balance
## three weeks later.
##
## THE FOOTPRINT IS CHECKED AS CAREFULLY AS THE CELL, because that is where a shored cell can still
## get somebody killed. `collapse` refuses and `collapse_footprint` must agree with it, or the
## Brute buries a mouse standing in a corridor that is visibly still there.
func _check_shoring() -> void:
	_findings.clear()
	if not await _fresh_network():
		_broken("shoring", "the arena would not build")
		return

	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 8)
	var graph := _network.graph()
	var cell := Vector2i(0, 4)

	if _network.is_shored(1, cell):
		_fail("SHORING", "a freshly dug cell is already shored")
	if _network.shore(1, Vector2i(0, 40)):
		_fail("SHORING", "earth that was never dug accepted timbers")
	if not _network.shore(1, cell):
		_fail("SHORING", "an ordinary dug cell refused to be shored")
	if not _network.is_shored(1, cell):
		_fail("SHORING", "the cell does not report itself as shored")
	if _network.shore(1, cell):
		_fail("SHORING", "shoring the same cell twice reported success -- it would stack")

	# NOTHING ELSE ABOUT THE CELL CHANGED. Shoring is not an obstruction and not rock: you can
	# still walk through it and a route still runs through it. If that ever stops being true the
	# Engineer has accidentally been given the barricade twice.
	if _network.is_blocked(1, cell):
		_fail("SHORING", "shoring blocked the cell -- it is not a barricade")
	if not graph.has(1, cell):
		_fail("SHORING", "shoring took the cell out of the routing graph")

	# THE ABSORB. The collapse reports failure -- nothing came down -- and the timbers are spent.
	var before := _network.cell_count(1)
	if not _network.collapse_footprint(1, cell).is_empty():
		_fail("SHORING", "a shored cell claims a footprint -- somebody would be buried in it")
	if _network.collapse(1, cell):
		_fail("SHORING", "a collapse aimed at shored timbers reported that it took the cell")
	if not _network.is_dug(1, cell):
		_fail("SHORING", "the cell came down anyway")
	if _network.cell_count(1) != before:
		_fail("SHORING", "the plane lost a cell to a collapse that was supposed to be absorbed")
	if _network.is_shored(1, cell):
		_fail("SHORING", "the timbers survived the collapse they absorbed")

	# AND EXACTLY ONE. The second collapse finds bare earth and takes it, which is what keeps this
	# an answer to the Brute rather than an immunity from it.
	if _network.collapse_footprint(1, cell).size() != 1:
		_fail("SHORING", "the cell did not go back to an ordinary one-cell footprint")
	if not _network.collapse(1, cell):
		_fail("SHORING", "a second collapse was refused -- the shoring is not one-shot")
	if _network.is_dug(1, cell):
		_fail("SHORING", "the cell survived a collapse it had nothing left to absorb")

	# A SHAFT HOLDS FROM EITHER END, and both sets of timbers go at once. The rule is that a shaft
	# is a single object (see [method TunnelNetwork.collapse_shaft]), so half-protecting one is not
	# a state the world can hold.
	_descend(1, Vector2i(0, 6))
	if not _network.shore(2, Vector2i(0, 6)):
		_fail("SHORING", "the landing under a shaft refused timbers")
	if not _network.collapse_footprint(1, Vector2i(0, 6)).is_empty():
		_fail("SHORING", "a shaft with a shored landing still claims a footprint")
	if _network.collapse(1, Vector2i(0, 6)):
		_fail("SHORING", "shoring the landing did not save the shaft above it")
	if not _network.has_shaft_down(1, Vector2i(0, 6)):
		_fail("SHORING", "the shaft came down despite its landing being braced")
	if _network.is_shored(2, Vector2i(0, 6)):
		_fail("SHORING", "the landing's timbers survived holding a shaft up")
	if not _network.collapse(1, Vector2i(0, 6)):
		_fail("SHORING", "the shaft refused a second collapse with nothing left to absorb")

	# THE BOOK DOES NOT OUTLIVE THE EARTH. A cell taken for any other reason must not leave timbers
	# recorded against ground that no longer exists -- they could never be spent or broken, and the
	# cell can be dug again later.
	if _network.is_shored(2, Vector2i(0, 6)) or _network.is_shored(1, Vector2i(0, 6)):
		_fail("SHORING", "shoring survived the cell it was in")

	print("")
	_running.erase("shoring")
	print("-- shoring")
	if _findings.is_empty():
		print("   ok")
	else:
		for finding: String in _findings:
			print("   FAIL %s" % finding)
		_total_failures += _findings.size()


## Rock: earth that never opens, laid differently on every plane. (M4, GDD section 3)
##
## THE ONLY CHECK IN THIS FILE THAT RUNS AGAINST A GENERATED LAYOUT, and that is the point.
## Everything else builds its subject by hand, so it can only find the mistakes somebody thought
## to describe; this one asks whether the thing the player will actually meet -- a seeded field of
## seams nobody placed -- obeys the rules. Generation failing open (no rock at all) and generation
## failing closed (a nest walled in) are both invisible in play until the match that hits them,
## and both are one line here.
func _check_rock() -> void:
	_findings.clear()
	if _scene != null:
		_scene.free()
	# Nests are KEPT, unlike every other scenario: the clearance around them is a generation rule,
	# and a check that strips the nests would assert it against a map that has none.
	_scene = _arena(["Player", "CameraRig", "DepthFocus", "FallGuard", "HUD",
		"Surface/Rocks", "MatchDirector", "Navigation"], true)
	await process_frame
	await physics_frame
	_network = _scene.get_node("Tunnels") as TunnelNetwork

	# It ran at all, and it ran nowhere it shouldn't have. An empty layout would quietly turn the
	# whole feature off and every other assertion below would pass by vacuity.
	if not _network.rock_cells(0).is_empty():
		_fail("ROCK", "there is rock on the surface, which is not diggable in the first place")
	var counts: Array[int] = []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		counts.append(_network.rock_cells(plane).size())
		if counts[plane - 1] <= 0:
			_fail("ROCK", "plane %d has no rock at all" % plane)
	if counts.size() == 3 and counts[2] <= counts[0]:
		_fail("ROCK", "the deepest plane is no rockier than the first (%d vs %d)"
			% [counts[2], counts[0]])

	# PER-PLANE LAYOUTS ARE THE WHOLE IDEA (section 3). Rock in the same cells on every layer is a
	# flat maze drawn three times, and going around an obstruction would never mean going down.
	var first := {}
	for cell: Vector2i in _network.rock_cells(1):
		first[cell] = true
	var shared := 0
	for cell: Vector2i in _network.rock_cells(2):
		if first.has(cell):
			shared += 1
	if counts.size() > 1 and shared > counts[1] / 2:
		_fail("ROCK", "planes 1 and 2 share %d of %d cells -- the layouts are not independent"
			% [shared, counts[1]])

	# Nobody is walled in at home.
	for node in _scene.get_node("Nests").get_children():
		var nest := node as Nest
		if nest == null:
			continue
		var centre := _network.world_to_cell(nest.global_position)
		var reach := ceili(_network.rock_nest_clearance / TunnelNetwork.CELL) - 1
		for plane in range(1, TunnelNetwork.PLANE_COUNT):
			for x in range(centre.x - reach, centre.x + reach + 1):
				for y in range(centre.y - reach, centre.y + reach + 1):
					if _network.is_rock(plane, Vector2i(x, y)):
						_fail("ROCK", "rock at plane %d %v is inside %s's clearance"
							% [plane, Vector2i(x, y), nest.name])

	# THE ROCK ITSELF NEVER OPENS, AND THAT IS THE INVARIANT NOW.
	#
	# `[REVISED]` WHAT THIS USED TO ASSERT AND WHY IT CHANGED. Rock was a set of cells and a stroke
	# was refused outright if it touched one, so the check was "aim at a rock cell, be refused, and
	# find the cell still undug". A rock is a shape in the field now (see [RockBody]) and a stroke
	# that meets one stops AT it, keeping whatever it opened on the way -- so a dig aimed at a rock
	# square legitimately returns true, and the square legitimately ends up part corridor and part
	# stone. Every one of the old assertions would fail against a system working exactly as
	# intended, which is the most dangerous shape a test can have: right for the wrong reason, then
	# wrong for the right one.
	#
	# So the question is asked of the STONE rather than of the square. Nothing anywhere inside a
	# rock may end up open ground, no waypoint may land in one, and a stroke that can only reach
	# stone must be refused and must say so.
	var spoken: Array[String] = []
	_network.dig_refused.connect(func(reason: String) -> void: spoken.append(reason))

	var blocking := _blocking_rock(1, 3.0)
	if blocking.is_empty():
		_fail("ROCK", "no rock on plane 1 both clear to reach and wide enough to stop a stroke")
	else:
		# Straight at the middle of it, from five metres clear, one stroke chained onto the last.
		# The spot and the heading come from `_blocking_rock`, which is what guarantees the run is
		# not through some other lump and that the face really has nothing behind it.
		var lump := blocking[0] as RockBody
		var approach := blocking[1] as Vector2
		var heading := TunnelNetwork.direction_angle(lump.centre - approach)
		var reached := _drive_angled(1, approach, heading, 16)
		if approach.distance_to(reached) < 1.5:
			_fail("ROCK", "the corridor toward the rock never got going (%.1fm)"
				% approach.distance_to(reached))
		if lump.depth(reached) > 0.0:
			_fail("ROCK", "the corridor drove into the stone and kept going")

		# Refused, and out loud. The corridor is now standing against the face, so the next stroke
		# on the same heading has nothing but rock in front of it -- which is exactly the moment a
		# player holds the button and needs to be told why nothing is happening.
		spoken.clear()
		if _network.dig_segment(1, reached, heading):
			_fail("ROCK", "a stroke pointed straight into the rock face opened ground")
		if spoken.is_empty():
			_fail("ROCK", "digging into rock refused silently")

		# THE HEADLINE. Every sample of the plane's field over the rock's own square, against the
		# rock's own shape: if the two ever disagree by anything that matters, a mouse is standing
		# inside a boulder.
		#
		# MEASURED IN DEPTH AND TOLERANCED IN TEXELS, not asserted at zero. The field is stored at
		# 12.5cm and the contour interpolates its crossing between samples, so the drawn surface
		# lands a millimetre or two either side of where the analytic rock says it is -- on some
		# seeds, at a handful of points, and never by more than a few thousandths of a metre.
		# Asserting equality would make this check fail on the arithmetic rather than on the rule.
		# A quarter of a texel is two orders of magnitude past the disagreement the field can
		# actually produce and two orders short of a mouse, which is the gap a real leak lands in.
		var slack := TunnelContour.TEXEL * 0.25
		var inside := 0
		var deepest := 0.0
		var span := lump.reach()
		for j in range(41):
			for i in range(41):
				var at := lump.centre + Vector2(
					-span + 2.0 * span * float(i) / 40.0, -span + 2.0 * span * float(j) / 40.0
				)
				var into := lump.depth(at)
				if into > slack and _network.is_open_at(1, at):
					inside += 1
					deepest = maxf(deepest, into)
		if inside > 0:
			_fail("ROCK", "%d samples of open corridor are inside the stone, deepest %.3fm"
				% [inside, deepest])

		# And no bot is sent through it. The graph's waypoint for a cell the rock clips has to be
		# the standing room in the rest of that square, not the middle of the stone.
		for cell: Vector2i in _network.dug_cells(1):
			if not _network.graph().has(1, cell):
				continue
			var stand := _network.standing_point(1, cell)
			if lump.depth(Vector2(stand.x, stand.z)) > 0.0:
				_fail("ROCK", "the routing graph puts a waypoint inside the rock at %v" % cell)
				break

	# An entrance cannot be sunk into rock, from either end. That matters: a shaft that lands in
	# solid ground is the SHAFT_ENDS invariant failing from a direction no scenario builds by hand.
	var seam := _first_rock(1)
	if seam == Vector2i.MAX:
		_fail("ROCK", "no rock on plane 1 with soft ground beside it -- nothing to test")
	elif _network.dig_shaft_down(0, seam):
		_fail("ROCK", "an entrance was sunk from the lawn into rock")

	var deep := _first_rock(2)
	if deep != Vector2i.MAX:
		_network.dig(1, deep)
		if _network.dig_shaft_down(1, deep):
			_fail("ROCK", "a shaft was sunk onto rock a plane below")
		if _network.is_dug(2, deep):
			_fail("ROCK", "and it opened the rock cell it landed on")

	print("")
	_running.erase("rock")
	print("-- rock  cells/plane %s" % [counts])
	if _findings.is_empty():
		print("   ok")
	else:
		for finding: String in _findings:
			print("   FAIL %s" % finding)
		_total_failures += _findings.size()
## Which rock you can SEE, and which you cannot. (M4, GDD section 3)
##
## `[REVISED]` THIS USED TO CHECK A REVEAL, and there is no reveal any more. Rock was hidden
## information: running into a lump taught your crew where it went, and the check that mattered was
## the mirror -- what BLUE learned, and what RED still must not know. Visibility is a property of
## the STONE now. A rock taller than the layer of earth it sits in breaks the dirt above and stands
## where anybody can see it; a shorter one is buried and nobody can. Both crews look at the same
## world, so there is no leak to check for and the whole per-crew half of this is gone.
##
## WHAT IS LEFT IS THAT THE TWO CASES BOTH HAPPEN AND ARE TOLD APART, which is the failure this
## replaces the old one with. A height rule that put every rock above the dirt would make the
## surface a complete map of the underground and nothing would ever ambush you; one that put every
## rock below it would draw no stone at all and look exactly like the feature being switched off.
## Both read as "fine" from a single screenshot, so both are asserted against the other.
##
## AND THAT THE DRAWN STONE FOLLOWS THE SHAPE. The lumps are batched per plane per grade, so the
## check is that a plane with surfacing breakable rock has a pale mesh and one without has none --
## the same assertion in both directions, for the same reason.
func _check_surfacing() -> void:
	_findings.clear()
	if _scene != null:
		_scene.free()
	# ROCK ON. Every other scenario in this file turns it off so a seeded lump cannot land on a
	# hand-picked coordinate; this one is about the lumps.
	_scene = _arena(STRIP, true)
	if _scene == null:
		_broken("surfacing", "the arena would not build")
		return
	await process_frame
	await physics_frame
	_network = _scene.get_node_or_null("Tunnels") as TunnelNetwork
	if _network == null:
		_broken("surfacing", "the arena built without a network")
		return

	var thickness := TunnelNetwork.SPACING
	var above := 0
	var below := 0
	var pale_up := 0
	var dark_up := 0
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		for entry: Variant in _network.rock_bodies(plane):
			var rock := entry as RockBody
			if rock.breaks_surface(thickness):
				above += 1
				if rock.breakable:
					pale_up += 1
				else:
					dark_up += 1
			else:
				below += 1

	if above + below == 0:
		_broken("surfacing", "no rock anywhere in the map -- nothing to be visible or hidden")
		return
	# BOTH OUTCOMES, and the numbers are deliberately loose. The exact split is a tuning decision
	# that should be free to move; what must not happen is one of the two disappearing, which is
	# what turns the surface into either a full map or a blank one.
	if above == 0:
		_fail("SURFACING", "not one rock in the map stands above the dirt -- nothing is visible")
	if below == 0:
		_fail("SURFACING", "every rock in the map stands above the dirt -- nothing can ambush you")

	# THE HEIGHT RULE ITSELF, asked of the geometry rather than of the count. A rock that reports
	# breaking the surface must actually be taller than the earth it sits in, and one that reports
	# otherwise must not -- the two halves of one subtraction, which is the sort of thing that
	# survives a refactor only if somebody wrote it down.
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		for entry: Variant in _network.rock_bodies(plane):
			var rock := entry as RockBody
			var says := rock.breaks_surface(thickness)
			var truly := rock.height > thickness
			if says != truly:
				_fail("SURFACING", "a rock disagrees with its own height about breaking the dirt")
				break
			if says and rock.rise_above(thickness) <= 0.0:
				_fail("SURFACING", "a rock breaks the surface but stands no distance above it")
				break
			if not says and rock.rise_above(thickness) != 0.0:
				_fail("SURFACING", "a buried rock reports standing above the dirt")
				break

	# THE DRAWN STONE, in both directions. A plane whose surfacing rock is all one grade must have
	# a mesh for that grade and none for the other, which catches the two surfaces being crossed --
	# a failure that draws bedrock in the breakable colour and is invisible in a headless run.
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		var pale := 0
		var dark := 0
		for entry: Variant in _network.rock_bodies(plane):
			var rock := entry as RockBody
			if not rock.breaks_surface(thickness):
				continue
			if rock.breakable:
				pale += 1
			else:
				dark += 1
		var pale_mesh: Mesh = (_network._rock_lumps[plane] as MeshInstance3D).mesh
		var dark_mesh: Mesh = (_network._bedrock_lumps[plane] as MeshInstance3D).mesh
		if (pale > 0) != (pale_mesh != null):
			_fail("SURFACING", "plane %d draws breakable stone it has none of, or none it has"
				% plane)
		if (dark > 0) != (dark_mesh != null):
			_fail("SURFACING", "plane %d draws bedrock it has none of, or none it has" % plane)

	# NOTHING IS DRAWN FOR THE BURIED ROCK, which is the whole economy of the change: the buried
	# half is already the stone face the contour wrapped round it, and modelling it twice would put
	# two descriptions of one rock in the scene. Asserted by triangle count against the lumps that
	# should be there rather than by eye.
	var surfacing_lobes := 0
	for entry: Variant in _network.rock_bodies(1):
		var rock := entry as RockBody
		if rock.breaks_surface(thickness):
			surfacing_lobes += rock.lobes.size()
	var drawn := 0
	for node: MeshInstance3D in [_network._rock_lumps[1], _network._bedrock_lumps[1]]:
		if node.mesh != null:
			drawn += node.mesh.surface_get_array_len(0)
	var per_lump := RockShell.RINGS * RockShell.SEGMENTS * 6
	if drawn != surfacing_lobes * per_lump:
		_fail("SURFACING", "plane 1 draws %d vertices of stone for %d surfacing lobes (expected %d)"
			% [drawn, surfacing_lobes, surfacing_lobes * per_lump])

	print("")
	_running.erase("surfacing")
	print("-- surfacing")
	print("   %d rocks above the dirt (%d pale, %d dark), %d buried" % [
		above, pale_up, dark_up, below
	])
	if _findings.is_empty():
		print("   ok")
	else:
		for finding: String in _findings:
			print("   FAIL %s" % finding)
		_total_failures += _findings.size()



## No-surface zones: paving you can tunnel under but not come up through. (M4, GDD section 3)
##
## THE WHOLE CHECK IS A PAIR OF OPPOSITES, and either one alone would pass while the feature was
## broken. A seal that refused everything -- horizontal digging, the plane below, the cells beside
## it -- would satisfy every "was it refused?" assertion in here and would be a slab of rock with
## a different message. A seal that refused nothing would satisfy every "did it still work?"
## assertion. So each half is asserted against the other, and the margin cases at the slab edge
## are named cells rather than a sweep, because "which side of the paving is this cell on" is the
## exact question a shaft mouth asks.
##
## The zone is placed HERE rather than read off the map, like every scenario in this file and
## unlike `_check_rock`: where the arena's patio sits is a level decision that will move, and a
## check anchored to it would start failing the day somebody drags it.
func _check_seal() -> void:
	_findings.clear()
	if not await _fresh_network():
		_broken("paving", "the arena would not build")
		return

	# Footprint chosen so its edges fall BETWEEN cell centres: cells 7 and 13 have their centres
	# outside the rectangle and their square metre of ground over it, which is the half-cell margin
	# the network asks with, and the only part of this rule with arithmetic in it.
	var zone := NoSurfaceZone.new()
	zone.extents = Vector2(2.5, 3.0)
	zone.show_paving = false
	zone.position = Vector3(10.0, 0.0, 0.0)
	_scene.get_node("Surface").add_child(zone)
	await process_frame

	# Vacuity first. A query that answered "sealed" everywhere would make every refusal below pass
	# for the wrong reason, and one that answered "clear" everywhere would make every success pass
	# for the wrong reason. Same trap the rock check documents, from both sides at once.
	if not _network.is_sealed(Vector2i(10, 0)):
		_fail("PAVING", "the middle of the slab is not sealed -- nothing below is being tested")
	if _network.is_sealed(Vector2i(0, 0)):
		_fail("PAVING", "open lawn well clear of the slab reports as sealed")
	if not _network.is_sealed(Vector2i(13, 0)):
		_fail("PAVING", "a cell overlapping the slab edge is not sealed -- a mouth would bite it")
	if _network.is_sealed(Vector2i(14, 0)):
		_fail("PAVING", "a cell a clear metre past the slab is sealed -- the rule overreaches")

	var spoken: Array[String] = []
	_network.dig_refused.connect(func(reason: String) -> void: spoken.append(reason))

	# You cannot get in from the top.
	if _network.dig_shaft_down(0, Vector2i(10, 0)):
		_fail("PAVING", "an entrance was sunk through the paving")
	if _network.has_shaft_down(0, Vector2i(10, 0)):
		_fail("PAVING", "and it recorded a mouth in the middle of the slab")
	if spoken.is_empty():
		_fail("PAVING", "digging into the paving from the lawn refused silently")

	# But you can tunnel the whole way under it -- which is the half of the rule that makes it a
	# no-SURFACE zone rather than a wall. In from the lawn beside the slab and straight across.
	_descend(0, Vector2i(5, 0))
	_drive(1, Vector2i(5, 0), Vector2i(1, 0), 10)
	for x in range(5, 15):
		if not _network.is_dug(1, Vector2i(x, 0)):
			_fail("PAVING", "the corridor stopped at %v -- paving is blocking a horizontal dig"
				% Vector2i(x, 0))

	# And you cannot come out under it either. Same rule, met from below, which is where a player
	# actually meets it.
	spoken.clear()
	if _network.dig_shaft_up(1, Vector2i(10, 0)):
		_fail("PAVING", "a mouse broke out through the paving from underneath")
	if _network.has_shaft_up(1, Vector2i(10, 0)):
		_fail("PAVING", "and it left a mouth in the middle of the slab")
	if spoken.is_empty():
		_fail("PAVING", "breaking out under the paving refused silently")

	# Going DEEPER under it is untouched. The seal is a rule about the lawn, and a version of it
	# that leaked downward would quietly turn the patio into a column of rock three planes tall.
	if not _network.dig_shaft_down(1, Vector2i(10, 0)):
		_fail("PAVING", "a shaft from plane 1 to plane 2 was refused under the paving")
	if not _network.is_dug(2, Vector2i(10, 0)):
		_fail("PAVING", "and the plane below it never opened")

	# The rule stops where the paving does. Without this the check passes on a map where nobody
	# can surface anywhere, which is the failure that would be hardest to notice in play: you
	# would simply believe the R key was broken.
	if not _network.dig_shaft_up(1, Vector2i(14, 0)):
		_fail("PAVING", "breaking out a clear metre past the slab was refused too")
	elif not _network.has_shaft_up(1, Vector2i(14, 0)):
		_fail("PAVING", "the mouth past the slab was allowed but never recorded")

	print("")
	_running.erase("paving")
	print("-- paving")
	if _findings.is_empty():
		print("   ok")
	else:
		for finding: String in _findings:
			print("   FAIL %s" % finding)
		_total_failures += _findings.size()


## Nothing lying on the lawn may reach down into a tunnel.
##
## THE ONE INVARIANT THAT COVERS A WHOLE CLASS OF INVISIBLE BUG. Surface clutter collides on
## `WORLD_BIT`, which every mouse masks on every plane -- that is what makes the ground and the
## perimeter wall solid to somebody who is underground and should never see them. The price of that
## convenience is that a surface object which hangs even a little below the grass is a surface
## object standing in plane 1's corridor: solid, unlit, undrawn from down there, and impossible to
## work out from anything on screen.
##
## WHICH IS EXACTLY WHAT HAPPENED. `rock_scatter.gd` parented its collider to the MESH, so a big
## rock's unit box inherited the mesh's scale, its 22% sinking and its random lean -- putting the
## bottom of the box up to 57cm under the lawn. Plane 1's floor is at -0.65 and a mouse is 0.40
## tall, so anything below -0.25 is in occupied ground. The Brute met it first and hardest, being
## the widest body and so the one that reaches furthest from a corridor's spine, and the report was
## "the Brute gets stuck under some of the big rocks" -- with nothing on screen to blame.
##
## MEASURED OFF THE COLLIDERS, NOT BY SWEEPING THE YARD. A probe walked over the arena proves the
## invariant only where it happened to step, and the offending rocks are a couple of dozen objects
## in six thousand square metres of lawn; this reads every shape in the scene, so a new prop with a
## sunk collider fails on the run it is added rather than on the playtest that finds it.
##
## THE SCENE IS THE REAL ONE, obstructions and all. Every other check in this file strips the rock
## scatter and the boulders precisely because their colliders get in the way -- which is this bug
## seen from the other side, and why it survived a suite that builds fifteen arenas.
func _check_clutter() -> void:
	_findings.clear()
	if _scene != null:
		_scene.free()
		_scene = null
	# UNSTRIPPED, which is the whole point: the things every other scenario removes are the
	# subject here. Only the match is taken out, for the determinism reason STRIP_MATCH gives.
	_scene = _arena(STRIP_MATCH, true, true)
	if _scene == null:
		_broken("clutter", "the arena would not build -- no collider was measured")
		return
	await process_frame
	await physics_frame

	# The top of a mouse standing on the shallowest tunnel floor. Anything on the world layer that
	# reaches below this is inside ground a mouse is entitled to walk through.
	var ceiling := -TunnelNetwork.SPACING + Mouse.BODY_HEIGHT
	var measured := 0
	var lowest := INF
	var worst := ""
	for shape: CollisionShape3D in _world_shapes(_scene):
		if shape.shape == null:
			continue
		measured += 1
		var box := shape.shape.get_debug_mesh().get_aabb()
		var floor_y := INF
		for corner in range(8):
			floor_y = minf(floor_y, (shape.global_transform * box.get_endpoint(corner)).y)
		if floor_y < lowest:
			lowest = floor_y
			worst = shape.get_parent().name if shape.get_parent() != null else shape.name
		if floor_y < ceiling:
			_fail("CLUTTER", "%s reaches to y=%.3f, inside plane 1's mouse band (below %.3f)"
				% [_owner_path(shape), floor_y, ceiling])

	# Vacuity, same trap `_check_rock` documents: a scene whose clutter never loaded would pass
	# this without a single shape being looked at.
	if measured < 8:
		_fail("CLUTTER", "only %d world colliders in the arena -- the clutter did not load"
			% measured)

	print("")
	_running.erase("clutter")
	print("-- clutter")
	print("   %d world colliders, lowest %.3f (%s), floor of the band %.3f"
		% [measured, lowest, worst, ceiling])
	if _findings.is_empty():
		print("   ok")
	else:
		for finding: String in _findings:
			print("   FAIL %s" % finding)
		_total_failures += _findings.size()


## Every collision shape in the scene belonging to a body on the world layer.
##
## BY LAYER RATHER THAN BY TYPE, because what makes an object a hazard to a tunnel is not what
## class it is -- it is that a mouse three quarters of a metre down still masks it. The tunnel
## planes' own bodies are on their own layers and correctly excluded; CSG collision is generated
## into a child body, which this finds like any other.
func _world_shapes(node: Node) -> Array[CollisionShape3D]:
	var found: Array[CollisionShape3D] = []
	var body := node as CollisionObject3D
	if body != null and body.collision_layer & TunnelNetwork.WORLD_BIT != 0:
		for child in body.get_children():
			var shape := child as CollisionShape3D
			if shape != null:
				found.append(shape)
	for child in node.get_children():
		found.append_array(_world_shapes(child))
	return found


## Enough of the path to find the thing again, which "Collision" on its own never is.
func _owner_path(shape: Node) -> String:
	var body: Node = shape.get_parent()
	var host: Node = body.get_parent() if body != null else null
	var parts: Array[String] = []
	if host != null:
		parts.append(host.name)
	if body != null:
		parts.append(body.name)
	parts.append(shape.name)
	return "/".join(parts)


## The largest rock on a plane, so the geometry checks have room to be wrong in. Null if the layout
## somehow has none -- which the caller reports rather than passing over.
func _biggest_rock(plane: int) -> RockBody:
	var best: RockBody = null
	for entry: Variant in _network.rock_bodies(plane):
		var rock := entry as RockBody
		if rock != null and (best == null or rock.reach() > best.reach()):
			best = rock
	return best


## A rock that can actually stop a stroke dead, and a clear place to drive at it from.
##
## `[ADDED]` BECAUSE "THE BIGGEST ROCK" CARRIED TWO ASSUMPTIONS THAT USED TO BE FREE. Both broke
## when rock stopped being metres across, and both broke QUIETLY -- as a rule failing rather than as
## scaffolding failing, which is the expensive kind.
##
## THE FIRST IS THAT THE RUN AT IT IS CLEAR. A plane held a few dozen lumps; it now holds a few
## hundred, and a straight five-metre approach very often rams a DIFFERENT rock. Every assertion
## afterwards then describes a corridor that never reached the subject.
##
## THE SECOND IS THAT A STROKE INTO ITS FACE OPENS NOTHING, which is what "digging into rock is
## refused" is asserted against. That is not a property of rock, it is a property of rock WIDER THAN
## A STROKE: the refusal fires only when a stroke would open no ground at all, and a corridor driven
## at a lump narrower than itself comes out curved around it -- which is the documented rule working,
## not the refusal being broken. So the subject has to be a rock whose stone covers the whole
## footprint of the stroke that will be aimed at it, and that is checked against the field rather
## than guessed from the radius.
##
## Returns `[]` when the layout has no such rock, which the caller reports as scaffolding.
func _blocking_rock(plane: int, clearance: float) -> Array:
	var candidates: Array[RockBody] = []
	for entry: Variant in _network.rock_bodies(plane):
		var rock := entry as RockBody
		if rock != null:
			candidates.append(rock)
	candidates.sort_custom(
		func(a: RockBody, b: RockBody) -> bool: return a.reach() > b.reach()
	)

	var half := TunnelNetwork.SEG_HALF_WIDTH
	for rock: RockBody in candidates:
		for step in range(12):
			var angle := TAU * float(step) / 12.0
			var away := Vector2(cos(angle), sin(angle))
			var side := Vector2(-away.y, away.x)
			var face := rock.edge_along(angle)
			var from := rock.centre + away * (face + clearance)

			# The approach: nothing but earth the whole way in, across the corridor's width -- and
			# STOPPED A HALF WIDTH SHORT OF THE FACE, which is not a fudge, it is where the corridor
			# tip actually ends up. Run all the way to the face instead and the test is impossible
			# to satisfy for exactly the rocks it is looking for: a lump wider than the corridor has
			# stone under the corridor's EDGES well before its centre line reaches the stone, so
			# every wide rock was rejected as unreachable and the check reported the map having no
			# blocking rock when the map was full of them.
			var stop := rock.centre + away * (face + half)
			var clear := true
			for i in range(0, 41):
				var at := from.lerp(stop, float(i) / 40.0)
				for across: float in [-half, 0.0, half]:
					if _network.is_stone_at(plane, at + across * side):
						clear = false
						break
				if not clear:
					break
			if not clear:
				continue

			# And the stone behind the face: a band as wide as the corridor and as deep as one
			# stroke, measured INWARD from the edge. That is the region the next stroke would have
			# to open, and the refusal fires exactly when all of it is rock -- so this is the
			# condition under test, stated in the field's own terms rather than guessed from a
			# radius.
			var blocks := true
			for i in range(1, 9):
				var along := face - TunnelNetwork.SEG_LENGTH * float(i) / 8.0
				if along <= 0.0:
					break
				for across: float in [-half, -half * 0.5, 0.0, half * 0.5, half]:
					var at := rock.centre + away * along + side * across
					if not _network.is_stone_at(plane, at):
						blocks = false
						break
				if not blocks:
					break
			if blocks:
				return [rock, from, angle]
	return []


## A rock cell on `plane` with at least one diggable neighbour, so there is somewhere to stand
## while running into it. MAX if the layout somehow has none.
func _first_rock(plane: int) -> Vector2i:
	var cells: Array = _network.rock_cells(plane)
	cells.sort()  # Deterministic: the same seam every run, so a failure is reproducible.
	for cell: Vector2i in cells:
		if _soft_neighbour(plane, cell) != Vector2i.MAX:
			return cell
	return Vector2i.MAX


func _soft_neighbour(plane: int, cell: Vector2i) -> Vector2i:
	for side: Vector2i in TunnelNetwork.SIDES:
		var beside := cell + side
		if _network.in_bounds(beside) and not _network.is_rock(plane, beside):
			return beside
	return Vector2i.MAX


## Consecutive waypoints must be one step apart: a shared face on the same plane, or the same
## cell across a plane through a shaft. Anything else is a route through earth.
## Every leg of a route, checked to be a leg a mouse could actually take.
##
## `[REVISED]` A STEP IS EIGHT-WAY NOW, AND BEING ONE STEP IS NO LONGER THE POINT. Adjacency was
## the whole test while a corridor was a run of squares; with strokes at free angles it is barely
## half of one, because two cells can share a face and have earth standing in it. So the leg is
## WALKED -- the player's own capsule, in the physics world, from one waypoint to the next -- which
## is the promise the graph is making and the thing a bot will do with the answer.
##
## THE ROUTE'S OWN WAYPOINTS, deliberately, rather than the cell centres they used to be. If the
## graph ever hands back an `at` in solid earth, this is where it is caught, and the capsule cannot
## be talked out of noticing.
func _check_steps(route: Array[Dictionary], label: String) -> void:
	var probe := _capsule_probe()
	for i in range(1, route.size()):
		var here: Vector2i = route[i]["cell"]
		var last: Vector2i = route[i - 1]["cell"]
		var plane: int = route[i]["plane"]
		var was: int = route[i - 1]["plane"]

		if plane == was:
			var gap := here - last
			if maxi(absi(gap.x), absi(gap.y)) != 1:
				_fail("ROUTING", "%s: %v to %v is not one step" % [label, last, here])
				continue
			# Plane 0 legs are the lawn, which is route_planner.gd's business and not a walk
			# between two cells of tunnel.
			if plane == 0:
				continue
			probe.collision_mask = _mask_for(plane)
			if not _capsule_walk(probe, route[i - 1]["at"], route[i]["at"]):
				_fail("ROUTING", "%s: %v to %v is a step the mouse cannot walk" % [label, last, here])
			continue

		if absi(plane - was) != 1 or here != last:
			_fail("ROUTING", "%s: jumped from plane %d to %d" % [label, was, plane])
		elif not _network.has_shaft_down(mini(plane, was), here):
			_fail("ROUTING", "%s: changed plane at %v with no shaft there" % [label, here])


func _report_routing() -> void:
	print("")
	_running.erase("routing")
	print("-- routing")
	if _findings.is_empty():
		print("   ok")
		return
	for finding: String in _findings:
		print("   FAIL %s" % finding)
	_total_failures += _findings.size()


# ---------------------------------------------------------------------------- scenarios


## Drive a corridor from `from` along `step`, stopping at the first cell that won't take.
##
## Models the player rather than the API. A player can only dig where they can stand, so they
## cannot leave a gap behind them and carry on past it -- whereas a bare loop over dig() can,
## and then REACHABLE quite correctly reports the far side as stranded and blames the network
## for what the test did.
func _drive(plane: int, from: Vector2i, step: Vector2i, count: int) -> void:
	for i in range(count):
		var at := from + step * i
		if _network.is_dug(plane, at):
			continue
		if not _network.dig(plane, at):
			return


## Drive a corridor at an arbitrary angle, stroke chained onto stroke, and report where it got to.
##
## THE SAME SHAPE AS `_drive` AND A DIFFERENT UNIT, which is the whole point of it existing: cells
## can only say the four directions they have names for, and everything this file has ever dug has
## therefore been axis-aligned. A graph that only works on axis-aligned corridors passes an audit
## built entirely out of them, which is how four-way survived the change of geometry unnoticed.
##
## Chained end to end, the way the dig controller does it, so consecutive strokes overlap and the
## corridor comes out continuous rather than as a row of discs.
func _drive_angled(plane: int, from: Vector2, angle: int, count: int) -> Vector2:
	var at := from
	for i in range(count):
		if not _network.dig_segment(plane, at, angle):
			break
		at = TunnelNetwork.segment_end(TunnelNetwork.segment_id(at, angle))
	return at


## The cell half a stroke back from a point, which is the last one a corridor certainly claimed.
##
## A stroke's rounded end reaches past its own centreline without making any of that square
## walkable (see TunnelNetwork._probe_cell), so the cell holding the very tip of a corridor is
## routinely not a cell at all. Stepping back to the middle of the last stroke names one that is.
func _cell_behind(tip: Vector2, angle: int) -> Vector2i:
	var back := tip - TunnelNetwork.angle_direction(angle) * (TunnelNetwork.SEG_LENGTH * 0.5)
	return _network.world_to_cell(Vector3(back.x, 0.0, back.y))


## Sink a shaft and go down it, the way pressing F then E does.
func _descend(plane: int, cell: Vector2i) -> bool:
	return _network.dig_shaft_down(plane, cell)


## An entrance from the lawn and a corridor away from it. The shape of the first ten seconds
## of play, and everything else is a variation on it.
func _build_entrance_and_corridor() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 8)
	_drive(1, Vector2i(0, 7), Vector2i(1, 0), 6)


## All the way to the deepest plane, one shaft at a time, each offset from the last so the
## no-stacking rule is satisfied honestly rather than by luck.
func _build_descend_to_the_bottom() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 4)
	_descend(1, Vector2i(0, 3))
	_drive(2, Vector2i(0, 3), Vector2i(1, 0), 4)
	_descend(2, Vector2i(3, 3))
	_drive(3, Vector2i(3, 3), Vector2i(0, -1), 4)


## Dug from underneath with R. Same object as a descent, authored from the other end.
func _build_climb_back_up() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(1, 0), 6)
	# Standing at (5,0) on plane 1, break upward to the surface.
	_network.dig_shaft_up(1, Vector2i(5, 0))


## A shaft down and a shaft up wanting the same cell. Must be refused, or E has two
## destinations and no way to pick.
func _build_stacked_shaft_refused() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 4)
	# (0,0) on plane 1 already has a shaft coming down into it from the lawn.
	_network.dig_shaft_down(1, Vector2i(0, 0))


## F pressed underground where there is no floor to sink from.
func _build_shaft_without_floor() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 3)
	_network.dig_shaft_down(1, Vector2i(9, 9))


## F pressed on the bottom plane. Nothing below to break into.
func _build_shaft_from_deepest_plane() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 3)
	_descend(1, Vector2i(0, 2))
	_drive(2, Vector2i(0, 2), Vector2i(1, 0), 3)
	_descend(2, Vector2i(2, 2))
	_drive(3, Vector2i(2, 2), Vector2i(0, 1), 3)
	_network.dig_shaft_down(3, Vector2i(2, 4))


## Running a corridor back underneath your own entrance. Used to be a trap -- the entrance
## RAMP filled plane 1's headroom at two cells and the corridor could not pass. A shaft
## occupies nothing, so this is now simply a corridor.
func _build_corridor_under_own_entrance() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(1, 0), 5)
	_drive(1, Vector2i(4, 0), Vector2i(0, -1), 5)
	_drive(1, Vector2i(4, -4), Vector2i(-1, 0), 6)
	_drive(1, Vector2i(-1, -4), Vector2i(0, 1), 5)


## Two corridors sharing a footprint on different planes. GDD section 3 makes independent
## per-plane layouts the whole point of having depth, so this must be unremarkable.
func _build_stacked_corridors() -> void:
	_descend(0, Vector2i(-6, 0))
	_drive(1, Vector2i(-6, 0), Vector2i(1, 0), 13)
	_descend(1, Vector2i(6, 0))
	_drive(2, Vector2i(6, 0), Vector2i(-1, 0), 13)


## A shaft sunk directly over a corridor that already exists on the plane below. The old
## VERTICAL invariant existed entirely to forbid this; now it just joins the two.
func _build_shaft_over_existing_corridor() -> void:
	_descend(0, Vector2i(-6, 0))
	_drive(1, Vector2i(-6, 0), Vector2i(1, 0), 10)
	# Clear of the entrance landing: a cell can't be both ends of a shaft, and the exclusion
	# radius keeps the next one off all eight of its neighbours too. At (-5,0) -- one cell
	# along, which is where this sat before the radius existed -- the descent is refused and
	# the rest of the scenario quietly tests nothing.
	_descend(1, Vector2i(-4, 0))
	_drive(2, Vector2i(-4, 0), Vector2i(1, 0), 11)
	# Plane 2 now runs directly under plane 1. Drop a second shaft into the middle of it --
	# the case the retired VERTICAL invariant existed entirely to forbid.
	_network.dig_shaft_down(1, Vector2i(3, 0))


## Corridors driven into all four arena boundaries. What's under test is that the last cell is
## properly walled rather than open to the void.
func _build_corridor_to_every_boundary() -> void:
	var edge := _network.half_extent_cells
	_descend(0, Vector2i(0, 0))
	for step: Vector2i in TunnelNetwork.SIDES:
		_drive(1, Vector2i.ZERO, step, edge + 2)


## A shaft on the very boundary cell, and one outside it.
func _build_shaft_at_boundary() -> void:
	var edge := _network.half_extent_cells
	_descend(0, Vector2i(edge, 0))
	_network.dig_shaft_down(0, Vector2i(edge + 1, 0))


## A wide open room rather than a corridor. Wall generation only emits faces on the outside,
## and the mouse has to fit everywhere inside it.
func _build_wide_chamber() -> void:
	_descend(0, Vector2i(0, 0))
	for x in range(-3, 4):
		_drive(1, Vector2i(x, -3), Vector2i(0, 1), 7)
	_descend(1, Vector2i(2, 2))
	_drive(2, Vector2i(2, 2), Vector2i(1, 0), 4)


## Two entrances into one network, one cell apart.
## Two ways into the same plane. Spaced past the exclusion radius on purpose: put them side by
## side, as this scenario originally did, and the second one is simply refused -- the scenario
## still passes every invariant while quietly testing one entrance instead of two.
func _build_two_entrances() -> void:
	_descend(0, Vector2i(0, 0))
	_descend(0, Vector2i(3, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 5)
	_drive(1, Vector2i(3, 0), Vector2i(0, 1), 5)


## A corridor with its far end brought down by an Engineer (M4).
##
## THE POINT IS THE NINE INVARIANTS ABOVE, applied to geometry that got SMALLER. Everything else
## in this file builds by digging, and collapse is the only operation that removes a cell -- so
## it is the only one that can leave a wall unbuilt, a floor without collision under it, or a
## capsule able to slide into the hole where a tile used to be. Running the whole existing suite
## over it costs one scenario and covers all of that.
##
## A DEAD END, deliberately, so REACHABLE still holds. Collapsing the MIDDLE of a corridor
## strands everything past it -- which is exactly what a cave-in is for, and is asserted on its
## own terms in `_check_collapse` rather than here, where it would read as the network being
## broken. REACHABLE is a rule about what DIGGING may leave behind.
func _build_collapsed_dead_end() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 6)
	_network.collapse(1, Vector2i(0, 5))


## Entrances crowding each other. Every cell touching the first one must be refused, including
## the diagonals -- a diagonal pair is still two mouths you can step between in one move.
func _build_crowded_entrances_refused() -> void:
	_descend(0, Vector2i(0, 0))
	for x in range(-1, 2):
		for y in range(-1, 2):
			_network.dig_shaft_down(0, Vector2i(x, y))
	# One clear cell out, which must be allowed, or the radius is off by one.
	_descend(0, Vector2i(2, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 4)
	_drive(1, Vector2i(2, 0), Vector2i(0, 1), 4)


# ------------------------------------------------------------------------------- audit


func _audit(label: String) -> void:
	_findings.clear()
	_check_shaft_ends()
	_check_no_stack()
	_check_shaft_spacing()
	_check_plane_layers()
	_check_bounds()
	_check_reachable()
	_check_floor_physics()
	_check_headroom()
	_check_containment()
	_check_index_exact()
	_check_no_interior_faces()
	_check_contour_matches_field()
	_check_graph_edges()

	var counts: Array = []
	var shafts := 0
	for plane in range(TunnelNetwork.PLANE_COUNT):
		counts.append(_network.cell_count(plane))
		shafts += (_network._shafts[plane] as Dictionary).size()
	print("")
	print("-- %s  cells/plane %s  shafts %d" % [label, counts, shafts])
	if _findings.is_empty():
		print("   ok")
		return
	for finding: String in _findings:
		print("   FAIL %s" % finding)
	_total_failures += _findings.size()


## The routing graph and the collision mesh agree about where a mouse can go.
##
## THE INVARIANT THE FOUR-WAY GRAPH DIED OF, stated so it cannot come back. Connectivity used to be
## a rule you could read off the cells -- share a face and you are connected -- and off-grid digging
## made that rule wrong in both directions at once: a corridor at an angle runs through cells that
## touch only at their corners, and clips others whose shared face still has a metre of earth in it.
## Neither failure shows up anywhere else. A missing edge is a bot that will not follow you down a
## corridor you are standing in; an extra one is a bot walking into a wall and grinding there, which
## reads as the AI being broken rather than as the map being described wrongly.
##
## SO THE TEST IS NOT A RULE AT ALL, it is the two systems put side by side. tunnel_graph.gd reaches
## its answer from the strokes and the dug field; this asks the PHYSICS ENGINE, by walking the
## player's own capsule between the two standing points, and insists they say the same thing. There
## is no third opinion to appeal to -- the capsule is what the player will actually be.
##
## BOTH DIRECTIONS, which is what makes it teeth-tested rather than decorative. Join all eight
## neighbours blindly and the extra edges fail here; go back to four and every angled corridor in
## the file reports missing ones.
func _check_graph_edges() -> void:
	var graph := _network.graph()
	if graph == null:
		return
	var probe := _capsule_probe()
	var missing: Array = []
	var invented: Array = []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		probe.collision_mask = _mask_for(plane)
		for cell: Vector2i in _network.dug_cells(plane):
			var here := _network.standing_point(plane, cell)
			for side: Vector2i in _compass_cells():
				var next: Vector2i = cell + side
				if not _network.is_dug(plane, next):
					continue
				# Once per pair. The walk is symmetric and it is the expensive half.
				if side.x < 0 or (side.x == 0 and side.y < 0):
					continue
				var walks := _capsule_walk(probe, here, _network.standing_point(plane, next))
				var joined := graph.joined(plane, cell, next)
				if walks and not joined:
					missing.append("plane %d %v-%v" % [plane, cell, next])
				elif joined and not walks:
					invented.append("plane %d %v-%v" % [plane, cell, next])
	if not missing.is_empty():
		_fail("GRAPH_EDGES", "%d walks the graph does not offer: %s" % [
			missing.size(), ", ".join(missing.slice(0, 6))
		])
	if not invented.is_empty():
		_fail("GRAPH_EDGES", "%d edges the mouse cannot walk: %s" % [
			invented.size(), ", ".join(invented.slice(0, 6))
		])


## The occupancy index says exactly what the segments say.
##
## THE BUG CLASS THIS EXISTS FOR is the one the whole hybrid design rests on. Cells are no longer
## the world -- they are a derived index over the strokes, maintained incrementally by `_occupy`
## and `_vacate` as things are dug and brought down. Incremental caches drift, and this one drifts
## silently: a cell left in the index after the last stroke through it is gone is a corridor the
## fog still uncovers, the minimap still draws and a bot will still route through, over ground
## that is solid. Nothing looks wrong until somebody walks into it.
##
## Recomputed from scratch and compared, which is the only check that cannot share the bug.
func _check_index_exact() -> void:
	for plane in range(TunnelNetwork.PLANE_COUNT):
		var wanted := {}
		for id: int in _network.segments(plane):
			for cell: Vector2i in _network.segment_cells(id):
				wanted[cell] = true

		var held := {}
		for cell: Vector2i in _network.dug_cells(plane):
			held[cell] = true

		for cell: Vector2i in wanted:
			if not held.has(cell):
				_fail("INDEX_EXACT", "plane %d %v is under a stroke and not in the index"
					% [plane, cell])
				return
		for cell: Vector2i in held:
			if not wanted.has(cell):
				_fail("INDEX_EXACT", "plane %d %v is in the index with no stroke under it"
					% [plane, cell])
				return

		# The reverse index has to agree too, and it is the one that decides when a cell CLOSES.
		# A stale id left in a cell's set keeps that cell open forever after a cave-in.
		for cell: Vector2i in held:
			for id: int in _network.segments_in_cell(plane, cell):
				if not _network.has_segment(plane, id):
					_fail("INDEX_EXACT", "plane %d %v still lists a stroke that is gone"
						% [plane, cell])
					return


## Every wall face stands exactly where earth meets air.
##
## THE ARTIFACT CONTOURING EXISTS TO PREVENT is a fin: a wall left standing across a corridor where
## two strokes overlap, which is what per-stroke geometry would produce at every bend and every
## branch. Contouring the union structurally cannot make one, so what is worth checking is that the
## union is what got contoured -- a chunk built from a stale stroke set, or one stroke missed off a
## chunk's gather, leaves a wall hanging in open tunnel and nothing else would notice.
##
## ASKED AS A DISTANCE RATHER THAN AS "IS THERE TUNNEL ON BOTH SIDES", which was the first version
## of this check and produced two false alarms immediately. Stepping a fixed distance either side
## calls a genuinely THIN wall of earth -- two corridors passing close, which the scenarios build
## deliberately -- a fin, because the step lands inside the tunnel on the far side. Distance to the
## nearest stroke surface has no such ambiguity: on a true outline it is zero however thin the
## earth behind it, and a fin is buried well inside a stroke and reads strongly negative.
func _check_no_interior_faces() -> void:
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		for instance in _network._walls[plane].get_children():
			var walls := (instance as MeshInstance3D).mesh as ArrayMesh
			if walls == null:
				continue
			var faces: PackedVector3Array = walls.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			# ASKED OF THE FOOT OF EACH FACE. A face is a strip of rows (TunnelContour.WALL_RINGS) and
			# every row above the first is deliberately set BACK from the outline, into the earth,
			# which this check has no quarrel with -- it is hunting for faces standing on the wrong
			# side of it. The bottom row is the one on the outline and the one worth measuring.
			for t in range(0, faces.size(), TunnelContour.face_verts()):
				var middle := (faces[t] + faces[t + 1]) * 0.5
				var at := Vector2(middle.x, middle.z)
				var distance := _distance_to_tunnel(plane, at)
				# One texel of slack. The contour interpolates the crossing point along a texel edge,
				# so a face can sit a fraction of a texel off the true surface and be perfectly correct.
				if distance < -TunnelContour.TEXEL:
					_fail("NO_INTERIOR_FACES",
						"plane %d has a wall at %.2f,%.2f standing %.2fm inside the tunnel"
						% [plane, middle.x, middle.z, -distance])
					return


## Distance from a point to the nearest stroke surface: negative inside, zero on the wall.
##
## Only the strokes registered NEAR the point are considered, through the cell index. Scanning
## every stroke on the plane is what the first version did, and on the 441-cell scenario that is
## several million distance evaluations for one check.
func _distance_to_tunnel(plane: int, at: Vector2) -> float:
	var best := 1000.0
	var centre := _network.world_to_cell(Vector3(at.x, 0.0, at.y))
	for y in range(centre.y - 2, centre.y + 3):
		for x in range(centre.x - 2, centre.x + 3):
			for id: int in _network.segments_in_cell(plane, Vector2i(x, y)):
				best = minf(best, TunnelContour.segment_distance(
					at, TunnelNetwork.segment_origin(id), TunnelNetwork.segment_end(id),
					TunnelNetwork.SEG_HALF_WIDTH
				))
	return best


## What the lid discards agrees with what the floor is built from.
##
## THE DRAWN WORLD AND THE WALKED WORLD ARE TWO ARTEFACTS OFF ONE FIELD -- the cutaway texture the
## shader samples, and the contour the collision mesh is built from -- and the failure mode when
## they disagree is the nastiest kind: everything looks right and you cannot walk where you can
## plainly see. Checked at cell centres through `is_cut_away`, which reads the actual texture
## rather than recomputing the rule, so this compares the picture against the geometry.
##
## Only meaningful with no crew filter applied. Under a viewing crew the cutaway is deliberately
## SMALLER than the world -- that is the fog -- so a mismatch there is the feature working.
func _check_contour_matches_field() -> void:
	if _network._view_team >= 0:
		return
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network.dug_cells(plane):
			if not _network.is_cut_away(plane, cell):
				_fail("CONTOUR_MATCHES_FIELD",
					"plane %d %v is dug and the earth above it is not cut away" % [plane, cell])
				return


func _fail(check: String, detail: String) -> void:
	_findings.append("[%s] %s" % [check, detail])


## The harness itself is broken. Counted as a failure rather than skipped: a scenario that did
## not run is not a scenario that passed, and the exit code has to say so.
func _broken(label: String, why: String) -> void:
	print("")
	print("-- %s" % label)
	print("   BROKEN %s" % why)
	_total_failures += 1


## Both ends of a shaft have to be somewhere you can stand: floor below, and floor above
## unless the top is the lawn, which is everywhere.
func _check_shaft_ends() -> void:
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._shafts[plane]:
			if plane > 0 and not _network.is_dug(plane, cell):
				_fail("SHAFT_ENDS", "shaft at plane %d %v has no floor at the top" % [plane, cell])
			if plane + 1 >= TunnelNetwork.PLANE_COUNT:
				_fail("SHAFT_ENDS", "shaft at plane %d %v has no plane below" % [plane, cell])
			elif not _network.is_dug(plane + 1, cell):
				_fail("SHAFT_ENDS", "shaft at plane %d %v lands on solid earth" % [plane, cell])


## Nothing may have a way up AND a way down. E has one key and needs one answer.
func _check_no_stack() -> void:
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._shafts[plane]:
			if plane + 1 < TunnelNetwork.PLANE_COUNT and _network._shafts[plane + 1].has(cell):
				_fail("NO_STACK", "plane %d %v has shafts both up and down" % [plane + 1, cell])


## Shaft mouths keep their distance. Checked across ADJACENT LAYERS as well as within one,
## because a shaft recorded at plane N is a hole in N's floor and a hole in the ceiling of
## N+1 -- so a floor hole and a ceiling hole a cell apart are two mouths in the same corridor
## even though they live in different rows of _shafts.
func _check_shaft_spacing() -> void:
	var reach: int = _network.shaft_exclusion_cells
	if reach <= 0:
		return
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._shafts[plane]:
			for other_plane in range(plane, mini(plane + 2, TunnelNetwork.PLANE_COUNT)):
				for other: Vector2i in _network._shafts[other_plane]:
					if other == cell and other_plane == plane:
						continue
					var gap := maxi(absi(other.x - cell.x), absi(other.y - cell.y))
					if gap > 0 and gap <= reach:
						_fail("SHAFT_SPACING", "shafts %v (plane %d) and %v (plane %d) are %d cell(s) apart" % [
							cell, plane, other, other_plane, gap])


## Each plane's geometry on its own layer, which is what lets a barrier overshoot without
## fencing off the layer above.
func _check_plane_layers() -> void:
	for plane in range(TunnelNetwork.PLANE_COUNT):
		var body := _network.get_node_or_null("Collision%d" % plane) as StaticBody3D
		if body == null:
			_fail("PLANE_LAYERS", "plane %d has no collision body" % plane)
			continue
		var wanted := TunnelNetwork.plane_bit(plane)
		if body.collision_layer != wanted:
			_fail("PLANE_LAYERS", "plane %d is on layer %d, wanted %d" % [
				plane, body.collision_layer, wanted
			])


func _check_bounds() -> void:
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._cells[plane]:
			if not _network.in_bounds(cell):
				_fail("BOUNDS", "plane %d %v is outside the arena" % [plane, cell])


## Walk the network the way a player does and see what can't be got to.
##
## Roots are the surface shafts, since the lawn is walkable everywhere. Any dug cell not
## reached is earth that was removed and can never be stood in.
func _check_reachable() -> void:
	var seen: Dictionary = {}
	var queue: Array[Vector3i] = []
	for cell: Vector2i in _network._shafts[0]:
		var node := Vector3i(0, cell.x, cell.y)
		seen[node] = true
		queue.append(node)

	if queue.is_empty() and _total_dug() > 0:
		_fail("REACHABLE", "network has dug cells but no surface entrance")
		return

	while not queue.is_empty():
		var node: Vector3i = queue.pop_back()
		for next: Vector3i in _walkable_from(node.x, Vector2i(node.y, node.z)):
			if seen.has(next):
				continue
			seen[next] = true
			queue.append(next)

	var unreachable: Array = []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._cells[plane]:
			if not seen.has(Vector3i(plane, cell.x, cell.y)):
				unreachable.append("plane %d %v" % [plane, cell])
	if not unreachable.is_empty():
		_fail("REACHABLE", "%d cells unreachable from any entrance: %s" % [
			unreachable.size(), ", ".join(unreachable.slice(0, 8))
		])


## Independent of the network's own idea of connectivity, on purpose: a check that shares an
## implementation with the thing it checks proves only that the code agrees with itself.
##
## `[REVISED]` AND IT HAD TO STOP BEING FOUR SIDES, for the same reason the graph did. This used to
## call two cells connected when they shared a face, which off-grid digging makes wrong in both
## directions -- a corridor at 30 degrees runs through cells that touch only at their corners, and
## clips others whose shared face is still a metre of earth. What kept it honest through the change
## is that it does not ask the network anything: eight candidates, and the PHYSICS decides, by
## walking the player's own capsule from one standing point to the other. The graph reaches its
## answer from the strokes; this one reaches it from the collision mesh those strokes generated,
## which is exactly the disagreement worth having a second opinion about.
func _walkable_from(plane: int, cell: Vector2i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	# Plane 0 is the lawn: you can be anywhere on it, so the only edge that matters is down.
	if plane > 0:
		var probe := _capsule_probe()
		probe.collision_mask = _mask_for(plane)
		var here := _network.standing_point(plane, cell)
		for side: Vector2i in _compass_cells():
			var next := cell + side
			if not _network.is_dug(plane, next):
				continue
			if not _capsule_walk(probe, here, _network.standing_point(plane, next)):
				continue
			out.append(Vector3i(plane, next.x, next.y))
	if _network.has_shaft_down(plane, cell):
		out.append(Vector3i(plane + 1, cell.x, cell.y))
	if _network.has_shaft_up(plane, cell):
		out.append(Vector3i(plane - 1, cell.x, cell.y))
	return out


## Render and collision are generated from the same cell data but by different code, and they
## have silently disagreed before. Drop a ray on every floor cell and insist.
func _check_floor_physics() -> void:
	var misses: Array = []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._cells[plane]:
			var top := _network.plane_y(plane)
			# WHERE THE TUNNEL ACTUALLY IS IN THIS CELL, not the middle of the square. A corridor
			# a metre wide running at an angle across a metre grid does not cover every cell
			# centre it passes through -- so a ray dropped at the centre can miss floor that is
			# plainly there, twenty centimetres away. See TunnelNetwork.standing_point.
			var at := _network.standing_point(plane, cell)
			var query := PhysicsRayQueryParameters3D.create(
				at + Vector3.UP * 0.3, at + Vector3.DOWN * 0.3
			)
			query.collision_mask = _mask_for(plane)
			var hit: Dictionary = _space.intersect_ray(query)
			if hit.is_empty():
				misses.append("plane %d %v" % [plane, cell])
			elif absf((hit["position"] as Vector3).y - top) > 0.05:
				misses.append("plane %d %v at y=%.2f (wanted %.2f)" % [
					plane, cell, (hit["position"] as Vector3).y, top
				])
	if not misses.is_empty():
		_fail("FLOOR_PHYSICS", "%d cells without a floor beneath them: %s" % [
			misses.size(), ", ".join(misses.slice(0, 8))
		])


## Can the mouse actually STAND in every cell it can dig?
##
## The exact failure that lowering PLANE_SPACING invites. Bringing the planes from 1.5 to 0.65
## made the tunnels visible and simultaneously slid every ceiling down onto the mouse's head --
## with a 0.5-thick lawn slab there was 0.15 of air above plane 1's floor and a mouse is 0.4
## tall. Nothing about that shows up as a fall or a hole; the mouse simply spends the whole
## game wedged in the ground, which is why it needs asking directly.
func _check_headroom() -> void:
	var probe := _capsule_probe()
	var squashed: Array = []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		probe.collision_mask = _mask_for(plane)
		for cell: Vector2i in _network._cells[plane]:
			# The spot in this cell a mouse would stand on, which on an angled corridor is not the
			# centre of the square. See _check_floor_physics.
			var feet := _network.standing_point(plane, cell)
			probe.transform = Transform3D(Basis(), feet + Vector3.UP * (0.2 + STAND_EPSILON))
			probe.motion = Vector3.ZERO
			if not _space.intersect_shape(probe, 1).is_empty():
				squashed.append("plane %d %v in %s" % [
					plane, cell, _blocker(probe, feet, STAND_EPSILON)
				])
	if not squashed.is_empty():
		_fail("HEADROOM", "%d cells the mouse cannot stand up in: %s" % [
			squashed.size(), ", ".join(squashed.slice(0, 5))
		])


## Stand the player's own capsule in every dug cell, slide it eight ways, and check that
## everywhere it can REACH has ground under it.
##
## The only check that can find a hole nobody predicted. The others encode my model of the
## geometry, so they can only catch mistakes that model already anticipates -- and every
## fall-out-of-the-world bug so far has been a case where the model and the collision trimesh
## disagreed. Here the question is put to the physics engine in the terms the player
## experiences it: can I get to a place with nothing to stand on?
func _check_containment() -> void:
	var probe := _capsule_probe()
	var escapes: Array = []
	var unprobed: Array = []

	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		# The player's real mask for this layer. Anything on another plane is not merely
		# ignored here, it genuinely cannot touch a mouse standing on this one.
		probe.collision_mask = _mask_for(plane)
		for cell: Vector2i in _network._cells[plane]:
			# Started from where the tunnel actually is in this cell rather than from the middle
			# of the square. See _check_floor_physics -- and note that this check then SLIDES the
			# capsule eight ways from here, so it still explores the whole cell and beyond.
			var floor_at := _network.standing_point(plane, cell)
			var stand: Variant = _clear_stance(probe, floor_at)
			if stand == null:
				unprobed.append("plane %d %v (blocked by %s)" % [
					plane, cell, _blocker(probe, floor_at, 0.24)
				])
				continue
			var feet: Vector3 = stand
			for direction: Vector3 in _compass():
				if _obstructed(probe, feet, direction):
					continue  # Walled. Contained.
				var landed := feet + direction * REACH
				var down := PhysicsRayQueryParameters3D.create(
					landed + Vector3.UP * RAY_RISE, landed + Vector3.DOWN * MAX_DROP
				)
				down.collision_mask = probe.collision_mask
				if _space.intersect_ray(down).is_empty():
					escapes.append("plane %d %v toward (%.1f,%.1f)" % [
						plane, cell, direction.x, direction.z
					])

	if not escapes.is_empty():
		_fail("CONTAINMENT", "%d ways to walk into open air: %s" % [
			escapes.size(), ", ".join(escapes.slice(0, 6))
		])
	# Reported rather than swallowed. A sample we couldn't stand up in proved nothing, and
	# silently dropping it is how an audit starts lying.
	if not unprobed.is_empty():
		_fail("CONTAINMENT", "%d samples had no collision-free stance: %s" % [
			unprobed.size(), ", ".join(unprobed.slice(0, 6))
		])


## Can the capsule get from `feet` to `feet + direction * REACH`?
##
## Stepped overlap tests rather than one cast_motion sweep, and that is not stylistic.
## cast_motion against these wall quads reported a clear sweep straight THROUGH a wall -- the
## quads are zero-thickness trimesh faces, which is the case swept trimesh queries handle
## worst. intersect_shape at intervals catches them, at the cost of a few thousand extra
## queries nobody is waiting on.
func _obstructed(
	probe: PhysicsShapeQueryParameters3D, feet: Vector3, direction: Vector3
) -> bool:
	probe.motion = Vector3.ZERO
	var travelled := STEP
	while travelled <= REACH:
		var at := feet + direction * travelled
		probe.transform = Transform3D(Basis(), at + Vector3.UP * 0.2)
		if not _space.intersect_shape(probe, 1).is_empty():
			return true
		travelled += STEP
	return false


## Find a pose at or just above `feet` where the capsule isn't already intersecting.
##
## Load-bearing, not defensive politeness: a query started from an INTERSECTING pose reports
## no collision, indistinguishable from open air, so a buried capsule reads as an escape in
## all eight directions. That produced 45 confident false alarms on a network with nothing
## wrong with it.
func _clear_stance(probe: PhysicsShapeQueryParameters3D, feet: Vector3) -> Variant:
	for lift: float in [STAND_EPSILON, 0.06, 0.10, 0.14, 0.18, 0.24]:
		var at := feet + Vector3.UP * lift
		probe.transform = Transform3D(Basis(), at + Vector3.UP * 0.2)
		probe.motion = Vector3.ZERO
		if _space.intersect_shape(probe, 1).is_empty():
			return at
	return null


## What the capsule is buried in, for the report. "No stance" alone sends you reasoning about
## geometry in your head; the collider tells you in one line.
func _blocker(probe: PhysicsShapeQueryParameters3D, feet: Vector3, lift: float) -> String:
	probe.transform = Transform3D(Basis(), feet + Vector3.UP * (0.2 + lift))
	probe.motion = Vector3.ZERO
	var names: Array[String] = []
	for hit: Dictionary in _space.intersect_shape(probe, 4):
		var collider: Object = hit.get("collider")
		if collider is Node:
			names.append((collider as Node).name)
	return ", ".join(names) if not names.is_empty() else "nothing (probe fault)"


## The player's actual collider, so this measures the body that will really be there.
func _capsule_probe() -> PhysicsShapeQueryParameters3D:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.16
	capsule.height = 0.4
	var probe := PhysicsShapeQueryParameters3D.new()
	probe.shape = capsule
	return probe


func _mask_for(plane: int) -> int:
	return TunnelNetwork.WORLD_BIT | TunnelNetwork.plane_bit(plane)


## The eight cells around one. Candidates for a step, settled by [method _capsule_walk].
func _compass_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for x in [-1, 0, 1]:
		for y in [-1, 0, 1]:
			if x != 0 or y != 0:
				out.append(Vector2i(x, y))
	return out


## Can the player's own capsule get from one standing point to another in a straight line?
##
## THE AUDIT'S WHOLE ANSWER TO "ARE THESE TWO CELLS CONNECTED", and it is deliberately the question
## a bot's legs ask rather than the one the graph asks. Underground a bot walks straight at its next
## waypoint, so a route is only ever as good as this.
##
## Stepped overlap tests rather than a cast_motion sweep, for the reason [method _obstructed] gives
## at length: the walls are zero-thickness trimesh quads and swept queries walk straight through
## them. Both ends are lifted to a clear stance first -- a query begun from an intersecting pose
## reports open air, which would turn every walled-off pair into a connection.
func _capsule_walk(
	probe: PhysicsShapeQueryParameters3D, from: Vector3, to: Vector3
) -> bool:
	var start: Variant = _clear_stance(probe, from)
	if start == null:
		return false
	var feet: Vector3 = start
	var lift := feet.y - from.y
	var target := to + Vector3.UP * lift
	var span := feet.distance_to(target)
	if span < 0.0001:
		return true
	var direction := (target - feet) / span
	var travelled := STEP
	while travelled <= span:
		probe.transform = Transform3D(Basis(), feet + direction * travelled + Vector3.UP * 0.2)
		probe.motion = Vector3.ZERO
		if not _space.intersect_shape(probe, 1).is_empty():
			return false
		travelled += STEP
	return true


## Eight directions, because the dig controller cuts on eight and the player moves freely.
func _compass() -> Array:
	var out: Array = []
	for x in [-1, 0, 1]:
		for z in [-1, 0, 1]:
			if x == 0 and z == 0:
				continue
			out.append(Vector3(x, 0.0, z).normalized())
	return out


func _total_dug() -> int:
	var total := 0
	for plane in range(TunnelNetwork.PLANE_COUNT):
		total += _network.cell_count(plane)
	return total
