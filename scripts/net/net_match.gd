extends Node
## The match on a wire: input up, snapshots down, and a client that draws what it is told.
##
## THE SERVER SIDE IS SMALL BECAUSE `MatchDirector` WAS ALREADY THE SIM. The plan's survey promised
## this and it held — every rule already resolves in one `_physics_process` on one node, so nothing
## had to be gathered up first. What this file adds is the two ends of a pipe: a received frame
## becomes `Mouse.drive()`, and every mouse's pose becomes bytes.
##
## THE CLIENT SIDE IS SMALL FOR A DIFFERENT REASON: it does almost nothing on purpose. There is no
## prediction and no client-side rule evaluation, because the plan defers prediction until it
## demonstrably hurts and because the alternative is two implementations of every rule that have to
## agree. A client sends what its keyboard wanted and draws the world it is sent.
##
## NO SPAWN MESSAGES, WHICH IS WHAT STEP 3 BOUGHT. The population of the world is the seat roster:
## ten chairs, always occupied. A client builds its mice from the seating message and every
## snapshot afterwards only has to say where they are. Spawn/despawn replication is one of the
## fiddliest parts of any netcode and this design does not have it.
##
## WHAT IS NOT HERE YET, and neither is a stub pretending otherwise: score, cheese, health, the
## banner, and the tunnel network. Those are the "on change" half of step 4 and the filtered half
## of step 5. **Snapshots go to everyone unfiltered, so nothing secret may ever be added to one.**

## Snapshots per second. The plan's number. Deliberately below the physics rate: the client
## interpolates, and sending every tick would double the bandwidth to buy smoothness the
## interpolation already provides.
const SNAPSHOT_HZ: float = 30.0

@export var director_path: NodePath

var _net: NetSession
var _director: MatchDirector
var _transport: NetTransport
var _since_snapshot: float = 0.0
var _tick: int = 0
## Mice this client built for seats it does not simulate, keyed the way `Snapshot` keys them.
var _puppets: Dictionary = {}
## The last seating the server sent us, on a client. The server uses `Net.seats()` directly.
var _client_seats: Seats
## Until the seating arrives, how long before asking again. Zero, so the first ask is immediate.
var _hello_left: float = 0.0
## Counted and reported, because "is it actually working" is otherwise unanswerable from outside
## the process -- and a player saying "it felt laggy" is worth very little next to a log saying
## four snapshots arrived in the last five seconds.
var _received: int = 0
var _applied: int = 0
## Poses that arrived mid-swing. Counted because a swing is the only *action* in this protocol --
## everything else a snapshot carries is a position -- and "melee crosses the wire" is half of what
## checkpoint 1 claims. Poses rather than swings, deliberately: one swipe spans a dozen packets and
## calling that twelve swings would be a lie in the log.
var _swings: int = 0
var _report_left: float = REPORT_SECONDS
## Inputs the server took off the wire since the last report. Counted because "the client is
## connected" and "the client is being listened to" are different claims and look identical.
var _inputs: int = 0
## `--autopilot`: drive the local mouse with a synthetic intent instead of a keyboard.
##
## THE MULTIPLAYER EQUIVALENT OF `bot_soak.gd`, and it exists for the same reason that file does:
## you cannot soak-test a network by holding W. A headless client has no keyboard, so without this
## every automated two-process test watches a mouse stand perfectly still and cannot tell a working
## input path from a broken one -- which is precisely the failure that looks like success.
var _autopilot: bool = false

## How often to say what the wire is doing. Rare enough to be ignorable, often enough that a
## thirty-second playtest produces several.
const REPORT_SECONDS: float = 5.0

## How often an unseated client asks who it is. See `NetMessage` for why it has to ask at all.
##
## REPEATED RATHER THAN SENT ONCE, which is the cheap way to be right about a question with two
## racing answers: the client may reach its arena before the server has seated it, or be seated
## long before it reaches its arena, and a single hello at the wrong end of that race is a client
## that watches ten mice it cannot identify for the rest of the match. It stops the moment an
## answer arrives, so the cost of the repetition is one small packet a second during a loading
## screen.
const HELLO_SECONDS: float = 1.0


func _ready() -> void:
	_net = get_node_or_null(^"/root/Net") as NetSession
	_director = get_node_or_null(director_path) as MatchDirector
	if _net == null or _director == null:
		# An audit builds arenas without a session. Replication simply does not happen, which is
		# the correct behaviour and not an error worth shouting about.
		set_physics_process(false)
		return

	_transport = _net.transport()
	_transport.packet_received.connect(_on_packet)
	_net.seating_changed.connect(_on_seating_changed)

	_autopilot = OS.get_cmdline_user_args().has("--autopilot")
	if not _net.is_server():
		_become_client()
	_on_seating_changed()


