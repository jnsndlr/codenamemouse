class_name StompDust
extends Node3D
## The lawn answering a Brute's boot: a ring of dust thrown outward, and a shock ring that runs
## out along the ground and dies.
##
## WHY THE STOMP NEEDED THIS MORE THAN ANY OTHER ABILITY. Every other thing a mouse does leaves
## its own evidence -- a cell disappears, a boulder appears, cant is scratched into the floor. A
## stomp's whole result is *underground*, on a layer the person pressing the key cannot see, and
## about a third of the time (see [CaveIn]) there is no result at all. Without something on the
## surface, the most physical action in the game is a keypress that plays nothing. The dust is
## what makes it an action rather than a query.
##
## AND IT MUST NOT SAY WHETHER IT WORKED. This is the constraint that shapes the whole file: the
## dust is IDENTICAL over a tunnel and over bare earth. A bigger cloud when something gave way
## would rebuild, in particles, exactly the free sonar sweep [CaveIn] refuses to be -- a Brute
## could pace the lawn reading the enemy's network off the size of its own dust. So this takes the
## stomp's position and nothing else. It is not told what was found and has no way to ask.
##
## NO PHYSICS BODIES AND NO GPUParticles, for the same reasons [RockDebris] gives. A dozen puffs
## integrated by hand for eight tenths of a second is less machinery than a particle system whose
## every property would have to be authored in a scene this project builds in code -- and the
## motion wanted here is a specific one (out fast, up slowly, expand, fade) rather than anything a
## generic emitter does better.
##
## SEEDED FROM THE CELL, so the same stomp looks the same on the host and on the client. Nothing
## depends on that -- it is decoration and the two ends never compare it -- but "identical input,
## identical picture" costs one integer here and is the sort of thing that is impossible to add
## back once a screenshot from two machines has to be explained.

## How many puffs go up. Enough to read as a ring rather than as a handful of squares.
@export var puffs: int = 10
## Outward speed, in metres per second. Fast at the start, and heavily damped below -- dust leaves
## quickly and then hangs, which is most of what makes it read as dust rather than as debris.
@export var burst_speed: Vector2 = Vector2(1.4, 2.6)
## The upward drift on top of that. Small: this is a foot hitting the ground, not an explosion.
@export var lift_speed: Vector2 = Vector2(0.35, 0.8)
## How much speed survives each second. Low, so the ring is thrown and then stalls.
@export_range(0.0, 1.0, 0.01) var drag: float = 0.06
## Metres across at birth and at death. Growing is what sells it as a cloud rather than a pellet.
##
## SMALL, AND THE FIRST VERSION WAS NOT. At 0.12->0.42 with fourteen puffs at 0.85 alpha, the ring
## closed into a single beige disc wider than the mouse and hid it completely -- the screenshot
## probe is the only reason that was caught, because in prose "a ring of dust puffs" describes both
## the intended effect and the blob exactly as well. A mouse is 0.4 metres tall; anything here that
## approaches that number is not dust, it is weather.
@export var puff_size: Vector2 = Vector2(0.07, 0.20)
@export var puff_seconds: Vector2 = Vector2(0.45, 0.7)
## The flat ring that runs out along the ground. Read separately from the puffs because it is
## doing a different job: the puffs are the impact, this is the reach.
@export var ring_radius: float = 1.05
@export var ring_seconds: float = 0.42
## Dry pale earth, a little lighter than the lawn it comes off so it reads against it. Thin enough
## to see the mouse through: the Brute is what you are watching, and the dust is what it did.
@export var dust_color: Color = Color(0.78, 0.71, 0.56, 0.40)

## The soft round falloff every puff is drawn with, generated once for the whole process.
##
## PROCEDURAL, AND NOT OPTIONAL. A quad with a flat colour is a SQUARE -- at this zoom ten of them
## overlapping read as a stack of beige tiles, which is exactly what the first screenshot showed.
## The shape of a dust puff is entirely in its edge, so the edge has to exist. Thirty-two pixels
## square is plenty for something 20cm across on screen, and it costs one image at startup rather
## than an imported asset this project would otherwise have to keep in `art/`.
##
## SQUARED FALLOFF, so the puff is dense in the middle and goes to nothing well before the quad's
## edge -- a linear ramp leaves a visible circular rim, which is a different artefact and no less
## obviously a shape.
## Shared with [CeilingDust], which is the same material of dust seen from underneath. One
## generated image for the process, and the two effects cannot drift apart into two dusts.
static var _falloff: ImageTexture


