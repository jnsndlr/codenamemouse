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
##
## IT ONLY KNOWS WHAT ITS CREW HAS SEEN (M8). Every rule below that names an enemy reads
## spotting.gd's contact book rather than the scene tree -- the same book the minimap draws from,
## with the same range, the same line of sight, the same opacity threshold and the same fifteen
## seconds of memory. What a bot does is therefore legible from your own HUD: the marker you can
## see is the marker it is acting on.
##
## THE BOOK IS ALLOWED TO BE WRONG, and that is what makes it worth reading. A contact freezes
## where it was last seen and fades from there, so a defender that loses you in the grass walks to
## where you WERE and arrives at nothing. Nobody had to write a search behaviour; it is what
## reading a stale book looks like from the outside.

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
## How near a shaft mouth a contact has to have been lost for a defender to conclude they climbed
## into it. A little over one cell, because the sweep runs four times a second and a mouse can be
## most of a stride from the hole in the frame it was last resolved.
##
## Tight ON PURPOSE. It is the difference between "I watched them drop into that hole" and "they
## disappeared somewhere over there and there happens to be a tunnel nearby", and only the first
## is knowledge. See `_went_to_ground`.
@export var mouth_slack: float = 1.2

@export_group("Thinking")
## Seconds between decisions. Doubles as reaction time.
@export var think_seconds: float = 0.3
## How long a bot may ask for a heading and not travel before it decides it is stuck. Comfortably
## longer than a think, so an ordinary re-plan or a moment spent squeezing past somebody is not
## mistaken for a wedge -- and short enough that a player never watches a teammate stand in a
## corridor wondering what it is doing.
@export var stuck_seconds: float = 1.0
## How far it must have got in that window to count as moving. A tenth of a body width: a bot
## grinding along a wall does travel, slowly, and that is not stuck.
@export var stuck_distance: float = 0.15
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

@export_group("Cheese")
## How low the crew's pile has to get before a raider goes shopping instead of raiding.
##
## LOW ON PURPOSE. Cheese is the crew's lives, not a second score (GDD section 2), so fetching it
## is what you do when you are running out -- not a steady errand somebody is always on. Set this
## near the starting twenty and a crew spends the whole match hauling wedges and never contests a
## banner, which is a worse game than the one where they never fetch any.
@export var forage_below: int = 6
## And how much it wants before it stops. Above `forage_below` by enough to be worth the trip --
## see `_foraging`, where the gap between these two numbers is the whole point.
@export var forage_until: int = 12
## How far a bot will walk for a pile. Beyond this the trip costs more than the wedge is worth and
## the crew would be better off defending what it has.
@export var forage_range: float = 30.0

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
## cost. 1.0 is "take whichever is genuinely shorter"; below 1.0 buys a tunnel some slack.
##
## This only ever applies when BOTH ends are on the lawn -- following someone down is not a
## preference, it is the only way to get there.
##
## `[REVISED at M8]` 0.7, which is "worth a route up to about forty per cent longer". It sat at 1.0
## and the note here used to argue that almost nothing underground wins a straight comparison on
## eighty metres of open dirt, and that this was the honest answer rather than a disabled feature.
## Half of that was right and the conclusion was wrong: a pure shortest-path comparison cannot
## express the reason to use a tunnel at all. **Underground is cover.** Arriving unseen is worth
## walking further for, and a planner that only ever prices distance will decline every tunnel on
## every map until the surface route is physically longer, which is a very high bar.
##
## THE NUMBER IS BORROWED RATHER THAN INVENTED. bot_digger.gd's `REUSE_SLACK` is 1.35 and makes
## exactly this argument in exactly these words for exactly this trade -- how much further a bot
## will walk to arrive through a hole. The digger and the walker had been disagreeing about it,
## which is the sort of split that shows up as a bot walking to a mouth and then deciding not to
## use it.
@export var tunnel_bias: float = 0.7

