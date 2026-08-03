class_name SwingArc
extends MeshInstance3D
## The visible swipe: a tapering, fading ribbon swept through the melee cone.
##
## WHY THIS EXISTS. The cone in `Mouse._resolve_swing` is invisible, so a whiff and a hit look
## identical up to the moment health does or doesn't move. That makes spacing -- the one thing a
## scrap is actually about (GDD section 6) -- unlearnable. This draws the cone the resolver
## actually uses: `attack_reach` out, `attack_arc_degrees` across, swept over the windup so the
## ribbon completes at the instant the hit resolves. Stand outside the swoosh and you were never
## going to be hit.
##
## HONEST BY CONSTRUCTION. It reads reach and arc off the mouse at `play()` time rather than
## keeping numbers of its own, so a class swap, a tuning pass, or an exported tweak in the
## inspector moves the drawing with the hitbox. There is no second set of values to forget.
##
## Drawn, not authored. No texture, no particle system, no imported animation -- an ImmediateMesh
## rebuilt per frame while a swing is in the air, which is at most a few dozen triangles for a
## fraction of a second per swing. That also means it needs nothing added to a scene: every mouse
## gets one from `Mouse._ready`, bots included, so a bot's swing telegraphs exactly like a
## player's.

## Samples across the ribbon. Enough that a 110-degree fan reads as a curve rather than a fan of
## flat chords; small enough that the per-frame rebuild is noise.
const SEGMENTS: int = 18
## Height off the mouse's feet. Roughly mid-body on a 0.4-tall capsule, so the swipe reads as a
## paw going through someone rather than a decal on the floor.
const HEIGHT: float = 0.2
## How long the ribbon lingers once the head has reached the far edge of the cone. Short: it is a
## tell for a swing that has already resolved, and a lingering one would misread as a live hitbox.
const FADE_SECONDS: float = 0.11
## Opacity at the leading edge.
const HEAD_ALPHA: float = 0.72
## The tail never fades to nothing while the swing is in the air. Without this floor the far half
## of the cone is invisible at the moment the hit lands, which is exactly when the player is
## trying to read whether their spacing was right.
const TAIL_ALPHA: float = 0.16
## How much of the ribbon's brightness the INNER edge keeps, at the head and at the tail. The
## head is nearly solid -- that is the paw, a line as long as the reach. Behind it the fill drops
## away and what is left is the rim at `attack_reach`, which is the answer to the only question
## the player is asking: stand further out than that and you whiffed.
const INNER_ALPHA_HEAD: float = 0.55
const INNER_ALPHA_TAIL: float = 0.18

## The mouse this belongs to. Read every frame for facing, because you can keep turning mid-swing
## and the resolver uses the facing at the instant it fires -- a ribbon frozen to the facing at
## the start of the swing would lie about where the cone ended up.
var _mouse: Mouse
var _mesh: ImmediateMesh
var _material: StandardMaterial3D
var _age: float = 0.0
var _sweep: float = 0.4
var _reach: float = 0.95
var _half_arc: float = 0.9
var _colour: Color = Color.WHITE


func _init() -> void:
	_mesh = ImmediateMesh.new()
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	position.y = HEIGHT
	visible = false
	set_process(false)

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Ordinary alpha, NOT additive. Additive was the first try and it turned to grey mush: a pale
	# blue added to a pale green floor desaturates instead of brightening, and the swipe lost both
	# its edge and whose it was. Mixing keeps the hue. Depth WRITE off for the same reason a decal
	# doesn't want one; depth TEST stays on, so a swing taken underground is still hidden by the
	# ground above it.
	_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED


## Wire it to its mouse. Separate from `_init` because the node is built before it is parented.
func arm(mouse: Mouse) -> void:
	_mouse = mouse


## Start a swipe. Call it at the moment the swing starts, not when it resolves.
##
## `sweep_seconds` is the windup, so the head of the ribbon arrives at the far edge of the cone
## on the frame the damage lands. The recovery that follows is deliberately NOT drawn -- the
## punishable half of a whiffed swing should look like a mouse standing there with nothing in
## front of it.
func play(sweep_seconds: float) -> void:
	if _mouse == null:
		return
	_reach = _mouse.attack_reach
	_half_arc = deg_to_rad(_mouse.attack_arc_degrees) * 0.5
	# Toward white so it stays legible against its own team's colour on the ground, but not all
	# the way -- whose swing it was still matters in a four-mouse pile.
	_colour = _mouse.team_color.lerp(Color.WHITE, 0.55)
	_sweep = maxf(sweep_seconds, 0.01)
	_age = 0.0
	visible = true
	set_process(true)
	_draw_ribbon()


func stop() -> void:
	visible = false
	set_process(false)
	_mesh.clear_surfaces()


func _process(delta: float) -> void:
	if _mouse == null or _mouse.is_scruffed():
		stop()
		return
	_age += delta
	if _age >= _sweep + FADE_SECONDS:
		stop()
		return
	_draw_ribbon()


## One triangle strip from the leading edge back to where the swing started.
##
## The tail is PINNED to the starting edge rather than trailing the head by a fixed time. A
## trail that runs off the back would show a moving slice of the cone; this shows the whole cone
## from the moment the sweep completes, which is the frame the player needs to read.
func _draw_ribbon() -> void:
	var facing := _mouse.get_facing_direction()
	rotation.y = atan2(-facing.x, -facing.z)

	# Right to left, the way a paw goes. `head` is where the leading edge has got to; the sweep
	# finishes at the far edge and then the whole ribbon fades in place.
	var swept := clampf(_age / _sweep, 0.0, 1.0)
	var head := -_half_arc + _half_arc * 2.0 * swept
	var fade := 1.0 - clampf((_age - _sweep) / FADE_SECONDS, 0.0, 1.0)

	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _material)
	for index in SEGMENTS + 1:
		var along := float(index) / float(SEGMENTS)
		var angle := lerpf(head, -_half_arc, along)
		# Taper: the head is a near-full radial line, which is what puts the reach on screen. By
		# the tail it has narrowed to a thin band riding the outer edge -- the shape a swipe
		# leaves, and it keeps the outer radius (the part that decides a hit) visible throughout.
		var outer := _reach * lerpf(1.0, 0.94, along)
		var inner := _reach * lerpf(0.4, 0.82, along)
		var strength := HEAD_ALPHA * fade * lerpf(1.0, TAIL_ALPHA, sqrt(along))
		var rim := _colour
		rim.a = strength
		var hub := _colour
		hub.a = strength * lerpf(INNER_ALPHA_HEAD, INNER_ALPHA_TAIL, along)
		_mesh.surface_set_color(hub)
		_mesh.surface_set_normal(Vector3.UP)
		_mesh.surface_add_vertex(_on_arc(angle, inner))
		_mesh.surface_set_color(rim)
		_mesh.surface_set_normal(Vector3.UP)
		_mesh.surface_add_vertex(_on_arc(angle, outer))
	_mesh.surface_end()


## A point in the cone, in the same convention `Mouse._facing` uses: zero is straight ahead down
## local -Z, positive swings to the mouse's left.
func _on_arc(angle: float, radius: float) -> Vector3:
	return Vector3(-sin(angle) * radius, 0.0, -cos(angle) * radius)
