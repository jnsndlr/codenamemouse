extends Control
## Health, drawn over the mouse it belongs to.
##
## SAME CONVENTION AS THE CONTEXTUAL HINT (GDD section 10, and contextual_hint.gd): information
## that is about a particular mouse right now goes above that mouse's head, not in a corner. In
## a scrap you have no attention to spend looking away, and a bar parked at the edge of the
## screen tells you someone is nearly out of health at the exact moment you are least able to
## read it.
##
## ONLY WHEN IT MATTERS. A bar over a mouse at full health is clutter -- eight of them turn the
## arena into a spreadsheet -- so a bar appears when its owner has been hurt and fades out again
## once they're whole. The player's own bar and stamina behave the same way, which means an
## untouched field is completely clean and any bar you can see is a fight in progress.
##
## Drawn immediately rather than built from nodes. It is a rectangle per wounded mouse, it
## changes every frame, and `_draw` on one Control is both less code and less garbage than a
## pool of ColorRects being reparented.

## Where on the mouse the bar hangs, in metres. Above the ears and above a carried banner would
## be too high -- this sits on the shoulders, under the pole.
const HEAD: float = 0.46

@export var director_path: NodePath

@export_group("Bar")
@export var bar_size: Vector2 = Vector2(30.0, 4.0)
## Pixels between the projected point and the bar. On top of the world-space lift, because the
## camera's pitch squashes vertical distance on screen.
@export var screen_lift: float = 16.0
## How long a bar lingers after the last damage, so you can read the result of an exchange
## rather than watching it vanish the instant it stops changing.
@export var linger_seconds: float = 3.0
@export var fade_seconds: float = 0.6

var _director: MatchDirector
## mouse -> seconds since it was last worth showing.
var _shown: Dictionary = {}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_director = get_node_or_null(director_path) as MatchDirector


func _process(delta: float) -> void:
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null:
			continue
		# Hurt, or flat on your back. Both are states somebody is about to act on.
		if mouse.get_health_ratio() < 1.0 or mouse.is_scruffed():
			_shown[mouse] = 0.0
		elif _shown.has(mouse):
			_shown[mouse] = _shown[mouse] + delta
			if _shown[mouse] > linger_seconds + fade_seconds:
				_shown.erase(mouse)
	queue_redraw()


func _draw() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var player: Mouse = _director.get_player() if _director != null else null
	# The bars over heads scale too, or they become invisible threads on a large window while the
	# panels around the edge stay legible.
	var ui := HudSkin.scale_for(get_viewport_rect().size)

	for key: Variant in _shown.keys():
		var mouse := key as Mouse
		if mouse == null or not is_instance_valid(mouse):
			_shown.erase(key)
			continue

		var head := mouse.global_position + Vector3.UP * HEAD
		# Behind the camera projects to a point that is still on screen, mirrored. Without this
		# a mouse at your back draws a bar floating over the far side of the arena.
		if camera.is_position_behind(head):
			continue

		var fade := 1.0 - clampf(
			(_shown[mouse] - linger_seconds) / maxf(fade_seconds, 0.001), 0.0, 1.0
		)
		if fade <= 0.0:
			continue

		var at := camera.unproject_position(head) - Vector2(bar_size.x * ui * 0.5, screen_lift * ui)
		_bar(at, mouse.get_health_ratio(), Team.color_of(mouse.team), fade, ui)

		# Stamina under your own bar, and only yours -- it is personal and never shown for
		# anyone else (GDD section 9).
		if mouse == player and mouse.has_method("get_stamina_ratio"):
			var stamina: float = mouse.call("get_stamina_ratio")
			if stamina < 1.0:
				_bar(
					at + Vector2(0.0, (bar_size.y + 2.0) * ui), stamina,
					Color(0.85, 0.82, 0.55), fade * 0.9, ui, bar_size.y * 0.6
				)


func _bar(
	at: Vector2, fill: float, colour: Color, alpha: float, ui: float, height: float = -1.0
) -> void:
	var tall := (bar_size.y if height < 0.0 else height) * ui
	var wide := bar_size.x * ui
	var frame := Rect2(at, Vector2(wide, tall))
	draw_rect(frame.grow(1.0 * ui), Color(0.0, 0.0, 0.0, 0.55 * alpha), true)
	draw_rect(
		Rect2(at, Vector2(wide * clampf(fill, 0.0, 1.0), tall)),
		Color(colour.r, colour.g, colour.b, alpha), true
	)
