extends SceneTree
## Does a second machine's keyboard actually move a mouse -- and only its own?
##
## `seat_audit.gd` proves two processes agree about who is sitting where. That is a table, and a
## table can be perfect while nothing is replicated at all: its two processes never leave the title
## screen, so no arena exists and no snapshot has ever been built. This file is the next question
## and it needs a real match at both ends, which is what `--play` is for.
##
## THE FAILURE THIS EXISTS FOR HAS ALREADY HAPPENED ONCE, by hand: a host logging 285 inputs a
## second while the mouse those inputs were driving stood perfectly still, because the seat held a
## `Bot` and a bot ignores an input frame. Every count on both ends was healthy. That is why the
## checks below are about POSITIONS and only incidentally about counts -- a pipe that moves bytes
## is not the claim, a pipe that moves the right mouse is.
##
## WHAT IT CANNOT SEE: latency, jitter, and anything about a real network. Both processes are on
## one machine over loopback, so this is an assertion about correctness and never about feel.
## Checkpoint 5 -- a friend, over the internet, for a full match -- is the only thing that answers
## the other question and no tool is going to answer it for us.
##
##   godot --headless --path . --script res://tools/replication_audit.gd

## Not the seat audit's port. The two suites are run back to back and a socket in TIME_WAIT from
## the previous one is a connection failure that reads exactly like a broken transport.
const PORT: int = 47871
## The arena, not the title screen -- a navmesh bake and thirty-odd scene resources longer than
## what `seat_audit.gd` waits for.
const BOOT_SECONDS: float = 14.0
## How long the client sits on the title screen after connecting, before entering the match.
##
## THE GAP IS THE POINT AND IT IS WHY THIS IS NOT ZERO. Connecting and entering a match are
## separate moments in the real product -- you join, you look at the menu, you press Play; or you
## quit to the title mid-evening and go back in. Everything the server says in between is said to a
## process with no arena in it. With no delay the client's scene load blocks its own main loop for
## long enough that the seating arrives *after* the arena is up, every time, and the suite passes
## on timing rather than on design.
const CLIENT_TITLE_SECONDS: String = "8"
## Long enough for five or six reports at `NetMatch.REPORT_SECONDS` once the client is actually in
## the arena, which is what makes the position statistics below mean anything. One sample is a
## coincidence.
##
## LENGTHENED AT M7 for the digging check. The autopilot spends its first fourteen seconds on the
## lawn -- that is where the position spread is earned, since a corridor is one cell wide -- then
## sinks a shaft and holds the dig button, and a Generalist takes about a second and a half per
## tile. A run that ends before it has opened one proves nothing about the half of the milestone
## this suite was extended for.
const PLAY_SECONDS: float = 54.0
## `--quit-after` counts FRAMES. ~150s at 60Hz: a backstop well past a run that needs about 50,
## since both processes are killed explicitly.
const LIFETIME_FRAMES: String = "9000"

## Nests sit at (-20, 0, -20) and (20, 0, 20), so the two crews start 56m apart. A mouse drawn in
## the wrong seat is out by tens of metres; the autopilot's own wandering is a fraction of that.
const CREWS_APART: float = 25.0
## How far the two ends may disagree about where one mouse is. Generous ON PURPOSE, and see
## `_centre` for why the comparison is between averages rather than between instants.
const AGREEMENT: float = 8.0
## A mouse that walked. The autopilot turns as it goes, so it circles rather than leaves; this is
## comfortably inside one lap and comfortably outside standing still.
const WANDERED: float = 5.0
## A mouse that did not. The host's own has no keyboard behind it, but it does share a nest with
## four bots that leave at the whistle, so it is allowed to be shoved a little.
const STOOD_STILL: float = 3.0

