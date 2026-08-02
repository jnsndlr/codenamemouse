class_name Boulder
extends Node3D
## A rock lying on the lawn, big enough to be in the way above ground and in the earth below it.
##
## THE OBSTRUCTION YOU CAN SEE, and that is the entire design. A rock seam (GDD section 3) is
## invisible until you dig into it, which makes the underground a place you map by paying for the
## knowledge. A boulder is the opposite number: it is standing there in daylight, so the moment you
## look at it you know that plane 1 is shut underneath it. One kind of rock charges you to find out;
## the other tells you for free, and having both is what stops "where is the rock" being one
## question with one answer.
##
## PLANE 1 ONLY. A boulder is a lump sitting IN the topsoil, not a column running to the bottom of
## the map -- so the way past it is to go under it, which is the answer this game most wants you to
## reach for. Blocking every plane would make it a wall, and a wall you can see from the surface is
## just a smaller arena.
##
## IT COVERS CELLS, PLURAL, AND BREAKS IN QUARTERS. Each cell of the footprint is its own
## `Breakable` with its own hit pool, so a four-tile boulder is twenty Brute swings to erase and
## five to open one corner of. That makes clearing it a decision about how much you want -- a gap to
## dig through, or the whole thing gone -- rather than a single long countdown you either finish or
## waste.
##
## SEEDED FROM ITS CELLS, like every other rock in this game, so the same spot always grows the same
## boulder and a screenshot is comparable to the last one.

## Every section gone. The field listens so it can tell the navmesh the ground has changed.
signal cleared(boulder: Boulder)

const GROUP: StringName = &"boulder"

## Footprint in cells, anchored at `origin_cell`. Rectangles only: every real boulder is a lump,
## and an authored outline is a level-editing feature nothing needs yet.
var size: Vector2i = Vector2i.ONE
var origin_cell: Vector2i = Vector2i.ZERO
## Brute swings per cell-section. Five, so a single tile is a real commitment and the four-tile
## boulders are a project -- the number the whole "break it in quarters" idea is priced against.
var hits_per_section: int = 5
## How tall a one-cell section stands, in metres. Well over a mouse (0.4): a boulder you can see
## over is cover you cannot use.
var height: float = 0.9
var rock_color: Color = Color(0.38, 0.38, 0.40)

var _network: TunnelNetwork
var _sections: Array[BoulderSection] = []


## Built and placed in one call, like the barricade -- a boulder that exists but has not claimed its
## cells is a state nothing wants and everything would have to handle.
static func place(
	network: TunnelNetwork, at_cell: Vector2i, span: Vector2i, parent: Node
) -> Boulder:
	var boulder := Boulder.new()
	boulder.origin_cell = at_cell
	boulder.size = Vector2i(maxi(span.x, 1), maxi(span.y, 1))
	boulder._network = network
	parent.add_child(boulder)
	return boulder


## The cells a boulder of `span` anchored at `at_cell` would cover. Static, so the scatter can ask
## before committing to a spot -- and so there is one definition of the footprint rather than one
## for placing and one for testing.
static func cells_for(at_cell: Vector2i, span: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for x in range(maxi(span.x, 1)):
		for y in range(maxi(span.y, 1)):
			cells.append(at_cell + Vector2i(x, y))
	return cells


func _ready() -> void:
	add_to_group(GROUP)
	if _network == null:
		_network = get_tree().get_first_node_in_group(TunnelNetwork.NETWORK_GROUP) as TunnelNetwork
	if _network == null:
		return

	for cell: Vector2i in cells_for(origin_cell, size):
		var section := BoulderSection.new()
		section.name = "Section%d_%d" % [cell.x, cell.y]
		section.cell = cell
		section.hits_to_clear = hits_per_section
		section.height = height
		section.rock_color = rock_color
		section.network = _network
		# The pieces outlive the rock they came off, and this node does not -- see the field's own
		# note. Whatever the boulders hang from is the right home for them.
		section.debris_host = get_parent()
		add_child(section)
		# Placed after entering the tree so the section can put itself at its own cell in world
		# space rather than depending on what transform this node happens to carry.
		section.settle()
		section.broken.connect(_on_section_broken)
		_sections.append(section)


## Where the whole rock sits, for anything that wants to know without walking the sections.
func centre() -> Vector3:
	var middle := Vector2(origin_cell) + (Vector2(size) - Vector2.ONE) * 0.5
	return Vector3(middle.x * TunnelNetwork.CELL, 0.0, middle.y * TunnelNetwork.CELL)


func sections_left() -> int:
	var left := 0
	for section: BoulderSection in _sections:
		if is_instance_valid(section):
			left += 1
	return left


## The surface cells that still contain rock. The minimap asks the boulder instead of drawing its
## original rectangle so a section disappears from the map on the same swing that clears it.
func occupied_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for section: BoulderSection in _sections:
		if is_instance_valid(section) and not section.is_queued_for_deletion():
			cells.append(section.cell)
	return cells


func _on_section_broken(_what: Breakable, _by: Mouse) -> void:
	# One frame late, because the section frees itself deferred and is still standing right now.
	# Counting it as gone here would announce an empty boulder while a quarter of it is on screen.
	await get_tree().process_frame
	if sections_left() <= 0:
		cleared.emit(self)
		queue_free()
