class_name CeilingDust
extends Node3D
## Earth trickling out of a ceiling you cannot see, over one open tunnel cell, because something
## came down nearby.
##
## THE OTHER HALF OF A COLLAPSE, and the half nobody was being told about. Standing in a corridor
## when a Brute brings a cell down two tiles away was, until this, completely silent: either you
## were in the cell and you were buried, or you were not and absolutely nothing happened. The most
## dangerous thing in the game underground gave no warning at all to the people it was about to be
## dangerous to.
##
## SO IT IS A TELL, NOT AN EFFECT. What this says is *something just came in near here* -- and the
## radius it covers is deliberately wider than the collapse itself ([CaveIn]), so the dust reaches
## mice who were **not** caught. Being rattled and dusted is the near miss; it is the thing you get
## to react to, and reacting to it is a mouse deciding to be somewhere else.
##
## IT DOES NOT SAY WHERE, AND THAT IS THE RESTRAINT. Motes fall over the cell they are drawn in,
## not toward the collapse -- no direction, no distance, nothing to triangulate from. You learn
## that the earth moved nearby, which is what someone standing in a corridor would actually know,
## and you go and look if you want more than that.
##
## DRAWN ONLY OVER CELLS THE VIEWER'S CREW MAY KNOW ABOUT, which the caller enforces. That rule
## matters more here than anywhere else in the effects: dust falling over an enemy corridor would
## draw its floor plan into the air for anyone standing in earshot of a collapse, which is M5's
## pillar leaking through a particle. See [method CaveIn._shake_the_earth].
##
## NO PHYSICS AND NO PARTICLE SYSTEM, and the same generated falloff texture the stomp's dust uses
## -- it is the same earth, and two dusts that drifted apart in look would be two answers to what
## one material does.

## Motes per cell. Few: this is a dozen cells at once in a busy moment, and the readable signal is
## *many cells trickling* rather than any one cell producing a shower.
@export var motes: int = 4
## How far above the floor they start, as a fraction of the plane spacing. Near the top, because
## the ceiling is what is shedding -- starting them halfway down reads as dust appearing in mid-air.
@export_range(0.1, 1.0, 0.05) var from_height: float = 0.82
@export var fall_speed: Vector2 = Vector2(0.9, 1.6)
@export var mote_size: Vector2 = Vector2(0.05, 0.11)
@export var seconds: Vector2 = Vector2(0.5, 0.95)
## Same earth as the stomp throws up, but COOLER AND THINNER, and both are corrections made from a
## screenshot. A corridor is lit by lamplight and the walls are warm orange; dust in the stomp's
## own sandy hue landed within a few percent of the background and read as *brightness* rather than
## as falling material -- patches of glow rather than grit. Pulled toward grey and down to a third
## of the surface dust's opacity, it reads as what it is: earth coming loose in a lit tunnel.
@export var dust_color: Color = Color(0.63, 0.60, 0.55, 0.30)

var _motes: Array[Dictionary] = []
var _age: float = 0.0
var _longest: float = 0.0


## Trickle dust into one cell. `at` is the floor of the cell; `height` is the plane spacing, which
## is how tall the invisible ceiling is.
static func fall(parent: Node, at: Vector3, height: float, seed_value: int) -> CeilingDust:
	if parent == null:
		return null
	var dust := CeilingDust.new()
	dust.name = "CeilingDust"
	parent.add_child(dust)
	dust.global_position = at
	dust._build(height, seed_value)
	return dust


func _build(height: float, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var half := TunnelNetwork.CELL * 0.34

	for index in range(maxi(motes, 0)):
		var material := StandardMaterial3D.new()
		material.albedo_color = dust_color
		material.albedo_texture = StompDust.puff_texture()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

		var piece := MeshInstance3D.new()
		piece.mesh = quad
		piece.material_override = material
		piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Scattered across the cell rather than centred, so a corridor of these reads as earth
		# shedding along its whole length instead of as one dot per tile.
		piece.position = Vector3(
			rng.randf_range(-half, half),
			height * from_height,
			rng.randf_range(-half, half)
		)
		var size := rng.randf_range(mote_size.x, mote_size.y)
		piece.scale = Vector3(size, size, size)
		add_child(piece)

		_motes.append({
			"node": piece,
			"material": material,
			"fall": rng.randf_range(fall_speed.x, fall_speed.y),
			"life": rng.randf_range(seconds.x, seconds.y),
			# Staggered starts, so the cell trickles for its whole life rather than dropping
			# everything it has on one frame. This is the difference between dust and a dropped
			# bucket, and it costs one float.
			"wait": rng.randf_range(0.0, 0.35),
			"age": 0.0,
		})
		_longest = maxf(_longest, float(_motes[-1]["life"]) + float(_motes[-1]["wait"]))

	if _motes.is_empty():
		queue_free()


func _process(delta: float) -> void:
	_age += delta
	for mote: Dictionary in _motes:
		var node: MeshInstance3D = mote["node"]
		if not is_instance_valid(node):
			continue
		if float(mote["wait"]) > 0.0:
			mote["wait"] = float(mote["wait"]) - delta
			# Held invisible rather than merely still, or the cell shows its full complement of
			# motes hanging at the ceiling before any of them has started to move.
			node.visible = false
			continue
		node.visible = true
		mote["age"] = float(mote["age"]) + delta
		var through := clampf(float(mote["age"]) / maxf(float(mote["life"]), 0.01), 0.0, 1.0)
		# Accelerating, because it is falling. Constant-speed dust reads as being lowered.
		node.position.y -= float(mote["fall"]) * delta * (0.4 + through)
		var material: StandardMaterial3D = mote["material"]
		material.albedo_color.a = dust_color.a * (1.0 - smoothstep(0.4, 1.0, through))

	if _age >= _longest + 0.1:
		queue_free()
