class_name TunnelSight
extends Node
## What a crew learns about somebody else's tunnel by being in it, and how long that lasts.
##
## THE SECOND HALF OF M5'S BOUNDARY. The first half said a crew maps what it CUT: blue's corridor
## does not appear on red's minimap, and where the two meet, only the junction is shared. That
## rule on its own is too absolute -- it means you can stand in an enemy corridor, look down it,
## and have your own map insist there is nothing there. Knowledge has to be able to arrive by
## looking, or the map stops being a map and becomes a list of receipts.
##
## SO SIGHT GRANTS, AND TIME TAKES BACK. A cell of an enemy network that one of your crew can
## actually see goes onto your map, and it starts ageing the moment nobody can see it any more.
## GDD section 3 asks for exactly this asymmetry -- your own network known intimately and far
## ahead, theirs by direct line of sight with fog beyond -- and the fog is what makes a breach
## worth something without making it worth everything. You come out of an enemy tunnel knowing
## roughly where it went, for a while, and then you don't.
##
## THE MEMORY IS spotting.gd's, DELIBERATELY. That file already answers "how long does a crew
## remember something it can no longer see" for mice, and answers it with a live contact that
## freezes and fades. Terrain gets the same seconds, the same fade fraction and the same
## confidence curve, because a player should have to learn the staleness rule ONCE. Two decay
## models on one minimap would be two things to learn and would look like a bug in whichever one
## the player noticed second.
##
## LINE OF SIGHT IS THE GRID, NOT A RAYCAST, and that is the right answer rather than the cheap
## one. Underground the walls ARE the cells nobody has dug, so "can I see that cell" is exactly
## "is every cell between here and there open" -- a question the network can answer without a
## physics server, deterministically, in a headless audit, and identically on a server at M7. A
## ray would have asked the collision geometry the same question through two layers of
## indirection and given a slightly different answer at corners.
##
## IT NEVER FLOOD-FILLS. A corridor bending out of sight stops at the bend, which is the whole
## point: a breach tells you where you are, not where the route goes. That is the same line
## sonar.gd holds -- one mark, never the shape -- and both exist so that M5's question has a
## chance of being answered honestly.

## So the HUD can find it without being wired to it. Same convention as the director and spotting.
const SIGHT_GROUP: StringName = &"tunnel_sight"

@export var network_path: NodePath

@export_group("Sight")
## How far down a corridor a mouse can read the earth, in cells. Much shorter than the surface
## sight range, and it barely matters what the number is: a one-cell corridor means the geometry
## does the limiting, and anything past a bend is invisible at any range.
@export var sight_cells: int = 7
## Seconds between sweeps. Spotting's interval, for the same reason -- it doubles as how long it
## takes to notice, and noticing on the exact frame you clip a corner reads as cheating.
@export var interval: float = 0.25
## Whether a crew learns an enemy MOUTH by walking past it on the lawn. A shaft is a hole in the
## grass with light coming out of it and there is nothing subtle about spotting one; the rule is
## here as a dial rather than as an assumption because it is the one piece of enemy network that
## can be found without going underground.
@export var spot_mouths: bool = true
## How near a mouth has to be, in metres, before it is noticed from the surface.
@export var mouth_range: float = 11.0

@export_group("Memory")
## How long a cell stays on the map after nobody can see it. Spotting's number.
@export var memory_seconds: float = 15.0
## The last fraction of that, over which it fades out.
@export_range(0.0, 1.0, 0.05) var fade_fraction: float = 0.45

var _network: TunnelNetwork
## Per side, per plane: cell -> seconds since last seen. Only ever holds cells the crew does NOT
## own -- the moment a cell becomes yours by digging, remembering it separately would be a second
## opinion about your own network that could go stale underneath you.
var _seen: Array = []
## Per side: cell -> seconds since last seen, for shaft mouths on the lawn.
var _mouths: Array[Dictionary] = [{}, {}]
var _since_sweep: float = 999.0
## Planes whose membership changed since the world was last told, as `side * PLANE_COUNT + plane`.
## Tracked rather than recomputed because the WORLD has to be corrected -- the lid cutaway is
## drawn from this, and a plane whose set has not moved must not cost a rebuild sixty times a
## second just so we can discover that it has not moved.
var _dirty: Dictionary = {}


