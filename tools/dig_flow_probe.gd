extends SceneTree
## Does a click open a metre at once, and does the class decide only how soon the next one comes?
##
##   godot --headless --path . --script tools/dig_flow_probe.gd
##
## THE MODEL THIS CHECKS, stated plainly because it is the third one and the other two are still
## legible in the file's history: the press cuts a whole stroke instantly, and the cost is a
## per-class recharge paid AFTERWARDS. Nothing is ever part-dug, nothing is ever un-dug, and no
## stretch of any dig has the player holding a button waiting to find out whether it worked.
##
##   INSTANT   One frame of a press opens a whole stroke. Not a bite of one, not a bar starting to
##             fill -- a committed metre, in the cell books, on the frame the button went down.
##   COOLDOWN  And the next one does not come until the recharge is up. Without this half, "instant"
##             is a mouse that opens the whole map on the frame it presses.
##   CLASSES   An Engineer's recharge is shorter than everybody else's, and that is now the ONLY
##             place the class spread lives -- the first stroke is instant for a Generalist too.
##             GDD section 4 (revised) wants roughly three to one, which is what dig_speed says.
##   REPEATS   Leaning on the button digs again the moment the recharge expires, rather than needing
##             a click per metre. Clicking and holding are the same rule at two speeds.
##   PAID      The recharge runs down wherever the cursor is pointing, so looking at rock or at
##             nothing is not a way to wait out your own cooldown for free.
##   STICKS    A frame that names no stroke while the hand is still does not lose the target.
##   REFUSES   ...but pointing somewhere else that names no stroke DOES, or a seam never gets to
##             say so. The two are the same -1 and only the cursor tells them apart.

const PLANE: int = 1


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	var network := scene.get_node("Tunnels") as TunnelNetwork
	network.rock_density = 0.0
	(scene.get_node("MatchDirector") as MatchDirector).crew_size = 1
	root.add_child(scene)
	await process_frame
	await physics_frame

	var player := scene.get_node("Player") as Mouse
	var controller: Node = player.get_node("DigController")

	# Standing still, on a layer, in a corridor of its own -- the physics and the controller both
	# driven by hand from here so a frame is a frame and nothing walks off between two of them.
	network.dig_shaft_down(0, Vector2i(0, 0))
	await process_frame
	await physics_frame
	player.set_physics_process(false)
	controller.set_physics_process(false)
	player.global_position = network.cell_to_world(PLANE, Vector2i(0, 0)) + Vector3.UP * 0.05
	controller._plane = PLANE
	player.set_class(MouseClass.ENGINEER)

	var failures := 0
	failures += _check_instant(player, controller, network)
	failures += _check_cooldown(player, controller, network)
	failures += _check_classes(player, controller, network)
	failures += _check_repeats(player, controller, network)
	failures += _check_paid(player, controller, network)
	failures += _check_sticks(player, controller, network)
	failures += _check_refuses(player, controller, network)

	print("")
	if failures == 0:
		print("=".repeat(78))
		print("DIGGING IS INSTANT: the click cuts, the class decides only when the next one may.")
		print("=".repeat(78))
	else:
		printerr("%d dig flow checks FAILED" % failures)
	scene.free()
	quit(0 if failures == 0 else 1)


## INSTANT. One frame of a press is a whole stroke, committed.
func _check_instant(player: Mouse, controller: Node, network: TunnelNetwork) -> int:
	print("")
	print("-- instant")
	_stand(player, network)
	var at := network.cell_to_world(PLANE, Vector2i(0, 2))
	var before := network.segment_count(PLANE)
	var cells := network.dug_cells(PLANE).size()
	_hold(player, controller, at, 1)

	var bad := 0
	if network.segment_count(PLANE) != before + 1:
		printerr("   one frame of a press cut %d strokes, not one" % [
			network.segment_count(PLANE) - before
		])
		bad += 1
	# A stroke rather than a carve: the cell books have to have moved, since that is what everything
	# downstream -- routing, the fog, the minimap, the wire -- is actually built on.
	if network.dug_cells(PLANE).size() <= cells:
		printerr("   the stroke opened no cells, so nothing downstream knows it happened")
		bad += 1
	if controller.cells_cut() < 1:
		printerr("   the cut went uncounted")
		bad += 1
	if bad == 0:
		print("   ok -- one frame, one stroke, %d cells opened" % [
			network.dug_cells(PLANE).size() - cells
		])
	return bad


