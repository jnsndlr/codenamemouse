class_name ShoreUp
extends MouseControl
## The Engineer's class ability: stand in a corridor for three seconds and the next collapse aimed
## at it is spent breaking your timbers instead of taking the cell (GDD section 4).
##
## Q HAD NO MEANING FOR THE ENGINEER, and that was the loudest hole in the roster. Every other
## class has an answer to the ability key -- [CaveIn] for a Brute, [Sonar] for a Sneak,
## [SecondWind] for a Generalist -- and the Engineer, whose whole identity is the map, had a dead
## key and one ability on X. This is what goes there.
##
## IT IS THE ESCAPE BUTTON, GIVEN BACK IN THE OTHER DIRECTION. GDD section 4 names the cost of
## moving un-digging to the Brute out loud: *"the Engineer has lost its escape button"*, and it
## leaves the question open on purpose -- if the Engineer turns out to be uncatchable without it,
## the answer is not the cave-in coming back. This is that answer, and it is deliberately not a
## seal. You cannot close a corridor behind you any more. What you can do, before anything goes
## wrong, is decide which corridor is worth keeping.
##
## WHICH IS WHY THE COST IS TIME AND NOT A COOLDOWN. There is no recharge on this at all: an
## Engineer may shore every cell it owns, one after another, for as long as nobody comes. Three
## seconds standing still, underground, doing nothing else is the entire price, and it is a real
## one -- it is three seconds of not digging, not running, and not being anywhere else, in the one
## place on the map where being caught standing still is worst. A cooldown on top would be pricing
## the same act twice, and would turn a builder into somebody waiting for a meter.
##
## MOVING CANCELS IT, AND THAT IS THE TEETH. Without that the three seconds are a formality you
## spend backing away from a fight. With it, shoring is something you do to ground you have already
## made safe -- which is what makes a Sneak finding an Engineer mid-shore a genuinely good moment
## for both of them.
##
## THE CELL YOU ARE STANDING IN, NOT THE ONE YOU AIM AT, and that is the one place this
## deliberately parts company with [Barricade] and [CaveIn]. Both of those are aimed, and section 4
## argues at length that aiming is what stops "seal the cell behind you" from being a free thing
## you do while running. That argument does not apply here, because holding still for three seconds
## already forbids running -- and aiming would add a second demand to an act whose whole shape is
## *commit to this spot*. Standing in the cell you are reinforcing is also the picture: a mouse
## bracing a roof is under the roof.
##
## A PUPPET BUILDS NOTHING (M7). It runs the same hold, draws the same progress and refuses for the
## same reasons, so the person pressing Q sees the bar fill on their own screen; what it does not
## do is write to the earth. The server's shoring arrives through `adopt_shoring` and the timbers
## come up from the same signal on both machines -- see [Shoring].

## Timbers went in. Carries the cell, so an audit can assert what a hold produced rather than
## trusting that the network's book and the ability agree.
signal shored(plane: int, cell: Vector2i)
signal refused(reason: String)

@export_group("Ability")
## The class this belongs to. Q means one thing per class and the gate is the same in all four.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.ENGINEER
## Seconds of standing still to put timbers in. **The whole balance of the ability** -- there is no
## cooldown, so this number is the only thing rationing it (see the header).
@export var seconds: float = 3.0
## How far the mouse may drift before the hold is abandoned, in metres. Not zero: a mouse standing
## on a slope or settling against a wall moves a little without anybody pressing anything, and a
## cast that cancelled on that would be a cast nobody could complete.
@export var drift: float = 0.22

## 0 while idle, rising to 1 as the timbers go in.
var _progress: float = 0.0
## Where the hold started, so drift can be measured against it rather than against last frame --
## a per-frame check passes for a mouse creeping steadily across the cell.
var _anchor: Vector3 = Vector3.ZERO
var _cell: Vector2i = Vector2i.MAX
var _cursor: DigCursor


func _ready() -> void:
	super()
	if _player == null or _network == null:
		push_warning("shore up: needs a mouse and a network -- the ability is off")
		set_physics_process(false)
		return
	refused.connect(explain)


## How far through the hold, for a HUD or an audit. 0 when nothing is being shored.
func progress() -> float:
	return _progress


## The cell a hold would put timbers in, or MAX if this mouse is not somewhere it can.
##
## NO REACH TEST, because there is no aim: the answer is the cell under the mouse's own feet or
## nothing at all. What it does check is everything that would make the timbers meaningless -- the
## surface, a cell already shored, and a shaft.
func target() -> Vector2i:
	if _player == null or _network == null or _player.get_plane() <= 0:
		return Vector2i.MAX
	var plane := _player.get_plane()
	var cell := _network.world_to_cell(_player.global_position)
	if not _network.is_dug(plane, cell) or _network.is_shored(plane, cell):
		return Vector2i.MAX
	# NEVER A SHAFT CELL, and the reason is the shaft rule rather than a worry about the picture.
	# A shaft comes down as one object, so shoring either end holds both (see
	# [method TunnelNetwork.collapse_shaft]) -- which would let an Engineer buy two cells' worth of
	# protection for one cell's worth of standing about, at the exact spot the Brute's stomp is
	# meant to be able to reach. Timbers across a ladder are also a picture of a blocked ladder.
	if _network.has_shaft_down(plane, cell) or _network.has_shaft_up(plane, cell):
		return Vector2i.MAX
	return cell


