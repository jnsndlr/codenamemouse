class_name Bot
extends Mouse
## A mouse driven by a navmesh and five rules.
##
## Solo play is the same match with AI in every other seat (GDD section 1), so a bot is not a
## training dummy -- it is the other side of the loop M3 exists to evaluate. If a bot never
## comes to take the banner back, the flag run isn't tense and the milestone can't answer its
## own question.
##
## PRIORITIES, NOT A STATE GRAPH. Every `think_seconds` it asks one question -- what is the
## most urgent thing on the field? -- and answers with a destination. Ranked ifs beat a
## transition table here because the ranking IS the design: the banner outranks the fight,
## defence outranks offence, and reading the list tells you what the bot values. A graph with
## the same behaviour would spread that over nine edges.
##
## It re-decides on a timer rather than every frame, and that is deliberate. Re-picking a goal
## sixty times a second makes a bot standing between two equally good options vibrate, and the
## interval doubles as a plain reaction time -- it takes a beat to notice you.
##
## IT GOES UNDERGROUND (M4). Two navigation systems, joined at the mouths: a navmesh on the lawn
## and an AStar3D graph over the dug cells (tunnel_graph.gd), stitched into one list of waypoints
## by route_planner.gd. Everything below the `_decide` ranking is unchanged by it -- the bot
## still picks a destination and walks at it. What changed is that "walk at it" may now mean
## climbing down a hole.
##
## THE RANKING NEVER MENTIONS TUNNELS, and that is the point. A bot does not decide to go
## underground; it decides to chase the mouse holding its banner, and the route to that mouse
## happens to run through a shaft. Until M4 the same decision produced a bot standing on the lawn
## above them, which is what made digging an exploit rather than a choice -- not because the AI
## was too stupid to follow, but because it structurally could not.

enum { RAIDER, DEFENDER }

@export_group("Role")
## What this bot is for. Assigned by the director from its seat, so every crew has someone at
## home and someone on the way over -- see MatchDirector.SEATS.
@export_enum("Raider", "Defender") var role: int = RAIDER
## What this bot turns up as. Also from the seat, and it is a WANT rather than a costume: the bot
## puts it on at its own nest, through the same rule the player's C key obeys (class_swap.gd).
##
## THE SWAP IS NOT DECORATION. A bot that was simply born the right class would never exercise the
## thing the swap point is for, and the swap point is the answer GDD section 4 gives to every
## composition problem in the game -- adaptation costs the walk home and nothing else. A crew
## whose Engineer is scruffed on the far side of the yard gets it back by walking, exactly as a
## human would, and the rule gets used in every match instead of on the evenings somebody
## remembers to press C.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var preferred_class: int = MouseClass.GENERALIST
## How far from its own nest a defender will go. Measured from the NEST, not from the bot, so a
## defender that chases someone to the edge of its patch turns round rather than being walked
## away from the thing it is guarding. This is the whole anti-lure rule and it is one word:
## `nest`.
@export var defend_radius: float = 9.0

@export_group("Thinking")
## Seconds between decisions. Doubles as reaction time.
@export var think_seconds: float = 0.3
## How close an enemy has to be before this bot squares up to them -- turns to face, and swings
## if they come inside `strike_radius`. It does NOT change where the bot is going.
##
## THAT SEPARATION IS THE WHOLE FIX. The first version made "an enemy is near" a destination,
## and four bots spent an entire ninety-second soak brawling in the middle of the yard: nobody
## ever reached a banner, and the milestone's question -- is the flag run tense? -- could not be
## asked because there were no flag runs. A raider now swings at whatever it brushes past and
## keeps walking.
@export var engage_radius: float = 4.5
## How close it gets before swinging. Inside its own reach, so it doesn't flail at the air.
@export var strike_radius: float = 0.75
## How far off perfect the facing may be and still swing, in degrees. Well inside the swing arc
## so a bot doesn't clip you with the very edge of a cone it never aimed.
@export var strike_arc: float = 40.0

@export_group("Scurry")
## How close a pursuer has to be before a carrying bot spends a life on getting away.
##
## THE POINT OF THE GATE IS THAT A BURST IS FOR A CHASE, NOT FOR A COMMUTE. A bot that scurried the
## instant it picked the banner up would arrive home fractionally sooner having spent one of its
## crew's lives on an empty lawn, and the counter would drop for no reason anybody watching could
## see -- which is the opposite of what GDD section 2 wants the spend to feel like.
@export var scurry_pursuit: float = 7.0
## How far away a thief can be and still be worth burning a life to catch. Beyond this the burst
## runs out long before the gap does, and the cheese bought two seconds of jogging.
@export var scurry_chase: float = 18.0