## COOLDOWN. And nothing else opens until the recharge is up.
func _check_cooldown(player: Mouse, controller: Node, network: TunnelNetwork) -> int:
	print("")
	print("-- cooldown")
	_stand(player, network)
	var at := network.cell_to_world(PLANE, Vector2i(2, 0))
	# Fresh charge, then the stroke that spends it.
	_wait(player, controller, network, 120)
	_hold(player, controller, at, 1)
	var after := network.segment_count(PLANE)
	if controller.get_dig_charge() >= 1.0:
		printerr("   a stroke cost no recharge at all")
		return 1
	# Ten more frames of leaning on it, well inside an Engineer's half second.
	_hold(player, controller, at, 10)
	if network.segment_count(PLANE) != after:
		printerr("   %d more strokes landed inside the recharge" % [
			network.segment_count(PLANE) - after
		])
		return 1
	print("   ok -- the stroke landed, the next ten frames of holding did not")
	return 0


## CLASSES. The recharge is the only thing the class decides.
func _check_classes(player: Mouse, controller: Node, network: TunnelNetwork) -> int:
	print("")
	print("-- classes")
	var bad := 0
	# THE FIRST STROKE IS INSTANT FOR EVERYBODY, which is worth asserting rather than assuming: it
	# is the half of this design most likely to be quietly "fixed" back into a class-scaled bite.
	for mouse_class: int in [MouseClass.ENGINEER, MouseClass.GENERALIST]:
		player.set_class(mouse_class)
		_stand(player, network)
		_wait(player, controller, network, 200)
		var spot := Vector2i(0, -2) if mouse_class == MouseClass.ENGINEER else Vector2i(-2, 0)
		var before := network.segment_count(PLANE)
		_hold(player, controller, network.cell_to_world(PLANE, spot), 1)
		if network.segment_count(PLANE) == before:
			printerr("   %s did not open a stroke on the press" % MouseClass.name_of(mouse_class))
			bad += 1

	var fast := _gap(player, controller, network, MouseClass.ENGINEER, Vector2(1.0, 1.0))
	var plodding := _gap(player, controller, network, MouseClass.GENERALIST, Vector2(-1.0, -1.0))
	if fast < 0 or plodding < 0:
		printerr("   a held button did not produce two strokes: %d and %d" % [fast, plodding])
		return bad + 1
	if plodding <= fast:
		printerr("   a Generalist recharged as fast as an Engineer: %d against %d" % [
			plodding, fast
		])
		bad += 1
	# GDD section 4 (revised) puts everybody else at about three times an Engineer's dig time. The
	# band is loose because the answer is quantised to whole frames at either end.
	var ratio := float(plodding) / maxf(1.0, float(fast))
	if ratio < 2.0 or ratio > 4.0:
		printerr("   the spread is %.2fx, which is not the ~3x the classes are meant to be" % ratio)
		bad += 1
	if bad == 0:
		print("   ok -- both cut on the press; %d frames to recharge against %d (%.2fx)" % [
			plodding, fast, ratio
		])
	return bad


## REPEATS. Leaning on the button digs again the moment it can.
func _check_repeats(player: Mouse, controller: Node, network: TunnelNetwork) -> int:
	print("")
	print("-- repeats")
	player.set_class(MouseClass.ENGINEER)
	_stand(player, network)
	_wait(player, controller, network, 200)
	var before := network.segment_count(PLANE)
	# Two seconds of holding, against a half-second recharge: four strokes, give or take the frame
	# the first one lands on. Walking forward with the corridor, which is the point of the model.
	_advance(player, controller, network, Vector2(1.0, -1.0), 120)
	var cut := network.segment_count(PLANE) - before
	if cut < 3:
		printerr("   two seconds of holding produced %d strokes, so it is not repeating" % cut)
		return 1
	print("   ok -- %d strokes out of two seconds of one held button" % cut)
	return 0


## PAID. The recharge runs down wherever the cursor is, not only where it can dig.
func _check_paid(player: Mouse, controller: Node, network: TunnelNetwork) -> int:
	print("")
	print("-- paid")
	player.set_class(MouseClass.ENGINEER)
	_stand(player, network)
	_wait(player, controller, network, 200)
	_advance(player, controller, network, Vector2(-1.0, 1.0), 1)
	if controller.get_dig_charge() >= 1.0:
		printerr("   the setup stroke cost no recharge, so there is nothing to wait out")
		return 1
	# Half a second of pointing at open sky, well out of reach of any tunnel. If the cooldown only
	# ticked while a stroke was on offer, this would come back still spent.
	_hold(player, controller, Vector3(30.0, network.plane_y(PLANE), 30.0), 40, false)
	if controller.get_dig_charge() < 1.0:
		printerr("   pointing away froze the recharge at %.2f" % controller.get_dig_charge())
		return 1
	print("   ok -- the recharge ran down while the cursor was nowhere near anything diggable")
	return 0


