extends SceneTree
## Photographs a Sneak going to glass, so the one claim this ability makes can be looked at rather
## than taken on trust: **is it findable?**
##
## THE FAILURE THIS EXISTS TO CATCH IS THE ABILITY WORKING TOO WELL. Every other shot probe in this
## project photographs something that might be absent -- dust that did not spawn, a ring drawn at
## the wrong radius, cant with no colour in it. This one photographs something that might be
## *perfect*, which is a bug with no error message and no audit that can see it: `spotting.gd`
## will report the Sneak concealed either way, and a screenshot of an empty lawn is exactly what a
## working fade and a mouse that has been deleted both look like.
##
## So the shots are composed against the two backdrops the shader has to survive, and they are
## different problems rather than two samples of one:
##
##   ON FLAT GROUND (`fade_open_*.png`). Open dirt with nothing to distort, which is the case the
##   fresnel rim exists for: the only thing left of the mouse is its outline. If this frame shows a
##   clearly legible mouse the ability does not work, and `rim_strength` and `body_bleed` are the
##   two numbers that made it so. Both have already been turned down twice on the evidence of this
##   frame, which is the whole argument for the probe existing.
##
##   ACROSS AN EDGE (`fade_edge_*.png`). `fade_glass.gdshader` is a lens, and a lens is only ever
##   visible in what it bends -- so this run lays a black-and-white test card under the same spot
##   and photographs the same ability over it. A working veil visibly kinks the bars where the body
##   passes over them, and that kink is the tell the entire design rests on. An unbroken card means
##   the refraction is too weak to be beaten by looking, and the ability has no counterplay at all.
##
## THE PAIR IS THE POINT rather than either frame alone: the same veil has to be nearly perfect
## against flat ground and findable against pattern, and a single backdrop cannot show both.
##
## THE TRANSITION IS PHOTOGRAPHED TOO, at three frames across the quarter second the veil takes to
## arrive. A mouse that swaps between solid and glass between two frames reads as a draw error
## rather than as an ability, and the in-between frames are the only place that shows.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/fade_shot.gd
##
## Writes fade_*.png to the user data folder, next to the screenshot key's own evidence.

## Frames after the press. 0 is the solid mouse for reference, 4 and 9 catch the veil arriving,
## and 40 is well inside the ten seconds -- fully glass, doing nothing, which is the state a
## defender actually has to search.
const AT_FRAMES: Array[int] = [0, 4, 9, 40]

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var player := scene.get_node("Player") as Mouse
	var fade := player.get_node("Fade") as Fade
	if fade == null:
		print("FAIL -- the player carries no Fade control")
		quit()
		return
	var rig: Node3D = scene.get_node("CameraRig")
	# Closer than the slam shot's 5.5. The thing being judged is a body 32cm across and whether its
	# outline can be picked out; at the ordinary standoff a faded mouse is a dozen pixels and every
	# frame would pass.
	rig.set("zoom_idle", 4.0)
	rig.set("speed_zoom", false)
	player.set_class(MouseClass.SNEAK)

	# ONE SPOT FOR BOTH RUNS, with a test card laid under the second. Open lawn well clear of both
	# nests and the patio, which is where the other shot probes learned to stand.
	var spot := Vector3(6.0, 0.2, 6.0)
	await _sequence(scene, player, fade, rig, spot, "open")
	_lay_card(scene, spot)
	await _sequence(scene, player, fade, rig, spot, "edge")

	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()


