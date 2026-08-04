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
## NO MOUSE SPAWN MESSAGES, WHICH IS WHAT STEP 3 BOUGHT. The population is the seat roster:
## ten chairs, always occupied. A client builds its mice from the seating message and every
## snapshot afterwards only has to say where they are. Spawn/despawn replication is one of the
## fiddliest parts of any netcode and this design does not have it.
##
## TWO CLOCKS, NOT ONE. Poses go out thirty times a second because they are smooth; the scoreboard
## goes out four times a second because none of it is. Splitting them is what lets the scoreboard be
## sent whole every time — see `net_message.gd` — instead of as a set of changes that can be missed.
##
## Runtime cheese is a separate, slow, complete world picture. It cannot ride in the mouse
## snapshot because a lost spawn or removal must heal, and it cannot ride in the tunnel payload
## because cheese is deliberately public to both crews. Barricades and sonar marks remain the two
## runtime objects this protocol does not yet reproduce on clients.

## Snapshots per second. The plan's number. Deliberately below the physics rate: the client
## interpolates, and sending every tick would double the bandwidth to buy smoothness the
## interpolation already provides.
const SNAPSHOT_HZ: float = 30.0

## Scoreboards per second. A tenth of the pose rate, because none of what it carries is smooth --
## the clock is read in whole seconds, the score changes a handful of times a match, and a quarter
## second of a stale cheese counter is not a thing anybody can perceive. See `net_message.gd` for
## why this is periodic rather than sent on change.
const MATCH_HZ: float = 4.0

## How often each client is offered the earth it is allowed to know about.
##
## Slower than the scoreboard because a cell takes half a second of held effort to open, so nothing
## underground can change faster than this notices -- and because the work is per-client and walks
## every dug cell, which is the one thing in this file that is not free. Sent reliably and only
## when something has actually changed, so the ordinary tick is no packet at all.
const EARTH_HZ: float = 2.0

## Cheese piles do not move. Twice a second makes a pickup or drop visible within half a second,
## while the complete-state shape means a lost packet needs no acknowledgement or special repair.
const CHEESE_HZ: float = 2.0

@export var director_path: NodePath

var _net: NetSession
var _director: MatchDirector
var _transport: NetTransport
var _since_snapshot: float = 0.0
var _since_state: float = 0.0
var _since_earth: float = 0.0
var _since_cheese: float = 0.0
var _tick: int = 0
var _cheese_tick: int = 0
var _tunnels: TunnelNetwork
## The per-crew filter, on the server. See `tunnel_view.gd` -- it is the one place that decides
## what a client is allowed to know about the earth, and it is one place on purpose.
var _view: TunnelView
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
## Cells of earth put on the wire, and taken off it.
var _earth_sent: int = 0
var _earth_taken: int = 0
## Cells taken BACK off a client: the fog closing. Counted separately because "we never send what
## they may not know" and "we take it away again when they stop being allowed" are different
## promises, and the second one is the one that is easy to leave out and impossible to see.
var _earth_forgotten: int = 0
## Scoreboards taken off the wire. Separate from the pose counters because they arrive on their own
## clock, and "the mice move but the score never changes" is a specific failure worth naming.
var _states: int = 0
## Complete cheese-world pictures received. Separate because a correct scoreboard alongside a
## stale yard is exactly the disagreement this payload exists to prevent.
var _cheese_states: int = 0
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
## Seconds of lawn left before the autopilot starts looking for a way down.
var _autopilot_surface: float = AUTOPILOT_SURFACE_SECONDS
## Seconds until the next attempt at a shaft. Zero means "try on the next tick".
var _autopilot_left: float = 0.0
## Whether the dig button is already down, so the PRESS bit is set on the first tick only -- which
## is what a real button does and what the rock branch of `dig_controller.gd` distinguishes.
var _autopilot_digging: bool = false
## Whether E is owed on the next tick, having just pressed F.
var _autopilot_burrow: bool = false
## Latched the first time a pose says this mouse is off the lawn. See `_autopilot_frame`.
var _autopilot_down: bool = false

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

