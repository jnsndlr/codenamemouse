extends SceneTree
## Who is in which chair, asserted twice over: as a table, and as two real processes.
##
## THE TABLE HALF is ordinary and fast — claim, release, balance, full. The **process half** is why
## the CLI flags exist. `--host` and `--join` were built before any Host button precisely so that
## checkpoint 1 ("two windows on one machine, one seat each") could be *checked* rather than
## demonstrated: this launches two actual copies of the game, lets them find each other over a real
## socket, and reads what each one says about its own seating out of its log.
##
## That is a slower and uglier test than anything else in `tools/`, and it is the only kind that
## can catch the failures this step can actually have — a client that connects but is never seated,
## a host that seats it and spawns a bot in the same chair, a disconnect that removes a mouse
## instead of handing it to a bot. None of those are visible from inside one process.
##
##   godot --headless --path . --script res://tools/seat_audit.gd

const PORT: int = 47870
## Long enough for a headless process to parse the project and reach the title screen, which is
## the main scene -- no arena, so no navmesh bake to wait on.
const BOOT_SECONDS: float = 8.0
## `--quit-after` counts FRAMES, not seconds, and mistaking the two is how the first run of this
## file failed: at 1200 the host had already exited before the client was launched, and the
## symptom was an unconnectable socket rather than a missing process. 6000 is ~100s of headroom
## over a test that needs about 25, and it is a backstop -- the processes are killed explicitly.
const LIFETIME_FRAMES: String = "6000"
## The client is given a SHORT life and allowed to end it itself, rather than being killed.
##
## A hard kill is a crash, and ENet only learns about a crash when the peer timeout expires --
## five to thirty seconds, which is not the case worth asserting. A player *quitting* is the
## ordinary case, and it should free the chair at once. Asserting the graceful path is what
## caused `NetSession._exit_tree` to exist at all.
const CLIENT_FRAMES: String = "900"

var _failures: int = 0


func _initialize() -> void:
	_check_table()
	await _check_two_processes()

	print("")
	if _failures > 0:
		print("=== %d FAILED. The seating is not what it says it is. ===" % _failures)
		quit(1)
		return
	print("==============================================================================")
	print("EVERY CHAIR IS ACCOUNTED FOR: claimed, balanced, released to a bot, over a socket.")
	print("==============================================================================")
	quit()


# ------------------------------------------------------------------------------------- the table


func _check_table() -> void:
	print("-- an empty match is all bots")
	var seats := Seats.new(5)
	_check("ten seats, nobody in them", seats.total_humans() == 0)
	_check("and every one of them is a bot", not seats.is_human(Team.BLUE, 0) and not seats.is_human(Team.RED, 4))
	_check("nobody is seated by accident", seats.seat_of(1).is_empty())

	print("\n-- the host takes blue 0")
	seats.seat_host(1)
	_check("blue 0 is the host", seats.occupant(Team.BLUE, 0) == 1)
	_check("which is a human", seats.is_human(Team.BLUE, 0))
	_check("and the rest are not", seats.humans(Team.BLUE) == 1 and seats.humans(Team.RED) == 0)

	print("\n-- joiners balance the crews")
	# Blue already has the host, so the first joiner must go red. A `claim` that only looked for a
	# free chair would put them on blue seat 1 and stack both humans on one side.
	var a := seats.claim(200)
	_check("the first joiner goes to the emptier crew", a[0] == Team.RED)
	var b := seats.claim(201)
	_check("the second evens it up again", b[0] == Team.BLUE)
	_check("and takes the lowest free chair", b[1] == 1)
	_check("three people are seated", seats.total_humans() == 3)
	_check("peers() lists exactly them", Array(seats.peers()).size() == 3)

	print("\n-- and nobody is seated twice")
	var again := seats.claim(200)
	_check("claiming an existing seat returns the same one", again == a)
	_check("without adding a person", seats.total_humans() == 3)
	_check("a bot cannot claim a seat", seats.claim(Seats.BOT).is_empty())

	print("\n-- leaving hands the chair to a bot, and does NOT remove it")
	var freed := seats.release(200)
	_check("the seat that was freed is the one they had", freed == a)
	_check("it is now a bot", not seats.is_human(freed[0], freed[1]))
	_check("the crew still has five chairs", seats.crew_size() == 5)
	_check("two people remain", seats.total_humans() == 2)
	_check("releasing a stranger does nothing", seats.release(999).is_empty())

	print("\n-- a full match refuses")
	var full := Seats.new(2)
	full.seat_host(1)
	for peer: int in [10, 20, 30]:
		full.claim(peer)
	_check("four chairs, four people", full.total_humans() == 4 and full.is_full())
	_check("the fifth is turned away", full.claim(40).is_empty())
	_check("and did not displace anybody", full.total_humans() == 4)


