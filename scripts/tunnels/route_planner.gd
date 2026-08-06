class_name RoutePlanner
extends RefCounted
## Lawn or tunnel: how something gets from here to there when here and there may be on different
## planes.
##
## TWO NAVIGATION SYSTEMS, ONE ANSWER. The surface is a navmesh and the underground is a grid
## graph, and they meet at exactly one kind of place: a shaft mouth on the lawn. A plan is
## therefore always the same shape -- walk to a mouth, follow the network, come up at a mouth,
## walk on -- with any of those legs possibly empty. Returning an EMPTY plan means "there is
## nothing clever to do here, walk over the grass", which is the overwhelmingly common answer and
## deliberately costs the caller nothing.
##
## MOUTHS ARE TRIED, NOT PICKED. The first version of this went down at the entrance nearest you
## and came up at the entrance nearest your destination, which is what a person would do and is
## wrong in one specific way: the nearest hole may lead into a corridor that does not go where
## you are going. The audit caught it immediately -- a bot standing on the lawn above its quarry,
## which is the exact failure M4 exists to remove. So the few nearest mouths at each end are
## tried in turn and the cheapest route that actually connects wins. A handful of graph queries
## costs less than being wrong, and being wrong here looks like the AI being stupid.
##
## THE LAWN IS MEASURED BY THE NAVMESH, not as the crow flies, and that is the difference
## between this being a feature and being decoration. The straight line is free and was the first
## version, but it is optimistic in exactly the case tunnels exist for: a patio or a wall in the
## way makes the real walk far longer than the line, and a planner comparing against the line
## concludes the surface is fine and never goes under anything. It would have made "would you
## rather take the tunnel?" unanswerable by construction. One query per plan buys the honest
## number; the short hops to and from a mouth stay straight-line, where being a metre out cannot
## change the answer.

## What a plane change is worth, in metres of walking. The graph prices routes with the same
## number (TunnelGraph.PLANE_COST) -- if these two ever disagree, the planner will choose a route
## the graph did not think was best, which is the sort of bug that looks like the AI dithering.
const PLANE_COST: float = TunnelGraph.PLANE_COST

## How many entrances to try at each end. Three covers every sensible arrangement of a yard this
## size, and bounds the worst case at nine graph queries for a plan that finds nothing.
const MOUTH_CANDIDATES: int = 3

## `team` for a caller with no crew: every mouth on the map is a candidate.
##
## FOR THE GEOMETRY AUDITS AND NOTHING ELSE. tunnel_audit.gd asks whether a route across a network
## exists at all, which is a question about the graph rather than about anybody's knowledge, and
## handing it a crew would make it test two things and diagnose neither. Anything with a team must
## pass one -- see `_ends`.
const ANY_CREW: int = -1


## How to get from `from` to `to`, as waypoints. Empty means "just walk there".
##
## Each waypoint is `{at: Vector3, plane: int}`. A change of plane between consecutive waypoints
## is a shaft transit, and the waypoint before it is always the mouth to stand on.
##
## `team` IS WHOSE KNOWLEDGE THE ROUTE MAY BE BUILT FROM, and it is not optional for anybody in a
## match. See `_ends`.
static func plan(
	network: TunnelNetwork,
	from: Vector3,
	from_plane: int,
	to: Vector3,
	to_plane: int,
	tunnel_bias: float = 1.0,
	team: int = ANY_CREW
) -> Array[Dictionary]:
	var nothing: Array[Dictionary] = []
	if network == null:
		return nothing
	var graph := network.graph()
	if graph == null:
		return nothing

	var starts := _ends(network, graph, from, from_plane, team)
	var finishes := _ends(network, graph, to, to_plane, team)
	if starts.is_empty() or finishes.is_empty():
		return nothing

	var best: Array[Dictionary] = nothing
	var best_cost := INF
	for start: Dictionary in starts:
		for finish: Dictionary in finishes:
			var steps := graph.route(start["plane"], start["cell"], finish["plane"], finish["cell"])
			if steps.is_empty():
				continue
			# The two surface legs are part of the price. For an end that is already underground
			# they come out as zero, because the first or last cell IS where the mouse is.
			var cost := (
				from.distance_to(steps[0]["at"])
				+ length(steps)
				+ (steps[steps.size() - 1]["at"] as Vector3).distance_to(to)
			)
			if cost < best_cost:
				best_cost = cost
				best = steps
	if best.is_empty():
		return nothing

	# Both ends on the lawn is the only case where there is a choice to make. Underground, at
	# either end, the network is the only way there and the comparison would be against a walk
	# that cannot happen.
	if from_plane == 0 and to_plane == 0 and best_cost * tunnel_bias >= _lawn(network, from, to):
		return nothing

	# The last leg over the grass. Not appended when the destination is underground: the final
	# cell IS the destination, and a waypoint at a mouse's exact position would have the bot
	# walking to where they were rather than to where they are.
	if to_plane == 0:
		best.append({"at": to, "plane": 0})
	return best


