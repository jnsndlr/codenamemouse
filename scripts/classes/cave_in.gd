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
## `[REVISED]` A SHAFT IS NOW SOMETHING IT CAN TAKE, and it takes both ends. Either form may aim at
## a ladder: underground you point at the cell the shaft passes through, and from the lawn the
## stomp's patch reaches an entrance through its LANDING one plane down. Filling one end and not
## the other is not a state the world can hold, so a collapse on a shaft cell always costs two
## cells -- the mouth and what it lands on.
##
## THAT MAKES THE ENTRANCE THE PRIZE, and it is the reason the ability is worth its cooldown. A
## sealed corridor is a detour; a filled entrance is a crew that has to dig a new way in. It is also
## the point at which the Sneak's cant mark pays for itself twice over (GDD section 5): the mark
## names a cell, the Brute walks the lawn above it, and what a guess used to buy -- a room of
## corridor -- can now be the enemy's front door.
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
## Radius of the patch on the layer DIRECTLY below, in cells.
##
## `[REVISED]` 2.2, UP FROM 1.2 -- a tile wider. At 1.2 the patch was a plus-shape of five cells,
## which turned out to ask more of the Sneak's mark than the mark can give: cant names a *cell*,
## the Brute has to walk to the lawn above it, and standing one tile off meant the whole ten
## seconds bought nothing. Thirteen cells on the layer below is a patch you can aim by eye from a
## mark, which is what makes the handoff (GDD section 5) a play rather than a precision test.
##
## The taper below is unchanged, so the layer under that still narrows to five cells and plane 3
## is still out of reach -- widening the mouth of the shock did not widen its depth.
@export var stomp_radius_cells: float = 2.2
## Deepest layer a stomp reaches. GDD section 5 hangs the whole counterplay web on this number:
## the Engineer's answer to a Brute is to dig BELOW it, and that answer only exists because there
## is a floor the shock does not get through.
##
## Kept as its own dial rather than left to fall out of the taper below, because it is a DESIGN
## rule and the taper is a feel one. Widening the patch should not quietly hand the Brute plane 3.
@export var stomp_max_plane: int = 2
## Most cells that may trickle ceiling dust for one tremor, whatever the radius works out to. A
## DRAW BUDGET, not a design rule: the tell is *many cells shedding at once* and twenty carries that
## as well as fifty-five does, at a third of the nodes. See [method _thin_to_budget].
@export var tremor_dust_cells: int = 20
## Camera trauma at the Brute's own feet, 0..1. See [method CameraRig.shake].
@export_range(0.0, 1.0, 0.05) var stomp_shake: float = 0.85
## How far away the thump is still felt at all, in metres. Roughly two zoomed-out screen heights:
## far enough that a Brute working a chokepoint registers on a teammate holding the nest, close
## enough that it is never news about a part of the map you cannot see.
@export var stomp_shake_range: float = 14.0

