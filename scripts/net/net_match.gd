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
## Runtime cheese, barricades and sonar cant are separate, slow, complete world pictures. They
## cannot ride in the mouse snapshot because a lost spawn or removal must heal. Cheese is public;
## barricades are filtered through tunnel sight; cant follows its own literacy rule per player.
## The sonar's temporary scan shimmer is a private reliable response rather than persistent state.

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

## Barricade damage is discrete but happens in combat, so it updates faster than an immobile cheese
## pile. The complete-state shape still makes every missed spawn, hit, or removal self-healing.
const BARRICADE_HZ: float = 4.0

## Cant is tiny but contested at arm's reach. Four pictures a second keeps erasure and a class
## change responsive while preserving the same lost-packet recovery as the other runtime sets.
const CANT_HZ: float = 4.0

@export var director_path: NodePath

var _net: NetSession
var _director: MatchDirector
var _transport: NetTransport
var _since_snapshot: float = 0.0
var _since_state: float = 0.0
var _since_earth: float = 0.0
var _since_cheese: float = 0.0
var _since_barricades: float = 0.0
var _since_cant: float = 0.0
var _tick: int = 0
var _cheese_tick: int = 0
var _barricade_tick: int = 0
var _cant_tick: int = 0
var _tunnels: TunnelNetwork
var _sight: TunnelSight
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
## Complete, crew-filtered barricade pictures received.
var _barricade_states: int = 0
## Complete, player-filtered cant pictures and private scan echoes received.
var _cant_states: int = 0
var _sonar_echoes: int = 0
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
## Two cells under the nests. The replication audit puts one red-visible and one blue-only rock
## here before the joining client enters its arena, proving both late-join healing and no leak.
const AUDIT_BARRICADE_RED: Vector2i = Vector2i(10, 10)
const AUDIT_BARRICADE_BLUE: Vector2i = Vector2i(-18, 18)
var _audit_barricades: bool = false
var _audit_barricades_done: bool = false
var _audit_barricade_age: float = 0.0
var _audit_barricade_stage: int = 0
var _audit_red_rock: BarricadeRock
## Four moments for the last replication gap: own cant before a late join, enemy cant on another
## depth that must stay home, enemy cant on the mouse's OWN plane that turns on its class alone,
## and a private scan echo after its arena exists.
const AUDIT_CANT_RED: Vector2i = Vector2i(12, 12)
const AUDIT_CANT_BLUE: Vector2i = Vector2i(-17, 17)
const AUDIT_CANT_BLUE_DEEP: Vector2i = Vector2i(-16, 17)
const AUDIT_SONAR_SCAN: Vector2i = Vector2i(15, 12)
## Far enough from the mouse that `Sonar.erase_reach_cells` cannot rub the control out from under
## the test, close enough that it is unambiguously on the same floor.
const AUDIT_CANT_BESIDE_OFFSET: Vector2i = Vector2i(3, 0)
var _audit_sonar: bool = false
var _audit_sonar_done: bool = false
var _audit_sonar_age: float = 0.0
var _audit_sonar_stage: int = 0
var _audit_red_mark: SonarMark
var _audit_blue_mark: SonarMark
var _audit_blue_deep_mark: SonarMark
var _audit_scan_mark: SonarMark
var _audit_beside_mark: SonarMark
var _audit_beside_gen_mark: SonarMark


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
	_sight = get_tree().get_first_node_in_group(TunnelSight.SIGHT_GROUP) as TunnelSight
	if _tunnels != null and _sight != null:
		_view = TunnelView.new(_tunnels, _sight)

	_autopilot = OS.get_cmdline_user_args().has("--autopilot")
	if _net.is_server():
		_director.event.connect(_on_event)
		_audit_barricades = OS.get_cmdline_user_args().has("--audit-barricades")
		_audit_sonar = OS.get_cmdline_user_args().has("--audit-sonar")
		if OS.get_cmdline_user_args().has("--audit-cheese"):
			_director.call("_drop_cheese", AUDIT_CHEESE_AT, 3)
			_net.log_line("audit cheese placed before the client arena exists")
	else:
		_become_client()
	# THIS CALL IS THE LINE BETWEEN "CAME THROUGH THE LOBBY" AND "TURNED UP LATE". Everybody seated
	# right now got here the ordinary way and already has their `START`; the flag goes up immediately
	# afterwards, so every seating change from this point on belongs to somebody who needs telling.
	_on_seating_changed()
	_greeted_the_lobby = true


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
		_ensure_sonar_echo_links()
		if _audit_barricades:
			_tick_audit_barricades(delta)
		if _audit_sonar:
			_tick_audit_sonar(delta)
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
		_since_barricades += delta
		if _since_barricades >= 1.0 / BARRICADE_HZ:
			_since_barricades = 0.0
			_send_barricades()
		_since_cant += delta
		if _since_cant >= 1.0 / CANT_HZ:
			_since_cant = 0.0
			_send_cant()
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
		_net.log_line("and %d barricade-world pictures" % _barricade_states)
		_net.log_line("and %d cant-world pictures, %d sonar echoes" % [
			_cant_states, _sonar_echoes,
		])
	# THE SAME LINE FROM BOTH ENDS, built by the same code out of the same accessors. Two formats
	# would make the comparison a comparison of two formatters; one means the audit is reading the
	# same question answered twice, which is the only version of this that proves anything.
	_net.log_line(_scoreboard())
	_report_traffic()
	_report_cheese()
	_report_barricades()
	_report_cant()
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
	_barricade_states = 0
	_cant_states = 0
	_sonar_echoes = 0


