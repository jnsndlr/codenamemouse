class_name DigCursor
extends Node3D
## A cubic metre of ground being worked on, and how far through the work you are.
##
## `[NO LONGER THE DIG'S]`, which is worth knowing before reading anything below: the name and
## every instinct about this class come from digging, and digging is the one thing that does not
## use it any more. Holding the dig button draws itself now -- the paws scrabble and the earth
## comes off the face (see [DigDust]) -- and a box was drawn on every stroke the cursor merely
## PASSED OVER, which meant a wireframe flickering across the ground all match for a control that
## was not being used.
##
## ONE CALLER LEFT: an Engineer bracing a cell ([ShoreUp]). The Brute's cave-in used to borrow this
## too, and that turned out to be the shape's real problem rather than a saving -- two unrelated
## abilities drawing the identical orange cube meant a Brute's aim was reported as a dig cursor
## that would not go away, by a player who was not digging. It has its own mark now
## ([CollapseCursor]); if a third thing ever wants this box, that is the question to ask first.
##
## Drawn in the world on the block itself rather than as a HUD element by the cursor. The thing
## being described is a cubic metre of ground, so it should be lit on that cube -- a bar
## floating near the mouse would make you look away from the exact spot you are aiming at to
## read how it's going.
##
## A CUBE, floor to lid, not a square on the floor. What these abilities act on is the whole cell,
## and outlining only its base described the hole rather than the thing being acted on.
##
## Two readings off one box: a wireframe saying WHERE, and light rising through it saying HOW FAR.
## Both abilities that still use it are held for a stretch of seconds, which is what the rising
## light is for and is precisely what digging stopped being.
##
## Everything visual lives in dig_cursor.gdshader, including why it ignores depth. This used to
## be four mesh bars and an additive material, and both halves of it were invisible in practice.

@export var hover_color: Color = Color(0.55, 0.95, 1.00, 0.95)
## The part of the wireframe still to be dug. Deliberately the dimmest, deepest colour here:
## the countdown is read off the CONTRAST between this and the flooded part, so a bright orange
## un-dug wireframe would make the rising light almost invisible against it.
@export var digging_color: Color = Color(0.85, 0.36, 0.06, 0.90)
## `[REMOVED]` A THIRD COLOUR FOR GROUND THAT WILL NOT OPEN, along with the `show_blocked` door it
## was read through. Both callers are gone the same way: digging stopped drawing a box at all, and
## the cave-in's cursor is its own flat crack now ([CollapseCursor]) with its own two colours. The
## grammar it carried -- grey and NOT pulsing, because a pulse means "go on then" and this state's
## one job was to say the opposite -- is worth keeping in mind for whatever draws refusal next.

var _material: ShaderMaterial
var _box: BoxMesh
var _mesh: MeshInstance3D


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = load("res://art/shaders/dig_cursor.gdshader") as Shader
	_material.set_shader_parameter("edge_color", hover_color)

	_box = BoxMesh.new()
	_mesh = MeshInstance3D.new()
	_mesh.mesh = _box
	_mesh.material_override = _material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)

	visible = false


## Park the cursor on `cell` of `plane`, `progress` of the way through. Vector2i.MAX hides it.
##
## STILL CELL-SHAPED, AND NOW THE ONLY DOOR. Digging stopped being square, grew a stroke-shaped
## box of its own, and has since stopped drawing a box at all; the two abilities that borrow this
## cursor were square the whole way through, because a Brute bringing down a cell (see [CaveIn])
## and an Engineer bracing one (see [ShoreUp]) are both properties of a PLACE rather than strokes
## with a direction.
func show_at(
	network: TunnelNetwork, plane: int, cell: Vector2i, progress: float, digging: bool
) -> void:
	if cell == Vector2i.MAX:
		visible = false
		return

	visible = true
	_fit_cell(network.wall_height)
	global_position = network.cell_to_world(plane, cell)
	rotation = Vector3.ZERO
	_material.set_shader_parameter("edge_color", digging_color if digging else hover_color)
	_material.set_shader_parameter("progress", clampf(progress, 0.0, 1.0))
	_material.set_shader_parameter("pulse", 0.0 if digging else 1.0)


## Size the box to a cubic metre of ground: one cell across, and as tall as the plane's walls, so
## it reaches from the floor the block sits on to the lid it holds up.
##
## Read off the network rather than baked in, because wall_height is an exported dial and a
## cursor that disagreed with it would draw the wrong volume with no visible cause.
##
## KEYED ON THE WHOLE SIZE, not on the height, which is a guard left standing on purpose now that
## there is only one shape to draw. It was put there when the dig wanted a stroke-shaped box off
## the same wall height as this cell-shaped one: keyed on height alone, whichever was drawn first
## would have stuck and the other would silently have borrowed it. The dig's box is gone, but the
## next caller that wants a differently-shaped one will not have to rediscover that.
func _fit_cell(height: float) -> void:
	var size := Vector3(TunnelChunks.CELL, height, TunnelChunks.CELL)
	if _box.size.is_equal_approx(size):
		return
	_box.size = size
	# The mesh is centred on its own origin; lift it so the box's underside sits on the floor.
	_mesh.position = Vector3(0.0, size.y * 0.5, 0.0)
	_material.set_shader_parameter("half_extent", size * 0.5)
