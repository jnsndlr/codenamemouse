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

@onready var _pitch: Node3D = $Pitch
@onready var _camera: Camera3D = $Pitch/Camera3D

var _target: Node3D
var _zoom: float = zoom_idle


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
func _wanted_zoom() -> float:
	if not _target.has_method("get_horizontal_speed"):
		return zoom_idle

	var current: float = _target.get_horizontal_speed()
	var walk: float = _target.get_walk_speed() if _target.has_method("get_walk_speed") else 4.5
	var top: float = _target.get_sprint_speed() if _target.has_method("get_sprint_speed") else walk

	if current <= walk:
		return lerpf(zoom_idle, zoom_run, clampf(current / maxf(walk, 0.001), 0.0, 1.0))

	var over := (current - walk) / maxf(top - walk, 0.001)
	return lerpf(zoom_run, zoom_sprint, clampf(over, 0.0, 1.0))


func _desired_position() -> Vector3:
	var base: Vector3 = _target.global_position
	if not _target.has_method("get_aim_point"):
		return base

	var lead: Vector3 = (_target.get_aim_point() - base) * aim_lead
	lead.y = 0.0
	if lead.length() > max_lead:
		lead = lead.normalized() * max_lead
	return base + lead
