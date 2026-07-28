extends Node3D
## Fixed isometric camera that follows the player with a little lead toward the cursor.
##
## The angles are exported and applied at runtime rather than baked into the scene file,
## because "what does isometric actually feel like" is a question you answer by dragging
## a slider for ten minutes. Tweak yaw/pitch/zoom in the inspector while the game runs.
##
## True isometric is pitch 35.264. Games that call themselves isometric are usually
## steeper — 40 to 50 — because it reads better and shows more of what's in front of you.

@export_group("Framing")
## Rotation around the world Y axis. 45 puts map edges on the screen diagonals.
@export_range(0.0, 90.0, 0.5) var yaw_degrees: float = 45.0
## Downward tilt. Lower sees further ahead; higher reads more like a floor plan.
@export_range(15.0, 80.0, 0.5) var pitch_degrees: float = 40.0
## Orthographic view height in world units. Smaller means more zoomed in.
@export_range(4.0, 40.0, 0.5) var zoom: float = 9.0

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


func _ready() -> void:
	_target = get_node_or_null(target) as Node3D
	_apply_framing()
	if _target != null:
		global_position = _desired_position()


func _process(_delta: float) -> void:
	# Cheap enough to reapply every frame, which is what makes live inspector tweaking work.
	if Engine.is_editor_hint() or OS.is_debug_build():
		_apply_framing()


func _physics_process(delta: float) -> void:
	if _target == null:
		return
	# Exponential smoothing: same result at 30fps and 240fps.
	var weight := 1.0 - exp(-follow_speed * delta)
	global_position = global_position.lerp(_desired_position(), weight)


func _apply_framing() -> void:
	rotation_degrees.y = yaw_degrees
	_pitch.rotation_degrees.x = -pitch_degrees
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = zoom


func _desired_position() -> Vector3:
	var base: Vector3 = _target.global_position
	if not _target.has_method("get_aim_point"):
		return base

	var lead: Vector3 = (_target.get_aim_point() - base) * aim_lead
	lead.y = 0.0
	if lead.length() > max_lead:
		lead = lead.normalized() * max_lead
	return base + lead