## Walk forward, turning slowly, swinging every couple of seconds. Enough to prove movement,
## facing and melee all survive the trip; not enough to be mistaken for an AI.
func _autopilot_frame() -> InputFrame:
	var frame := InputFrame.new()
	var t := Time.get_ticks_msec() / 1000.0
	frame.move = Vector2(0.0, 1.0)
	# An aim point that orbits, so facing changes and the snapshot's facing field is exercised
	# rather than staying at whatever the spawn happened to set.
	var me := _director.local_mouse()
	var here := me.global_position if me != null else Vector3.ZERO
	frame.aim_point = here + Vector3(cos(t * 0.7), 0.0, sin(t * 0.7)) * 4.0
	frame.set_pressed(InputFrame.Action.ATTACK, fmod(t, 2.0) < 0.05)
	return frame


func _physics_process(delta: float) -> void:
	# ESTABLISHED, not merely online. A client is "online" the instant `join()` returns and is not
	# reachable until the handshake completes -- several seconds when the arena is still loading --
	# and sending into that gap produced one ENet error per physics tick.
	if not _net.is_established():
		return
	_report(delta)
	if _net.is_server():
		_since_snapshot += delta
		if _since_snapshot >= 1.0 / SNAPSHOT_HZ:
			_since_snapshot = 0.0
			_broadcast_snapshot()
			_received += 1
		return
	if _client_seats == null:
		_say_hello(delta)
	_send_input()


## Counts AND POSITIONS, and the positions are the half that can be checked from outside.
##
## A count says the pipe is moving bytes. It cannot say the bytes mean anything: the "285 inputs a
## second while the mouse stood still" bug produced a perfectly healthy set of counts on both ends.
## So each end says where it thinks a mouse is, in world coordinates, and
## `tools/replication_audit.gd` reads the two logs and compares them. That is the only vantage
## point from which "the server is moving somebody else's mouse" is visible at all.
func _report(delta: float) -> void:
	_report_left -= delta
	if _report_left > 0.0:
		return
	_report_left = REPORT_SECONDS
	var mine := _director.local_mouse()
	if _net.is_server():
		_net.log_line("sent %d snapshots for %d mice, took %d inputs, mine at %s" % [
			_received, _seated_count(), _inputs, _where(mine),
		])
		_report_remotes()
	else:
		_net.log_line("received %d snapshots, %d poses, a swing in %d of them, mine at %s" % [
			_received, _applied, _swings, _where(mine),
		])
	_received = 0
	_applied = 0
	_inputs = 0
	_swings = 0


## Where the server thinks each remote human's mouse is -- one line per person in the match.
##
## The claim being written down is the security boundary in `_apply_input`: a packet drives the
## chair its sender sits in and no other. From inside either process that is invisible; set
## alongside the client's own "mine at", it is checkable.
func _report_remotes() -> void:
	var roster := _net.seats()
	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(roster.crew_size()):
			var who := roster.occupant(side, seat)
			if who == Seats.BOT or who == _net.local_peer():
				continue
			_net.log_line("peer %d drives %s seat %d at %s" % [
				who, Team.name_of(side), seat, _where(_director.seat_mouse(side, seat)),
			])


## Rounded to a decimetre. The log is read by another process and a full float is noise in it.
func _where(mouse: Mouse) -> String:
	return "?" if mouse == null else str(mouse.global_position.snapped(Vector3.ONE * 0.1))


func _seated_count() -> int:
	var roster := _net.seats()
	var count := 0
	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(roster.crew_size()):
			if _director.seat_mouse(side, seat) != null:
				count += 1
	return count


# ------------------------------------------------------------------------------------ the server


func _broadcast_snapshot() -> void:
	var roster := _net.seats()
	var shot := Snapshot.new()
	_tick += 1
	shot.tick = _tick

	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(roster.crew_size()):
			var mouse := _director.seat_mouse(side, seat)
			if mouse == null:
				continue
			var flags := 0
			if mouse.is_scruffed():
				flags |= Snapshot.Flag.SCRUFFED
			if mouse.is_carrying():
				flags |= Snapshot.Flag.CARRYING
			if mouse.is_swinging():
				flags |= Snapshot.Flag.SWINGING
			shot.add(
				Snapshot.key_for(side, seat, roster.crew_size()),
				mouse.global_position,
				mouse.get_facing_angle(),
				flags
			)

	# Unreliable, and see `net_message.gd` for why that is a decision rather than a default.
	_transport.broadcast(shot.to_bytes(), false)


## Somebody's keyboard, from somewhere else. Applied to the mouse in THEIR seat and nowhere else.
##
## THE SEAT LOOKUP IS THE SECURITY BOUNDARY, such as it is. A packet cannot name the mouse it wants
## to drive — it drives whichever chair its sender is sitting in, so a client cannot steer anybody
## but itself no matter what it sends. That is the shape the plan asks for: cheating becomes
## structurally impossible rather than merely discouraged.
func _apply_input(from: int, bytes: PackedByteArray) -> void:
	var seated := _net.seats().seat_of(from)
	if seated.is_empty():
		return
	var frame := InputFrame.from_bytes(bytes.slice(1))
	if frame == null:
		return
	var mouse := _director.seat_mouse(seated[0], seated[1])
	if mouse != null:
		mouse.drive(frame)
		_inputs += 1


# ------------------------------------------------------------------------------------ the client


