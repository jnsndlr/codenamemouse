class_name NetSession
extends Node
## The one object that knows whether this process is hosting, joined, or alone — and who is in
## which seat because of it.
##
## It owns a [NetTransport] and a [Seats], and it is deliberately the *only* thing that does. The
## director asks it questions; nothing else in the game has heard of a socket. That boundary is
## what lets `MatchDirector` stay the sim rather than becoming the sim *and* the netcode, which is
## the usual way a listen server turns into a rewrite.
##
## AN AUTOLOAD, so it outlives `change_scene`. Hosting starts at the title screen and has to still
## be hosting when the arena finishes loading; a session that lived in the arena would tear its own
## socket down every time somebody went back to the menu. It is the same argument
## `screenshot.gd` makes and the opposite of the one `settings.gd` makes, and the difference is
## whether the thing has a lifetime of its own.
##
## OFFLINE IS NOT A SPECIAL CASE — that is the design decision worth defending here. An offline
## match is a `Seats` with peer 1 in blue seat 0 and bots everywhere else, and `is_server()` is
## true, so every rule takes the host branch. Single player is a listen server with no clients,
## and there is no second code path to keep alive.

## Where a friend connects. Nothing negotiates this yet -- direct connect only, which is what the
## plan's "What we deliberately don't build yet" asks for.
const DEFAULT_PORT: int = 47800
## Nine other people is already past anything this game is designed for; the cap is here so a
## malformed command line cannot open a thousand-slot server.
const MAX_PEERS: int = 9

signal seating_changed()

## The host says the match is beginning. Emitted on a CLIENT only, and the reason it lives here
## rather than in `NetMatch` is that its whole job is reaching somebody who has no arena yet -- a
## `NetMatch` exists only inside the arena this signal is what makes you load.
signal match_starting()

## The wire dropped under us. DISTINCT FROM `go_offline`, which is also how a session starts and how
## a deliberate "leave the lobby" is expressed. This one is the failure, and the difference matters
## to whoever has to put it on screen: one of them is a thing the player did.
signal wire_lost()

var _transport: NetTransport
var _seats: Seats
var _local: int = NetTransport.SERVER_ID
## What `host` opened, so the lobby can print it. 0 when not hosting a socket.
var _port: int = 0
## Where `join` was pointed, for the one line of screen text that says what you are waiting on.
var _joined: String = ""
## Where `--audit-log` wants a copy of everything this file says. Empty in a normal run.
var _log_path: String = ""
## What the command line asked for, applied once the whole line has been parsed.
var _start: Array = []