@export_group("Navigation")
## How near a waypoint counts as reached.
@export var waypoint_slack: float = 0.35
## How near the destination counts as arrived.
@export var arrival_slack: float = 0.5
## What a tunnel route has to beat the surface by before a bot bothers, as a multiplier on its
## cost. 1.0 is "take whichever is genuinely shorter".
##
## This only ever applies when BOTH ends are on the lawn -- following someone down is not a
## preference, it is the only way to get there. On the current arena, eighty metres of open dirt,
## almost nothing underground wins this comparison, and that is the honest answer rather than a
## disabled feature: tunnels pay off on a map with things in the way, which is a map problem
## (GDD section 8) and belongs to whichever milestone first lays out a real yard.
@export var tunnel_bias: float = 1.0

@onready var _agent: NavigationAgent3D = $Agent

var _director: MatchDirector
## Found lazily, like the director. Optional: a map without one still plays, it just has no
## concealment for the bots to respect.
var _spotting: Spotting
var _network: TunnelNetwork
var _goal: Vector3 = Vector3.ZERO
## Which plane the destination is on. Almost always 0 -- the banners and the nests are on the
## surface by rule -- so this is really "is the mouse I am chasing underground".
var _goal_plane: int = 0
## Waypoints from route_planner.gd, or empty for "walk over the grass". A change of plane between
## consecutive waypoints is a shaft, and the one before it is the mouth to stand on.
var _route: Array[Dictionary] = []
var _quarry: Mouse = null
var _since_think: float = 999.0
## Purely for the debug readout -- what it thinks it's doing.
var _intent: String = "idle"
## The Engineer's raid. Held by every bot and consulted by none of them but an Engineer, which is
## cheaper than creating one on a class swap and means the state is always there to be reset.
var _digger := BotDigger.new()
## True while `_digger` is steering. Movement is different then: the digger says exactly which
## cell to stand in and decides for itself when it has got there, so the arrival slack that keeps
## a bot from jittering on the lawn would leave it stalled half a tile short of a face.
var _driven: bool = false
## Whether `_decide` fell all the way through to rule 6. The one errand a dig may replace.
var _raiding: bool = false
## WHERE THE RANKING WANTS TO GO, kept apart from `_goal`, which is where the feet are pointed
## this frame. Almost always the same thing -- and catastrophically not while the digger is
## driving, because the digger STEERS by writing `_goal` (stand at this face, walk to that cell)
## and would then read its own last instruction back as the destination it was heading for. It
## did exactly that: half a metre from a target it had set itself, it concluded it had arrived at
## the enemy banner, tried to surface in the middle of its own corridor, was refused, and handed
## control back -- every other frame. The corridor advanced one cell every seven seconds instead
## of every half second, and each time the refusal didn't come it punched a useless mouth in the
## lawn. Same separation `_quarry` already has from `_goal`, and for the same reason.
var _errand: Vector3 = Vector3.ZERO


func _ready() -> void:
	super()
	_agent.path_desired_distance = waypoint_slack
	_agent.target_desired_distance = arrival_slack
	_goal = global_position


func get_intent() -> String:
	var digging := _digger.get_intent()
	return digging if _driven and not digging.is_empty() else _intent


func _control(delta: float) -> void:
	if _director == null:
		_director = get_tree().get_first_node_in_group(MatchDirector.DIRECTOR_GROUP) as MatchDirector
		if _director == null:
			return

	if _network == null:
		_network = get_tree().get_first_node_in_group(TunnelNetwork.NETWORK_GROUP) as TunnelNetwork

	_since_think += delta
	if _since_think >= think_seconds:
		_since_think = 0.0
		_reclass()
		_decide()
		_consider_scurry()
		# Taken here, once, straight off the ranking -- before anything downstream is allowed to
		# point the feet somewhere else for a frame.
		_errand = _goal
		_goal_plane = _head_for_the_face()
		_plan()

	# EVERY FRAME, unlike the decision above it, because a dig is a CLOCK. Opening a tile takes
	# half a second of held effort and a behaviour sampled three times a second would charge it
	# in lumps -- the same reason dig_controller.gd runs on the physics tick and not on input.
	_drive(delta)
	_fight(delta)
	_walk(delta)


