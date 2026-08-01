class_name TunnelGraph
extends RefCounted
## The dug network as something you can path through: an `AStar3D` kept in step with the cells.
##
## WHY THIS IS THE HEART OF M4. Digging has worked since M2 and shipped with the flag game at M3,
## but only a player could use it -- bots walk a navmesh, and there is no navmesh underground. A
## tunnel a defender structurally cannot follow you into is not a route, it is an exploit, and
## the milestone's question (would you *rather* take the tunnel?) cannot be asked while the
## answer is "obviously, nobody can stop you". This class is what makes the underground contested.
##
## FOUR-WAY, AND THAT IS NOT A SIMPLIFICATION. Walls are built on the four faces of every cell
## (TunnelNetwork.SIDES), so two diagonally touching cells meet at a corner with a wall on either
## side of it and no gap a mouse can fit through. Eight-way edges would produce routes that walk
## through solid earth. The graph's connectivity is the geometry's connectivity, exactly.
##
## SHAFTS ARE THE ONLY VERTICAL EDGE, which is the same rule the player plays by (GDD section 3).
## Plane 0 appears in the graph *only* at shaft mouths: the surface is a navmesh, not a grid, and
## the mouths are precisely the places the two systems touch. That makes an entrance a real
## bottleneck for pathing in the same way it is for a mouse -- there is no other way down.
##
## KEPT IN STEP INCREMENTALLY, on the network's `cell_opened` and `shaft_opened` signals. A dig
## changes one cell out of five thousand; a graph that rebuilds to learn that is one nobody can
## afford to keep current, and a stale graph is worse than none -- it routes bots into earth.
##
## A NOTE ON COST. Point positions are the real world positions with the VERTICAL EXAGGERATED
## (`plane_cost`). Planes are only 0.65m apart, so at true scale a shaft transit is nearly free
## and a route will happily porpoise between two parallel corridors to save a centimetre. Pricing
## a plane change at a couple of metres of walking makes routes commit to a depth, which is both
## what a person would do and what reads as deliberate from above.

## What a plane change costs, expressed as the metres of walking it is worth. Purely a routing
## price -- the transit itself is instant, and this never moves a mouse anywhere.
const PLANE_COST: float = 2.5

## Cells are addressed from -MASK_HALF_CELLS to +MASK_HALF_CELLS, so a row is this wide and an
## id is (plane, x, y) flattened. Sized off the network's own mask bound rather than off
## `half_extent_cells`, which is an export somebody may widen.
const SPAN: int = TunnelNetwork.MASK_HALF_CELLS * 2 + 1

var _network: TunnelNetwork
var _astar: AStar3D = AStar3D.new()


func _init(network: TunnelNetwork) -> void:
	_network = network
	network.cell_opened.connect(_on_cell_opened)
	network.shaft_opened.connect(_on_shaft_opened)
	network.cell_collapsed.connect(_on_cell_collapsed)
	# Whatever already exists. Nothing does at startup today, but a map that ships with a dug
	# network -- an authored burrow under the patio, say -- would otherwise be invisible to every
	# bot in the match, and that is a bug you would hunt for in the AI.
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in network.dug_cells(plane):
			_on_cell_opened(plane, cell)
		for cell: Vector2i in network.shaft_cells(plane):
			_on_shaft_opened(plane, cell)


# --------------------------------------------------------------------------------- queries


## Whether this cell is somewhere a route can stand: a dug floor, or a shaft mouth on the lawn.
func has(plane: int, cell: Vector2i) -> bool:
	return _astar.has_point(_id(plane, cell))


## The way from one cell to another, as world positions with the plane each belongs to.
##
## Returns an empty array when there is no way through -- which is a completely ordinary answer
## and the caller's cue to walk round on the surface instead.
func route(from_plane: int, from: Vector2i, to_plane: int, to: Vector2i) -> Array[Dictionary]:
	var start := _id(from_plane, from)
	var finish := _id(to_plane, to)
	var steps: Array[Dictionary] = []
	if start == finish or not _astar.has_point(start) or not _astar.has_point(finish):
		return steps

	for id in _astar.get_id_path(start, finish):
		var plane := _plane_of(id)
		var cell := _cell_of(id)
		steps.append({
			"plane": plane,
			"cell": cell,
			"at": _network.cell_to_world(plane, cell),
		})
	return steps


