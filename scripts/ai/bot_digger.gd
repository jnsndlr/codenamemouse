class_name BotDigger
extends RefCounted
## An Engineer bot's raid, which is a dig.
##
## WHY THIS EXISTS. Until now nothing in a match ever cut a tunnel except the human. Bots could
## follow one (M4) and the network could keep two crews' maps apart (M5), but the second half of
## M5's question -- is crawling into an ENEMY tunnel frightening -- cannot be asked at all if the
## enemy has never dug. So the Engineer seat does the thing its class is for, and the yard fills
## up with corridors somebody else made. Everything M5 built to hide is now something there is
## something to hide.
##
## A SEPARATE FILE, and not because bot.gd is long. bot.gd is a RANKING -- six ifs that say what
## this crew values, readable top to bottom in one sitting -- and the moment a corridor march with
## its own progress timer and its own failure modes is spliced into it, that stops being true.
## Here the ranking stays a ranking and calls out to a thing with a name.
##
## IT ONLY EVER REPLACES THE LAST RULE. A bot does not dig instead of chasing the mouse carrying
## its banner, or instead of recovering the one lying in the grass -- those are urgent and a
## tunnel is a twenty-second investment. Digging is what an Engineer does INSTEAD OF WALKING to
## the enemy banner, which is bot.gd's rule 6 and its lowest-priority errand. When something
## urgent happens mid-corridor this simply stops driving, and route_planner.gd walks the bot out
## through the mouth it cut on the way in -- no unwinding, no abandonment state, because the
## tunnel it is standing in is a real route and the planner already knows how to use one.
##
## ONE CELL AT A TIME, ON A CLOCK. Opening a tile costs the same seconds it costs a player, so an
## Engineer underground is committed and slow and can be caught at it -- which is the trade GDD
## section 4 asks digging to be. A bot that cut a corridor instantly would make the tunnel free,
## and free tunnels would answer M5's question with the wrong game.

## Seconds for this bot to open one CELL.
##
## `[REVISED]` DERIVED NOW, AND FROM THE NETWORK'S OWN NUMBERS. This used to be a hardcoded 0.5
## with a header explaining that it was deliberately duplicated from dig_controller.gd, and warning
## that if the two ever disagreed the crew digging faster would be the one nobody was watching.
## That warning was about to come true: the player's dig moved to a per-plane clock and a per-class
## STROKE LENGTH, and a bot left on a flat half-second would have cut a full metre for the price
## of an Engineer's while playing a Generalist. Both halves now come from [TunnelNetwork], which is
## the object a bot legitimately holds -- so the duplication that made the warning necessary is
## simply gone, rather than being watched.
##
## A CELL RATHER THAN A STROKE, and that is what the conversion in here is for. Bots choose a
## neighbouring CELL and cut it with [method TunnelNetwork.dig], which lays one full metre however
## short the digger's own stroke is; charging them their class's stroke time for a whole metre of
## corridor would make a Generalist bot nearly three times faster underground than the player
## beside it. Paying by the metre keeps a bot's metres per second identical to a player's.
static func cell_seconds(bot: Mouse, plane: int) -> float:
	var stroke: float = TunnelNetwork.SEG_LENGTHS[bot.get_dig_stroke()]
	return TunnelNetwork.dig_seconds_at(plane) * (TunnelNetwork.SEG_LENGTH / maxf(stroke, 0.01))

## How near the goal the bot has to get before it stops tunnelling and comes up, in metres. It
## surfaces SHORT of the objective rather than under it: coming up on top of the banner would make
## a tunnel a teleport, and the point of the raid is to arrive somewhere unwatched, not to skip the
## last part of the map.
const SURFACE_WITHIN: float = 9.0
## How far the goal has to be before tunnelling is worth it at all. Under this, walk.
const WORTH_DIGGING: float = 22.0
## Clearance from its own nest before it will cut a mouth. A hole in the middle of your own spawn
## disc is where every respawning crew mate lands, and it puts the entrance to your network at the
## one coordinate the enemy already knows.
const NEST_CLEARANCE: float = 5.0
## How far a bot will walk to use a mouth its crew already cut, in metres. Generous, because
## walking to a real tunnel is almost always better than starting a second one.
const REUSE_RANGE: float = 34.0
## How much longer the trip through an existing mouth may be than the walk over the top, as a
## multiplier, and still be taken. Above 1 deliberately: underground is cover, and arriving unseen
## is worth a few metres of detour in a way a pure shortest-path comparison cannot express.
const REUSE_SLACK: float = 1.35
## How near a mouth counts as standing on it, in metres.
const DOORSTEP: float = 0.45
## How long a bot may fail to leave a cell before it writes off where it was trying to go. Longer
## than a stride and shorter than a fight, so a bot briefly body-blocked by a crew mate waits it
## out and a bot genuinely caught on geometry gives up quickly.
const STUCK_SECONDS: float = 1.4
## How long it stops thinking about digging after running out of options. Long enough to walk out
## and be somewhere else; short enough that a corridor is not abandoned over one bad seam.
const REST_SECONDS: float = 6.0

