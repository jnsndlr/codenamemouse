class_name Player
extends CharacterBody3D
## M1: a mouse that moves.
##
## Two things here are worth understanding, because everything later builds on them.
##
## Movement is CAMERA-RELATIVE. The isometric camera sits at a fixed 45 degree yaw, so
## raw WASD would send you diagonally across the screen and feel wrong immediately. We
## project the input onto the camera's flattened basis so W always means "up-screen".
##
## Aim is the CURSOR PROJECTED ONTO THE GROUND PLANE. A ray from the camera through the
## mouse position, intersected with the horizontal plane at the player's feet. This is
## the same operation digging and abilities will use later, so it lives here from day one.

@export var speed: float = 4.5
## Sprint is free right now. Once the economy exists it drains the team's cheese pool
## while held, and cheese is respawns — see GDD section 2.
@export var sprint_speed: float = 7.2
@export var acceleration: float = 40.0
@export var friction: float = 35.0

@onready var _visual: Node3D = $Visual
@onready var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 20.0)

var _aim_point: Vector3 = Vector3.ZERO


## Where the player is currently pointing, on the ground plane.
## The camera rig reads this to lead the view slightly toward the cursor.
func get_aim_point() -> Vector3:
	return _aim_point


func is_sprinting() -> bool:
	return Input.is_action_pressed("sprint")


func get_walk_speed() -> float:
	return speed


func get_sprint_speed() -> float:
	return sprint_speed


func get_horizontal_speed() -> float:
	return Vector3(velocity.x, 0.0, velocity.z).length()


func _physics_process(delta: float) -> void:
	_update_aim()
	_apply_movement(delta)


func _apply_movement(delta: float) -> void:
	var direction := _input_direction()
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var top_speed := sprint_speed if is_sprinting() else speed

	if direction.length_squared() > 0.0:
		horizontal = horizontal.move_toward(direction * top_speed, acceleration * delta)
	else:
		horizontal = horizontal.move_toward(Vector3.ZERO, friction * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta

	move_and_slide()


func _input_direction() -> Vector3:
	var raw := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if raw.length_squared() < 0.01:
		return Vector3.ZERO

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector3(raw.x, 0.0, raw.y).normalized()

	var basis := camera.global_transform.basis
	var forward := basis.z * -1.0
	forward.y = 0.0
	var right := basis.x
	right.y = 0.0

	# raw.y is +1 for "move_down" (S), so subtract to make W push forward.
	return (right.normalized() * raw.x - forward.normalized() * raw.y).normalized()


func _update_aim() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var mouse := get_viewport().get_mouse_position()
	var ground := Plane(Vector3.UP, global_position.y)
	var hit: Variant = ground.intersects_ray(
		camera.project_ray_origin(mouse), camera.project_ray_normal(mouse)
	)
	if hit == null:
		return

	_aim_point = hit
	var to_aim: Vector3 = _aim_point - global_position
	to_aim.y = 0.0
	if to_aim.length_squared() > 0.0004:
		_visual.global_rotation.y = atan2(to_aim.x, to_aim.z)
