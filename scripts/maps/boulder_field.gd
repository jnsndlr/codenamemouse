class_name BoulderField
extends Node3D
## Boulders scattered across the yard: the obstruction you can see, above ground and below it.
##
## SEEDED, like the rock seams and the pebble scatter, because a map you cannot replay is a map you
## cannot learn (GDD section 8 wants layouts to be a recipe plus a seed) and because a bug that only
## happens on one layout is a bug you can only reproduce by luck.
##
## FEW AND LARGE, which is the opposite of the pebble scatter next door and the reason both exist.
## Those are motion reference -- hundreds of small things streaming past so you can feel your own
## speed. These are terrain: a dozen objects big enough to break a sightline, worth walking around,
## and worth going UNDER, which is the only one of the three that this game is really about.
##
## SNAPPED TO THE DIG GRID, because a boulder blocks whole cells of plane 1 and a rock that visually
## straddles two cells while blocking one is a lie you can only discover by digging.
##
## IT IS A GENERATOR, NOT A LAYOUT. When the Backyard BBQ gets designed (GDD section 8) the boulders
## that matter will be placed by hand as children of the map, and this stays as the filler between
## them -- the same relationship the grass patches will have to an authored flowerbed.

## Reads the network for its own rock-clearance rule, so a change there cannot leave boulders
## sitting inside a nest's guaranteed soft ground.
@export var network_path: NodePath

@export var boulder_seed: int = 20260802
## How many to try for. A dozen over an eighty-metre yard is sparse on purpose: this is the first
## thing on this map that makes crossing the middle a route choice rather than a straight line, and
## the honest way to find the right number is to play with it, not to guess it now.
@export var count: int = 14
## Kept inside the perimeter wall, and inside the diggable bounds -- a boulder half outside the
## grid would block cells nobody can reach anyway.
@export var half_extent_cells: int = 32
## The footprints on offer, and how they are weighted -- singles are the common case and the 2x2 is
## the landmark you navigate by.
@export var spans: Array[Vector2i] = [
	Vector2i(1, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2), Vector2i(2, 2)
]
## Brute swings per cell-section: five, so a 2x2 is twenty and a single is a real commitment.
@export var hits_per_section: int = 5
## Height of a section, in metres. Well over a mouse, so a boulder is cover rather than a kerb.
@export var height: Vector2 = Vector2(0.75, 1.15)
@export var rock_color: Color = Color(0.38, 0.38, 0.40)
## Cells of clear ground between boulders. Two boulders touching read as one bigger boulder with a
## seam down it, and the gap between them is where the interesting movement happens.
@export var spacing_cells: int = 3

var _network: TunnelNetwork
var _taken: Dictionary = {}
var _placed: int = 0


func _ready() -> void:
	_network = get_node_or_null(network_path) as TunnelNetwork
	if _network == null:
		_network = get_tree().get_first_node_in_group(TunnelNetwork.NETWORK_GROUP) as TunnelNetwork
	if _network == null:
		push_warning("boulder field: no tunnel network -- boulders would block nothing")
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = boulder_seed

	var attempts := 0
	while _placed < count and attempts < count * 40:
		attempts += 1
		var span: Vector2i = spans[rng.randi_range(0, spans.size() - 1)]
		var at := Vector2i(
			rng.randi_range(-half_extent_cells, half_extent_cells - span.x),
			rng.randi_range(-half_extent_cells, half_extent_cells - span.y)
		)
		if not _clear(at, span):
			continue

		var boulder := Boulder.place(_network, at, span, self)
		boulder.name = "Boulder%d" % _placed
		boulder.hits_per_section = hits_per_section
		boulder.height = rng.randf_range(height.x, height.y)
		boulder.rock_color = rock_color
		boulder.cleared.connect(_on_boulder_cleared)
		for cell: Vector2i in Boulder.cells_for(at, span):
			_taken[cell] = true
		_placed += 1

	print("boulders: %d, covering %d cells of plane 1" % [_placed, _taken.size()])


## Precise live footprints for the shared surface-minimap contract. Asking the surviving sections
## means a quarter disappears from the panel on the same swing that removes it from the yard.
func minimap_shapes() -> Array[Dictionary]:
	var shapes: Array[Dictionary] = []
	for child: Node in get_children():
		var boulder := child as Boulder
		if boulder == null:
			continue
		for cell: Vector2i in boulder.occupied_cells():
			shapes.append({
				"kind": &"circle",
				"style": &"boulder",
				"position": Vector2(cell.x, cell.y) * TunnelNetwork.CELL,
				"radius": TunnelNetwork.CELL * 0.46,
				"min_radius_px": 2.2,
			})
	return shapes


## May a boulder of `span` stand at `at`?
##
## The nest rule is the load-bearing one, and it is the network's own clearance rather than a number
## of this file's choosing. A boulder inside that radius would put rock in the ground a crew is
## guaranteed to be able to dig -- which the tunnel audit asserts, correctly, and which in play is a
## crew that cannot get underground at home in the same place every single match.
func _clear(at: Vector2i, span: Vector2i) -> bool:
	for cell: Vector2i in Boulder.cells_for(at, span):
		if not _network.in_bounds(cell) or _network.is_rock(1, cell):
			return false
		var here := Vector2(cell.x * TunnelNetwork.CELL, cell.y * TunnelNetwork.CELL)
		if Nest.blocks(get_tree(), here, _network.rock_nest_clearance):
			return false
		# Not on the paving either. A boulder sitting on the patio is a rock on a concrete slab,
		# and the cell it would block is one nobody can surface into anyway.
		if NoSurfaceZone.seals(get_tree(), here, TunnelNetwork.CELL):
			return false
		# And not up against another boulder. Checked as a square ring rather than a circle, to
		# match the way every other spacing rule in this project is measured.
		for x in range(cell.x - spacing_cells, cell.x + spacing_cells + 1):
			for y in range(cell.y - spacing_cells, cell.y + spacing_cells + 1):
				if _taken.has(Vector2i(x, y)):
					return false
	return true


## A boulder is gone: the ground it stood on is walkable now, and the navmesh still thinks it
## is not.
##
## REBAKED, THREADED. nav_surface.gd bakes once at startup and its own comment says to revisit if
## the map ever changes mid-match -- this is that. Leaving it stale is not neutral: bots would keep
## walking around a rock that a Brute has just spent twenty swings removing, which reads as the AI
## refusing to use the thing you made for it. Threaded because the bake reads meshes back off the
## GPU and doing that on the main thread is a visible hitch; one bake per boulder cleared, and a
## boulder takes twenty swings, so the rate is not a concern.
func _on_boulder_cleared(_boulder: Boulder) -> void:
	var region := get_tree().get_first_node_in_group(NavSurface.REGION_GROUP) as NavSurface
	if region != null:
		region.rebake()