## Whatever the plan, how far it is -- plane changes priced the same way the graph prices them.
## Exposed because anything comparing two routes has to use the same ruler this file does.
static func length(steps: Array[Dictionary]) -> float:
	var total := 0.0
	for i in range(1, steps.size()):
		if int(steps[i]["plane"]) != int(steps[i - 1]["plane"]):
			total += PLANE_COST
			continue
		total += (steps[i]["at"] as Vector3).distance_to(steps[i - 1]["at"])
	return total


## The entrances a crew may build a route from.
##
## ASKED OF tunnel_sight.gd, which is the node that owns the question -- a crew knows the holes it
## cut plus the ones it has walked past and not yet forgotten, and that union is exactly what the
## minimap draws. Reproducing it here would be the second copy that drifts, and the day it drifted
## a bot would decline an entrance the player can see on their own map.
##
## FAILS CLOSED, unlike most of the optional lookups in this project. With no sight node there is no
## model of what a crew has seen, so the answer falls back to what it has DUG -- fewer routes rather
## than more. Every other fail-open in the AI trades a bit of realism for a bot that still plays;
## this one would trade hidden information for it, and that is not a trade this file gets to make.
static func _known_mouths(
	network: TunnelNetwork, graph: TunnelGraph, team: int
) -> Array[Vector2i]:
	if team == ANY_CREW:
		return graph.mouths()
	var tree := network.get_tree()
	if tree != null:
		var sight := tree.get_first_node_in_group(TunnelSight.SIGHT_GROUP) as TunnelSight
		if sight != null:
			return sight.known_mouths(team)
	return network.known_shaft_cells(0, team)


## How far it really is over the grass, walked rather than flown.
##
## Falls back to the straight line when there is no navigation map -- which is the case in the
## tunnel audit, where the navmesh is stripped, and would be the case on a map still being built.
## A wrong answer here only ever costs a route choice; refusing to answer would cost the caller
## its only comparison.
static func _lawn(network: TunnelNetwork, from: Vector3, to: Vector3) -> float:
	var world := network.get_world_3d()
	if world == null or not world.navigation_map.is_valid():
		return from.distance_to(to)
	var path := NavigationServer3D.map_get_path(world.navigation_map, from, to, true)
	if path.size() < 2:
		return from.distance_to(to)

	var total := 0.0
	for i in range(1, path.size()):
		total += path[i].distance_to(path[i - 1])
	return total


## Where a route may start or finish, best candidate first.
##
## Underground that is one place: the cell you are standing in. On the lawn it is the nearest few
## entrances a crew KNOWS ABOUT, because the surface is not part of the graph and a mouth is the
## only way in.
##
## THE CREW FILTER IS AN M5 RULE, NOT AN OPTIMISATION, and it was missing here for four milestones.
## `graph.mouths()` is every entrance on the map, so a bot planning a route would happily walk into
## a shaft the enemy Engineer had cut on the far side of the yard and follow their corridor -- a
## crew acting on tunnels it has never seen, which is precisely the hidden information GDD section
## 3 is built on and which the minimap, the cutaway and the sonar all take pains to withhold.
##
## IT WAS INVISIBLE BECAUSE OF A DIAL. `tunnel_bias` sat at 1.0 -- take a tunnel only if it is
## genuinely shorter -- and on eighty metres of open lawn almost nothing underground wins that
## comparison, so bots were rarely routed through any mouth at all and never noticeably through the
## wrong one. Lowering the bias so tunnels are actually used is what would have turned a quiet leak
## into visible behaviour, which is why this is fixed first and in the same pass.
##
## bot_digger.gd already had this right -- `_entrance` asks `known_shaft_cells` -- so the walker and
## the digger have been disagreeing about which holes exist. One of them was reading the map.
##
## Which crew's knowledge, and what counts as knowing, is `_known_mouths`.
static func _ends(
	network: TunnelNetwork, graph: TunnelGraph, at: Vector3, plane: int, team: int
) -> Array[Dictionary]:
	var ends: Array[Dictionary] = []
	if plane > 0:
		var cell := network.world_to_cell(at)
		if graph.has(plane, cell):
			ends.append({"plane": plane, "cell": cell})
		return ends

	var mouths := _known_mouths(network, graph, team)
	mouths.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (
			network.cell_to_world(0, a).distance_squared_to(at)
			< network.cell_to_world(0, b).distance_squared_to(at)
		)
	)
	# WHAT A CREW KNOWS AND WHAT STILL EXISTS ARE TWO DIFFERENT LISTS. A shaft the Brute brought
	# down leaves the graph but stays on the crew's map until sight takes it back -- knowledge is
	# allowed to be out of date (tunnel_sight.gd), routes are not. Without this the nearest few
	# candidates can all be holes that are no longer there, and the plan comes back empty while a
	# perfectly good entrance sits fourth in the list.
	for cell: Vector2i in mouths:
		if not graph.has(0, cell):
			continue
		ends.append({"plane": 0, "cell": cell})
		if ends.size() >= MOUTH_CANDIDATES:
			break
	return ends
