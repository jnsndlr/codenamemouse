class_name CaveIn
extends Node
## The Engineer's capability: bring a tunnel down on the cell you are looking at.
##
## PILLAR 4, RELOCATED. GDD section 4 used to give the Engineer terrain alteration outright --
## "nobody else alters terrain" -- and that turned out to be the wrong lever, because it makes
## one seat a requirement rather than a choice. Everyone digs now. What nobody else can do is
## **un**-dig, and that is a better unique capability anyway: making a tunnel is something you do
## slowly, in your own time, for yourself; unmaking one is something you do *at* somebody.
##
## AIMED, NOT AUTOMATIC. The obvious reading of "cave in behind you" is to seal the cell you just
## left, automatically, while fleeing. It is aimed with the cursor instead, at any adjacent cell,
## and that is deliberate: the cursor is the steering wheel (GDD section 9), so sealing the way
## you came means turning to look at it, which means not running for a moment. That is exactly
## the trade section 9 asks for elsewhere -- "turning to throw while fleeing is a real trade
## rather than a free action" -- and it is what stops this being a free escape button. It also
## costs nothing to explain: you already point at a tile to dig one.
##
## ADJACENT ONLY. A one-cell reach, which is a much shorter arm than digging's 2.6, because the
## thing being removed can have a mouse standing in it. Collapsing something across the room
## would be an execution at range.
##
## MICE CAUGHT INSIDE ARE SCRUFFED (GDD section 3). Not killed -- nothing in this game is --
## and, notably, this is the only way to scruff somebody that has no facing check and no arc.
## Standing in the wrong cell is the whole counterplay, which is why the reach is one tile and
## the cooldown is long enough to see coming.
##
## NUMBERS LIVE HERE, not in an AbilityDefinition resource, and that is on purpose for exactly
## one more ability. The plan sketches `AbilityDefinition` and it is the right shape -- the day
## Barricade lands there are two things sharing a cooldown, a cast time and a cheese cost, and it
## should be built then, from two real examples rather than from one and a guess.

## Emitted whichever way it goes, so the HUD can say what happened without this file knowing
## there is a HUD. Refusals matter as much as successes: a key that silently does nothing is
## indistinguishable from a key that is broken.
signal collapsed(plane: int, cell: Vector2i)
signal refused(reason: String)

@export var player_path: NodePath
@export var network_path: NodePath

@export_group("Ability")
## Which class may do this. An export rather than a hard-coded check, because "who owns this
## capability" is a design question and the answer has already moved once.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.ENGINEER
## Seconds between uses. Long: this removes a piece of the map, and the counterplay to it is
## seeing that the Engineer has just used it.
@export var cooldown: float = 6.0
## How far the aimed cell may be, in cells. One -- see the header.
@export var reach_cells: float = 1.6

var _player: Mouse
var _network: TunnelNetwork
var _cooldown_left: float = 0.0
var _cursor: CollapseCursor


func _ready() -> void:
	_player = get_node_or_null(player_path) as Mouse
	_network = get_node_or_null(network_path) as TunnelNetwork
	if _player == null or _network == null:
		push_warning("cave-in: needs a player and a network -- the ability is off")
		set_process(false)
		set_process_unhandled_input(false)
		return
	# Refusals go out on the network's existing "say why" channel rather than a second one. That
	# signal is named for digging but it is really the one line on screen that explains a control
	# that just did nothing, and a refused cave-in is exactly that -- see depth_indicator.gd.
	refused.connect(_network.dig_refused.emit)

	# Parented to the network, like the dig cursor, so it moves with the tunnels rather than with
	# this node -- which is a plain Node with no transform of its own.
	_cursor = CollapseCursor.new()
	_network.add_child(_cursor)


func _process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_show_reach()


## Light up the cell this would bring down.
##
## Only for the class that can do it. A box following every mouse that walks through a corridor
## would be noise, and worse, it would promise a capability three of the four do not have -- the
## class gate is the whole of Pillar 4 for the Engineer and the world should say so.
func _show_reach() -> void:
	if _cursor == null:
		return
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


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ability"):
		return
	if _player == null or _player.is_scruffed():
		return

	# Q is the primary CLASS ability, not a global cave-in button. Other classes leave the event
	# untouched so their own ability node can claim it (the Sneak's Sonar is the first).
	if _player.mouse_class != owner_class:
		return
	if _player.get_plane() <= 0:
		refused.emit("nothing to bring down up here")
		return
	if _cooldown_left > 0.0:
		refused.emit("still clearing the last one -- %ds" % ceili(_cooldown_left))
		return

	var cell := target()
	if cell == Vector2i.MAX:
		refused.emit("point at the tunnel beside you")
		return

	var plane := _player.get_plane()
	if not _network.collapse(plane, cell):
		return

	_bury(plane, cell)
	_cooldown_left = cooldown
	collapsed.emit(plane, cell)
	get_viewport().set_input_as_handled()


## Everyone standing in the cell as it comes down (GDD section 3).
##
## Credited to the Engineer, which matters for the feed and for anything that later counts who
## did what -- a cave-in is a kill you earned, not an act of God. The damage is deliberately
## enormous rather than exact: this is a roof landing on you, and a Brute surviving it on high
## health would read as the mechanic being broken rather than as the Brute being tough.
func _bury(plane: int, cell: Vector2i) -> void:
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or mouse.is_scruffed() or mouse.get_plane() != plane:
			continue
		if _network.world_to_cell(mouse.global_position) != cell:
			continue
		mouse.take_hit(9999.0, mouse.global_position, 0.0, _player)