@export_group("Tremor")
## How far past the collapse the earth is felt to move, in cells. Added to whatever the collapse
## itself reached, so the dust always covers ground the cave-in did *not* take -- the near miss is
## the entire point of it (see [CeilingDust]).
@export var tremor_extra_cells: float = 2.0
## Camera trauma for a mouse underground inside the tremor, at its centre. A fraction of what the
## Brute upstairs feels: you are being rattled by something happening nearby, not doing it.
@export_range(0.0, 1.0, 0.05) var tremor_shake: float = 0.35

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
	# ASKED BEFORE IT HAPPENS, because afterwards there is nothing left to ask. A shaft cell takes
	# its other end down with it (see [method TunnelNetwork.collapse_shaft]), and everyone standing
	# in either one is buried -- burying only the cell that was aimed at would leave a mouse alive
	# inside a tile that no longer exists.
	var footprint := _network.collapse_footprint(plane, cell)
	if not _network.collapse(plane, cell):
		return

	for down: Array in footprint:
		_bury(down[0], down[1])
	# Reach zero on each: this form takes the cells it aimed at and no ring around them, so the
	# tremor is `tremor_extra_cells` and nothing more. A cave-in should be felt by the corridor next
	# door, not by the whole level.
	var seeds: Array = []
	for down: Array in footprint:
		if int(down[0]) > 0:  # The lawn end of a shaft sheds no ceiling; the layer under it does.
			seeds.append([down[0], down[1], 0.0])
	_shake_the_earth(seeds)
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

	# THE DUST AND THE THUMP GO OFF HERE, above the puppet check, and that placement is the whole
	# of how they stay honest. Everything below this line is about what happened UNDERGROUND --
	# which cells came down, who was buried, whether anything was there at all -- and none of it
	# may reach the surface. Firing the presentation before any of that is known means it cannot
	# accidentally come to depend on it: there is no branch here that a found tunnel could take
	# and an empty stomp could not.
	_kick_up_dust(here)

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
		note("you throw your weight into the ground")
		return

	# THE TREMOR IS AIMED AT WHAT THE STOMP WOULD HAVE REACHED, not at what it did -- so it is
	# computed before the collapsing starts and does not care how much of it was actually there.
	# A stomp over nothing rattles the corridors around it exactly as hard as one that brings a
	# room down, which is the same rule the surface dust obeys, extended underground: the earth
	# moving is what a nearby mouse hears, and it does not tell them whether anything gave.
	var reached := stomp_cells(here)
	_shake_the_earth(_tremor_seed_cells(here))

	var taken := 0
	for entry: Array in reached:
		var plane: int = entry[0]
		var cell: Vector2i = entry[1]
		# A SHAFT INSIDE THE PATCH COMES DOWN WHOLE, which is how a stomp reaches the surface. The
		# patch itself never touches plane 0 -- there is nothing up there to collapse but grass --
		# so an entrance is taken through its LANDING: the plane-1 cell is in the patch like any
		# other, and filling it fills the mouth on the lawn with it. That also means one entry here
		# can take a cell another entry was going to; the second attempt finds it gone and the
		# `continue` below is the whole of the handling that needs.
		var footprint := _network.collapse_footprint(plane, cell)
		if not _network.collapse(plane, cell):
			continue
		for down: Array in footprint:
			_bury(down[0], down[1])
		taken += footprint.size()

	_cooldown_left = stomp_cooldown
	stomped.emit(taken)
	# `note` RATHER THAN `explain`, because neither of these is a refusal -- the ability fired.
	# These two lines are the reason [MouseControl] has a second door at all: sent down the refusal
	# channel they came out on screen as **BLOCKED: the ground gives way beneath you**, which is
	# what a channel named for one voice does to a message written in the other.
	note(
		"the ground gives way beneath you" if taken > 0
		else "solid ground -- nothing under here"
	)


## The surface half of a stomp: a ring of dust, and a thump in the camera.
##
## SPAWNED IN THE WORLD, WATCHED OR NOT. The dust is a thing that happens in the yard rather than a
## thing one player is shown -- an enemy Sneak lying in the grass should see a Brute testing the
## ground twenty metres away, because that is exactly the information the stomp is meant to give
## away in exchange for what it learns. That makes it the opposite of the sonar echo, which is one
## Sneak's private hearing and is gated on `watched()`.
##
## THE SHAKE IS THE OPPOSITE, and belongs to one pair of eyes: there is one camera on this machine
## and it is the local viewer's. FELT AT A DISTANCE, though, and falling off with it -- a Brute
## stamping beside you should rattle your view whoever is driving it. That is not a leak: a Brute
## on the lawn is a mouse standing in the open, in plain sight, doing the loudest thing in the
## game. What the shake never says is whether the stomp FOUND anything, which is the rule the
## whole ability is built around.
##
## ON A CLIENT THIS RUNS FOR ITS OWN MOUSE ONLY, which is the known gap. A remote Brute's stomp
## reaches this machine as a collapsed cell if the crew may know about it, and as nothing at all
## if it may not -- so its dust does not travel. Fixing that is a one-shot world event on the wire
## (`SONAR_ECHO` is the pattern), and it is deliberately not built here: the message would have to
## be filtered per-crew or it would announce every stomp on the map, which is a bigger question
## than a dust cloud.
func _kick_up_dust(here: Vector2i) -> void:
	# Seeded from the cell so both ends of a wire draw the same cloud. Nothing compares them; it
	# costs one integer and removes a class of "why do the screenshots differ" question.
	StompDust.burst(
		_network, _network.cell_to_world(0, here) + Vector3.UP * 0.02, here.x * 73856093 ^ here.y
	)

	var rig := get_tree().get_first_node_in_group(CameraRig.RIG_GROUP) as CameraRig
	var watcher := director().local_mouse() if director() != null else _player
	if rig == null or watcher == null:
		return
	# Full trauma under your own feet, nothing past the falloff. Squared so the strong half of the
	# curve is close in -- a linear falloff has the whole yard feeling a faint tremor, which is
	# both noisy and, at the edges, a hint that something happened somewhere you cannot see.
	var distance := watcher.global_position.distance_to(_player.global_position)
	var nearness := 1.0 - clampf(distance / stomp_shake_range, 0.0, 1.0)
	rig.shake(stomp_shake * nearness * nearness)


