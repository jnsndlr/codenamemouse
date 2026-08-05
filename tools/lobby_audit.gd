extends SceneTree
## The door: two real processes meet in a lobby, and the host's button is what puts them in a match.
##
## Everything else in `tools/` tests a match that is already running. This tests the part before it,
## which until M7's checkpoint 5 did not exist: there was no Host button, no Join field, and no room
## to wait in — `Routes.to_match` took no arguments and joining was a command-line flag, so a friend
## could not reach a match without a terminal.
##
## **`START` is the only message in the protocol whose receiver has no arena**, which is exactly why
## it needs a suite of its own. It is handled by `NetSession` rather than `NetMatch` because a client
## sitting in a lobby has no `NetMatch` to hand it to, and that makes it the one packet no other audit
## here can reach: every one of them begins after both ends are already playing.
##
## THE ORDERING ASSERTION IS THE POINT. "The client ended up in an arena" proves nothing on its own —
## a client that entered one by any other route would satisfy it. What has to be true is that it was
## NOT in an arena until the host said so, so the check is on the order of two lines in one log. The
## cant audit taught this the hard way: a check that a thing is absent, without ruling out the other
## reasons it could be absent, passes for free.
##
##   godot --headless --path . --script res://tools/lobby_audit.gd

const PORT: int = 47880
## Long enough for a headless process to parse the project and reach the lobby. Same number
## `seat_audit` uses, for the same reason: no arena on the way, so no navmesh bake to wait on.
const BOOT_SECONDS: float = 8.0
## When the host presses its own Start button, measured from the moment its lobby appears. It must be
## comfortably after the client has booted AND connected, or this suite would be testing a START sent
## to nobody -- which passes the host's half and silently skips the client's.
const START_AFTER: String = "16"
## Frames, not seconds. `seat_audit` has the scar tissue about that; this file added its own. A
## headless process with no arena in front of it runs uncapped, so the host burned most of a 6000
## budget sitting in the lobby and then quit *while this suite was reading its logs* -- the client
## dutifully recorded a connection loss that was the audit's own doing, and the drop check failed on
## it. The processes are killed explicitly, so this is only a backstop and there is no reason for it
## to be tight.
const LIFETIME_FRAMES: String = "40000"

var _failures: int = 0


func _initialize() -> void:
	await _play_a_lobby()

	print("")
	if _failures > 0:
		print("=== %d FAILED. The door does not work. ===" % _failures)
		quit(1)
		return
	print("==============================================================================")
	print("THE HOST OPENS A DOOR AND A GUEST WALKS IN, and neither of them typed a flag to play.")
	print("==============================================================================")
	quit()


