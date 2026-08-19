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
## `[REVISED]` AN EDGE IS A WALK THAT WORKS, NOT A SHARED FACE. This file used to join cells that
## touched on one of four sides, on the argument that walls are built on the four faces of a cell so
## two diagonally touching cells meet at a corner with no gap between them. That argument was
## airtight while a tunnel was a run of whole squares, and off-grid digging retired it: a stroke at
## 30 degrees leaves a chain of cells joined only at their corners, and clips others whose far side
## is untouched earth. Four-way was then wrong twice over, and the two failures look nothing alike
## from the outside -- a bot that will not follow you down a diagonal corridor, and a bot that walks
## into a wall and grinds against it, which reads as broken AI rather than as a routing bug.
##
## So the eight neighbours are CANDIDATES and none of them is an edge until
## [method TunnelNetwork.walkable_between] says a mouse fits between the two standing points. The
## graph's connectivity is the earth's connectivity, which is what four-way was always trying to say.
##
## AND THE TEST IS THE BOT'S OWN MOVEMENT MODEL. Underground a bot heads straight at its next
## waypoint, because there is no navmesh down here and the graph is supposed to have done the
## routing. An edge is therefore a promise that walking straight from one standing point to the next
## works, and the only honest way to make that promise is to ask precisely that question.
##
## POINTS SIT WHERE A MOUSE WOULD STAND, not at the middle of the square. On an angled corridor the
## centre of a claimed cell is routinely solid earth, so waypoints taken from it would send a bot
## into a wall on the way to a cell it can perfectly well reach. Distances come out honest as a side
## effect: `AStar3D` prices an edge by the gap between its points, so a diagonal step costs its real
## length rather than being quietly sold at the price of a straight one.
##
## SHAFTS ARE THE ONLY VERTICAL EDGE, which is the same rule the player plays by (GDD section 3).
## Plane 0 appears in the graph *only* at shaft mouths: the surface is a navmesh, not a grid, and
## the mouths are precisely the places the two systems touch. That makes an entrance a real
## bottleneck for pathing in the same way it is for a mouse -- there is no other way down.
##
## KEPT IN STEP INCREMENTALLY, and now off the STROKE signals as well as the cell ones. A cell is
## still what a point is, but a cell can no longer tell you where the walls are: one stroke cut
## between two corridors joins them without opening a single new cell, and one stroke removed can
## divide a cell from its neighbour while both stay dug. Either would leave a cell-only listener
## certain nothing had changed. The strokes are the geometry, so the geometry is what the edges
## listen to.
##
## WHAT THE NEW EDGES COST, measured rather than guessed, because "ask the earth about every pair of
## neighbours" sounds expensive. One walk is **19us**; a stroke re-asks a few dozen pairs, most of
## which exit on a missing point before any earth is sampled. Against the **~6ms** of contour and
## collision rebuild the same stroke already pays, the whole sweep is below the run-to-run variance
## of measuring it -- timing thirty strokes with the graph attached and detached could not separate
## them. Digging is not where this file's cost would ever show up.
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

## The eight cells a step could go to. Candidates only -- see the header, and [method _reconsider],
## which is the thing that decides.
const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

## Half of them, so that walking a patch of cells considers each PAIR once rather than twice. The
## test is symmetric, so the other four are the same four questions with the ends swapped.
const HALF_NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1),
]

var _network: TunnelNetwork
var _astar: AStar3D = AStar3D.new()


func _init(network: TunnelNetwork) -> void:
	_network = network
	network.cell_opened.connect(_on_cell_opened)
	network.shaft_opened.connect(_on_shaft_opened)
	network.cell_collapsed.connect(_on_cell_closed)
	# THE STROKES, WHICH ARE WHERE THE WALLS ACTUALLY ARE. A cell signal says a place appeared or
	# went; only a stroke can say the earth between two places moved. See the header.
	network.segment_opened.connect(_on_segment_changed)
	network.segment_closed.connect(_on_segment_changed)
	# A barricade takes the cell out of the graph and putting it back is the same operation as
	# digging it: add the point, join its neighbours. That reuse is deliberate -- a second
	# "restore" path would be a second place for the joining rules to be got wrong, and the way
	# you would find out is a bot refusing to walk down a corridor that is visibly clear.
	network.cell_blocked.connect(_on_cell_closed)
	network.cell_unblocked.connect(_on_cell_restored)
	# Whatever already exists. Nothing does at startup today, but a map that ships with a dug
	# network -- an authored burrow under the patio, say -- would otherwise be invisible to every
	# bot in the match, and that is a bug you would hunt for in the AI.
	# EVERY POINT BEFORE ANY EDGE, because both kinds of join want both ends already there and a
	# shaft's lower end lives on the plane after the one being walked.
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in network.dug_cells(plane):
			_add(plane, cell)
		for cell: Vector2i in network.shaft_cells(plane):
			_add(plane, cell)
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in network.shaft_cells(plane):
			_join_shaft(plane, cell)
		if plane > 0:
			_relink(plane, network.dug_cells(plane))


