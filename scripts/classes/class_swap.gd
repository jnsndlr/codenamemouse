class_name ClassSwap
extends MouseControl
## The swap point: change class at your own nest, free, at the cost of the walk there.
##
## GDD SECTION 4 IS SPECIFIC ABOUT THE PRICE. Adaptation is always possible and never
## resource-gated -- it costs **time and position**, never cheese. So there is no cooldown here,
## no charge and no limit; there is a place, and that place is the far end of the arena from
## wherever the fight is. Composition-as-strategy survives, and a crew can answer a Brute
## holding a corridor by going home and coming back as something that beats it.
##
## THE NEST IS THE POINT, not a prop in it. The rule is "you are inside your own nest", asked of
## the nest itself (`Nest.contains`), which means it is automatically the same disc that a
## capture needs and the same one a respawn puts you on. A separate swap-point object placed by
## hand would immediately drift away from all three, and a swap zone that is not quite the
## capture zone is a bug you only find by playing.
##
## ONE KEY, CYCLING. Four bindings for four classes would need memorising and would go stale the
## moment a fifth exists; at the nest you are stationary and safe, so pressing C twice to skip
## past the Brute costs nothing. The prompt says what you would become next, so the cycle is
## legible without knowing the order.
##
## RESPAWNING IS ALREADY COVERED, and that is not an accident. GDD section 4 also makes a switch
## free on respawn -- and a respawn puts you at your own nest, which is where this works. There
## is no second mechanism.
##
## BOTS OBEY THE SAME RULE, through `allowed` below rather than through a copy of it. This node is
## the player's input handler and a bot has no input, but WHERE a class change is legal is not an
## input question -- it is a rule, and the moment it exists twice the two copies start to differ.
## A bot that could re-spec mid-corridor would be a bot playing a different game.
##
## ONE PER MOUSE SINCE M7, not one per arena. See [MouseControl]. The director is inherited from
## there and found by group rather than wired, because a mouse spawned into a chair at runtime has
## no scene to have been wired in.

@export var director_path: NodePath


func _ready() -> void:
	super()
	if not director_path.is_empty():
		_director = get_node_or_null(director_path) as MatchDirector
	if _player == null:
		push_warning("class swap: needs a mouse to swap -- swapping is off")
		set_physics_process(false)


## Whether ANY mouse may change class where it is standing. The rule, in one place.
##
## Scruffed is excluded deliberately, and it is the interesting exclusion: you lie where you fell
## for six seconds, and if that spot happens to be your own nest you should not be able to spend
## the wait shopping for a class. Coming back on your feet and then pressing C is the same
## action with the tempo cost the design asked for.
static func allowed(mouse: Mouse, director: MatchDirector) -> bool:
	if mouse == null or director == null or not director.is_playing():
		return false
	if mouse.is_scruffed() or mouse.get_plane() != 0:
		return false
	var nest := director.nest_of(mouse.team)
	return nest != null and nest.contains(mouse.global_position)


## Whether the mouse this node is fitted to could swap right now.
func available() -> bool:
	return allowed(_player, director())


## What the contextual hint should say, or "" when there is nothing on offer.
##
## Just the key. The selector bar (class_bar.gd) appears on exactly the same condition and shows
## the four cards with a pointer over the one you are, so naming the next class here as well
## would be the same fact in two places on screen -- and the one above your head would be the
## smaller, later, harder-to-read copy.
func prompt() -> String:
	return "[C]  change class" if available() else ""


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
## A CLIENT ASKS AND WAITS, with no local guess (M7). This is the one control with nothing to
## predict: a swap is instantaneous, the new class rides in the very next pose -- two spare bits of
## the flag byte, see `snapshot.gd` -- and a client that swapped itself would be re-typing the
## mouse a thirtieth of a second before being told the same thing, or, on the run where the server
## refused, a thirtieth of a second before being told something else.
func _physics_process(_delta: float) -> void:
	if _player == null or not acts():
		return
	if not _player.input().is_pressed(InputFrame.Action.SWAP_CLASS) or not available():
		return
	_player.set_class(MouseClass.next(_player.mouse_class))
