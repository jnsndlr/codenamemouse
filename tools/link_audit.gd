extends SceneTree
## The same match, over a wire made bad on purpose.
##
## **EVERY OTHER SUITE HERE RUNS ON THE ONE LINK WHERE THIS PROTOCOL'S CENTRAL CLAIMS CANNOT BE
## WRONG.** Loopback has no latency, no jitter and no loss, so on loopback interpolation is
## indistinguishable from teleporting to the last packet, and "the next complete picture heals it" is
## indistinguishable from never needing to heal. `net_match.gd` has argued since its first commit that
## twenty snapshots a second is enough *because the client interpolates*, and `net_message.gd` that
## unreliable delivery is right *because the next one fixes it*. Both were reasonable. Neither had ever
## met a network.
##
## So both ends get `--lag`, `--jitter` and `--loss`, and the assertions are the ones
## `replication_audit` already makes — do the two ends agree where the mouse is, does the world
## reconcile, is the earth still filtered — with the tolerances opened up to what a bad link deserves
## and nothing else changed. **A failure here is not "the wire is bad", it is "the protocol needed the
## wire to be good".**
##
## LOSS IS APPLIED TO UNRELIABLE PACKETS ONLY, on the way out, where reliability is still known. See
## `enet_transport.degrade`: dropping a reliable packet at the application layer would discard
## something ENet had guaranteed, and a lost `SEATS` or `START` does not heal — that would be testing a
## protocol this game does not have.
##
##   godot --headless --path . --script res://tools/link_audit.gd

const PORT: int = 47895
## A poor domestic connection rather than a catastrophic one: about 120ms each way with 40ms of swing
## and one unreliable packet in eight thrown away. Chosen to be plainly worse than anything this
## project has run on and plainly survivable, because the interesting answer is "it still converges",
## not "it falls over at 90% loss" -- which it should.
const LAG_MS: String = "120"
const JITTER_MS: String = "40"
const LOSS_PERCENT: String = "12"

const BOOT_SECONDS: float = 10.0
## Longer than `replication_audit`'s, because everything this measures now takes a round trip it did
## not before, and the periodic pictures need several intervals to demonstrate healing.
const PLAY_SECONDS: float = 45.0
const CLIENT_TITLE_SECONDS: String = "8"
const LIFETIME_FRAMES: String = "40000"

## How far apart the two ends may think one MOVING mouse is.
##
## **LOOSE, AND THE REASON IS THE MEASUREMENT RATHER THAN THE PROTOCOL** -- worth stating plainly,
## because the first version of this constant was 6.0 and the run came back at 5.8, which reads like a
## meaningful margin and was mostly an accident. Each end reports every five seconds, so even matched
## by timestamp the closest pair of readings can be two and a half seconds apart, and a mouse at a
## sprint crosses most of a yard in that. **Nearly all of any figure here is the gap between two
## reports, not the gap between two machines.** No threshold on this can be tight enough to see 160ms
## of latency, so it is set where it catches what it genuinely can: a client stuck at its spawn, or
## driving a mouse somewhere completely different. Gross desync, not lag.
##
## Demanding the tight figure would in any case be demanding prediction, which this project has
## deliberately not built -- see the plan's risk list, "the scope trap is prediction".
const SPREAD_METRES: float = 15.0

## And how far apart they may be once the mouse has STOPPED.
##
## This is the strong half, and it is strong for the opposite reason. `--autopilot` spends the back of a
## match parked in a one-cell corridor; with nothing moving, latency explains *nothing*, so whatever
## gap is left is real error that never resolved. A protocol that had quietly drifted -- applied a pose
## to the wrong seat, lost a mouse's plane, healed a picture incorrectly -- shows up here and nowhere
## else. Latency is allowed to be invisible in this number. Drift is not.
const SETTLED_METRES: float = 1.0

var _failures: int = 0


func _initialize() -> void:
	await _play_on_a_bad_wire()

	print("")
	if _failures > 0:
		print("=== %d FAILED. The protocol needed the wire to be good. ===" % _failures)
		quit(1)
		return
	print("==============================================================================")
	print("IT SURVIVES A BAD LINE: lag, jitter and lost packets, and the world still agrees.")
	print("==============================================================================")
	quit()