## Seconds the two ends' clocks may differ by. Both are sampled on their own five-second timer, so
## this is phase, not drift -- and the failure it exists to catch is out by minutes.
const CLOCK_DRIFT: int = 8
## Wedges the two ends' stores may differ by, for the same reason: a Scurry spent between the two
## reports is a real difference between two true readings.
const CHEESE_DRIFT: int = 4
## `MatchDirector.starting_cheese`. Duplicated rather than read, because the point of the check is
## that the number MOVED, and a constant that follows the game's own would move with it.
const STARTING_CHEESE: int = 20
## Health is 0..255 and regenerates, so two readings five seconds apart are legitimately unequal.
const HEALTH_DRIFT: int = 40
## How far either side of the client's own report to look for what its crew was allowed to know.
## Wide enough to cover both processes' report phase and the second it takes the fog to be sent;
## narrow enough that it is nowhere near the length of a match.
const FOG_GRACE_MS: int = 8000

var _failures: int = 0


func _initialize() -> void:
	await _play_a_match()

	print("")
	if _failures > 0:
		print("=== %d FAILED. What crosses the wire is not what is happening. ===" % _failures)
		quit(1)
		return
	print("==============================================================================")
	print("A SECOND KEYBOARD MOVES A SECOND MOUSE, and the host and the client agree which.")
	print("==============================================================================")
	quit()


func _play_a_match() -> void:
	print("-- a host and a client, both inside a real arena")

	var godot := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var host_log := _log_path("host")
	var join_log := _log_path("client")

	var host_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--host", str(PORT), "--play", "--audit-cheese", "--audit-log", host_log,
	])
	if host_pid <= 0:
		_broken("could not launch a host process")
		return
	# The host must be IN ITS ARENA, not merely bound, before the client knocks. A seating message
	# is sent the moment a peer joins and there is nothing to receive it until both ends have a
	# match loaded.
	await _wait(BOOT_SECONDS)

	var join_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--join", "127.0.0.1:%d" % PORT, "--play", CLIENT_TITLE_SECONDS,
		"--autopilot", "--audit-log", join_log,
	])
	if join_pid <= 0:
		OS.kill(host_pid)
		_broken("could not launch a client process")
		return

	await _wait(PLAY_SECONDS)
	var host_said := _read(host_log)
	var client_said := _read(join_log)
	OS.kill(join_pid)
	OS.kill(host_pid)
	await _wait(2.0)

	if host_said.is_empty() or client_said.is_empty():
		_broken("one of them wrote nothing -- it never got far enough to be judged")
		return

	_check_the_pipe(host_said, client_said)
	_check_the_mouse(host_said, client_said)
	_check_the_digging(host_said, client_said)
	_check_the_scoreboard(host_said, client_said)
	_check_the_cheese_world(host_said, client_said)
	_check_the_earth(host_said, client_said)


# ------------------------------------------------------------------------------ bytes are moving


## The cheap half. None of it proves anything about the game; all of it distinguishes "the wire is
## dead" from "the wire is lying", and those two want different fixes.
func _check_the_pipe(host_said: String, client_said: String) -> void:
	print("\n-- the wire")
	_check("the host is hosting", host_said.contains("hosting on %d" % PORT))
	_check("the client connected and was seated", client_said.contains("connected as peer")
		and host_said.contains("takes RED seat"))
	_check("the host has a full match to send", host_said.contains("for 10 mice"))

	var sent := _totals(host_said, "sent (\\d+) snapshots")
	var took := _totals(host_said, "took (\\d+) inputs")
	var got := _totals(client_said, "received (\\d+) snapshots")
	var drawn := _totals(client_said, "(\\d+) poses")
	_check("the host sent snapshots (%d)" % sent, sent > 0)
	_check("the client received them (%d)" % got, got > 0)
	# THE ONE THAT CATCHES A KEYING BUG. A snapshot carries ten poses and a client that recognises
	# none of the seat keys applies zero of them -- while still counting every packet as received,
	# which reads as a healthy connection and an empty world.
	_check("and applied about ten poses each (%d)" % drawn, drawn >= got * 8)
	_check("the host took the client's inputs (%d)" % took, took > 0)

	# MOVEMENT AND MELEE is what checkpoint 1 claims, and a swing is the only one of the two that
	# is an action rather than a position. The autopilot presses attack every couple of seconds;
	# for this to be non-zero the bit has to survive the frame, be applied to a seat, start a real
	# swing under the server's own rules, and come back down as a flag.
	var swings := _totals(client_said, "a swing in (\\d+) of them")
	_check("and its swings came back as swings (%d poses)" % swings, swings > 0)