## One backdrop, four frames.
func _sequence(
	scene: Node, player: Mouse, fade: Fade, rig: Node3D, at: Vector3, label: String
) -> void:
	player.global_position = at
	player.velocity = Vector3.ZERO
	# STILL, AND THAT IS THE HARD CASE ON PURPOSE. A moving lens is far easier to spot -- the
	# distortion travels across the ground behind it -- so photographing a walk would flatter the
	# shader. What a defender is really up against is a Sneak that has stopped.
	#
	# AND THE MOUSE KEEPS ITS PHYSICS PROCESS, which the other shot probes all turn off and which
	# would have made this one photograph nothing at all. `slam_shot.gd` disables it so the real
	# cursor cannot capture over the top of the [InputFrame] it drives in; this probe drives no
	# input and calls the ability directly, so it has nothing to protect against -- while the veil's
	# whole clock, the material swap included, lives in `_tick_timers` on the physics tick.
	#
	# THE FIRST BUILD OF THIS PROBE COPIED THE LINE ANYWAY, and it produced a photograph that looked
	# plausible and was of the wrong thing: a mouse whose `is_faded()` was true, whose veil had
	# therefore never been put on, and which `grass_camouflage.gd` was dutifully drawing at the
	# concealed tenth of its team colour. A pale blue translucent mouse -- the exact look this
	# ability was built to replace, photographed and mistaken for it twice. The tell was in the
	# probe's own output: ten seconds of fade left after forty frames of it running.
	fade.set("_cooldown_left", 0.0)
	player.set_faded(0.0)
	# LONG ENOUGH FOR THE CAMERA TO ARRIVE, which six frames was not: `camera_rig.gd` chases the
	# mouse rather than being parented to it, so the reference frame of the first run was a
	# photograph of the lawn the player had just been teleported away from. A shot probe whose
	# control frame does not contain the subject cannot be compared to anything.
	for i in range(45):
		await process_frame

	if not fade.go_to_glass():
		print("FAIL -- %s: the fade was refused" % label)
		return
	print("fade[%s]: %.0fs of veil at %.1f,%.1f" % [label, fade.duration, at.x, at.z])

	for step in range(AT_FRAMES.max() + 1):
		if AT_FRAMES.has(step):
			RenderingServer.force_draw()
			root.get_texture().get_image().save_png(OUT + "fade_%s_%02d.png" % [label, step])
		await process_frame

	# Said out loud, because "the mouse is hard to see in this picture" and "the ability is running"
	# are two different claims and a screenshot only ever carries the first.
	print("  still faded: %s (%.1fs left)" % [player.is_faded(), player.fade_left()])


## A test card on the ground: black and white bars, laid under the spot the Sneak stands on.
##
## BUILT RATHER THAN FOUND, after two attempts at finding one. The patio rim is the longest straight
## edge on the map and backs onto a wall of shoulder-height grass, so the frame was a lens held
## against a thicket -- and clutter cannot be seen to kink, which means it proves nothing either
## way. The nest pad is flat, painted and unmistakably straight, and is also where four bots stand:
## the photograph came back with three blue mice in it and no way to tell which was the subject.
##
## The question this probe asks is a question about a SHADER -- does a straight line bend as it
## passes behind a faded mouse -- and it does not need the arena's help to ask it. A card is the
## same in every build, has known geometry, and puts the answer in the middle of the frame.
##
## HIGH CONTRAST AND FINE PITCH ON PURPOSE. Refraction displaces by a fraction of the screen; over
## a gentle gradient that displacement lands on a colour barely different from the one it left, and
## the effect is invisible for reasons that have nothing to do with its strength. Hard bars at a
## pitch near the size of the body are the case that shows the true magnitude.
func _lay_card(scene: Node, at: Vector3) -> void:
	var card := Node3D.new()
	card.name = "FadeTestCard"
	scene.add_child(card)
	card.global_position = at - Vector3.UP * (at.y - 0.02)

	for index in range(12):
		var bar := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(3.0, 0.16)
		bar.mesh = quad
		var paint := StandardMaterial3D.new()
		paint.albedo_color = Color.WHITE if index % 2 == 0 else Color(0.06, 0.06, 0.07)
		paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bar.material_override = paint
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Flat on the ground, running across the camera's view.
		bar.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		bar.position = Vector3(0.0, 0.0, (float(index) - 5.5) * 0.32)
		card.add_child(bar)
