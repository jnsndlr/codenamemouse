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


## How to get from `from` to `to`, as waypoints. Empty means "just walk there".
##
## Each waypoint is `{at: Vector3, plane: int}`. A change of plane between consecutive waypoints
## is a shaft transit, and the waypoint before it is always the mouth to stand on.
static func plan(
	network: TunnelNetwork,
	from: Vector3,
	from_plane: int,
	to: Vector3,
	to_plane: int,
	tunnel_bias: float = 1.0
) -> Array[Dictionary]:
	var nothing: Array[Dictionary] = []
	if network == null:
		return nothing
	var graph := network.graph()
	if graph == null:
		return nothing

	var starts := _ends(network, graph, from, from_plane)
	var finishes := _ends(network, graph, to, to_plane)
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
## entrances, because the surface is not part of the graph and a mouth is the only way in.
static func _ends(
	network: TunnelNetwork, graph: TunnelGraph, at: Vector3, plane: int
) -> Array[Dictionary]:
	var ends: Array[Dictionary] = []
	if plane > 0:
		var cell := network.world_to_cell(at)
		if graph.has(plane, cell):
			ends.append({"plane": plane, "cell": cell})
		return ends

	var mouths := graph.mouths()
	mouths.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (
			network.cell_to_world(0, a).distance_squared_to(at)
			< network.cell_to_world(0, b).distance_squared_to(at)
		)
	)
	for cell: Vector2i in mouths.slice(0, MOUTH_CANDIDATES):
		ends.append({"plane": 0, "cell": cell})
	return ends
