extends Node3D
## Patches of grass that bend away from whoever walks through them (GDD section 8).
##
## PATCHES, NOT A LAWN. Grass here is cover, and cover has to have edges -- the mechanic is
## choosing whether to cross open ground or go the long way through concealment, and a field
## with grass everywhere offers no such choice. Seeded like the rock scatter, so a session is
## reproducible and the patch you learned is where you left it.
##
## One MultiMesh per patch and ONE material for all of them. A per-blade MeshInstance3D the
## way the rocks are done would be tens of thousands of nodes; more to the point the shader
## takes the actor list as a uniform, so a shared material means one upload per frame instead
## of one per patch.
##
## The bend strength each actor carries is computed HERE rather than in the shader, because it
## is a gameplay number and not a rendering one -- the speed ladder is GDD section 9, the tell
## it produces is section 8, and a balance pass on either should not mean editing GLSL.

## Live actors plus the fading marks behind them, sharing one array. Must match the shader's
## own MAX_INFLUENCES -- it sizes a uniform array, so it cannot be read from here.
const MAX_INFLUENCES: int = 48
## Anything that bends grass adds itself here. A group rather than an exported path list, so
## the bots that arrive at M3 start bending grass without this file changing.
const ACTOR_GROUP: StringName = &"grass_actor"

@export var grass_seed: int = 20260731
@export var patch_count: int = 14
## Concealment is a DENSITY question, and the first pass at 900 answered it wrong: scattered
## blades you can see a whole mouse between are scenery, not cover. What has to be true is
## that a still mouse inside a patch is genuinely hard to pick out, because that is the half
## of the trade the speed tell is bought against.
@export var blades_per_patch: int = 4500
## Patch footprint. Wide enough to hide in and to have to commit to crossing.
@export var patch_radius: Vector2 = Vector2(2.5, 5.5)
@export var half_extent: float = 34.0
## No grass on the spawn point, so the first thing you see isn't the inside of a blade.
@export var clear_radius: float = 4.0
## How far in from a patch's rim concealment takes to reach full. The band where you are
## partly hidden -- and where someone watching gets a partial read on you.
@export var edge_softness: float = 1.2

@export_group("Blade")
## Taller than the mouse, or it conceals nothing -- the capsule is about 0.4 and grass that
## comes up to its shoulder just makes it easier to spot.
@export var blade_height: Vector2 = Vector2(0.44, 0.68)
## Wide enough to survive the pixel pass. At 0.05 a blade landed on one or two fat pixels and
## flickered in and out as the camera moved; a mass of grass has to read as a mass.
@export var blade_width: float = 0.085
## Vertical segments. The bend is quadratic in height, so a blade needs enough spans to
## actually curve -- at 1 it can only shear, which reads as a hinge rather than as grass.
@export var blade_segments: int = 3

@export_group("Speed tell")
## At or below this speed a mouse bends nothing at all. This is the Slow rung of the ladder
## (GDD section 9: 3.0 base * 0.45 = 1.35 m/s), and section 8 is explicit that it should cost
## you nothing but time to leave the grass completely still.
@export var quiet_speed: float = 1.4
## The speed that bends grass as hard as it goes -- Sprint (3.0 * 1.4 = 4.2 m/s). Run sits
## between the two and gets a middling wake, which is the whole ladder in two numbers.
@export var loud_speed: float = 4.2

@export_group("Trail")
## How long a mark takes to stand back up. This is the wake (GDD section 8) and it is the more
## informative half of the tell: a gap where someone IS tells you where they are, and a gap
## slowly closing behind them tells you which way they went and how long ago. Zero makes the
## grass springy and instantaneous, which is the source tutorial's behaviour.
@export var springback_seconds: float = 0.5
## How far an actor travels between leaving marks. Tighter is a smoother trail and burns the
## fixed slot budget faster -- at 0.25 a mouse running for the full springback holds about
## twenty of the forty-odd slots, which is why this is a knob and not a constant.
@export var trail_spacing: float = 1.1

