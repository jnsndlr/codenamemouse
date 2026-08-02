extends SceneTree
## Leave a full match running and report what the bots actually DID.
##
##   godot --headless --path . --script tools/bot_soak.gd [seconds]
##
## WHY THIS EXISTS, AND WHY THE TWO AUDITS DO NOT COVER IT. tunnel_audit.gd and match_audit.gd ask
## whether the RULES hold: can this cell be dug, does that crew know about it, may this class do
## that. They are the right shape for a rule and the wrong shape for a behaviour, because almost
## every way an AI can be bad is perfectly legal. An Engineer that punches a three-tile pit, walks
## away, respawns and punches another one breaks no rule at all -- every dig is valid, every cell
## is correctly attributed, and match_audit's "an Engineer bot opens earth on its own" passes
## comfortably. It was also, for a while, exactly what the bots did: twenty-eight cells of tunnel
## spread across ELEVEN mouths in a minute, a yard full of holes that went nowhere.
##
## Four bugs came out of the first two runs of this file. Three of them were invisible by reading
## the code and instant in the numbers:
##
##   * the digger read its own steering back as its destination, and dug at a fourteenth speed
##   * it started a fresh hole every time a raid was interrupted, instead of using its own mouth
##   * a greedy one-cell stepper was doing the corridor navigation, and oscillated at every bend
##   * the frontier it walked to could be the cell it was already standing in, so it never left
##
## THE NUMBERS ARE THE POINT, not the pass. A soak over a live match is stochastic -- somebody gets
## scruffed at a different moment and the totals move -- so thresholds here are set where a
## BEHAVIOUR is broken rather than where it is merely worse than last time, and everything else is
## printed for a human to look at. The two things it will fail on are unambiguous: a bot frozen in
## place, and a network that is all entrances and no tunnel.

## How long to watch, in seconds, when the command line does not say.
const DEFAULT_SECONDS: float = 90.0
## How often to take a reading. Long enough that a bot walking normally covers real ground, short
## enough to see a corridor grow.
const SAMPLE: float = 5.0

## Less movement than this across a whole sample, in metres, is not walking.
const STALL_DISTANCE: float = 0.6
## Consecutive stalled samples before it counts as frozen rather than unlucky. Three samples is
## fifteen seconds of a mouse standing somewhere it did not mean to stand.
const STALL_SAMPLES: int = 3
## The intent of a bot whose job is to stand still. Everything else should be going somewhere.
const POST: String = "holding the nest"

## Below this many dug cells per shaft mouth, the crews are making pits rather than tunnels. Six is
## generous -- a corridor that reaches anything at all on this arena is dozens -- and it is set that
## low so this fails on the behaviour being broken rather than on a bad afternoon.
const MIN_CELLS_PER_MOUTH: float = 6.0

var _scene: Node
var _network: TunnelNetwork
var _director: MatchDirector
## bot -> where it was at the last reading.
var _was: Dictionary = {}
## bot -> how many readings in a row it has not moved for.
var _frozen: Dictionary = {}
var _findings: Array[String] = []


func _initialize() -> void:
	var seconds := DEFAULT_SECONDS
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and args[0].is_valid_float():
		seconds = maxf(SAMPLE, args[0].to_float())

	_scene = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	# The camera, the HUD and the grass are the expensive half of the scene and none of them
	# changes what a bot decides. Rock and boulders STAY -- unlike in the audits, where they are
	# stripped so a seeded seam cannot fail a rule check for the wrong reason. Here they are the
	# most interesting thing on the map: going round a seam, or under it, is most of what an
	# Engineer's route-finding has to get right, and a soak on clean earth would prove nothing.
	for path: String in ["CameraRig", "HUD", "LookPanel", "Surface/Rocks", "Surface/Grass", "FallGuard"]:
		var node: Node = _scene.get_node_or_null(path)
		if node != null:
			node.free()
	root.add_child(_scene)
	await process_frame
	await physics_frame

	_network = _scene.get_node("Tunnels") as TunnelNetwork
	_director = _scene.get_node("MatchDirector") as MatchDirector

	print("=".repeat(78))
	print("BOT SOAK -- %d seconds, crew of %d a side" % [int(seconds), _director.crew_size])
	print("=".repeat(78))

	var samples := int(ceilf(seconds / SAMPLE))
	for i in range(samples):
		await _advance(SAMPLE)
		_report(float(i + 1) * SAMPLE)

	_verdict()