## What the last five seconds actually cost, per kind, both directions.
##
## **THIS FILE HAS BEEN ARGUING ABOUT BANDWIDTH SINCE ITS FIRST LINE WITHOUT ONE MEASUREMENT IN IT.**
## The header explains that twenty snapshots a second is "deliberately below the physics rate" because
## sending every tick "would double the bandwidth to buy smoothness the interpolation already
## provides"; `net_message.gd` explains that the earth is the one payload that "genuinely could not
## afford to be idempotent". Both are plausible and both were assertions. Meanwhile step 6 finished
## with **four** separate per-peer periodic full pictures -- cheese, barricades, cant, and the
## scoreboard -- on top of snapshots and the earth, and nobody had ever added the set up.
##
## THE TRANSPORT COUNTS AND THIS FILE NAMES, which is the only split that keeps both honest. A count
## kept where payloads are *built* measures what we meant to send; the transport's counts are bytes
## that left a socket, after a dropped-on-purpose packet was dropped. The transport buckets them by
## first byte because it has no business knowing what a kind is -- the enum lives here.
func _report_traffic() -> void:
	var out := _transport.traffic_out()
	var into := _transport.traffic_in()
	_transport.clear_traffic()
	_net.log_line("wire out %s | in %s" % [_traffic_of(out), _traffic_of(into)])


## `12.3 KB/s [SNAPSHOT 8.1 BARRICADES 2.0 ...]`, biggest first, so the line answers "what is this
## costing and what is the cost" in one read.
func _traffic_of(counted: Dictionary) -> String:
	var total: int = 0
	var kinds: Array[int] = []
	for kind: int in counted:
		total += int(counted[kind])
		kinds.append(kind)
	kinds.sort_custom(func(a: int, b: int) -> bool:
		return int(counted[a]) > int(counted[b])
	)
	var parts := PackedStringArray()
	for kind: int in kinds:
		parts.append("%s %.1f" % [
			_kind_name(kind), int(counted[kind]) / REPORT_SECONDS / 1024.0,
		])
	return "%.1f KB/s [%s]" % [total / REPORT_SECONDS / 1024.0, " ".join(parts)]


func _kind_name(kind: int) -> String:
	var names := NetMessage.Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?%d" % kind


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


## Barricades are terrain knowledge, so the server reports both the complete world and each
## crew's permitted subset. The client reports only what it holds. The two-process audit uses the
## red-visible test rock to prove delivery and the blue-only one to prove the filter is real.
func _report_barricades() -> void:
	if _tunnels == null:
		return
	if not _net.is_server():
		_net.log_line("barricade world: hold %s" % _barricades_of(-1))
		_report_barricade_supply()
		return
	_net.log_line("barricade world: all %s" % _barricades_of(-1))
	for side: int in [Team.BLUE, Team.RED]:
		_net.log_line("barricade %s may know %s" % [
			Team.name_of(side), _barricades_of(side),
		])
	_report_barricade_supply()


func _report_barricade_supply() -> void:
	var mouse := _director.local_mouse()
	var wall: Barricade = null
	if mouse != null:
		wall = mouse.get_node_or_null(^"Barricade") as Barricade
	var standing := wall.max_standing - wall.in_hand() if wall != null else 0
	_net.log_line("barricade supply: mine %d standing" % standing)