# ------------------------------------------------------------------------------- the class


## Put on the class this seat is for, if this is a place a class may be changed.
##
## THE RULE IS BORROWED, NOT REBUILT. `ClassSwap.allowed` is the same predicate the player's C key
## is gated on -- own nest, on the surface, on your feet -- so a bot cannot re-spec somewhere a
## human could not. Almost every swap therefore happens on respawn, which is precisely where GDD
## section 4 says a free switch belongs, and it costs the bot the same walk home it costs you.
func _reclass() -> void:
	var wanted := _wanted_class()
	if mouse_class == wanted or not ClassSwap.allowed(self, _director):
		return
	set_class(wanted)
	# Whatever it was in the middle of belonged to the mouse it used to be. A Generalist does not
	# inherit an Engineer's half-cut corridor.
	_digger.reset()
	_driven = false


## What this bot would rather be: its seat, and nothing cleverer.
##
## THERE WAS A COVER RULE HERE AND IT WAS WRONG. It said a bot would take the Engineer seat when
## its crew had none standing, on the theory that a digger is a capability rather than a
## preference. The theory is fine; the behaviour was not. Engineers are scruffed constantly, and
## "standing" flips several times a minute, so every mouse that happened to be home flipped to
## Engineer, cut a stub, flipped back when the real one respawned, and cut nothing further. It
## made the crew's composition jitter and it made the yard worse -- which is the argument against
## it, not the theory.
##
## If a crew genuinely needs cover for a dead specialist, that belongs to a rule about the MATCH
## and not to whoever is standing nearest a nest at the time.
func _wanted_class() -> int:
	return preferred_class


# --------------------------------------------------------------------------------- deciding


## The ranking. Read top to bottom, it is this bot's entire personality.
##
## Two decisions, kept apart: WHERE IT IS GOING and WHO IT IS SQUARING UP TO. Only the first
## four rules can move a bot, and none of them is "an enemy is nearby".
func _decide() -> void:
	var ours := _director.banner_of(team)
	var theirs := _director.banner_of(Team.other(team))
	_quarry = _pick_quarry()
	# The default, overwritten only by the two rules that can point at a mouse. Everything else a
	# bot wants is a banner or a nest, and neither can be underground -- one by rule (GDD
	# section 2), the other by being a place in the yard.
	_goal_plane = 0
	# Cleared here and set by exactly one rule below, so "may I dig?" is answered by where the
	# ranking landed rather than by a second opinion about the state of the match.
	_raiding = false

	# 1. Carrying it home is everything. Nothing outranks a capture in progress -- a bot that
	#    stops mid-run to trade blows is how a steal turns into nothing.
	if is_carrying():
		_intent = "running it home"
		_goal = _director.nest_of(team).global_position
		return

	# 2. Our banner is out there in the open. Touching it sends it home instantly, which is the
	#    cheapest thing anyone on this crew can do for the score.
	if ours.state == Banner.DROPPED:
		_intent = "recovering our banner"
		_goal = ours.global_position
		return

	# 3. Somebody is running off with it, and EVERYONE goes -- raider and defender alike. Not
	#    loyalty: while our banner is away this crew cannot score at all (GDD section 2), so
	#    there is nothing else worth doing. Chase the carrier rather than the banner, so a
	#    handoff doesn't shake the pursuit.
	var thief := _director.carrier_of(team)
	if thief != null and not thief.is_scruffed():
		_intent = "chasing the carrier"
		_goal = thief.global_position
		# A carrier cannot be underground -- both gates see to that -- so this is 0 today. Read
		# off the mouse anyway rather than assumed, because the day something drags a carrier
		# through a shaft, a bot that assumed will chase a hole in the lawn.
		_goal_plane = thief.get_plane()
		return

	# 4. A defender's whole job: meet anyone who comes into the yard, and go back home when they
	#    don't. Measured from the nest, so it cannot be walked away from its post.
	if role == DEFENDER:
		var nest := _director.nest_of(team)
		var intruder := _nearest_enemy_within(nest.global_position, defend_radius)
		if intruder != null:
			_intent = "defending"
			_goal = intruder.global_position
			# THE ONE THAT MATTERS. Someone crossing your patch three planes down is still
			# crossing your patch, and until M4 a defender watched them do it from the lawn.
			# Measured from the nest in plan view, so a tunnel does not buy an intruder distance
			# it did not walk.
			_goal_plane = intruder.get_plane()
			return
		_intent = "holding the nest"
		_goal = _post(nest)
		return

	# 5. An ally has their banner -- escort them home rather than running a second raid into a
	#    nest that no longer has anything to steal.
	if theirs.state == Banner.CARRIED and theirs.carrier != null and theirs.carrier.team == team:
		_intent = "escorting"
		_goal = theirs.carrier.global_position
		return

	# 6. Otherwise: go and take theirs. THE ONLY ERRAND AN ENGINEER MAY DIG, because it is the only
	#    one that is not urgent -- everything above this is a banner in play, and a tunnel is a
	#    twenty-second investment nobody makes while the match is being decided above their head.
	_intent = "going for their banner"
	_goal = theirs.global_position
	_raiding = true