@onready var _agent: NavigationAgent3D = $Agent

var _director: MatchDirector
## Found lazily, like the director. THIS BOT'S ENTIRE SENSORY APPARATUS since M8 -- every rule that
## names an enemy goes through it. Optional: a map without one still plays, and `_unaided_within`
## says what a bot sees then.
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
## Progress bookkeeping for [method _check_progress]: when the current window opened, and where.
var _stuck_for: float = 0.0
var _stuck_at: Vector3 = Vector3.ZERO
var _stuck_strikes: int = 0
## Purely for the debug readout -- what it thinks it's doing.
var _intent: String = "idle"
## The Engineer's raid. Held by every bot and consulted by none of them but an Engineer, which is
## cheaper than creating one on a class swap and means the state is always there to be reset.
var _digger := BotDigger.new()
## True while `_digger` is steering. Movement is different then: the digger says exactly which
## cell to stand in and decides for itself when it has got there, so the arrival slack that keeps
## a bot from jittering on the lawn would leave it stalled half a tile short of a face.
var _driven: bool = false
## Whether `_decide` fell all the way through to the raid. The one errand a dig may replace.
var _raiding: bool = false
## Whether this bot is currently on a refill run. Latched rather than recomputed, which is what
## keeps the crew from oscillating across the threshold -- see `_foraging`.
var _stocking: bool = false
## Contacts this bot has personally walked to and found nothing at. Keyed by mouse; a key is struck
## out the moment that mouse is seen again.
##
## WITHOUT THIS A DEFENDER FREEZES ON A GHOST, and bot_soak.gd caught it doing so within one run of
## the contact book landing: two defenders stood still for fifteen seconds each, 'checking a
## contact'. A stale contact keeps its last-seen position for the whole of `memory_seconds`, so a
## bot that walks there, finds nobody, and reads the same book again is handed the destination it is
## already standing on -- `_heading` measures a gap inside `arrival_slack` and returns nothing. It
## is the investigation behaviour working perfectly, right up to the point where it should have
## ended and did not.
##
## BY IDENTITY, NOT BY DISTANCE, which is the part worth getting right. "Have I already checked
## somewhere near here" answered from position is true while the bot stands on the spot and false
## again the moment it walks back to its post -- so the bot turns round and comes back, forever.
## That is an oscillation wearing a fix. What a mouse actually knows is *I looked for THEM and they
## were not there*, and that is about who, not where.
var _cleared: Dictionary = {}
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
		_consider_pace()
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
	_check_progress(delta)


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

	# 4. Holding a wedge: put it in the pile. A wedge in the paws is worth nothing at all until it
	#    is banked (GDD section 2, and match_director.gd's `_check_cheese` is where the walk gets
	#    paid), so a mouse that picks one up and then wanders off has taken cheese OUT of the
	#    economy -- it is off the map, uncounted, and it drops on the floor the moment they are
	#    scruffed.
	#
	#    ABOVE EVERYTHING EXCEPT THE BANNER, and below all three banner rules, which is the whole
	#    of the argument for where it sits. It is one short walk to convert, so making it wait
	#    behind a raid means it never converts; but a crew that is losing its flag right now does
	#    not stop to do the shopping.
	if get_carried_cheese() > 0:
		_intent = "banking a wedge"
		_goal = _director.nest_of(team).stores_point()
		return

	# 5. A defender's whole job: meet anyone who comes into the yard, and go back home when they
	#    don't. Measured from the nest, so it cannot be walked away from its post.
	if role == DEFENDER:
		var nest := _director.nest_of(team)
		var intruder := _seen_within(nest.global_position, defend_radius, false)
		if not intruder.is_empty():
			# STALE CONTACTS ARE ALLOWED HERE, unlike in `_pick_quarry`, and the three intents say
			# which is which out loud. Walking to where somebody was last seen is a perfectly
			# sensible thing to do about a shape that went into the grass thirty metres from your
			# nest -- it is what a person does -- and it is the only way losing a defender by
			# breaking line of sight can feel like something you achieved rather than a bot bug.
			var live := bool(intruder["live"])
			# WHERE THE CREW LAST SAW THEM, not where they are. Reading the mouse's live position
			# here would quietly undo the whole of the change above it: the bot would arrive at a
			# stale marker's coordinates by way of a perfect pursuit curve.
			#
			# THE ONE THAT MATTERS about the plane. Someone crossing your patch three planes down is
			# still crossing your patch, and until M4 a defender watched them do it from the lawn.
			var at: Vector3 = intruder["at"]
			var plane := int(intruder["plane"])
			var label := "defending"

			if not live:
				label = "checking a contact"
				# LOST ON A SHAFT MOUTH MEANS THEY WENT DOWN IT. Resolved BEFORE the arrival test
				# below, and getting that order wrong broke `bots_follow` in exactly the way the
				# check exists to catch: a defender that reached the hole had, by the arrival test's
				# reckoning, checked the spot and found nothing -- so it struck the contact off and
				# went home, standing on the entrance its quarry had just climbed into.
				if plane == 0:
					var below := _went_to_ground(at)
					if not below.is_empty():
						label = "following them down"
						at = below["at"]
						plane = int(below["plane"])

			# ARRIVED AND FOUND NOBODY: strike it off and go back to the post. Measured against
			# where the bot is actually being sent -- which for a contact that went underground is
			# the corridor and not the lawn above it, hence the plane term. Without that, a defender
			# standing on a mouth is already "at" the cell below and never descends.
			if live or plane != get_plane() or _flat_gap(at) > arrival_slack:
				_intent = label
				_goal = at
				_goal_plane = plane
				return
			_cleared[intruder["mouse"]] = true
		_intent = "holding the nest"
		_goal = _post(nest)
		return

	# 6. An ally has their banner -- escort them home rather than running a second raid into a
	#    nest that no longer has anything to steal.
	if theirs.state == Banner.CARRIED and theirs.carrier != null and theirs.carrier.team == team:
		_intent = "escorting"
		_goal = theirs.carrier.global_position
		return

	# 7. The crew is running out of lives: go and fetch some. THE BANKRUPTCY PLAY (GDD section 2)
	#    -- disengage, concede if you have to, go and refill -- and until M8 the AI could not
	#    perform it at all. Bots picked cheese up by walking over it and never once went to get any,
	#    so a crew of bots played the whole economy by accident.
	#
	#    RAIDERS ONLY. Sending the defender shopping empties the nest, which is how a refill turns
	#    into a conceded capture nobody chose.
	#
	#    NOT `_raiding`, deliberately: an Engineer does not tunnel to a cheese pile. Digging is a
	#    twenty-second investment that pays off by arriving somewhere unwatched, and a wedge on the
	#    open lawn is neither.
	if role == RAIDER and _foraging():
		var pile := CheeseCache.nearest(get_tree(), global_position)
		if pile != null and global_position.distance_to(pile.global_position) <= forage_range:
			_intent = "fetching cheese"
			_goal = pile.global_position
			return

	# 8. Otherwise: go and take theirs. THE ONLY ERRAND AN ENGINEER MAY DIG, because it is the only
	#    one that is not urgent -- everything above this is a banner in play, and a tunnel is a
	#    twenty-second investment nobody makes while the match is being decided above their head.
	_intent = "going for their banner"
	_goal = theirs.global_position
	_raiding = true