## Every entrance on the lawn. The only places a route may cross between navmesh and network.
func mouths() -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	for cell: Vector2i in _network.shaft_cells(0):
		found.append(cell)
	return found


## The entrance nearest a world position, or MAX if there are none. Nearest by straight line
## rather than by walking distance, deliberately: see route_planner.gd, which is where the
## consequences of that choice are argued.
func nearest_mouth(to: Vector3) -> Vector2i:
	var best := Vector2i.MAX
	var closest := INF
	for cell: Vector2i in _network.shaft_cells(0):
		var gap := _network.cell_to_world(0, cell).distance_to(to)
		if gap < closest:
			closest = gap
			best = cell
	return best


## How many cells the graph knows about. For the audits, and for a debug readout.
func size() -> int:
	return _astar.get_point_count()


# ------------------------------------------------------------------------------ keeping up


func _on_cell_opened(plane: int, cell: Vector2i) -> void:
	_add(plane, cell)
	# Sideways, to any neighbour that is already open. Nothing has to be done for neighbours dug
	# later -- they will run this same loop and find this cell.
	for side: Vector2i in TunnelNetwork.SIDES:
		_join(plane, cell, plane, cell + side)
	# And vertically, in case the floor was opened underneath a shaft that already existed --
	# which is exactly what `dig_shaft_down` does, in that order.
	_join(plane, cell, plane + 1, cell)
	_join(plane - 1, cell, plane, cell)


## A shaft's lower end is a floor cell that `dig` has already announced; its upper end may be a
## floor cell too, or -- at plane 0 -- the lawn, which exists only as this mouth.
func _on_shaft_opened(plane: int, cell: Vector2i) -> void:
	_add(plane, cell)
	_join(plane, cell, plane + 1, cell)


## A cell came down (the Engineer's cave-in). `AStar3D.remove_point` takes its edges with it, so
## there is nothing else to unpick -- which is the whole reason the graph is an AStar3D and not
## an adjacency list somebody maintains by hand.
##
## THE ROUTES THAT USED IT ARE NOT REPAIRED, and must not be. A bot re-plans every third of a
## second and will discover the corridor is gone on its own; a graph that tried to patch the
## plans already in flight would be guessing at what those bots wanted. Sealing a tunnel in front
## of somebody and watching them turn around a beat later is the mechanic working.
func _on_cell_collapsed(plane: int, cell: Vector2i) -> void:
	var id := _id(plane, cell)
	if _astar.has_point(id):
		_astar.remove_point(id)


func _add(plane: int, cell: Vector2i) -> void:
	if plane < 0 or plane >= TunnelNetwork.PLANE_COUNT:
		return
	var id := _id(plane, cell)
	if _astar.has_point(id):
		return
	_astar.add_point(id, Vector3(
		float(cell.x) * TunnelNetwork.CELL,
		-float(plane) * PLANE_COST,
		float(cell.y) * TunnelNetwork.CELL
	))


## Connect two cells if both are in the graph and are not already joined. Silently does nothing
## otherwise, which is what lets the callers above be written as a list of "and also this one"
## without a guard on each.
func _join(a_plane: int, a: Vector2i, b_plane: int, b: Vector2i) -> void:
	var first := _id(a_plane, a)
	var second := _id(b_plane, b)
	if not _astar.has_point(first) or not _astar.has_point(second):
		return
	# Vertical joins are only ever legal through a shaft. Without this the two calls in
	# `_on_cell_opened` would weld every plane to the one below it wherever their floors overlap,
	# and bots would walk through the ceiling.
	if a_plane != b_plane and not _network.has_shaft_down(mini(a_plane, b_plane), a):
		return
	if not _astar.are_points_connected(first, second):
		_astar.connect_points(first, second)


# ------------------------------------------------------------------------------- addressing


func _id(plane: int, cell: Vector2i) -> int:
	var x := cell.x + TunnelNetwork.MASK_HALF_CELLS
	var y := cell.y + TunnelNetwork.MASK_HALF_CELLS
	return plane * SPAN * SPAN + x * SPAN + y


func _plane_of(id: int) -> int:
	return id / (SPAN * SPAN)


func _cell_of(id: int) -> Vector2i:
	var flat := id % (SPAN * SPAN)
	return Vector2i(
		flat / SPAN - TunnelNetwork.MASK_HALF_CELLS,
		flat % SPAN - TunnelNetwork.MASK_HALF_CELLS
	)