var _material: ShaderMaterial
## Live actors and fading marks, packed together for one upload per frame.
var _actors: PackedVector4Array = PackedVector4Array()
## {at: Vector3, strength: float, age: float}, oldest first.
var _trail: Array[Dictionary] = []
## Actor instance id -> where it last left a mark.
var _last_drop: Dictionary = {}
## {at: Vector3, extent: float} per patch, for concealment_at(). Kept beside the MultiMeshes
## rather than derived from them -- a patch's footprint is a gameplay fact, and digging it back
## out of 4500 blade transforms every frame would be absurd.
var _patches: Array[Dictionary] = []


## The material every patch shares, so the look panel can drive its uniforms live. Handing out
## the material rather than proxying each uniform through this script keeps the tuning surface
## in one place -- the shader's own declarations.
func get_material() -> ShaderMaterial:
	return _material


## How much cover a world position has, 0 in the open and 1 deep in a patch.
##
## FADED AT THE EDGE rather than a yes-or-no test, and that matters more than it sounds. A hard
## boundary means a mouse crossing a patch edge pops between visible and hidden in a single
## frame, which reads as a rendering fault and, worse, teaches players to sit exactly on the
## line. A margin makes the edge of cover a real place with its own risk.
##
## Cheap enough to call every frame per actor: fourteen circle tests, no physics query. It also
## means grass concealment needs no collision shapes at all, which keeps 63000 blades out of
## the physics world entirely.
func concealment_at(at: Vector3) -> float:
	var best := 0.0
	for i in range(_patches.size()):
		var centre: Vector3 = _patches[i]["at"]
		var extent: float = _patches[i]["extent"]
		var away := Vector2(at.x - centre.x, at.z - centre.z).length()
		best = maxf(best, smoothstep(extent, extent - edge_softness, away))
		if best >= 1.0:
			break
	return best


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = load("res://art/shaders/grass_interact.gdshader")

	var rng := RandomNumberGenerator.new()
	rng.seed = grass_seed
	var mesh := _blade_mesh()

	var placed := 0
	var attempts := 0
	while placed < patch_count and attempts < patch_count * 20:
		attempts += 1
		var spot := Vector2(
			rng.randf_range(-half_extent, half_extent),
			rng.randf_range(-half_extent, half_extent)
		)
		if spot.length() < clear_radius:
			continue
		var extent := rng.randf_range(patch_radius.x, patch_radius.y)
		_build_patch(placed, spot, extent, mesh, rng)
		_patches.push_back({"at": Vector3(spot.x, 0.0, spot.y), "extent": extent})
		placed += 1

	_actors.resize(MAX_INFLUENCES)
	print("grass: %d patches, %d blades" % [placed, placed * blades_per_patch])


func _process(delta: float) -> void:
	_age_trail(delta)

	var count := 0

	# Live actors first, so they can never be crowded out of the array by their own trail --
	# losing the mark under your feet to make room for one you left a second ago would be
	# exactly backwards.
	for node: Node in get_tree().get_nodes_in_group(ACTOR_GROUP):
		var body := node as Node3D
		if body == null or count >= MAX_INFLUENCES:
			continue
		var at := body.global_position
		var strength := speed_tell(body)
		_actors[count] = Vector4(at.x, at.y, at.z, strength)
		count += 1
		_maybe_drop(body, at, strength)

	for mark: Dictionary in _trail:
		if count >= MAX_INFLUENCES:
			break
		var at: Vector3 = mark["at"]
		# Linear recovery, so the exported number means what it says: a mark is fully gone
		# after exactly `springback_seconds`. An exponential decay would look much the same
		# and turn the knob into "roughly how long, ish".
		var left: float = 1.0 - mark["age"] / maxf(springback_seconds, 0.001)
		_actors[count] = Vector4(at.x, at.y, at.z, mark["strength"] * maxf(left, 0.0))
		count += 1

	# Anything past `count` is stale, and the shader loops to `influence_count` -- but a
	# zeroed tail is cheap insurance against a frame where the count grows before the slot is
	# written, which would otherwise flatten a patch at the world origin.
	for i in range(count, MAX_INFLUENCES):
		_actors[i] = Vector4.ZERO

	_material.set_shader_parameter("influences", _actors)
	_material.set_shader_parameter("influence_count", count)


