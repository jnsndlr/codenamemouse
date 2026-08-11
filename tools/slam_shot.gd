extends SceneTree
## Photographs a Slam frame by frame, so what the ability looks like can be looked at rather than
## taken on trust -- the dust ring, the camera thump, and the two mice leaving.
##
## THREE THINGS THAT ONLY A PICTURE CAN SETTLE, and the audit checks none of them:
##
##   DOES THE RING READ AS THE REACH? [Slam] draws [StompDust] at its own radius rather than the
##   stomp's, on the theory that a player learns how far a slam goes by watching where the dust
##   stops. If the ring is wider than the shove or narrower than it, the effect is teaching the
##   wrong number -- and a wrong number taught by a particle effect is the hardest kind to unlearn.
##
##   DOES IT SWALLOW THE MOUSE? This is the specific failure [StompDust] carries a warning about:
##   the first stomp cloud closed into a single beige disc wider than the Brute and hid the thing
##   you were meant to be watching. Slam draws the same puffs at a wider spread, which is the exact
##   change that could bring it back.
##
##   IS IT A CIRCLE? The audit proves the RULE is a circle by shoving a mouse standing behind the
##   Brute. Whether it LOOKS like one is a different question, and the answer is in the dust.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/slam_shot.gd
##
## Writes slam_*.png to the user data folder, next to the screenshot key's own evidence.

## Frames after the press. The first catches the ring leaving, the last catches it gone -- the
## same three the stomp is photographed at, so the two effects can be held side by side.
const AT_FRAMES: Array[int] = [3, 10, 22]

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var player := scene.get_node("Player") as Mouse
	var slam := player.get_node("Slam") as Slam
	var rig: Node3D = scene.get_node("CameraRig")
	rig.set("zoom_idle", 5.5)
	rig.set("speed_zoom", false)
	player.set_class(MouseClass.BRUTE)

	# Open lawn, well clear of both nests and the patio -- the same lesson the stomp shot learned
	# the hard way. A shot with a refusal printed across it is a shot you stop believing.
	var spot := Vector3(6.0, 0.2, 6.0)
	player.global_position = spot
	player.velocity = Vector3.ZERO

	# ONE IN FRONT AND ONE BEHIND, which is the whole picture. A slam is the only attack in the
	# game with no arc, and a screenshot of two mice leaving in opposite directions is the only
	# way to see that without reading the source.
	var ahead := _mouse(scene, Team.RED, spot + Vector3(0.0, 0.0, -0.9))
	var behind := _mouse(scene, Team.RED, spot + Vector3(0.0, 0.0, 1.0))
	await create_timer(1.4).timeout

	# Off physics before an intent is driven in: the player recomputes its aim from the real cursor
	# every tick and would capture over the top of the frame. Same reason the audits do it.
	player.set_physics_process(false)
	slam.set("_cooldown_left", 0.0)

	var frame := InputFrame.new()
	frame.aim_point = player.global_position
	frame.set_pressed(InputFrame.Action.SLAM, true)
	frame.set_held(InputFrame.Action.SLAM, true)
	player.call("drive", frame)
	slam._physics_process(0.0)

	# Said out loud, because "there is dust in the picture" and "the ability fired" are two
	# different claims and a screenshot only carries the first.
	print("slam: ring drawn at %.2fm, shove %.1f (about %.2fm of travel)" % [
		slam.radius, slam.knockback, slam.knockback / maxf(ahead.knock_damping, 0.01)
	])

	for step in range(AT_FRAMES.max() + 1):
		await process_frame
		if AT_FRAMES.has(step):
			RenderingServer.force_draw()
			root.get_texture().get_image().save_png(OUT + "slam_%02d.png" % step)

	# Where they ended up, so the picture and the arithmetic can be checked against each other.
	await create_timer(0.6).timeout
	print("  ahead  moved %.2fm" % ahead.global_position.distance_to(spot + Vector3(0.0, 0.0, -0.9)))
	print("  behind moved %.2fm" % behind.global_position.distance_to(spot + Vector3(0.0, 0.0, 1.0)))
	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()


## A bare mouse to be shoved. Built rather than spawned through the director, so the shot is not
## at the mercy of which seat a bot happened to take.
func _mouse(scene: Node, side: int, at: Vector3) -> Mouse:
	var mouse := Mouse.new()
	mouse.name = "Target%s%d" % [Team.name_of(side), randi() % 1000]
	mouse.team = side

	# Before it enters the tree: `@onready var _visual := $Visual` resolves the instant it does.
	var visual := Node3D.new()
	visual.name = "Visual"
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.16
	capsule.height = 0.4
	body.mesh = capsule
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Team.color_of(side)
	body.material_override = skin
	body.position.y = 0.2
	visual.add_child(body)
	mouse.add_child(visual)

	var shape := CollisionShape3D.new()
	var hull := CapsuleShape3D.new()
	hull.radius = 0.16
	hull.height = 0.4
	shape.shape = hull
	shape.position.y = 0.2
	mouse.add_child(shape)

	mouse.position = at
	scene.add_child(mouse)
	return mouse
