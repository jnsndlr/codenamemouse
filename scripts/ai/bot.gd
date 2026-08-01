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
## What this bot is for. Assigned by the director when it spawns, alternating down the crew, so
## every crew has someone at home and someone on the way over.
@export_enum("Raider", "Defender") var role: int = RAIDER
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


func _ready() -> void:
	super()
	_agent.path_desired_distance = waypoint_slack
	_agent.target_desired_distance = arrival_slack
	_goal = global_position


func get_intent() -> String:
	return _intent


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
		_decide()
		_plan()

	_fight(delta)
	_walk(delta)


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

	# 6. Otherwise: go and take theirs.
	_intent = "going for their banner"
	_goal = theirs.global_position


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


func _nearest_enemy_within(of: Vector3, reach: float) -> Mouse:
	var best: Mouse = null
	var closest := reach
	for node in get_tree().get_nodes_in_group(MOUSE_GROUP):
		var other := node as Mouse
		if other == null or other.team == team or other.is_scruffed():
			continue
		var gap := of.distance_to(other.global_position)
		if gap <= closest:
			closest = gap
			best = other
	return best


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
func _heading() -> Vector3:
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
