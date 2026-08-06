class_name CaveIn
extends MouseControl
## The Brute's capability: bring a tunnel down. One cell at arm's length while you are in it, or a
## stomp from the lawn that drops a small patch of the layers below.
##
## ONE PER MOUSE SINCE M7, not one per arena. See [MouseControl].
##
## `[REVISED]` THE ABILITY MOVED FROM THE ENGINEER TO THE BRUTE, and that resolves the `[DECIDE]`
## GDD section 4 has carried since M4. The two classes were written with the same verb pointed at
## each other -- the Engineer sealing from inside as an escape, the Brute collapsing from the
## surface as denial -- on the theory that "where you stand" was a big enough difference to make
## them separate capabilities. It is not. They are one mechanic with two postures, and splitting a
## mechanic across two classes means neither owns it, which is the exact opposite of what Pillar 4
## asks for. So un-digging is the Brute's whole, and the Engineer's exclusive falls back to
## Barricade alone -- which section 4 already names as the fallback.
##
## THE CONSEQUENCE FOR THE ENGINEER IS REAL AND IS THE POINT. It loses its escape button: a
## corridor it dug is no longer a corridor it can close behind itself. What it keeps is making and
## shaping -- three times the dig speed, and the one thing that stands in a corridor without
## destroying it. The class that BUILDS the map and the class that UNBUILDS it are now two
## different people, which is a cleaner line than the one that ran through the middle of a verb.
##
## TWO FORMS, ONE KEY, AND THE PLANE DECIDES WHICH. Underground it is aimed and surgical; on the
## surface it is a stomp, centred on your own feet, that takes a patch. That is not two abilities
## sharing a binding -- it is one capability asked in the two places a Brute can be standing, and
## the difference between them is the difference between the two jobs section 4 gives the class:
## corking a tunnel you are inside, and denying one you are on top of.
##
## THE STOMP IS NOT AIMED, and that is what makes sonar worth having. The cave-in is aimed because
## you can see the corridor you are sealing; on the lawn you can see nothing, so aiming would be
## pointing at grass and hoping. Centring it on the Brute's own cell means the crew's answer to
## "where do I stomp" is a cant mark on the minimap -- a Sneak found the tunnel and the Brute walks
## to it. That is section 5's counterplay web with the middle link finally built.
##
## MICE CAUGHT INSIDE ARE SCRUFFED (GDD section 3). Not killed -- nothing in this game is --
## and, notably, this is the only way to scruff somebody that has no facing check and no arc.
## Standing in the wrong cell is the whole counterplay, which is why the reach is one tile and
## the cooldown is long enough to see coming.
##
## NUMBERS LIVE HERE, not in an AbilityDefinition resource, and that is on purpose for exactly
## one more ability. The plan sketches `AbilityDefinition` and it is the right shape -- the day
## Slam lands there are three things sharing a cooldown, a cast time and a cheese cost, and it
## should be built then, from real examples rather than from a guess.

## Emitted whichever way it goes, so the HUD can say what happened without this file knowing
## there is a HUD. Refusals matter as much as successes: a key that silently does nothing is
## indistinguishable from a key that is broken.
signal collapsed(plane: int, cell: Vector2i)
## A stomp landed, and how much ground it found. Zero is a real and interesting answer -- see
## `_stomp`.
signal stomped(cells: int)
signal refused(reason: String)

@export_group("Ability")
## Which class may do this. An export rather than a hard-coded check, because "who owns this
## capability" is a design question and the answer has now moved twice.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.BRUTE
## Seconds between uses of the aimed, underground form. Long: this removes a piece of the map, and
## the counterplay to it is seeing that the Brute has just used it.
@export var cooldown: float = 6.0
## How far the aimed cell may be, in cells. One -- a much shorter arm than digging's 2.6, because
## the thing being removed can have a mouse standing in it. Collapsing something across the room
## would be an execution at range.
@export var reach_cells: float = 1.6

