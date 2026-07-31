class_name MatchDirector
extends Node
## The rules of the match, in one file, written as rules.
##
## Capture the flag, unmodified (GDD section 2, and Pillar 1 -- the playground version is the
## point). Steal their banner, carry it home, score. Your own banner has to be home for a
## capture to count. A dropped banner returns itself after twenty seconds, or instantly if one
## of its own crew touches it.
##
## EVERY RULE IS HERE AND NOWHERE ELSE. The banner owns its state and its return clock, the
## nest owns its address, the mouse owns its health -- but which mouse may pick up which
## banner, and what a capture requires, is decided in one place you can read top to bottom.
## The alternative is a rule spread across three Area3Ds and a signal, which is how CTF
## implementations end up with a capture that works except when the carrier is scruffed on the
## line.
##
## PROXIMITY IS DISTANCE, not physics. Eight mice and two banners is twenty comparisons a tick
## -- far cheaper than the Area3D bookkeeping it replaces, deterministic under a headless
## audit, and it sidesteps the classic CTF bug where a fast carrier tunnels through the capture
## trigger between two frames.
##
## THE FLAG CANNOT ENTER A TUNNEL (GDD section 2, decided). Digging moves mice, never
## objectives -- otherwise tunnels become the dominant escape route and surface defence stops
## mattering. The dig controller refuses to take a carrier down a shaft, and the rule below is
## the backstop for every other way a mouse might end up underground.

signal event(text: String)
signal score_changed(blue: int, red: int)
signal match_ended(winner: int)

const DIRECTOR_GROUP: StringName = &"match_director"
## No winner: the clock ran out level.
const DRAW: int = -1

@export var blue_nest_path: NodePath
@export var red_nest_path: NodePath
@export var player_path: NodePath

@export_group("Match")
## GDD section 1: eight minutes, or first to three.
@export var match_seconds: float = 480.0
@export var capture_limit: int = 3
## How long the result sits on screen before everything resets. Long enough to say something
## about the last capture, short enough that nobody goes to make tea.
@export var restart_delay: float = 8.0

@export_group("Rules")
## How close you have to be to grab a banner. Generous, at a scale where the mouse is 0.32
## across -- a pickup you can miss by running past it is a bad kind of hard.
@export var pickup_radius: float = 0.85
## Seconds flat on your back before you're back at your nest. GDD section 2 makes this 6, and
## 20 when the team's cheese runs out -- the second half needs the economy, which is M6.
@export var respawn_seconds: float = 6.0
## How far off the spawn point each arrival is placed. See `_send_home`: mice sharing a point
## do not stand on each other, they launch.
@export var spawn_spread: float = 0.4

@export_group("Bots")
## Mice per crew, the player included. Solo play is the same match with AI in every other seat
## (GDD section 1), so this is one honest number rather than two bot counts: the player takes a
## blue seat and every remaining seat on both sides is filled with a bot.
##
## Three rather than the GDD's eventual four, because three is the smallest crew that can field
## a defender and still have someone raiding -- and a defended nest is what makes the flag run
## worth measuring. With nobody at home a steal is a walk.
@export var crew_size: int = 3
@export var bot_scene: PackedScene = preload("res://scenes/actors/bot.tscn")

var _nests: Array[Nest] = []
var _banners: Array[Banner] = []
var _player: Mouse
var _score: Array[int] = [0, 0]
var _clock: float = 0.0
var _playing: bool = true
var _winner: int = DRAW
var _restart_left: float = 0.0
## How many mice have been placed at a nest, so consecutive arrivals land on different spots.
var _spawned: int = 0
## mouse -> seconds until it's back on its feet.
var _down: Dictionary = {}
## Mice whose signals are already connected, so the roster can be rescanned freely.
var _known: Dictionary = {}


func _ready() -> void:
	add_to_group(DIRECTOR_GROUP)
	var blue := get_node_or_null(blue_nest_path) as Nest
	var red := get_node_or_null(red_nest_path) as Nest
	if blue == null or red == null:
		push_error("match director: both nests must be wired -- no match without them")
		set_physics_process(false)
		return

	_nests = [blue, red]
	_banners = [blue.get_banner(), red.get_banner()]
	_clock = match_seconds

	_player = get_node_or_null(player_path) as Mouse
	if _player != null:
		_player.set_team(Team.BLUE)
		_send_home(_player)

	# Deferred, because a node cannot gain siblings while its parent is still building its
	# children -- `add_sibling` refuses outright during `_ready`. One frame later the arena is
	# whole, which is also when the navmesh is finished baking and there is somewhere to walk.
	_spawn_bots.call_deferred()
	event.emit("MATCH START -- steal the %s banner" % Team.name_of(Team.RED))


