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
## Starting rotation around the world Y axis. 45 puts map edges on the screen diagonals.
## The view keys turn in quarter steps from here; this is only where it begins.
@export_range(0.0, 90.0, 0.5) var yaw_degrees: float = 45.0
## Downward tilt. Lower sees further ahead; higher reads more like a floor plan.
##
## Raised from 40 for the tunnels, and it is worth knowing the exchange rate: a wall of
## height D hides a strip of floor D / tan(pitch) wide behind it. Going 40 -> 48 shrinks that
## by a fifth for free, on every wall in the game, which is the cheapest visibility you can
## buy. Steeper than about 55 and the world starts reading as a floor plan.
@export_range(15.0, 80.0, 0.5) var pitch_degrees: float = 48.0

@export_group("Swivel")
## Quarter turns, because a tunnel is always dug on the grid and a quarter turn is the only
## rotation that keeps a corridor square to the screen.
##
## This is the counterpart to lowering the walls rather than an alternative to it. A trench
## running ACROSS the view is hidden behind its own near wall along its whole length; the same
## trench running toward the camera is open end to end. Being able to turn the world is what
## makes that recoverable instead of just bad luck.
@export var swivel_speed: float = 9.0

@export_group("Speed zoom")
## Whether the view widens with speed at all. Off pins it at `zoom_idle` forever.
##
## Worth being able to switch off in one click rather than by flattening three numbers: a
## breathing view is the kind of thing that feels great for ten seconds and tiring for ten
## minutes, and that is only answerable by turning it off mid-play and noticing whether you
## miss it. It also removes the moving part that fights `pixel_aligned_panning`.
@export var speed_zoom: bool = true
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

@export_group("Pixel grid")
## Hold the rendered image still on the fat-pixel grid while the camera slides underneath it.
##
## OFF, and that reverses the reference project's choice for a reason specific to this game.
##
## What it buys is the end of edge crawl: without it the camera moves in continuous world
## units while the image is quantised into blocks, so a static edge sits in one block for a
## while and then flips to the next, and every straight line fizzes as you walk. What it costs
## is that the world can then only move in whole-pixel steps, so the camera judders -- and the
## judder scales with `pixel_size`, because that is the size of the step.
##
## Two things make that trade bad here rather than merely a matter of taste:
##
##   The camera zooms CONSTANTLY. `_camera.size` rides player speed (see the Speed zoom group),
##   and a fat pixel is a fraction of that size -- so the grid being snapped to is resized
##   every frame the view breathes. The rounding target then moves on its own, independently
##   of the player, and the result is not clean pixel stepping but erratic jumping. The
##   reference has a fixed camera that never zooms, which is why it never meets this.
##
##   The camera FOLLOWS. A fixed or grid-stepped camera has nothing to judder against; one
##   that smoothly tracks a moving player spends its whole life mid-step.
##
## Left as a toggle rather than deleted, because it is the correct technique for a camera that
## doesn't zoom, and the panel makes the difference a keypress away. If crawl turns out to be
## the greater evil, the better fix is to slide the SHADER's sampling grid with the camera
## instead of snapping the camera to the shader's grid -- same stability, no judder.
@export var pixel_aligned_panning: bool = false
## Must match the pixel pass's own `pixel_size`, or the camera snaps to the wrong grid and
## makes the crawl worse rather than better. The look panel drives both from one slider.
@export_range(1.0, 20.0, 1.0) var pixel_size: float = 4.0

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
## The camera's standoff from the rig, before any pixel-grid correction. Captured rather than
## hardcoded so moving the camera in the scene doesn't silently become a permanent offset.
var _camera_rest: Vector3
var _zoom: float = zoom_idle
var _speed_signal: float = 0.0
## Where the swivel is heading, in radians. Kept unwrapped and turned into rotation by
## lerp_angle, which always takes the short way round -- so the ninth quarter turn is a
## quarter turn, not two and a bit revolutions.
var _wanted_yaw: float = 0.0