## Is this crew poor enough to go shopping, and has it stopped being poor yet?
##
## HYSTERESIS, AND IT IS NOT OPTIONAL. A bare `cheese_of(team) < forage_below` flips the moment a
## single wedge lands, so a bot banks one, decides the crew is fine, turns round for the enemy
## nest, gets scruffed, and the crew is a wedge poorer than when it started. The same jitter that
## made the old dynamic class rule unusable (see `_wanted_class`), one system over: a threshold
## read raw is a threshold something will oscillate across.
##
## So it latches. Below `forage_below` the crew starts shopping, and it does not stop until it has
## `forage_until` -- which means a refill is a decision the crew commits to for a stretch, and
## reads from outside as a crew that has pulled back to regroup rather than as five mice
## twitching.
func _foraging() -> bool:
	if _director == null:
		return false
	var pile := _director.cheese_of(team)
	if _stocking:
		_stocking = pile < forage_until
	else:
		_stocking = pile < forage_below
	return _stocking


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

	# LIVE CONTACTS ONLY. A burst is a life, and spending one because somebody was seen near this
	# spot twelve seconds ago is spending it on a memory. The rule is "I am being chased", which is
	# a thing you have to be able to SEE to be true.
	if is_carrying():
		if not _seen_within(global_position, scurry_pursuit, true).is_empty():
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


