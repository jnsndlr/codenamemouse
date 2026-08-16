extends SceneTree
## Does a stroke cut continuously arrive continuously, cost what it should, and change nothing else?
##
##   godot --headless --path . --script tools/carve_probe.gd
##
## WHAT CARVING IS ALLOWED TO CHANGE, AND WHAT IT IS NOT. A carve is meant to be the LOOK of a
## stroke arriving, and nothing else: the same metre of corridor, for the same time held, opening
## the same cells at the same moment it always did. Everything the game is balanced on hangs off
## `dig_segment` -- what a stroke costs, what it opens, who learns of it, what routing believes --
## so the interesting question is not whether the earth comes out, it is whether ANYTHING ELSE
## moved while it did.
##
## The five, in the order they would bite:
##
##   GROWS     Ground part-way along a carve reads as dug, and ground past its end does not. If
##             this fails there is no feature.
##   OFFERS    The stroke being carved still offers itself. This is the one that broke first: a
##             carve makes its own stroke's earth read as gone, so `opens_ground` refused it, the
##             target reset, and the dig cancelled itself a few centimetres short every time.
##   COSTS     A carve claims no cells and teaches no crew. The economy is `dig_segment`'s alone.
##   KEEPS     Earth that has come out stays out, and a stroke picked up again resumes rather than
##             restarting. This is the rule that changed: a carve used to be abandoned the moment
##             the button came up, which filled the trench back in under whoever was standing in it.
##   IMMUTABLE The same claim asked of the field rather than of one stroke, and asked of the worst
##             thing a player can do to it: a cursor swept across half a dozen strokes with the
##             button down, jumping back and forth, asking for less than has already been given,
##             committing some and abandoning others. Not one texel of the plane may close at any
##             point in that. A per-stroke check cannot see the failure this would catch, because
##             the ways a carve used to close ground were all about the OTHER stroke -- the one the
##             cursor moved to.
##   PRICE     What eight rebuilds a stroke actually costs, against the one it replaces.

const PLANE: int = 1


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	var network := scene.get_node("Tunnels") as TunnelNetwork
	network.rock_density = 0.0
	(scene.get_node("MatchDirector") as MatchDirector).crew_size = 1
	root.add_child(scene)
	await process_frame
	await process_frame

	var failures := 0
	failures += _check_grows(network)
	failures += _check_offers(network)
	failures += _check_costs(network)
	failures += _check_keeps(network)
	failures += _check_immutable(network)
	scene.free()
	await _report_price()

	print("")
	if failures == 0:
		print("=".repeat(78))
		print("CARVING HOLDS: the earth arrives continuously and nothing else moved with it.")
		print("=".repeat(78))
	else:
		printerr("%d carving checks FAILED" % failures)
	quit(0 if failures == 0 else 1)


## GROWS. Part-cut ground is dug ground, and only as far as it has been cut.
func _check_grows(network: TunnelNetwork) -> int:
	print("")
	print("-- grows")
	var at := Vector2(-16.0, -16.0)
	var angle := 0
	var id := TunnelNetwork.segment_id(at, angle)
	var bad := 0

	for along: float in [0.25, 0.5, 0.75]:
		network.carve(PLANE, id, along)
		# A hair inside what has been cut, and a hair past it. Half a texel of margin either way,
		# since `carve` snaps to the grid it can actually draw.
		var inside := at + Vector2(along - TunnelContour.TEXEL, 0.0)
		var beyond := at + Vector2(along + TunnelNetwork.SEG_HALF_WIDTH + 0.2, 0.0)
		if not network.is_cut_away(PLANE, network.world_to_cell(Vector3(inside.x, 0.0, inside.y))):
			# Asked of the field itself rather than of the cell, since a cell is a metre wide and a
			# carve is measured in centimetres.
			pass
		if network._is_earth(PLANE, inside):
			printerr("   %.2fm in, ground the carve has taken still reads as earth" % along)
			bad += 1
		if not network._is_earth(PLANE, beyond):
			printerr("   %.2fm in, ground the carve has NOT reached already reads as dug" % along)
			bad += 1
	if bad == 0:
		print("   ok -- dug as far as it has been cut, and no further")
	return bad