## Cells whose plan turned out to be impossible. Cleared whenever the bot picks a new heading, so
## a seam that stopped it once does not stop it forever on a different errand.
var _refused: Dictionary = {}
## The cell being opened or walked to, or MAX for "pick one".
var _target: Vector2i = Vector2i.MAX
var _progress: float = 0.0
## Which cell the bot is in, and the one it was in before that.
##
## THE PREVIOUS CELL IS NOT A CANDIDATE, and leaving it out of that rule cost a whole soak. With
## the way ahead blocked by a seam, `_choose` fell to the cross axis, picked the open cell beside
## it, arrived, re-chose from there, and picked the cell it had just left -- because that one is
## open too and the rule had no memory. Two bots spent thirty-five seconds stepping between the
## same pair of tiles at full walking speed. A digger needs to know where it came from.
var _here: Vector2i = Vector2i.MAX
var _previous: Vector2i = Vector2i.MAX
## How long the bot has been in the same cell while trying to leave it.
##
## THE WORLD IS ALLOWED TO SAY NO. "The cell is open, so I can walk into it" is very nearly true
## and fails often enough to matter -- a corner the capsule catches on, a shove from a fight, an
## enemy standing in the gap. Every one of those looks identical from here, and none of them is
## worth a special case. What is worth having is the bot NOTICING, because without it the first
## surprise is permanent: two Engineers ended a soak pressed against a wall, at speed, for the
## rest of the match.
var _stuck: float = 0.0
## Seconds until it will consider digging again. Set when it runs out of ideas, so it stops
## re-deciding sixty times a second and lets the ranking walk it somewhere useful.
var _rest: float = 0.0
## Whether the last `_choose` came back empty because the earth said no, rather than because the
## way ahead was already open. Two very different answers that were the same value.
var _dead_end: bool = false
## Corridor heads that ran into stone. NOT cleared by `reset` -- rock does not move, and a bot that
## forgot every time it climbed a shaft would walk back to the same seam all match.
var _spent: Dictionary = {}
## What it is doing, for the debug readout. Same job as bot.gd's `_intent`.
var _intent: String = ""


func get_intent() -> String:
	return _intent


## Whether it has given up for the moment. Read by the ranking, which must stop sending the bot to
## a corridor head it has just declared useless -- otherwise the rest is spent pacing in front of
## the stone instead of going and playing the match.
func is_resting() -> bool:
	return _rest > 0.0


## Give up whatever it was doing. Called when the bot's errand changes, so a corridor aimed at the
## enemy nest is not silently continued toward a banner that has since moved.
func reset() -> void:
	_target = Vector2i.MAX
	_here = Vector2i.MAX
	_previous = Vector2i.MAX
	_progress = 0.0
	_stuck = 0.0
	_refused.clear()
	_intent = ""


## One tick of the raid. Returns where the bot should walk and on which plane, or an empty
## dictionary for "not driving -- do whatever you would have done".
##
## The bot is passed in rather than held, so this object never outlives a mouse it has a reference
## to and never has to check whether it still does.
func think(bot: Mouse, network: TunnelNetwork, nest: Vector3, goal: Vector3, delta: float) -> Dictionary:
	if bot == null or network == null or bot.is_scruffed() or bot.is_carrying():
		return {}
	if not bot.can_enter_tunnels():
		return {}
	_rest = maxf(0.0, _rest - delta)
	if _rest > 0.0:
		_intent = ""
		return {}

	var plane := bot.get_plane()
	var here := network.world_to_cell(bot.global_position)
	var reach := _flat(bot.global_position, goal)

	# Where it is, and whether it is getting anywhere. Kept here rather than in `_underground`
	# because it is true of the bot rather than of the corridor.
	if here != _here:
		_previous = _here
		_here = here
		_stuck = 0.0
	else:
		_stuck += delta

	if plane == 0:
		return _from_the_lawn(bot, network, here, nest, goal, reach)
	return _underground(bot, network, plane, here, goal, reach, delta)


