class_name Barricade
extends MouseControl
## The Engineer's other half: put a boulder in the way (GDD section 4).
##
## ONE PER MOUSE SINCE M7, not one per arena. See [MouseControl] -- and this is the ability that
## most obviously wanted it already: `max_standing` is *this Engineer's* budget, and a single node
## per arena could only ever hold one Engineer's worth.
##
## THE PAIR TO THE CAVE-IN, and the two are deliberately different tools rather than one tool with
## a flag. A cave-in is permanent, instant, kills the corridor and can scruff whoever is standing
## there; a barricade is a delay -- the corridor still exists, you can see down it, and the other
## crew gets it back by fielding the class that shifts rock. One is denial, the other is tempo.
## Section 4's Engineer is "map control, route creation, fortification"; the cave-in is the first
## two and this is the third.
##
## NO CHEESE COST, unlike the two-cheese price GDD section 2 pencilled in. The economy does not
## exist until M6 and the cheese ledger currently has nothing that spends it -- pricing an ability
## against a resource with no sinks would mean tuning it twice, once now against nothing and again
## when the sinks arrive. The cost is COOLDOWN AND SUPPLY instead, which are both real: ten seconds
## between placements, and never more than three of yours standing at once. Both are the sort of
## limit you feel in the moment rather than in an account balance.
##
## THREE STANDING, NOT THREE PLACED. Barricades cleared by a Brute give the slot back, so an
## Engineer working against a Brute has a live budget rather than an ammunition count -- which is
## what makes the two classes an argument instead of a countdown.
##
## AIMED, like everything else this class does. Same reasoning as the cave-in: the cursor is the
## steering wheel (section 9), so choosing the cell means turning to look at it and therefore not
## running for a moment.

signal placed(plane: int, cell: Vector2i)
signal refused(reason: String)

@export_group("Ability")
## Who may do this. An export rather than a hard-coded check, because "which class owns this" is a
## design question and this project's answers have moved before.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.ENGINEER
## Seconds before the next one can go down. Starts READY -- you arrive at the match with one in
## hand, because an ability that begins on cooldown is one whose first use is at a time nobody
## chose.
@export var cooldown: float = 10.0
## How many of this Engineer's barricades may stand at once.
@export var max_standing: int = 3
## How far the aimed cell may be, in cells. The same arm's length as the cave-in: you are heaving
## a rock into a gap, not throwing it.
@export var reach_cells: float = 1.6

var _cooldown_left: float = 0.0
## Barricades this Engineer has standing. Pruned rather than counted from the group, because the
## limit is per-Engineer and a shared group would let one crew's boulders eat another's budget.
var _standing: Array[BarricadeRock] = []


func _ready() -> void:
	super()
	if _player == null or _network == null:
		push_warning("barricade: needs a mouse and a network -- the ability is off")
		set_process(false)
		set_physics_process(false)
		return
	# Refusals go to the local viewer and to nobody else -- see [MouseControl].
	refused.connect(explain)


func _process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	# Walked rather than filtered: `Array.filter` hands back an UNTYPED array, and assigning one to
	# a typed variable aborts the call at runtime. That is the same GDScript trap that let the
	# tunnel audit spend its whole life passing without testing anything.
	var still: Array[BarricadeRock] = []
	for rock: BarricadeRock in _standing:
		if is_instance_valid(rock):
			still.append(rock)
	_standing = still


func cooldown_left() -> float:
	return _cooldown_left


## How many more you could put down right now, ignoring the cooldown. For a HUD that wants to draw
## the supply rather than make the player count boulders.
func in_hand() -> int:
	return maxi(0, max_standing - _standing.size())


func is_ready() -> bool:
	return (
		_cooldown_left <= 0.0 and in_hand() > 0
		and _player != null and _player.mouse_class == owner_class
	)


## The cell a barricade would go in, or MAX if there isn't a legal one under the cursor.
func target() -> Vector2i:
	if _player == null or _network == null or _player.get_plane() <= 0:
		return Vector2i.MAX

	var plane := _player.get_plane()
	var cell := _network.world_to_cell(_player.get_aim_point())
	var here := _network.world_to_cell(_player.global_position)
	if cell == here:
		return Vector2i.MAX
	if Vector2(cell - here).length() > reach_cells:
		return Vector2i.MAX
	if not _network.is_dug(plane, cell) or _network.is_blocked(plane, cell):
		return Vector2i.MAX
	# NEVER A SHAFT CELL. Wedging a boulder into the mouth of a ladder would leave E pointing at a
	# route nobody can take, and the beam of daylight -- the only thing that says a way out is here
	# -- would go on saying it. The cave-in refuses shafts for the same family of reason.
	if _network.has_shaft_down(plane, cell) or _network.has_shaft_up(plane, cell):
		return Vector2i.MAX
	return cell


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
	if not _player.input().is_pressed(InputFrame.Action.BARRICADE):
		return
	if _player.is_scruffed():
		return

	if _player.mouse_class != owner_class:
		refused.emit("only the %s can set a barricade" % MouseClass.name_of(owner_class))
		return
	if _player.get_plane() <= 0:
		refused.emit("nothing to wedge it against up here")
		return
	if _cooldown_left > 0.0:
		refused.emit("catching your breath -- %ds" % ceili(_cooldown_left))
		return
	if in_hand() <= 0:
		refused.emit("three is all you can hold open at once")
		return

	var cell := target()
	if cell == Vector2i.MAX:
		refused.emit("point at the open tunnel beside you")
		return
	# NOT ON TOP OF SOMEBODY. A barricade is a wall, and dropping a wall onto a mouse would either
	# trap it inside solid rock or shove it through one -- neither of which is a mechanic. The
	# cave-in gets to bury people because it is a roof falling in; this is a rock being pushed, and
	# you cannot push a rock through someone.
	var plane := _player.get_plane()
	if _occupied(plane, cell):
		refused.emit("somebody is standing there")
		return

	# A PUPPET RUNS ITS COOLDOWN AND PUTS NOTHING DOWN (M7). A boulder is a world object spawned at
	# runtime, and this protocol does not replicate barricades yet. So a remote Engineer's
	# barricades are real on the server, block the routing graph there, and are invisible to every
	# client until that gap is closed.
	# Placing one locally instead would be worse than invisible: it would be a wall that only one
	# machine believes in.
	if not acts():
		_cooldown_left = cooldown
		return

	var rock := BarricadeRock.place(_network, plane, cell, _player)
	_standing.append(rock)
	_cooldown_left = cooldown
	placed.emit(plane, cell)


func _occupied(plane: int, cell: Vector2i) -> bool:
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or mouse.is_scruffed() or mouse.get_plane() != plane:
			continue
		if _network.world_to_cell(mouse.global_position) == cell:
			return true
	return false
