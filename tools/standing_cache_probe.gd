extends SceneTree
## Can the remembered standing point go stale? Checked against a live match, not reasoned about.
##
##   godot --headless --path . --script tools/standing_cache_probe.gd [seconds]
##
## [member TunnelNetwork._standing_at] is what makes bot routing affordable -- one `RoutePlanner.plan`
## fell from 6.8ms to 0.23ms with it -- and it is exactly the kind of cache whose failure is silent
## and nasty: a stale waypoint is a point in solid earth, so the bot walks into a wall and grinds
## there, and nothing errors. The two ways it can rot are a stroke changing which cells it reaches
## and a rock coming or going, and both are edits a live match makes constantly.
##
## SO THE MATCH IS THE SUBJECT, not a scripted sequence. Bots dig, cave in, shore up and break rock
## on their own schedule; every few seconds every remembered answer is compared against the one the
## uncached path computes right now. A single disagreement fails the run and names the cell.
##
## AND THE LIVE MATCH IS THE SECOND CHECK, NOT THE FIRST, because on its own it is a check that
## cannot fail -- which is this project's most-repeated bug and was this probe's first draft. Ripping
## the `erase` out of `_occupy` and watching a two-minute soak stay green is what proved it: for a
## remembered answer to rot, a bot has to have asked about a cell, a later stroke has to reach that
## same cell, AND the new stroke has to move the deepest point in it. The bots dig at the frontier
## and route through corridors behind it, so the three coincide rarely enough that two minutes of
## real play never produced one.
##
## SO THE SUBJECT IS BUILT RATHER THAN WAITED FOR. `_deliberate` asks about a run of cells, digs a
## second stroke straight through them, and asks again -- which is the collision the soak was
## failing to arrange, made to happen on purpose. It fails immediately if either `erase` is missing,
## and that is verified by removing them; the soak then runs afterwards for the cases a scripted
## sequence would not think of (a cave-in, a shored cell, a Brute taking a lobe out of a rock).

const DEFAULT_SECONDS: float = 120.0
const SWEEP: float = 8.0


func _initialize() -> void:
	var seconds := DEFAULT_SECONDS
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		seconds = maxf(args[0].to_float(), SWEEP)

	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var network := scene.get_node("Tunnels") as TunnelNetwork

	var wrong := _deliberate(network)
	if wrong > 0:
		print("\n=== the built subject already disagrees; the soak below cannot add to that. ===")
		quit(1)
		return

	var elapsed := 0.0
	var since := 0.0
	var sweeps := 0
	var compared := 0
	while elapsed < seconds:
		await process_frame
		var delta := root.get_process_delta_time()
		elapsed += delta
		since += delta
		if since < SWEEP:
			continue
		since = 0.0
		sweeps += 1
		var store: Array = network.get("_standing_at")
		for plane in range(TunnelNetwork.PLANE_COUNT):
			var kept: Dictionary = store[plane]
			var remembered := kept.duplicate()
			# Cleared so the next call has to do the work rather than hand back what is being
			# checked -- a comparison against itself is the check that cannot fail.
			kept.clear()
			for cell: Vector2i in remembered:
				var fresh: Vector3 = network.standing_point(plane, cell)
				compared += 1
				if fresh.distance_to(remembered[cell] as Vector3) > 0.0001:
					wrong += 1
					if wrong <= 8:
						print("STALE plane %d cell %s: remembered %s, actually %s (at %.0fs)" % [
							plane, cell, remembered[cell], fresh, elapsed])
		print("%4.0fs  swept %d remembered points, %d wrong so far" % [elapsed, compared, wrong])

	if wrong == 0:
		print("\nSTANDING CACHE OK -- a built subject, plus %d points over %d sweeps, none stale."
			% [compared, sweeps])
	else:
		print("\n=== %d STALE of %d compared. Bots are being sent into earth. ===" % [wrong, compared])
	quit(0 if wrong == 0 else 1)