# --------------------------------------------------------------------------------- queries


## The mouse the human is driving, for anything that has to tell "you" from "them" -- the HUD
## and, later, the per-team visibility filter at M5.
func get_player() -> Mouse:
	return _player


func nest_of(side: int) -> Nest:
	return _nests[side]


func banner_of(side: int) -> Banner:
	return _banners[side]


func score_of(side: int) -> int:
	return _score[side]


func time_left() -> float:
	return maxf(0.0, _clock)


func is_playing() -> bool:
	return _playing


func get_winner() -> int:
	return _winner


## Seconds until this mouse is back, or 0 if it's up. Read by the HUD, and by bots that would
## otherwise keep chasing a body.
func respawn_left(mouse: Mouse) -> float:
	return _down.get(mouse, 0.0)


## Whoever is carrying `side`'s banner, or null. The one query a defending bot needs.
func carrier_of(side: int) -> Mouse:
	return _banners[side].carrier


# ------------------------------------------------------------------------------- the rules


func _physics_process(delta: float) -> void:
	_scan_roster()
	_tick_respawns(delta)

	if not _playing:
		_restart_left -= delta
		if _restart_left <= 0.0:
			_reset()
		return

	_clock -= delta
	if _clock <= 0.0:
		_finish(_leader())
		return

	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or mouse.is_scruffed():
			continue
		_check_carry(mouse)
		_check_pickup(mouse)
		_check_capture(mouse)


## A carrier who has gone underground drops it, wherever they are.
##
## The backstop, not the rule -- dig_controller.gd refuses to take a carrier down a shaft in
## the first place, which is where the player meets this. This catches everything else: a bot
## that doesn't know better, and every future way of being moved somewhere you didn't choose
## (Slam, a cave-in, a current).
func _check_carry(mouse: Mouse) -> void:
	if not mouse.is_carrying() or mouse.get_plane() == 0:
		return
	var banner := mouse.get_carried() as Banner
	if banner == null:
		return
	banner.drop()
	event.emit("the %s banner will not go underground" % Team.name_of(banner.team))


## Touching a banner: theirs is a steal, yours is a rescue.
func _check_pickup(mouse: Mouse) -> void:
	if mouse.get_plane() != 0:
		return

	var theirs := _banners[Team.other(mouse.team)]
	if not mouse.is_carrying() and theirs.state != Banner.CARRIED:
		if _within(mouse, theirs, pickup_radius):
			theirs.take(mouse)
			event.emit("%s takes the %s banner" % [
				Team.name_of(mouse.team), Team.name_of(theirs.team)
			])
			return

	# Your own, lying in the open, goes straight home when you touch it (GDD section 2). Note
	# this works while you are carrying theirs -- running past your own dropped banner on the
	# way home is a good moment and there is no reason to forbid it.
	var ours := _banners[mouse.team]
	if ours.state == Banner.DROPPED and _within(mouse, ours, pickup_radius):
		ours.send_home()
		event.emit("%s returns their banner" % Team.name_of(mouse.team))


## A capture needs three things at once: their banner in your paws, you at home, and YOUR
## banner already there. The third is what makes defence matter -- a crew that has lost its
## own banner cannot score until it gets it back, so a double steal turns into a standoff
## rather than a race.
func _check_capture(mouse: Mouse) -> void:
	if not mouse.is_carrying():
		return
	var banner := mouse.get_carried() as Banner
	if banner == null or not _nests[mouse.team].contains(mouse.global_position):
		return
	if not _banners[mouse.team].is_home():
		return

	banner.send_home()
	_score[mouse.team] += 1
	score_changed.emit(_score[Team.BLUE], _score[Team.RED])
	event.emit("%s SCORES  (%d - %d)" % [
		Team.name_of(mouse.team), _score[Team.BLUE], _score[Team.RED]
	])
	if _score[mouse.team] >= capture_limit:
		_finish(mouse.team)


func _within(mouse: Mouse, banner: Banner, reach: float) -> bool:
	var gap := mouse.global_position - banner.global_position
	gap.y = 0.0
	return gap.length() <= reach


# ------------------------------------------------------------------------------- respawning


