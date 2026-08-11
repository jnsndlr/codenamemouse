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
## A crew's stores changed. Carries the side and what it left, so the HUD can tick the counter
## the moment it happens (GDD section 10 asks for exactly that, and asks for it to be hard to
## miss -- the whole point of a life costing something is that the team sees it go).
signal cheese_changed(side: int, amount: int)
signal match_ended(winner: int)

const DIRECTOR_GROUP: StringName = &"match_director"
const CHEESE_CACHE := preload("res://scripts/game/cheese_cache.gd")
## No winner: the clock ran out level.
const DRAW: int = -1

## Who the mice are, per crew, by seat. Flavour, and cheap -- but the roster is a list of names
## and "BotBLUE2" on it makes your own crew read as scenery. Distinct across the two crews so a
## name in the feed is never ambiguous.
const CREW_NAMES: Array = [
	["NIBS", "PIP", "TUFT", "BURR", "SNIP", "MOTE"],
	["BRIE", "WICK", "GRIT", "RUSK", "CHAFF", "DUSK"],
]

## What each seat is FOR: where it stands, and what it turns up as.
##
## ONE TABLE RATHER THAN TWO ALTERNATIONS. Role used to be `seat % 2` and class was not chosen at
## all, which meant the composition of a crew was an emergent property of an arithmetic
## expression -- readable only by working it out, and impossible to state an intent about. The
## intent is stateable: every crew fields a defender at home, somebody going for the banner, and
## the two specialists whose systems M5 is trying to observe. Written down, it can be argued with.
##
## THE ENGINEER RAIDS AND THE SNEAK DEFENDS, both on purpose. An Engineer only digs somewhere
## worth digging to, and the place worth digging to is the other crew's half -- a defending
## Engineer would cut a burrow around its own nest and prove nothing. The Sneak holds the nest
## because sonar is a WATCH: sounding the layer below your own banner is how a crew finds out it
## is being tunnelled under, which is the counterplay the Engineer's raid deserves.
##
## Seat 0 is the player's on blue. It is the Generalist because that is the on-ramp, and because
## a human who wants something else can walk to the nest and press C.
##
## ONE ENGINEER, NOT TWO. The second Engineer seat was a mistake made for a good reason -- more
## diggers, more tunnel, more for M5 to be about -- and it produced the opposite. Two of them raid
## on separate errands, get interrupted separately and respawn separately, so a crew ended up with
## two half-finished corridors rather than one that went anywhere. One Engineer, reusing its own
## mouth (see bot_digger.gd), builds a network. The fifth seat is a second Generalist raider, which
## is also the honest answer to "what does a crew actually need more of".
##
## Indexed modulo its own length, so `crew_size` can be turned up or down without this going out
## of range.
const SEATS: Array[Dictionary] = [
	{"class": MouseClass.GENERALIST, "defends": false},
	{"class": MouseClass.SNEAK, "defends": true},
	{"class": MouseClass.ENGINEER, "defends": false},
	{"class": MouseClass.BRUTE, "defends": true},
	{"class": MouseClass.GENERALIST, "defends": false},
]

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
## Seconds flat on your back before you're back at your nest, while the crew can pay for it.
@export var respawn_seconds: float = 6.0
## And what it costs when the crew is broke (GDD section 2).
##
## SURVIVABLE, NOT TERMINAL, and the gap between the two numbers is the whole design. A crew at
## zero is not out -- it is a crew that gets overrun if it keeps trading, which is what makes
## disengaging and going to refill a real option rather than a concession. Section 2 asks
## specifically that this not be tuned away.
@export var broke_respawn_seconds: float = 20.0
## Extra seconds on top, for a mouse the roof came in on ([method Mouse.bury]).
##
## ZERO, AND DELIBERATELY LEFT THERE. Burial arrived as a *word*: a collapse is not a scruffing and
## should not be called one. Whether digging yourself out should also take longer than getting up
## off the floor is a genuinely separate question -- it changes what the Brute's ability is worth
## and how much a corridor costs to stand in -- and it is the sort of thing that should be decided
## by playing rather than inherited from a rename. The dial is here so that decision is one number
## when somebody wants to make it.
@export var buried_extra_seconds: float = 0.0
## How far off the spawn point each arrival is placed. See `_send_home`: mice sharing a point
## do not stand on each other, they launch.
@export var spawn_spread: float = 0.4