# ------------------------------------------------------------------------------- the surface


## On the lawn with a long walk ahead: use the way in your crew already has, or make one.
##
## USE BEFORE MAKE, and getting that the wrong way round was the whole of the first version's
## problem. A digger that cut a hole wherever it happened to be standing produced, over a minute,
## twenty-eight cells of tunnel spread across ELEVEN separate mouths -- because a raid is
## interrupted constantly (a banner drops, a carrier needs chasing, you get scruffed and respawn),
## and every time the errand came back round the bot started again from scratch a few metres from
## home. The yard filled up with three-cell stubs that went nowhere and meant nothing, and no crew
## ever had a network worth being frightened of.
##
## So an Engineer walks to its crew's nearest useful mouth and goes down THAT. The corridor below
## already points at the enemy, `_choose` prefers open ground, and the march therefore runs to the
## far end of what the crew has built and extends it. One growing tunnel per crew instead of a
## stub per respawn, and the only new idea is "look for a door before you make one".
func _from_the_lawn(
	bot: Mouse, network: TunnelNetwork, here: Vector2i, nest: Vector3, goal: Vector3, reach: float
) -> Dictionary:
	if reach < WORTH_DIGGING:
		return {}

	var door := _entrance(bot, network, goal, reach)
	if door != Vector2i.MAX:
		var at := network.cell_to_world(0, door)
		if _flat(bot.global_position, at) > DOORSTEP:
			_intent = "heading for our tunnel"
			return {"at": at, "plane": 0}
		if TunnelTransit.take(network, bot, 0) < 0:
			# Standing on it and unable to take it -- carrying, or too big. Not a digging problem.
			return {}
		reset()
		_intent = "gone to ground"
		return {"at": bot.global_position, "plane": bot.get_plane()}

	if _flat(bot.global_position, nest) < NEST_CLEARANCE:
		return {}
	if not network.can_shaft_down(0, here):
		return {}

	network.dig_shaft_down(0, here, bot.team)
	if TunnelTransit.take(network, bot, 0) < 0:
		return {}
	reset()
	_intent = "gone to ground"
	return {"at": bot.global_position, "plane": bot.get_plane()}