## Spend a life, or don't. The economy half of the ranking above.
##
## THIS WAS MISSING UNTIL M7 AND IT WAS A REAL GAP, not a polish item. A crew whose AI seats never
## spend cheese is a crew playing a different economy from the crew across the yard: it ends every
## match with full stores and never once trades a life for a metre. That was tolerable at M6, where
## the question was whether a *human* agonises over a spend. It stops being tolerable the moment
## the other side is a second human, because then the two crews are being scored against each other
## and only one of them is playing the game.
##
## ASKED OF THE DIRECTOR, exactly as a player's key press is. The pool is the crew's, the ledger is
## the director's, and a bot that could boost itself would be a bot that could spend its team's
## lives without the thing holding the ledger hearing about it. Same call, same refusals, same
## line in the feed -- there is no AI-flavoured Scurry.
##
## TWO MOMENTS, AND THEY ARE THE TWO THE RANKING ALREADY CARES ABOUT: getting away with their
## banner, and catching whoever has yours. Both are "a distance that has to close or open right
## now", which is what the burst is for.
##
## THERE IS DELIBERATELY NO "HURT, BREAK OFF" RULE, which is the obvious third one and would be
## wrong here. Nothing in the ranking retreats -- a hurt bot's destination is still the mouse
## hitting it -- so a burst bought to escape would be spent closing the last metre on the thing
## that is killing it. That rule belongs with a flee behaviour or not at all.
func _consider_scurry() -> void:
	if not scurry_ready():
		return

	if is_carrying():
		if _nearest_enemy_within(global_position, scurry_pursuit) != null:
			_director.try_scurry(self)
		return

	var thief := _director.carrier_of(team)
	if thief == null or thief.is_scruffed():
		return
	var gap := global_position.distance_to(thief.global_position)
	# Already on top of them: a burst adds nothing a swing would not, and the cooldown means it is
	# not there for the next thief.
	if gap > strike_radius * 2.0 and gap < scurry_chase:
		_director.try_scurry(self)


## Where a defender stands when nothing is happening: a step out of the nest, toward the middle
## of the arena. On the banner itself it would be in the way of its own crew returning it.
func _post(nest: Nest) -> Vector3:
	var toward := -nest.global_position
	toward.y = 0.0
	if toward.length_squared() < 0.01:
		return nest.global_position
	return nest.global_position + toward.normalized() * 2.2


## Who this bot is squaring up to: the nearest enemy close enough to be worth facing. Never a
## destination -- see `engage_radius`.
func _pick_quarry() -> Mouse:
	var near := _nearest_enemy()
	if near == null:
		return null
	if global_position.distance_to(near.global_position) > engage_radius:
		return null
	return near


## The nearest enemy this bot has actually SEEN within `reach` of a spot.
##
## The concealment gate belongs here and not in `_nearest_enemy`, because this is the one that
## produces a DESTINATION -- a defender reading this sets `_goal` to whatever it returns. Walking
## at a mouse crouched in deep grass is the precise failure GDD section 8 is meant to prevent:
## the human does everything the mechanic asks, goes still, watches the blades settle, and the
## defender strolls over anyway. Whatever the grass hides, it has to hide from both crews or it
## is scenery.
##
## A carrier is never hidden -- grass_camouflage.gd pins them at full opacity -- so the rule that
## sends a bot after its stolen banner needs no exception here and does not get one.
func _nearest_enemy_within(of: Vector3, reach: float) -> Mouse:
	var best: Mouse = null
	var closest := reach
	for node in get_tree().get_nodes_in_group(MOUSE_GROUP):
		var other := node as Mouse
		if other == null or other.team == team or other.is_scruffed():
			continue
		if _hidden_from_me(other):
			continue
		var gap := of.distance_to(other.global_position)
		if gap <= closest:
			closest = gap
			best = other
	return best