@export_group("Cheese")
## What each crew starts the match with. GDD section 2: cheese is the team's respawn supply,
## not a second score -- the team's health bar.
##
## THE WHOLE ECONOMY LANDED AT ONCE, and it had to. A respawn cost without any way to refill is
## a countdown, and a twenty-second respawn on top of that is a death spiral -- both are a worse
## game than no economy at all. So caches, carrying, banking, raiding, the broke respawn and
## Scurry arrived together at M6, and the number on the HUD has consequences in both directions.
@export var starting_cheese: int = 20
## The most a crew can hold. Caps the bankruptcy play's upside so a crew that spends a whole
## match hauling cheese cannot bank an unlosable pile -- the point of refilling is to get back
## in the fight, not to win by not fighting.
@export var cheese_ceiling: int = 40
## How close a fresh drop has to be to an existing pile to join it rather than start its own.
##
## Dropped cheese never rots, which is what makes a fight worth going back to -- and is also what
## would carpet a contested corridor in single wedges if each one stood alone. Fifteen dots inside
## five metres is noise; one pile of fifteen is a landmark, and a landmark is the thing worth
## fighting over. Merging is what turns a killing ground into an objective instead of litter.
@export var drop_merge_radius: float = 2.2
## How far a scruffed carrier's banner skids, in metres.
##
## THE STAND-OFF ON ONE SQUARE METRE is what this is for -- see [method Banner.drop], which has the
## argument. Deliberately smaller than `drop_merge_radius`, because the banner and the cheese are
## being scattered for two different reasons: the banner skids so the ground around a fallen
## carrier becomes contestable, and it must not skid so far that the crew who won the fight cannot
## find it.
@export var banner_scatter: float = 1.4
## How far the wedges a scruffed mouse was carrying fly, in metres.
##
## WIDER THAN THE BANNER'S, and the reason is capacity. A Brute goes down with up to five wedges on
## it, and five wedges landing on one spot is the same pile it was carrying -- whoever won the
## fight sweeps it up in one step and the haul never happened. Spread over a couple of metres it is
## a *scatter*, which takes time to collect, can be contested while you collect it, and is
## visibly the wreck of somebody's run.
@export var cheese_scatter: float = 2.0
## What a wedge in the air looks like. Matched to [CheeseCache]'s own defaults rather than read off
## a cache, because a scatter can happen where there is no cache to ask -- and a wedge that changed
## colour on landing would make the throw read as a swap rather than as a throw.
@export var dropped_cheese_color: Color = Color(0.93, 0.78, 0.32)
@export var dropped_wedge_size: float = 0.16

@export_group("Bots")
## Mice per crew, the player included. Solo play is the same match with AI in every other seat
## (GDD section 1), so this is one honest number rather than two bot counts: the player takes a
## blue seat and every remaining seat on both sides is filled with a bot.
##
## FIVE, past the GDD's four, and the extra seat is bought for a reason rather than for scale.
## Three was the smallest crew that could field a defender and still raid, which was the right
## number while the only question was whether the flag run was tense. M5 asks a different one --
## is an enemy tunnel frightening -- and that needs somebody to have DUG one. A crew of five can
## carry a full-time Engineer and a Sneak without giving up the defender or the raid, so the
## hidden-information systems get exercised in every match instead of when the seats happen to
## line up.
@export var crew_size: int = 5
@export var bot_scene: PackedScene = preload("res://scenes/actors/bot.tscn")
## What a seat holding a remote human gets. The same scene the local player is, because a
## networked player must not be a different kind of thing from a local one.
@export var player_scene: PackedScene = preload("res://scenes/player/player.tscn")

var _nests: Array[Nest] = []
var _banners: Array[Banner] = []
var _player: Mouse
var _score: Array[int] = [0, 0]
var _cheese: Array[int] = [0, 0]
var _clock: float = 0.0
var _playing: bool = true
var _winner: int = DRAW
var _restart_left: float = 0.0
## How many mice have been placed at a nest, so consecutive arrivals land on different spots.
var _spawned: int = 0
## mouse -> seconds until it's back on its feet.
var _down: Dictionary = {}
## "side:seat" -> Mouse (M7 step 4). The snapshot is seat-indexed, so replication needs to be able
## to ask "who is in chair 7" without searching the tree and hoping the answer is stable.
var _seated: Dictionary = {}
## Whether this machine applies the rules. False on a client, where the server owns all of them
## and this node's only remaining job is having spawned the mice.
var _simulating: bool = true

## Positions are sent as 32-bit floats. A cache created from a packet therefore need not compare
## bit-for-bit with the same deterministically generated position on the client, even though it is
## visibly the same place. Piles cannot be closer than the merge radius in ordinary play, so five
## centimetres is generous for serialization error and far too small to confuse two real piles.
const CACHE_RECONCILE_DISTANCE: float = 0.05


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
	_cheese = [starting_cheese, starting_cheese]

	# The local human takes whatever seat this machine holds -- blue 0 when hosting or offline,
	# and whatever the host handed out when joining. `local_seat` is empty only while a client is
	# still connecting, which is the one case where blue 0 is a guess rather than an answer.
	_player = get_node_or_null(player_path) as Mouse
	if _player != null:
		var mine := _seats().seat_of(_local_peer())
		var side: int = mine[0] if not mine.is_empty() else Team.BLUE
		var seat: int = mine[1] if not mine.is_empty() else 0
		_player.set_team(side)
		_name_seat(_player, side, seat)
		# ONLY THE SERVER MAY REGISTER A CHAIR HERE. A client does not know its seat yet -- the
		# fallback above guesses blue 0 -- and registering that guess made `adopt_seating` see a
		# non-empty table and decline to correct it. The client then listened to blue 0's poses
		# for the whole match: its mouse stood exactly where the host's was standing, which looks
		# like "no input is getting through" and is nothing of the kind.
		if _local_is_server():
			_remember_seat(_player, side, seat)
		_send_home(_player)

	# Deferred, because a node cannot gain siblings while its parent is still building its
	# children -- `add_sibling` refuses outright during `_ready`. One frame later the arena is
	# whole, which is also when the navmesh is finished baking and there is somewhere to walk.
	#
	# A CLIENT WAITS FOR ITS SEATING INSTEAD. It cannot know which chair is its own until the
	# server says so, and spawning first would put a bot in the chair the human is about to sit
	# in -- two mice in one seat, which the snapshot has no way to express and the player would
	# see as their own body standing next to them.
	if _local_is_server():
		_spawn_bots.call_deferred()
	event.emit("MATCH START -- steal the %s banner" % Team.name_of(Team.RED))