## Ask about a run of cells, move the earth under them, and ask again.
##
## THE FIRST STROKE RUNS ALONG THE EDGE OF A ROW OF CELLS AND THE SECOND DOWN THE MIDDLE, which
## took two goes to get right and is the whole reason this function reports BROKEN rather than ok
## when nothing moves. `standing_point` keeps the DEEPEST of twenty-five samples, so merely adding
## a stroke to a cell changes nothing -- the first draft laid the second stroke across the first at
## an angle, every cell kept the sample it already had, and a subject in which the answer cannot
## move is a subject in which a missing invalidation cannot be seen. Off-spine first, through the
## middle second, is the arrangement where the right answer genuinely changes.
func _deliberate(network: TunnelNetwork) -> int:
	var cells: Array[Vector2i] = []
	# Along the shoulder of the row of cells centred on y = 4, so the deepest sample in each sits
	# well off the middle of the square.
	for step in range(6):
		network.dig_segment(1, Vector2(-6.0 + float(step) * 1.0, 4.45), 0, 0)
	for cell: Vector2i in network.dug_cells(1):
		cells.append(cell)
	if cells.is_empty():
		print("BROKEN: the built subject dug nothing, so nothing below was tested.")
		return 1

	var asked := {}
	for cell: Vector2i in cells:
		asked[cell] = network.standing_point(1, cell)

	# And now straight down the middle of the same row, which is deeper than the shoulder was and
	# so is where a mouse would now stand.
	for step in range(6):
		network.dig_segment(1, Vector2(-6.0 + float(step) * 1.0, 4.0), 0, 0)

	var moved := 0
	var stale := 0
	var store: Array = network.get("_standing_at")
	for cell: Vector2i in asked:
		var handed := network.standing_point(1, cell)
		var kept: Dictionary = store[1]
		var remembered: Variant = kept.get(cell)
		kept.erase(cell)
		var truth := network.standing_point(1, cell)
		if truth.distance_to(asked[cell] as Vector3) > 0.0001:
			moved += 1
		if handed.distance_to(truth) > 0.0001:
			stale += 1
			if stale <= 6:
				print("STALE (built) cell %s: handed out %s, actually %s" % [cell, handed, truth])
		if remembered == null:
			pass
	# A subject in which nothing moved would report a working cache no matter what it did.
	if moved == 0:
		print("BROKEN: the second stroke moved no standing point, so staleness was impossible.")
		return 1
	print("built subject (a stroke arriving): %d cells, %d genuinely moved, %d handed out stale"
		% [asked.size(), moved, stale])
	return stale + _deliberate_collapse(network, cells)


## And the other direction: a stroke LEAVING, which is [method TunnelNetwork._vacate] and a separate
## `erase`. Kept apart from the arrival case above because they are two invalidations and a subject
## that only ever adds earth proves one of them.
func _deliberate_collapse(network: TunnelNetwork, cells: Array[Vector2i]) -> int:
	var asked := {}
	for cell: Vector2i in cells:
		asked[cell] = network.standing_point(1, cell)

	# Take the middle strokes back out, which leaves the shoulder stroke as the deepest thing in the
	# cells they ran through -- so the answer must walk back off the centre line. `forget_segment`
	# rather than `collapse`, because a collapse closes the cells outright and a cell that is no
	# longer dug is not a cell anybody asks a standing point of: it removes the subject instead of
	# moving it, which is how the first version of this phase managed to test nothing.
	var dropped := 0
	for step in range(6):
		if network.forget_segment(1, Vector2(-6.0 + float(step) * 1.0, 4.0), 0):
			dropped += 1
	if dropped == 0:
		print("BROKEN: no stroke was removed, so a stroke leaving was never tested.")
		return 1

	var moved := 0
	var stale := 0
	var store: Array = network.get("_standing_at")
	for cell: Vector2i in asked:
		if not network.is_dug(1, cell):
			continue
		var handed := network.standing_point(1, cell)
		(store[1] as Dictionary).erase(cell)
		var truth := network.standing_point(1, cell)
		if truth.distance_to(asked[cell] as Vector3) > 0.0001:
			moved += 1
		if handed.distance_to(truth) > 0.0001:
			stale += 1
			if stale <= 6:
				print("STALE (collapse) cell %s: handed out %s, actually %s" % [cell, handed, truth])
	if moved == 0:
		print("BROKEN: the collapse moved no standing point, so staleness was impossible.")
		return 1
	print("built subject (a stroke leaving): %d genuinely moved, %d handed out stale"
		% [moved, stale])
	return stale