## Where a stomp's tremor radiates from, regardless of what was under the lawn.
##
## THE CENTRE OF EACH LAYER IT COULD HAVE REACHED, not the cells it found. `stomp_cells` only
## returns cells that are actually dug, so a stomp over solid earth returns nothing and would
## radiate nothing -- which would make the *absence* of a tremor the same free answer the ability
## spends ten seconds refusing to give. This says "the shock arrived on planes 1 and 2 under this
## spot" and lets the tremor find whatever open corridor is near it.
##
## EACH SEED CARRIES ITS OWN REACH -- `[plane, cell, radius]`. The tremor is *the collapse plus a
## couple of cells*, so it has to be told how far the collapse got, and the two forms of this
## ability get very different answers: a stomp spreads a patch, an aimed cave-in takes one tile.
## The first build read `stomp_radius_cells` in both cases and gave a single-cell cave-in a
## four-cell cloud of dust, which is not a near miss, it is weather.
func _tremor_seed_cells(here: Vector2i) -> Array:
	var seeds: Array = []
	var deepest := mini(stomp_max_plane, TunnelNetwork.PLANE_COUNT - 1)
	for plane in range(1, deepest + 1):
		var radius := stomp_radius_cells - float(plane - 1)
		if radius < 0.0:
			break
		seeds.append([plane, here, radius])
	return seeds


## The near miss: dust out of the ceiling over open corridor near a collapse, and a rattle in the
## view of anyone underground close enough to feel it.
##
## WIDER THAN THE COLLAPSE, BY DESIGN. `tremor_extra_cells` is added on top of whatever the
## collapse itself reached, so this always covers ground the cave-in did not take. Everyone it
## reaches is someone who was *not* buried -- that is the whole content of the effect. Before it,
## a collapse two tiles away was completely silent to the mouse it nearly got.
##
## PRESENTATION, AND THEREFORE VIEWER-LOCAL AND FILTERED. Two rules, and the second is the one that
## matters:
##
##   The dust is drawn only for the machine's own viewer, like the sonar echo. A host runs this
##   ability for every human in the match and would otherwise trickle four crews' worth of dust
##   through its own yard.
##
##   And only over cells that viewer's crew MAY KNOW ABOUT. Dust falling in an enemy corridor
##   would draw its floor plan in the air for anybody within earshot of a collapse -- a Brute could
##   stomp blindly and read the answer off where the dust landed, which is precisely the free sonar
##   sweep the ability is built to refuse, arriving by a side door. `TunnelSight.knows` is the same
##   predicate the minimap and the cutaway ask.
func _shake_the_earth(seeds: Array) -> void:
	if seeds.is_empty() or _network == null:
		return
	var watcher := director().local_mouse() if director() != null else _player
	if watcher == null or watcher.get_plane() <= 0:
		return  # Nobody underground is looking; there is no ceiling to shed for anyone.

	var sight := get_tree().get_first_node_in_group(TunnelSight.SIGHT_GROUP) as TunnelSight
	var watching := watcher.get_plane()
	var strongest := 0.0
	var here := _network.world_to_cell(watcher.global_position)

	for seed_entry: Array in seeds:
		var plane: int = seed_entry[0]
		var centre: Vector2i = seed_entry[1]
		# The layer the shock hit, and the one under it -- the floor that just moved is somebody
		# else's ceiling. Deeper than that is out of reach for the same reason the collapse is.
		if watching != plane and watching != plane + 1:
			continue
		var radius: float = float(seed_entry[2]) + tremor_extra_cells
		if watching == plane + 1:
			radius -= 1.0  # A layer further from it, so a little less of it arrives.
		if radius <= 0.0:
			continue

		var span := ceili(radius)
		var eligible: Array[Vector2i] = []
		for dx in range(-span, span + 1):
			for dy in range(-span, span + 1):
				var cell := centre + Vector2i(dx, dy)
				var away := Vector2(dx, dy).length()
				if away > radius or not _network.is_dug(watching, cell):
					continue
				if sight != null and not sight.knows(watcher.team, watching, cell):
					continue
				eligible.append(cell)

		for cell in _thin_to_budget(eligible):
			CeilingDust.fall(
				_network,
				_network.cell_to_world(watching, cell),
				TunnelNetwork.SPACING,
				cell.x * 73856093 ^ cell.y ^ watching
			)
		strongest = maxf(
			strongest, 1.0 - clampf(Vector2(here - centre).length() / radius, 0.0, 1.0)
		)

	if strongest <= 0.0:
		return
	var rig := get_tree().get_first_node_in_group(CameraRig.RIG_GROUP) as CameraRig
	if rig != null:
		rig.shake(tremor_shake * strongest * strongest)


