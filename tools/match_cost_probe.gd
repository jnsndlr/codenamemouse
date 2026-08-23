extends SceneTree
## Does a match get more expensive to SIMULATE the longer it runs, and where does that go?
##
##   godot --headless --path . --script tools/match_cost_probe.gd [seconds]
##
## The complaint this exists for is "it starts to lag, especially on plane 1". `dig_cost_probe`
## prices one stroke in isolation and `underground_frame_probe` photographs a frame that is already
## dug; neither watches the bill grow under a match that is playing itself. This runs the real
## arena with its real bots and samples the simulation cost against what has been dug, so the shape
## of the curve is visible rather than inferred.
##
## HEADLESS ON PURPOSE, unlike the frame probes. Everything here is main-thread simulation --
## physics, bot decisions, the dig -- and stripping the renderer removes the one term that is
## bounded by the refresh interval and would otherwise flatten every row into it.
##
## PHYSICS TIME IS THE COLUMN THAT MATTERS. `underground_frame_probe` measured plane 1 with the
## bots disabled and physics fell from 11.6ms to 1.1ms, so the sim -- not the drawing -- is what
## is close to the tick budget down there. What this adds is whether it climbs.

const DEFAULT_SECONDS: float = 150.0
const SAMPLE: float = 10.0
## When to turn the scenario's system off. Late enough that the match has dug a network of the
## size the complaint is about, so the row after it is the cost of everything ELSE at that size.
const CUT_AT: float = 90.0


func _initialize() -> void:
	var seconds := DEFAULT_SECONDS
	var scenario := "baseline"
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		scenario = args[0]
	if args.size() > 1:
		seconds = maxf(args[1].to_float(), SAMPLE)

	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var network := scene.get_node("Tunnels") as TunnelNetwork

	print("scenario\tat\tphys_avg\tphys_max\tframes\tseg_p1")
	var elapsed := 0.0
	var since := 0.0
	var cut := false
	var phys_total := 0.0
	var phys_max := 0.0
	var frames := 0
	while elapsed < seconds:
		await process_frame
		var delta := root.get_process_delta_time()
		elapsed += delta
		since += delta
		# AVERAGED OVER THE WINDOW, not read once at the end of it. The monitor reports the LAST
		# frame, and a single frame either did or did not contain a dig commit -- sampled once every
		# ten seconds that is a coin toss printed to two decimal places, which is what the first
		# version of this probe did and why its rows bounced between 29 and 92.
		var phys := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		phys_total += phys
		phys_max = maxf(phys_max, phys)
		frames += 1
		if since < SAMPLE:
			continue
		since = 0.0
		var seg_all := 0
		for plane in range(TunnelNetwork.PLANE_COUNT):
			seg_all += network.segment_count(plane)
		print("%s\t%5.0fs\t%.2f\t%.2f\t%d\t%d" % [
			scenario, elapsed, phys_total / float(maxi(frames, 1)), phys_max, frames,
			network.segment_count(1),
		])
		if not cut and elapsed >= CUT_AT:
			cut = true
			_apply(scenario, scene)
		phys_total = 0.0
		phys_max = 0.0
		frames = 0
	quit()


func _apply(scenario: String, scene: Node) -> void:
	match scenario:
		"baseline":
			pass
		"bots":
			for node: Node in get_nodes_in_group(Mouse.MOUSE_GROUP):
				if node.name != "Player":
					node.process_mode = Node.PROCESS_MODE_DISABLED
		"think":
			# The bots keep their bodies, their collisions and their last destination; what stops
			# is the ranking and the routing. Splits "the AI is expensive" into which half.
			for node: Node in get_nodes_in_group(Mouse.MOUSE_GROUP):
				var bot := node as Bot
				if bot != null:
					bot.think_seconds = 99999.0
		"dig":
			for node: Node in get_nodes_in_group(Mouse.MOUSE_GROUP):
				var digger := node.get_node_or_null(^"DigController")
				if digger != null:
					(digger as Node).process_mode = Node.PROCESS_MODE_DISABLED
		"sight":
			for node: Node in get_nodes_in_group(&"tunnel_sight"):
				node.process_mode = Node.PROCESS_MODE_DISABLED
		"spotting":
			for node: Node in get_nodes_in_group(&"spotting"):
				node.process_mode = Node.PROCESS_MODE_DISABLED
		_:
			push_error("match_cost_probe: unknown scenario '%s'" % scenario)