# --------------------------------------------------------------------------------- queries


## The mouse the human is driving, for anything that has to tell "you" from "them" -- the HUD
## and, later, the per-team visibility filter at M5.
func get_player() -> Mouse:
	return _player


## The mouse this machine's human is driving. The same thing as `get_player` today, and named
## separately because M7's survey found "the player" assumed singular in thirty-one places -- this
## is the one that means "mine" rather than "the only one".
func local_mouse() -> Mouse:
	return _player


## Who is in a given chair, or null. The question replication asks thirty times a second.
func seat_mouse(side: int, seat: int) -> Mouse:
	# VALIDITY BEFORE THE CAST, not after. Typing the variable `Mouse` performs the cast on
	# assignment, and casting a freed object throws -- so the `is_instance_valid` guard that looks
	# like it covers this was already too late. Swapping a bot for a remote player frees a mouse
	# every time somebody joins, and this is asked ten times per snapshot, thirty times a second.
	var who: Variant = _seated.get("%d:%d" % [side, seat])
	if who == null or not is_instance_valid(who):
		return null
	return who as Mouse


## Stop applying the rules. Called on a client, where every rule resolves on the server.
##
## The mice stay, the HUD stays, the scene stays -- what stops is this node's `_physics_process`,
## which is where pickup, capture, scruffing, respawn and the whole cheese loop live. That they are
## all in one place is what makes this one line instead of a client-side flag on every rule, and it
## is the survey's "MatchDirector is already the sim" being cashed in.
func set_simulating(on: bool) -> void:
	_simulating = on
	set_physics_process(on)
	# The banners go with it. They own a return clock that expires into an action, and an action is
	# a rule -- a client counting the same twenty seconds down and sending the banner home itself
	# would agree with the server right up until the two clocks did not.
	for banner: Banner in _banners:
		if banner != null:
			banner.set_puppet(not on)


## The scoreboard, from the wire. The one door through which a client's match state is written.
##
## EVERY FIELD HERE IS ONE THE RULES ABOVE WOULD HAVE SET, which is why this is a single method
## rather than a setter each: it is not an API, it is the seam where "this machine worked it out"
## becomes "this machine was told". Nothing else may call it and nothing on a host ever does.
##
## The HUD is not involved and does not need to be. `score_bug`, `match_hud` and `roster` ask this
## node for these numbers already, so writing them here is the whole of making a client's HUD
## correct -- no UI file learns that a network exists.
func adopt_state(state: MatchState, crew: int) -> void:
	_score[Team.BLUE] = state.score[Team.BLUE]
	_score[Team.RED] = state.score[Team.RED]
	_clock = state.clock
	_winner = state.winner
	if _playing != state.playing:
		_playing = state.playing
		match_ended.emit(_winner)
	for side: int in [Team.BLUE, Team.RED]:
		if _cheese[side] != state.cheese[side]:
			_cheese[side] = state.cheese[side]
			# Emitted rather than merely stored, because the cheese counter is the one HUD element
			# that ANIMATES on change (GDD section 2: the visibility of the spend is the feature),
			# and a client that only ever saw the number arrive would show the count without the
			# thing that makes a Scurry feel like it cost something.
			cheese_changed.emit(side, _cheese[side])
	score_changed.emit(_score[Team.BLUE], _score[Team.RED])

	_down.clear()
	for side: int in [Team.BLUE, Team.RED]:
		for seat: int in range(crew):
			var mouse := seat_mouse(side, seat)
			var left := float(state.respawns[Snapshot.key_for(side, seat, crew)])
			if mouse != null and left > 0.0:
				_down[mouse] = left

	for side: int in [Team.BLUE, Team.RED]:
		var flag: MatchState.Flag = state.flags[side]
		var by: Mouse = null
		if flag.carrier != MatchState.NOBODY:
			by = seat_mouse(flag.carrier / crew, flag.carrier % crew)
		_banners[side].adopt(flag.state, by, flag.position)


## A line of commentary that was written somewhere else. Emitted exactly as a local one would be,
## so the feed cannot tell the difference and there is one place that formats these.
func adopt_event(text: String) -> void:
	event.emit(text)


