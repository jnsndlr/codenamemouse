class_name Player
extends CharacterBody3D
## M1: a mouse that moves.
##
## Movement is CAMERA-RELATIVE. The isometric camera sits at a fixed 45 degree yaw, so
## raw WASD would send you diagonally across the screen and feel wrong immediately. We
## project input onto the camera's flattened basis so W always means "up-screen".
##
## Facing follows MOVEMENT, not the cursor. Cursor-facing read as twitchy at this scale:
## the mouse is small on screen and every flick of the wrist spun it around. Turning is
## rate-limited, which is where a good chunk of the sense of weight comes from.
##
## The cursor still does one job — the camera leads gently toward it, so you can peek
## around without moving. That's why we still project it onto the ground plane here.

@export_group("Movement")
@export var speed: float = 3.0
## Sprint is free right now. Once the economy exists it drains the team's cheese pool
## while held, and cheese is respawns — see GDD section 2.
@export var sprint_speed: float = 5.0
## Lower is heavier. This is the main weight dial.
@export var acceleration: float = 16.0
## Higher stops you sooner. Kept above acceleration so stopping reads crisper than starting.
@export var friction: float = 24.0
## Radians per second the body can turn. Lower feels heavier and more committed.
@export var rotation_speed: float = 9.0

@onready var _visual: Node3D = $Visual
@onready var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 20.0)

var _aim_point: Vector3 = Vector3.ZERO


## Where the cursor currently sits on the ground plane.
## The camera rig reads this to lead the view. It does NOT affect facing.
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
	var direction := _input_direction()
	_update_aim()
	_apply_movement(direction, delta)
	_update_facing(direction, delta)


func _apply_movement(direction: Vector3, delta: float) -> void:
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


## Turn toward where we're heading, at a capped rate. Holding the last facing when input
## stops is deliberate — snapping back to a default direction on release feels wrong.
func _update_facing(direction: Vector3, delta: float) -> void:
	if direction.length_squared() < 0.001:
		return

	var wanted := atan2(direction.x, direction.z)
	var difference := angle_difference(_visual.rotation.y, wanted)
	var step := rotation_speed * delta
	_visual.rotation.y += clampf(difference, -step, step)


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
	if hit != null:
		_aim_point = hit
