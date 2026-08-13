extends SceneTree
## Photographs the Sneak's dust screen, because its whole claim is a claim about what you can see.
##
## THE ONE QUESTION: **is anything actually hidden?** Every other property of this ability can be
## asserted headlessly -- the cooldown, the radius, the second it lasts, whether `spotting.gd` drops
## the contact -- and none of those is the ability. The ability is that a mouse standing in the
## cloud cannot be seen, and there is no way to check that except to put a mouse in the cloud and
## look at the frame.
##
## THE FAILURE IT IS COMPOSED AGAINST is the opposite of the one [StompDust] guards. That file
## carries a warning about a cloud that "closed into a single beige disc wider than the mouse and
## hid it completely", and tuned it out; this one has to close, and the way it fails is by being a
## pretty ring of puffs with a perfectly visible mouse in the middle of it. So the shot deliberately
## parks a second mouse dead centre and photographs the thickest moment.
##
## AND THE RIM IS PHOTOGRAPHED TOO, with a third mouse just outside the radius. A screen that hides
## the whole yard is as broken as one that hides nothing, and four metres is a starting number -- so
## the frame has to show where the cloud stops as well as that it starts.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/dust_shot.gd
##
## Writes dust_*.png to the user data folder.

## Frames after the press. 4 catches it blooming, 14 is about the thickest, 30 is near the end of
## the one second, and 70 is well after -- the yard should be completely clear again by then, which
## is the frame that proves the cloud goes away rather than merely thinning.
const AT_FRAMES: Array[int] = [4, 14, 30, 70]

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var player := scene.get_node("Player") as Mouse
	var dust := player.get_node("DustKick") as DustKick
	if dust == null:
		print("FAIL -- the player carries no DustKick control")
		quit()
		return
	var rig: Node3D = scene.get_node("CameraRig")
	# Wide enough that a four metre cloud and the ground outside it both fit in the frame -- the
	# rim is half the thing being judged.
	rig.set("zoom_idle", 9.0)
	rig.set("speed_zoom", false)
	player.set_class(MouseClass.SNEAK)

	var spot := Vector3(6.0, 0.2, 6.0)
	player.global_position = spot
	player.velocity = Vector3.ZERO

	# INSIDE AND OUTSIDE, which is the whole composition. `inside` is the claim; `outside` is the
	# control, and without it a photograph of a thick cloud proves only that dust was drawn.
	var inside := _mouse(scene, Team.RED, spot + Vector3(1.4, 0.0, 0.4))
	# Placed on the far side from the roster panel, which the first version was not: the control's
	# reference patch of ground landed on the HUD and the reading came back nonsense.
	var outside := _mouse(scene, Team.RED, spot - Vector3(dust.radius + 1.2, 0.0, 0.0))
	for i in range(45):
		await process_frame

	dust.set("_cooldown_left", 0.0)
	if not dust.kick():
		print("FAIL -- the kick was refused")
		quit()
		return
	print("dust: %.1fm screen, %.1fs" % [dust.radius, DustScreen.new().seconds])
	print("  inside  at %.2fm from the middle" % inside.global_position.distance_to(spot))
	print("  outside at %.2fm" % outside.global_position.distance_to(spot))

	var frames: Dictionary = {}
	for step in range(AT_FRAMES.max() + 1):
		if AT_FRAMES.has(step):
			RenderingServer.force_draw()
			var shot := root.get_texture().get_image()
			frames[step] = shot
			shot.save_png(OUT + "dust_%02d.png" % step)
		await process_frame

	# MEASURED, NOT LEFT TO THE EYE, and that is worth the twenty lines. "Both mice are hidden" and
	# "both mice are washed out but perfectly legible" look far more alike in a screenshot than they
	# do in a fight, and the second one is what the first three builds of [DustScreen] actually
	# produced -- a thick, convincing, entirely see-through cloud that read as working every time it
	# was looked at. The camera is fixed and the mice are placed by this file, so the pixel each one
	# stands on is knowable, and how much of its colour survives is the whole claim of the ability
	# stated as a number.
	_measure(frames, inside, "inside")
	_measure(frames, outside, "outside")

	# Said out loud, because a screenshot cannot carry the rule half of the ability.
	var clouds := get_nodes_in_group(DustScreen.SCREEN_GROUP)
	print("  clouds still standing after %d frames: %d" % [AT_FRAMES.max(), clouds.size()])
	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()


## How much of a mouse's own colour is left on screen at the thickest moment, against the frame
## taken after the cloud has gone.
##
## READ THROUGH THE CAMERA'S OWN PROJECTION rather than at a guessed pixel, so the number survives a
## change of zoom, of resolution or of where the shot is composed. A body sampled at its middle,
## which is the part a cloud has to cover -- an ability that hid a mouse's feet and left its head
## showing would score well on an average over the whole silhouette.
func _measure(frames: Dictionary, who: Mouse, label: String) -> void:
	var camera := root.get_viewport().get_camera_3d()
	if camera == null or not frames.has(AT_FRAMES.max()):
		return
	var head := who.global_position + Vector3.UP * 0.2
	if camera.is_position_behind(head):
		return
	var at := camera.unproject_position(head)
	var clear: Image = frames[AT_FRAMES.max()]
	var x := clampi(int(at.x), 0, clear.get_width() - 1)
	var y := clampi(int(at.y), 0, clear.get_height() - 1)
	# A patch of ground a body's width to the side: near enough to be under the same part of the
	# cloud, far enough to be off the mouse.
	var near_x := clampi(x + 55, 0, clear.get_width() - 1)
	var near_y := clampi(y + 20, 0, clear.get_height() - 1)

	# THE QUESTION IS "CAN YOU TELL SOMETHING IS THERE", NOT "HAS THIS PIXEL CHANGED COLOUR", and
	# the first version of this measured the second. It compared each frame's pixel against the same
	# pixel in clear air, which sounds equivalent and is not: dust laid over a mouse changes the
	# pixel by about as much as dust laid over grass does, so a fully hidden mouse and a bare patch
	# of lawn both scored 21% and the metric reported the ability broken while the screenshot showed
	# it working perfectly.
	#
	# So it is measured as CONTRAST AGAINST THE GROUND BESIDE IT, in the same frame. In clear air a
	# red mouse on a green lawn is a large difference; under a working screen the two pixels are the
	# same dust and the difference goes to nothing. That ratio is exactly what an eye looking for a
	# mouse is doing, it needs no reference colour, and it cannot be fooled by the cloud and the
	# subject happening to be similar colours.
	var bare := _apart(clear.get_pixel(x, y), clear.get_pixel(near_x, near_y))
	if bare < 0.02:
		print("  %s: nothing to measure -- it is the same colour as the ground beside it" % label)
		return

	for step: int in AT_FRAMES:
		var shot: Image = frames[step]
		var left := _apart(shot.get_pixel(x, y), shot.get_pixel(near_x, near_y))
		print("  %s at frame %02d: %.0f%% hidden" % [label, step, (1.0 - left / bare) * 100.0])


func _apart(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


## A bare mouse to hide. Built rather than spawned through the director, so the shot is not at the
## mercy of which seat a bot happened to take -- the same construction `slam_shot.gd` uses.
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