## A cache safely outside every bot route, used only when the two-process audit asks for it. The
## host creates it before the client even enters an arena, so seeing it at the other end proves a
## complete state heals a missed runtime spawn rather than merely forwarding a well-timed event.
const AUDIT_CHEESE_AT: Vector3 = Vector3(31.0, 0.0, -31.0)


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

	# Found by group rather than wired, like everything else that has to be reachable from a node
	# spawned at runtime. Both are optional: an arena without tunnels is a valid arena, and the
	# audits build several.
	_tunnels = get_tree().get_first_node_in_group(TunnelNetwork.NETWORK_GROUP) as TunnelNetwork
	var sight := get_tree().get_first_node_in_group(TunnelSight.SIGHT_GROUP) as TunnelSight
	if _tunnels != null and sight != null:
		_view = TunnelView.new(_tunnels, sight)

	_autopilot = OS.get_cmdline_user_args().has("--autopilot")
	if _net.is_server():
		_director.event.connect(_on_event)
		if OS.get_cmdline_user_args().has("--audit-cheese"):
			_director.call("_drop_cheese", AUDIT_CHEESE_AT, 3)
			_net.log_line("audit cheese placed before the client arena exists")
	else:
		_become_client()
	_on_seating_changed()


## How long the autopilot walks the lawn before it starts trying to get under it. Long enough that
## the position spread `replication_audit.gd` measures is earned on the surface, where a mouse can
## actually move; a corridor is one cell wide and a mouse in one barely does.
const AUTOPILOT_SURFACE_SECONDS: float = 14.0
## Seconds between attempts to sink a shaft. A refusal is ordinary -- nest clearance, another
## entrance too close, paving -- so this retries rather than giving up, and slowly enough that a
## refusal message is not printed sixty times a second.
const AUTOPILOT_SHAFT_SECONDS: float = 3.0
## How long the autopilot points at one neighbouring cell before trying the next. Comfortably more
## than the ~1.5 seconds a Generalist takes to open a tile -- see `_autopilot_frame`.
const AUTOPILOT_SIDE_SECONDS: float = 4.0