## STICKS. A still hand keeps its stroke through a frame that names nothing.
func _check_sticks(player: Mouse, controller: Node, network: TunnelNetwork) -> int:
	print("")
	print("-- sticks")
	_stand(player, network)
	_hold(player, controller, network.cell_to_world(PLANE, Vector2i(-1, 2)), 4, false)
	if controller._target < 0:
		printerr("   the setup never found a stroke to hold on to")
		return 1
	# The flicker itself, forced: one frame in which the aim names no stroke while the cursor has
	# not moved. Straight into `_drifted`, since the conditions that really produce it are
	# floating-point ties nothing can arrange on purpose.
	if controller._drifted(-1, controller._aimed_at):
		printerr("   one frame of a still hand naming nothing dropped the stroke")
		return 1
	print("   ok -- the stroke survived a frame that named nothing")
	return 0


## REFUSES. A hand that has MOVED and names nothing has genuinely left.
func _check_refuses(player: Mouse, controller: Node, network: TunnelNetwork) -> int:
	print("")
	print("-- refuses")
	_stand(player, network)
	_hold(player, controller, network.cell_to_world(PLANE, Vector2i(1, -2)), 4, false)
	if controller._target < 0:
		printerr("   the setup never found a stroke to leave")
		return 1
	var away: Vector2 = controller._aimed_at + Vector2(controller.aim_slack * 4.0, 0.0)
	if not controller._drifted(-1, away):
		printerr("   pointing somewhere else that names nothing kept the old stroke -- a seam here")
		printerr("   would never get to refuse out loud")
		return 1
	print("   ok -- moving the cursor onto nothing gives the stroke up")
	return 0


## Frames between one stroke and the next, for a class leaning on the button. Counted from the
## first stroke THIS class cuts, since a recharge left running by the last one is not its to wear.
func _gap(
	player: Mouse, controller: Node, network: TunnelNetwork, mouse_class: int, heading: Vector2
) -> int:
	player.set_class(mouse_class)
	_stand(player, network)
	var seen := network.segment_count(PLANE)
	var first := -1
	for i in range(400):
		_advance(player, controller, network, heading, 1)
		var now := network.segment_count(PLANE)
		if now <= seen:
			continue
		seen = now
		if first < 0:
			first = i
		else:
			return i - first
	return -1


## Dig off down a heading, walking forward with the corridor as it opens.
##
## THE PLAYER HAS TO MOVE, and a probe that leaves it standing still is testing the reach rule
## rather than the dig. Reach is measured from the MOUSE to where the cut happens (GDD section 3,
## and see `_aimed_id`), so a corridor run out past `dig_reach` from a mouse rooted to the spot
## stops being diggable after two strokes -- which is the rule working, and is exactly the walking
## the instant dig exists to make possible. Stepping to the stroke's own origin each frame is the
## cheapest honest stand-in for a player following their own tunnel in.
func _advance(
	player: Mouse, controller: Node, network: TunnelNetwork, heading: Vector2, frames: int
) -> void:
	for i in range(frames):
		var here := player.global_position
		var aim := here + Vector3(heading.x, 0.0, heading.y).normalized() * 2.0
		_hold(player, controller, aim, 1, true, i == 0)
		if controller._target >= 0:
			var root := TunnelNetwork.segment_origin(controller._target)
			player.global_position = Vector3(
				root.x, network.plane_y(PLANE) + 0.05, root.y
			)


## Back to the shaft landing, which is dug from the first frame of every run and is the one spot
## a check can start from without depending on what the check before it opened.
func _stand(player: Mouse, network: TunnelNetwork) -> void:
	player.global_position = network.cell_to_world(PLANE, Vector2i(0, 0)) + Vector3.UP * 0.05


## Let the recharge run out with the button up, so a check starts from a known full charge.
func _wait(player: Mouse, controller: Node, network: TunnelNetwork, frames: int) -> void:
	_hold(player, controller, Vector3(40.0, network.plane_y(PLANE), 40.0), frames, false)


## Drive the controls for a stretch of frames, aimed at one spot.
func _hold(
	player: Mouse,
	controller: Node,
	at: Vector3,
	frames: int,
	holding: bool = true,
	press: bool = true
) -> void:
	for i in range(frames):
		var frame := InputFrame.new()
		frame.aim_point = at
		frame.set_held(InputFrame.Action.DIG, holding)
		frame.set_pressed(InputFrame.Action.DIG, holding and press and i == 0)
		player.drive(frame)
		controller._update_dig(frame, 1.0 / 60.0)