## Replace the client's cheese world with the server's complete picture.
##
## MATCH BY PLACE, NOT NODE NAME. Authored caches have deterministic readable names, but runtime
## drops do not, and names are scene-tree bookkeeping rather than game identity. Piles never move;
## their position is their stable identity, with a small allowance for float serialization.
func adopt_cheese_caches(state: CheeseState) -> void:
	if _simulating or state == null:
		return

	var unmatched: Array[CheeseCache] = []
	for node: Node in get_tree().get_nodes_in_group(CheeseCache.GROUP):
		var cache := node as CheeseCache
		if cache != null and not cache.is_queued_for_deletion():
			unmatched.append(cache)

	for reading: CheeseState.Cache in state.caches:
		var at := Vector3(reading.position.x, 0.0, reading.position.y)
		var cache := _cache_at(unmatched, at)
		if cache == null:
			cache = _make_cache(at, reading.wedges, reading.spread, "ReplicatedWedge")
		else:
			unmatched.erase(cache)
			if cache.wedges != reading.wedges or not is_equal_approx(cache.spread, reading.spread):
				cache.adopt(reading.wedges, reading.spread)

	# Anything the client still has is absent from the authoritative picture. Remove it from the
	# group immediately so the minimap and a second packet in this frame cannot find a phantom
	# while `queue_free` waits for the end of the frame.
	for stale: CheeseCache in unmatched:
		stale.remove_from_group(CheeseCache.GROUP)
		stale.queue_free()


func _cache_at(caches: Array[CheeseCache], at: Vector3) -> CheeseCache:
	var closest: CheeseCache = null
	var distance := CACHE_RECONCILE_DISTANCE
	for cache: CheeseCache in caches:
		var gap := Vector2(cache.global_position.x - at.x, cache.global_position.z - at.z).length()
		if gap <= distance:
			closest = cache
			distance = gap
	return closest


func _make_cache(at: Vector3, wedges: int, spread: float, cache_name: String) -> CheeseCache:
	var pile := Node3D.new()
	pile.set_script(CHEESE_CACHE)
	pile.name = cache_name
	pile.wedges = wedges
	pile.spread = spread
	var field := get_tree().get_first_node_in_group(&"cheese_field")
	(field if field != null else self).add_child(pile)
	pile.global_position = at
	# `_ready` ran when the node was added, before its final global position was known. Rebuild once
	# at the real position so the seeded wedge scatter is stable and matches a locally made pile.
	pile.adopt(wedges, spread)
	return pile as CheeseCache


## A client learning the seating for the first time: take our own chair, then fill the rest.
##
## Called once, when the first seating message arrives. Everything here is deferred until then
## because a client that guessed would guess blue seat 0 and be wrong for every player but the
## host.
func adopt_seating(roster: Seats, local_peer: int) -> void:
	var mine := roster.seat_of(local_peer)
	if mine.is_empty() or _player == null:
		return
	if not _seated.is_empty():
		return

	_player.set_team(mine[0])
	_name_seat(_player, mine[0], mine[1])
	_remember_seat(_player, mine[0], mine[1])
	_spawn_bots()


## Put a remote human's mouse in a chair a bot was holding, or hand it back.
##
## THE MOUSE IS REPLACED RATHER THAN RETROFITTED. A `Bot` ignores the input frame -- its `_control`
## reads a navigation path -- so driving one with a received frame arrives, is applied, and does
## nothing, which is exactly the failure this was found by: the host logged 285 inputs a second
## while the mouse stood still. The seat gets a `Player` marked remote instead, so a networked
## human runs the *identical* code a local one does, stamina and speed ladder included.
##
## Placed at the nest rather than where the bot was standing, for the same reason a respawn is:
## a mouse that appears mid-corridor belongs to a match nobody was watching.
func seat_remote(side: int, seat: int, remote: bool) -> void:
	if not _simulating or player_scene == null or bot_scene == null:
		return
	var current := seat_mouse(side, seat)
	if current != null:
		var already_remote := current is Player
		if already_remote == remote:
			return
		# Out of the group before it is out of the tree, the same bargain `SonarMark.discard` makes.
		# A `queue_free`d node survives in its groups to the end of the frame, and every roster walk
		# in the game reads that group -- so leaving it there means one more tick of scans, rules and
		# signal wiring aimed at a mouse that is already gone.
		current.remove_from_group(Mouse.MOUSE_GROUP)
		current.queue_free()

	var mouse: Mouse = (player_scene if remote else bot_scene).instantiate()
	if mouse == null:
		return
	var post: Dictionary = SEATS[seat % SEATS.size()]
	mouse.name = "%s%s%d" % ["Peer" if remote else "Bot", Team.name_of(side), seat]
	mouse.team = side
	if remote:
		mouse.call("set_remote", true)
	else:
		mouse.role = Bot.DEFENDER if bool(post["defends"]) else Bot.RAIDER
		mouse.preferred_class = int(post["class"])
	_name_seat(mouse, side, seat)
	_remember_seat(mouse, side, seat)
	mouse.position = _nests[side].spawn_point()
	add_sibling(mouse)
	_send_home(mouse)


func _local_is_server() -> bool:
	var net := get_node_or_null(^"/root/Net")
	return net == null or bool(net.call("is_server"))