## OFFERS. A stroke must not talk itself out of being finished.
func _check_offers(network: TunnelNetwork) -> int:
	print("")
	print("-- offers")
	var at := Vector2(-16.0, -12.0)
	var angle := 0
	var id := TunnelNetwork.segment_id(at, angle)
	var bad := 0
	for along: float in [0.125, 0.5, 0.875, 1.0]:
		network.carve(PLANE, id, along)
		if not network.opens_ground(PLANE, at, angle):
			printerr("   %.3fm in, the stroke being carved stopped offering itself" % along)
			bad += 1
	# And the finish still lands.
	if not network.dig_segment(PLANE, at, angle, Team.BLUE):
		printerr("   the stroke refused to commit after being carved end to end")
		bad += 1
	if network.carving(PLANE).has(id):
		printerr("   committing the stroke left its carve behind")
		bad += 1
	if bad == 0:
		print("   ok -- carved end to end, still offered, still commits, carve retired")
	return bad


## COSTS. The economy belongs to `dig_segment` and a carve must not touch it.
func _check_costs(network: TunnelNetwork) -> int:
	print("")
	print("-- costs")
	var at := Vector2(-16.0, -8.0)
	var angle := 0
	var id := TunnelNetwork.segment_id(at, angle)
	var cells := network.dug_cells(PLANE).size()
	var strokes := network.segment_count(PLANE)
	var bad := 0

	network.carve(PLANE, id, 1.0)
	if network.dug_cells(PLANE).size() != cells:
		printerr("   a carve claimed %d cells" % [network.dug_cells(PLANE).size() - cells])
		bad += 1
	if network.segment_count(PLANE) != strokes:
		printerr("   a carve counted as a stroke")
		bad += 1
	if not network.graph().route(PLANE, Vector2i(-16, -8), PLANE, Vector2i(-15, -8)).is_empty():
		printerr("   routing walked through ground that is only part cut")
		bad += 1
	if bad == 0:
		print("   ok -- no cells, no strokes, no routes: %d cells before and after" % cells)
	return bad


## KEEPS. Earth that has come out stays out, and a stroke picked up again resumes.
##
## THE RULE THIS REPLACED SAID THE OPPOSITE, and read as a bug in two different voices: a trench
## that filled itself in when the button came up, and -- reported as something else entirely -- a
## mouse falling through the floor at the edge of a dig, which is what happens to anybody standing in
## a trench that closes on a plane with no world beneath it.
func _check_keeps(network: TunnelNetwork) -> int:
	print("")
	print("-- keeps")
	var at := Vector2(-16.0, -4.0)
	var id := TunnelNetwork.segment_id(at, 0)
	var before := _picture(network)
	# WITH A CREW, because the picture being compared is the cutaway and the cutaway is per crew.
	# A teamless carve is nobody's and shows in nobody's lid, which would make this check compare
	# two identical pictures and call it a pass.
	network.carve(PLANE, id, 0.6, Team.BLUE)
	var during := _picture(network)
	# What letting go and pressing again looks like from here: the same stroke, asked for less than
	# it has already given. It must neither put earth back nor charge for the metre twice.
	network.carve(PLANE, id, 0.2, Team.BLUE)
	var after := _picture(network)

	var bad := 0
	if during == before:
		printerr("   carving 0.6m changed nothing in the field at all")
		bad += 1
	if after != during:
		printerr("   coming back to a part-cut stroke moved earth (%d texels differ)" % [
			_differences(during, after)
		])
		bad += 1
	# Snapped down to the texel the field can actually draw, which is what `carve` stored.
	var want := floorf(0.6 / TunnelContour.TEXEL) * TunnelContour.TEXEL
	if not is_equal_approx(network.carved_along(PLANE, id), want):
		printerr("   the stroke forgot how far it had been cut: %.3fm" % [
			network.carved_along(PLANE, id)
		])
		bad += 1
	if bad == 0:
		print("   ok -- %d texels opened, all of them still open, resumed at %.3fm" % [
			_differences(before, during), network.carved_along(PLANE, id)
		])
	return bad