func _barricades_of(side: int) -> String:
	var parts := PackedStringArray()
	var crew := (
		_net.seats().crew_size() if _net.is_server()
		else (_client_seats.crew_size() if _client_seats != null else 0)
	)
	for node: Node in get_tree().get_nodes_in_group(BarricadeRock.BARRICADE_GROUP):
		var rock := node as BarricadeRock
		if rock == null or rock.is_queued_for_deletion():
			continue
		if side >= 0 and (_sight == null or not _sight.knows(side, rock.plane, rock.cell)):
			continue
		var owner := _key_of(rock.owner_mouse, crew) if crew > 0 else BarricadeState.NOBODY
		parts.append("%d.%d,%d=%d/%d@%d" % [
			rock.plane, rock.cell.x, rock.cell.y,
			rock.hits_left(), rock.hits_to_clear, owner,
		])
	parts.sort()
	return "[%s]" % " ".join(parts)


## Cant has a different boundary from earth. The owning crew always reads its marks, even when
## the marked tunnel itself is secret; an enemy reads them only while playing the class that knows
## the language. The host prints both rule views and the client prints the one it actually holds.
func _report_cant() -> void:
	if _tunnels == null:
		return
	if not _net.is_server():
		var viewer := _director.local_mouse()
		var team_name := Team.name_of(viewer.team) if viewer != null else "?"
		var viewer_class_name := viewer.get_class_name() if viewer != null else "?"
		_net.log_line("cant viewer %s %s: hold %s" % [
			team_name, viewer_class_name, _cant_of(-1, -1, -1),
		])
		return
	_net.log_line("cant world: all %s" % _cant_of(-1, -1, -1))
	for side: int in [Team.BLUE, Team.RED]:
		for kind: int in [MouseClass.GENERALIST, MouseClass.SNEAK]:
			_net.log_line("cant %s %s on plane 0 may read %s" % [
				Team.name_of(side), MouseClass.name_of(kind), _cant_of(side, kind, 0),
			])


func _cant_of(viewer_team: int, viewer_class: int, viewer_plane: int) -> String:
	var parts := PackedStringArray()
	for node: Node in get_tree().get_nodes_in_group(SonarMark.MARK_GROUP):
		var mark := node as SonarMark
		if mark == null or mark.is_queued_for_deletion():
			continue
		# `viewer_team` of -1 is "every mark there is", which is what both ends print to be compared.
		if (
			viewer_team >= 0
			and not mark.can_be_read_by(viewer_team, viewer_class, viewer_plane)
		):
			continue
		# `@OWNER/TUNNEL`: who scratched it, then whose corridor it names. The separator is not
		# cosmetic -- the audits match on `@RED` to mean "a mark red scratched", and a second crew
		# name joined by anything they also use would start matching those by accident.
		parts.append("%d.%d,%d@%s/%s" % [
			mark.plane, mark.cell.x, mark.cell.y, Team.name_of(mark.owner_team),
			SonarMark.team_label(mark.tunnel_team),
		])
	parts.sort()
	return "[%s]" % " ".join(parts)


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
			if mouse.was_buried():
				flags |= Snapshot.Flag.BURIED
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


## Every barricade this peer's crew is currently entitled to see.
##
## ADDRESSED FOR THE SAME REASON AS EARTH. A rock names its plane and cell, so putting all of them
## in a broadcast would be a compact enemy tunnel map. Unlike earth this remains a full picture:
## at three standing per Engineer the set is tiny, and absence is what makes breakage, cave-ins,
## fog loss, packet loss and late joining all converge through the same reconciliation.
func _send_barricades() -> void:
	if _tunnels == null or _sight == null:
		return
	var roster := _net.seats()
	var rocks: Array[BarricadeRock] = []
	for node: Node in get_tree().get_nodes_in_group(BarricadeRock.BARRICADE_GROUP):
		var rock := node as BarricadeRock
		if rock != null and not rock.is_queued_for_deletion() and rock.hits_left() > 0:
			rocks.append(rock)
	rocks.sort_custom(func(a: BarricadeRock, b: BarricadeRock) -> bool:
		return a.plane < b.plane or (
			a.plane == b.plane and (
				a.cell.x < b.cell.x or (a.cell.x == b.cell.x and a.cell.y < b.cell.y)
			)
		)
	)
	var standing := PackedByteArray()
	standing.resize(roster.crew_size() * 2)
	for rock: BarricadeRock in rocks:
		var owner := _key_of(rock.owner_mouse, roster.crew_size())
		if owner != BarricadeState.NOBODY and owner < standing.size():
			standing[owner] = mini(int(standing[owner]) + 1, 255)

	_barricade_tick += 1
	for peer: int in roster.peers():
		if peer == _net.local_peer():
			continue
		var seated := roster.seat_of(peer)
		if seated.is_empty():
			continue
		var state := BarricadeState.new()
		state.revision = _barricade_tick
		# Supply is private to the player whose HUD needs it. Sending every seat's count would reveal
		# hidden enemy fortification activity even though their coordinates were filtered correctly.
		var own_standing := PackedByteArray()
		own_standing.resize(standing.size())
		var own_key := Snapshot.key_for(seated[0], seated[1], roster.crew_size())
		own_standing[own_key] = standing[own_key]
		state.set_standing(own_standing)
		for rock: BarricadeRock in rocks:
			if not _sight.knows(seated[0], rock.plane, rock.cell):
				continue
			state.add(
				rock.plane, rock.cell,
				_key_of(rock.owner_mouse, roster.crew_size()),
				rock.hits_left(), rock.hits_to_clear
			)
		_transport.send(peer, state.to_bytes(), false)