@export_group("Stomp")
## Seconds between stomps. Longer than the aimed form, because it takes a patch rather than a tile
## and because it is the one that gets spent on a guess -- see `_stomp`.
@export var stomp_cooldown: float = 10.0
## Radius of the patch on the layer DIRECTLY below, in cells. 1.2 is a plus-shape: the cell under
## your feet and its four neighbours. Small on purpose -- the fantasy is a heavy mouse putting a
## foot through a roof, not an earthquake, and a wide one would make the Sneak's mark unnecessary
## because you could stand anywhere near it and still connect.
@export var stomp_radius_cells: float = 1.2
## Deepest layer a stomp reaches. GDD section 5 hangs the whole counterplay web on this number:
## the Engineer's answer to a Brute is to dig BELOW it, and that answer only exists because there
## is a floor the shock does not get through.
##
## Kept as its own dial rather than left to fall out of the taper below, because it is a DESIGN
## rule and the taper is a feel one. Widening the patch should not quietly hand the Brute plane 3.
@export var stomp_max_plane: int = 2

var _cooldown_left: float = 0.0
## Built on the first frame anybody is looking at this mouse, and never on the other nine.
var _cursor: CollapseCursor


func _ready() -> void:
	super()
	if _player == null or _network == null:
		push_warning("cave-in: needs a mouse and a network -- the ability is off")
		set_process(false)
		set_physics_process(false)
		return
	# Refusals go out to the local viewer and to nobody else. `explain` is the base class's one
	# door for that, and the reason it is a door rather than a direct `dig_refused.emit` is that
	# a host now runs this ability for every human in the match -- see [MouseControl].
	refused.connect(explain)


func _process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_show_reach()


## Light up the cell this would bring down.
##
## Only for the class that can do it. A box following every mouse that walks through a corridor
## would be noise, and worse, it would promise a capability three of the four do not have -- the
## class gate is the whole of Pillar 4 for the Brute and the world should say so.
## ...AND ONLY FOR THE MOUSE THIS MACHINE IS LOOKING AT (M7). Every driven mouse carries one of
## these now, so an unconditional cursor would light a cell for every Brute in the match on
## every screen in the match.
##
## NOTHING IS DRAWN FOR THE STOMP, and that is deliberate rather than unfinished. There is no cell
## to point at -- the patch is wherever you are standing -- so the only thing a cursor could add is
## a box on the grass restating your own position. Worse, a box that appeared only when there was
## something underneath would be a free sonar: the Brute could sweep the lawn and read the enemy's
## network off its own cursor. What you are standing on stays hidden until you spend the ability.
func _show_reach() -> void:
	if not watched():
		if _cursor != null:
			_cursor.show_target(_network, 0, Vector2i.MAX, false)
		return
	if _cursor == null:
		# Parented to the network, like the dig cursor, so it moves with the tunnels rather than
		# with this node -- which is a plain Node with no transform of its own.
		_cursor = CollapseCursor.new()
		_network.add_child(_cursor)
	if _player == null or _player.is_scruffed() or _player.mouse_class != owner_class:
		_cursor.show_target(_network, 0, Vector2i.MAX, false)
		return
	var plane := _player.get_plane()
	if plane <= 0:
		_cursor.show_target(_network, 0, Vector2i.MAX, false)
		return
	_cursor.show_target(_network, plane, target(), _cooldown_left <= 0.0)


## 0 when ready, counting down otherwise. For a HUD that wants to draw the wait.
func cooldown_left() -> float:
	return _cooldown_left


func is_ready() -> bool:
	return _cooldown_left <= 0.0 and _player != null and _player.mouse_class == owner_class


## The cell this would bring down, or MAX if there isn't a legal one under the cursor.
##
## THE AIMED FORM ONLY. On the surface there is no aimed cell at all and this answers MAX, which is
## the honest answer: a stomp does not have a target, it has a location.
##
## Deliberately the same shape of question the dig controller asks, and deliberately NOT shared
## code with it: they agree today by coincidence of both being "the cell under the cursor, within
## a reach", and the moment either grows a rule of its own -- a barricade needs a wall, this one
## needs an occupied cell to be worth it -- a shared helper would have to grow a flag.
func target() -> Vector2i:
	if _player == null or _network == null or _player.get_plane() <= 0:
		return Vector2i.MAX

	var aim := _player.get_aim_point()
	var cell := _network.world_to_cell(aim)
	var here := _network.world_to_cell(_player.global_position)
	if cell == here:
		return Vector2i.MAX
	if Vector2(cell - here).length() > reach_cells:
		return Vector2i.MAX
	if not _network.can_collapse(_player.get_plane(), cell):
		return Vector2i.MAX
	return cell


