class_name GrassPatch
extends Node3D
## Noise-painted grass that bends away from whoever walks through it (GDD section 8).
##
## PAINTED BY NOISE, NOT STAMPED AS CIRCLES. Grass is cover and cover needs organic edges. A broad
## noise field paints growing regions over the whole yard while a detail field breaks those regions
## into wisps, gaps and dense islands. Render chunks are only a culling/performance detail; neither
## the visible grass, concealment, nor the minimap knows or exposes their rectangular boundaries.
##
## One MultiMesh per render chunk and ONE material for all of them. A per-blade MeshInstance3D the
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
## Half-step used to difference the painted field into a gradient. Has to sit well below the
## finest wavelength in play or it measures noise instead of slope: the detail field's top octave
## is 0.19 * 4 = 0.76, about a 1.3 m wavelength, so 0.05 has plenty of room.
const GRADIENT_STEP: float = 0.05
## Extra cull margin on each render chunk, in metres.
##
## Covers exactly what the mesh bounds cannot know about: the shader's own displacement. That is
## `interact_power` (0.18) times a push the shader clamps to 1, plus `wind_strength` (0.035) on two
## axes, so about 0.19 m at the absolute worst. This was 2.0 -- eleven times what it needs, which on
## a 6 m chunk means culling a box more than twice the chunk's own width and drawing a third more
## grass than is on screen.
const CULL_MARGIN: float = 0.35

@export var grass_seed: int = 20260731
@export var half_extent: float = 34.0
## No grass on the spawn point, so the first thing you see isn't the inside of a blade.
@export var clear_radius: float = 4.0

@export_group("Distribution")
## Candidate spacing at maximum noise density. 0.15 is about 44 blades per square metre: thick
## enough to make the noise peaks real cover without paying that cost over the whole arena.
@export_range(0.08, 0.5, 0.01) var sample_spacing: float = 0.15
## Render-only chunk size. Smaller chunks cull better; this never affects the painted pattern.
##
## The camera is orthographic and tightly zoomed (camera_rig.gd: 7.5 idle to 10.75 sprint), so it
## only ever sees 3-6% of the arena -- which makes chunk granularity, not blade count, the thing
## that decides how much grass gets vertex-shaded. tools/grass_cull_probe.gd measures the whole
## curve; 6 m with the tightened margin draws about 15% of the field at sprint zoom against 23% for
## the old 8 m and 2.0 margin, and 4 m only buys another point and a half for 289 draw calls.
@export_range(3.0, 20.0, 1.0) var render_chunk_size: float = 6.0
## Broad soil/moisture regions, then smaller breakup within them.
@export_range(0.005, 0.2, 0.005) var field_noise_frequency: float = 0.055
@export_range(0.02, 1.0, 0.01) var detail_noise_frequency: float = 0.19
@export_range(0.0, 0.5, 0.01) var detail_influence: float = 0.22
## Below this combined noise value the lawn stays open. This single number is the shape OUTLINE --
## the contour where grass starts -- and nothing below moves it.
@export_range(0.0, 1.0, 0.01) var coverage_threshold: float = 0.49
## How far in from that outline the grass takes to reach full density, IN METRES.
##
## Metres, and that is the entire point. The obvious way to feather an edge is a second noise
## threshold and a smoothstep between the two, which is what this used to do -- but a fixed band of
## noise VALUE is a wildly variable distance on the ground. Measured over this arena (tools/
## grass_probe.gd) the old 0.49-0.66 band spanned 2.4 m where the field is steep and 11 m where it
## is flat, median 4.35 m. Grass shapes here are rarely more than ten metres across, so a taper
## that wide left them with no interior at all: 36% of the grassed ground sat below density 0.1 and
## only 14% ever reached full. Dividing by the local slope converts value into distance, so a shape
## is solid everywhere except a rim of exactly this width.
@export_range(0.1, 3.0, 0.05) var edge_feather: float = 0.6
## The same taper for CONCEALMENT, kept separate and wider on purpose.
##
## The blades want a tight rim so the patch reads as solid cover; hiding does not want the same
## number, or cover would switch on over 0.6 m -- about a seventh of a second at sprint -- and a
## mechanic you cross faster than you can react to is a coin flip rather than a decision. Wider
## here means the edge of a patch is partial cover you can feel yourself entering.
@export_range(0.1, 4.0, 0.05) var cover_feather: float = 1.4
## Coarse sampling used only to paint the minimap. It reads the same continuous mask as the blades.
@export_range(0.5, 3.0, 0.1) var minimap_sample_spacing: float = 1.4
## Whether grass is drawn into the sun's shadow map as well as the frame.
##
## OFF, which is the largest single saving available here and the one worth re-examining by eye
## first. Every blade that casts runs its vertex shader again per shadow cascade, and the cascades
## are fitted to the camera's range rather than to what is on screen, so grass can cost several
## times more in the shadow pass than in the visible one. What it buys back at this scale is close
## to nothing: blades are half a metre tall under a pixelation pass whose fat pixels are wider than
## the shadows they would cast. Left as a switch, not a deletion, because that is a look call.
@export var cast_shadows: bool = false