# ------------------------------------------------------------------------ and they mean something


## The half that matters. Three positions are in play: where the client thinks its own mouse is,
## where the host thinks that same seat's mouse is, and where the host's own mouse is.
func _check_the_mouse(host_said: String, client_said: String) -> void:
	print("\n-- and a mouse at the other end of it")

	var client_here := _positions(client_said, "received.*mine at \\(([^)]*)\\)")
	var host_here := _positions(host_said, "sent.*mine at \\(([^)]*)\\)")
	var host_thinks := _positions(host_said, "drives RED seat \\d+ at \\(([^)]*)\\)")

	if client_here.size() < 3 or host_here.size() < 3 or host_thinks.size() < 3:
		_broken("not enough reports to judge (%d client, %d host, %d remote)"
			% [client_here.size(), host_here.size(), host_thinks.size()])
		return

	# THE ROUND TRIP, and the assertion the whole file is for. The client's keyboard is synthetic,
	# its mouse is a puppet that simulates nothing, and the only way that puppet can end up
	# somewhere else is: frame out, applied to a seat, simulated by the host, sent back as a pose.
	# Every one of those has to work for this number to be non-zero.
	_check("the client's mouse went somewhere (%.1fm)" % _spread(client_here),
		_spread(client_here) > WANDERED)

	# NOT THE HOST'S MOUSE, which is the mirroring bug written as a distance. A client that never
	# learns its seat falls back to blue 0 -- the host's chair -- and then draws its own body
	# standing exactly where the host is standing while its inputs move a mouse it cannot see.
	# Both ends look completely healthy from inside.
	var apart := _centre(client_here).distance_to(_centre(host_here))
	_check("it is not the host's mouse (%.1fm apart)" % apart, apart > CREWS_APART)

	# A CLIENT DRIVES ITS OWN CHAIR AND NOBODY ELSE'S. `_apply_input` looks the sender up in the
	# seat table and never reads a mouse id off the packet, so this is structural -- but it is
	# structural in one line that a refactor could quietly widen, and the cost of being wrong is
	# that one player's keys move another player's mouse.
	_check("nobody drove the host's mouse (%.1fm)" % _spread(host_here),
		_spread(host_here) < STOOD_STILL)

	# BOTH ENDS AGREE ABOUT ONE MOUSE. Compared as averages rather than instant-for-instant: the
	# two logs are written on unsynchronised five-second timers in different processes, so the
	# samples are up to five seconds out of step with each other and the autopilot circles the
	# yard in about nine. Two averages over the same lap land in the same place; a client drawing
	# a different mouse entirely does not, which is the failure worth catching.
	var disagreement := _centre(client_here).distance_to(_centre(host_thinks))
	_check("the host and the client agree where it is (%.1fm)" % disagreement,
		disagreement < AGREEMENT)


# ------------------------------------------------------------------------- and a hole in the ground