## Every cell a stomp from `here` would try to bring down, deepest layer last.
##
## THE PATCH TAPERS WITH DEPTH: full radius on the layer directly below, one cell narrower for each
## one under that. So a default stomp is five cells on plane 1 and the single cell directly beneath
## you on plane 2 -- the shock spreads at the top and arrives at the bottom as a point. That reads
## correctly (a foot going through a roof does not shake the cellar evenly) and it does real design
## work: an Engineer one layer down loses a room, an Engineer two layers down loses a tile, and an
## Engineer on plane 3 is out of reach entirely.
##
## PURE, AND ASKED BEFORE IT IS ACTED ON, because the audits want to know what a stomp WOULD take
## without a mouse having to stand there and press the key.
func stomp_cells(here: Vector2i) -> Array:
	var found: Array = []
	var deepest := mini(stomp_max_plane, TunnelNetwork.PLANE_COUNT - 1)
	for plane in range(1, deepest + 1):
		var radius := stomp_radius_cells - float(plane - 1)
		if radius < 0.0:
			break
		var span := ceili(radius)
		for dx in range(-span, span + 1):
			for dy in range(-span, span + 1):
				var cell := here + Vector2i(dx, dy)
				if Vector2(dx, dy).length() > radius:
					continue
				if not _network.can_collapse(plane, cell):
					continue
				found.append([plane, cell])
	return found


## READ ON THE PHYSICS TICK, NOT FROM AN INPUT EVENT (M7).
##
## This was an `_unhandled_input` handler, which is the natural way to write it and the one shape
## that cannot survive a server: an event handler fires on *this* machine's event stream, and a
## server has no such stream for a peer three hundred miles away. It now reads the same
## [InputFrame] everything else does, so a packet drives it exactly as a keyboard does.
##
## `_physics_process` AND NOT `_process`, and that distinction is load-bearing. The frame is built
## once per physics tick and its pressed bits stay latched for that whole tick; idle frames can run
## more than once per physics tick on a fast display, and this ability would fire twice from one
## keypress at 120Hz and once at 60Hz. Cooldown ticking stays in `_process` -- that is a wall
## clock, and it does not care.
##
## Nothing consumes the press any more. `set_input_as_handled` used to stop two ability nodes
## reacting to the same key; the class gate below was always what actually did that work, since
## only one node's `owner_class` can match the mouse.
func _physics_process(_delta: float) -> void:
	if _player == null:
		return
	if not _player.input().is_pressed(InputFrame.Action.ABILITY):
		return
	if _player.is_scruffed():
		return

	# Q is the primary CLASS ability, not a global cave-in button. Other classes leave the event
	# untouched so their own ability node can claim it (the Sneak's Sonar is the first).
	if _player.mouse_class != owner_class:
		return

	if _player.get_plane() <= 0:
		_stomp()
	else:
		_cave_in()


## The aimed form: one cell, at arm's length, in the tunnel you are standing in.
func _cave_in() -> void:
	if _cooldown_left > 0.0:
		refused.emit("still clearing the last one -- %ds" % ceili(_cooldown_left))
		return

	var cell := target()
	if cell == Vector2i.MAX:
		refused.emit("point at the tunnel beside you")
		return

	# A PUPPET RUNS ITS COOLDOWN AND NEVER ACTS ON IT (M7), which is the same shape checkpoint 3
	# settled for the banner's return clock. Every check above this line is a rule both machines
	# can evaluate identically off state both machines have, so the person pressing Q gets a HUD
	# that greys out and a reason when it refuses; what they do not get is a hole in the ground,
	# because the roof coming in is the server's to decide and `_bury` is damage.
	if not acts():
		_cooldown_left = cooldown
		return

	var plane := _player.get_plane()
	if not _network.collapse(plane, cell):
		return

	_bury(plane, cell)
	_cooldown_left = cooldown
	collapsed.emit(plane, cell)