func _play_a_lobby() -> void:
	print("-- a host in a lobby, and a guest who found it")

	var godot := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var host_log := _log_path("host")
	var join_log := _log_path("client")

	# NEITHER PROCESS IS GIVEN `--play`. That is the whole test: `--play` is the private entrance the
	# replication suites use to get straight into an arena, and if either end had it, reaching a match
	# would prove nothing about the lobby. These two are in exactly the state a clicked one is.
	var host_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--host", str(PORT), "--lobby-start", START_AFTER,
		"--audit-log", host_log,
	])
	if host_pid <= 0:
		print("BROKEN: could not launch a host process")
		_failures += 1
		return
	await _wait(BOOT_SECONDS)

	var join_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--join", "127.0.0.1:%d" % PORT, "--audit-log", join_log,
	])
	if join_pid <= 0:
		print("BROKEN: could not launch a client process")
		OS.kill(host_pid)
		_failures += 1
		return

	# Boot, connect, sit, be started, load an arena, and report from inside it at least once. The
	# report interval is five seconds, so the tail of this is waiting for evidence rather than events.
	await _wait(42.0)

	# THE LATECOMER GOES IN WHILE THE OTHER TWO ARE STILL PLAYING, which is the entire point and was
	# the first version's bug: it was launched after the kills below and had nothing to join, so four
	# checks failed on an audit that was itself broken rather than on the code under test. All three
	# processes now live until every log has been read.
	var late_log := _log_path("latecomer")
	var late_pid := _launch_a_latecomer(godot, project, late_log)
	if late_pid > 0:
		await _wait(24.0)

	var host_said := _read(host_log)
	var client_said := _read(join_log)
	var late_said := _read(late_log)
	if late_pid > 0:
		OS.kill(late_pid)
	OS.kill(join_pid)
	OS.kill(host_pid)
	await _wait(2.0)

	if host_said.is_empty() or client_said.is_empty():
		print("BROKEN: one of the processes wrote nothing -- neither can be judged")
		_failures += 1
		return

	_check("the host reached a lobby rather than the title",
		host_said.contains("lobby: hosting on %d" % PORT))
	_check("and the guest reached one too, from a typed address",
		client_said.contains("lobby: joined 127.0.0.1:%d" % PORT))
	_check("the guest was seated while still in that lobby",
		host_said.contains("takes RED seat"))

	print("\n-- and the host's button is what starts the match")
	_check("the host says it told somebody", host_said.contains("told 1 peer(s)"))
	_check("and the guest heard it",
		client_said.contains("the host says the match is beginning"))

	# THE ORDER, not merely the presence of both. A guest that was already in an arena would satisfy
	# every check above.
	var told_at := client_said.find("the host says the match is beginning")
	var first_report := client_said.find("received ")
	_check("the guest was in no arena until it was told (%d before %d)" % [told_at, first_report],
		told_at >= 0 and first_report > told_at)
	_check("and then it really was in one, replicating",
		client_said.contains("received ") and client_said.contains("snapshots"))
	_check("the host is in the same match, sending",
		host_said.contains("sent ") and host_said.contains("snapshots"))
	# SCOPED TO THE WINDOW THIS SUITE IS ABOUT -- joining, waiting, being started -- and not to the
	# whole log. What happens to the wire afterwards is the next checkpoint's subject, and reading the
	# entire file made this assert something it cannot control: whichever process this suite kills
	# first makes the other one log a drop, so the check failed on the audit's own teardown.
	var through_the_door := client_said.substr(0, maxi(first_report, 0))
	_check("and nobody dropped on the way through the door",
		not through_the_door.contains("connection lost"))

	_check_the_latecomer(late_said, late_pid)


## A third process turns up after the match has started, and is let in.
##
## **REJOINING WAS BROKEN AND NOT BY A LITTLE.** `START` is sent by the lobby's button, and the host
## leaves that lobby the instant it presses it -- so anybody arriving later was seated, given a mouse on
## the server, and sent snapshots and earth and cheese while *sitting on a lobby screen forever*
## watching none of it. Indistinguishable from a hang. It is the same gap for a friend who turned up
## ten minutes late and for a player whose wire dropped and who wants back in, and `drop_audit` had
## just finished making the second of those a thing people would actually try.
##
## THIS PROCESS GETS `--join` AND NOTHING ELSE. No `--play` to walk itself into an arena and no
## `--lobby-start`, so the only thing that can put it in a match is the host noticing it and saying so.
## If `_start_the_latecomers` does nothing, this process sits in a lobby and every check below fails.
func _launch_a_latecomer(godot: String, project: String, late_log: String) -> int:
	var pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--join", "127.0.0.1:%d" % PORT, "--audit-log", late_log,
	])
	if pid <= 0:
		print("BROKEN: could not launch a latecomer")
		_failures += 1
	return pid


func _check_the_latecomer(late_said: String, late_pid: int) -> void:
	print("\n-- and somebody who turned up late is let in")
	if late_pid <= 0:
		return
	_check("the latecomer reached a lobby with the match already running",
		late_said.contains("lobby: joined 127.0.0.1:%d" % PORT))
	_check("the host noticed and told it to come in",
		late_said.contains("the host says the match is beginning"))
	_check("and it is replicating a match that started without it",
		late_said.contains("received ") and late_said.contains("snapshots"))
	# THE WHOLE WORLD, NOT THE PART THAT HAPPENED WHILE IT WATCHED. This is the payoff of every
	# complete-state decision in step 6: there are no spawn events to replay, so a latecomer is owed
	# the same periodic pictures everybody else gets and catches up by receiving one of each.
	_check("and was given the world as it stands, not as it started",
		late_said.contains("cheese world: hold [")
		and late_said.contains("barricade world: hold [")
		and late_said.contains("cant viewer "))
	_check("including earth it never dug",
		late_said.contains("earth: took ") and not late_said.contains("hold []\nearth"))


# ---------------------------------------------------------------------------------------- plumbing


func _log_path(who: String) -> String:
	return ProjectSettings.globalize_path("user://lobby_audit_%s.log" % who)


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
