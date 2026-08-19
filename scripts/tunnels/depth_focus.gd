extends Node
## How the world above you gets out of the way.
##
## M2 did this by ghosting: fade the surface to 16% alpha and look at the tunnel through it.
## It worked, but it was always a compromise -- you were reading a network through a sheet of
## translucent grass, everything landed in the transparent pass with depth-write off, and the
## rendering bugs that caused are documented all over tunnel_network.gd.
##
## This does it the way the ground actually behaves: the tunnel is an open TRENCH cut down
## through solid earth, and you look into it. The ground is cut away exactly where the layer
## below is dug (earth_cutaway.gdshader), and the surface is pushed back with LIGHT rather
## than opacity -- darkened and desaturated, the way a garden reads at dusk next to a lamplit
## burrow. Nothing is transparent, so nothing has to sort.
##
## The cut is a RENDERING cut only. Collision is untouched, so the ground stays solid and you
## still enter a tunnel by choosing to, not by walking into a hole.

## What sits ON the ground rather than being the ground: rocks, grass, paving and props. Marked in
## the scene rather than listed here, because "is this scenery or is this the world" is a
## per-object question a map author answers and this file has no way to guess. This group is also
## the minimap contract: add every new surface object here; generators expose `minimap_shapes()`
## and ordinary GeometryInstance3D props get a footprint automatically.
const SURFACE_CLUTTER: StringName = &"surface_clutter"

@export var network_path: NodePath
@export var player_path: NodePath
## Everything that belongs to the world above: ground, walls, props, rocks.
@export var surface_path: NodePath
## The ground slab itself. Named explicitly rather than found by guesswork, because the
## perimeter walls are siblings of it and must NOT be cut -- a hole in the arena wall is a way
## out of the map.
@export var ground_slab_path: NodePath
## The scene's WorldEnvironment. Underground, sky ambient is the enemy of everything the
## lamps are trying to do -- it lights the earth evenly from nowhere, so the trench reads flat
## and the pools of lamplight have nothing to be brighter than.
@export var environment_path: NodePath

@export_group("Ghosting")
## How far down the surface goes once you are under it. Not black: the props and rocks up
## there are your landmarks for where you are in the arena.
@export_range(0.0, 1.0, 0.01) var surface_dim_underground: float = 0.20
## Deliberately unhurried. Snapping the whole world's brightness on a plane change is
## disorienting; a visible fade tells you what just happened and why.
@export var fade_speed: float = 5.0
## Sky ambient once you are underground, as a fraction of what it is up top.
@export_range(0.0, 1.0, 0.01) var ambient_underground: float = 0.22

var _network: TunnelNetwork
var _player: Node3D
var _surface: Node3D
var _clutter: Array[Node3D] = []
var _materials: Array[StandardMaterial3D] = []
var _slab_material: ShaderMaterial
var _environment: Environment
var _surface_ambient: float = 0.45
var _dim: float = 1.0
var _last_plane: int = -1


func _ready() -> void:
	_network = get_node_or_null(network_path) as TunnelNetwork
	_player = get_node_or_null(player_path) as Node3D
	_surface = get_node_or_null(surface_path) as Node3D
	var world := get_node_or_null(environment_path) as WorldEnvironment
	if world != null and world.environment != null:
		_environment = world.environment
		_surface_ambient = _environment.ambient_light_energy
	_cut_the_ground()
	_collect_surface_materials()
	for node in get_tree().get_nodes_in_group(SURFACE_CLUTTER):
		var scenery := node as Node3D
		if scenery != null:
			_clutter.append(scenery)


## Hand the ground slab the same cutaway shader planes 2 and 3 use on their own earth lids, so
## the surface is simply the lid of plane 1 and every layer is treated identically.
func _cut_the_ground() -> void:
	var slab := get_node_or_null(ground_slab_path) as CSGPrimitive3D
	if slab == null or _network == null:
		return

	var source := slab.material as StandardMaterial3D
	_slab_material = ShaderMaterial.new()
	_slab_material.shader = load("res://art/shaders/earth_cutaway.gdshader") as Shader
	_slab_material.set_shader_parameter("dug_here", _network.dug_mask(1))
	# Plane 0 holds no floor of its own -- the lawn IS its floor, and a surface entrance is
	# just a mark laid on top of it. So there is nothing coplanar up here to make room for.
	_slab_material.set_shader_parameter("cut_above", false)
	_slab_material.set_shader_parameter("dug_above", _network.dug_mask(0))
	_slab_material.set_shader_parameter("field_half_metres", float(_network.mask_half_cells()))
	_slab_material.set_shader_parameter(
		"field_texels_per_metre", float(TunnelContour.TEXELS_PER_METRE)
	)
	# The lawn is the lid of plane 1 and takes the same rim back its walls lean away by, so an
	# entrance reads as a cut in the ground rather than as a hole punched in a sheet of it.
	_slab_material.set_shader_parameter("dug_grow", _network.rim_grow(1))
	_slab_material.set_shader_parameter(
		"albedo_color", source.albedo_color if source != null else Color(0.44, 0.42, 0.31)
	)
	# The same grain the trench floors and lids carry, so the lawn is the top of the same earth
	# rather than a differently-made surface that happens to be brown.
	_slab_material.set_shader_parameter("dirt", DirtTexture.shared())
	_slab_material.set_shader_parameter("dirt_tile", DirtTexture.WORLD_TILE)
	slab.material = _slab_material


