class_name Shoring
extends Node3D
## The timbers in a shored cell: what three seconds of an Engineer's attention looks like from
## inside the corridor (GDD section 4).
##
## SCENERY, AND ONLY SCENERY. Every rule about shoring lives in [TunnelNetwork] -- the book of
## which cells are shored, the absorb inside `collapse`, the wire. This node has no collider, takes
## no part in routing, and nothing asks it a question. That separation is deliberate and it is the
## opposite of [BarricadeRock], which is a wall and therefore has to be physical, routed and
## breakable all at once: a barricade you can see and walk through would be a lie about the map,
## whereas shoring you can see and walk through is exactly what shoring is.
##
## WHICH IS WHY IT FREES ITSELF OFF A SIGNAL rather than being freed by whoever removed the
## shoring. There are four ways a cell stops being shored -- a Brute spends a collapse on it, the
## floor under it goes for some other reason, a client's crew forgets that corridor, or the match
## ends -- and only two of them have a caller who could reasonably be asked to tidy up. All four
## pass through `shoring_broke`, so listening for it is the one arrangement where the prop cannot
## outlive the fact it is drawing. The same argument [BarricadeRock] makes for watching
## `cell_collapsed` under its own feet, applied to everything rather than to one case.
##
## IDENTICAL ON A HOST AND A CLIENT, and that falls out of the above rather than being arranged.
## Both machines keep the shoring book -- one by deciding, one by being told (see
## [method TunnelNetwork.adopt_shoring]) -- and both spawn this from the same signal. There is no
## replica flag here because there is nothing for a replica to do differently.
##
## THREE PIECES OF WOOD AND NOT A MODEL. Two posts against the walls and a lintel across them: the
## universally legible shape for *this bit of roof is being held up*, at any angle, in a game whose
## corridors are a metre wide and lit by one lamp every four cells. The posts sit hard against the
## walls so a mouse never runs into the thing visually blocking its way.

## So a fresh prop can find out whether one is already standing here, and so an audit can count
## what is drawn against what the network says is shored.
const SHORING_GROUP: StringName = &"shoring"

## How much of the cell the timbers span, wall to wall. Just under 1.0 so the posts read as being
## set against the earth rather than embedded in it.
@export var fill: float = 0.92
## Post thickness as a fraction of the cell.
@export var beam: float = 0.11
## How far up the corridor the timbers reach. Not the full wall: a lintel flush against the ceiling
## disappears into it, and the gap is what makes the roof read as being *held*.
@export var height_fraction: float = 0.88
@export var wood_color: Color = Color(0.42, 0.29, 0.16)

var plane: int = 0
var cell: Vector2i = Vector2i.ZERO

var _network: TunnelNetwork


## Put timbers in the world at a cell the network already considers shored.
##
## THE NETWORK IS ASKED FIRST AND IS NOT TOLD ANYTHING HERE. Callers shore the cell through
## [method TunnelNetwork.shore] (or the wire does through `adopt_shoring`) and this draws the
## result -- so a prop can never exist over a cell the rules disagree about. Returns the existing
## prop rather than a second one if the cell already has timbers.
static func place(network: TunnelNetwork, at_plane: int, at_cell: Vector2i) -> Shoring:
	if network == null:
		return null
	var standing := at(network, at_plane, at_cell)
	if standing != null:
		return standing
	var timbers := Shoring.new()
	timbers.plane = at_plane
	timbers.cell = at_cell
	timbers._network = network
	network.add_child(timbers)
	return timbers


## The timbers standing in a cell, or null. Searched rather than indexed: there are a handful of
## these in a match and a second table would be a second thing to keep in step with the first.
static func at(tree_node: Node, at_plane: int, at_cell: Vector2i) -> Shoring:
	if tree_node == null or not tree_node.is_inside_tree():
		return null
	for node: Node in tree_node.get_tree().get_nodes_in_group(SHORING_GROUP):
		var timbers := node as Shoring
		if (
			timbers != null and not timbers.is_queued_for_deletion()
			and timbers.plane == at_plane and timbers.cell == at_cell
		):
			return timbers
	return null


func _ready() -> void:
	add_to_group(SHORING_GROUP)
	if _network == null:
		_network = get_parent() as TunnelNetwork
	if _network == null:
		queue_free()
		return
	global_position = _network.cell_to_world(plane, cell)
	_build(TunnelNetwork.CELL * fill, _network.wall_height * height_fraction)
	_network.shoring_broke.connect(_on_shoring_broke)


## Drawn ACROSS the corridor, which is a guess this makes on purpose and states out loud.
##
## A cell has no direction -- it is a square of floor with earth on some sides and corridor on
## others -- so there is no correct axis for a lintel until you look at the neighbours, and looking
## at the neighbours gets it wrong at a junction anyway. Both posts and one beam over the top reads
## as shoring from either approach, and the one thing it must never do is look like a barricade.
func _build(span: float, tall: float) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = wood_color
	material.roughness = 0.95
	material.metallic = 0.0

	var thick := TunnelNetwork.CELL * beam
	var post := Vector3(thick, tall, thick)
	var edge := (span - thick) * 0.5
	_piece(material, post, Vector3(0.0, tall * 0.5, -edge))
	_piece(material, post, Vector3(0.0, tall * 0.5, edge))
	# The lintel spans the two posts and sits on top of them, so the joint reads as carpentry
	# rather than as three boxes that happen to touch.
	_piece(
		material, Vector3(thick, thick, span), Vector3(0.0, tall - thick * 0.5, 0.0)
	)


func _piece(material: StandardMaterial3D, size: Vector3, at: Vector3) -> void:
	var box := BoxMesh.new()
	box.size = size
	var piece := MeshInstance3D.new()
	piece.mesh = box
	piece.material_override = material
	piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	piece.position = at
	add_child(piece)


## No debris and no splinters, and that is the same rule [BarricadeRock.discard_replica] states:
## on a client, timbers vanishing can mean *the Brute broke them* or *your crew stopped being able
## to see that corridor*, and inventing a burst for the second one would leak the fact that
## somebody is down there through a particle effect. The Brute gets its confirmation in words, from
## the ability that spent the cooldown.
func _on_shoring_broke(at_plane: int, at_cell: Vector2i) -> void:
	if at_plane == plane and at_cell == cell:
		remove_from_group(SHORING_GROUP)
		queue_free()