## Which gear to walk in. The third decision, alongside where to go and who to hit.
##
## BOTS COULD NOT DO EITHER OF THESE UNTIL M8, and it was a real asymmetry rather than a missing
## flourish. `_tier_multiplier` lived on `Player`, so every bot in every match ran at exactly one
## speed: it could not sprint, which meant a human could simply outrun a defender for as long as
## they liked, and it could not go quiet, which meant the grass concealed the human from the AI
## (M8's other half) and never the AI from the human. Two mechanics that applied to one mouse in
## four.
##
## SPRINT IS FOR THE TWO MOMENTS THE RANKING ALREADY CARES ABOUT -- getting away with their banner,
## and catching whoever has yours -- because those are the two errands that are a race. It is
## deliberately the same pair `_consider_scurry` spends cheese on, and the two stack the way they
## do for a player: sprint is free and runs out, Scurry costs a life and does not. A bot reaches for
## the free one first by simply having both rules read the same situation.
##
## CREEPING IS FOR A RAID, and only while the raid is the errand. The point is not that slow is
## safer -- it is that a mouse crossing the yard at a walk stays under `reveal_opacity` in cover and
## therefore off the enemy's map (grass_camouflage.gd), which is the same trade the human makes
## with the same key. It is skipped the moment anything urgent happens, because everything above
## the raid in the ranking is a banner in play and none of it waits.
##
## NO CREEPING WHILE THE DIGGER DRIVES. A dig is meant to look like standing still, the digger
## returns the bot's own position to express that, and halving a zero heading achieves nothing
## except making the walk to the next face take twice as long.
func _consider_pace() -> void:
	var racing := is_carrying()
	if not racing:
		var thief := _director.carrier_of(team)
		racing = thief != null and not thief.is_scruffed()
	request_sprint(racing)

	# Only worth the speed when there is something to hide in. Asked of the same node the enemy
	# crew's sweep asks, so a bot slows down exactly when slowing down would buy it something --
	# and out in the open, where it would buy nothing, it walks like everybody else.
	set_creeping(_raiding and not racing and not _driven and _in_cover())


## Would going quiet actually hide this mouse? True only where there is cover to be hidden by.
##
## ASKED OF ITS OWN CONCEALMENT rather than of the enemy's contact book, and the distinction is the
## whole reason this is legal. "Am I hidden right now" is a fact about this mouse and the grass it
## is standing in; "does the enemy know where I am" is a fact about THEIR knowledge, and a bot
## reading that would be omniscience wearing a stealth costume.
##
## Fails closed. No spotting node means no concealment model, so there is nothing to be quiet for
## and the bot walks at its normal pace -- which is exactly what the headless audits should see.
func _in_cover() -> bool:
	if _spotting == null:
		_spotting = get_tree().get_first_node_in_group(Spotting.SPOTTING_GROUP) as Spotting
	if _spotting == null:
		return false
	# A TUNNEL IS NOT COVER. The concealment field is x,z only, so asking it from underground gets
	# back whatever is growing on the ceiling -- and a bot creeping down an empty corridor because
	# of a patch of lawn above its head is slow for nothing.
	if get_plane() > 0:
		return false
	# Measured at RUNNING pace rather than at the pace it is considering, which is the only way to
	# ask the question without it answering itself: a bot already creeping is already hidden, so
	# reading its current opacity would latch it into a permanent crawl the moment it touched a
	# patch. `concealment_at` is about the ground, not about the mouse on it.
	return _spotting.cover_at(global_position) > 0.0


