class_name Player
extends CharacterBody3D
## The mouse, and how it moves.
##
## THE CURSOR IS THE STEERING WHEEL (GDD section 9). The mouse turns to face the cursor at
## a capped rate, and W drives it that way. W/S/A/D are relative to FACING, not to the
## camera — so S is a backpedal and A/D are sidesteps, and all three keep you pointed at
## whatever you were pointed at.
##
## The thing that makes this work: movement is DERIVED FROM facing, so the two can never
## disagree. The old camera-relative scheme turned velocity almost instantly while the body
## turned at a capped rate, so the mouse visibly crabbed sideways through every direction
## change. Here the turn-rate cap still supplies the weight, but as a body that takes a
## moment to swing around — and W pushing along a swinging facing is what produces the
## arcs. Lower `turn_speed` for a heavier mouse; it's the main weight dial now.
##
## Speed ladder: Slow (hold Shift) < Run (default) < Sprint (double-tap W, costs personal
## stamina). Sprint never costs cheese — that's Scurry, which is a separate, bigger thing
## and doesn't exist yet. On a pad, feathering the stick covers Slow-to-Run, so Shift has
## no pad equivalent and Sprint moves to L3.

@export_group("Movement")
@export var speed: float = 3.0
## Applied on top of `speed`. Slow overrides Sprint while held — you can't be quiet and
## fast, which is the whole point of the tier.
@export_range(0.1, 1.0, 0.01) var slow_multiplier: float = 0.45
@export_range(1.0, 2.5, 0.05) var sprint_multiplier: float = 1.4
## Sidestepping and backpedalling are slower than running forward. The backpedal number is
## load-bearing: it's what makes turning-to-throw-while-fleeing a real trade rather than a
## free action (GDD section 9).
@export_range(0.1, 1.0, 0.01) var strafe_multiplier: float = 0.85
@export_range(0.1, 1.0, 0.01) var back_multiplier: float = 0.7
## Higher reaches top speed sooner. Kept brisk, because weight now comes from the turn
## rate rather than from a sluggish ramp — a mouse that's slow to start AND slow to turn
## just feels broken.
@export var acceleration: float = 30.0
## Higher stops you sooner. Above acceleration so stopping reads crisper than starting.
@export var friction: float = 34.0
## Radians per second the body can turn toward the cursor. THE weight dial. Per-class
## later: the Scout whips around, the Bruiser commits to a heading.
@export var turn_speed: float = 10.0
## Cursor closer than this to the mouse stops steering it. Without this the facing spins
## wildly whenever the cursor passes over the body.
@export var aim_deadzone: float = 0.45

@export_group("Sprint stamina")
## Seconds of sprint at full stamina. This is the per-class dial (GDD section 9) — sprint
## SPEED is uniform, duration is what differs. Scout 6.0, Bruiser 1.5.
@export var sprint_seconds: float = 4.0
## Quiet time before stamina starts coming back.
@export var stamina_regen_delay: float = 2.0
## Seconds to refill from empty, once regen has started.
@export var stamina_refill_seconds: float = 6.0
## Can't re-engage sprint below this much stamina. Stops stutter-sprinting on fumes.
@export var sprint_minimum: float = 0.35
## How quickly the second W tap has to land.
@export var double_tap_window: float = 0.28

@export_group("Appearance")
## Team colour is applied over whatever the model ships with, rather than baked into the
## mesh. Crews are blue and red (GDD section 1), so tint has to be a runtime decision —
## the same mouse asset serves both sides and, later, all four classes.
@export var team_color: Color = Color(0.30, 0.45, 0.80)

@onready var _visual: Node3D = $Visual
@onready var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 20.0)

## Y rotation of the visual. Forward is its local -Z, per Godot's convention and per how
## mouse.blend is actually built — nose at -Z, tail at +Z. Worth stating because the code
## this replaced assumed +Z was forward, which was invisible while the player was a
## symmetric capsule and quietly made the mouse run tail-first once the model landed.
var _facing: float = 0.0
var _aim_point: Vector3 = Vector3.ZERO
var _stamina: float = 0.0
var _regen_timer: float = 0.0
var _sprinting: bool = false
var _since_forward_tap: float = 999.0


func _ready() -> void:
	apply_team_color(team_color)
	_facing = _visual.rotation.y
	_stamina = sprint_seconds


## Flat tint across every mesh in the model. Deliberately crude for now — once classes
## exist this wants two tones (fur and tunic) so silhouette AND colour both carry class
## identity at isometric distance.
func apply_team_color(colour: Color) -> void:
	team_color = colour
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.85
	for node in _visual.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_override = material


## Where the cursor currently sits on the ground plane. This is the aim source — thrown
## acorns, barricade placement and dig direction all want it later. The camera does NOT
## read it; it works out its own lead from screen space (see camera_rig.gd).
func get_aim_point() -> Vector3:
	return _aim_point


## Unit vector the mouse is pointing. Dig direction and ramp direction both come from
## here rather than from velocity -- you should be able to aim a tunnel while standing
## still, and while digging you are barely moving anyway.
func get_facing_direction() -> Vector3:
	return _forward()


func is_sprinting() -> bool:
	return _sprinting