## Walk forward, turning slowly, swinging every couple of seconds -- and then go underground and
## dig. Enough to prove movement, facing, melee and now DIGGING all survive the trip; not enough to
## be mistaken for an AI.
##
## THE DIGGING HALF EXISTS BECAUSE OF WHAT M7 JUST CHANGED. Until the controls became children of a
## mouse, a remote human's DIG bits arrived at a server with nothing to consume them -- and that
## failure is completely silent: the packets are counted, the seat is right, the mouse moves, and
## the earth simply never opens. A headless client has no keyboard, so without this every automated
## test watches a mouse that would not have dug anyway and cannot tell the two apart.
##
## SCRIPTED OFF THE MOUSE'S OWN PLANE, not off a timer, because "am I underground yet" is the only
## honest cue: the shaft is cut by the *server* and the client finds out about it in a pose. A
## timer would be this suite testing its own guess at the round trip.
func _autopilot_frame() -> InputFrame:
	var frame := InputFrame.new()
	var t := Time.get_ticks_msec() / 1000.0
	var me := _director.local_mouse()
	var here := me.global_position if me != null else Vector3.ZERO
	# An aim point that orbits, so facing changes and the snapshot's facing field is exercised
	# rather than staying at whatever the spawn happened to set.
	frame.aim_point = here + Vector3(cos(t * 0.7), 0.0, sin(t * 0.7)) * 4.0

	if me == null or me.get_plane() == 0:
		frame.move = Vector2(0.0, 1.0)
		frame.set_pressed(InputFrame.Action.ATTACK, fmod(t, 2.0) < 0.05)
		if _autopilot_surface > 0.0:
			_autopilot_surface -= 1.0 / 60.0
			return frame
		# ONE F AND ONE E PER ATTEMPT, AND NEVER AGAIN ONCE IT IS DOWN. E takes whichever shaft the
		# cell has, up OR down, so pressing it on every tick while waiting for the pose that says
		# "you are underground now" walks the mouse down the shaft and straight back up it. The
		# round trip is two poses long and the mouse oscillated for the whole run -- which is not a
		# bug in the transit, it is exactly what holding the key would do to a person.
		if _autopilot_down:
			return frame
		_autopilot_left -= 1.0 / 60.0
		if _autopilot_left <= 0.0:
			# Cut a mouth. The shaft has to exist before there is anything to climb down.
			_autopilot_left = AUTOPILOT_SHAFT_SECONDS
			_autopilot_burrow = true
			frame.set_pressed(InputFrame.Action.SHAFT_DOWN, true)
		elif _autopilot_burrow:
			_autopilot_burrow = false
			frame.set_pressed(InputFrame.Action.BURROW, true)
		return frame

	_autopilot_down = true

	# Underground: stand still and hold the dig button on a neighbouring cell.
	#
	# AIMED AT A CELL CENTRE, NOT A DISTANCE AHEAD. The first version aimed one metre along the
	# facing, which lands on the boundary of the cell the mouse is already standing in -- and
	# `_aimed_cell` refuses a cell that is already dug, so the hold never had a target and the run
	# proved only that the F key worked. `cell_to_world` puts the aim squarely in the next cell.
	#
	# STILL, AND SLOWLY. The second version walked and rotated the aim once a second, and opened
	# nothing at all: progress belongs to the tile you are POINTING AT, so moving the aim -- or
	# moving the mouse, which moves the cell the aim is measured from -- resets it. A Generalist
	# needs about a second and a half per tile, so anything faster than this is a mouse that starts
	# four digs and finishes none. That is a real property of the control and not a quirk of the
	# harness; a person holding the button learns it in one corridor.
	if _tunnels != null:
		var cell := _tunnels.world_to_cell(here)
		var index := int(t / AUTOPILOT_SIDE_SECONDS) % TunnelNetwork.SIDES.size()
		frame.aim_point = _tunnels.cell_to_world(me.get_plane(), cell + TunnelNetwork.SIDES[index])
	frame.set_held(InputFrame.Action.DIG, true)
	frame.set_pressed(InputFrame.Action.DIG, not _autopilot_digging)
	_autopilot_digging = true
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
		_since_state += delta
		if _since_state >= 1.0 / MATCH_HZ:
			_since_state = 0.0
			_broadcast_state()
		_since_earth += delta
		if _since_earth >= 1.0 / EARTH_HZ:
			_since_earth = 0.0
			_send_earth()
		_since_cheese += delta
		if _since_cheese >= 1.0 / CHEESE_HZ:
			_since_cheese = 0.0
			_broadcast_cheese()
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
		_net.log_line("and %d scoreboards" % _states)
		_net.log_line("and %d cheese-world pictures" % _cheese_states)
	# THE SAME LINE FROM BOTH ENDS, built by the same code out of the same accessors. Two formats
	# would make the comparison a comparison of two formatters; one means the audit is reading the
	# same question answered twice, which is the only version of this that proves anything.
	_net.log_line(_scoreboard())
	_report_cheese()
	_report_earth()
	_earth_sent = 0
	_earth_taken = 0
	_earth_forgotten = 0
	_received = 0
	_applied = 0
	_inputs = 0
	_swings = 0
	_states = 0
	_cheese_states = 0


## The earth, as cells, from whichever end this is.
##
## THE CELLS THEMSELVES, NOT A COUNT, and that is the difference between an audit that can see the
## leak and one that cannot. Counts would say a client holds forty cells; only the coordinates say
## *which* forty, and the whole question of this milestone is whether any of them are the enemy's.
## A run produces a few dozen, which is a few kilobytes of log and worth every byte.
##
## The host prints two sets: everything a crew is ALLOWED to know -- the filter's own predicate,
## `TunnelSight.knows`, asked directly so the audit is checking the rule rather than the sender's
## opinion of it -- and everything dug anywhere. The client prints what it actually holds. The
## invariant is that the third is inside the first.
func _report_earth() -> void:
	if _tunnels == null:
		return
	if not _net.is_server():
		_net.log_line("earth: took %d, hold %s" % [_earth_taken, _cells_of(-1)])
		return
	_net.log_line("earth: sent %d, took back %d, all %s" % [
		_earth_sent, _earth_forgotten, _cells_of(-1),
	])
	for side: int in [Team.BLUE, Team.RED]:
		_net.log_line("earth %s may know %s" % [Team.name_of(side), _cells_of(side)])