## On a client nothing simulates. Every mouse in the scene becomes a puppet, the director stops
## applying rules, and this node's whole job becomes sending a frame and applying poses.
func _become_client() -> void:
	_director.set_simulating(false)
	for node: Node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse != null:
			mouse.set_puppet(true)


## "I am in a match now, and I do not know who I am." Sent until answered.
func _say_hello(delta: float) -> void:
	_hello_left -= delta
	if _hello_left > 0.0:
		return
	_hello_left = HELLO_SECONDS
	_transport.send(NetTransport.SERVER_ID, NetMessage.head(NetMessage.Kind.HELLO).data_array, true)


func _send_input() -> void:
	var me := _director.local_mouse()
	if me == null:
		return
	if _autopilot:
		me.drive(_autopilot_frame())
	var out := NetMessage.head(NetMessage.Kind.INPUT)
	out.put_data(me.input().to_bytes())
	_transport.send(NetTransport.SERVER_ID, out.data_array, true)


func _apply_snapshot(bytes: PackedByteArray) -> void:
	var shot := Snapshot.from_bytes(bytes)
	if shot == null:
		return
	# OUT-OF-ORDER SNAPSHOTS ARE DROPPED, not applied. They are sent unreliably, so they can and
	# will arrive shuffled, and applying an older one after a newer one drags every mouse backwards
	# for a frame -- a rubber-band that looks exactly like bad interpolation and is not.
	if shot.tick <= _tick:
		return
	_tick = shot.tick
	_received += 1

	for pose: Snapshot.Pose in shot.poses:
		var mouse := _puppet_for(pose.key)
		if mouse != null:
			mouse.apply_pose(pose.position, pose.facing, pose.flags)
			_applied += 1
			if (pose.flags & Snapshot.Flag.SWINGING) != 0:
				_swings += 1


func _puppet_for(key: int) -> Mouse:
	if _client_seats == null:
		return null
	var crew := _client_seats.crew_size()
	var side := key / crew
	var seat := key % crew
	if side > Team.RED:
		return null
	var mouse := _director.seat_mouse(side, seat)
	if mouse != null:
		return mouse
	return _puppets.get(key)


# ----------------------------------------------------------------------------------- the seating


func _on_seating_changed() -> void:
	if not _net.is_server():
		return
	var roster := _net.seats()
	# Reconcile the world with the table BEFORE telling anyone about it: a chair that just gained
	# a human needs a mouse that listens to one, and a chair that lost theirs needs its bot back.
	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(roster.crew_size()):
			if side == Team.BLUE and seat == Seats.HOST_SEAT:
				continue  # The host's own chair holds the authored Player and is never swapped.
			# DEFERRED for the same reason `_spawn_bots` is: a node cannot gain siblings while its
			# parent is still building its children, and a mouse added during `_ready` has its own
			# `_ready` deferred -- so `@onready var _visual` is still null when `_send_home` turns
			# it. That surfaced as a wall of "Invalid assignment of property 'rotation' on a base
			# object of type 'Nil'", which names neither the mouse nor the cause.
			_director.seat_remote.call_deferred(side, seat, roster.is_human(side, seat))

	_send_seating(NetTransport.ALL_PEERS)


## The whole table, to one peer or to everybody.
##
## SENT ON BOTH A CHANGE AND A REQUEST, and it needs both. The broadcast is for the clients already
## in the match, who have to hear that somebody arrived; the reply to `HELLO` is for the client
## that has only just got an arena and missed everything said before it existed. Neither covers the
## other, and the one that was missing is the one nothing could see -- see `net_message.gd`.
func _send_seating(to: int) -> void:
	var roster := _net.seats()
	var out := NetMessage.head(NetMessage.Kind.SEATING)
	out.put_u8(roster.crew_size())
	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(roster.crew_size()):
			out.put_u32(roster.occupant(side, seat))
	_transport.send(to, out.data_array, true)


func _apply_seating(bytes: PackedByteArray) -> void:
	var into := NetMessage.body(bytes, 2)
	if into == null:
		return
	var crew := into.get_u8()
	if bytes.size() != 2 + 2 * crew * 4:
		return
	_client_seats = Seats.new(crew)
	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(crew):
			var who := into.get_u32()
			if who > Seats.BOT:
				_client_seats.sit(side, seat, who)
	_director.adopt_seating(_client_seats, _net.local_peer())


# ------------------------------------------------------------------------------------- the door


func _on_packet(from: int, bytes: PackedByteArray) -> void:
	match NetMessage.kind_of(bytes):
		NetMessage.Kind.INPUT:
			if _net.is_server():
				_apply_input(from, bytes)
		NetMessage.Kind.SNAPSHOT:
			# Only from the server. A client that could broadcast poses could move every mouse
			# in the match, which is the whole game.
			if not _net.is_server() and from == NetTransport.SERVER_ID:
				_apply_snapshot(bytes)
		NetMessage.Kind.SEATING:
			if not _net.is_server() and from == NetTransport.SERVER_ID:
				_apply_seating(bytes)
		NetMessage.Kind.HELLO:
			if _net.is_server():
				_send_seating(from)