## 0..1, for the HUD. Personal and private — never shown for anyone else (GDD section 10).
func get_stamina_ratio() -> float:
	return _stamina / maxf(sprint_seconds, 0.001)


func get_walk_speed() -> float:
	return speed


func get_sprint_speed() -> float:
	return speed * sprint_multiplier


func get_horizontal_speed() -> float:
	return Vector3(velocity.x, 0.0, velocity.z).length()


func _physics_process(delta: float) -> void:
	_update_aim()
	_update_sprint(delta)
	_update_facing(delta)
	_apply_movement(delta)


## Double-tap W. Sprint holds while W is held and dies the moment you stop pushing forward,
## run dry, or drop to Slow — so it can never be left on by accident, which is why it
## doesn't need to be a toggle.
func _update_sprint(delta: float) -> void:
	if Input.is_action_just_pressed("move_forward"):
		if _since_forward_tap <= double_tap_window and _stamina >= sprint_minimum:
			_sprinting = true
		_since_forward_tap = 0.0
	else:
		_since_forward_tap += delta

	# L3 on a pad, because you can't double-tap a stick.
	if Input.is_action_just_pressed("sprint") and _stamina >= sprint_minimum:
		_sprinting = true

	if Input.get_action_strength("move_forward") <= 0.0 or Input.is_action_pressed("slow"):
		_sprinting = false

	if _sprinting:
		_stamina = maxf(0.0, _stamina - delta)
		_regen_timer = 0.0
		if _stamina <= 0.0:
			_sprinting = false
		return

	_regen_timer += delta
	if _regen_timer >= stamina_regen_delay:
		var rate := sprint_seconds / maxf(stamina_refill_seconds, 0.001)
		_stamina = minf(sprint_seconds, _stamina + rate * delta)


## Turn toward the cursor (or the right stick) at a capped rate. Facing is updated even
## when standing still — being able to point at something you're backing away from is the
## reason S exists.
func _update_facing(delta: float) -> void:
	var wanted := _aim_direction()
	if wanted.is_zero_approx():
		return

	var difference := angle_difference(_facing, _heading_to(wanted))
	var step := turn_speed * delta
	_facing = wrapf(_facing + clampf(difference, -step, step), -PI, PI)
	_visual.rotation.y = _facing


func _apply_movement(delta: float) -> void:
	var wish := _wish_direction()
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)

	if wish.length_squared() > 0.0:
		horizontal = horizontal.move_toward(wish * _tier_speed(), acceleration * delta)
	else:
		horizontal = horizontal.move_toward(Vector3.ZERO, friction * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta

	move_and_slide()


func _tier_speed() -> float:
	if _sprinting:
		return speed * sprint_multiplier
	if Input.is_action_pressed("slow"):
		return speed * slow_multiplier
	return speed


## Facing-relative, which is the whole scheme. Note the penalties are applied AFTER the
## radial clamp, so holding W+D doesn't launder the strafe penalty away by renormalising.
func _wish_direction() -> Vector3:
	var raw := Vector2(
		Input.get_action_strength("strafe_right") - Input.get_action_strength("strafe_left"),
		Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	)
	if raw.length_squared() < 0.0001:
		return Vector3.ZERO
	if raw.length() > 1.0:
		raw = raw.normalized()

	var forward := _forward()
	var right := forward.cross(Vector3.UP)
	var ahead := raw.y * (1.0 if raw.y >= 0.0 else back_multiplier)
	return forward * ahead + right * raw.x * strafe_multiplier


## The two halves of the -Z-forward convention, kept together so they can't drift apart.
func _forward() -> Vector3:
	return Vector3(-sin(_facing), 0.0, -cos(_facing))


func _heading_to(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


## Right stick wins when it's deflected; otherwise the cursor. A neutral stick returns
## zero, which _update_facing reads as "hold what you've got" — that's what lets a pad
## player let go of the stick without the mouse snapping to a default heading.
func _aim_direction() -> Vector3:
	var stick := Vector2(
		Input.get_action_strength("look_right") - Input.get_action_strength("look_left"),
		Input.get_action_strength("look_down") - Input.get_action_strength("look_up")
	)
	if stick.length() > 0.25:
		return _camera_relative(stick)

	var to_cursor := _aim_point - global_position
	to_cursor.y = 0.0
	if to_cursor.length() < aim_deadzone:
		return Vector3.ZERO
	return to_cursor.normalized()


## Stick up means up-screen, which is what the fixed 45 degree camera yaw would otherwise
## make a diagonal.
func _camera_relative(input: Vector2) -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector3(input.x, 0.0, input.y).normalized()

	var basis := camera.global_transform.basis
	var forward := -basis.z
	forward.y = 0.0
	var right := basis.x
	right.y = 0.0
	return (right.normalized() * input.x - forward.normalized() * input.y).normalized()


func _update_aim() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var mouse := get_viewport().get_mouse_position()
	var ground := Plane(Vector3.UP, global_position.y)
	var hit: Variant = ground.intersects_ray(
		camera.project_ray_origin(mouse), camera.project_ray_normal(mouse)
	)
	if hit != null:
		_aim_point = hit
