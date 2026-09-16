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
## `peak_avg` averages Godot's reported one-second maxima; it is NOT average tick time.
## `peak_max` is the largest engine-reported physics peak seen in the window. The separate
## script-tick meter brackets node physics callbacks and reports true mean/p95/p99/max for
## those callbacks, excluding the engine's native physics/navigation step. Keep both: one
## measures the whole engine's spikes, the other measures the scripts' distribution.
## Godot 4.7.1 main/main.cpp publishes physics_process_max once per reporting second.

const DEFAULT_SECONDS: float = 150.0
const SAMPLE: float = 10.0
## When to turn the scenario's system off. Late enough that the match has dug a network of the
## size the complaint is about, so the row after it is the cost of everything ELSE at that size.
const CUT_AT: float = 90.0

class TickStart extends Node:
	var began: int = 0
	func _physics_process(_delta: float) -> void:
		began = Time.get_ticks_usec()

class TickEnd extends Node:
	var start: TickStart
	var samples: Array[float] = []
	func _physics_process(_delta: float) -> void:
		samples.append(float(Time.get_ticks_usec() - start.began) / 1000.0)


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
	var start := TickStart.new()
	start.process_physics_priority = -1000000
	root.add_child(start)
	var meter := TickEnd.new()
	meter.start = start
	meter.process_physics_priority = 1000000
	root.add_child(meter)

	print("scenario\tat\tpeak_avg\tpeak_max\tframes\tseg_p1")
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
		# Godot publishes the maximum over its last reporting second, not the last tick.
		var phys := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		phys_total += phys
		phys_max = maxf(phys_max, phys)
		frames += 1
		if since < SAMPLE and elapsed < seconds:
			continue
		since = 0.0
		var seg_all := 0
		for plane in range(TunnelNetwork.PLANE_COUNT):
			seg_all += network.segment_count(plane)
		print("%s\t%5.0fs\t%.2f\t%.2f\t%d\t%d" % [
			scenario, elapsed, phys_total / float(maxi(frames, 1)), phys_max, frames,
			network.segment_count(1),
		])
		if not meter.samples.is_empty():
			meter.samples.sort()
			var sum := 0.0
			for value: float in meter.samples:
				sum += value
			print("script ticks=%d avg=%.2f p95=%.2f p99=%.2f max=%.2f ms" % [
				meter.samples.size(), sum / meter.samples.size(),
				meter.samples[int((meter.samples.size() - 1) * 0.95)],
				meter.samples[int((meter.samples.size() - 1) * 0.99)], meter.samples[-1],
			])
			meter.samples.clear()
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