## Too well concealed for this bot to be steering at, on the same 0..1 scale the minimap uses.
##
## Asked of spotting.gd rather than answered here, so there is exactly one threshold in the game
## for "I have not resolved that shape". A second copy would drift, and the day it drifted the
## grass would conceal you from the map and not from the bots -- which is worse than not
## concealing you at all, because it would still LOOK like it was working.
##
## Fails open. No spotting node means no concealment model at all, and a defender that ignores
## every intruder is a far louder bug than one that sees too well.
func _hidden_from_me(other: Mouse) -> bool:
	if _spotting == null:
		_spotting = get_tree().get_first_node_in_group(Spotting.SPOTTING_GROUP) as Spotting
	return _spotting != null and _spotting.hidden(other)


## Nearest enemy still standing. A scruffed mouse is not a threat and chasing one is the
## classic bot bug where it stands over a body until the respawn.
func _nearest_enemy() -> Mouse:
	var best: Mouse = null
	var closest := INF
	for node in get_tree().get_nodes_in_group(MOUSE_GROUP):
		var other := node as Mouse
		if other == null or other == self or other.team == team or other.is_scruffed():
			continue
		if other.get_plane() != get_plane():
			continue
		var gap := global_position.distance_to(other.global_position)
		if gap < closest:
			closest = gap
			best = other
	return best


# ---------------------------------------------------------------------------------- acting


## Face the quarry and swing when it's actually in front. Facing is decided here rather than in
## `_walk` so a bot backing off from someone keeps its nose on them, which is the same thing
## the cursor does for a player.
func _fight(delta: float) -> void:
	if _quarry == null or not is_instance_valid(_quarry) or _quarry.is_scruffed():
		return
	var toward := _quarry.global_position - global_position
	toward.y = 0.0
	if toward.length_squared() < 0.0001:
		return

	_face_toward(toward, delta)
	if toward.length() > strike_radius:
		return
	if get_facing_direction().angle_to(toward.normalized()) > deg_to_rad(strike_arc):
		return
	swing()


## An Engineer on a raid walks to the head of its own corridor, not to the banner.
##
## Returns the plane the walk ends on, and leaves `_goal` pointing at the frontier if there is one.
## `_errand` still holds the banner, so the digging knows which way to cut once it gets there.
##
## THE POINT IS THAT THE WALK IS ROUTED. Getting to the far end of your own tunnel means following
## a corridor with bends in it, which is what route_planner.gd is for and what a one-cell greedy
## stepper is emphatically not -- the stepper walks into the outside of the first corner, backs up,
## and oscillates. Splitting it here means the digger never has to navigate: it is only ever asked
## what to do when the bot is already standing at solid earth.
func _head_for_the_face() -> int:
	if not _raiding or mouse_class != MouseClass.ENGINEER or _network == null:
		return _goal_plane
	# Given up on that corridor for the moment: go and be a mouse instead of walking back to the
	# seam that just refused it.
	if _digger.is_resting():
		return _goal_plane
	var face := _digger.frontier(self, _network, _goal)
	if face.is_empty():
		return _goal_plane
	_goal = face["at"]
	return int(face["plane"])


## Hand the frame to the Engineer's raid, if this bot is one and this is its errand.
##
## The digger returns where to stand and on which plane, or nothing at all -- and nothing at all is
## the normal answer, including for an Engineer. It declines on the lawn until the walk is long
## enough to be worth a hole, and it declines underground the moment it is boxed in. Both times
## control falls back to the ranking and to route_planner.gd, which can walk a bot out of a tunnel
## through the mouth it came in by, so there is no abandonment path to write.
func _drive(delta: float) -> void:
	var was := _driven
	_driven = false
	if _network != null and _raiding and mouse_class == MouseClass.ENGINEER:
		var order := _digger.think(
			self, _network, _director.nest_of(team).global_position, _errand, delta
		)
		if not order.is_empty():
			_goal = order["at"]
			_goal_plane = int(order["plane"])
			# The digger's corridor IS the route. A plan made a moment ago describes a network
			# that did not have the last cell in it.
			_route.clear()
			_driven = true

	# Handed back mid-corridor: re-plan now rather than at the next think, because until there is
	# a route the fallback is to walk straight at a goal that may be through a wall.
	if was and not _driven:
		_plan()