# --------------------------------------------------------------------------------- readings


func _report(at: float) -> void:
	var cells := 0
	var per: Array[String] = []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		var count := _network.cell_count(plane)
		cells += count
		per.append("p%d:%d" % [plane, count])
	var mouths := _network.shaft_cells(0).size()

	print("")
	print("-- t=%3ds   %d cells (%s)   %d mouths   %s cells/mouth   %d-%d" % [
		int(at), cells, " ".join(per), mouths,
		"--" if mouths == 0 else "%.1f" % (float(cells) / float(mouths)),
		_director.score_of(Team.BLUE), _director.score_of(Team.RED)
	])

	for node in root.get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var bot := node as Bot
		if bot == null:
			continue
		var moved := _step(bot)
		print("   %-10s %-4s %-9s plane %d   %5.1fm  %s" % [
			bot.name, MouseClass.tag_of(bot.mouse_class),
			"defender" if bot.role == Bot.DEFENDER else "raider",
			bot.get_plane(), moved, bot.get_intent()
		])


## How far this bot travelled since the last reading, and whether that is a problem.
##
## A SCRUFFED MOUSE IS NOT STALLED -- it is lying where it fell, on purpose, and counting that
## would make the check fire hardest during the most normal thing in a match. Nor is a defender at
## its post: standing near its own nest IS the job, and an early version of this flagged the one
## bot behaving correctly. Everything else that has not moved in fifteen seconds is stuck on
## something, and every AI bug this file has found so far looked exactly like that.
func _step(bot: Bot) -> float:
	var now := bot.global_position
	var moved := 0.0
	if _was.has(bot):
		moved = (now - (_was[bot] as Vector3)).length()
	else:
		moved = INF
	_was[bot] = now

	var excused := bot.is_scruffed() or bot.get_intent() == POST
	if excused or moved > STALL_DISTANCE:
		_frozen[bot] = 0
		return 0.0 if moved == INF else moved

	var strikes := int(_frozen.get(bot, 0)) + 1
	_frozen[bot] = strikes
	if strikes == STALL_SAMPLES:
		_findings.append("%s (%s) froze for %ds while '%s' on plane %d" % [
			bot.name, MouseClass.tag_of(bot.mouse_class),
			int(STALL_SAMPLES * SAMPLE), bot.get_intent(), bot.get_plane()
		])
	return moved


# ---------------------------------------------------------------------------------- verdict


func _verdict() -> void:
	var cells := 0
	var deepest := 0
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		var count := _network.cell_count(plane)
		cells += count
		if count > 0:
			deepest = plane
	var mouths := _network.shaft_cells(0).size()

	print("")
	print("=".repeat(78))
	print("%d cells, %d mouths, deepest plane %d" % [cells, mouths, deepest])
	for side in [Team.BLUE, Team.RED]:
		# How far the crew's own network actually reaches from home. A tunnel that never leaves
		# the doorstep is the failure that "cells were dug" cannot see.
		var home := _director.nest_of(side).global_position
		var reach := 0.0
		var owned := 0
		for plane in range(1, TunnelNetwork.PLANE_COUNT):
			for cell: Vector2i in _network.known_tunnel_cells(plane, side):
				owned += 1
				var at := _network.cell_to_world(plane, cell)
				reach = maxf(reach, Vector2(at.x - home.x, at.z - home.z).length())
		print("   %-4s knows %3d cells, reaching %.0fm from its nest" % [
			Team.name_of(side), owned, reach
		])

	# A crew with no tunnel at all is a different report from a crew with a bad one, and only the
	# second is a failure of the digging. Nothing dug usually means nothing got the chance to.
	if mouths > 0 and float(cells) / float(mouths) < MIN_CELLS_PER_MOUTH:
		_findings.append(
			"the crews are digging pits, not tunnels (%.1f cells per mouth, want %.0f)" % [
				float(cells) / float(mouths), MIN_CELLS_PER_MOUTH
			]
		)

	print("=".repeat(78))
	if _findings.is_empty():
		print("NOTHING WEDGED. Read the numbers above -- they are the actual output.")
		quit(0)
		return
	for finding: String in _findings:
		print("PROBLEM: %s" % finding)
	print("=".repeat(78))
	quit(1)


func _advance(seconds: float) -> void:
	for i in range(maxi(1, int(ceilf(seconds * 60.0)))):
		await physics_frame