@export_group("Blade")
## Taller than the mouse, or it conceals nothing -- the capsule is about 0.4 and grass that
## comes up to its shoulder just makes it easier to spot.
@export var blade_height: Vector2 = Vector2(0.44, 0.68)
## A broad base that survives the pixel pass. At 0.05 a blade landed on one or two fat pixels and
## flickered in and out as the camera moved; tapering from 0.12 gives the patch weight at ground
## level while the shader keeps the tips narrow.
@export var blade_width: float = 0.12
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
var _field_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
## Live actors and fading marks, packed together for one upload per frame.
var _actors: PackedVector4Array = PackedVector4Array()
## {at: Vector3, strength: float, age: float}, oldest first.
var _trail: Array[Dictionary] = []
## Actor instance id -> where it last left a mark.
var _last_drop: Dictionary = {}
## Cached coarse paint for the minimap. The world and gameplay evaluate the continuous field.
var _minimap_shapes: Array[Dictionary] = []
var _blade_count: int = 0


## The material every render chunk shares, so the look panel can drive its uniforms live. Handing out
## the material rather than proxying each uniform through this script keeps the tuning surface
## in one place -- the shader's own declarations.
func get_material() -> ShaderMaterial:
	return _material


## How much cover a world position has, 0 in painted-open ground and 1 at a noise peak.
##
## Cheap enough to call every frame per actor: two noise samples and no physics query. The cover
## edge is therefore exactly the organic edge players see, with no invisible circular footprint.
func concealment_at(at: Vector3) -> float:
	var local: Vector3 = to_local(at)
	var spot := Vector2(local.x, local.z)
	if not _grass_allowed(spot):
		return 0.0
	return smoothstep(0.0, cover_feather, _edge_distance(spot))


## Blade density at a world position: 0 on open ground, on paving, in a nest or off the map, and
## 1 inside a grass shape past its rim. The painter's own answer to "should anything grow here".
##
## Public as the counterpart to `concealment_at`, which answers the gameplay question through the
## same mask but its own wider ramp. tools/grass_paving_probe.gd integrates this to check that what
## was actually PLANTED matches what the mask says -- the one test that catches the mask being
## right by the time anyone asks it and wrong at the moment it was used.
func density_at(at: Vector3) -> float:
	var local: Vector3 = to_local(at)
	var spot := Vector2(local.x, local.z)
	if not _grass_allowed(spot):
		return 0.0
	return _grass_density(spot)


## How many blades this patch actually planted.
func blade_count() -> int:
	return _blade_count


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = load("res://art/shaders/grass_interact.gdshader")

	var rng := RandomNumberGenerator.new()
	rng.seed = grass_seed
	var mesh := _blade_mesh(blade_segments)
	_field_noise = _make_noise(grass_seed, field_noise_frequency, 4)
	_detail_noise = _make_noise(grass_seed + 7919, detail_noise_frequency, 3)

	var started := Time.get_ticks_msec()
	var counts: Vector3i = _paint_noise_field(mesh, rng)
	_blade_count = counts.x
	_paint_minimap()

	_actors.resize(MAX_INFLUENCES)
	print("grass: %d noise-painted blades in %d render chunks (%d past the %.2f m rim) in %d ms" % [
		counts.x, counts.y, counts.z, edge_feather, Time.get_ticks_msec() - started
	])


## A coarse sampling of the same paint mask, cached because the minimap asks every frame.
func minimap_shapes() -> Array[Dictionary]:
	return _minimap_shapes


