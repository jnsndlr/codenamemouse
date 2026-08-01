class_name CollapseCursor
extends Node3D
## Which cell a cave-in would land on, and whether it would go off.
##
## THE BOX IS THE WHOLE THING. This started out also outlining every cell in reach, on the theory
## that "which ones could I have picked" was worth answering as well as "which one am I on". In a
## corridor that reads fine; in a chamber it is a bright frame around every tile on screen, and the
## grid it draws pulls the eye harder than the mouse standing in the middle of it. The box on the
## aimed cell answers the question that actually matters and answers it in the one place you are
## already looking, so the rest was noise dressed up as help.
##
## THE DIG CURSOR'S OWN SHADER, because the question -- "this cubic metre of ground, right here" --
## is the same one, and a second implementation of it would be a second thing to keep in step with
## `wall_height`.
##
## COLOUR CARRIES READINESS. Warm means the ability will fire; cold means it is still cooling, and
## the cell is still drawn rather than hidden, because "where would this land" does not stop being
## a useful question while you wait. That puts the cooldown in the world rather than only in a line
## of HUD text.

## The aimed cell when the ability is ready.
@export var ready_color: Color = Color(1.00, 0.34, 0.10, 0.95)
## The same cell while it cools. Desaturated rather than merely dimmer: at a glance the difference
## between "hot" and "not yet" should be hue, because brightness is already saying how far the
## lamps reach.
@export var cooling_color: Color = Color(0.42, 0.62, 0.74, 0.80)

var _box: DigCursor


func _ready() -> void:
	_box = DigCursor.new()
	_box.hover_color = ready_color
	_box.digging_color = ready_color
	_box.blocked_color = cooling_color
	add_child(_box)


## Show the cell the cave-in would take, or hide on Vector2i.MAX -- which is what standing on the
## lawn, playing anything but an Engineer, or pointing at solid earth all look like.
func show_target(network: TunnelNetwork, plane: int, cell: Vector2i, is_ready: bool) -> void:
	if cell == Vector2i.MAX:
		_box.visible = false
		return
	if is_ready:
		_box.show_at(network, plane, cell, 0.0, false)
	else:
		_box.show_blocked(network, plane, cell)
