class_name ClassSwap
extends Node
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

@export var player_path: NodePath
@export var director_path: NodePath

var _player: Mouse
var _director: MatchDirector


func _ready() -> void:
	_player = get_node_or_null(player_path) as Mouse
	_director = get_node_or_null(director_path) as MatchDirector
	if _player == null or _director == null:
		push_warning("class swap: needs a player and a director -- swapping is off")
		set_process_unhandled_input(false)


## Whether the mouse this is watching could swap right now.
##
## Scruffed is excluded deliberately, and it is the interesting exclusion: you lie where you fell
## for six seconds, and if that spot happens to be your own nest you should not be able to spend
## the wait shopping for a class. Coming back on your feet and then pressing C is the same
## action with the tempo cost the design asked for.
func available() -> bool:
	if _player == null or _director == null or not _director.is_playing():
		return false
	if _player.is_scruffed() or _player.get_plane() != 0:
		return false
	var nest := _director.nest_of(_player.team)
	return nest != null and nest.contains(_player.global_position)


## What the contextual hint should say, or "" when there is nothing on offer.
##
## Just the key. The selector bar (class_bar.gd) appears on exactly the same condition and shows
## the four cards with a pointer over the one you are, so naming the next class here as well
## would be the same fact in two places on screen -- and the one above your head would be the
## smaller, later, harder-to-read copy.
func prompt() -> String:
	return "[C]  change class" if available() else ""


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("swap_class") or not available():
		return
	_player.set_class(MouseClass.next(_player.mouse_class))
	get_viewport().set_input_as_handled()
