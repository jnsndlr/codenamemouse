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
const PLAY_SECONDS: float = 42.0
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
		"--", "--host", str(PORT), "--play", "--audit-log", host_log,
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