## The surface form: put a foot through whatever is under you.
##
## IT ALWAYS GOES OFF, and never refuses for finding nothing. That rule is the whole design of this
## half. A stomp that only fired over a tunnel would answer "is there something beneath me?" for
## free, on demand, anywhere on the map -- a Brute could walk the lawn tapping Q and read the
## enemy's entire network off which presses were refused, which is M5's pillar handed away by a
## guard clause. So an empty stomp costs exactly what a full one costs: the cooldown.
##
## AND IT STILL SAYS WHAT HAPPENED. Spending ten seconds to learn there is nothing here is
## information you paid for, and it is the price a crew without a Sneak pays for the same knowledge
## a cant mark gives away. What this project will not tolerate is a key that appears broken -- three
## other files say so in their own headers -- so the answer arrives, it just arrives after the bill.
##
## NOT THROUGH PAVING (GDD section 3). A no-surface zone is a slab, and you cannot stamp through a
## slab; the earth under a patio is the one earth a Brute cannot reach from above. This is a
## refusal that leaks nothing -- the paving is authored, visible, and standing right there in front
## of everybody -- and it hands the Engineer a real answer: a route under the patio is a route no
## stomp can touch.
func _stomp() -> void:
	var here := _network.world_to_cell(_player.global_position)
	if _network.is_sealed(here):
		refused.emit("paving underfoot -- nothing to put a foot through")
		return
	if _cooldown_left > 0.0:
		refused.emit("catching your breath -- %ds" % ceili(_cooldown_left))
		return

	# A puppet runs its cooldown and moves no earth, exactly as the aimed form does -- BUT IT STILL
	# HAS TO SAY SOMETHING, and this is the one place in the five controls where that is true.
	#
	# Every other ability leaves a puppet a visible result to read: a cell vanishes, a boulder
	# appears, an echo shimmers, and the server's picture supplies it a moment later. A stomp that
	# finds nothing produces no world change at all, so a client Brute pressing Q on bare ground
	# would get silence -- which is this project's oldest bug in a new costume, a key that is
	# indistinguishable from a broken one.
	#
	# IT ACKNOWLEDGES THE ACT AND NOT THE OUTCOME, which is the only honest thing it can do. A
	# client's network holds what its own crew knows rather than what is there, so asking
	# `stomp_cells` here and reporting the answer would print a confident lie about the enemy's
	# tunnels roughly whenever it mattered. What the client can be certain of is that its mouse
	# just stamped; what happened underneath arrives, or does not, from the server.
	if not acts():
		_cooldown_left = stomp_cooldown
		explain("you throw your weight into the ground")
		return

	var taken := 0
	for entry: Array in stomp_cells(here):
		var plane: int = entry[0]
		var cell: Vector2i = entry[1]
		if not _network.collapse(plane, cell):
			continue
		_bury(plane, cell)
		taken += 1

	_cooldown_left = stomp_cooldown
	stomped.emit(taken)
	# `explain` DIRECTLY RATHER THAN THROUGH `refused`, because neither of these is a refusal --
	# the ability fired. The base class's door is the one line on screen that says what a control
	# just did, and a stomp is the first thing in the game whose OUTCOME needs it rather than its
	# rejection. Emitting a success on a signal named `refused` would read as one for anything that
	# later listens for real refusals -- a feed, a tutorial, an audit counting failed presses.
	explain(
		"the ground gives way beneath you" if taken > 0
		else "solid ground -- nothing under here"
	)


## Everyone standing in the cell as it comes down (GDD section 3).
##
## Credited to the Brute, which matters for the feed and for anything that later counts who did
## what -- a cave-in is a kill you earned, not an act of God. The damage is deliberately enormous
## rather than exact: this is a roof landing on you, and a Brute surviving it on high health would
## read as the mechanic being broken rather than as the Brute being tough.
func _bury(plane: int, cell: Vector2i) -> void:
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or mouse.is_scruffed() or mouse.get_plane() != plane:
			continue
		if _network.world_to_cell(mouse.global_position) != cell:
			continue
		mouse.take_hit(9999.0, mouse.global_position, 0.0, _player)