## Can the second keyboard change the WORLD, or only walk around in it? (M7)
##
## THE FAILURE THIS EXISTS FOR IS COMPLETELY SILENT, and it was the state of the game until the
## controls became children of a mouse. A remote player's DIG bits crossed the wire from step 2
## onward and arrived at a server where the dig controller was an arena singleton wired to
## `../Player` -- *the* player, the host's own. Every count was healthy, the seat was right, the
## mouse moved, the snapshots came back, and the earth simply never opened. Nothing above this
## function can tell that apart from a client that chose not to dig.
##
## THREE CLAIMS, AND THE THIRD IS THE ONE THAT IS EASY TO MISS.
##
## 1. The host's copy of the client's mouse went underground -- so a BURROW crossed, was applied to
##    the right chair, and the server moved that mouse a plane down.
## 2. The host's copy of the client's mouse *cut cells*, counted on the controller that belongs to
##    that chair. `dig()` records which crew learnt a cell and never whose hand was on the button,
##    so a per-seat counter is the only thing that can say "this human dug" rather than "somebody
##    dug" in a match with four bot Engineers in it.
## 3. The client's OWN controller cut nothing. A client that also cuts is a client that has a
##    second opinion about the shape of the world -- the two agree until they don't, and the
##    disagreement arrives as a corridor that exists on one machine.
func _check_the_digging(host_said: String, client_said: String) -> void:
	print("\n-- and a hole it dug from three hundred miles away")

	var their_planes := _totals(host_said, "drives RED seat \\d+ at [^\\n]*plane (\\d+)")
	var their_shafts := _numbers(host_said, "drives RED seat \\d+ at [^\\n]*sank (\\d+)")
	var their_cuts := _numbers(host_said, "drives RED seat \\d+ at [^\\n]*cut (\\d+)")
	var my_cuts := _numbers(client_said, "received.*mine at [^\\n]*cut (\\d+)")
	# NOT A HARNESS COMPLAINT, MOST LIKELY. `_where` prints a dash where a mouse has no dig
	# controller, so the commonest way to arrive here is the exact regression this check exists
	# for: a mouse in a chair that carries no controls. Verified by making `MouseControls.fit`
	# skip remote players -- which is precisely the state of the game before this step -- and
	# watching it land on this line.
	if their_cuts.is_empty() or their_shafts.is_empty() or my_cuts.is_empty():
		_broken("a mouse in this match has no controls to cut with -- see mouse_controls.gd")
		return

	# The LAST value, not the sum: the counters are cumulative, so a total across reports would
	# count the same cells five times over and read as success on one lucky tile.
	#
	# THE SHAFT AND THE CORRIDOR ARE SEPARATE CLAIMS. The first version of this check added them
	# and passed on a run where the client pressed F once and never opened a cell -- the press path
	# working and the hold path not, reported as digging. F is one keypress; a corridor cell is
	# half a second of a HELD bit surviving the trip, being read on the server's physics tick, and
	# accumulating against a per-class dig rate. That is the harder claim and it needs its own line.
	_check("the client sank a shaft with F (%d)" % their_shafts[-1], their_shafts[-1] > 0)
	_check("and the host took it underground (%d plane-reports)" % their_planes, their_planes > 0)
	_check("and holding dig opened real earth (%d cells)" % their_cuts[-1], their_cuts[-1] > 0)
	_check("while the client itself cut nothing (%d)" % my_cuts[-1], my_cuts[-1] == 0)


# --------------------------------------------------------------- and a match, not just a puppet show