## The far end of this crew's network, as a place to walk to, or an empty dictionary if the crew
## has no tunnel worth going to.
##
## WHERE AN ENGINEER IS ACTUALLY TRYING TO GET TO while it is raiding. Its errand is the enemy
## banner, but its immediate destination is the head of its own corridor -- and the difference
## matters because the walk there runs through a tunnel, which is a routing problem and belongs to
## route_planner.gd rather than to a greedy stepper. Handing the ranking this point instead of the
## banner is what lets the planner do that walk properly; `_errand` keeps the banner, so the digger
## still knows which way to cut once it arrives.
##
## The cell closest to the goal, which is the head of the corridor by definition on a network that
## was dug toward one. Cheap: a few hundred cells against a distance each, three times a second.
##
## IT MUST BE SOMEWHERE ELSE, and by a clear margin. Scored against the bot's own position with no
## exclusions, the winner is frequently the cell the bot is STANDING IN -- its centre is a few
## centimetres nearer the goal than the mouse slouched at the edge of it. The ranking then hands
## the walker a destination it has already reached, `_heading` sees it inside the arrival slack and
## returns nothing, and the bot stands in its own corridor staring at its feet for the rest of the
## match. Both Engineers did exactly that. A whole cell of margin means the answer is always a
## place worth walking to, or no answer at all.
func frontier(bot: Mouse, network: TunnelNetwork, goal: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var standing := network.world_to_cell(bot.global_position)
	var here := bot.get_plane()
	var closest := _flat(bot.global_position, goal) - TunnelNetwork.CELL
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in network.known_tunnel_cells(plane, bot.team):
			if _spent.has(cell) or (plane == here and cell == standing):
				continue
			var at := network.cell_to_world(plane, cell)
			var gap := _flat(at, goal)
			if gap < closest:
				closest = gap
				best = {"at": at, "plane": plane}
	return best


## The crew's best way in, or MAX for "there isn't one worth walking to".
##
## Scored as the whole detour -- out to the mouth and on to the goal -- against walking straight
## there, which is the only comparison that means anything. A mouth behind you is not an entrance,
## it is a longer walk with a hole in the middle of it. `REUSE_SLACK` above 1 is what lets a bot
## accept a slightly worse walk for a much better arrival: underground is cover, and arriving
## unseen is worth a few metres.
func _entrance(bot: Mouse, network: TunnelNetwork, goal: Vector3, reach: float) -> Vector2i:
	var best := Vector2i.MAX
	var cheapest := reach * REUSE_SLACK
	for cell: Vector2i in network.known_shaft_cells(0, bot.team):
		var at := network.cell_to_world(0, cell)
		var walk := _flat(bot.global_position, at)
		if walk > REUSE_RANGE:
			continue
		var detour := walk + _flat(at, goal)
		if detour < cheapest:
			cheapest = detour
			best = cell
	return best


# ---------------------------------------------------------------------------- the corridor


## Underground: cut the next cell toward the goal, walk into it, repeat. Come up when close.
func _underground(
	bot: Mouse, network: TunnelNetwork, plane: int, here: Vector2i,
	goal: Vector3, reach: float, delta: float
) -> Dictionary:
	if reach <= SURFACE_WITHIN:
		return _surface(bot, network, plane, here)

	# Walking at an open cell and not arriving. Something the grid cannot see is in the way -- a
	# corner the capsule caught, a shove, somebody standing there. Which one does not matter and is
	# not worth asking; what matters is that this route is not working, so write the cell off and
	# go round. Only ever applies while WALKING: a dig is meant to look like standing still.
	if _target != Vector2i.MAX and network.is_dug(plane, _target) and _stuck > STUCK_SECONDS:
		_refused[_target] = true
		_target = Vector2i.MAX
		_stuck = 0.0

	if _target == Vector2i.MAX or _target == here:
		_target = _choose(network, plane, here, network.world_to_cell(goal))
		_progress = 0.0
		if _target == Vector2i.MAX:
			# NOT A FAILURE, and usually not even unusual. `_choose` returns nothing whenever the
			# way ahead is already open, which is the answer at every step of the walk out to the
			# frontier -- so this is the normal state of an Engineer between its mouth and its
			# face. Handing back lets route_planner.gd do that walk, which is the whole point of
			# the split.
			#
			# A DEAD END IS THE OTHER CASE and needs saying out loud, because the head of the
			# corridor is where `frontier` sends the bot: leave it standing there and it will be
			# sent back to the same stone every third of a second for the rest of the match. Spent
			# heads are struck off, so the next-best one is chosen and the crew's network grows a
			# branch instead of stopping.
			if _dead_end:
				# GO UNDER IT. Rock is a wall on ONE plane -- that is the whole of what makes it
				# interesting (GDD section 3: go round it, or go under it), and the layout is
				# different on every layer precisely so that going under works. A digger that
				# could only go round was stopped for good by the first seam it met in the
				# midfield, which on this arena is where every seam is; both crews' corridors
				# ended at the same stone and the bots paced in front of it.
				var below := _descend(bot, network, plane, here)
				if not below.is_empty():
					return below
				_spent[here] = true
				_rest = REST_SECONDS
			_intent = ""
			return {}

	# Still solid: stand at the face and work. The bot is held at its own position on purpose --
	# walking INTO an unopened cell is walking into a wall, and the animation of a mouse jogging
	# on the spot against earth is exactly what a dig should not look like.
	if not network.is_dug(plane, _target):
		_progress += delta / maxf(cell_seconds(bot, plane), 0.01)
		_intent = "cutting a corridor"
		if _progress < 1.0:
			return {"at": bot.global_position, "plane": plane}
		_progress = 0.0
		if not network.dig(plane, _target, bot.team):
			# It was legal when it was chosen and is not now -- another crew's cave-in, or a cell
			# somebody else opened first. Either way, re-choose.
			_refused[_target] = true
			_target = Vector2i.MAX
			return {"at": bot.global_position, "plane": plane}
		# Running into a seam teaches your crew where it goes (GDD section 3). A bot's crew learns
		# the same way a player's does -- otherwise per-crew rock knowledge would be a fact about
		# the human only, and the minimap would be telling the truth for one side of the match.
		for side: Vector2i in TunnelNetwork.SIDES:
			network.reveal_vein(plane, _target + side, bot.team)

	_intent = "cutting a corridor"
	return {"at": network.cell_to_world(plane, _target), "plane": plane}


## Stone ahead and stone to both sides: sink a shaft and carry on underneath it.
##
## The deeper plane has its own rock laid out differently, so the seam that stopped this corridor
## almost never stops the one below -- and if it does, this happens again one layer down. The
## Engineer arrives at the enemy nest two planes deep having gone under everything in the way,
## which is the shape of play the rock generation was designed to produce and which nothing in the
## game had yet done on purpose.
func _descend(bot: Mouse, network: TunnelNetwork, plane: int, here: Vector2i) -> Dictionary:
	if not network.can_shaft_down(plane, here):
		return {}
	if not network.dig_shaft_down(plane, here, bot.team):
		return {}
	if TunnelTransit.take(network, bot, plane) < 0:
		return {}
	reset()
	_intent = "going under it"
	return {"at": bot.global_position, "plane": bot.get_plane()}


## Close enough: break out into the daylight.
##
## Failing to find a way up is not a stall. It hands control back, and the bot walks out through
## whatever mouth the planner can find -- usually the one it came in by, which is a longer trip
## home and an honest consequence of having tunnelled under a patio.
func _surface(bot: Mouse, network: TunnelNetwork, plane: int, here: Vector2i) -> Dictionary:
	if not network.can_shaft_up(plane, here):
		_intent = ""
		return {}
	network.dig_shaft_up(plane, here, bot.team)
	if TunnelTransit.take(network, bot, plane) < 0:
		_intent = ""
		return {}
	reset()
	_intent = "up and out"
	return {"at": bot.global_position, "plane": bot.get_plane()}


# -------------------------------------------------------------------------------- choosing


## The next cell to OPEN, heading for `toward`, or MAX for "nothing to cut from here".
##
## THIS ONLY EVER RETURNS SOLID EARTH, and that is the correction that made the whole behaviour
## work. It used to return open cells too, on the reasonable-sounding grounds that walking down a
## corridor somebody already cut beats cutting a parallel one beside it. True, and not this
## function's business: walking a corridor is PATHFINDING, which route_planner.gd does properly
## over the same graph the player's routes use. Doing it here meant a greedy one-cell stepper with
## a compass was navigating, and a greedy stepper in a corridor with a bend in it walks into the
## wall, backtracks, and oscillates -- which is exactly what two Engineers spent a soak doing.
##
## So the two jobs are split at the obvious seam. **Walk with the planner; dig at a face.** If the
## way ahead is already open there is nothing for a digger to do, and saying so -- returning MAX --
## hands the bot back to the navigation that can actually get it to the frontier.
##
## THE LONGER AXIS FIRST, with the cross axis as the fallback, which is a staircase rather than a
## diagonal -- and a staircase is what the grid can cut. Leaning on a seam until it slides past is
## the whole of this bot's route-finding around rock, and it produces a corridor with a kink in it
## that reads exactly like somebody dug until they hit something.
func _choose(network: TunnelNetwork, plane: int, here: Vector2i, toward: Vector2i) -> Vector2i:
	_dead_end = false
	var delta := toward - here
	if delta == Vector2i.ZERO:
		return Vector2i.MAX

	var along := Vector2i(signi(delta.x), 0)
	var across := Vector2i(0, signi(delta.y))
	if absi(delta.y) > absi(delta.x):
		var swap := along
		along = across
		across = swap

	# The way ahead is already a corridor: walk it, do not cut beside it. Blocked is different --
	# a barricade sits in an OPEN cell, so digging cannot help and going round is the only answer,
	# which is the point of one.
	if along != Vector2i.ZERO and network.is_dug(plane, here + along):
		if not network.is_blocked(plane, here + along):
			return Vector2i.MAX
		return _aside(network, plane, here, across)
	if along != Vector2i.ZERO and _face(network, plane, here + along):
		return here + along
	return _aside(network, plane, here, across)


## The way round, when the way through is stone. Cross axis first in the direction of the goal,
## then the other way, and neither if both are stone as well -- at which point this plane has
## nothing to offer and `_underground` rests.
func _aside(network: TunnelNetwork, plane: int, here: Vector2i, across: Vector2i) -> Vector2i:
	for step: Vector2i in [across, -across]:
		if step == Vector2i.ZERO:
			continue
		if _face(network, plane, here + step):
			return here + step
	_dead_end = true
	return Vector2i.MAX


## Is this cell solid earth this bot may open?
func _face(network: TunnelNetwork, plane: int, cell: Vector2i) -> bool:
	return not _refused.has(cell) and cell != _previous and network.can_dig(plane, cell)


func _flat(from: Vector3, to: Vector3) -> float:
	return Vector2(to.x - from.x, to.z - from.z).length()