## Every mark this PLAYER can read, not every mark their crew can read. Own cant is crew
## knowledge; enemy cant is class knowledge, so two players on one crew can be owed different
## pictures at the same moment. Filtering against the authoritative mouse class also means a
## client cannot ask to keep enemy marks after swapping away from Sneak.
func _send_cant() -> void:
	var roster := _net.seats()
	var marks: Array[SonarMark] = []
	for node: Node in get_tree().get_nodes_in_group(SonarMark.MARK_GROUP):
		var mark := node as SonarMark
		if mark != null and not mark.is_queued_for_deletion():
			marks.append(mark)
	marks.sort_custom(func(a: SonarMark, b: SonarMark) -> bool:
		return a.owner_team < b.owner_team or (
			a.owner_team == b.owner_team and (
				a.plane < b.plane or (a.plane == b.plane and (
					a.cell.x < b.cell.x or (a.cell.x == b.cell.x and a.cell.y < b.cell.y)
				))
			)
		)
	)

	_cant_tick += 1
	for peer: int in roster.peers():
		if peer == _net.local_peer():
			continue
		var seated := roster.seat_of(peer)
		if seated.is_empty():
			continue
		var viewer := _director.seat_mouse(seated[0], seated[1])
		if viewer == null:
			continue
		var state := SonarState.new()
		state.revision = _cant_tick
		for mark: SonarMark in marks:
			# `SonarMark.can_be_read_by` AND NOT THE RULE WRITTEN OUT AGAIN HERE. This is the copy
			# that matters -- it is the one deciding what leaves the machine -- so it must be the
			# same call the renderer and the audit's report make, or the check they agree on is a
			# check of three separately maintained opinions.
			if mark.can_be_read_by(seated[0], viewer.mouse_class, viewer.get_plane()):
				state.add(mark.owner_team, mark.plane, mark.cell, mark.tunnel_team)
		_transport.send(peer, state.to_bytes(), false)


## Sonar belongs to a runtime-spawned Player, so signal wiring follows the roster rather than an
## authored NodePath. Rescanning is cheap (at most four human mice) and closes the small window
## between a peer taking a seat and that deferred Player entering the tree.
##
## REMEMBERED IN A TABLE RATHER THAN ASKED OF THE SIGNAL, and the reason is a Godot detail worth
## writing down: **`Callable.bind` arguments do not participate in Callable equality.** Measured on
## 4.7 -- `bind(a) == bind(b)` is true, and `connect` with a differently bound copy is refused as a
## duplicate. So `is_connected(Callable(self, "_on_sonar_scanned").bind(mouse))` does not ask "is
## this mouse's sonar linked", it asks "is anything linked to `_on_sonar_scanned` here". That
## happens to be the same question while there is one Sonar per mouse and each is bound to its own
## -- which is a guard resting on a coincidence, and it built a fresh Callable every tick to do it.
var _echo_linked: Dictionary = {}
## Peers already told to load an arena, by id. See `_start_the_latecomers`.
var _started: Dictionary = {}
## Whether the lobby crowd has been counted. Below this line a seating change is a latecomer.
var _greeted_the_lobby: bool = false


func _ensure_sonar_echo_links() -> void:
	for node: Node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or not (mouse is Player):
			continue
		var sonar := mouse.get_node_or_null(^"Sonar") as Sonar
		if sonar == null or _echo_linked.has(sonar):
			continue
		_echo_linked[sonar] = true
		sonar.scanned.connect(_on_sonar_scanned.bind(mouse))

	# A seat handed back to a bot frees its Player and its Sonar with it. Pruned here rather than on
	# a departure signal because this scan is already the thing that runs every tick, and a table
	# keyed by freed objects would grow for the length of the match.
	for sonar: Variant in _echo_linked.keys():
		if not is_instance_valid(sonar):
			_echo_linked.erase(sonar)


