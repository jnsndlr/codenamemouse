extends Node
## The actual M2 experiment: making four stacked planes readable from one camera.
##
## Two rules, both from GDD section 3:
##   1. Descend and the SURFACE ghosts out, so it stops hiding what's under it.
##   2. Exactly ONE plane is in focus at a time. Everything else fades back.
##
## Rule 2 is the load-bearing one and it's worth stating why. Rendering all four planes at
## equal weight produces a pile of overlapping outlines that reads as noise -- you can see
## there is a network but not what shape it is. Focusing one plane costs you the overview
## and buys you comprehension, and the bet of this milestone is that that trade is correct.
## If it isn't, the fallback is dropping from three depths to two, not tuning these alphas.

@export var network_path: NodePath
@export var player_path: NodePath
## Everything that should ghost when the player goes under it.
@export var surface_path: NodePath

@export_group("Ghosting")
@export_range(0.0, 1.0, 0.01) var surface_alpha_underground: float = 0.16
## Deliberately unhurried. Snapping the whole world's opacity on a plane change is
## disorienting; a visible fade tells you what just happened and why.
@export var fade_speed: float = 5.0

var _network: TunnelNetwork
var _player: Node3D
var _materials: Array[StandardMaterial3D] = []
var _alpha: float = 1.0
var _last_plane: int = -1


func _ready() -> void:
	_network = get_node_or_null(network_path) as TunnelNetwork
	_player = get_node_or_null(player_path) as Node3D
	_collect_surface_materials()


## Each surface mesh gets its own material copy so fading them can't leak into anything
## else sharing the same resource -- including the tunnel materials, which are tinted
## separately and would otherwise vanish along with the ground.
func _collect_surface_materials() -> void:
	var surface := get_node_or_null(surface_path) as Node3D
	if surface == null:
		return

	for node in surface.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		var material := _fadeable(mesh_instance.get_active_material(0))
		mesh_instance.material_override = material
		_materials.append(material)

	# The ground is CSG so entrances can be subtracted out of it (see surface_holes.gd).
	# CSG primitives carry their own material and have no material_override, so they are
	# collected separately rather than being silently skipped and left opaque.
	for node in surface.find_children("*", "CSGPrimitive3D", true, false):
		var primitive := node as CSGPrimitive3D
		if primitive.operation != CSGShape3D.OPERATION_UNION:
			continue
		var material := _fadeable(primitive.material)
		primitive.material = material
		_materials.append(material)


func _fadeable(source: Material) -> StandardMaterial3D:
	var material: StandardMaterial3D = (
		source.duplicate() if source is StandardMaterial3D else StandardMaterial3D.new()
	)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _process(delta: float) -> void:
	if _network == null or _player == null:
		return

	var plane := _network.plane_at_height(_player.global_position.y)
	if plane != _last_plane:
		_network.set_focus_plane(plane)
		_last_plane = plane

	var wanted := 1.0 if plane <= 0 else surface_alpha_underground
	_alpha = lerpf(_alpha, wanted, 1.0 - exp(-fade_speed * delta))

	for material in _materials:
		var colour := material.albedo_color
		colour.a = _alpha
		material.albedo_color = colour


func get_current_plane() -> int:
	return _last_plane