## Each surface mesh gets its own material copy so dimming them can't leak into anything else
## sharing the same resource -- including the tunnel materials, which are lit separately and
## would otherwise darken along with the ground.
func _collect_surface_materials() -> void:
	if _surface == null:
		return

	# Deduplicated by source material. The rock scatter shares one material across ~760
	# meshes; a copy each would mean 760 materials to walk every frame of a fade, for
	# identical output.
	var seen: Dictionary = {}
	for node in _surface.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		var source: Material = mesh_instance.get_active_material(0)
		var key: Variant = source.get_instance_id() if source != null else 0
		if not seen.has(key):
			var made := _dimmable(source)
			seen[key] = made
			_materials.append(made)
		mesh_instance.material_override = seen[key]

	# CSG primitives carry their own material and have no material_override, so they are
	# collected separately rather than being silently skipped and left bright. The slab is
	# excluded -- it is on the cutaway shader now and dims through its own uniform.
	for node in _surface.find_children("*", "CSGPrimitive3D", true, false):
		var primitive := node as CSGPrimitive3D
		if primitive.operation != CSGShape3D.OPERATION_UNION:
			continue
		if primitive.material == _slab_material:
			continue
		var material := _dimmable(primitive.material)
		primitive.material = material
		_materials.append(material)


## Opaque, always. Dimming multiplies albedo instead of dropping alpha, which is the whole
## point: marking these transparent up front is what once put an 80x80 ground slab in the same
## depth-write-off pass as 760 rocks and had it paint straight over all of them.
func _dimmable(source: Material) -> StandardMaterial3D:
	var material: StandardMaterial3D = (
		source.duplicate() if source is StandardMaterial3D else StandardMaterial3D.new()
	)
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.set_meta("base_albedo", material.albedo_color)
	return material


func _process(delta: float) -> void:
	if _network == null or _player == null:
		return

	var plane := _network.plane_at_height(_player.global_position.y)
	if plane != _last_plane:
		_network.set_focus_plane(plane)
		_last_plane = plane

	# WHOSE ROCK IS DRAWN. Veins are hidden until a crew digs into one (GDD section 3), so the
	# network has to be told which crew is looking through this camera -- it cannot go and find out
	# for itself without a rendering object reaching into the match to ask whose side it is on, and
	# at M7 that question has no single answer on a server. Told every frame and ignored unless it
	# changed, which is once: this file already owns "what the local player can see of the layers",
	# and a one-off call in `_ready` would miss the player being handed a different mouse.
	var side: Variant = _player.get("team")
	if side != null:
		_network.show_crew_knowledge(int(side))

	# Below plane 1 the surface isn't dimmed, it's GONE -- you are looking down at the earth
	# lid of your own layer, and the garden two storeys up would only float over the top of it.
	if _surface != null:
		_surface.visible = plane <= 1

	# THE LAWN'S CLUTTER GOES THE MOMENT YOU ARE UNDER IT, one layer sooner than the ground it
	# stands on. The ground has to stay: it is plane 1's lid, and the trench is a cut through it.
	# What sits on top of it does not -- a rock and a tuft of grass drawn over an open trench are
	# a metre above the floor you are reading and land on it from this angle, so the corridor
	# fills with objects that look like they are in it and are not. Dimming them to 20% was not
	# enough, because the problem was never brightness; it was that they are in the way.
	for scenery: Node3D in _clutter:
		scenery.visible = plane <= 0

	var wanted := 1.0 if plane <= 0 else surface_dim_underground
	_dim = lerpf(_dim, wanted, 1.0 - exp(-fade_speed * delta))

	for material in _materials:
		material.albedo_color = (material.get_meta("base_albedo") as Color) * _dim
	if _slab_material != null:
		_slab_material.set_shader_parameter("dim", _dim)
		# The ground CLOSES UP when you're standing on it. Left permanently cut, the whole
		# tunnel network read as a black trench drawn across the lawn from a surface view --
		# which gives away for free the hidden information the game is built on.
		_slab_material.set_shader_parameter("cutting", plane >= 1)
	if _environment != null:
		_environment.ambient_light_energy = lerpf(
			_surface_ambient * ambient_underground, _surface_ambient,
			inverse_lerp(surface_dim_underground, 1.0, _dim)
		)


func get_current_plane() -> int:
	return _last_plane