## A scan's full outline is private to the mouse that paid the cooldown. The persistent mark is
## handled by `_send_cant`; this one-shot is only the brief presentation that leads into it.
func _on_sonar_scanned(
	source_plane: int, _target_plane: int, cells: Array[Vector2i], owners: Array[int],
	mouse: Mouse
) -> void:
	if cells.is_empty():
		return  # Matches local presentation: "nothing answers" produces no empty shimmer.
	var peer := _peer_for_mouse(mouse)
	if peer <= Seats.BOT or peer == _net.local_peer():
		return  # The listen-server player's own Sonar already draws this locally.
	var bytes := SonarState.echo_to_bytes(source_plane, cells, owners)
	if not bytes.is_empty():
		_transport.send(peer, bytes, true)


func _peer_for_mouse(mouse: Mouse) -> int:
	var roster := _net.seats()
	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(roster.crew_size()):
			if _director.seat_mouse(side, seat) == mouse:
				return roster.occupant(side, seat)
	return Seats.BOT


## Build the replication audit's pair only after the remote seat has become a real Player. The
## joining process remains on its title screen for eight seconds, so these rocks predate its arena:
## a later appearance proves state recovery, not a conveniently timed spawn event.
func _try_audit_barricades() -> void:
	if _tunnels == null:
		return
	var roster := _net.seats()
	var remote: Mouse = null
	for peer: int in roster.peers():
		if peer == _net.local_peer():
			continue
		var seated := roster.seat_of(peer)
		if seated.is_empty():
			continue
		var candidate := _director.seat_mouse(seated[0], seated[1])
		if candidate is Player:
			remote = candidate
			break
	if remote == null:
		return

	_tunnels.dig(1, AUDIT_BARRICADE_RED, Team.RED)
	# The hidden control sits away from both crews' normal routes. Clear a generated vein only in
	# this audit world so the coordinate remains deterministic across seeds.
	_tunnels.remove_rock(1, AUDIT_BARRICADE_BLUE)
	_tunnels.dig(1, AUDIT_BARRICADE_BLUE, Team.BLUE)
	if not _tunnels.is_dug(1, AUDIT_BARRICADE_RED):
		return
	_audit_red_rock = BarricadeRock.place(_tunnels, 1, AUDIT_BARRICADE_RED, remote)
	# One authoritative damage step, so the client has to reproduce visual/remaining-hit state and
	# not merely the existence of a fresh default rock.
	var brute := Mouse.new()
	brute.mouse_class = MouseClass.BRUTE
	_audit_red_rock.hit_by(brute)
	brute.free()
	if _tunnels.is_dug(1, AUDIT_BARRICADE_BLUE):
		BarricadeRock.place(
			_tunnels, 1, AUDIT_BARRICADE_BLUE, _director.local_mouse()
		)
	_audit_barricades_done = true
	_net.log_line("audit barricades placed before the client arena exists")


## After late-join spawn has had time to appear in a five-second report, move the same rock
## through one more damage stage and then clear it. The real two-process audit can therefore prove
## update and removal, not only creation.
func _tick_audit_barricades(delta: float) -> void:
	if not _audit_barricades_done:
		_try_audit_barricades()
		return
	_audit_barricade_age += delta
	if _audit_barricade_stage == 0 and _audit_barricade_age >= 18.0:
		if is_instance_valid(_audit_red_rock):
			_audit_brute_hit(_audit_red_rock)
			_net.log_line("audit barricade damaged to one hit")
		_audit_barricade_stage = 1
	elif _audit_barricade_stage == 1 and _audit_barricade_age >= 30.0:
		if is_instance_valid(_audit_red_rock):
			_audit_brute_hit(_audit_red_rock)
			_net.log_line("audit barricade cleared")
		_audit_barricade_stage = 2


## Build three marks before the joining process has an arena. Red owns one and must receive it as
## a Generalist; blue owns a same-plane control that crosses only while that authoritative mouse is
## a Sneak, plus a deep control that must still stay home. Together they expose late joining,
## literacy and the depth boundary separately.
func _try_audit_sonar() -> void:
	if _tunnels == null:
		return
	var remote := _audit_remote_mouse()
	if remote == null:
		return
	remote.set_class(MouseClass.GENERALIST)
	# THREE DIFFERENT `tunnel_team` VALUES ON THE THREE CONTROLS, on purpose. The field is new on
	# the wire and it is presentation rather than a rule, which is exactly the kind of field that
	# gets serialised wrong and never noticed -- if all three fixtures shared a value, a decoder
	# that returned a constant would pass. Red's names blue's corridor (an enemy target, the case
	# the whole feature exists for), blue's names its own, and the deep one is a junction.
	_audit_red_mark = _make_audit_mark(Team.RED, 0, AUDIT_CANT_RED, Team.BLUE)
	_audit_blue_mark = _make_audit_mark(Team.BLUE, 0, AUDIT_CANT_BLUE, Team.BLUE)
	_audit_blue_deep_mark = _make_audit_mark(
		Team.BLUE, 2, AUDIT_CANT_BLUE_DEEP, SonarMark.SHARED
	)
	_audit_sonar_done = (
		_audit_red_mark != null and _audit_blue_mark != null
		and _audit_blue_deep_mark != null
	)
	if _audit_sonar_done:
		_net.log_line("audit cant placed before the client arena exists")