## Work out the way there, and hand the walking below a single point to head for.
##
## Re-planned every decision rather than kept until it fails. A route is cheap, the destination
## is usually a mouse that is moving, and a plan held onto is a bot walking confidently to where
## somebody used to be. It also means a tunnel dug across a bot's route is noticed within a third
## of a second, with no invalidation machinery at all.
func _plan() -> void:
	_route = RoutePlanner.plan(
		_network, global_position, get_plane(), _goal, _goal_plane, tunnel_bias
	)
	_aim()


## Point the navigation agent at whatever the current leg ends with. Only meaningful on the
## surface: underground there is no navmesh, and the graph has already done the routing.
func _aim() -> void:
	if get_plane() != 0:
		return
	var aim := _goal
	if not _route.is_empty():
		aim = _route[0]["at"]
	_agent.target_position = aim


func _walk(delta: float) -> void:
	var heading := _heading()
	if heading.is_zero_approx():
		return

	_wish = heading
	# Only steer with the feet when there's nobody to look at -- otherwise the fight owns the
	# facing and this would drag its nose back onto the path mid-scrap.
	if _quarry == null:
		_face_toward(heading, delta)


## Which way to push this frame, or zero for "stay put".
##
## NO ARRIVAL SLACK WHILE DIGGING. The slack exists so a bot that has reached a waypoint stops
## rather than shuffling on the spot, and it is half a metre -- half a cell. The digger works in
## whole cells and decides for itself when it is standing in one, so borrowing the slack here
## would park it on the boundary between the cell it is in and the face it is cutting, which
## reads as a mouse that has forgotten what it was doing. Standing still is expressed the honest
## way instead: the digger returns the bot's own position, and the heading comes out zero.
func _heading() -> Vector3:
	if _driven:
		var to_cell := _goal - global_position
		to_cell.y = 0.0
		if to_cell.length() < 0.02:
			return Vector3.ZERO
		return to_cell.normalized()

	var aim := _goal
	var reach := arrival_slack
	if not _route.is_empty():
		aim = _route[0]["at"]
		reach = waypoint_slack
	if _flat_gap(aim) <= reach:
		if not _route.is_empty():
			_advance()
		return Vector3.ZERO

	var step := _next_step(aim)
	var toward := step - global_position
	toward.y = 0.0
	if toward.length_squared() < 0.0001:
		return Vector3.ZERO
	return toward.normalized()


## Arrived at a waypoint: drop it, and if the next one is on another plane, take the shaft that
## must be under our feet.
##
## Failing to find that shaft clears the whole route rather than limping on. It means the plan
## and the world have disagreed -- knocked off the mouth mid-transit, or the cell was never quite
## reached -- and the next decision is a third of a second away. A bot that keeps walking a route
## it has fallen off is the one that ends up jogging on the spot against a wall.
func _advance() -> void:
	_route.pop_front()
	if _route.is_empty():
		return

	if int(_route[0]["plane"]) != get_plane():
		if TunnelTransit.take(_network, self, get_plane(), 0.05) < 0:
			_route.clear()
			return
		# Standing where that waypoint was, now: it was the far end of the shaft.
		_route.pop_front()
	_aim()


## Distance to a point, ignoring height. Two waypoints on different planes are two thirds of a
## metre apart vertically, which is enough for a straight distance check to never call the one
## under your feet "reached".
func _flat_gap(to: Vector3) -> float:
	return Vector2(to.x - global_position.x, to.z - global_position.z).length()


## The next point on the way to `aim`.
##
## Underground, `aim` is the adjacent cell the graph picked and there is nothing to add -- head
## straight at it. On the surface the navmesh knows about the props and the walls, so the agent
## gets the last word.
##
## The fallback matters more than it looks. If the navmesh failed to bake, an agent returns its
## own position forever and every bot stands still looking broken -- which is indistinguishable
## from the AI being wrong. Walking straight at the goal is visibly dumb around a wall, but it
## is visibly ALIVE, and tools/match_audit.gd asserts a real path exists between the nests so
## the failure is caught somewhere it can be read.
func _next_step(aim: Vector3) -> Vector3:
	if get_plane() != 0:
		return Vector3(aim.x, global_position.y, aim.z)
	if _agent.get_navigation_map().is_valid() and not _agent.is_navigation_finished():
		var step := _agent.get_next_path_position()
		if step.distance_to(global_position) > 0.01:
			return Vector3(step.x, global_position.y, step.z)
	return Vector3(aim.x, global_position.y, aim.z)