## IMMUTABLE. Sweeping a held cursor around must never close a texel that was open.
##
## COUNTED OVER THE WHOLE PLANE, not over the stroke being asked about, which is the point of having
## this as well as KEEPS. Every way a carve used to close ground was a side effect on a stroke the
## cursor had just LEFT -- re-keying to a new id dropped the old one, shrinking un-cut the tail --
## so the only check that can see it is one watching all of the earth while the aim moves.
func _check_immutable(network: TunnelNetwork) -> int:
	print("")
	print("-- immutable")
	var open := _open(network)
	var low := open
	var bad := 0
	var ids: Array[int] = []
	for i in range(6):
		# A fan of strokes off one spot, close enough together that their capsules overlap, which is
		# what makes a stroke's tail somebody else's field and a dropped carve somebody else's hole.
		ids.append(TunnelNetwork.segment_id(Vector2(-16.0, 4.0 + float(i) * 0.5), i * 5))

	# The sweep: forward, back to a stroke already part cut and asked for LESS, a commit in the
	# middle of it, and two left half done at the end.
	var script: Array = [
		[0, 0.375], [1, 0.25], [2, 0.5], [1, 0.125], [0, 0.75], [3, 0.625],
		[2, 0.25], [4, 1.0], [0, 0.5], [5, 0.875], [3, 0.25], [1, 0.75],
	]
	for step: Array in script:
		var id: int = ids[step[0] as int]
		network.carve(PLANE, id, step[1] as float, Team.BLUE)
		var now := _open(network)
		if now < open:
			printerr("   carving %.3fm of stroke %d closed %d texels somewhere" % [
				step[1] as float, step[0] as int, open - now
			])
			bad += 1
		open = maxi(open, now)
	# And a commit part-way through the fan, which is the other id-shuffling moment.
	network.dig_segment(PLANE, TunnelNetwork.segment_origin(ids[2]),
		TunnelNetwork.segment_angle(ids[2]), Team.BLUE)
	var after := _open(network)
	if after < open:
		printerr("   committing a part-cut stroke closed %d texels" % [open - after])
		bad += 1
	if bad == 0:
		print("   ok -- %d steps over 6 overlapping strokes, %d texels opened, none ever closed" % [
			script.size() + 1, after - low
		])
	return bad


## How much of the plane reads as open, in texels.
func _open(network: TunnelNetwork) -> int:
	var count := 0
	for byte: int in _picture(network):
		if byte > 0:
			count += 1
	return count


## The plane's cutaway as bytes, which is the one picture every surface is built from.
func _picture(network: TunnelNetwork) -> PackedByteArray:
	return network._mask_images[PLANE].get_data()


func _differences(a: PackedByteArray, b: PackedByteArray) -> int:
	var count := 0
	for i in range(mini(a.size(), b.size())):
		if a[i] != b[i]:
			count += 1
	return count


## PRICE. A stroke arrives in eight steps instead of one; this is what the other seven cost.
##
## A NETWORK PER MEASUREMENT, for the reason island_probe.gd spells out at length: a dig
## re-assembles the whole plane's mesh from its chunks, so a timing taken on a map with more tunnel
## on it is measuring the map rather than the change.
func _report_price() -> void:
	print("")
	print("-- price")
	for carved: bool in [false, true]:
		var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
		var network := scene.get_node("Tunnels") as TunnelNetwork
		network.rock_density = 0.0
		(scene.get_node("MatchDirector") as MatchDirector).crew_size = 1
		root.add_child(scene)
		await process_frame
		await process_frame

		var at := Vector2(4.0, -14.0)
		var strokes := 0
		var elapsed := 0.0
		for i in range(16):
			var angle := (i * 3) % TunnelNetwork.ANGLE_STEPS
			var id := TunnelNetwork.segment_id(at, angle)
			var start := Time.get_ticks_usec()
			if carved:
				# The steps a held button really produces: the network snaps to its own grid, so
				# asking more often than this costs nothing and does nothing.
				for step in range(1, 9):
					network.carve(PLANE, id, TunnelNetwork.SEG_LENGTH * float(step) / 8.0)
			var cut := network.dig_segment(PLANE, at, angle, Team.BLUE)
			elapsed += float(Time.get_ticks_usec() - start) / 1000.0
			if not cut:
				break
			at = TunnelNetwork.segment_end(TunnelNetwork.segment_id(at, angle))
			strokes += 1
		print("   %-10s %6.2f ms over %d strokes (%.2f ms each)" % [
			"carved" if carved else "whole", elapsed, strokes,
			elapsed / maxf(1.0, float(strokes))
		])
		scene.free()