func _tick_audit_sonar(delta: float) -> void:
	if not _audit_sonar_done:
		_try_audit_sonar()
		return
	_audit_sonar_age += delta
	var remote := _audit_remote_mouse()
	if remote == null:
		return

	# Once the client arena has been alive for several seconds, let the same player read the enemy
	# control mark and perform a real scan. The signal path sends only that player the brief echo;
	# the mark it leaves returns through the periodic state path.
	if _audit_sonar_stage == 0 and _audit_sonar_age >= 16.0:
		remote.set_class(MouseClass.SNEAK)
		remote.set_plane(0)
		remote.global_position = _tunnels.cell_to_world(0, AUDIT_SONAR_SCAN) + Vector3.UP * 0.2
		_tunnels.remove_rock(1, AUDIT_SONAR_SCAN)
		_tunnels.dig(1, AUDIT_SONAR_SCAN, Team.BLUE)
		var sonar := remote.get_node_or_null(^"Sonar") as Sonar
		var heard := sonar.scan() if sonar != null else 0
		_audit_scan_mark = _mark_at(Team.RED, 0, AUDIT_SONAR_SCAN)
		_net.log_line("audit sonar made remote a Sneak and sounded %d cells" % heard)
		_audit_sonar_stage = 1
	# A CONTROL PLACED BESIDE THE MOUSE, ON THE MOUSE'S OWN PLANE, ONCE PER CLASS -- and it took two
	# tries to get this honest. **Absence cannot prove class**, because two rules revoke a mark and
	# both end in the same empty hold: the mark was unreadable to this class, or the mouse walked off
	# its plane. Version one put the control on plane 0 and swapped class eleven seconds later, by
	# which time `--autopilot` had dug down to plane 1 and DEPTH had taken it -- a pass proving
	# nothing. Version two placed the control beside the mouse and asked whether the plane had
	# changed, which turned a false pass into a *reported* one but still let the check itself go
	# green. What the audit actually needs is a reading of a mark the depth rule would have ALLOWED,
	# so the two are paired: one control read while a Sneak, a second placed on the mouse's plane at
	# the instant of the swap, and the client's own reported depth checked against each. See
	# `_check_the_cant_world`.
	elif _audit_sonar_stage == 1 and _audit_sonar_age >= 23.0:
		_audit_beside_mark = _place_beside(remote, AUDIT_CANT_BESIDE_OFFSET, "Sneak")
		_audit_sonar_stage = 2
	elif _audit_sonar_stage == 2 and _audit_sonar_age >= 31.0:
		# Placed BEFORE the swap and reported after it, so no five-second report can ever observe
		# this mark while the mouse is still a Sneak: every reading of it is a Generalist's.
		_audit_beside_gen_mark = _place_beside(
			remote, -AUDIT_CANT_BESIDE_OFFSET, "Generalist"
		)
		remote.set_class(MouseClass.GENERALIST)
		_net.log_line(
			"audit sonar returned remote to Generalist on plane %d" % remote.get_plane()
		)
		_audit_sonar_stage = 3
	elif _audit_sonar_stage == 3 and _audit_sonar_age >= 39.0:
		for mark: SonarMark in [_audit_red_mark, _audit_scan_mark]:
			if is_instance_valid(mark) and not mark.is_queued_for_deletion():
				mark.discard()
		_net.log_line("audit red cant erased while blue control remains")
		_audit_sonar_stage = 4


func _audit_remote_mouse() -> Mouse:
	var roster := _net.seats()
	for peer: int in roster.peers():
		if peer == _net.local_peer():
			continue
		var seated := roster.seat_of(peer)
		if seated.is_empty():
			continue
		var candidate := _director.seat_mouse(seated[0], seated[1])
		if candidate is Player:
			return candidate
	return null


## An enemy control on the plane the mouse is standing on this instant, logged as the exact token a
## hold line prints -- so the audit matches one string instead of reassembling a coordinate it half
## remembers, and reads the plane back out of the token rather than being told it separately.
func _place_beside(remote: Mouse, offset: Vector2i, whose: String) -> SonarMark:
	var plane := remote.get_plane()
	var cell := _tunnels.world_to_cell(remote.global_position) + offset
	var mark := _make_audit_mark(Team.BLUE, plane, cell)
	_net.log_line("audit sonar blue control beside the %s: %d.%d,%d@BLUE" % [
		whose, plane, cell.x, cell.y,
	])
	return mark


