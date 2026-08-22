class_name DigDust
extends Node3D
## Earth coming loose under a mouse's paws: a steady trickle of small puffs off the face being
## dug, and a kick of them when a stroke actually lands.
##
## WHY DIGGING NEEDED DUST AT ALL. The recharge model (see [DigController]) made the stroke
## instant and the wait invisible -- which fixed the button and quietly removed the picture. A
## held dig is a metre of corridor appearing, twice a second, and nothing at all in between;
## "standing next to a wall" and "eating through a wall" look identical. The trickle is what fills
## that gap: it runs the whole time the button is down on a real target, so the WORK is visible
## even in the instants when no earth is moving.
##
## AND IT IS NOW THE WHOLE PICTURE, not the decoration on top of one. There used to be a hover box
## drawn on the stroke under the cursor; it was removed because it drew itself over every piece of
## ground the cursor merely crossed, whether or not anybody was digging. This and the scrabble the
## body wears (see [method Mouse._process]) are all that says a dig is happening, which is worth
## knowing before tuning any number here down to nothing.
##
## ONE EMITTER PER DIGGER, REUSED, not a burst object per stroke. [StompDust] frees itself
## because a stomp is an event; digging is a STATE, held for whole seconds, and churning out a
## node tree per puff-cycle would be allocation for its own sake. This node lives under the tunnel
## network for as long as its controller does, and being switched off simply lets its last puffs
## finish.
##
## NO PHYSICS BODIES AND NO GPUParticles, for the reasons [RockDebris] gives and [StompDust]
## repeats: a handful of hand-integrated quads is less machinery than an authored particle
## system in a project that builds its scenes in code, and the motion wanted -- out of the wall,
## up a little, hang, gone -- is specific.
##
## NOT SEEDED, unlike [StompDust], and on purpose. A stomp is one event both machines witness, so
## identical clouds are free to have; this trickle is tied to a held button sampled every few
## frames, and two machines never see those frames alike anyway. Decoration tied to live input
## gets a live RNG.

## Seconds between one trickle puff and the next while active. Fast enough to read as continuous
## effort, slow enough that the face stays visible through it -- this is scratching, not smoke.
@export var emit_seconds: float = 0.16
## How many puffs a landed stroke kicks out at once. The stroke removes a cubic metre in an
## instant; a plain trickle-sized puff on that frame would make the biggest moment the quietest.
@export var burst_puffs: int = 3
## Speed away from the face, in metres per second, for trickle and burst respectively. The burst
## range deliberately overlaps the top of the trickle: a landed stroke is the same dust, thrown
## harder, not a different weather.
@export var trickle_speed: Vector2 = Vector2(0.5, 1.0)
@export var burst_speed: Vector2 = Vector2(1.0, 1.9)
## The upward drift on top of that. Small -- paws throw earth backward, not up.
@export var lift_speed: Vector2 = Vector2(0.25, 0.55)
## How much speed survives each second. Looser than [StompDust]'s 0.06 -- a stomp throws a ring
## across open lawn and wants it to stall where it lands, while these have to get clear of the
## face they came off -- but not by much: earth thrown a metre down the corridor is a mouse
## sneezing, not a mouse digging.
@export_range(0.0, 1.0, 0.01) var drag: float = 0.2
## Metres across at birth and at death, before each puff's own `grain`. SMALL, and the one
## tuning pass that mattered went the other way first: chasing "the dust does not read" through
## size, speed, count and alpha produced a cloud two or three times the mouse -- measurably
## brighter at every step and a smear at every step -- which is [StompDust]'s own hard-won note
## about clouds that swallow the mouse, rebuilt underground in a corridor one metre wide.
##
## The dial that actually fixed it was the SHAPE of a puff rather than the size of one (see
## `_disc`), and once the rim was hard these could go back to being small. A screenshot diff is
## the only reason any of that was visible: in prose, every one of those passes was "a trickle
## of small dust puffs off the face".
@export var puff_size: Vector2 = Vector2(0.035, 0.085)
@export var puff_seconds: Vector2 = Vector2(0.3, 0.5)
## The same dry pale earth as every other dust in the game, and reading [StompDust.dust_color]
## would couple two exports for the sake of one literal. If the earth changes colour, it changes
## colour in the handful of places earth is thrown.
##
## A SHADE LIGHTER AND A SHADE THICKER THAN THE STOMP'S, for a reason that is about where it is
## seen rather than what it is made of. The stomp's dust is pale beige on a green lawn and
## separates from it for free; this is pale beige on a corridor of dug earth in very nearly that
## colour, lit by the same warm lamp. Underground there is no hue contrast to be had, so what
## little there is has to come from value and alpha.
@export var dust_color: Color = Color(0.84, 0.78, 0.65, 0.34)
## Puffs alive at once before the oldest is retired early. A held button plus a fast class plus
## bursts could otherwise pile up quads without bound on a long dig.
@export var most_puffs: int = 8

var _active: bool = false
## Which way loose earth leaves the face, on the XZ plane: BACK toward the digger, because the
## solid ground is on the other side. Unit length, or zero before the first aim arrives.
var _back: Vector2 = Vector2.ZERO
var _since: float = 0.0
var _puffs: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
## The toon puff: a flat disc with a crisp rim, generated once for the whole process.
##
## NOT [StompDust]'S FALLOFF, and this is the one place the two dusts deliberately part company.
## That texture is a squared radial ramp -- alpha `(1-r)^2` -- which has no edge at all by
## construction, and a soft-edged sprite CANNOT read as a grain no matter how it is tuned: eight
## of them overlapping is eight glows adding up to one glow, which is exactly what three tuning
## passes produced (measurably brighter each time, and a smear every time). Size, speed, count
## and alpha were all the wrong dials; the shape was the problem.
##
## A HARD RIM IS ALSO THE ASK. This is the toon dig -- the same register as the squash-and-jab
## the body wears while it cuts -- and cartoon dust is drawn, with a line round it. Overlapping
## discs that keep their edges read as a handful of puffs; overlapping glows read as weather.
static var _disc: ImageTexture
## One two-triangle quad shared by every puff; the size rides on each instance's scale. The
## MATERIAL is per puff because each fades on its own clock -- see [StompDust._build].
var _quad := QuadMesh.new()