func _make_noise(noise_seed: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_gain = 0.52
	noise.fractal_lacunarity = 2.0
	return noise


func _noise_01(noise: FastNoiseLite, at: Vector2) -> float:
	return clampf(noise.get_noise_2d(at.x, at.y) * 0.5 + 0.5, 0.0, 1.0)


## The raw painted height field. Low-frequency Perlin establishes broad islands; detail perturbs
## their edges and cuts holes through them. Thresholded at `coverage_threshold` this is the shape.
func _painted(at: Vector2) -> float:
	if _field_noise == null or _detail_noise == null:
		return 0.0
	var broad := _noise_01(_field_noise, at)
	var detail := _noise_01(_detail_noise, at) - 0.5
	return broad + detail * detail_influence


## Roughly how many metres `at` lies inside its grass shape. Negative outside.
##
## The field's value tells you which side of the outline you are on but not how far, because how
## fast the value climbs varies by more than an order of magnitude across the map. Its GRADIENT is
## the missing conversion factor: value-above-threshold divided by metres-per-unit-of-value is
## metres. That is the standard first-order distance estimate for an implicit surface, and it is
## only accurate near the contour -- which is the only place the answer is used, since both callers
## saturate their smoothstep a metre or two in.
##
## Costs four extra field samples, so it is deliberately not paid where the value alone already
## settles the question. Outside the shape there is nothing to measure; the sign is the answer.
func _edge_distance(at: Vector2) -> float:
	var above := _painted(at) - coverage_threshold
	if above <= 0.0:
		return -1.0
	var gx := (_painted(at + Vector2(GRADIENT_STEP, 0.0))
		- _painted(at - Vector2(GRADIENT_STEP, 0.0))) / (2.0 * GRADIENT_STEP)
	var gz := (_painted(at + Vector2(0.0, GRADIENT_STEP))
		- _painted(at - Vector2(0.0, GRADIENT_STEP))) / (2.0 * GRADIENT_STEP)
	var slope := sqrt(gx * gx + gz * gz)
	# A dead-flat plateau is arbitrarily deep inside, not arbitrarily close to an edge. It has to
	# clear the WIDER of the two ramps: returning just `edge_feather` would fill the blades in and
	# still leave concealment short of 1, so the densest grass on the map would not fully hide you.
	if slope < 0.0001:
		return maxf(edge_feather, cover_feather)
	return above / slope


## How thickly blades grow at a spot: 0 outside a shape, 1 anywhere past the rim.
func _grass_density(at: Vector2) -> float:
	if _field_noise == null or _detail_noise == null:
		return 0.0
	return smoothstep(0.0, edge_feather, _edge_distance(at))


func _grass_allowed(spot: Vector2) -> bool:
	if absf(spot.x) > half_extent or absf(spot.y) > half_extent:
		return false
	if spot.length() < clear_radius:
		return false
	var world: Vector3 = to_global(Vector3(spot.x, 0.0, spot.y))
	var world_spot := Vector2(world.x, world.z)
	if Nest.blocks(get_tree(), world_spot):
		return false
	# NOTHING GROWS THROUGH PAVING. Asked with half a blade's width of margin, because the answer
	# that matters is whether any part of the blade sits on the slab, not whether its centre does
	# -- a root a centimetre off the edge still puts half its base on the concrete.
	return not NoSurfaceZone.seals(get_tree(), world_spot, blade_width * 0.5)


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
func _blade_mesh(segments: int) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(blade_width, 1.0)
	mesh.center_offset = Vector3(0.0, 0.5, 0.0)
	mesh.subdivide_depth = maxi(segments, 1)
	return mesh


## Paint every chunk from the same world-scale mask. Chunks neither choose centres nor own a
## footprint; changing `render_chunk_size` produces the identical field, apart from harmless jitter.
func _paint_noise_field(mesh: Mesh, rng: RandomNumberGenerator) -> Vector3i:
	var total := 0
	var chunks_used := 0
	var dense := 0
	var diameter := half_extent * 2.0
	var chunk_count := ceili(diameter / maxf(render_chunk_size, 0.1))
	for z in range(chunk_count):
		for x in range(chunk_count):
			var result: Vector2i = _paint_chunk(Vector2i(x, z), mesh, rng)
			total += result.x
			dense += result.y
			if result.x > 0:
				chunks_used += 1
	return Vector3i(total, chunks_used, dense)


func _paint_chunk(key: Vector2i, mesh: Mesh, rng: RandomNumberGenerator) -> Vector2i:
	var start := Vector2(
		-half_extent + float(key.x) * render_chunk_size,
		-half_extent + float(key.y) * render_chunk_size
	)
	var finish := Vector2(
		minf(start.x + render_chunk_size, half_extent),
		minf(start.y + render_chunk_size, half_extent)
	)
	var columns := maxi(1, ceili((finish.x - start.x) / maxf(sample_spacing, 0.01)))
	var rows := maxi(1, ceili((finish.y - start.y) / maxf(sample_spacing, 0.01)))
	var cell := Vector2((finish.x - start.x) / float(columns), (finish.y - start.y) / float(rows))
	var transforms: Array[Transform3D] = []
	var colours: Array[Color] = []
	var dense_count := 0

	for row in range(rows):
		for column in range(columns):
			var spot := start + Vector2(
				(float(column) + 0.5) * cell.x + rng.randf_range(-cell.x * 0.42, cell.x * 0.42),
				(float(row) + 0.5) * cell.y + rng.randf_range(-cell.y * 0.42, cell.y * 0.42)
			)
			# Mask first, density second. The mask is two cheap group scans; the density now costs
			# five noise samples where it has to measure a gradient, so it is the one worth not
			# paying for ground that was never going to grow anything.
			if not _grass_allowed(spot):
				continue
			var density := _grass_density(spot)
			if rng.randf() > density:
				continue

			var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU))
			var height := rng.randf_range(blade_height.x, blade_height.y) * lerpf(0.88, 1.06, density)
			basis = basis.scaled(Vector3(1.0, height, 1.0))
			basis = basis.rotated(Vector3.RIGHT, rng.randf_range(-0.14, 0.14))
			transforms.append(Transform3D(basis, Vector3(spot.x, 0.0, spot.y)))

			var shade := rng.randf_range(0.78, 1.12)
			colours.append(Color(shade, shade * rng.randf_range(0.96, 1.04), shade))
			if density >= 0.82:
				dense_count += 1

	if transforms.is_empty():
		return Vector2i.ZERO

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in range(transforms.size()):
		multimesh.set_instance_transform(i, transforms[i])
		multimesh.set_instance_color(i, colours[i])

	var instance := MultiMeshInstance3D.new()
	instance.name = "NoiseChunk%d_%d" % [key.x, key.y]
	instance.multimesh = multimesh
	instance.material_override = _material
	# The shader bends tips outside untouched mesh bounds, so a chunk clipped at the screen edge
	# would otherwise pop as its untouched bounds leave.
	instance.extra_cull_margin = CULL_MARGIN
	if not cast_shadows:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return Vector2i(transforms.size(), dense_count)