func _make_audit_mark(
	side: int, plane: int, cell: Vector2i, whose: int = SonarMark.SHARED
) -> SonarMark:
	var mark := SonarMark.new()
	_tunnels.add_child(mark)
	mark.configure(_tunnels, side, plane, cell, whose)
	return mark


func _mark_at(side: int, plane: int, cell: Vector2i) -> SonarMark:
	for node: Node in get_tree().get_nodes_in_group(SonarMark.MARK_GROUP):
		var mark := node as SonarMark
		if (
			mark != null and mark.owner_team == side
			and mark.plane == plane and mark.cell == cell
		):
			return mark
	return null


func _audit_brute_hit(rock: BarricadeRock) -> void:
	var brute := Mouse.new()
	brute.mouse_class = MouseClass.BRUTE
	rock.hit_by(brute)
	brute.free()


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


func _apply_barricades(bytes: PackedByteArray) -> void:
	# Owner is a seat key. Like the scoreboard, this picture has no meaning until the seating table
	# exists; it is complete and periodic, so dropping an early one is repaired by the next.
	if _client_seats == null or _tunnels == null:
		return
	var state := BarricadeState.from_bytes(bytes)
	if state == null or state.revision <= _barricade_tick:
		return
	_reconcile_barricades(state)
	_barricade_tick = state.revision
	_barricade_states += 1


func _reconcile_barricades(state: BarricadeState) -> void:
	_adopt_barricade_supplies(state.standing)
	var unmatched: Array[BarricadeRock] = []
	for node: Node in get_tree().get_nodes_in_group(BarricadeRock.BARRICADE_GROUP):
		var rock := node as BarricadeRock
		if rock != null and not rock.is_queued_for_deletion():
			unmatched.append(rock)

	for reading: BarricadeState.Rock in state.rocks:
		# Earth is reliable but may still be a packet behind this unreliable picture on first join.
		# A rock without its tunnel would float in closed earth; skip it and let the next complete
		# picture create it once the cell has arrived.
		if not _tunnels.is_dug(reading.plane, reading.cell):
			continue
		var rock := _barricade_at(unmatched, reading.plane, reading.cell)
		var owner: Mouse = null
		if reading.owner != BarricadeState.NOBODY:
			owner = _puppet_for(reading.owner)
		if rock == null:
			rock = BarricadeRock.reproduce(
				_tunnels, reading.plane, reading.cell, owner,
				reading.hits_left, reading.hits_total
			)
		else:
			unmatched.erase(rock)
			rock.adopt_replica(owner, reading.hits_left, reading.hits_total)

	# Missing means broken, collapsed, or no longer permitted by fog. All three remove the local
	# picture; only the server mutates the real graph.
	for stale: BarricadeRock in unmatched:
		stale.discard_replica()


func _adopt_barricade_supplies(standing: PackedByteArray) -> void:
	var keys := _client_seats.crew_size() * 2 if _client_seats != null else 0
	for key: int in range(keys):
		var mouse := _puppet_for(key)
		if mouse == null:
			continue
		var wall := mouse.get_node_or_null(^"Barricade") as Barricade
		if wall != null:
			wall.adopt_standing(int(standing[key]) if key < standing.size() else 0)


func _barricade_at(
	rocks: Array[BarricadeRock], plane: int, cell: Vector2i
) -> BarricadeRock:
	for rock: BarricadeRock in rocks:
		if rock.plane == plane and rock.cell == cell:
			return rock
	return null


func _apply_cant(bytes: PackedByteArray) -> void:
	var state := SonarState.from_bytes(bytes)
	if state == null or state.revision <= _cant_tick:
		return
	_reconcile_cant(state)
	_cant_tick = state.revision
	_cant_states += 1