func _init() -> void:
	_quad.size = Vector2.ONE


## Solid to about two thirds out, then off over a few pixels: opaque enough to have a shape,
## with just enough ramp that the rim is a circle rather than a staircase at this zoom.
static func _puff_texture() -> ImageTexture:
	if _disc != null:
		return _disc
	var size := 48
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var middle := (float(size) - 1.0) * 0.5
	for x in range(size):
		for y in range(size):
			var away := Vector2(float(x) - middle, float(y) - middle).length() / middle
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, 1.0 - smoothstep(0.66, 0.92, away)))
	_disc = ImageTexture.create_from_image(image)
	return _disc


## Point the emitter at the face being worked: `at` is where the puffs are born, `back` is the
## direction they are thrown (toward the digger, since that is the open side of the wall).
## Called every frame the aim holds -- the face slides as the cursor does.
func aim(at: Vector3, back: Vector2) -> void:
	global_position = at
	if back.length_squared() > 0.0001:
		_back = back.normalized()


## Turn the trickle on or off. Off does not clear the puffs already flying -- earth in the air
## when the button comes up still lands.
func set_active(on: bool) -> void:
	if on and not _active:
		# The first puff goes up on the press, not an `emit_seconds` later: the stroke itself is
		# instant now, and dust that lags the press would re-open the exact "did the button work"
		# gap the recharge model was built to close.
		_since = maxf(emit_seconds, _since)
	_active = on


## A stroke landed: throw a proper kick of earth. The trickle says "working"; this says "worked".
func kick() -> void:
	for _index in range(maxi(burst_puffs, 0)):
		_spawn(burst_speed)


func _process(delta: float) -> void:
	if _active:
		_since += delta
		while _since >= maxf(emit_seconds, 0.01):
			_since -= maxf(emit_seconds, 0.01)
			_spawn(trickle_speed)
	else:
		_since = 0.0
	_step(delta)


func _spawn(speed: Vector2) -> void:
	if _back == Vector2.ZERO:
		return
	# Retire the oldest rather than refuse the newest: the newest puff is the one that carries
	# the current stroke's evidence.
	while _puffs.size() >= maxi(most_puffs, 1):
		var old: Dictionary = _puffs.pop_front()
		var stale: MeshInstance3D = old["node"]
		if is_instance_valid(stale):
			stale.queue_free()

	# Fanned around the back direction rather than straight along it, so a held dig builds a
	# small cone of falling earth instead of a bead chain.
	var spun := _back.rotated(_rng.randf_range(-0.7, 0.7))
	var out := Vector3(spun.x, 0.0, spun.y)

	var material := StandardMaterial3D.new()
	material.albedo_color = dust_color
	material.albedo_texture = _puff_texture()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	var piece := MeshInstance3D.new()
	piece.mesh = _quad
	piece.material_override = material
	piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Born a hand's width off the face with a little scatter, so the cone has a root you can see
	# rather than every puff materialising at one point.
	piece.position = out * _rng.randf_range(0.04, 0.14) + Vector3(
		_rng.randf_range(-0.07, 0.07),
		_rng.randf_range(0.03, 0.18),
		_rng.randf_range(-0.07, 0.07)
	)
	add_child(piece)

	_puffs.append({
		"node": piece,
		"material": material,
		"velocity": out * _rng.randf_range(speed.x, speed.y)
			+ Vector3.UP * _rng.randf_range(lift_speed.x, lift_speed.y),
		"life": _rng.randf_range(puff_seconds.x, puff_seconds.y),
		"age": 0.0,
		# A per-puff size multiplier, so the cone is made of grains of different sizes rather
		# than of one grain repeated. Ten identically-sized quads overlapping is what turned the
		# first tuning pass into a single pale smear across the dig cursor -- variation is most
		# of what makes a cloud read as granular at this zoom.
		"grain": _rng.randf_range(0.65, 1.35),
	})


func _step(delta: float) -> void:
	for index in range(_puffs.size() - 1, -1, -1):
		var puff: Dictionary = _puffs[index]
		var node: MeshInstance3D = puff["node"]
		if not is_instance_valid(node):
			_puffs.remove_at(index)
			continue
		puff["age"] = float(puff["age"]) + delta
		var life := float(puff["life"])
		var through := clampf(float(puff["age"]) / maxf(life, 0.01), 0.0, 1.0)
		if through >= 1.0:
			node.queue_free()
			_puffs.remove_at(index)
			continue

		# Exponential damping, not a subtraction -- the same long-frame trap [StompDust] names.
		var velocity: Vector3 = puff["velocity"] * pow(drag, delta)
		puff["velocity"] = velocity
		node.position += velocity * delta

		# Grows the whole way, fades on the back half: dispersing, not being deleted.
		var size := lerpf(puff_size.x, puff_size.y, through) * float(puff["grain"])
		node.scale = Vector3(size, size, size)
		var material: StandardMaterial3D = puff["material"]
		material.albedo_color.a = dust_color.a * (1.0 - smoothstep(0.45, 1.0, through))