static func puff_texture() -> ImageTexture:
	return _puff_texture()


static func _puff_texture() -> ImageTexture:
	if _falloff != null:
		return _falloff
	var size := 32
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var middle := (float(size) - 1.0) * 0.5
	for x in range(size):
		for y in range(size):
			var away := Vector2(float(x) - middle, float(y) - middle).length() / middle
			var alpha := clampf(1.0 - away, 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha * alpha))
	_falloff = ImageTexture.create_from_image(image)
	return _falloff


## How much wider than this class's own default the caller asked for, from `reach`. Everything a
## puff does in METRES scales with it; nothing it does in seconds or in alpha does.
var _spread: float = 1.0
var _puffs: Array[Dictionary] = []
var _ring: MeshInstance3D
var _ring_material: StandardMaterial3D
var _ring_age: float = 0.0
var _age: float = 0.0
var _longest: float = 0.0


## Throw dust at `at`. `seed_value` should be derived from the stomped cell so both machines
## produce the same cloud.
##
## `reach` is how far the shock ring runs, in metres, or 0 for this class's own default.
##
## A REACH RATHER THAN A SCALE FACTOR, because both callers know a distance and neither knows a
## multiplier. [Slam] draws its ring at exactly the radius it shoves through, which is what makes
## the dust teach the ability's range instead of merely decorating it -- and a caller that had to
## work out `1.6 / 1.05` to say so would be one refactor of the default away from lying about it.
## The puffs are carried outward in proportion, so a wider ring is not a narrow burst with a big
## circle drawn round it. Their SIZE is untouched on purpose: grain of dust is grain of dust, and
## this file's own hard-won note about clouds that swallow the mouse applies at every reach.
static func burst(
	parent: Node, at: Vector3, seed_value: int, reach: float = 0.0
) -> StompDust:
	if parent == null:
		return null
	var dust := StompDust.new()
	dust.name = "StompDust"
	if reach > 0.0:
		dust._spread = reach / maxf(dust.ring_radius, 0.01)
		dust.ring_radius = reach
		dust.burst_speed *= dust._spread
	parent.add_child(dust)
	# Positioned after entering the tree, so `at` is honoured as the world point it is whatever
	# transform the parent carries -- the same reason [RockDebris.burst] does it in this order.
	dust.global_position = at
	dust._build(seed_value)
	return dust


