class_name SonarMark
extends MeshInstance3D
## A piece of Sneak cant scratched onto the floor above a detected tunnel.
##
## It is world information, not a private HUD ping. The owning crew can always read it; an enemy
## can only see it while playing a Sneak, which is also the only class allowed to erase it.

const MARK_GROUP: StringName = &"sonar_mark"

var owner_team: int = Team.BLUE
var plane: int = 0
var target_plane: int = 1
var cell: Vector2i = Vector2i.ZERO


func configure(network: TunnelNetwork, side: int, source_plane: int, target: Vector2i) -> void:
	owner_team = clampi(side, Team.BLUE, Team.RED)
	plane = clampi(source_plane, 0, TunnelNetwork.PLANE_COUNT - 1)
	target_plane = mini(plane + 1, TunnelNetwork.PLANE_COUNT - 1)
	cell = target
	name = "SonarMark_%s_%d_%d_%d" % [Team.name_of(owner_team), plane, cell.x, cell.y]
	position = network.cell_to_world(plane, cell) + Vector3.UP * 0.035
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_to_group(MARK_GROUP)
	mesh = _glyph()


func can_be_seen_by(viewer_team: int, viewer_class: int) -> bool:
	return viewer_team == owner_team or viewer_class == MouseClass.SNEAK


func _glyph() -> ArrayMesh:
	var material := StandardMaterial3D.new()
	var colour := Team.color_of(owner_team).lerp(Color(0.92, 0.89, 0.72), 0.58)
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_material(material)
	# A forked downward rune: "a way runs beneath this place", readable at mouse scale without
	# looking like another mouse, shaft, or objective marker.
	_bar(tool, Vector2(-0.34, -0.18), Vector2(0.0, 0.17), 0.075, colour)
	_bar(tool, Vector2(0.0, 0.17), Vector2(0.34, -0.18), 0.075, colour)
	_bar(tool, Vector2(0.0, 0.18), Vector2(0.0, -0.36), 0.075, colour)
	return tool.commit()


func _bar(tool: SurfaceTool, a: Vector2, b: Vector2, width: float, colour: Color) -> void:
	var direction := (b - a).normalized()
	var across := Vector2(-direction.y, direction.x) * width * 0.5
	var points := [a + across, b + across, b - across, a - across]
	for index in [0, 1, 2, 0, 2, 3]:
		var point: Vector2 = points[index]
		tool.set_normal(Vector3.UP)
		tool.set_color(colour)
		tool.add_vertex(Vector3(point.x, 0.0, point.y))