## Spread `cells` down to at most `tremor_dust_cells`, keeping the spread rather than the nearest.
##
## THE COST OF THIS EFFECT IS CELLS, AND CELLS GROW AS THE SQUARE OF THE RADIUS. At 4.2 the disc is
## about fifty-five of them, four motes each -- two hundred nodes built in one frame for a tell that
## reads perfectly well at a fifth of that. Widening the stomp by one cell would have added another
## thirty, silently, because nothing in the ability's own numbers looks like a draw budget.
##
## STRIDED, NOT NEAREST. Taking the closest cells packs every mote into a blob around the collapse,
## which is exactly the direction-and-distance the effect refuses to give away (see the class note
## on [CeilingDust]). Row-major order strided by a constant scatters the survivors across the whole
## disc, so what thins out is the density and not the reach.
func _thin_to_budget(cells: Array[Vector2i]) -> Array[Vector2i]:
	var budget := maxi(tremor_dust_cells, 1)
	if cells.size() <= budget:
		return cells
	var kept: Array[Vector2i] = []
	var stride := float(cells.size()) / float(budget)
	for index in range(budget):
		kept.append(cells[mini(int(float(index) * stride), cells.size() - 1)])
	return kept


## Everyone standing in the cell as it comes down (GDD section 3).
##
## Credited to the Brute, which matters for the feed and for anything that later counts who did
## what -- a cave-in is one you earned, not an act of God.
##
## `[REVISED]` BURIED, NOT SCRUFFED. [method Mouse.bury] rather than a nine-thousand-point hit --
## same outcome, different word, and the word was the point: nobody wrestled you, a cubic metre of
## earth arrived where you were standing. The blunt damage is still what does it underneath, and
## still deliberately enormous rather than exact: this is a roof, and a Brute surviving one on high
## health would read as the mechanic being broken rather than as the Brute being tough.
## NOT ON THE LAWN, and this guard is load-bearing rather than defensive. A shaft collapse names
## both of its ends, and the upper end of an entrance is plane 0 -- so without this, the very first
## thing a Brute does when it stomps the mouth it is standing on is bury ITSELF. There is nothing
## above the surface to arrive on top of you; a mouth closing under your feet is ground filling in,
## not a roof coming down.
func _bury(plane: int, cell: Vector2i) -> void:
	if plane <= 0:
		return
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or mouse.is_scruffed() or mouse.get_plane() != plane:
			continue
		if _network.world_to_cell(mouse.global_position) != cell:
			continue
		mouse.bury(_player)