func _build(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	# A quad per puff, billboarded. One mesh shared between them -- the size is carried on the
	# instance's scale, so a dozen copies of a two-triangle mesh would be a dozen copies of
	# nothing. The MATERIAL is per puff, because each fades on its own clock and alpha lives on
	# the material; a shared one would fade the whole cloud in lockstep, which reads as a single
	# object disappearing rather than as dust dispersing.
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE

	for index in range(maxi(puffs, 0)):
		# Spread around the ring rather than picked at random, then jittered. Pure random angles
		# clump, and a clumped ring reads as three lumps instead of a circle -- the same reason
		# the boulder scatter walks its shards round the shell.
		var angle := TAU * float(index) / float(maxi(puffs, 1)) + rng.randf_range(-0.22, 0.22)
		var out := Vector3(cos(angle), 0.0, sin(angle))
		var speed := rng.randf_range(burst_speed.x, burst_speed.y)
		var life := rng.randf_range(puff_seconds.x, puff_seconds.y)

		var material := StandardMaterial3D.new()
		material.albedo_color = dust_color
		material.albedo_texture = _puff_texture()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Off the depth buffer, because a dozen overlapping transparent quads sorted against one
		# another is a flickering mess -- and dust has no business occluding anything anyway.
		material.no_depth_test = false
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

		var piece := MeshInstance3D.new()
		piece.mesh = quad
		piece.material_override = material
		piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# BORN ALREADY OUT ON THE RING rather than at the Brute's feet. Starting them all at the
		# centre means the first tenth of a second is every puff stacked in one place, which is the
		# densest and most opaque moment of the effect and lands squarely over the mouse -- the
		# thing you are actually meant to be looking at.
		#
		# AND THE RING WIDENS WITH `reach`, which the first version of that argument missed. Held
		# at a fixed 0.22-0.44 while [Slam] drew its shock out to 1.6m, ten puffs still opened
		# inside half a metre and rebuilt the exact beige disc this note was written about -- plain
		# in `slam_03.png` and invisible to every audit in the project. A birth radius is a
		# distance, so it scales with the other distances here.
		piece.position = out * rng.randf_range(0.22, 0.44) * _spread + Vector3.UP * 0.06
		add_child(piece)

		_puffs.append({
			"node": piece,
			"material": material,
			"velocity": out * speed + Vector3.UP * rng.randf_range(lift_speed.x, lift_speed.y),
			"life": life,
			"age": 0.0,
			"spin": rng.randf_range(-2.4, 2.4),
		})
		_longest = maxf(_longest, life)

	_build_ring()
	_longest = maxf(_longest, ring_seconds)
	if _puffs.is_empty() and _ring == null:
		queue_free()


## The flat shock ring: a unit annulus on the ground, scaled outward as it goes.
##
## BUILT AT UNIT RADIUS AND SCALED, rather than rebuilt each frame at the radius it has reached.
## Regenerating a mesh every frame for four tenths of a second is a lot of allocation for a
## circle, and scaling a flat ring is exactly equivalent.
func _build_ring() -> void:
	var segments := 40
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Thin, and thinner on the inside edge, so the ring reads as a leading edge running outward
	# rather than as a disc that happens to have a hole in it.
	var inner := 0.82
	for index in range(segments):
		var a := TAU * float(index) / float(segments)
		var b := TAU * float(index + 1) / float(segments)
		var points: Array[Vector3] = [
			Vector3(cos(a) * inner, 0.0, sin(a) * inner),
			Vector3(cos(a), 0.0, sin(a)),
			Vector3(cos(b), 0.0, sin(b)),
			Vector3(cos(b) * inner, 0.0, sin(b) * inner),
		]
		for corner: int in [0, 1, 2, 0, 2, 3]:
			tool.set_normal(Vector3.UP)
			tool.add_vertex(points[corner])

	_ring_material = StandardMaterial3D.new()
	_ring_material.albedo_color = dust_color
	_ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	_ring = MeshInstance3D.new()
	_ring.mesh = tool.commit()
	_ring.material_override = _ring_material
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Just proud of the lawn, the same clearance the nest pads and the cant marks use. Flush
	# z-fights across the whole ring.
	_ring.position = Vector3.UP * 0.03
	_ring.scale = Vector3(0.05, 1.0, 0.05)
	add_child(_ring)


func _process(delta: float) -> void:
	_age += delta
	_step_puffs(delta)
	_step_ring(delta)
	# Freed by the clock rather than by counting live pieces, so a cloud whose last puff was
	# somehow removed by something else still goes away.
	if _age >= _longest + 0.1:
		queue_free()


func _step_puffs(delta: float) -> void:
	for puff: Dictionary in _puffs:
		var node: MeshInstance3D = puff["node"]
		if not is_instance_valid(node):
			continue
		puff["age"] = float(puff["age"]) + delta
		var life := float(puff["life"])
		var through := clampf(float(puff["age"]) / maxf(life, 0.01), 0.0, 1.0)

		# Exponential damping rather than a subtraction, so the puff never reverses when the
		# frame is long -- the trap a linear drag term sets for anything integrated by hand.
		var velocity: Vector3 = puff["velocity"] * pow(drag, delta)
		puff["velocity"] = velocity
		node.position += velocity * delta

		# Grows the whole way, fades on the back half. Fading from the start makes the cloud
		# look like it is being deleted; holding it and then letting go looks like it disperses.
		var size := lerpf(puff_size.x, puff_size.y, through)
		node.scale = Vector3(size, size, size)
		node.rotate_y(float(puff["spin"]) * delta)
		var material: StandardMaterial3D = puff["material"]
		material.albedo_color.a = dust_color.a * (1.0 - smoothstep(0.45, 1.0, through))


func _step_ring(delta: float) -> void:
	if not is_instance_valid(_ring):
		return
	_ring_age += delta
	var through := clampf(_ring_age / maxf(ring_seconds, 0.01), 0.0, 1.0)
	# Eased out, so the ring leaves fast and slows -- a shock front, not a balloon.
	var eased := 1.0 - pow(1.0 - through, 2.4)
	var radius := maxf(ring_radius, 0.01) * eased
	_ring.scale = Vector3(radius, 1.0, radius)
	_ring_material.albedo_color.a = dust_color.a * (1.0 - through)
	if through >= 1.0:
		_ring.queue_free()
		_ring = null
