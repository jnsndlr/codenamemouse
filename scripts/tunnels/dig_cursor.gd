class_name DigCursor
extends Node3D
## The block of earth you are about to dig, and how far through digging it you are.
##
## Drawn in the world on the block itself rather than as a HUD element by the cursor. The thing
## being described is a cubic metre of ground, so it should be lit on that cube -- a bar
## floating near the mouse would make you look away from the exact spot you are aiming at to
## read how it's going.
##
## A CUBE, floor to lid, not a square on the floor. What a dig removes is the whole cell, and
## outlining only its base described the hole you would be left with rather than the thing you
## are about to take away.
##
## Two readings off one box: a wireframe saying WHERE, and light rising through it saying HOW
## FAR. The wireframe appears on hover with no button pressed, which is what makes the reach and
## adjacency rules learnable -- you find out a tile is out of range by pointing at it, not by
## holding a button for half a second and being told nothing happened.
##
## Everything visual lives in dig_cursor.gdshader, including why it ignores depth. This used to
## be four mesh bars and an additive material, and both halves of it were invisible in practice.

@export var hover_color: Color = Color(0.55, 0.95, 1.00, 0.95)
## The part of the wireframe still to be dug. Deliberately the dimmest, deepest colour here:
## the countdown is read off the CONTRAST between this and the flooded part, so a bright orange
## un-dug wireframe would make the rising light almost invisible against it.
@export var digging_color: Color = Color(0.85, 0.36, 0.06, 0.90)
## A block of rock (GDD section 3). Grey and, unlike the other two, NOT pulsing: a pulse is this
## cursor's way of saying "go on then", and the one thing this state has to say is that holding the
## button will achieve nothing. You find out the seam is there by pointing at it, which is the same
## way you find out a tile is out of reach.
@export var blocked_color: Color = Color(0.72, 0.75, 0.80, 0.85)

var _material: ShaderMaterial
var _box: BoxMesh
var _mesh: MeshInstance3D
var _height: float = 0.0


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
func show_at(
	network: TunnelNetwork, plane: int, cell: Vector2i, progress: float, digging: bool
) -> void:
	if cell == Vector2i.MAX:
		visible = false
		return

	visible = true
	_fit(network.wall_height)
	global_position = network.cell_to_world(plane, cell)
	_material.set_shader_parameter("edge_color", digging_color if digging else hover_color)
	_material.set_shader_parameter("progress", clampf(progress, 0.0, 1.0))
	# The hover pulse and the rising flood are the same channel of attention. Leaving the pulse
	# running under the flood makes the countdown look like it is stuttering.
	_material.set_shader_parameter("pulse", 0.0 if digging else 1.0)


## Park the cursor on a cell that is never going to open. Same box, so the thing being described
## is still a cubic metre of ground -- it is just a cubic metre of rock.
func show_blocked(network: TunnelNetwork, plane: int, cell: Vector2i) -> void:
	if cell == Vector2i.MAX:
		visible = false
		return

	visible = true
	_fit(network.wall_height)
	global_position = network.cell_to_world(plane, cell)
	_material.set_shader_parameter("edge_color", blocked_color)
	_material.set_shader_parameter("progress", 0.0)
	_material.set_shader_parameter("pulse", 0.0)


## Size the box to the seam being cut: one cell across, and as tall as the plane's walls, so it
## reaches from the floor the block sits on to the lid it holds up.
##
## Read off the network rather than baked in, because wall_height is an exported dial and a
## cursor that disagreed with it would draw the wrong volume with no visible cause.
func _fit(height: float) -> void:
	if is_equal_approx(height, _height):
		return
	_height = height
	_box.size = Vector3(TunnelChunks.CELL, height, TunnelChunks.CELL)
	# The mesh is centred on its own origin; lift it so the cube's underside sits on the floor.
	_mesh.position = Vector3(0.0, height * 0.5, 0.0)
	_material.set_shader_parameter(
		"half_extent", Vector3(TunnelChunks.CELL * 0.5, height * 0.5, TunnelChunks.CELL * 0.5)
	)