## The HUD's numbers, asked of both processes and compared.
##
## THE CLOCK IS WHAT MAKES THIS BITE. Score and stores can sit unchanged for a long stretch of a
## quiet match, so two ends agreeing about them proves little on its own -- but a client that never
## received a scoreboard sits at the full eight minutes forever while the host counts down, and no
## amount of the rest of the netcode working can hide that. It is the one field guaranteed to move.
func _check_the_scoreboard(host_said: String, client_said: String) -> void:
	print("\n-- and a match around it")

	var host_board := _boards(host_said)
	var client_board := _boards(client_said)
	if host_board.size() < 3 or client_board.size() < 3:
		_broken("not enough scoreboards to judge (%d host, %d client)"
			% [host_board.size(), client_board.size()])
		return

	var seen := _totals(client_said, "and (\\d+) scoreboards")
	_check("the client is sent the scoreboard (%d)" % seen, seen > 0)

	var first: Dictionary = client_board[0]
	var last: Dictionary = client_board[-1]
	var theirs: Dictionary = host_board[-1]
	_check("its clock is running (%ds to %ds)" % [first["clock"], last["clock"]],
		last["clock"] < first["clock"])

	# Sampled up to five seconds apart on unsynchronised timers, so this is a tolerance rather than
	# an equality -- and a client with no scoreboard at all is out by hundreds, not by seconds.
	var drift: int = absi(last["clock"] - theirs["clock"])
	_check("and it is the host's clock (%ds apart)" % drift, drift <= CLOCK_DRIFT)

	# THE STORES ARE LIVES (GDD section 10) and until this milestone the AI never spent one. Both
	# halves matter: that the number moved at all is bots actually Scurrying, and that both ends
	# moved together is the pool being replicated rather than each end keeping its own.
	var blue: int = last["cheese_blue"]
	var red: int = last["cheese_red"]
	_check("the crews have been spending (%d/%d)" % [blue, red], blue < STARTING_CHEESE
		or red < STARTING_CHEESE)
	var gap: int = absi(blue - theirs["cheese_blue"]) + absi(red - theirs["cheese_red"])
	_check("and both ends see the same stores (%d/%d vs %d/%d)"
		% [blue, red, theirs["cheese_blue"], theirs["cheese_red"]], gap <= CHEESE_DRIFT)

	# THIS ONE CANNOT FAIL BY DELIVERY AND IS NOT MEANT TO. Nobody scores in twenty-five seconds of
	# autopilot, so both ends read 0-0 whether or not a single scoreboard arrived -- verified, by
	# deleting the broadcast and watching this check pass while five others failed. What it is here
	# for is the OTHER failure: a field read at the wrong offset. Score, stores and clock share one
	# packet, so a mis-sized header shows up as a score of 71 next to a perfectly sensible clock,
	# and only a field-by-field comparison sees it.
	_check("the score agrees (%d-%d vs %d-%d)" % [
		last["blue"], last["red"], theirs["blue"], theirs["red"],
	], last["blue"] == theirs["blue"] and last["red"] == theirs["red"])

	# WEAKER THAN IT LOOKS, FOR THE SAME REASON AND SAID OUT LOUD FOR THE SAME REASON: nothing hits
	# the autopilot in a quiet run, so both ends usually read full health and this cannot fail by
	# delivery either. It catches the byte being scaled by the wrong maximum or read at the wrong
	# offset, which are the mistakes it is actually possible to make here. **Whoever adds combat to
	# this suite should promote it to a real check**, because at that point it can be one.
	var mine := _numbers(client_said, "received.*health (\\d+)")
	var theirs_health := _numbers(host_said, "drives RED seat \\d+ at [^\\n]*health (\\d+)")
	if mine.is_empty() or theirs_health.is_empty():
		_broken("neither end reported a health")
		return
	var apart: int = absi(mine[-1] - theirs_health[-1])
	_check("both ends agree how hurt it is (%d vs %d)" % [mine[-1], theirs_health[-1]],
		apart <= HEALTH_DRIFT)


# ---------------------------------------------------------------- and cheese lying in the yard


## A host creates this pile before the client enters its arena. It is absent from the client's
## deterministic opening map and no event is waiting to be replayed, so the only way it can appear
## is from a later complete cheese-world picture. That is spawn replication and late-join recovery
## in one observable fact.
func _check_the_cheese_world(host_said: String, client_said: String) -> void:
	print("\n-- and the cheese lying in the yard")
	var pictures := _totals(client_said, "(\\d+) cheese-world pictures")
	_check("the client receives complete cheese pictures (%d)" % pictures, pictures > 0)
	_check("the host made the late-join test pile",
		host_said.contains("audit cheese placed before the client arena exists"))
	var late_pile := "31.0,-31.0=3"
	_check("a pile made before its arena appears on the client",
		client_said.contains(late_pile))