func _paint_minimap() -> void:
	_minimap_shapes.clear()
	var spacing := maxf(minimap_sample_spacing, 0.1)
	var samples := ceili((half_extent * 2.0) / spacing)
	var cell_half := spacing * 0.54
	for z in range(samples):
		for x in range(samples):
			var spot := Vector2(
				-half_extent + (float(x) + 0.5) * spacing,
				-half_extent + (float(z) + 0.5) * spacing
			)
			# CONCEALMENT, not blade count. The minimap is a cover map -- what it owes the player
			# is the same answer concealment_at gives them, so the two cannot disagree about where
			# a patch begins. With the rim now only `edge_feather` wide, blade density would paint
			# it as a hard-edged solid, which is exactly the lie the wider cover taper avoids.
			var density := smoothstep(0.0, cover_feather, _edge_distance(spot))
			if density < 0.10:
				continue
			if not _grass_allowed(spot):
				continue
			var points := PackedVector2Array()
			for corner: Vector2 in [
				spot + Vector2(-cell_half, -cell_half),
				spot + Vector2(cell_half, -cell_half),
				spot + Vector2(cell_half, cell_half),
				spot + Vector2(-cell_half, cell_half),
			]:
				var world: Vector3 = to_global(Vector3(corner.x, 0.0, corner.y))
				points.append(Vector2(world.x, world.z))
			_minimap_shapes.append({
				"kind": &"polygon",
				"style": &"grass",
				"points": points,
				"strength": lerpf(0.28, 1.0, density),
				"outline": false,
			})
