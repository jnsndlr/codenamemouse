extends SceneTree
## Photographs a Second Wind across the two seconds it lasts, so the rings can be looked at rather
## than taken on trust.
##
## THE FAILURE THIS EXISTS TO CATCH IS THE ONE [StompDust] CARRIES A WARNING ABOUT. Its first build
## closed into a single beige disc wider than the Brute and hid the mouse completely -- and in prose
## "a ring of dust puffs" describes both the intended effect and the blob exactly as well. Rings
## running up a body are the same shape of risk: at the wrong radius they are a barrel the mouse is
## standing inside, and nothing in the audit can tell the difference.
##
## THREE THINGS ONLY A PICTURE SETTLES:
##
##   CAN YOU STILL SEE THE MOUSE? The wind is presentation on a mouse that is being chased. If the
##   effect obscures the thing it is attached to, it has made the fight harder to read at the exact
##   moment reading it matters.
##
##   IS IT LEGIBLE AGAINST THE LAWN? The rings are the stamina bar's pale gold, chosen because green
##   -- the reflex colour for a heal -- is the colour of the entire arena. Whether gold survives the
##   same test is a question about pixels.
##
##   DOES IT READ AS TWO SECONDS? The rings are the only thing on screen that says the ability is
##   still going, which is what makes the heal a window an opponent can act inside rather than a
##   number that changed. A last frame with rings still up would mean the picture outlives the rule.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/wind_shot.gd
##
## Writes wind_*.png to the user data folder, next to the screenshot key's own evidence.

## Seconds of wind still to run when each shot is taken, and the last one is the point of the list:
## at zero the ability is over, and a frame with rings still up would mean the picture outlives the
## rule.
##
## BY THE ABILITY'S OWN CLOCK RATHER THAN BY A FRAME COUNT, which the first version of this tool
## used and which measured nothing. The wind ticks on the PHYSICS tick and this loop runs on the
## render one -- uncapped in a windowed run, so 140 frames bought 1.3 seconds of a 2-second ability
## and the "it has finished" shot was taken two thirds of the way through it.
const AT_LEFT: Array[float] = [1.85, 1.0, 0.0]

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var player := scene.get_node("Player") as Mouse
	var wind := player.get_node("SecondWind") as SecondWind
	# Close, because the subject is 0.4m tall and the rings are drawn off its own radius. Set on the
	# RIG: it drives `Camera3D.size` off the player's speed every tick and would overwrite this.
	var rig: Node3D = scene.get_node("CameraRig")
	rig.set("zoom_idle", 4.5)
	rig.set("speed_zoom", false)
	player.set_class(MouseClass.GENERALIST)

	# Open lawn, well clear of both nests and the patio -- the same lesson the stomp and slam shots
	# learned the hard way. A shot with a refusal printed across it is a shot you stop believing.
	player.revive_at(Vector3(6.0, 0.2, 6.0), 0.0)
	player.velocity = Vector3.ZERO
	# Hurt, so the health bar over its head is drawn climbing while the rings run. The two halves of
	# the ability are meant to be legible in one frame.
	player.take_hit(60.0, player.global_position + Vector3(0.0, 0.0, 1.0), 0.0)
	await create_timer(1.0).timeout

	# Off physics before an intent is driven in: the player recomputes its aim from the real cursor
	# every tick and would capture over the top of the frame. Same reason the audits do it.
	player.set_physics_process(false)
	player.velocity = Vector3.ZERO

	var frame := InputFrame.new()
	frame.aim_point = player.global_position
	frame.set_pressed(InputFrame.Action.ABILITY, true)
	frame.set_held(InputFrame.Action.ABILITY, true)
	player.call("drive", frame)
	wind._physics_process(0.0)

	# Said out loud, because "there are rings in the picture" and "the ability fired" are two
	# different claims and only one of them is visible.
	print("wind: %.2fs to run, health %.2f, stamina %.2f" % [
		wind.wind_left(), player.get_health_ratio(), player.get_stamina_ratio()
	])

	for index in range(AT_LEFT.size()):
		var mark: float = AT_LEFT[index]
		while wind.wind_left() > mark:
			await process_frame
		# Two more frames past the end, so the last shot is of a mouse the ability has left rather
		# than of the tick it ended on.
		if mark <= 0.0:
			await process_frame
			await process_frame
		RenderingServer.force_draw()
		var shot := "wind_%d.png" % index
		root.get_texture().get_image().save_png(OUT + shot)
		print("%s: %.2fs left, health %.2f" % [shot, wind.wind_left(), player.get_health_ratio()])

	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()