## Scruffed: drop whatever you were carrying, then lie there for six seconds.
##
## Dropping where you FELL is the whole point of the rule -- it leaves the banner in the
## middle of the fight that just happened, which is what makes defending a corridor worth
## doing. A banner that teleported home on a scruff would make every steal a coin flip.
func _on_scruffed(mouse: Mouse, by: Mouse) -> void:
	if mouse.is_carrying():
		var banner := mouse.get_carried() as Banner
		if banner != null:
			banner.drop()
			event.emit("the %s banner is dropped" % Team.name_of(banner.team))

	_down[mouse] = respawn_seconds
	if by != null:
		event.emit("%s scruffs %s" % [Team.name_of(by.team), Team.name_of(mouse.team)])


func _tick_respawns(delta: float) -> void:
	for mouse: Mouse in _down.keys():
		if not is_instance_valid(mouse):
			_down.erase(mouse)
			continue
		var left: float = _down[mouse] - delta
		if left > 0.0:
			_down[mouse] = left
			continue
		_down.erase(mouse)
		_send_home(mouse)


## Back on your feet at your own nest, a step off the exact spot the last one used.
##
## THE STEP MATTERS. Two mice occupying the same point is not a near miss for a physics engine
## -- it is a zero-length separation vector, and resolving it launches them apart in whatever
## direction the solver happens to pick, usually straight up. Respawning a whole crew at one
## coordinate is the reliable way to produce that, and it reads as the game being broken rather
## than as two mice standing too close.
func _send_home(mouse: Mouse) -> void:
	var nest := _nests[mouse.team]
	var around := TAU * float(_spawned % 6) / 6.0
	_spawned += 1
	var step := Vector3(cos(around), 0.0, sin(around)) * spawn_spread
	mouse.revive_at(nest.spawn_point() + step, nest.spawn_facing())


# ------------------------------------------------------------------------------- the match


func _leader() -> int:
	if _score[Team.BLUE] == _score[Team.RED]:
		return DRAW
	return Team.BLUE if _score[Team.BLUE] > _score[Team.RED] else Team.RED


func _finish(winner: int) -> void:
	_playing = false
	_winner = winner
	_restart_left = restart_delay
	_clock = maxf(_clock, 0.0)
	event.emit("DRAW" if winner == DRAW else "%s WINS" % Team.name_of(winner))
	match_ended.emit(winner)


## Everything back to the start. A spike you have to restart from the editor to play twice is
## a spike you play once, and M3's question -- is the flag run tense? -- is not answerable in
## one match.
func _reset() -> void:
	_score = [0, 0]
	_clock = match_seconds
	_winner = DRAW
	_playing = true
	_down.clear()
	for banner: Banner in _banners:
		banner.send_home()
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse != null:
			_send_home(mouse)
	score_changed.emit(0, 0)
	event.emit("MATCH START -- steal the %s banner" % Team.name_of(Team.RED))


# --------------------------------------------------------------------------------- roster


## Find any mouse we haven't met and listen to it.
##
## Rescanned every tick rather than collected once at startup, because the roster genuinely
## changes: bots are spawned here, the player readies on its own schedule, and M7 adds players
## joining mid-match. At eight mice the scan is noise, and it means nothing can be forgotten by
## being created in the wrong order.
func _scan_roster() -> void:
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or _known.has(mouse):
			continue
		_known[mouse] = true
		mouse.scruffed.connect(_on_scruffed)


## Fill both crews. Seat 0 on blue is the player's, if there is one.
##
## Roles alternate down the seats -- raider, defender, raider -- so no crew is ever all-attack
## or all-defence regardless of what `crew_size` is set to. It also means the player's own crew
## always has somebody minding the nest, which is what stops solo play being two mice running
## past each other in opposite directions forever.
func _spawn_bots() -> void:
	if bot_scene == null:
		return
	for side in [Team.BLUE, Team.RED]:
		var first := 1 if side == Team.BLUE and _player != null else 0
		for seat in range(first, maxi(first, crew_size)):
			var bot := bot_scene.instantiate() as Mouse
			if bot == null:
				push_error("match director: bot scene is not a Mouse")
				return
			bot.name = "Bot%s%d" % [Team.name_of(side), seat]
			bot.team = side
			bot.role = Bot.DEFENDER if seat % 2 == 1 else Bot.RAIDER
			# Positioned BEFORE it enters the tree. A body that exists at the origin for one
			# frame and is moved afterwards depenetrates against its old overlap and its new
			# transform at once, which fires whoever was standing there across the arena.
			bot.position = _nests[side].spawn_point()
			add_sibling(bot)
			# Then placed properly, once the model exists to be turned. The same call a respawn
			# uses -- one way to put a mouse on its feet, first time or fifth.
			_send_home(bot)