## The public cheese world, from either end. Positions and counts rather than only a total: two
## worlds can both contain seven piles while disagreeing about every place and amount in them.
func _report_cheese() -> void:
	var parts := PackedStringArray()
	for node: Node in get_tree().get_nodes_in_group(CheeseCache.GROUP):
		var cache := node as CheeseCache
		if cache == null or cache.is_empty() or cache.is_queued_for_deletion():
			continue
		parts.append("%.1f,%.1f=%d" % [
			cache.global_position.x, cache.global_position.z, cache.wedges,
		])
	parts.sort()
	_net.log_line("cheese world: hold [%s]" % " ".join(parts))


## `plane.x,y` for every cell, space separated. `side` of -1 is every dug cell there is.
func _cells_of(side: int) -> String:
	var sight := get_tree().get_first_node_in_group(TunnelSight.SIGHT_GROUP) as TunnelSight
	var parts := PackedStringArray()
	for plane: int in range(1, TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _tunnels.dug_cells(plane):
			if side >= 0 and (sight == null or not sight.knows(side, plane, cell)):
				continue
			parts.append("%d.%d,%d" % [plane, cell.x, cell.y])
	return "[%s]" % " ".join(parts)


## What this machine believes the match is. Asked of the director, which on a host is the sim and
## on a client is whatever the last scoreboard said -- so the two lines are comparable exactly when
## replication is working, and not otherwise.
func _scoreboard() -> String:
	return "score %d-%d, cheese %d/%d, clock %d, banners %d/%d" % [
		_director.score_of(Team.BLUE), _director.score_of(Team.RED),
		_director.cheese_of(Team.BLUE), _director.cheese_of(Team.RED),
		ceili(_director.time_left()),
		_director.banner_of(Team.BLUE).state, _director.banner_of(Team.RED).state,
	]


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
##
## Health rides along because it is the one part of a pose that is neither a position nor a bit,
## and a byte that is quietly always 255 -- because nothing ever wrote it, or because the ratio was
## scaled by the wrong maximum -- is invisible in a game where most mice are unhurt most of the
## time. Said out loud on both ends, it can be compared.
func _where(mouse: Mouse) -> String:
	if mouse == null:
		return "?"
	return "%s health %d plane %d %s" % [
		str(mouse.global_position.snapped(Vector3.ONE * 0.1)),
		int(mouse.get_health_ratio() * 255.0),
		mouse.get_plane(),
		_earth_moved_by(mouse),
	]


## What this mouse's own controls have opened: corridor cells, and shafts.
##
## THE POINT IS THE ASYMMETRY. The controls are children of the mouse now, so these are the host's
## answer for a *particular chair* -- and a client running the identical controller on the identical
## intent reports zero, because a puppet never reaches for the earth. Neither figure means anything
## alone; together they are the only way a suite can tell "a remote human dug" from "somebody dug",
## since `dig()` records which crew learnt a cell and never whose hand it was.
##
## THE TWO ARE PRINTED SEPARATELY because they are different claims: a shaft is one keypress and a
## corridor cell is half a second of holding, and an audit that adds them can pass on the press.
func _earth_moved_by(mouse: Mouse) -> String:
	var digger := mouse.get_node_or_null(^"DigController")
	if digger == null:
		return "cut - sank -"
	return "cut %d sank %d" % [int(digger.call("cells_cut")), int(digger.call("shafts_cut"))]


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
			if mouse.is_swinging():
				flags |= Snapshot.Flag.SWINGING
			flags |= (mouse.get_plane() << Snapshot.PLANE_SHIFT) & Snapshot.PLANE_MASK
			flags |= (mouse.mouse_class << Snapshot.CLASS_SHIFT) & Snapshot.CLASS_MASK
			shot.add(
				Snapshot.key_for(side, seat, roster.crew_size()),
				mouse.global_position,
				mouse.get_facing_angle(),
				flags,
				int(mouse.get_health_ratio() * 255.0)
			)

	# Unreliable, and see `net_message.gd` for why that is a decision rather than a default.
	_transport.broadcast(shot.to_bytes(), false)


## The scoreboard: everything on the HUD that is not a mouse.
##
## Read entirely through the director's ordinary public accessors -- the same ones the HUD calls --
## rather than through anything added for the network. Writing it on a client goes through one
## deliberate door (`adopt_state`); reading it here needs no door at all, and that asymmetry is the
## right way round.
func _broadcast_state() -> void:
	var roster := _net.seats()
	var crew := roster.crew_size()
	var state := MatchState.new()
	state.score = [_director.score_of(Team.BLUE), _director.score_of(Team.RED)]
	state.cheese = [_director.cheese_of(Team.BLUE), _director.cheese_of(Team.RED)]
	state.clock = _director.time_left()
	state.playing = _director.is_playing()
	state.winner = _director.get_winner()

	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(crew):
			var mouse := _director.seat_mouse(side, seat)
			if mouse == null:
				continue
			# Rounded UP, so a mouse with a tenth of a second left still reads as down rather than
			# as standing. The HUD ceils this number anyway; what matters is that zero means up.
			var left := ceili(_director.respawn_left(mouse))
			state.respawns[Snapshot.key_for(side, seat, crew)] = mini(left, 255)

	for side: int in [Team.BLUE, Team.RED]:
		var banner := _director.banner_of(side)
		var flag: MatchState.Flag = state.flags[side]
		flag.state = banner.state
		flag.position = banner.global_position
		flag.carrier = _key_of(banner.carrier, crew)

	_transport.broadcast(state.to_bytes(), false)


## Every public pile in the yard, as a complete picture. Sorted so identical worlds make identical
## packets and logs even though scene-tree group order is not an identity contract.
func _broadcast_cheese() -> void:
	var caches: Array[CheeseCache] = []
	for node: Node in get_tree().get_nodes_in_group(CheeseCache.GROUP):
		var cache := node as CheeseCache
		if cache != null and not cache.is_empty() and not cache.is_queued_for_deletion():
			caches.append(cache)
	caches.sort_custom(func(a: CheeseCache, b: CheeseCache) -> bool:
		return a.global_position.x < b.global_position.x or (
			is_equal_approx(a.global_position.x, b.global_position.x)
			and a.global_position.z < b.global_position.z
		)
	)

	var state := CheeseState.new()
	_cheese_tick += 1
	state.revision = _cheese_tick
	for cache: CheeseCache in caches:
		state.add(cache.global_position, cache.wedges, cache.spread)
	_transport.broadcast(state.to_bytes(), false)


## A line of the feed, forwarded as the server wrote it.
##
## TEXT ON THE WIRE, WHICH IS A DECISION AND HAS A CONDITION ON IT. The alternative is an event id
## plus arguments, formatted at each end -- more compact, and it would put the wording in two
## places that have to agree. Text wins here because the feed is a dozen lines a match and every
## one of them is already public: every current event is a score, a steal, a scruff, a spend or a
## whistle, and both crews are meant to see all of them.
##
## **The condition is that this stays true.** The moment an event says something only one crew
## should know -- "OTTO breaks into a vein", anything about a tunnel -- this becomes a leak with a
## broadcast in front of it, and it has to move behind step 5's filter with the rest of M5's
## pillar. That is the whole reason this note is here rather than in a commit message.
func _on_event(text: String) -> void:
	if not _net.is_established():
		return
	var out := NetMessage.head(NetMessage.Kind.EVENT)
	out.put_utf8_string(text)
	_transport.broadcast(out.data_array, true)


func _apply_event(bytes: PackedByteArray) -> void:
	var into := NetMessage.body(bytes, 5)
	if into == null:
		return
	var text := into.get_utf8_string()
	if not text.is_empty():
		_director.adopt_event(text)


## The earth, one client at a time.
##
## ADDRESSED, NEVER BROADCAST, and that is the entire security property of this milestone. Two
## clients on opposite crews are owed different worlds; a broadcast here would be correct for
## neither and would hand each of them the other's floor plan, which is a failure that **looks
## exactly like a working game**. The decision about what may go in each packet is not made here --
## it is made in `tunnel_view.gd`, in one place, so there is one place to audit.
func _send_earth() -> void:
	if _view == null:
		return
	var roster := _net.seats()
	for peer: int in roster.peers():
		if peer == _net.local_peer():
			continue
		var seated := roster.seat_of(peer)
		if seated.is_empty():
			continue
		var batch := _view.batch(peer, seated[0])
		if batch.is_empty():
			continue
		for entry: Array in batch:
			if entry[0] == TunnelView.Kind.FORGET:
				_earth_forgotten += 1
		var out := NetMessage.head(NetMessage.Kind.TUNNELS)
		out.put_u8(batch.size())
		for entry: Array in batch:
			out.put_u8(entry[0])
			out.put_u8(entry[1])
			out.put_16(entry[2].x)
			out.put_16(entry[2].y)
			out.put_u8(entry[3])
		_transport.send(peer, out.data_array, true)
		_earth_sent += batch.size()


## The earth, applied. Nothing here decides anything: every entry already happened on a machine
## that was allowed to decide it, and this end is transcribing.
func _apply_earth(bytes: PackedByteArray) -> void:
	var into := NetMessage.body(bytes, 2)
	if into == null:
		return
	var count := into.get_u8()
	if bytes.size() != 2 + count * TunnelView.ENTRY_SIZE:
		return
	for i: int in range(count):
		var kind := into.get_u8()
		var plane := into.get_u8()
		var cell := Vector2i(into.get_16(), into.get_16())
		var bits := into.get_u8()
		match kind:
			TunnelView.Kind.CELL:
				_tunnels.adopt_cell(plane, cell, bits)
			TunnelView.Kind.SHAFT:
				_tunnels.adopt_shaft(plane, cell, bits)
			TunnelView.Kind.ROCK:
				_tunnels.adopt_rock(plane, cell, bits)
			TunnelView.Kind.FORGET:
				_tunnels.forget_cell(plane, cell)
		_earth_taken += 1


## Which chair a mouse is sitting in, as a snapshot key, or `NOBODY`.
##
## Searched rather than stored, because ten comparisons four times a second is nothing and the
## alternative is a second table that has to be kept in step with the first one. The failure mode
## of a stale reverse index here would be a banner drawn on the wrong mouse.
func _key_of(mouse: Mouse, crew: int) -> int:
	if mouse == null:
		return MatchState.NOBODY
	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(crew):
			if _director.seat_mouse(side, seat) == mouse:
				return Snapshot.key_for(side, seat, crew)
	return MatchState.NOBODY


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
	# THE EARTH STOPS BEING OURS TO CUT, and the refusal lives on the network rather than on the
	# five things that cut it -- the dig controller, the cave-in, the barricade, a bot's digger and
	# anybody taking a shaft. Guarding each caller is five chances to miss one; guarding the state
	# is none.
	if _tunnels != null:
		_tunnels.set_puppet(true)


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
			mouse.apply_pose(pose.position, pose.facing, pose.flags, pose.health)
			_applied += 1
			if (pose.flags & Snapshot.Flag.SWINGING) != 0:
				_swings += 1


## The scoreboard, applied. Dropped whole if the client does not yet know the seating, since every
## index in it is a seat key and a key without a table is a number.
func _apply_state(bytes: PackedByteArray) -> void:
	if _client_seats == null:
		return
	var state := MatchState.from_bytes(bytes)
	if state == null:
		return
	_director.adopt_state(state, _client_seats.crew_size())
	_states += 1


func _apply_cheese(bytes: PackedByteArray) -> void:
	var state := CheeseState.from_bytes(bytes)
	if state == null or state.revision <= _cheese_tick:
		return
	_cheese_tick = state.revision
	_director.adopt_cheese_caches(state)
	_cheese_states += 1


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
		NetMessage.Kind.MATCH:
			if not _net.is_server() and from == NetTransport.SERVER_ID:
				_apply_state(bytes)
		NetMessage.Kind.EVENT:
			if not _net.is_server() and from == NetTransport.SERVER_ID:
				_apply_event(bytes)
		NetMessage.Kind.TUNNELS:
			if not _net.is_server() and from == NetTransport.SERVER_ID and _tunnels != null:
				_apply_earth(bytes)
		NetMessage.Kind.CHEESE:
			if not _net.is_server() and from == NetTransport.SERVER_ID:
				_apply_cheese(bytes)
