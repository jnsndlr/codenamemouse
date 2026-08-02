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
const STRIP: Array[String] = [
	"Player", "CameraRig", "DigController", "DepthFocus", "FallGuard", "HUD", "Surface/Rocks",
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

	await _check_dig_flow()
	await _check_routing()
	await _check_collapse()
	await _check_rock()
	await _check_reveal()
	await _check_seal()

	print("")
	print("=".repeat(78))
	if _total_failures == 0:
		print("ALL INVARIANTS HOLD across %d scenarios, plus dig flow, routing, collapse, rock,"
			% scenarios.size() + " reveal and paving.")
	else:
		print("%d failures across %d scenarios plus dig flow, routing, collapse, rock, reveal"
			% [_total_failures, scenarios.size()] + " and paving.")
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
func _arena(strip: Array[String], rock: bool = false) -> Node:
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
	var player: Node3D = _scene.get_node("Player")
	var controller: Node = _scene.get_node("DigController")
	network.dig_shaft_down(0, Vector2i(0, 0))
	await process_frame
	await physics_frame

	player.set_physics_process(false)
	controller.set_physics_process(false)
	player.global_position = network.cell_to_world(1, Vector2i(0, 0)) + Vector3.UP * 0.05
	controller._plane = 1

	_findings.clear()
	var neighbour := Vector2i(0, 1)
	var slow := Vector2i(0, -1)
	var far := Vector2i(0, 9)

	# Adjacent, within reach, undug: an ENGINEER should open it after dig_seconds of holding.
	# Forty frames is two thirds of a second against a dig_seconds of 0.5.
	player.set_class(MouseClass.ENGINEER)
	player._aim_point = network.cell_to_world(1, neighbour)
	Input.action_press("dig")
	for i in range(40):
		controller._update_dig(1.0 / 60.0)
	if not network.is_dug(1, neighbour):
		_fail("DIG_FLOW", "an Engineer holding on an adjacent tile did not open it")

	# THE SPREAD, WHICH IS THE WHOLE POINT OF THE CLASS. Everybody can dig; the Engineer is about
	# three times faster (GDD section 4, revised -- see the note there). Both halves are asserted
	# because both are design: a Generalist must NOT open a tile in the time an Engineer does, or
	# the Engineer is decorative -- and must open it eventually, or a crew that loses its Engineer
	# is locked out of a third of the map.
	player.set_class(MouseClass.GENERALIST)
	player._aim_point = network.cell_to_world(1, slow)
	for i in range(40):
		controller._update_dig(1.0 / 60.0)
	if network.is_dug(1, slow):
		_fail("DIG_FLOW", "a Generalist dug as fast as an Engineer")
	for i in range(100):
		controller._update_dig(1.0 / 60.0)
	if not network.is_dug(1, slow):
		_fail("DIG_FLOW", "a Generalist could not open a tile however long it held")

	# Out of reach: must stay shut no matter how long you hold.
	player._aim_point = network.cell_to_world(1, far)
	for i in range(60):
		controller._update_dig(1.0 / 60.0)
	if network.is_dug(1, far):
		_fail("DIG_FLOW", "a tile %s cells away was diggable" % far.length())
	Input.action_release("dig")

	# Not holding: nothing opens however long you point at it.
	var another := Vector2i(1, 0)
	player._aim_point = network.cell_to_world(1, another)
	for i in range(40):
		controller._update_dig(1.0 / 60.0)
	if network.is_dug(1, another):
		_fail("DIG_FLOW", "a tile opened without the dig button held")

	print("")
	print("-- dig_flow")
	if _findings.is_empty():
		print("   ok")
		return
	for finding: String in _findings:
		print("   FAIL %s" % finding)
	_total_failures += _findings.size()


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

	# THE DIAGONAL. A staircase of corner-touching cells is not walkable and must not be
	# routable -- and the two cells at the ends of it are four cells apart in plan view, so a
	# graph that answers at all here is answering through solid earth.
	if not await _fresh_network():
		_broken("routing", "the arena would not build")
		return
	_descend(0, Vector2i(0, 0))
	for i in range(1, 5):
		_network.dig(1, Vector2i(i, i))
	graph = _network.graph()
	if not graph.route(1, Vector2i(0, 0), 1, Vector2i(4, 4)).is_empty():
		_fail("ROUTING", "a diagonal staircase routed as if it were a corridor")

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

	# A SHAFT HOLDS ITS STRETCH OPEN. Either end of a shaft is refused, or the audit's own
	# SHAFT_ENDS invariant would start failing the moment anyone used the ability near a ladder --
	# and in play it is a mouse pressing E and arriving inside solid ground.
	if _network.collapse(1, Vector2i(0, 0)):
		_fail("COLLAPSE", "the cell under an entrance came down")
	_descend(1, Vector2i(0, 6))
	if _network.collapse(1, Vector2i(0, 6)):
		_fail("COLLAPSE", "a cell with a shaft leading down came down")
	if _network.collapse(2, Vector2i(0, 6)):
		_fail("COLLAPSE", "the cell a shaft lands on came down")

	# The surface is not diggable and not collapsible either.
	if _network.collapse(0, Vector2i(0, 0)):
		_fail("COLLAPSE", "a piece of the lawn came down")

	print("")
	print("-- collapse")
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
	_scene = _arena(["Player", "CameraRig", "DigController", "DepthFocus", "FallGuard", "HUD",
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

	# A seam refuses the dig, SAYS SO, and stays refused. A tile that silently does nothing is
	# indistinguishable from a broken control -- the lesson the entrance key taught once already.
	var spoken: Array[String] = []
	_network.dig_refused.connect(func(reason: String) -> void: spoken.append(reason))
	var seam := _first_rock(1)
	if seam == Vector2i.MAX:
		_fail("ROCK", "no rock on plane 1 with soft ground beside it -- nothing to test")
	else:
		var beside := _soft_neighbour(1, seam)
		_network.dig(1, beside)
		if _network.dig(1, seam):
			_fail("ROCK", "a rock cell opened")
		if _network.is_dug(1, seam):
			_fail("ROCK", "the rock cell is dug afterwards")
		if spoken.is_empty():
			_fail("ROCK", "digging into rock refused silently")
		if _network.graph().has(1, seam):
			_fail("ROCK", "the routing graph will send a bot through the seam")

		# An entrance cannot be sunk into rock either, from either end. Both matter: a shaft that
		# lands in solid ground is the SHAFT_ENDS invariant failing from a direction no scenario
		# builds by hand.
		if _network.dig_shaft_down(0, seam):
			_fail("ROCK", "an entrance was sunk from the lawn into rock")

	var deep := _first_rock(2)
	if deep != Vector2i.MAX:
		_network.dig(1, deep)
		if _network.dig_shaft_down(1, deep):
			_fail("ROCK", "a shaft was sunk onto rock a plane below")
		if _network.is_dug(2, deep):
			_fail("ROCK", "and it opened the rock cell it landed on")

	print("")
	print("-- rock  cells/plane %s" % [counts])
	if _findings.is_empty():
		print("   ok")
	else:
		for finding: String in _findings:
			print("   FAIL %s" % finding)
		_total_failures += _findings.size()


## What a crew knows about the rock, and what it does not. (M4, GDD section 3)
##
## HIDDEN INFORMATION FAILS SILENTLY AND IN ONE DIRECTION -- towards knowing too much -- which is
## the same reason the match audit checks spotting so carefully. A reveal that leaks to both crews
## looks exactly like a reveal that works, from the only seat anybody plays from. So every
## assertion here has a mirror: what BLUE learned, and what RED still must not know.
##
## THE WHOLE VEIN, not the cell you hit, and the flood fill is four-way like everything else in this
## system. Two seams that touch at a corner are one blob to an eight-way fill and two separate
## problems to a mouse, who cannot dig through a corner -- so the fill has to agree with the walls.
func _check_reveal() -> void:
	_findings.clear()
	if _scene != null:
		_scene.free()
	# Rock ON, and the player and its controller KEPT: half of this check is the rule and half is
	# the wiring from a mouse pressing a button to the crew knowing something.
	_scene = _arena(["CameraRig", "DepthFocus", "FallGuard", "HUD", "Surface/Rocks",
		"MatchDirector", "Navigation", "Nests"], true)
	await process_frame
	await physics_frame
	_network = _scene.get_node("Tunnels") as TunnelNetwork

	var seam := _first_rock(1)
	if seam == Vector2i.MAX:
		_broken("reveal", "no rock on plane 1 with soft ground beside it -- nothing to run into")
		return

	# Nobody knows anything yet. Asserted first, because every "BLUE learned it" line below would
	# pass just as well against a network that hands out the whole layout from the first frame.
	if not _network.known_rock_cells(1, Team.BLUE).is_empty():
		_fail("REVEAL", "a crew knows where rock is before anybody has touched any")
	if _network.is_rock_known(1, seam, Team.BLUE):
		_fail("REVEAL", "the seam is known to BLUE before it has been dug into")

	var learned := _network.reveal_vein(1, seam, Team.BLUE)
	if learned <= 0:
		_fail("REVEAL", "running into a seam taught the crew nothing")

	# The vein, worked out here independently of the network's own fill -- a check that asked the
	# thing under test to define the right answer would pass whatever the fill did.
	var vein := {seam: true}
	var edge: Array[Vector2i] = [seam]
	while not edge.is_empty():
		var at: Vector2i = edge.pop_back()
		for side: Vector2i in TunnelNetwork.SIDES:
			var beside: Vector2i = at + side
			if vein.has(beside) or not _network.is_rock(1, beside):
				continue
			vein[beside] = true
			edge.append(beside)

	if learned != vein.size():
		_fail("REVEAL", "the whole vein is revealed (%d cells learned, the vein is %d)"
			% [learned, vein.size()])
	for cell: Vector2i in vein:
		if not _network.is_rock_known(1, cell, Team.BLUE):
			_fail("REVEAL", "cell %v of the vein was left unknown" % cell)
			break
	var mapped := _network.known_rock_cells(1, Team.BLUE).size()
	if mapped != vein.size():
		_fail("REVEAL", "the crew knows %d rock cells and the vein is %d -- the fill %s"
			% [mapped, vein.size(),
			"ran into unconnected rock" if mapped > vein.size() else "stopped short"])

	# AND THE OTHER CREW STILL HAS NO IDEA. The one assertion this whole feature exists for.
	if _network.is_rock_known(1, seam, Team.RED):
		_fail("REVEAL", "the other crew learned where the rock is for free")
	if not _network.known_rock_cells(1, Team.RED).is_empty():
		_fail("REVEAL", "the other crew's map filled in by itself")
	# Nor does the same crew learn about the plane below by digging into this one.
	if not _network.known_rock_cells(2, Team.BLUE).is_empty():
		_fail("REVEAL", "digging into plane 1 revealed rock on plane 2")

	if _network.reveal_vein(1, seam, Team.BLUE) != 0:
		_fail("REVEAL", "running into the same seam twice reported learning it twice")

	# THE PICTURE FOLLOWS THE KNOWLEDGE, and it is drawn for exactly one crew. Without this the
	# whole reveal can be correct and invisible, which from the only seat anybody plays from is
	# indistinguishable from it not working.
	_network.show_known_rock(Team.BLUE)
	if (_network._rock_caps[1] as MeshInstance3D).mesh == null:
		_fail("REVEAL", "the vein was learned but nothing is drawn over it")
	_network.show_known_rock(Team.RED)
	if (_network._rock_caps[1] as MeshInstance3D).mesh != null:
		_fail("REVEAL", "the other crew is shown a vein it has never touched")

	# AND THE CONTROLS DO IT. Everything above tests the rule; this tests that a mouse pressing the
	# dig button on a seam is what triggers it -- the half a player actually touches, and the half
	# that is one forgotten line away from never running.
	if not await _fresh_reveal_scene():
		_broken("reveal", "the arena would not build a second time")
		return
	var seam2 := _first_rock(1)
	var beside := _soft_neighbour(1, seam2)
	if seam2 == Vector2i.MAX or beside == Vector2i.MAX:
		_broken("reveal", "no seam with soft ground beside it in the second arena")
		return
	_network.dig(1, beside)
	var player: Node3D = _scene.get_node("Player")
	var controller: Node = _scene.get_node("DigController")
	player.set_physics_process(false)
	controller.set_physics_process(false)
	player.global_position = _network.cell_to_world(1, beside) + Vector3.UP * 0.05
	controller._plane = 1
	player.set("team", Team.RED)
	player._aim_point = _network.cell_to_world(1, seam2)
	# A FRAME BETWEEN THE PRESS AND THE READ. `Input.action_press` is buffered and does not become
	# visible to `is_action_pressed` until the next flush, so pressing and polling in the same
	# breath reports a button nobody is holding -- and the rock branch, which needs the press to be
	# NEW, never runs. It cost this check a wrong red before it cost anyone a wrong green.
	Input.action_press("dig")
	await process_frame
	controller._update_dig(1.0 / 60.0)
	Input.action_release("dig")
	if not _network.is_rock_known(1, seam2, Team.RED):
		_fail("REVEAL", "digging into a seam with the actual controls revealed nothing")
	if _network.is_rock_known(1, seam2, Team.BLUE):
		_fail("REVEAL", "and it told the other crew as well")

	# AND THE PATH THAT ACTUALLY HAPPENS: not swinging at the rock, but opening the cell beside it
	# and exposing its face. This is the one a player hits without meaning to, and it is the one the
	# feature originally missed -- the cursor greys out over rock specifically to say "don't hold
	# the button here", so almost nobody was ever going to trigger the head-on version.
	if not await _fresh_reveal_scene():
		_broken("reveal", "the arena would not build a third time")
		return
	var seam3 := _first_rock(1)
	var face := _soft_neighbour(1, seam3)
	if seam3 == Vector2i.MAX or face == Vector2i.MAX:
		_broken("reveal", "no seam with soft ground beside it in the third arena")
		return
	# Stand one cell further back, so the tile being opened is the one that touches the rock and the
	# player is not already standing against it.
	var back := face + (face - seam3)
	if _network.is_rock(1, back):
		_broken("reveal", "the cell behind the face is rock too -- nowhere to dig from")
		return
	_network.dig(1, back)
	var digger: Node3D = _scene.get_node("Player")
	var arm: Node = _scene.get_node("DigController")
	digger.set_physics_process(false)
	arm.set_physics_process(false)
	digger.global_position = _network.cell_to_world(1, back) + Vector3.UP * 0.05
	arm._plane = 1
	digger.set("team", Team.BLUE)
	digger.set_class(MouseClass.ENGINEER)
	digger._aim_point = _network.cell_to_world(1, face)
	Input.action_press("dig")
	await process_frame
	for i in range(40):
		arm._update_dig(1.0 / 60.0)
	Input.action_release("dig")
	if not _network.is_dug(1, face):
		_broken("reveal", "the tile beside the seam never opened -- nothing was exposed")
		return
	if not _network.is_rock_known(1, seam3, Team.BLUE):
		_fail("REVEAL", "opening the cell beside a seam exposed its face and taught nobody anything")
	if _network.is_rock_known(1, seam3, Team.RED):
		_fail("REVEAL", "and exposing a face told the other crew too")

	print("")
	print("-- reveal")
	if _findings.is_empty():
		print("   ok")
	else:
		for finding: String in _findings:
			print("   FAIL %s" % finding)
		_total_failures += _findings.size()


## A second arena with rock on and the controls attached, for the half of the reveal check that
## drives the dig button rather than the rule.
func _fresh_reveal_scene() -> bool:
	if _scene != null:
		_scene.free()
	_scene = _arena(["CameraRig", "DepthFocus", "FallGuard", "HUD", "Surface/Rocks",
		"MatchDirector", "Navigation", "Nests"], true)
	if _scene == null:
		return false
	await process_frame
	await physics_frame
	_network = _scene.get_node_or_null("Tunnels") as TunnelNetwork
	return _network != null


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
	print("-- paving")
	if _findings.is_empty():
		print("   ok")
	else:
		for finding: String in _findings:
			print("   FAIL %s" % finding)
		_total_failures += _findings.size()


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
func _check_steps(route: Array[Dictionary], label: String) -> void:
	for i in range(1, route.size()):
		var here: Vector2i = route[i]["cell"]
		var last: Vector2i = route[i - 1]["cell"]
		var plane: int = route[i]["plane"]
		var was: int = route[i - 1]["plane"]

		if plane == was:
			var gap := here - last
			if absi(gap.x) + absi(gap.y) != 1:
				_fail("ROUTING", "%s: %v to %v is not one step" % [label, last, here])
			continue

		if absi(plane - was) != 1 or here != last:
			_fail("ROUTING", "%s: jumped from plane %d to %d" % [label, was, plane])
		elif not _network.has_shaft_down(mini(plane, was), here):
			_fail("ROUTING", "%s: changed plane at %v with no shaft there" % [label, here])


func _report_routing() -> void:
	print("")
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
func _walkable_from(plane: int, cell: Vector2i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	# Plane 0 is the lawn: you can be anywhere on it, so the only edge that matters is down.
	if plane > 0:
		for side: Vector2i in TunnelNetwork.SIDES:
			if _network.is_dug(plane, cell + side):
				out.append(Vector3i(plane, cell.x + side.x, cell.y + side.y))
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
			var at := Vector3(cell.x * TunnelNetwork.CELL, top, cell.y * TunnelNetwork.CELL)
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
			var feet := Vector3(
				cell.x * TunnelNetwork.CELL, _network.plane_y(plane), cell.y * TunnelNetwork.CELL
			)
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
			var floor_at := Vector3(
				cell.x * TunnelNetwork.CELL, _network.plane_y(plane), cell.y * TunnelNetwork.CELL
			)
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