# --------------------------------------------------------------------------------- queries


## Whether this cell is somewhere a route can stand: a dug floor, or a shaft mouth on the lawn.
func has(plane: int, cell: Vector2i) -> bool:
	return _astar.has_point(_id(plane, cell))


## The way from one cell to another, as world positions with the plane each belongs to.
##
## Returns an empty array when there is no way through -- which is a completely ordinary answer
## and the caller's cue to walk round on the surface instead.
##
## `at` IS THE STANDING POINT, not the middle of the square, for the same reason the graph prices
## itself off one: on an angled corridor the middle of a claimed cell is often solid earth, and a
## bot walks at these in a straight line.
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
			"at": _network.standing_point(plane, cell),
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


## How many ways there are out of a cell. For the audits: the count is the one thing that says
## whether the earth was asked at all, since a graph joining every neighbour blindly and a graph
## joining none of them both hold exactly the right POINTS.
func edges(plane: int, cell: Vector2i) -> int:
	var id := _id(plane, cell)
	if not _astar.has_point(id):
		return 0
	return _astar.get_point_connections(id).size()


## Is there an edge between these two, on one plane? For the audits, which check this file's
## answer against the collision mesh one pair at a time.
func joined(plane: int, a: Vector2i, b: Vector2i) -> bool:
	if not _addressable(a) or not _addressable(b):
		return false
	var first := _id(plane, a)
	var second := _id(plane, b)
	if not _astar.has_point(first) or not _astar.has_point(second):
		return false
	return _astar.are_points_connected(first, second)


# ------------------------------------------------------------------------------ keeping up


## A cell became somewhere to stand. Its point goes in, and the vertical joins are settled here
## because a shaft is the one thing a cell CAN tell you about on its own.
##
## Its sideways joins are deliberately not settled here: the stroke that opened this cell is about
## to announce itself, and the earth around a cell is a question about strokes. Every path that
## emits `cell_opened` emits `segment_opened` immediately afterwards -- digging, and a client
## adopting a stroke off the wire -- so the joins are one signal away and doing them twice would be
## the same sweep for the same answer.
func _on_cell_opened(plane: int, cell: Vector2i) -> void:
	_add(plane, cell)
	# In case the floor was opened underneath a shaft that already existed -- which is exactly what
	# `dig_shaft_down` does, in that order.
	_join_shaft(plane, cell)
	_join_shaft(plane - 1, cell)


## A shaft's lower end is a floor cell that `dig` has already announced; its upper end may be a
## floor cell too, or -- at plane 0 -- the lawn, which exists only as this mouth.
func _on_shaft_opened(plane: int, cell: Vector2i) -> void:
	_add(plane, cell)
	_join_shaft(plane, cell)


## A cell went: brought down by the Brute, or shut behind a barricade.
##
## `AStar3D.remove_point` takes its edges with it, so there is nothing to unpick -- which is the
## whole reason the graph is an AStar3D and not an adjacency list somebody maintains by hand. What
## does need saying is that the cells AROUND it may have lost an edge to each other as well: a
## boulder dropped into a corner cell stands in the way of the diagonal step between the two cells
## either side of it, and neither of those has changed in any way it could notice.
##
## THE ROUTES THAT USED IT ARE NOT REPAIRED, and must not be. A bot re-plans every third of a
## second and will discover the corridor is gone on its own; a graph that tried to patch the
## plans already in flight would be guessing at what those bots wanted. Sealing a tunnel in front
## of somebody and watching them turn around a beat later is the mechanic working.
func _on_cell_closed(plane: int, cell: Vector2i) -> void:
	var id := _id(plane, cell)
	if _astar.has_point(id):
		_astar.remove_point(id)
	_relink(plane, [cell])


## A barricade came down and the cell is a place again. The whole of the restore: the point, its
## shafts, and the earth around it re-asked -- the last because nothing about the strokes changed
## while the boulder sat there, so no stroke signal is coming to do it.
func _on_cell_restored(plane: int, cell: Vector2i) -> void:
	_add(plane, cell)
	_join_shaft(plane, cell)
	_join_shaft(plane - 1, cell)
	_relink(plane, [cell])