# --------------------------------------------------------------------- and no floor plan it didn't earn


## **The assertion this milestone's risk register asked for**, and the only one here that guards a
## pillar rather than a feature.
##
## A VISIBILITY LEAK LOOKS LIKE NOTHING AT ALL FROM INSIDE A MATCH. The mice move, the score keeps,
## the minimap draws only your own corridors -- and a client that was sent the enemy's floor plan
## has it in memory whether or not anything on screen admits it. There is no playtest for that, no
## screenshot of it, and no way to notice it going wrong later. So the check is a set comparison
## between two processes: every cell the client holds must be one the rules say its crew may know.
##
## The host prints the permitted set using `TunnelSight.knows` **directly**, not the sender's
## record of what it sent. That is the difference between checking the rule and checking that the
## code agrees with itself.
func _check_the_earth(host_said: String, client_said: String) -> void:
	print("\n-- and no floor plan it did not earn")

	var mine := _last_bracketed(client_said, host_said)
	var dug := _last_report(host_said, "earth: sent \\d+, took back \\d+, all \\[([^\\]]*)\\]")
	if dug["cells"].is_empty():
		_broken("nobody dug anything -- there is no floor plan to leak, so nothing was tested")
		return
	if mine["at"] == 0:
		_broken("the client never reported what earth it holds")
		return

	# COMPARED AGAINST THE HOST'S VIEW AT THE CLIENT'S OWN MOMENT, widened by a grace window. The
	# two processes report on their own five-second timers, so the naive comparison -- last line
	# against last line -- judges a client's snapshot against a host's picture taken seconds later,
	# and a corridor whose fog closed in between reads as a leak. It did, on the first run of this
	# check, and a false alarm on an invariant is worse than no invariant: it is the thing that
	# gets the invariant relaxed.
	var permitted := _permitted_around(host_said, "RED", int(mine["at"]))
	var blue := _permitted_around(host_said, "BLUE", int(mine["at"]))
	var blue_only := _minus(blue, permitted)
	if blue_only.is_empty():
		_broken("blue cut nothing red may not know -- the leak check had nothing to catch")
		return

	var held: Dictionary = mine["cells"]
	_check("the client was sent earth at all (%d cells)" % held.size(), not held.is_empty())

	# THE ONE THAT MATTERS. Not "roughly right", not "most of them" -- a single cell of a network
	# this crew never cut and never saw is the pillar gone, and the game would play perfectly.
	var stolen := _minus(held, permitted)
	_check("and not one cell its crew may not know (%d of %d dug)" % [held.size(), dug["cells"].size()],
		stolen.is_empty())
	if not stolen.is_empty():
		print("        leaked: %s" % " ".join(PackedStringArray(stolen.keys()).slice(0, 12)))

	# Stated separately because the check above passes trivially if the client holds nothing, and
	# "the filter works" and "the filter is not just a wall" are different claims.
	_check("while blue holds %d cells red is not allowed" % blue_only.size(),
		held.size() < dug["cells"].size())

	# THE FOG HAS TO CLOSE, and this is the half that is easy to leave out: a client that keeps
	# every cell it ever glimpsed has a map more complete than the rules allow, and nothing looks
	# wrong while it happens. Only asserted when the run actually produced the situation -- if red
	# never lost sight of anything, saying so is worth more than a green tick.
	var lost := _fog_closed(host_said)
	var taken_back := _totals(host_said, "took back (\\d+)")
	if lost <= 0:
		print("   --    red never lost sight of anything; the fog was not exercised")
		return
	_check("and gives cells back as the fog closes (%d taken back, %d lost sight of)"
		% [taken_back, lost], taken_back > 0)


# --------------------------------------------------------------------------------------- plumbing


## Every number a pattern's first capture group matched, added up. The reports are per-interval
## rather than cumulative, so a total is the only thing that survives not knowing how many
## intervals a run produced.
func _totals(text: String, pattern: String) -> int:
	var re := RegEx.create_from_string(pattern)
	var sum := 0
	for hit: RegExMatch in re.search_all(text):
		sum += hit.get_string(1).to_int()
	return sum


