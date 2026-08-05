extends SceneTree
## Two processes in a real match, and then the host is killed.
##
## **THE FIRST SUITE HERE THAT BREAKS SOMETHING ON PURPOSE.** Every other audit in `tools/` gets two
## ends of a wire talking and finishes while they still are. That is why the bug this file exists for
## survived seven passing suites: on loopback the connection never drops, so `connection lost` appears
## in every audit log exactly once — as the last line, at teardown, where nothing is left to observe
## what happens next. Failure had no coverage at all.
##
## What was happening: `go_offline` closes the transport, `NetMatch._physics_process` returns at its
## `is_established` guard forever, the client's director had already been told `set_simulating(false)`
## and nothing turns it back on. Every mouse stays a puppet waiting for poses that never come. The
## match froze in silence with no message and no way out but the pause menu.
##
## THE HOST IS KILLED RATHER THAN ASKED TO LEAVE, and that is the harder of the two cases on purpose.
## A hard kill is a crash: ENet learns nothing until its peer timeout expires, so the client sits in a
## working-looking match for several seconds before anything tells it otherwise. `seat_audit` has the
## note about this — it goes the other way and lets its client quit gracefully, because there the
## question was whether a chair is freed promptly. Here the question is whether a client that is
## *given no warning at all* eventually notices, which is the case a real network produces.
##
## THE ORDERING IS THE ASSERTION. "The client said the wire died" is satisfied by a client that failed
## to connect in the first place and never played a second of the match. What has to be true is that it
## was replicating, then stopped, and then said why — so the check is on the position of that line
## relative to the LAST replication report, not merely on its presence. The cant audit is the reason
## this file was written that way from the start.
##
##   godot --headless --path . --script res://tools/drop_audit.gd

const PORT: int = 47890
## Long enough for a headless process to parse the project, build an arena and bake a navmesh.
const BOOT_SECONDS: float = 8.0
## Time in a real match before the floor is pulled out. Two five-second reports' worth, so "it was
## replicating first" is evidence rather than a hopeful single line.
const PLAY_SECONDS: float = 14.0
## How long to wait for a client to notice a host that simply stopped answering.
##
## GENEROUS ON PURPOSE, and the generosity is the point rather than a fudge. There is no disconnect
## packet coming -- the host was killed -- so the only thing that can end this is ENet's peer timeout,
## which `seat_audit` records as five to thirty seconds. A tight window here would make the suite
## flaky about somebody else's constant; a loose one costs half a minute and asserts the thing that
## actually matters, which is that a client left hanging does not hang forever.
##
## Measured at about three seconds on loopback, so this is roughly a tenfold margin and deliberately
## not trimmed to fit. The number it is waiting on belongs to ENet, not to this project, and buying
## thirty seconds of runtime to stop caring what it is exactly is a good trade.
const TIMEOUT_SECONDS: float = 45.0
## Frames, and a backstop only -- both processes are killed explicitly. `lobby_audit` has the scar
## about setting this tight: a headless process outside an arena runs uncapped and quits early, and
## the log it leaves behind reads as a network failure that was really the audit's own doing.
const LIFETIME_FRAMES: String = "60000"

var _failures: int = 0


func _initialize() -> void:
	await _pull_the_wire()

	print("")
	if _failures > 0:
		print("=== %d FAILED. A dropped match does not say so. ===" % _failures)
		quit(1)
		return
	print("==============================================================================")
	print("THE WIRE DIES AND SOMEBODY SAYS SO, instead of a yard that quietly stopped moving.")
	print("==============================================================================")
	quit()


func _pull_the_wire() -> void:
	print("-- a real match, and then no host")

	var godot := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var host_log := _log_path("host")
	var join_log := _log_path("client")

	var host_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--host", str(PORT), "--play", "--audit-log", host_log,
	])
	if host_pid <= 0:
		print("BROKEN: could not launch a host process")
		_failures += 1
		return
	await _wait(BOOT_SECONDS)

	var join_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--join", "127.0.0.1:%d" % PORT, "--play", "--autopilot",
		"--audit-log", join_log,
	])
	if join_pid <= 0:
		print("BROKEN: could not launch a client process")
		OS.kill(host_pid)
		_failures += 1
		return

	await _wait(PLAY_SECONDS)

	# READ BEFORE THE KILL, so "it was in a real match" is evidence gathered while it still was. Taken
	# afterwards this would be a claim about a log that had already been overtaken by the thing under
	# test.
	var while_playing := _read(join_log)
	_check("the client was in a real match first (%d reports)"
		% while_playing.count("received "),
		while_playing.contains("received ") and while_playing.contains("snapshots"))
	_check("and had not already lost anything",
		not while_playing.contains("the wire died"))

	print("\n-- the host is killed outright, with no goodbye")
	OS.kill(host_pid)
	await _wait(TIMEOUT_SECONDS)

	var client_said := _read(join_log)
	var still_running := OS.is_process_running(join_pid)
	OS.kill(join_pid)
	await _wait(2.0)

	_check("the client survived it rather than crashing", still_running)
	_check("it noticed the wire was gone", client_said.contains("connection lost"))
	_check("and said so in the arena instead of freezing",
		client_said.contains("disconnected: the wire died mid-match"))

	# The isolating check. A client that never got into a match could satisfy every line above.
	var last_report := client_said.rfind("received ")
	var said_at := client_said.find("disconnected: the wire died mid-match")
	_check("after it had stopped replicating, not before (%d after %d)"
		% [said_at, last_report],
		said_at > last_report and last_report >= 0)
	# The landing place is a DECISION, not a fallback: the arena holds, paused, with the notice over
	# it, because the last thing you saw is information and being flung back to a menu tells you
	# nothing. Nobody pressed the button in this run, so nothing should have moved.
	_check("and held the arena rather than flinging anybody at a menu",
		not client_said.contains("disconnected: back to the title"))


# ---------------------------------------------------------------------------------------- plumbing


func _log_path(who: String) -> String:
	return ProjectSettings.globalize_path("user://drop_audit_%s.log" % who)


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()


func _wait(seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		left -= root.get_process_delta_time()
		await process_frame


func _check(what: String, held: bool) -> void:
	print("   %s  %s" % ["ok  " if held else "FAIL", what])
	if not held:
		_failures += 1
