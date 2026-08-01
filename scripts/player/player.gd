class_name Player
extends Mouse
## The mouse you are driving. Everything a mouse can DO lives in `mouse.gd`; this is only the
## half that reads a keyboard -- steering, the speed ladder, and the swing.
##
## THE CURSOR IS THE STEERING WHEEL (GDD section 9). The mouse turns to face the cursor at a
## capped rate, and W drives it that way. W/S/A/D are relative to FACING, not to the camera --
## so S is a backpedal and A/D are sidesteps, and all three keep you pointed at whatever you
## were pointed at.
##
## The thing that makes this work: movement is DERIVED FROM facing, so the two can never
## disagree. The old camera-relative scheme turned velocity almost instantly while the body
## turned at a capped rate, so the mouse visibly crabbed sideways through every direction
## change. Here the turn-rate cap still supplies the weight, but as a body that takes a moment
## to swing around -- and W pushing along a swinging facing is what produces the arcs.
##
## Speed ladder: Slow (hold Shift) < Run (default) < Sprint (double-tap W, costs personal
## stamina). Sprint never costs cheese -- that's Scurry, which is a separate, bigger thing and
## doesn't exist yet.
##
## LEFT CLICK IS THE ATTACK, and digging moved to right click. GDD section 9's table always
## said so; through M2 there was nothing to fight, so the dig hold took the primary button by
## default and it would have quietly become the convention. Right click is the ability button
## in that same table, and digging is the Engineer's ability (section 4) -- so this is the
## binding the design already had, arrived at as soon as there was a reason to care.

@export_group("Sprint stamina")
## Seconds of sprint at full stamina. This is the per-class dial (GDD section 9) -- sprint
## SPEED is uniform, duration is what differs. Sneak 6.0, Brute 1.5.
@export var sprint_seconds: float = 4.0
## Quiet time before stamina starts coming back.
@export var stamina_regen_delay: float = 2.0
## Seconds to refill from empty, once regen has started.
@export var stamina_refill_seconds: float = 6.0
## Can't re-engage sprint below this much stamina. Stops stutter-sprinting on fumes.
@export var sprint_minimum: float = 0.35
## How quickly the second W tap has to land.
@export var double_tap_window: float = 0.28

@export_group("Aim")
## Cursor closer than this to the mouse stops steering it. Without this the facing spins
## wildly whenever the cursor passes over the body.
@export var aim_deadzone: float = 0.45

var _aim_point: Vector3 = Vector3.ZERO
var _stamina: float = 0.0
var _regen_timer: float = 0.0
var _sprinting: bool = false
var _since_forward_tap: float = 999.0


func _ready() -> void:
	super()
	_stamina = sprint_seconds


## Sprint duration is per-class (GDD section 9: Sneak 6.0, Brute 1.5) and sprint SPEED is not.
## Handled here rather than in the base class because a bot has no stamina to give a duration to,
## and the stat would be a property nothing reads on three quarters of the mice in the match.
func apply_class(definition: ClassDefinition) -> void:
	super(definition)
	sprint_seconds = definition.sprint_seconds
	# Topped up, not scaled. Swapping class at your own nest is the one moment stamina is
	# uninteresting -- you are standing still, at home, and about to walk somewhere.
	_stamina = sprint_seconds


## Where the cursor currently sits on the ground plane. This is the aim source -- thrown
## acorns, barricade placement and dig target all want it. The camera does NOT read it; it
## works out its own lead from screen space (see camera_rig.gd).
func get_aim_point() -> Vector3:
	return _aim_point


func is_sprinting() -> bool:
	return _sprinting


## 0..1, for the HUD. Personal and private -- never shown for anyone else (GDD section 10).
func get_stamina_ratio() -> float:
	return _stamina / maxf(sprint_seconds, 0.001)


func get_walk_speed() -> float:
	return speed


func get_sprint_speed() -> float:
	return speed * sprint_multiplier


## The one method the base class asks for. Aim, then the ladder, then a heading.
func _control(delta: float) -> void:
	_update_aim()
	_update_sprint(delta)
	_face_toward(_aim_direction(), delta)

	if Input.is_action_just_pressed("attack") and not _pointer_over_ui():
		swing()

	_wish = _wish_direction()


func _tier_multiplier() -> float:
	if _sprinting:
		return sprint_multiplier
	if Input.is_action_pressed("slow"):
		return slow_multiplier
	return 1.0


## Double-tap W. Sprint holds while W is held and dies the moment you stop pushing forward,
## run dry, or drop to Slow -- so it can never be left on by accident, which is why it doesn't
## need to be a toggle.
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


## Facing-relative, which is the whole scheme. Note the penalties are applied AFTER the radial
## clamp, so holding W+D doesn't launder the strafe penalty away by renormalising.
func _wish_direction() -> Vector3:
	var raw := Vector2(
		Input.get_action_strength("strafe_right") - Input.get_action_strength("strafe_left"),
		Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	)
	if raw.length_squared() < 0.0001:
		return Vector3.ZERO
	if raw.length() > 1.0:
		raw = raw.normalized()

	var forward := get_facing_direction()
	var right := forward.cross(Vector3.UP)
	var ahead := raw.y * (1.0 if raw.y >= 0.0 else back_multiplier)
	return forward * ahead + right * raw.x * strafe_multiplier


## Right stick wins when it's deflected; otherwise the cursor. A neutral stick returns zero,
## which `_face_toward` reads as "hold what you've got" -- that's what lets a pad player let
## go of the stick without the mouse snapping to a default heading.
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


## Stick up means up-screen, which is what the fixed 45 degree camera yaw would otherwise make
## a diagonal.
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


## Whether the cursor is over a piece of UI rather than over the world. The same guard the dig
## controller uses, and for the same reason -- swinging at the air every time you drag a slider
## on the look panel would be a strange way to tune a picture.
func _pointer_over_ui() -> bool:
	var viewport := get_viewport()
	return viewport != null and viewport.gui_get_hovered_control() != null