func is_ready() -> bool:
	return (
		_player != null and not _player.is_scruffed()
		and _player.mouse_class == owner_class and target() != Vector2i.MAX
	)


## READ ON THE PHYSICS TICK off the [InputFrame], like every other control -- see [Barricade] for
## why an `_unhandled_input` handler cannot survive a server.
##
## HELD RATHER THAN PRESSED, which makes this the only ability in the game that reads the ability
## key that way. The other three resolve on the press because they are instants; this one is a
## commitment, and the key being down is the commitment. A pressed bit would need a second key to
## abandon the cast, and the natural way to abandon this one is to let go and walk away.
func _physics_process(delta: float) -> void:
	if _player == null or _network == null:
		return

	# SILENT ON THE WRONG CLASS, AND BEFORE ANYTHING ELSE -- the same gate [CaveIn], [Sonar] and
	# [SecondWind] put at the top of their own handlers, and here it is a fix rather than tidiness.
	# Q belongs to all four classes; this node is fitted to every mouse and sits AFTER the other
	# three owners in `MouseControls.CONTROLS`, so a wrong-class refusal was the last thing said on
	# the frame and landed on the HUD **over the ability that had just worked**. A Brute bringing a
	# roof down was told it was not an Engineer, once per press, and so was every sonar and every
	# second wind.
	if _player.mouse_class != owner_class:
		_abandon()
		return

	var held := _player.input().is_held(InputFrame.Action.ABILITY)
	# The press is what earns a refusal out loud. Held-and-not-allowed says nothing at all, or an
	# Engineer leaning on Q out on the lawn would be told the same thing sixty times a second.
	if _player.input().is_pressed(InputFrame.Action.ABILITY):
		_explain_refusal()

	if not held or _player.is_scruffed():
		_abandon()
		return

	var cell := target()
	if cell == Vector2i.MAX:
		_abandon()
		return

	# STARTING, OR CARRYING ON. A hold that finds itself over a different cell than it started in
	# begins again there rather than crediting the walk: the three seconds are meant to be three
	# seconds in one place.
	if _cell != cell:
		_cell = cell
		_anchor = _player.global_position
		_progress = 0.0
	elif _player.global_position.distance_to(_anchor) > drift:
		refused.emit("hold still -- the timbers need setting")
		_abandon()
		return

	_progress += delta / maxf(seconds, 0.01)
	_show()
	if _progress < 1.0:
		return

	# A PUPPET FINISHES THE HOLD AND WRITES NOTHING (M7). `shore` refuses on a puppet network
	# anyway -- the guard lives on the state, which is the whole argument in `TunnelNetwork` -- so
	# this is belt and braces, and it is here so the reason is written next to the ability rather
	# than only next to the earth.
	var plane := _player.get_plane()
	if acts() and _network.shore(plane, _cell):
		Shoring.place(_network, plane, _cell)
		shored.emit(plane, _cell)
	# Said on both machines, because the hold finished on both and a completed cast that produced
	# no word would be indistinguishable from one the drift check quietly ate. What a puppet is
	# acknowledging is its own three seconds; the timbers arrive from the server a moment later.
	note("timbers in -- this roof will take one")
	_abandon()


## Say why the key did nothing, once, on the press. Ordered the way the mouse would discover them:
## where you are, then what is already here.
##
## NEVER "YOU ARE THE WRONG CLASS", and that row is gone rather than reordered. Every refusal in
## this file is spoken to somebody who pressed **their own class's key** and got nothing -- which
## is a fact about this corridor, not about them. Telling an Engineer it is an Engineer is the one
## thing the caller has already established, and telling anybody else was the bug: see the gate at
## the top of `_physics_process`.
func _explain_refusal() -> void:
	if _player.get_plane() <= 0:
		refused.emit("nothing to hold up out here")
		return
	var plane := _player.get_plane()
	var cell := _network.world_to_cell(_player.global_position)
	if _network.is_shored(plane, cell):
		refused.emit("these timbers are already in")
	elif _network.has_shaft_down(plane, cell) or _network.has_shaft_up(plane, cell):
		refused.emit("you cannot shore a shaft")


func _abandon() -> void:
	if _cell == Vector2i.MAX and _progress <= 0.0:
		return
	_progress = 0.0
	_cell = Vector2i.MAX
	_show()


## The cell filling up, drawn on the block itself -- the same cursor the dig uses, for the same
## reason: what is being described is a cubic metre of ground, and a bar near the mouse would make
## you look away from it. Its own instance rather than the dig controller's, because the two can
## never be running at once but both own their own visibility.
func _show() -> void:
	if not watched():
		if _cursor != null:
			_cursor.show_at(_network, _player.get_plane(), Vector2i.MAX, 0.0, false)
		return
	if _cursor == null:
		_cursor = DigCursor.new()
		# Timber gold rather than the dig's ember, so a cell filling with light reads as being built
		# up rather than cut away -- but at the dig cursor's SATURATION rather than at wood's. The
		# first version used the actual albedo of the props (0.72, 0.52, 0.24), which is the colour
		# of a plank and is not a colour that survives being drawn over lamplit floor.
		_cursor.digging_color = Color(0.98, 0.74, 0.24, 0.95)
		_network.add_child(_cursor)
	_cursor.show_at(_network, _player.get_plane(), _cell, _progress, _cell != Vector2i.MAX)