func _ready() -> void:
	add_to_group(SIGHT_GROUP)
	for side in [Team.BLUE, Team.RED]:
		var planes: Array[Dictionary] = []
		for plane in range(TunnelNetwork.PLANE_COUNT):
			planes.append({})
		_seen.append(planes)
	_network = get_node_or_null(network_path) as TunnelNetwork
	if _network == null:
		_network = get_tree().get_first_node_in_group(TunnelNetwork.NETWORK_GROUP) as TunnelNetwork
	if _network == null:
		push_warning("tunnel sight: no network -- enemy tunnels will never be learnt")
		set_physics_process(false)
		return
	# A cell that stops existing has to stop being remembered, or a crew keeps a floor plan of a
	# corridor an Engineer brought down on top of them.
	_network.cell_collapsed.connect(_on_collapsed)


# --------------------------------------------------------------------------------- queries


## Enemy cells this crew currently has on its map, as cell -> confidence in 0..1.
##
## Confidence rather than age, because every caller wants the same derived number and the one
## place it is worth computing is here -- a minimap that did its own arithmetic would be free to
## disagree with an audit that did its own.
func seen_cells(side: int, plane: int) -> Dictionary:
	var found: Dictionary = {}
	if plane <= 0 or plane >= TunnelNetwork.PLANE_COUNT:
		return found
	var book: Dictionary = _seen[clampi(side, Team.BLUE, Team.RED)][plane]
	for cell: Vector2i in book:
		found[cell] = confidence(float(book[cell]))
	return found


## Enemy shaft mouths this crew has walked past, as cell -> confidence.
func seen_mouths(side: int) -> Dictionary:
	var found: Dictionary = {}
	var book: Dictionary = _mouths[clampi(side, Team.BLUE, Team.RED)]
	for cell: Vector2i in book:
		found[cell] = confidence(float(book[cell]))
	return found


## 1 while it is fresh, falling to 0 as it is forgotten. spotting.gd's curve, to the letter.
func confidence(age: float) -> float:
	var fade := maxf(memory_seconds * fade_fraction, 0.001)
	return clampf((memory_seconds - age) / fade, 0.0, 1.0)


## Does this crew have this cell on its map at all, by either route? The question the minimap and
## the audit both really want, with the ownership rule folded in so neither can forget it.
func knows(side: int, plane: int, cell: Vector2i) -> bool:
	if _network == null:
		return false
	if _network.is_tunnel_known(plane, cell, side):
		return true
	if plane <= 0 or plane >= TunnelNetwork.PLANE_COUNT:
		return false
	return _seen[clampi(side, Team.BLUE, Team.RED)][plane].has(cell)


# ------------------------------------------------------------------------------- the sweep


func _physics_process(delta: float) -> void:
	_forget(delta)
	_since_sweep += delta
	if _since_sweep >= interval:
		_since_sweep = 0.0
		_look()
	_publish()


## Tell the world what changed, so the earth can open over a corridor somebody is looking at and
## close over one they have forgotten.
##
## THE WORLD IS THE HALF THAT MATTERS. A minimap that leaks is a mistake; a lid cutaway that leaks
## draws the enemy's whole floor plan into the ground in front of you, complete, before you have
## been anywhere near it -- which is what it did, and it made the filtered minimap beside it
## decorative. The network decides which of these two crews it is drawing for and throws the other
## away; that is its business, not this file's.
func _publish() -> void:
	if _dirty.is_empty():
		return
	for key: int in _dirty:
		var side := key / TunnelNetwork.PLANE_COUNT
		var plane := key % TunnelNetwork.PLANE_COUNT
		_network.show_glimpsed(side, plane, _seen[side][plane].keys())
	_dirty.clear()


func _touch(side: int, plane: int) -> void:
	_dirty[side * TunnelNetwork.PLANE_COUNT + plane] = true


## Age everything, and drop what nobody remembers. Every frame rather than on the sweep, so a
## cell thins out smoothly instead of in quarter-second steps.
func _forget(delta: float) -> void:
	for side in [Team.BLUE, Team.RED]:
		for plane in range(TunnelNetwork.PLANE_COUNT):
			var book: Dictionary = _seen[side][plane]
			for cell: Vector2i in book.keys():
				var age: float = book[cell] + delta
				if age > memory_seconds:
					book.erase(cell)
					_touch(side, plane)
				else:
					book[cell] = age
		for cell: Vector2i in _mouths[side].keys():
			var age: float = _mouths[side][cell] + delta
			if age > memory_seconds:
				_mouths[side].erase(cell)
			else:
				_mouths[side][cell] = age


