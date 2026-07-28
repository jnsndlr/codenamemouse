extends Node3D
## M1 test arena.
##
## Rotations live here rather than in the scene file because Transform3D basis matrices
## are unreadable in a diff and unpleasant to hand-edit. Positions stay in the .tscn.

@export var sun_angles := Vector3(-52.0, -38.0, 0.0)
@export var ramp_pitch: float = -18.0


func _ready() -> void:
	$Sun.rotation_degrees = sun_angles
	$Props/Ramp.rotation_degrees = Vector3(ramp_pitch, 0.0, 0.0)