## Everything this file reports, to stdout and — when `--audit-log <path>` was passed — to a file.
##
## `tools/seat_audit.gd` launches two whole game processes and has to read what each concluded
## about its own seating. `OS.create_process` hands back no pipe, and both processes share one
## `user://logs/` that they would clobber, so each is given a file of its own. Appended and closed
## per line, because the interesting case is reading it from another process while it still runs.
## STAMPED WITH WALL-CLOCK TIME, because the reader is another process. Two games started fourteen
## seconds apart both report every five seconds, so "the last line of each log" describes two
## moments that can be five seconds apart -- and five seconds is long enough for the fog to close
## over a corridor. Comparing them as though they were simultaneous produced a leak that was not
## one, which is a worse outcome than a missed bug: an invariant that cries wolf gets relaxed.
## Unix milliseconds rather than seconds-since-start, since only an absolute clock is shared.
func log_line(line: String) -> void:
	var stamped := "[%d] %s" % [Time.get_unix_time_from_system() * 1000.0, line]
	print("net: %s" % stamped)
	if _log_path.is_empty():
		return
	var file := FileAccess.open(_log_path, FileAccess.READ_WRITE) if FileAccess.file_exists(_log_path) \
		else FileAccess.open(_log_path, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line("net: %s" % stamped)
	file.close()


## Say goodbye properly on the way out.
##
## Without this a player who quits is noticed only when ENet's peer timeout expires — five to
## thirty seconds during which their crew is a mouse short, because the seat has not been handed
## to a bot yet. Closing the socket sends a real disconnect and the host reseats them at once.
##
## The seat audit found this: killing its client process outright left the host none the wiser,
## which is correct behaviour for a *crash* and was hiding the fact that the ordinary case — a
## person quitting — behaved identically.
func _exit_tree() -> void:
	if _transport != null:
		_transport.close()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_seats = Seats.new()
	_transport = ENetTransport.new()
	add_child(_transport)
	_transport.peer_joined.connect(_on_peer_joined)
	_transport.peer_left.connect(_on_peer_left)
	_transport.connection_lost.connect(_on_connection_lost)
	_transport.joined_server.connect(_on_joined_server)
	# THE SECOND LISTENER ON THIS SIGNAL, and deliberately so: `NetMatch` takes the same packets when
	# an arena exists, and the two do not overlap. Everything in the protocol except `START` is about
	# a match in progress and is ignored here; `START` is about one that has not begun, and there is
	# nothing in the arena to hear it.
	_transport.packet_received.connect(_on_packet)

	go_offline()
	_apply_command_line()


# ------------------------------------------------------------------------------------- the modes


## One human, nine bots, no socket. The state every session starts in.
func go_offline() -> void:
	_transport.close()
	_seats.clear()
	_port = 0
	_joined = ""
	_local = NetTransport.SERVER_ID
	_seats.seat_host(_local)
	seating_changed.emit()


func host(port: int = DEFAULT_PORT) -> Error:
	var err := _transport.host(port, MAX_PEERS)
	if err != OK:
		# Back to a playable state rather than a half-open one: a failed host must leave you able
		# to press Play, not stranded in a mode with no socket and no seats.
		go_offline()
		return err
	_seats.clear()
	_port = port
	_local = _transport.local_id()
	_seats.seat_host(_local)
	log_line("hosting on %d as peer %d" % [port, _local])
	seating_changed.emit()
	return OK


## `where` is "host", "host:port", or "host" with the default port implied.
func join(where: String) -> Error:
	var address := where
	var port := DEFAULT_PORT
	# rsplit, so an IPv6 literal's own colons do not get read as a port separator.
	var cut := where.rfind(":")
	if cut > 0:
		var tail := where.substr(cut + 1)
		if tail.is_valid_int():
			address = where.substr(0, cut)
			port = tail.to_int()

	var err := _transport.join(address, port)
	if err != OK:
		go_offline()
		return err
	_seats.clear()
	_joined = "%s:%d" % [address, port]
	log_line("joining %s" % _joined)
	return OK


## Tell everybody in the lobby to load the arena. Host only; harmless offline.
##
## RELIABLE, and it is worth saying why when so much of this protocol is not. Every unreliable
## message in here is a picture that will be sent again in a quarter of a second, so a lost one costs
## nothing. This one happens once. A player who missed it sits in a lobby watching a match they were
## invited to, and no later packet repairs that -- there is no periodic "by the way, we started".
func start_match() -> void:
	if not is_server() or not is_online():
		return
	_transport.broadcast(NetMessage.head(NetMessage.Kind.START).data_array, true)
	# The TRANSPORT's roster, which on a server is the clients and nothing else -- it is filled by
	# `peer_connected` and the host never connects to itself. Not `Seats.peers()`, which counts the
	# host among the seated and would report one player too many for the whole of the match.
	log_line("told %d peer(s) the match is beginning" % _transport.peers().size())


# ------------------------------------------------------------------------------------ questions


func seats() -> Seats:
	return _seats


## The port we are hosting on, or 0. Kept because the lobby has to tell a human a number, and asking
## the socket is better than the lobby remembering what it passed in.
func hosting_port() -> int:
	return _port if is_server() and is_online() else 0


## `host:port` this session was pointed at, or empty when not joining anybody.
func joined_address() -> String:
	return _joined


## The best guess at "what should my friend type", and honest that it is a guess.
##
## A LAN address is the one this can actually know. Over the internet the useful number is the
## router's public address with a forwarded port, and nothing on this machine can be sure of either
## -- so the lobby says what it knows and says the rest out loud rather than printing a number that
## works on one network and silently fails on every other.
func lan_address() -> String:
	for address: String in IP.get_local_addresses():
		if address.contains(":") or address.begins_with("127."):
			continue  # IPv6 and loopback: correct addresses, useless instructions.
		if (
			address.begins_with("192.168.") or address.begins_with("10.")
			or address.begins_with("172.")
		):
			return address
	return ""


## Size the crews to match whatever the map's director is set to.
##
## `crew_size` is an `@export` the README tells you to fiddle with, and a roster built to its own
## default would silently ignore it — the director would ask `roster.crew_size()`, get 5, and the
## dial would do nothing. That is the worst kind of broken setting: it looks adjustable.
##
## Refused once anybody else is seated, because resizing crews mid-match would either strand a
## peer in a seat that no longer exists or invent chairs nobody is in. Called from the director's
## `_ready`, which on a host is always before a client can have arrived.
func ensure_crew_size(size: int) -> void:
	if size == _seats.crew_size():
		return
	if _seats.total_humans() > 1:
		push_warning("net: crew size cannot change with %d people seated" % _seats.total_humans())
		return
	_seats = Seats.new(size)
	if is_server():
		_seats.seat_host(_local)
	seating_changed.emit()


func transport() -> NetTransport:
	return _transport


## True when this machine owns the simulation: hosting, or offline. The question the director asks
## before applying any rule.
func is_server() -> bool:
	return _transport.is_server()


func is_online() -> bool:
	return _transport.is_connected_up()


## Online AND actually through the door. What replication must wait for.
func is_established() -> bool:
	return _transport.is_established()


## This machine's peer id. `SERVER_ID` offline, which is why an offline match needs no special
## case: the local player really is peer 1, and really is the authority.
func local_peer() -> int:
	return _local


## `[team, seat]` for this machine, or empty while a client is still waiting to be seated.
func local_seat() -> Array:
	return _seats.seat_of(_local)


# ------------------------------------------------------------------------------------ the wiring


func _on_peer_joined(id: int) -> void:
	if not is_server():
		# On a client this fires for the server itself. A client does not run the seat table --
		# it is told what its seat is, which is step 4's packet and does not exist yet.
		return
	var got := _seats.claim(id)
	if got.is_empty():
		log_line("peer %d arrived and the match is full" % id)
		return
	log_line("peer %d takes %s seat %d -- %s" % [id, Team.name_of(got[0]), got[1], _seats.describe()])
	seating_changed.emit()


func _on_peer_left(id: int) -> void:
	if not is_server():
		return
	var freed := _seats.release(id)
	if freed.is_empty():
		return
	# The seat does NOT disappear. A crew that loses a human keeps its mouse and a bot takes over,
	# because the alternative is that quitting hands your opponents a numbers advantage.
	log_line("peer %d leaves %s seat %d to a bot -- %s" % [id, Team.name_of(freed[0]), freed[1], _seats.describe()])
	seating_changed.emit()


func _on_joined_server() -> void:
	_local = _transport.local_id()
	log_line("connected as peer %d" % _local)
	seating_changed.emit()


func _on_connection_lost() -> void:
	log_line("connection lost -- back to offline")
	# Said BEFORE the state is torn down, so a listener can still ask what it was losing.
	wire_lost.emit()
	go_offline()


func _on_packet(from: int, bytes: PackedByteArray) -> void:
	if is_server() or from != NetTransport.SERVER_ID:
		return
	if NetMessage.kind_of(bytes) == NetMessage.Kind.START:
		log_line("the host says the match is beginning")
		match_starting.emit()


# --------------------------------------------------------------------------------- command line


## `--host [port]` and `--join <address[:port]>`, read once at startup.
##
## FLAGS BEFORE BUTTONS, and that is a testability decision rather than a shortcut. Checkpoint 1 is
## "two windows on one machine", and with flags a tool can launch both and assert what happened;
## with only a Host button it can be demonstrated and never checked. The plan's own warning is that
## the failures that matter here are the ones that still look right from inside a match.
##
## Godot hands the game everything after a bare `--`, so these cannot collide with engine flags.
func _apply_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	for i: int in range(args.size()):
		var arg := String(args[i])
		var next := String(args[i + 1]) if i + 1 < args.size() else ""
		if arg == "--audit-log" and not next.is_empty():
			_log_path = next
			# Truncated on adoption, so a rerun is not read as the previous run's evidence --
			# the exact mistake the M6.5 logging work was about.
			var fresh := FileAccess.open(_log_path, FileAccess.WRITE)
			if fresh != null:
				fresh.close()
			continue
		if arg == "--host":
			_start = ["host", next]
		if arg == "--join":
			_start = ["join", next]

	# ACTED ON AFTER THE WHOLE LINE IS READ, not the moment the flag is seen. `--audit-log` may
	# come after `--host`, and starting the socket first would send the interesting lines to
	# stdout only -- which is precisely the evidence the seat audit exists to read.
	if _start.is_empty():
		return
	if _start[0] == "host":
		host(_start[1].to_int() if _start[1].is_valid_int() else DEFAULT_PORT)
	elif not _start[1].is_empty():
		join(_start[1])
	else:
		push_warning("net: --join needs an address")