## Every `(x, y, z)` a pattern's first capture group matched. Written by `Vector3.snapped`, so the
## text is decimetres and the parse can stay this blunt.
func _positions(text: String, pattern: String) -> Array[Vector3]:
	var re := RegEx.create_from_string(pattern)
	var out: Array[Vector3] = []
	for hit: RegExMatch in re.search_all(text):
		var parts := hit.get_string(1).split(",")
		if parts.size() != 3:
			continue
		out.append(Vector3(
			parts[0].strip_edges().to_float(),
			parts[1].strip_edges().to_float(),
			parts[2].strip_edges().to_float()
		))
	return out


## The widest gap between any two samples. "Did this thing move" asked in a way that a mouse
## walking in a circle cannot accidentally answer no -- first-to-last would read zero for a lap
## that happened to close.
func _spread(samples: Array[Vector3]) -> float:
	var worst := 0.0
	for a: Vector3 in samples:
		for b: Vector3 in samples:
			worst = maxf(worst, a.distance_to(b))
	return worst


## The average of the samples. For a mouse circling, this is the middle of the circle -- a
## statistic that does not care which point of the lap either process happened to write down.
func _centre(samples: Array[Vector3]) -> Vector3:
	var sum := Vector3.ZERO
	for at: Vector3 in samples:
		sum += at
	return sum / maxf(1.0, float(samples.size()))


## Every scoreboard line a process wrote, in order. Both ends log it from the same code, so this
## parses one format and not two -- the comparison is a question answered twice, not two formatters
## agreeing.
func _boards(text: String) -> Array[Dictionary]:
	var re := RegEx.create_from_string(
		"score (\\d+)-(\\d+), cheese (\\d+)/(\\d+), clock (\\d+), banners (\\d+)/(\\d+)")
	var out: Array[Dictionary] = []
	for hit: RegExMatch in re.search_all(text):
		out.append({
			"blue": hit.get_string(1).to_int(),
			"red": hit.get_string(2).to_int(),
			"cheese_blue": hit.get_string(3).to_int(),
			"cheese_red": hit.get_string(4).to_int(),
			"clock": hit.get_string(5).to_int(),
			"banner_blue": hit.get_string(6).to_int(),
			"banner_red": hit.get_string(7).to_int(),
		})
	return out


## The last report a pattern matched, as `{"at": unix ms, "cells": set}`.
##
## Last rather than merged, and stamped rather than bare: the client gives cells back as the fog
## closes, so a union over a whole run would accuse it of holding what it has already returned, and
## an unstamped set cannot be lined up against the other process at all.
func _last_report(text: String, pattern: String) -> Dictionary:
	var re := RegEx.create_from_string("\\[(\\d+)\\] " + pattern)
	var hits := re.search_all(text)
	if hits.is_empty():
		return {"at": 0, "cells": {}}
	var out: Dictionary = {}
	for cell: String in hits[-1].get_string(2).split(" ", false):
		out[cell] = true
	return {"at": hits[-1].get_string(1).to_int(), "cells": out}