## Leave a mark if this actor has travelled far enough since its last one.
##
## Distance-gated rather than time-gated, so the trail has even spacing regardless of speed --
## a timer would bunch marks up when you slow down and tear gaps in them when you sprint,
## which is precisely backwards for a tell that is supposed to read faster when you do.
func _maybe_drop(body: Node3D, at: Vector3, strength: float) -> void:
	var id := body.get_instance_id()
	if _last_drop.has(id) and at.distance_to(_last_drop[id]) < trail_spacing:
		return
	_last_drop[id] = at

	# A mouse creeping through leaves no mark at all, so there is nothing to fade -- the
	# quiet end of the ladder has to stay genuinely free (GDD section 8).
	if strength <= 0.01:
		return

	_trail.push_back({"at": at, "strength": strength, "age": 0.0})
	# Oldest marks go first when the budget runs out. They are also the faintest, so the
	# ceiling shows up as a trail that is shorter than asked for rather than one that blinks.
	while _trail.size() > MAX_INFLUENCES:
		_trail.pop_front()


func _age_trail(delta: float) -> void:
	var life := maxf(springback_seconds, 0.001)
	var alive: Array[Dictionary] = []
	for mark: Dictionary in _trail:
		mark["age"] = mark["age"] + delta
		if mark["age"] < life:
			alive.push_back(mark)
	_trail = alive


## Which rung of the speed ladder this actor is on, 0 (silent) to 1 (loudest).
##
## PUBLIC, because two systems must agree on it: the grass uses it to decide how hard to bend,
## and grass_camouflage.gd uses it to decide how visible the mouse is. Computing it twice would
## let them drift, and the moment they drift the mechanic stops being teachable -- what you see
## happen to the grass would no longer be what is happening to you.
##
## Reads MEASURED speed rather than which key is held, exactly as the camera's speed zoom does.
## That matters for the same reason it did there: carrying the flag, wading, or squeezing
## through a tunnel all slow you down, and every one should make you quieter and harder to see
## without anyone writing a special case for it.
func speed_tell(body: Node3D) -> float:
	if not body.has_method("get_horizontal_speed"):
		return 1.0
	var speed: float = body.get_horizontal_speed()
	return smoothstep(quiet_speed, loud_speed, speed)


## One blade, standing on the ground rather than centred on it.
##
## A QuadMesh is already in the XY plane, so it stands up without rotating; it is centred on
## the origin, though, which would bury half of every blade. The offset is what puts the root
## on the ground -- and the root is the end that must not move, since the shader anchors the
## bend to UV.y = 1.
func _blade_mesh() -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(blade_width, 1.0)
	mesh.center_offset = Vector3(0.0, 0.5, 0.0)
	mesh.subdivide_depth = blade_segments
	return mesh


func _build_patch(index: int, centre: Vector2, extent: float, mesh: Mesh,
		rng: RandomNumberGenerator) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	multimesh.instance_count = blades_per_patch

	for i in range(blades_per_patch):
		# Square-rooted radius, or every patch is a dense dot with a bald ring around it:
		# sampling radius uniformly puts as many blades in the tiny middle as in the wide rim.
		var angle := rng.randf_range(0.0, TAU)
		var reach := sqrt(rng.randf()) * extent
		var at := Vector3(
			centre.x + cos(angle) * reach,
			0.0,
			centre.y + sin(angle) * reach
		)

		var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU))
		# Height is the scale, since the blade mesh is one unit tall by construction.
		basis = basis.scaled(Vector3(1.0, rng.randf_range(blade_height.x, blade_height.y), 1.0))
		# A slight lean off vertical, so a patch doesn't read as a bed of nails.
		basis = basis.rotated(Vector3.RIGHT, rng.randf_range(-0.14, 0.14))
		multimesh.set_instance_transform(i, Transform3D(basis, at))

		# Per-blade tint. Uniform green at this density reads as one solid object, and the
		# bend then has nothing to show up against.
		var shade := rng.randf_range(0.78, 1.12)
		multimesh.set_instance_color(i, Color(shade, shade * rng.randf_range(0.96, 1.04), shade))

	var instance := MultiMeshInstance3D.new()
	instance.name = "Patch%d" % index
	instance.multimesh = multimesh
	instance.material_override = _material
	# The blades are displaced in the vertex shader, which the culler knows nothing about, so
	# a patch clipped at the screen edge would otherwise pop as its untouched bounds leave.
	instance.extra_cull_margin = 2.0
	add_child(instance)
