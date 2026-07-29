extends Node3D
## Fixed isometric camera that follows the player, leads toward the cursor, and pulls
## back as they pick up speed.
##
## The angles are exported and applied at runtime rather than baked into the scene file,
## because "what does isometric actually feel like" is a question you answer by dragging
## a slider for ten minutes. Tweak yaw/pitch in the inspector while the game runs.
##
## True isometric is pitch 35.264. Games that call themselves isometric are usually
## steeper — 40 to 50 — because it reads better and shows more of what's in front of you.

@export_group("Framing")
## Rotation around the world Y axis. 45 puts map edges on the screen diagonals.
@export_range(0.0, 90.0, 0.5) var yaw_degrees: float = 45.0
## Downward tilt. Lower sees further ahead; higher reads more like a floor plan.
@export_range(15.0, 80.0, 0.5) var pitch_degrees: float = 40.0

@export_group("Speed zoom")
## Orthographic view height when standing still. Smaller is more zoomed in.
@export_range(4.0, 40.0, 0.25) var zoom_idle: float = 7.5
## View height at full walking speed.
@export_range(4.0, 40.0, 0.25) var zoom_run: float = 9.0
## View height at full sprint.
@export_range(4.0, 40.0, 0.25) var zoom_sprint: float = 10.75
## How fast the view widens. Prompt, so speeding up feels responsive.
@export var zoom_out_speed: float = 3.5
## How fast the view narrows. Deliberately slower, so tapping keys doesn't pump the view.
@export var zoom_in_speed: float = 1.8

@export_group("Follow")
@export var target: NodePath
## Higher snaps to the player faster. Frame-rate independent.
@export var follow_speed: float = 8.0
## How far the view leads toward the cursor, as a fraction of the distance to it.
@export_range(0.0, 1.0, 0.01) var aim_lead: float = 0.22
## Hard cap on that lead, so flinging the cursor across the map doesn't lose the player.
@export var max_lead: float = 3.0
## World-space radius around screen centre where the cursor produces NO lead at all. The
## cursor now steers the mouse (GDD section 9), so it's in constant motion — without a
## dead zone the view drifts every time you correct your heading.
@export var lead_dead_zone: float = 1.5

@onready var _pitch: Node3D = $Pitch
@onready var _camera: Camera3D = $Pitch/Camera3D

var _target: Node3D
var _zoom: float = zoom_idle
var _speed_signal: float = 0.0


func _ready() -> void:
	_target = get_node_or_null(target) as Node3D
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_apply_angles()
	_zoom = zoom_idle
	_camera.size = _zoom
	if _target != null:
		global_position = _desired_position()


func _process(_delta: float) -> void:
	# Cheap enough to reapply every frame, which is what makes live inspector tweaking work.
	if OS.is_debug_build():
		_apply_angles()


func _physics_process(delta: float) -> void:
	if _target == null:
		return

	var weight := 1.0 - exp(-follow_speed * delta)
	global_position = global_position.lerp(_desired_position(), weight)

	# Smooth the speed BEFORE it reaches the zoom curve, not after. Zoom changes the
	# orthographic size, which changes how many world units a pixel covers, which changes
	# the cursor lead below — so a jittery speed reading would show up as the whole frame
	# breathing. One filter here fixes it everywhere downstream.
	_speed_signal = lerpf(_speed_signal, _current_speed(), 1.0 - exp(-6.0 * delta))

	# Asymmetric smoothing: widen promptly, return lazily.
	var wanted := _wanted_zoom()
	var rate := zoom_out_speed if wanted > _zoom else zoom_in_speed
	_zoom = lerpf(_zoom, wanted, 1.0 - exp(-rate * delta))
	_camera.size = _zoom


func _apply_angles() -> void:
	rotation_degrees.y = yaw_degrees
	_pitch.rotation_degrees.x = -pitch_degrees


## Zoom is driven by how fast the player is ACTUALLY moving, not by whether the sprint
## key is down. That matters later: carrying the flag, wading through water, or squeezing
## through a tunnel all slow you down, and the camera should tighten up for those without
## anyone writing a special case.
func _current_speed() -> float:
	if not _target.has_method("get_horizontal_speed"):
		return 0.0
	return _target.get_horizontal_speed()


func _wanted_zoom() -> float:
	if not _target.has_method("get_horizontal_speed"):
		return zoom_idle

	var current := _speed_signal
	var walk: float = _target.get_walk_speed() if _target.has_method("get_walk_speed") else 4.5
	var top: float = _target.get_sprint_speed() if _target.has_method("get_sprint_speed") else walk

	if current <= walk:
		return lerpf(zoom_idle, zoom_run, clampf(current / maxf(walk, 0.001), 0.0, 1.0))

	var over := (current - walk) / maxf(top - walk, 0.001)
	return lerpf(zoom_run, zoom_sprint, clampf(over, 0.0, 1.0))


func _desired_position() -> Vector3:
	var base: Vector3 = _target.global_position
	var lead := _lead_offset() * aim_lead
	if lead.length() > max_lead:
		lead = lead.normalized() * max_lead
	return base + lead


## Where the cursor sits relative to SCREEN CENTRE, in world units on the ground plane.
##
## This used to read the player's cursor ground-point and lead toward it, which was a
## feedback loop: the ground-point is computed from the camera's own transform, so the
## camera fed its own input. It converged, but slowly and through the follow lerp, so the
## frame never actually settled — hold the cursor perfectly still and the view still
## crept. Worse, orthographic size is part of that projection, so merely accelerating
## slid the camera sideways.
##
## Taking the difference between two points unprojected through the SAME camera cancels
## the camera's position exactly, which makes this a pure function of cursor screen
## position, camera angles and zoom. No loop, and it settles the instant you stop moving
## the mouse.
func _lead_offset() -> Vector3:
	var viewport := get_viewport()
	if viewport == null:
		return Vector3.ZERO

	var stick := Vector2(
		Input.get_action_strength("look_right") - Input.get_action_strength("look_left"),
		Input.get_action_strength("look_down") - Input.get_action_strength("look_up")
	)

	var offset: Vector3
	if stick.length() > 0.25:
		# Pad: the stick has no screen position to read, so lead a fixed distance along it.
		var size := viewport.get_visible_rect().size
		offset = _ground_point(size * 0.5 + stick * size.y * 0.5) - _ground_point(size * 0.5)
	else:
		offset = _ground_point(viewport.get_mouse_position()) \
			- _ground_point(viewport.get_visible_rect().size * 0.5)

	offset.y = 0.0
	var distance := offset.length()
	if distance <= lead_dead_zone:
		return Vector3.ZERO
	return offset.normalized() * (distance - lead_dead_zone)


func _ground_point(screen: Vector2) -> Vector3:
	var plane := Plane(Vector3.UP, _target.global_position.y)
	var hit: Variant = plane.intersects_ray(
		_camera.project_ray_origin(screen), _camera.project_ray_normal(screen)
	)
	return hit if hit != null else Vector3.ZERO
