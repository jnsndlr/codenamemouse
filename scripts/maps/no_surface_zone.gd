class_name NoSurfaceZone
extends Node3D
## Ground you can tunnel UNDER but cannot come up through: the patio slab, the concrete path,
## the flagstones (GDD section 3).
##
## THE OTHER KIND OF OBSTRUCTION, and the distinction is the whole reason it exists. Rock stops
## you HORIZONTALLY and moves from plane to plane, so going around one may mean going down. A
## no-surface zone stops you VERTICALLY and only at the lawn: the earth beneath it is ordinary
## earth, diggable end to end on every plane, and the only thing the paving refuses is a mouth.
## That turns a slab into a long committed crossing -- the enemy under the patio has to come up
## somewhere, and you know where the somewheres are, which is a piece of hidden information the
## map hands out for free.
##
## A RULE, NOT A PROP. What is authored here is a footprint and a refusal; the paving it draws is
## a grey box standing in for the real slab, and every query below is about the rectangle rather
## than about the mesh. So the day this map gets a modelled patio, the model becomes a child and
## `show_paving` goes off, and nothing that enforces the rule changes.
##
## THE FOOTPRINT IS A RECTANGLE, because every real one is: a slab, a path, a row of flagstones.
## A radius would make the patio a pond, and an arbitrary polygon is a level-editing feature this
## does not need yet -- two overlapping rectangles cover an L-shaped patio, and the query below
## already answers "any of them" rather than "the one".

## So the network can ask without being wired to any particular map. Joined HERE rather than
## ticked in the scene, unlike the nests: a zone left out of the group is a rule that silently
## does not apply, and the failure looks like the digging code being broken rather than like a
## map that forgot something.
##
## Joined in `_enter_tree`, and that is not a style choice. Godot runs `_enter_tree` over an
## entire subtree before it runs a single `_ready`, so registering there is the only way a zone
## is in the group no matter where the map author put it. In `_ready` the group is only populated
## for nodes that happen to sit ABOVE this one in the scene -- which is exactly how the patio came
## to be carpeted in grass: Surface/Grass paints in its own `_ready`, Surface/Patio is the next
## sibling down, and `seals()` was therefore asking an empty group.
const GROUP: StringName = &"no_surface"

## Half-extents on the ground, in metres: x across, y along z. The node's own yaw rotates it, so
## a path can run diagonally; tilting one is meaningless and nothing here reads it.
@export var extents: Vector2 = Vector2(6.0, 4.0):
	set(value):
		extents = value
		if is_inside_tree():
			_build()

## The grey box. Off for a map whose paving is real geometry parented underneath -- the rule and
## the picture are separate on purpose.
@export var show_paving: bool = true
## Pale, cool and flat against the warm dirt. The message it has to carry from across the yard is
## "this is not ground", because everything the zone does follows from that being obvious.
@export var paving_color: Color = Color(0.62, 0.61, 0.58)
## Just proud of the lawn. Flush z-fights it across the whole slab, the way the nest pads did.
@export var thickness: float = 0.06

var _slab: MeshInstance3D


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	_build()


## The paving's authored footprint, using the same transform as `covers`. The minimap consumes this
## shared shape contract, so replacing the placeholder slab with real art changes neither rule.
func minimap_shapes() -> Array[Dictionary]:
	var corners := PackedVector2Array()
	for corner: Vector3 in [
		Vector3(-extents.x, 0.0, -extents.y),
		Vector3(extents.x, 0.0, -extents.y),
		Vector3(extents.x, 0.0, extents.y),
		Vector3(-extents.x, 0.0, extents.y),
	]:
		var world: Vector3 = to_global(corner)
		corners.append(Vector2(world.x, world.z))
	return [{"kind": &"polygon", "style": &"paving", "points": corners}]


## Does any zone on this map seal `spot`, given in world x/z metres?
##
## `margin` widens every footprint. A shaft mouth is a whole cell wide, so the network asks with
## half a cell of margin: without it a mouth whose CENTRE is a hair off the slab still takes a
## bite out of it, and the hole you are refused and the hole you are allowed are drawn a
## centimetre apart with nothing to tell them apart.
static func seals(tree: SceneTree, spot: Vector2, margin: float = 0.0) -> bool:
	for node in tree.get_nodes_in_group(GROUP):
		var zone := node as NoSurfaceZone
		if zone != null and zone.covers(spot, margin):
			return true
	return false


func covers(spot: Vector2, margin: float = 0.0) -> bool:
	var here := to_local(Vector3(spot.x, global_position.y, spot.y))
	return absf(here.x) <= extents.x + margin and absf(here.z) <= extents.y + margin


func _build() -> void:
	if not show_paving:
		if _slab != null:
			_slab.queue_free()
			_slab = null
		return

	var mesh := BoxMesh.new()
	mesh.size = Vector3(extents.x * 2.0, thickness, extents.y * 2.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = paving_color
	material.roughness = 1.0
	mesh.material = material

	if _slab == null:
		_slab = MeshInstance3D.new()
		_slab.name = "Paving"
		add_child(_slab)
	_slab.mesh = mesh
	# Sitting ON the lawn rather than sunk into it, and with no collider: paving is something you
	# run across, and a box you have to step onto would make the patio a wall.
	_slab.position.y = thickness * 0.5