## Where a defender stands when nothing is happening: a step out of the nest, toward the middle
## of the arena. On the banner itself it would be in the way of its own crew returning it.
func _post(nest: Nest) -> Vector3:
	var toward := -nest.global_position
	toward.y = 0.0
	if toward.length_squared() < 0.01:
		return nest.global_position
	return nest.global_position + toward.normalized() * 2.2


## Who this bot is squaring up to: the nearest enemy its crew can see RIGHT NOW, close enough to
## be worth facing. Never a destination -- see `engage_radius`.
##
## LIVE CONTACTS ONLY, and that is the whole difference between this and the defender's rule. A
## remembered contact is a guess about where somebody was, and you do not swing at a guess. Until
## M8 this asked the scene tree with no concealment test of any kind -- the gate had been written
## once, for the rule that produces a destination, and never for this one -- so a mouse doing
## everything the grass asks still got faced, tracked and hit from four metres. Worse than merely
## being seen: `_walk` hands the facing to the fight, so the bot also visibly STOPPED and stared,
## which is how you know you have been spotted by something that cannot see you.
## MY PLANE ONLY, and asked as part of the search rather than of the answer. Filtering afterwards
## reads the same and is not: the book belongs to the CREW, so the nearest live contact may have
## been picked out by a mouse two planes up, and rejecting the winner leaves this bot ignoring the
## enemy actually standing next to it. Same bug the plane test in spotting.gd's own sweep exists to
## prevent, arriving through the back door.
func _pick_quarry() -> Mouse:
	var seen := _seen_within(global_position, engage_radius, true, true)
	if seen.is_empty():
		return null
	return seen["mouse"] as Mouse


## The nearest enemy this bot's CREW believes is within `reach` of a spot, or an empty dictionary.
## `fresh` demands the contact was seen in the most recent sweep rather than merely remembered;
## `reachable` demands it be on this bot's own plane.
##
## Returns `{mouse, at, plane, live}`. **`at` is where the crew last SAW them, which is not where
## they are** -- every caller wanting a destination wants that and not the mouse's position.
##
## PERCEPTION IS THE CONTACT BOOK AND THERE IS NO SECOND COPY OF IT. What used to be here was a
## direct scan of the scene tree filtered through one opacity threshold, and it got two things
## wrong at once. It saw through boulders, walls and its own back -- spotting.gd says plainly that
## range and line of sight are the sweep's business and not `hidden`'s, and nothing on this side
## was doing that work. And it was PER MOUSE, so a crew mate watching a lane was worth nothing to
## anybody but themselves, which is the opposite of what a shared picture is for.
##
## Asking the book buys plane, range, line of sight, the opacity threshold and the carrier
## exemption in one call, from the same node that decides what your minimap shows. The bot knows
## exactly what the marker on your HUD knows -- so when it does something surprising, the reason is
## on screen.
func _seen_within(of: Vector3, reach: float, fresh: bool, reachable: bool = false) -> Dictionary:
	if _spotting == null:
		_spotting = get_tree().get_first_node_in_group(Spotting.SPOTTING_GROUP) as Spotting
	if _spotting == null:
		return _unaided_within(of, reach, reachable)

	var best: Dictionary = {}
	var closest := reach
	var book := _spotting.contacts_for(team)
	for key: Variant in book.keys():
		# VALIDITY BEFORE THE CAST, for the reason spotting.gd's `_forget` spells out at length:
		# `key as Mouse` performs the cast on assignment and throws outright on a freed object, and
		# M7 frees a mouse every time a human takes a bot's chair.
		if key == null or not is_instance_valid(key):
			_cleared.erase(key)
			continue
		var other := key as Mouse
		# A scruffed mouse is not a threat, and chasing one is the classic bot bug where it stands
		# over a body until the respawn. The book keeps the contact -- it is still true that they
		# were seen there -- so the filter belongs here rather than in the sweep.
		if other == null or other.is_scruffed():
			continue
		var entry: Dictionary = book[key]
		var live := bool(entry.get("live", false))
		# SEEING THEM AGAIN UN-STRIKES THEM. A ghost this bot walked through is struck off until the
		# crew actually lays eyes on that mouse, at which point the contact is news again -- so
		# hiding, being found, and hiding again works as many times as you can manage it.
		if live:
			_cleared.erase(key)
		elif _cleared.has(key):
			continue
		if fresh and not live:
			continue
		if reachable and int(entry.get("plane", 0)) != get_plane():
			continue
		var at: Vector3 = entry.get("at", other.global_position)
		var gap := of.distance_to(at)
		if gap <= closest:
			closest = gap
			best = {
				"mouse": other,
				"at": at,
				"plane": int(entry.get("plane", 0)),
				"live": live,
			}
	return best