## A stroke was cut, or removed. Where the sideways edges are decided.
##
## THE SAME HANDLER FOR BOTH DIRECTIONS, because the work is identical: re-ask the earth. A stroke
## added can only ever open a way through and a stroke removed can only ever close one, but knowing
## which does not make the question cheaper -- and one handler cannot drift from the other.
##
## THE STROKE'S OWN CELLS PLUS A RING AROUND THEM. A stroke changes the answer for a pair of cells
## only where its body lies between them, and its body is inside the cells it claims but for the
## rounded caps on either end, which reach half a metre further. One cell of ring covers the caps
## with room to spare and costs a sweep of a few dozen pairs.
func _on_segment_changed(plane: int, id: int) -> void:
	var touched := _network.segment_cells(id)
	# Where a mouse stands in a cell is the deepest spot any stroke through it offers, so a stroke
	# arriving or leaving moves it. Stale positions are the quiet half of this bug: the edges would
	# be right and the waypoints would be somewhere else.
	for cell: Vector2i in touched:
		_reposition(plane, cell)
	_relink(plane, touched)


## Re-ask the earth about every pair of neighbouring cells in and around `cells`.
##
## Both directions, always: an edge that should not be there is removed here as readily as a missing
## one is added. Anything less would make this file's answer depend on the order the strokes arrived
## in, which is the one thing a cache over a world model must never do.
func _relink(plane: int, cells: Array) -> void:
	if plane <= 0 or plane >= TunnelNetwork.PLANE_COUNT:
		return
	var patch := {}
	for cell: Vector2i in cells:
		patch[cell] = true
		for side: Vector2i in NEIGHBOURS:
			# The ring can hang off the edge of the addressable field, and `_id` packs a cell into
			# one integer without room to say so -- a cell past the bound would alias onto a real
			# one somewhere else. Nothing is ever dug within twenty-five metres of that bound; this
			# is here so that the day something is, it is not a routing bug in a far corner.
			var near := cell + side
			if _addressable(near):
				patch[near] = true
	for cell: Vector2i in patch:
		for side: Vector2i in HALF_NEIGHBOURS:
			_reconsider(plane, cell, cell + side)


## One pair of neighbours, settled against the earth between them.
func _reconsider(plane: int, a: Vector2i, b: Vector2i) -> void:
	if not _addressable(a) or not _addressable(b):
		return
	var first := _id(plane, a)
	var second := _id(plane, b)
	if not _astar.has_point(first) or not _astar.has_point(second):
		return
	var joined := _astar.are_points_connected(first, second)
	var walkable := _network.walkable_between(plane, _standing(plane, a), _standing(plane, b))
	if walkable and not joined:
		_astar.connect_points(first, second)
	elif joined and not walkable:
		_astar.disconnect_points(first, second)


func _add(plane: int, cell: Vector2i) -> void:
	if plane < 0 or plane >= TunnelNetwork.PLANE_COUNT:
		return
	var id := _id(plane, cell)
	if _astar.has_point(id):
		return
	_astar.add_point(id, _position(plane, cell))


## Move a point to wherever a mouse would stand in its cell now. Silent if the cell has no point,
## which is the ordinary case for a stroke that clips a square without making it standable.
func _reposition(plane: int, cell: Vector2i) -> void:
	var id := _id(plane, cell)
	if not _astar.has_point(id):
		return
	_astar.set_point_position(id, _position(plane, cell))


## A cell's place in the routing world: where a mouse stands in it, with the vertical stretched to
## [constant PLANE_COST] so that going down a plane prices like the walk it is worth.
func _position(plane: int, cell: Vector2i) -> Vector3:
	var at := _network.standing_point(plane, cell)
	return Vector3(at.x, -float(plane) * PLANE_COST, at.z)


## Where a mouse stands in a cell, flat. What the walk between two cells is measured across.
func _standing(plane: int, cell: Vector2i) -> Vector2:
	var at := _network.standing_point(plane, cell)
	return Vector2(at.x, at.z)


## Join a cell to the one below it, if a shaft goes down from here and both ends are in the graph.
##
## THE ONE VERTICAL EDGE, and it is asked of the shaft rather than of the geometry: a shaft is a
## hole in a floor with a ladder in it, not a place a mouse can walk to, so nothing about the earth
## on either plane has any bearing on whether this edge exists.
func _join_shaft(plane: int, cell: Vector2i) -> void:
	if plane < 0 or plane + 1 >= TunnelNetwork.PLANE_COUNT:
		return
	if not _network.has_shaft_down(plane, cell):
		return
	var top := _id(plane, cell)
	var bottom := _id(plane + 1, cell)
	if not _astar.has_point(top) or not _astar.has_point(bottom):
		return
	if not _astar.are_points_connected(top, bottom):
		_astar.connect_points(top, bottom)


# ------------------------------------------------------------------------------- addressing


## Whether [method _id] can say this cell without it colliding with another one. See [method _relink].
static func _addressable(cell: Vector2i) -> bool:
	return (
		absi(cell.x) < TunnelNetwork.MASK_HALF_CELLS
		and absi(cell.y) < TunnelNetwork.MASK_HALF_CELLS
	)


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