## Everyone underground looks around, and everyone on the lawn looks for holes.
##
## Scruffed mice do not look. Lying on your back is not reconnaissance, and a crew that kept
## mapping a corridor through a body would be getting the one thing a defender's kill is supposed
## to take away.
func _look() -> void:
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or mouse.is_scruffed():
			continue
		var plane := mouse.get_plane()
		var here := _network.world_to_cell(mouse.global_position)
		if plane <= 0:
			if spot_mouths:
				_look_for_mouths(mouse.team, mouse.global_position)
			continue
		_look_along(mouse.team, plane, here)


## One mouse's view of one plane. Everything within reach that its crew does not already own, and
## that it has an unbroken line of open cells to.
func _look_along(side: int, plane: int, from: Vector2i) -> void:
	var book: Dictionary = _seen[side][plane]
	var reach := maxi(1, sight_cells)
	for dx in range(-reach, reach + 1):
		for dy in range(-reach, reach + 1):
			var cell := from + Vector2i(dx, dy)
			# A circle rather than the square the loop walks, so the corner of the box is not
			# further than the axis and sight is the same in every direction.
			if dx * dx + dy * dy > reach * reach:
				continue
			if not _network.is_dug(plane, cell):
				continue
			# Yours already, permanently, and by a better route than looking at it.
			if _network.is_tunnel_known(plane, cell, side):
				continue
			# Someone else on the crew already refreshed it this sweep.
			if book.get(cell, 1.0) == 0.0:
				continue
			if not _clear(plane, from, cell):
				continue
			if not book.has(cell):
				_touch(side, plane)
			book[cell] = 0.0


## Shaft mouths on the lawn, which need no line test: a hole in the grass with daylight going
## down it is not something you fail to notice at eleven metres.
func _look_for_mouths(side: int, from: Vector3) -> void:
	var book: Dictionary = _mouths[side]
	for cell: Vector2i in _network.shaft_cells(0):
		if _network.is_tunnel_known(1, cell, side):
			continue
		var at := _network.cell_to_world(0, cell)
		if Vector2(at.x - from.x, at.z - from.z).length() > mouth_range:
			continue
		book[cell] = 0.0


## Is every cell between these two open?
##
## Walked as a straight line sampled finely enough that no cell on it is skipped -- two samples a
## cell, which is more than the half-cell diagonal needs. Both ends are excluded: the cell you are
## standing in is not in your way, and the cell you are looking at is the thing being asked about.
##
## THE CORNER CASE IS THE POINT. A line clipping the diagonal between two closed cells passes
## through both of them and is refused, so you cannot see round a corner into a corridor that
## merely touches yours. Getting this wrong the generous way would be a slow leak: every
## intersection would donate a little more of the enemy route than the crew earned.
func _clear(plane: int, from: Vector2i, to: Vector2i) -> bool:
	var span := Vector2(to - from)
	var steps := int(ceilf(span.length() * 2.0))
	if steps <= 1:
		return true
	for i in range(1, steps):
		var at := Vector2(from) + span * (float(i) / float(steps))
		var cell := Vector2i(roundi(at.x), roundi(at.y))
		if cell == from or cell == to:
			continue
		if not _network.is_dug(plane, cell):
			return false
	return true


## A collapsed cell is forgotten by everyone at once. It is not stale information -- it is a place
## that no longer exists, and leaving it fading on a map would have a crew planning through rubble.
func _on_collapsed(plane: int, cell: Vector2i) -> void:
	if plane < 0 or plane >= TunnelNetwork.PLANE_COUNT:
		return
	# PLANE 0 IS A MOUTH GOING, not a floor: the Brute filled an entrance in. Mouths age out of
	# `_mouths` on their own after half a minute, which is the right rule for a hole somebody walked
	# past and the wrong one for a hole that no longer exists -- thirty seconds of a crew routing
	# towards a door that has been earth the whole time.
	if plane == 0:
		for side in [Team.BLUE, Team.RED]:
			_mouths[side].erase(cell)
		return
	for side in [Team.BLUE, Team.RED]:
		if _seen[side][plane].erase(cell):
			_touch(side, plane)