## A contact that went stale standing on a shaft mouth climbed into it. Returns where to go and
## look, or an empty dictionary.
##
## THE ONLY WAY A BOT FINDS A TUNNEL BY ITSELF, and it is narrow on purpose. Earth hides you (GDD
## section 3) and spotting.gd holds that line absolutely -- an enemy a metre below your feet is not
## spotted, and match_audit asserts exactly that. Until M8 the bots quietly disagreed: rule 4 read
## the scene tree and ignored planes entirely, so a defender had X-ray vision through the ground and
## an Engineer's raid could never work against one. The audit had been passing on the strength of
## that private model rather than of the rule.
##
## So a bot may not notice a CORRIDOR. It may only notice a MOUSE -- on the lawn, in the open,
## disappearing into a hole -- which is a thing you can genuinely watch happen. That is why this is
## asked of the contact's own last-seen point and not of the network: consulting the mouth list to
## find somewhere an enemy might be would be a bot reading a map of tunnels its crew never cut,
## which is the leak route_planner.gd is separately being fixed for. Here the mouth is only ever
## confirmation of something a crew mate saw.
##
## `[LATER]` The real counterplay to a raid is the Sneak's sonar, which is a WATCH and is precisely
## what the defending Sneak seat exists for (see MatchDirector.SEATS) -- and nothing in the game has
## ever fired it. When bots gain ability inputs, a defending Sneak should sound the layer below its
## own banner on a timer and act on the cant mark. A passive "hears an enemy one layer down" on the
## Sneak is worth weighing at the same time, as a class ability rather than as a fact about earth.
## This rule is what a bot can manage until then, not a substitute for either.
func _went_to_ground(at: Vector3) -> Dictionary:
	if _network == null:
		return {}
	var graph := _network.graph()
	if graph == null:
		return {}
	for cell: Vector2i in graph.mouths():
		var mouth := _network.cell_to_world(0, cell)
		if Vector2(at.x - mouth.x, at.z - mouth.z).length() > mouth_slack:
			continue
		# The mouth is on the lawn; what is under it is the first place worth looking. A shaft with
		# nothing at the bottom is a hole somebody filled in behind them.
		if not graph.has(1, cell):
			continue
		return {"at": _network.cell_to_world(1, cell), "plane": 1}
	return {}