## Everything a crew was allowed to know at any point within `FOG_GRACE` of one moment.
##
## A UNION OVER A WINDOW, not a single reading, and the window is the honest way to compare two
## processes that keep their own clocks. Anything inside it was legitimately sendable within a few
## seconds of the client's snapshot; a genuine leak is a set of cells that was never permitted at
## any moment of the match, so widening by seconds costs the check nothing.
## The client's most recent earth report that the HOST also has a picture of.
##
## THE GRACE WINDOW WAS ONLY HALF THE FIX, and this is the other half. `_permitted_around` widened
## the comparison so a corridor whose fog closed between the two logs stops reading as a leak --
## and that handles the case where the host's picture is a little *stale*. It does nothing for the
## case where the host has no picture at all.
##
## Both processes are killed at the same instant and the host was started fourteen seconds earlier,
## so their five-second report timers are permanently out of phase and the host's log routinely
## ends a second or two BEFORE the client's. Judged against its last line, everything the client
## legitimately learnt in that final second or two is a cell nobody ever said it could have. On the
## run that found this it was thirteen of them, on plane 2, all arriving in the client's very last
## report -- named by coordinate, looking exactly like the leak this check exists for.
##
## So the invariant is only asked where the two logs overlap. A false alarm on an invariant is
## worse than a missing one: it is the thing that gets the invariant relaxed. That sentence is
## already in the plan about this check, and this is the second time it applied.
func _last_bracketed(client_said: String, host_said: String) -> Dictionary:
	var re := RegEx.create_from_string("\\[(\\d+)\\] earth RED may know")
	var seen := re.search_all(host_said)
	if seen.is_empty():
		return {"at": 0, "cells": {}}
	var newest := seen[-1].get_string(1).to_int()

	var best: Dictionary = {"at": 0, "cells": {}}
	var holds := RegEx.create_from_string("\\[(\\d+)\\] earth: took \\d+, hold \\[([^\\]]*)\\]")
	for hit: RegExMatch in holds.search_all(client_said):
		var at := hit.get_string(1).to_int()
		if at > newest:
			continue
		var cells: Dictionary = {}
		for cell: String in hit.get_string(2).split(" ", false):
			cells[cell] = true
		best = {"at": at, "cells": cells}
	return best


func _permitted_around(text: String, crew: String, at: int) -> Dictionary:
	var re := RegEx.create_from_string("\\[(\\d+)\\] earth %s may know \\[([^\\]]*)\\]" % crew)
	var out: Dictionary = {}
	for hit: RegExMatch in re.search_all(text):
		if absi(hit.get_string(1).to_int() - at) > FOG_GRACE_MS:
			continue
		for cell: String in hit.get_string(2).split(" ", false):
			out[cell] = true
	return out


## How many cells the RED crew stopped being allowed to know over the run: the fog closing, as
## observed on the host. Zero means the situation the forget path exists for never arose.
func _fog_closed(text: String) -> int:
	var re := RegEx.create_from_string("earth RED may know \\[([^\\]]*)\\]")
	var lost := 0
	var last: Dictionary = {}
	for hit: RegExMatch in re.search_all(text):
		var now: Dictionary = {}
		for cell: String in hit.get_string(1).split(" ", false):
			now[cell] = true
		lost += _minus(last, now).size()
		last = now
	return lost


func _minus(from: Dictionary, these: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for cell: String in from:
		if not these.has(cell):
			out[cell] = true
	return out


## Every integer a pattern's first capture group matched, in order.
##
## Was `_healths`, and generalised rather than copied when M7 wanted the same thing for the
## per-seat dig counter. Order matters to both callers and for opposite reasons: health wants the
## LATEST reading, and the dig counter is cumulative, so a sum would count one tile five times.
func _numbers(text: String, pattern: String) -> Array[int]:
	var re := RegEx.create_from_string(pattern)
	var out: Array[int] = []
	for hit: RegExMatch in re.search_all(text):
		out.append(hit.get_string(1).to_int())
	return out


## The launched processes write to their own file rather than to stdout: `create_process` hands
## back no pipe, and both would otherwise share -- and clobber -- one `user://logs/`.
func _log_path(who: String) -> String:
	return ProjectSettings.globalize_path("user://replication_audit_%s.log" % who)


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()


func _wait(seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		await process_frame
		left -= root.get_process_delta_time()


## The test could not be run, which is a different result from the test failing and must not be
## reported as one -- a launch that never happened says nothing at all about the netcode.
func _broken(why: String) -> void:
	print("BROKEN: %s" % why)
	_failures += 1


func _check(what: String, ok: bool) -> void:
	print("   %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
