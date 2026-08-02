extends Label
## THE HOME FOR CONTEXTUAL CONTROL HINTS: a line of text floating just above the mouse's head.
##
## This is a convention, not a one-off. Every prompt that is true only right here and right now
## -- "[E] climb up" on a shaft, and whatever comes after it: opening a cache, hauling a body,
## boarding a rat -- belongs in this spot. It follows the same reasoning the GDD (section 10)
## already applies to sprint stamina: personal, moment-to-moment information goes near the
## mouse rather than parked in a corner, so you read it without looking away from where you
## are. In a chase you have no attention to spend on a glance at the HUD.
##
## Permanent bindings are the opposite kind of information and stay in the corner with the
## depth readout. The E prompt started life appended to that list and was unreadable there: a
## hint that is true on one tile out of a thousand cannot share a line with six that are always
## true, or it reads as more background text and you walk over the hole.
##
## SCREEN SPACE, projected from the mouse's position, rather than a Label3D in the world. A
## shaft's mouth sits under the earth lid of the plane above, so world-space text would be
## occluded by exactly the ground you are being told you can climb through -- the same trap the
## dig cursor fell into. Projecting keeps the text anchored to the mouse and always legible.

## Where on the mouse the text hangs from, in metres above its origin. The body capsule is
## 0.4 tall, so this clears the ears.
const HEAD: float = 0.5

@export var network_path: NodePath
@export var player_path: NodePath
## The swap point, if this map has one. Optional: it owns the rule about whether a class change
## is on offer, and this file only asks. Leaving it unwired costs the prompt, not the feature.
@export var swap_path: NodePath
## Optional Sneak sonar. Used only for the nearby enemy-cant prompt; the ability works without
## the HUD knowing about it.
@export var sonar_path: NodePath
## Clearance between the projected point and the bottom of the text, in pixels. On top of the
## world-space lift, because the camera's pitch squashes vertical distance on screen and the
## lift alone lands the text on the mouse's back.
@export var screen_lift: float = 22.0
## Keeps the hint off the very edge when the mouse is against the side of the screen.
@export var margin: float = 12.0
## How fast the prompt breathes. Slow: a prompt that flashes reads as an alarm.
@export var pulse_speed: float = 2.6

var _network: TunnelNetwork
var _player: Node3D
var _swap: ClassSwap
var _sonar: Sonar
var _showing: float = 0.0


func _ready() -> void:
	_network = get_node_or_null(network_path) as TunnelNetwork
	_player = get_node_or_null(player_path) as Node3D
	_swap = get_node_or_null(swap_path) as ClassSwap
	_sonar = get_node_or_null(sonar_path) as Sonar
	text = ""
	modulate.a = 0.0


func _process(delta: float) -> void:
	if _network == null or _player == null:
		return

	var wanted := _hint()
	if wanted != text:
		text = wanted
		_showing = 0.0
	if text.is_empty():
		modulate.a = 0.0
		return

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		modulate.a = 0.0
		return

	# The prompt scales with the rest of the HUD. It is a Label rather than drawn text, so this is
	# a font size rather than a multiplier, but it is the same number everything else uses.
	var ui := HudSkin.scale_for(get_viewport_rect().size)
	if label_settings != null and label_settings.font_size != int(26.0 * ui):
		label_settings.font_size = int(26.0 * ui)
		label_settings.outline_size = maxi(4, int(8.0 * ui))

	# Sized to the text before it is placed, because the position is derived from the width --
	# left at the node's authored rect it would be centred on the label, not on the mouse.
	reset_size()
	var anchor := camera.unproject_position(_player.global_position + Vector3.UP * HEAD)
	var edge := get_viewport_rect().size - size - Vector2(margin, margin)
	position = (anchor - Vector2(size.x * 0.5, size.y + screen_lift)).clamp(
		Vector2(margin, margin), Vector2(maxf(edge.x, margin), maxf(edge.y, margin))
	)

	# Fade in over roughly a fifth of a second, then breathe. Stepping onto a shaft should feel
	# like something arriving, not like a line of text blinking into existence.
	_showing += delta
	modulate.a = minf(_showing * 5.0, 1.0) * (0.82 + 0.18 * sin(_showing * pulse_speed))


## What the mouse could do where it is standing, or "" for nothing.
##
## THE RANKING, which is what this function is for. The screen has room for one line above the
## mouse's head, so two things being true at once resolves to the more urgent rather than
## stacking. A shaft outranks the swap point because a shaft is a way OUT and you may be being
## chased through it, while the swap point is at your own nest and will still be there in a
## second -- and because standing on a shaft in your own nest is otherwise a prompt that flickers
## between two offers.
func _hint() -> String:
	var plane := _network.plane_at_height(_player.global_position.y)
	var here := _network.world_to_cell(_player.global_position)
	# Down first. The no-stacking rule in _shaft_refusal means a cell can never have both, so
	# the order is a formality -- but it is the order that would matter if that rule ever went.
	if _network.has_shaft_down(plane, here):
		return "[E]  climb down"
	if _network.has_shaft_up(plane, here):
		return "[E]  climb up"
	if _sonar != null and _sonar.can_erase_enemy_mark():
		return "[Q]  erase enemy cant"
	# UNDER PAVING (GDD section 3), and the only line here that is a refusal rather than an offer.
	# It belongs in this slot anyway: a no-surface zone is a rule you meet by pressing R and being
	# told no, and finding out you are committed at the moment you wanted out is finding out too
	# late. It stays up for the whole crossing, which is the point -- the information is the
	# moment it CLEARS, because that is where you can come up.
	#
	# Plane 1 only. Deeper down there is nothing above you but more earth, and "no way up" would
	# be true everywhere and therefore say nothing.
	if plane == 1 and _network.is_sealed(here):
		return "paving overhead  --  no way up"
	if _swap != null:
		return _swap.prompt()
	return ""