func _ready() -> void:
	_target = get_node_or_null(target) as Node3D
	_camera_rest = _camera.position
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_wanted_yaw = deg_to_rad(yaw_degrees)
	rotation.y = _wanted_yaw
	_apply_angles()
	_zoom = zoom_idle
	_camera.size = _zoom
	if _target != null:
		global_position = _desired_position()
		# CUT ON RESPAWN, don't fly. A respawn puts the mouse at its own nest, which is most of
		# an arena away, and easing after it means several seconds where you can neither see
		# your mouse nor understand what you are looking at. It's the same reason the rig snaps
		# here rather than easing in from wherever it was authored.
		if _target.has_signal("revived"):
			_target.revived.connect(_cut_to_target)


func _cut_to_target(_mouse: Node) -> void:
	if _target != null:
		global_position = _desired_position()


func _process(_delta: float) -> void:
	# Cheap enough to reapply every frame, which is what makes live inspector tweaking work.
	if OS.is_debug_build():
		_apply_angles()


func _physics_process(delta: float) -> void:
	_swivel(delta)
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

	# Last, because it reads the zoom that was just written -- a fat pixel is a fraction of
	# the orthographic size, so it changes width every frame the view is breathing.
	_align_to_pixel_grid()


## Turn the world a quarter at a time, and glide rather than snap -- a hard cut leaves you with
## no idea which way anything went, which is the opposite of the point.
func _swivel(delta: float) -> void:
	if Input.is_action_just_pressed("view_left"):
		_wanted_yaw += PI * 0.5
	if Input.is_action_just_pressed("view_right"):
		_wanted_yaw -= PI * 0.5
	rotation.y = lerp_angle(rotation.y, _wanted_yaw, 1.0 - exp(-swivel_speed * delta))


## Nudge the camera by up to half a fat pixel so the world lands on the pixel grid the shader
## quantises to, instead of sliding under it.
##
## The correction goes on the CAMERA's local offset, never on the rig's position. Everything
## else -- the follow lerp, the cursor lead, anything that later asks where the view is --
## reads the rig, and quantising that would feed a stair-stepped position back into the
## smoothing that produced it. The rig stays perfectly smooth and only the eye is snapped.
##
## Snapping along the camera's OWN right and up rather than along world axes is what makes
## this work at 45 degrees of yaw: the grid the shader quantises to is the screen's, so the
## grid the camera aligns to has to be the screen's as well.
func _align_to_pixel_grid() -> void:
	if not pixel_aligned_panning:
		_camera.position = _camera_rest
		return

	var viewport := get_viewport()
	if viewport == null:
		return
	var height: float = viewport.get_visible_rect().size.y
	if height <= 0.0:
		return

	# World units spanned by one fat pixel. Godot's orthographic `size` is the VERTICAL extent
	# of the view, so this is the vertical figure -- and pixels are square, so it is the
	# horizontal one too.
	var unit := _camera.size * pixel_size / height
	if unit <= 0.0:
		return

	# Where the eye WOULD sit with no correction. Derived rather than read back off the node,
	# so nothing has to flush a transform mid-frame to make it true.
	var basis := _pitch.global_transform.basis
	var eye := global_position + basis * _camera_rest

	_camera.position = _camera_rest - Vector3(
		_fraction(eye.dot(basis.x) / unit) * unit,
		_fraction(eye.dot(basis.y) / unit) * unit,
		0.0
	)


## Signed distance to the nearest whole number, in [-0.5, 0.5]. Nearest rather than floor, so
## the correction is never more than half a pixel in either direction.
func _fraction(value: float) -> float:
	return value - roundf(value)


## Whether the view is still turning. Anything that reads a screen-space direction wants to
## know, because during the turn the ground under the cursor is sliding on its own.
func is_swivelling() -> bool:
	return absf(angle_difference(rotation.y, _wanted_yaw)) > 0.01


## PITCH ONLY. Yaw belongs to the swivel now, and reapplying the exported angle every frame
## would drag the view back to 45 degrees the instant it tried to turn.
func _apply_angles() -> void:
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
	if not speed_zoom or not _target.has_method("get_horizontal_speed"):
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