# --------------------------------------------------------------------------------- two processes


func _check_two_processes() -> void:
	print("\n-- two real processes, one socket")

	var godot := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var host_log := _log_path("host")
	var join_log := _log_path("client")

	var host_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--host", str(PORT), "--audit-log", host_log,
	])
	if host_pid <= 0:
		print("BROKEN: could not launch a host process")
		_failures += 1
		return
	# Let the host bind before the client tries the door, or the client fails to connect for a
	# reason that has nothing to do with seating.
	await _wait(BOOT_SECONDS)

	var join_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", CLIENT_FRAMES,
		"--", "--join", "127.0.0.1:%d" % PORT, "--audit-log", join_log,
	])
	if join_pid <= 0:
		print("BROKEN: could not launch a client process")
		OS.kill(host_pid)
		_failures += 1
		return

	await _wait(BOOT_SECONDS)
	var host_seated := _read(host_log)
	var client_said := _read(join_log)

	if host_seated.is_empty():
		print("BROKEN: the host wrote nothing -- it never got far enough to be judged")
		OS.kill(join_pid)
		OS.kill(host_pid)
		_failures += 1
		return

	_check("the host is hosting", host_seated.contains("hosting on %d" % PORT))
	_check("the client says it connected", client_said.contains("connected as peer"))
	# The assertion the whole file is for: a peer that arrives is SEATED, not merely connected.
	_check("the host seated the arrival", host_seated.contains("takes RED seat"))
	# Balance again, but over a real socket: the host holds blue 0, so the one joiner goes red.
	_check("on the emptier crew, not alongside the host", not host_seated.contains("takes BLUE seat"))
	_check("exactly once", host_seated.count("takes ") == 1)
	_check("and nobody was turned away", not host_seated.contains("the match is full"))

	print("\n-- and the chair goes back to a bot when they leave")
	# WAIT FOR THE CLIENT TO END ITSELF rather than killing it, then give the host a moment. Read
	# the log again afterwards -- the first version of this file asserted the departure against a
	# snapshot taken while both were still running, so it could only ever have failed.
	var quit_by_itself := await _wait_for_exit(join_pid, 30.0)
	_check("the client shut itself down cleanly", quit_by_itself)
	await _wait(5.0)
	var host_after := _read(host_log)
	OS.kill(host_pid)
	await _wait(2.0)

	_check("the host noticed the departure", host_after.contains("leaves RED seat"))
	_check("and handed the chair to a bot", host_after.contains("to a bot"))
	_check("the seat was not simply deleted", host_after.contains("RED[bot"))


# ---------------------------------------------------------------------------------------- plumbing


## The launched processes write to their own file rather than to stdout, because `create_process`
## hands back no pipe and both would otherwise share -- and clobber -- one `user://logs/`.
func _log_path(who: String) -> String:
	return ProjectSettings.globalize_path("user://seat_audit_%s.log" % who)


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return "" if file == null else file.get_as_text()


## Poll until a process is gone. Returns false if it outstayed the deadline, which is a different
## failure from "the host did not notice" and must not be reported as one.
func _wait_for_exit(pid: int, deadline: float) -> bool:
	var left := deadline
	while left > 0.0:
		if not OS.is_process_running(pid):
			return true
		await process_frame
		left -= root.get_process_delta_time()
	return false


func _wait(seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		await process_frame
		left -= root.get_process_delta_time()


func _check(what: String, ok: bool) -> void:
	print("   %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