func _play_on_a_bad_wire() -> void:
	print("-- %sms lag, %sms jitter, %s%% loss, on both ends" % [
		LAG_MS, JITTER_MS, LOSS_PERCENT,
	])

	var godot := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var host_log := _log_path("host")
	var join_log := _log_path("client")

	var host_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--host", str(PORT), "--play", "--audit-cheese", "--audit-barricades",
		"--lag", LAG_MS, "--jitter", JITTER_MS, "--loss", LOSS_PERCENT,
		"--audit-log", host_log,
	])
	if host_pid <= 0:
		print("BROKEN: could not launch a host process")
		_failures += 1
		return
	await _wait(BOOT_SECONDS)

	# BOTH ENDS DEGRADED, because a link is only symmetric if you spoil both halves of it. Degrading
	# the host alone would leave the client's inputs arriving instantly, which is not a network anybody
	# has and would quietly make the round trip half of what it says on the tin.
	var join_pid := OS.create_process(godot, [
		"--headless", "--path", project, "--quit-after", LIFETIME_FRAMES,
		"--", "--join", "127.0.0.1:%d" % PORT, "--play", CLIENT_TITLE_SECONDS,
		"--autopilot", "--lag", LAG_MS, "--jitter", JITTER_MS, "--loss", LOSS_PERCENT,
		"--audit-log", join_log,
	])
	if join_pid <= 0:
		print("BROKEN: could not launch a client process")
		OS.kill(host_pid)
		_failures += 1
		return

	await _wait(PLAY_SECONDS)
	var host_said := _read(host_log)
	var client_said := _read(join_log)
	OS.kill(join_pid)
	OS.kill(host_pid)
	await _wait(2.0)

	if host_said.is_empty() or client_said.is_empty():
		print("BROKEN: one of the processes wrote nothing -- neither can be judged")
		_failures += 1
		return

	_check("both ends know the wire was spoiled",
		host_said.contains("wire degraded on purpose")
		and client_said.contains("wire degraded on purpose"))
	_check("the match happened anyway", client_said.contains("received "))
	_check("and the client's inputs still reached the host", host_said.contains("took "))

	print("\n-- and the two ends still agree what happened")
	# THE WORST DISAGREEMENT ACROSS THE WHOLE MATCH, PAIRED BY WALL CLOCK -- not the last pair.
	#
	# The first version of this compared the final report from each end and read 0.0m, which looked
	# like a triumph and was nothing of the kind: `--autopilot` spends the back half of a match parked
	# in a one-cell corridor, where a stationary mouse agrees perfectly over any link at all. A check
	# on a moving target has to be taken while the target moves.
	#
	# Paired by timestamp because the two ends CANNOT be paired by index. They booted seconds apart and
	# both report every five, so the Nth line of one is not the Nth moment of the other -- the exact
	# mistake `net_session.log_line` stamps its output to prevent, and which it records having already
	# caused a leak that was not one.
	var spread := _worst_spread(host_said, client_said)
	var moved := _travelled(client_said)
	var settled := _settled_spread(host_said, client_said)
	_check("the client's mouse actually moved (%.1fm) -- a parked one agrees trivially" % moved,
		moved > 3.0)
	_check("while moving, neither end lost track of it (worst %.1fm, under %.0fm)"
		% [spread, SPREAD_METRES],
		spread >= 0.0 and spread < SPREAD_METRES)
	# The one that would catch drift. Once it stops, latency accounts for nothing.
	_check("and once it stopped they agreed to within %.1fm (%.1fm)"
		% [SETTLED_METRES, settled],
		settled >= 0.0 and settled < SETTLED_METRES)

	print("\n-- and every full picture healed itself")
	# THE SELF-HEALING CLAIM, ASKED PROPERLY FOR THE FIRST TIME. These are unreliable, so at 12% loss
	# a good number of them genuinely did not arrive; the design answer has always been that the next
	# one is a complete state and repairs everything. What that means in evidence is that the client
	# ends up holding the same world the host does, having certainly missed some of the telling.
	# NOT AN EXACT COMPARISON OF THE TWO LAST LINES, and the first version of this file was, and it was
	# flaky within three runs. **The two logs are not simultaneous.** Each end reports every five
	# seconds on its own phase, and `net_session.log_line` stamps every line specifically because of
	# this -- it records that comparing two ends as though they were the same instant once produced "a
	# leak that was not one". `replication_audit` reaches for a tolerance for the same reason. This is
	# the third time that trap has been walked into in this project and the first time it was caught by
	# a suite going red rather than by reading the code.
	#
	# So the claim is the one that is phase-independent and stronger anyway: **the client invents
	# nothing.** Every pile it holds is a pile the host holds. A complete-state protocol under loss is
	# allowed to be a beat behind; it is not allowed to hold a cache that does not exist.
	var mine := _piles(_last_capture(client_said, "cheese world: hold \\[([^\\]]*)\\]"))
	var theirs := _piles(_last_capture(host_said, "cheese world: hold \\[([^\\]]*)\\]"))
	var phantom := PackedStringArray()
	for pile: String in mine:
		if not theirs.has(pile):
			phantom.append(pile)
	_check("the client holds %d caches and invented none of them" % mine.size(),
		not mine.is_empty() and phantom.is_empty())
	_check("and is missing none of the host's %d either" % theirs.size(),
		mine.size() >= theirs.size())
	_check("and the barricade the host made before its arena existed",
		client_said.contains("1.10,10=") and host_said.contains("audit barricades placed"))
	# Stores move continuously as ten mice spend, so this is a drift tolerance rather than an equality
	# -- again because the two reports are moments apart, not because the wire is lossy.
	var drift := _store_drift(host_said, client_said)
	_check("and the scoreboard is at most a wedge or two behind (%d off)" % drift,
		drift >= 0 and drift <= 4)
	_check("the earth still arrived, and still only what the crew may know",
		client_said.contains("earth: took ")
		and not client_said.contains("1.-18,18"))

	print("\n-- and it did not cost more to run badly")
	var out := _kbps(host_said, "wire out ([0-9.]+) KB/s")
	_check("a bad wire is not a more expensive one (%.1f KB/s)" % out,
		out > 0.0 and out < 20.0)