func _reconcile_cant(state: SonarState) -> void:
	var unmatched: Array[SonarMark] = []
	for node: Node in get_tree().get_nodes_in_group(SonarMark.MARK_GROUP):
		var mark := node as SonarMark
		if mark != null and not mark.is_queued_for_deletion():
			unmatched.append(mark)

	for reading: SonarState.Mark in state.marks:
		var mark := _cant_at(unmatched, reading.owner_team, reading.plane, reading.cell)
		if mark == null:
			mark = SonarMark.new()
			_tunnels.add_child(mark)
			mark.configure(
				_tunnels, reading.owner_team, reading.plane, reading.cell, reading.tunnel_team
			)
		else:
			unmatched.erase(mark)
			# A MATCHED MARK MAY STILL HAVE CHANGED WHAT IT SAYS. Identity is crew-plane-cell, so
			# a corridor that becomes a junction after the two networks meet arrives as the same
			# mark carrying a different `tunnel_team` -- and without this the client would keep
			# drawing the old glyph for the rest of the match. Rebuilt only when it actually moved,
			# because `configure` regenerates the mesh.
			if mark.tunnel_team != reading.tunnel_team:
				mark.configure(
					_tunnels, reading.owner_team, reading.plane, reading.cell, reading.tunnel_team
				)

	# Missing means erased or no longer readable after a class change. Both remove the local world
	# picture; only the first removed the authoritative mark on the host.
	for stale: SonarMark in unmatched:
		stale.discard()


func _cant_at(
	marks: Array[SonarMark], owner_team: int, plane: int, cell: Vector2i
) -> SonarMark:
	for mark: SonarMark in marks:
		if mark.owner_team == owner_team and mark.plane == plane and mark.cell == cell:
			return mark
	return null


func _apply_sonar_echo(bytes: PackedByteArray) -> void:
	var reading := SonarState.echo_from_bytes(bytes)
	if reading.is_empty():
		return
	var mouse := _director.local_mouse()
	var sonar: Sonar = null
	if mouse != null:
		sonar = mouse.get_node_or_null(^"Sonar") as Sonar
	if sonar == null:
		return
	var cells: Array[Vector2i] = []
	for cell: Vector2i in reading["cells"]:
		cells.append(cell)
	var owners: Array[int] = []
	for whose: int in reading["owners"]:
		owners.append(whose)
	sonar.reproduce_echo(int(reading["plane"]), cells, owners)
	_sonar_echoes += 1
	_net.log_line("sonar echo: plane %d cells %s" % [reading["plane"], _cell_list(cells)])


func _cell_list(cells: Array[Vector2i]) -> String:
	var parts := PackedStringArray()
	for cell: Vector2i in cells:
		parts.append("%d,%d" % [cell.x, cell.y])
	parts.sort()
	return "[%s]" % " ".join(parts)


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
	_start_the_latecomers(roster)


## Anybody seated since this arena existed is told to load one, because nobody else will tell them.
##
## **THIS IS WHAT REJOINING WAS MISSING, AND IT WAS MISSING COMPLETELY.** `START` is broadcast by the
## lobby's button, and the host leaves that lobby the moment it presses it -- so a peer arriving
## afterwards was seated, given a mouse on the server, and sent snapshots, earth and cheese while it
## *sat on a lobby screen forever* watching none of it arrive. It looked exactly like a hang. Same gap
## whether they are a returning player whose wire dropped or a friend who turned up ten minutes late:
## the host is in a match and the newcomer has no way to learn it is allowed in.
##
## ONCE PER PEER, TRACKED BY ID, which is what makes it safe to hang off a signal that fires on every
## seating change. Peers seated before this node finished starting came in through the lobby and have
## their `START` already; they are marked on the way past rather than told a second time.
##
## THE PERIODIC FULL PICTURES ARE WHAT MAKE THIS WORK AT ALL -- the M7 argument arriving at its own
## conclusion. A latecomer is owed the entire world, and every runtime thing in it is already a
## complete state resent on a timer rather than a spawn event that has been and gone, so there is
## nothing to replay. The earth is the one diff, and `tunnel_view` keys its delivery history by peer,
## so a fresh id is owed all of it from the beginning.
func _start_the_latecomers(roster: Seats) -> void:
	for peer: int in roster.peers():
		if peer == _net.local_peer() or _started.has(peer):
			continue
		_started[peer] = true
		if not _greeted_the_lobby:
			continue
		_transport.send(peer, NetMessage.head(NetMessage.Kind.START).data_array, true)
		_net.log_line("told peer %d to join the match already in progress" % peer)


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
				# HELLO means the peer has an arena NOW. Terrain sent while it was connected on
				# the title screen had no NetMatch to consume it, so forget the delivery cursor
				# and replay everything this crew currently knows. Barricades wait for that earth.
				if _view != null:
					_view.forget_peer(from)
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
		NetMessage.Kind.BARRICADES:
			if not _net.is_server() and from == NetTransport.SERVER_ID:
				_apply_barricades(bytes)
		NetMessage.Kind.SONAR_MARKS:
			if not _net.is_server() and from == NetTransport.SERVER_ID and _tunnels != null:
				_apply_cant(bytes)
		NetMessage.Kind.SONAR_ECHO:
			if not _net.is_server() and from == NetTransport.SERVER_ID:
				_apply_sonar_echo(bytes)