## What a bot sees on a map with no spotting node: everything within reach, as it used to.
##
## FAILS OPEN, DELIBERATELY, which is the same bargain the old concealment gate struck. A map
## without a concealment model is one where a defender that ignored every intruder would be a far
## louder bug than one that sees too well -- and it is exactly what the headless audits build,
## where the grass, the camera and the HUD are stripped out and the rules are all that is left.
##
## Shaped like a contact so the callers cannot tell the difference, and reported `live`, because
## with nothing modelling memory there is no such thing as a stale one.
func _unaided_within(of: Vector3, reach: float, reachable: bool) -> Dictionary:
	var best: Dictionary = {}
	var closest := reach
	for node in get_tree().get_nodes_in_group(MOUSE_GROUP):
		var other := node as Mouse
		if other == null or other == self or other.team == team or other.is_scruffed():
			continue
		if reachable and other.get_plane() != get_plane():
			continue
		var gap := of.distance_to(other.global_position)
		if gap <= closest:
			closest = gap
			best = {
				"mouse": other,
				"at": other.global_position,
				"plane": other.get_plane(),
				"live": true,
			}
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
	# THE CREW IS PASSED, and it is what stops a bot routing through the enemy's holes. See
	# RoutePlanner._ends -- until M8 a plan was built from every mouth on the map.
	_route = RoutePlanner.plan(
		_network, global_position, get_plane(), _goal, _goal_plane, tunnel_bias, team
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


## Pushing, and going nowhere: throw the plan away and make another one.
##
## `[ADDED at M8]` THE FILE ALREADY DESCRIBED THIS BUG before anything could cause it -- see
## `_advance`: *"a bot that keeps walking a route it has fallen off is the one that ends up jogging
## on the spot against a wall"*. Only one way of falling off a route was handled there, the shaft
## that turned out not to be under your feet, because until mice were solid to their own crew
## nothing else could put a bot somewhere its plan did not expect. Now a teammate can, and a
## corridor is one cell wide, so being nudged half a metre sideways underground is the difference
## between a waypoint you can walk to and one with earth in the way. `bot_soak` caught an Engineer
## pressed into a wall at 2.9 m/s for fifteen seconds with nobody within three metres of it.
##
## RE-PLANNING IS THE WHOLE FIX, and it is enough because a plan is cheap and made from where the
## bot ACTUALLY is: the next one routes out of the corner it is in rather than through it. What it
## must not do is fire while a bot is legitimately still -- a digger at a face and a defender at
## its post both stand there on purpose -- so the test is *asked for a heading and did not travel*,
## which neither of them does.
##
## A SIDESTEP ON THE SECOND STRIKE, because a re-plan alone can hand back the same route: the
## planner has no idea the bot is wedged, and a wedge that survives one re-plan will survive ten.
## One cell of lateral push is enough to break the symmetry, and it is thrown away the moment the
## bot moves again.
func _check_progress(delta: float) -> void:
	if _driven or _wish.is_zero_approx():
		_stuck_for = 0.0
		_stuck_at = global_position
		return

	_stuck_for += delta
	if _stuck_for < stuck_seconds:
		return
	# Measured over the whole window rather than per frame, so a bot squeezing past somebody at a
	# crawl is not mistaken for one that has stopped.
	var travelled := Vector2(
		global_position.x - _stuck_at.x, global_position.z - _stuck_at.z
	).length()
	_stuck_for = 0.0
	_stuck_at = global_position
	if travelled > stuck_distance:
		_stuck_strikes = 0
		return

	_stuck_strikes += 1
	_route.clear()
	_plan()
	if _stuck_strikes >= 2:
		# Perpendicular to whichever way it was trying to go, and the side alternates with the
		# strike count so a bot that picks the wrong one does not keep picking it.
		var side := Vector3(-_wish.z, 0.0, _wish.x).normalized()
		_wish = (side if _stuck_strikes % 2 == 0 else -side)
		_stuck_strikes = 0


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