# ---------------------------------------------------------------------------------------- plumbing




## The furthest the two ends were ever from agreeing about one mouse, in metres, or -1 if there is not
## enough evidence to say.
##
## The client's `mine at` and the host's `peer N drives ... at` are the same mouse seen from both ends.
## Each client reading is matched to the host reading closest in time, and only when that gap is under
## half a report interval -- past that they are describing different moments and the difference between
## them is the clock, not the protocol.
func _worst_spread(host_said: String, client_said: String) -> float:
	var theirs := _stamped(host_said, "peer \\d+ drives .* at \\(([^)]*)\\)")
	var mine := _stamped(client_said, "mine at \\(([^)]*)\\)")
	if theirs.is_empty() or mine.is_empty():
		return -1.0

	var worst := -1.0
	for seen: Dictionary in mine:
		var nearest: Dictionary = {}
		var closest := 2500.0  # Half a report interval, in milliseconds.
		for other: Dictionary in theirs:
			var apart: float = absf(float(seen["at"]) - float(other["at"]))
			if apart < closest:
				closest = apart
				nearest = other
		if not nearest.is_empty():
			worst = maxf(worst, (seen["where"] as Vector3).distance_to(nearest["where"]))
	return worst


## Just the PLACES out of a cheese hold, dropping the counts. A pile's position is stable for as long as
## it exists; its count changes every time a mouse takes a wedge, so comparing counts across two reports
## taken moments apart measures the gap between the reports.
func _piles(hold: String) -> PackedStringArray:
	var places := PackedStringArray()
	for token: String in hold.split(" ", false):
		var cut := token.find("=")
		places.append(token.substr(0, cut) if cut > 0 else token)
	places.sort()
	return places


## How far apart the two ends' last scoreboards were, in wedges across both crews, or -1.
func _store_drift(host_said: String, client_said: String) -> int:
	var here := _last_capture(client_said, "cheese (\\d+/\\d+)")
	var there := _last_capture(host_said, "cheese (\\d+/\\d+)")
	if here.is_empty() or there.is_empty():
		return -1
	var mine := here.split("/")
	var theirs := there.split("/")
	if mine.size() != 2 or theirs.size() != 2:
		return -1
	return (
		absi(String(mine[0]).to_int() - String(theirs[0]).to_int())
		+ absi(String(mine[1]).to_int() - String(theirs[1]).to_int())
	)


## The last thing each end said, compared. Safe to pair without timestamps precisely because it is the
## settled case: a mouse that has not moved for ten seconds is in the same place in both logs whenever
## each of them happened to look.
func _settled_spread(host_said: String, client_said: String) -> float:
	var theirs := _stamped(host_said, "peer \\d+ drives .* at \\(([^)]*)\\)")
	var mine := _stamped(client_said, "mine at \\(([^)]*)\\)")
	if theirs.is_empty() or mine.is_empty():
		return -1.0
	return (mine[-1]["where"] as Vector3).distance_to(theirs[-1]["where"])


## Every `{at, where}` a pattern found, using the unix-millisecond stamp `NetSession.log_line` puts on
## every line -- which exists for precisely this comparison and says so.
func _stamped(source: String, pattern: String) -> Array[Dictionary]:
	var full := RegEx.create_from_string("\\[(\\d+)\\] .*%s" % pattern)
	var out: Array[Dictionary] = []
	for found: RegExMatch in full.search_all(source):
		var at := _vector(found.get_string(2))
		if at != Vector3.INF:
			out.append({"at": found.get_string(1).to_float(), "where": at})
	return out


func _vector(text: String) -> Vector3:
	var bits := text.split(",")
	if bits.size() != 3:
		return Vector3.INF
	return Vector3(
		String(bits[0]).strip_edges().to_float(),
		String(bits[1]).strip_edges().to_float(),
		String(bits[2]).strip_edges().to_float(),
	)


## How far the client's own mouse moved across every report, so "they agree" cannot be satisfied by a
## mouse that never went anywhere.
func _travelled(client_said: String) -> float:
	var pattern := RegEx.create_from_string("mine at \\(([^)]*)\\)")
	var walked := 0.0
	var last := Vector3.INF
	for found: RegExMatch in pattern.search_all(client_said):
		var at := _vector(found.get_string(1))
		if at == Vector3.INF:
			continue
		if last != Vector3.INF:
			walked += last.distance_to(at)
		last = at
	return walked


func _last_capture(source: String, pattern: String) -> String:
	var matches := RegEx.create_from_string(pattern).search_all(source)
	return "" if matches.is_empty() else matches[-1].get_string(1)


func _kbps(source: String, pattern: String) -> float:
	var got := _last_capture(source, pattern)
	return got.to_float() if got.is_valid_float() else 0.0


func _log_path(who: String) -> String:
	return ProjectSettings.globalize_path("user://link_audit_%s.log" % who)


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