func _remember_seat(mouse: Mouse, side: int, seat: int) -> void:
	_seated["%d:%d" % [side, seat]] = mouse


func nest_of(side: int) -> Nest:
	return _nests[side]


func banner_of(side: int) -> Banner:
	return _banners[side]


func score_of(side: int) -> int:
	return _score[side]


## What a crew has left in its stores. The second-most important number on the HUD, because it
## is lives (GDD section 10).
func cheese_of(side: int) -> int:
	return _cheese[side]


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
		_check_cheese(mouse)


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
		# `may_take` is the banner's own veto and covers exactly one case: the mouse it was just
		# knocked out of, for `recovery_seconds`. Without it a Slam is a no-op -- the banner lands
		# on the carrier's feet and this line hands it straight back on the same tick.
		if _within(mouse, theirs, pickup_radius) and theirs.may_take(mouse):
			theirs.take(mouse)
			event.emit("%s takes the %s banner" % [
				mouse.get_display_name(), Team.name_of(theirs.team)
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


# ---------------------------------------------------------------------------------- cheese


## The wedge loop: take one, walk it home, put it in the pile (GDD section 2).
##
## THREE PLACES A WEDGE CAN COME FROM AND ONE IT CAN GO. Caches on the map, a wedge somebody
## dropped, and the enemy's own stores -- which section 2 makes raidable on purpose, because it
## is the only cheese in the game that someone is standing over. Cheese is only ever banked at
## your own nest, so every wedge is a walk, and the walk is the mechanic.
##
## Surface only. Cheese does not go down a hole for the same reason a banner does not: an errand
## you can run underground is an errand nobody can contest.
func _check_cheese(mouse: Mouse) -> void:
	if mouse.get_plane() != 0:
		return

	# Banking first, so arriving home with a wedge always resolves this frame rather than being
	# beaten to it by the cache you happen to be standing in.
	#
	# `[REVISED]` NO LONGER A `return` WHEN YOU ARE MERELY HOLDING SOMETHING. While a mouse could
	# carry exactly one wedge, "carrying" and "full" were the same condition and returning here was
	# right. With capacity they are different: a Brute with two wedges walking over a cache should
	# take a third, and this line used to be what silently stopped it. The return stays for the
	# frame a bank actually happens, so arriving home does not also refill you from a pile
	# somebody dropped on your own doorstep.
	if mouse.get_carried_cheese() > 0 and _nests[mouse.team].at_stores(mouse.global_position):
		var banked := mouse.release_wedges()
		gain_cheese(mouse.team, banked)
		event.emit("%s banks %d wedge%s  (%s: %d)" % [
			mouse.get_display_name(), banked, "" if banked == 1 else "s",
			Team.name_of(mouse.team), _cheese[mouse.team]
		])
		return

	# Full paws, or still stowing the last one. Both are the mouse's own business (see
	# [method Mouse.has_room]) and neither is worth announcing -- a cache you walk over without
	# taking from is a thing you can see happening.
	if not mouse.has_room():
		return

	var cache := CheeseCache.nearest(get_tree(), mouse.global_position)
	if cache != null and cache.within(mouse.global_position) and cache.take():
		mouse.take_wedge()
		return

	# Raiding their stores. Costs THEM a life and gains you nothing until you get it home, which
	# is what makes a raid a commitment rather than a free denial -- get scruffed on the way back
	# and the wedge is lying in the open for whoever wants it.
	#
	# The PILE, not the nest. Their banner stands at the nest's centre and `_check_pickup` runs
	# before this, so a raider judged by the nest radius picks the banner up instead -- every
	# time, because it is worth more. Raiding would exist only in the one case where their banner
	# is already out and you have better things to do. The store being its own spot inside the
	# nest is what makes it a thing you can go and take.
	var theirs := Team.other(mouse.team)
	if _cheese[theirs] > 0 and _nests[theirs].at_stores(mouse.global_position):
		_spend_cheese(theirs, 1)
		mouse.take_wedge()
		event.emit("%s raids the %s stores" % [
			mouse.get_display_name(), Team.name_of(theirs)
		])


## Leave a pile where somebody fell, and leave it there. Nothing rots (GDD section 2 gives cheese
## no clock), so this is the map growing its own objectives: every fight that happened becomes
## somewhere both crews have a reason to come back to.
##
## Joins a pile already lying nearby rather than starting a new one. Without that, permanent drops
## turn any contested ground into a scatter of single wedges -- and a scatter is litter, while one
## growing pile is a place. The same fight that made it worth defending is what makes it worth
## taking back.
##
## Hung on the map's cache field when there is one, so it is scenery on the lawn like every other
## cache and drops out of sight with them when the view goes underground. Falls back to the
## director, which is somewhere rather than nowhere -- a map with no cheese field is a map where
## carrying cheese should still not silently lose it.
func _drop_cheese(at: Vector3, wedges: int) -> void:
	var here := Vector3(at.x, 0.0, at.z)
	var nearby := CheeseCache.nearest(get_tree(), here)
	if nearby != null and nearby.global_position.distance_to(here) <= drop_merge_radius:
		nearby.add_wedges(wedges)
		return

	_make_cache(here, wedges, 0.22, "DroppedWedge")


## A whole armful going down at once: one wedge per landing spot, thrown around the mouse.
##
## THIS EXISTS BECAUSE CAPACITY DOES. While everybody carried exactly one wedge, `_drop_cheese`
## was the whole story and one pile was the right picture. A Brute carries five, and five wedges
## delivered to a single point is the carrier's own stack handed intact to whoever scruffed it --
## the haul is not interrupted, it changes owner. Scattered, it is a mess somebody has to stand in
## the open picking up.
##
## `[REVISED]` THE WEDGES ARE THROWN AND THE PILES ARE MADE WHERE THEY LAND, rather than the piles
## being placed at spots a random number picked. See [FlyingWedge] for why that is one system
## instead of two. What this method now does is choose a direction and a distance, hand both to a
## wedge, and wait to be told where it stopped.
##
## SIBLINGS DO NOT MERGE WITH EACH OTHER, AND THAT IS THE OLDEST RULE HERE. The first version of
## this looped `_drop_cheese`, and the scatter did almost nothing: `drop_merge_radius` is 2.2
## against a 2.0 scatter, so the first wedge made a pile and every wedge after it was inside that
## pile's radius and joined it. The armful came apart in the air and arrived as one stack -- the
## exact picture this method exists to prevent, invisible except as an audit that failed about one
## run in three.
##
## FLIGHT MAKES THAT RULE HARDER RATHER THAN EASIER, which is worth saying out loud: the wedges now
## land at *different times*, so "the piles that existed before the drop" is no longer the same set
## as "the piles that exist when this wedge lands". The snapshot below is therefore taken once, at
## launch, and carried to every wedge in the armful through the binding on `settled`. A wedge
## landing near a pile that was already lying there still joins it -- that is the landmark rule and
## it is what stops contested ground becoming litter over a match. What it may not do is join a
## pile its own siblings made a fifth of a second ago.
func _scatter_cheese(at: Vector3, wedges: int) -> void:
	if wedges <= 0:
		return

	# Snapshotted BEFORE anything is thrown. Identity by instance rather than by position: a pile
	# that grows during this drop is still the same pile, and one made by a sibling mid-flight is
	# still not eligible however close it lands.
	var already: Array[CheeseCache] = []
	for node: Node in get_tree().get_nodes_in_group(CheeseCache.GROUP):
		var pile := node as CheeseCache
		if pile != null and not pile.is_queued_for_deletion():
			already.append(pile)

	if cheese_scatter <= 0.0:
		_drop_cheese(at, wedges)
		return

	# THE SURFACE OVER WHERE YOU FELL, not where you fell. Cheese has never gone underground (see
	# `_drop_cheese`), so a mouse scruffed three planes down spills onto the lawn above -- and a
	# wedge launched from the corridor it actually died in would fly up through the earth.
	var from := Vector3(at.x, 0.0, at.z)
	var field := get_tree().get_first_node_in_group(&"cheese_field")
	for i: int in range(wedges):
		# Spread evenly around, with a nudge so an armful is not a perfect rosette.
		var heading := TAU * (float(i) + randf() * 0.7) / float(wedges)
		# Square-rooted so the landing spots are spread evenly over the disc rather than bunched in
		# the middle. Divided down because the bounces carry a wedge past where it first hits --
		# this is the *throw*, not the resting place, and the resting place is what has to stay
		# inside `cheese_scatter`.
		var reach := sqrt(randf()) * cheese_scatter * 0.62
		var wedge := FlyingWedge.toss(
			field if field != null else self, from, heading, reach,
			dropped_cheese_color, dropped_wedge_size
		)
		wedge.settled.connect(_land_wedge.bind(already))


## One wedge has stopped rolling. The only place a scatter turns into cheese anybody can pick up.
func _land_wedge(_wedge: FlyingWedge, at: Vector3, eligible: Array[CheeseCache]) -> void:
	for pile: CheeseCache in eligible:
		if is_instance_valid(pile) and pile.global_position.distance_to(at) <= drop_merge_radius:
			pile.add_wedges(1)
			return
	_make_cache(at, 1, 0.22, "DroppedWedge")


## Put cheese in a crew's pile. The only way the number ever goes up.
func gain_cheese(side: int, amount: int) -> void:
	if amount <= 0:
		return
	var before := _cheese[side]
	_cheese[side] = mini(before + amount, cheese_ceiling)
	if _cheese[side] == before:
		return
	cheese_changed.emit(side, _cheese[side])
	if before == 0:
		event.emit("%s IS BACK IN CHEESE" % Team.name_of(side))


## Spend a cheese on a Scurry (GDD sections 2 and 9). Returns whether it fired.
##
## THE POOL IS CHECKED BEFORE THE MOUSE AND THE MOUSE BEFORE THE CHARGE, so a crew at zero is
## told no without being billed and a mouse on cooldown cannot burn a teammate's life on nothing.
## Everyone watching sees the counter drop at the moment the burst starts, which is most of what
## makes this a decision rather than a button -- section 2 is explicit that the visibility of the
## spend is the feature.
func try_scurry(mouse: Mouse) -> bool:
	if not _playing or mouse == null or mouse.is_scruffed():
		return false
	if _cheese[mouse.team] <= 0:
		return false
	if not mouse.scurry_ready():
		return false
	if not mouse.start_scurry():
		return false
	_spend_cheese(mouse.team, 1)
	event.emit("%s scurries  (%s: %d)" % [
		mouse.get_display_name(), Team.name_of(mouse.team), _cheese[mouse.team]
	])
	return true


## How long this crew waits to stand back up. Six seconds, or twenty while broke.
##
## Read at the moment of the scruff rather than when the timer runs out, so a crew that refills
## while you are down does not shorten a wait you already earned -- and, more to the point, so
## the punishment lands on the crew that was broke when it lost the fight. Zero cheese is meant
## to be survivable (section 2): twenty seconds is a crew getting overrun, not a crew that has
## lost, which is exactly what makes the bankruptcy play worth trying.
func respawn_wait(side: int) -> float:
	return broke_respawn_seconds if _cheese[side] <= 0 else respawn_seconds


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
			# SCATTERED HERE AND NOWHERE ELSE. Every other drop in the game is a rule setting the
			# banner down -- a carrier refused a shaft, a carrier who stopped existing -- and those
			# should land where the rule caught them. This one is somebody being put on their back.
			banner.drop(banner_scatter)
			event.emit("the %s banner is dropped" % Team.name_of(banner.team))

	# What you were hauling lands where you fell, exactly as the banner does and for the same
	# reason: it leaves the thing in the middle of the fight that just happened. A wedge that
	# vanished on a scruff would make escorting a carrier pointless and raiding free.
	var wedges := mouse.release_wedges()
	if wedges > 0:
		_scatter_cheese(mouse.global_position, wedges)
		event.emit("%s drops %d wedge%s" % [
			mouse.get_display_name(), wedges, "" if wedges == 1 else "s"
		])

	# READ BEFORE THE CHARGE. A crew on its last cheese pays for this respawn at the normal rate
	# and goes broke for the next one -- charging first would take the cheese and then bill the
	# same death for the broke timer, which is the one life you already paid for.
	# BURIED IS A LONGER WAIT AND THE DIAL IS AT ZERO. `buried_extra_seconds` exists so that "the
	# roof costs more than a paw" is one number rather than a refactor -- and it starts at nothing,
	# because renaming an outcome is a change to what the game SAYS and lengthening a respawn is a
	# change to what it costs, and the two arrived in one request wearing the same coat.
	_down[mouse] = respawn_wait(mouse.team) + (
		buried_extra_seconds if mouse.was_buried() else 0.0
	)
	# The life, charged at the moment it is spent rather than when the mouse stands back up. You
	# are down, the crew is already a cheese poorer, and the counter ticking as you hit the dirt
	# is the whole reason it is on screen (GDD section 10).
	_spend_cheese(mouse.team, 1)
	if mouse.was_buried():
		# Named even with nobody to credit, unlike a scruff. A collapse is the one way to go down
		# that has no attacker in half the cases that matter -- caught in your own Engineer's
		# corridor, or in a stomp from a Brute you never saw -- and "nothing appeared in the feed"
		# is how a player concludes the game glitched rather than that the ceiling arrived.
		if by != null:
			event.emit("%s buries %s" % [by.get_display_name(), mouse.get_display_name()])
		else:
			event.emit("%s is buried" % mouse.get_display_name())
	elif by != null:
		event.emit("%s scruffs %s" % [by.get_display_name(), mouse.get_display_name()])


## Take cheese off a crew's pile. Floors at zero and says so once.
##
## Zero is SURVIVABLE, deliberately (GDD section 2). The bankruptcy play -- concede a capture,
## pull everyone off defence, go and refill the pool -- only exists because running out is a
## setback rather than an ending, and it is one of the best things about cheese-as-lives. What
## running out actually costs is M6's to decide, alongside the caches that let you fix it.
func _spend_cheese(side: int, amount: int) -> void:
	if _cheese[side] <= 0:
		return
	var before := _cheese[side]
	_cheese[side] = maxi(0, before - amount)
	cheese_changed.emit(side, _cheese[side])
	if _cheese[side] == 0:
		event.emit("%s IS OUT OF CHEESE" % Team.name_of(side))


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
	_cheese = [starting_cheese, starting_cheese]
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
	for side in [Team.BLUE, Team.RED]:
		cheese_changed.emit(side, _cheese[side])
	event.emit("MATCH START -- steal the %s banner" % Team.name_of(Team.RED))


## Give a mouse the name its seat carries, unless the scene already named it. Nothing depends on
## a name being unique; it is on screen, and that is the whole job.
func _name_seat(mouse: Mouse, side: int, seat: int) -> void:
	if not mouse.display_name.is_empty():
		return
	var pool: Array = CREW_NAMES[side]
	mouse.display_name = pool[seat % pool.size()]


# --------------------------------------------------------------------------------- roster


## Find any mouse we haven't met and listen to it.
##
## Rescanned every tick rather than collected once at startup, because the roster genuinely
## changes: bots are spawned here, the player readies on its own schedule, and M7 adds players
## joining mid-match. At eight mice the scan is noise, and it means nothing can be forgotten by
## being created in the wrong order.
##
## ASKS THE SIGNAL, AND SKIPS A MOUSE ON ITS WAY OUT. It used to keep a `_known` table, and that
## table was wrong in a way that printed an engine error on **every seat handover in every match**:
## [method seat_remote] erases the outgoing mouse from it and then `queue_free`s that mouse -- but a
## queued node stays in its groups until the end of the frame, so the very next tick found a mouse in
## `MOUSE_GROUP` it had no record of, and connected a signal that was already connected. A cache of
## "have I met this" cannot be right when the thing it caches has a two-stage death; the signal
## itself always knows. `_on_scruffed` is unbound, so `is_connected` compares it exactly -- unlike a
## `bind`ed callable, whose arguments Godot ignores for equality (see `net_match.gd`).
func _scan_roster() -> void:
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or mouse.is_queued_for_deletion():
			continue
		if not mouse.scruffed.is_connected(_on_scruffed):
			mouse.scruffed.connect(_on_scruffed)


## The seat roster this match is being played from.
##
## Asked of the `Net` autoload rather than owned here, because occupancy outlives the arena: a
## client is seated the moment it connects, which is before the scene it will play in exists. The
## fallback is for the audits, which build a director without a session.
##
## OFFLINE IS THE SAME TABLE with one human in blue 0, so there is no branch below for
## "single player" -- that phrase does not appear anywhere in this file and should not start now.
func _seats() -> Seats:
	var net := get_node_or_null(^"/root/Net")
	if net != null:
		net.call("ensure_crew_size", crew_size)
		return net.call("seats")
	var solo := Seats.new(crew_size)
	solo.seat_host(NetTransport.SERVER_ID)
	return solo


func _local_peer() -> int:
	var net := get_node_or_null(^"/root/Net")
	return net.call("local_peer") if net != null else NetTransport.SERVER_ID


## Fill both crews from `SEATS`. Seat 0 on blue is the player's, if there is one.
##
## Both crews read the same table, so they are mirror images. That is worth more than variety
## here: when the two sides differ, every observation about a match has a second explanation, and
## M5's question -- is crawling into an enemy tunnel frightening -- cannot be answered by watching
## a crew that was simply better staffed.
func _spawn_bots() -> void:
	if bot_scene == null:
		return
	var roster := _seats()
	for side in [Team.BLUE, Team.RED]:
		for seat in range(roster.crew_size()):
			# A SEAT, NOT A BOT COUNT (M7 step 3). This used to be `range(first, crew_size)` with
			# `first` being 1 when a player happened to exist -- which is correct, and cannot
			# answer "seat 3 just disconnected mid-match, whose bot is that now". The roster
			# answers it: every seat is filled, and the ones with a human in them are skipped
			# here because that human's mouse arrives another way.
			# On a client the only chair to skip is our own -- every other seat gets a mouse here,
			# human or bot, because a remote player's mouse is drawn from snapshots exactly as a
			# remote bot's is and there is nothing to tell them apart at this end.
			if seat_mouse(side, seat) != null:
				continue
			if _simulating and roster.is_human(side, seat):
				continue
			var bot := bot_scene.instantiate() as Mouse
			if bot == null:
				push_error("match director: bot scene is not a Mouse")
				return
			var post: Dictionary = SEATS[seat % SEATS.size()]
			bot.name = "Bot%s%d" % [Team.name_of(side), seat]
			bot.team = side
			bot.role = Bot.DEFENDER if bool(post["defends"]) else Bot.RAIDER
			# The class the seat WANTS, and only that. It is NOT set here, deliberately: a bot
			# acquires its class at its own nest through the same rule the player's C key obeys
			# (class_swap.gd), and a bot spawns standing in that nest, so it arrives as a
			# Generalist and is an Engineer a third of a second later. Dressing it correctly here
			# would be the cheaper code and would make the swap point dead machinery -- exercised
			# by one human occasionally instead of by ten mice every respawn.
			bot.preferred_class = int(post["class"])
			_name_seat(bot, side, seat)
			# Positioned BEFORE it enters the tree. A body that exists at the origin for one
			# frame and is moved afterwards depenetrates against its old overlap and its new
			# transform at once, which fires whoever was standing there across the arena.
			bot.position = _nests[side].spawn_point()
			_remember_seat(bot, side, seat)
			# On a client nothing simulates, including the AI: this mouse is a picture of a bot
			# the server is thinking for, and letting it also think here would have it walk away
			# from where the snapshots keep putting it.
			if not _simulating:
				bot.set_puppet(true)
			add_sibling(bot)
			# Then placed properly, once the model exists to be turned. The same call a respawn
			# uses -- one way to put a mouse on its feet, first time or fifth.
			_send_home(bot)
