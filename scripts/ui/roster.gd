extends Control
## Your crew, one row each: who they are, what they're playing, how hurt they are, and whether
## they have the banner.
##
## YOUR CREW ONLY. The enemy's health is not something you should be able to read off a corner
## of the screen -- that is what the bar over their head is for, and it only appears once you
## have actually hit them (vitals.gd). What the roster is for is the decision you cannot make by
## looking at the yard: whether the mouse who just took their banner is at full health and worth
## escorting, or is about to be scruffed on the way home and needs someone to trade with.
##
## A PORTRAIT PER ROW, because a list of four names is a list you have to read, and a row of four
## faces is one you recognise. One face per class for now -- the Engineer and the Sneak are the
## same mouse in different headgear -- which is exactly as far as a placeholder should go. The
## drawing lives in `_portrait` and nowhere else, so the day there is real art it becomes a
## texture lookup and this file loses forty lines and changes in no other way. Per-mouse
## customisation, if it happens, is an M10 idea and wants the same seam.
##
## HEALTH IN SEGMENTS, not a sliding bar. On a roster the question is "how many more hits", which
## is a number, and a chunk going dark is visible across the room where three pixels of a bar is
## not. The chunks are the crew's colour while everyone is fine and degrade to amber and red as
## they are hurt -- the colour is doing the "how bad" job, the count is doing the "how much".
##
## HEALTH BARS HERE AND ALSO OVER HEADS, deliberately, and they are not redundant. The bar over
## a mouse is about the scrap in front of you; this list is about the fights you are NOT looking
## at. Same number, two different questions.
##
## Every size below is written against a 1280x720 window and multiplied by HudSkin.scale_for on
## the way out, so the panel is the same fraction of the screen whatever the window is doing.

@export var director_path: NodePath

@export_group("Layout")
@export var width: float = 268.0
@export var margin: float = 18.0
@export var row_height: float = 54.0
@export var row_gap: float = 6.0
## How many chunks a full health bar has.
@export var health_segments: int = 6


@export_group("Portrait")
## Fur, and the darker tone the ears and muzzle are picked out in.
@export var fur: Color = Color(0.62, 0.61, 0.63)
@export var fur_shade: Color = Color(0.44, 0.43, 0.46)
@export var ear_inner: Color = Color(0.86, 0.66, 0.68)

var _director: MatchDirector


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_director = get_node_or_null(director_path) as MatchDirector


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if _director == null:
		return
	var crew := _crew()
	if crew.is_empty():
		return

	var screen := get_viewport_rect().size
	var s := HudSkin.scale_for(screen)
	var row := row_height * s
	var gap := row_gap * s
	var head := 30.0 * s
	var pad := 10.0 * s

	var tall := head + float(crew.size()) * (row + gap) - gap + pad * 2.0
	var frame := Rect2(
		Vector2(screen.x - width * s - margin * s, screen.y - tall - margin * s),
		Vector2(width * s, tall)
	)
	HudSkin.panel(self, frame, 12.0 * s)

	var inner := frame.grow(-pad)
	var player := _director.get_player()
	var side := player.team if player != null else Team.BLUE
	HudSkin.text(
		self, Rect2(inner.position, Vector2(inner.size.x, head)),
		"%s TEAM" % Team.name_of(side), int(19.0 * s), Team.color_of(side).lerp(Color(1, 1, 1), 0.35)
	)

	var y := inner.position.y + head
	for mouse in crew:
		_row(Rect2(Vector2(inner.position.x, y), Vector2(inner.size.x, row)), mouse, mouse == player, s)
		y += row + gap


## The player first, then everyone else by name. Sorted rather than left in tree order because
## rows that reshuffle when a bot respawns are rows you have to re-read every time.
func _crew() -> Array[Mouse]:
	var player := _director.get_player()
	var side := player.team if player != null else Team.BLUE
	var found: Array[Mouse] = []
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse != null and mouse.team == side and mouse != player:
			found.append(mouse)
	found.sort_custom(func(a: Mouse, b: Mouse) -> bool:
		return a.get_display_name() < b.get_display_name()
	)
	if player != null:
		found.push_front(player)
	return found


func _row(row: Rect2, mouse: Mouse, is_player: bool, s: float) -> void:
	var down := mouse.is_scruffed()
	if is_player:
		# A gold edge rather than a brighter row. You need to find yourself in the list instantly,
		# and lightening the whole row would make your own health bar read as a different colour
		# from everyone else's.
		draw_rect(
			Rect2(row.position + Vector2(0.0, 2.0 * s), Vector2(3.0 * s, row.size.y - 4.0 * s)),
			HudSkin.GOLD, true
		)

	var face := row.size.y
	var portrait := Rect2(row.position + Vector2(7.0 * s, 0.0), Vector2(face, face))
	_portrait(portrait, mouse.mouse_class, down)

	var body := Rect2(
		Vector2(portrait.end.x + 9.0 * s, row.position.y),
		Vector2(row.end.x - portrait.end.x - 9.0 * s, row.size.y)
	)
	# The banner gets its own column down the right of the row rather than a pip dropped on top
	# of whatever is already there, so everything else is laid out against a width that already
	# knows about it.
	var carried := mouse.get_carried() as Banner
	var tail := 22.0 * s if carried != null else 0.0
	var text_width := body.size.x - tail
	var name_row := Rect2(body.position + Vector2(0.0, 4.0 * s), Vector2(text_width, 21.0 * s))

	HudSkin.text(
		self, name_row, mouse.get_display_name(), int(18.0 * s),
		HudSkin.TEXT_DIM if down else (HudSkin.GOLD if is_player else HudSkin.TEXT)
	)

	# The class tag doubles as the respawn clock. Same slot because they are the same question --
	# what can this mouse do for me right now -- and nothing is lost by not knowing someone's
	# class for six seconds while they are flat on their back.
	if down:
		HudSkin.text(
			self, name_row, "DOWN %ds" % ceili(_director.respawn_left(mouse)), int(14.0 * s),
			HudSkin.HEALTH_LOW, HORIZONTAL_ALIGNMENT_RIGHT
		)
	else:
		HudSkin.text(
			self, name_row, MouseClass.tag_of(mouse.mouse_class), int(13.0 * s),
			HudSkin.TEXT_DIM, HORIZONTAL_ALIGNMENT_RIGHT
		)

	var ratio := mouse.get_health_ratio()
	HudSkin.segments(
		self, Rect2(body.position + Vector2(0.0, 30.0 * s), Vector2(text_width, 12.0 * s)),
		ratio, _health_color(ratio, mouse.team, down), health_segments, 2.0 * s
	)

	# Whose banner, not just "a banner". On a four-crew map later it is the only thing that says
	# which run this is, and it costs nothing to be right about it now.
	if carried != null:
		HudSkin.flag(
			self, Vector2(body.end.x - 15.0 * s, body.position.y + row.size.y * 0.78),
			24.0 * s, Team.color_of(carried.team)
		)


## The crew's colour while they are fine, then amber, then red.
##
## Team colour at full is what makes the row read as YOUR crew at a glance; the degrade is what
## makes it read as a fight. A bar that stayed blue all the way to zero would look identical at
## the two moments you most need to tell apart.
func _health_color(ratio: float, side: int, down: bool) -> Color:
	if down:
		return Color(HudSkin.HEALTH_LOW.r, HudSkin.HEALTH_LOW.g, HudSkin.HEALTH_LOW.b, 0.4)
	if ratio > 0.6:
		return Team.color_of(side).lerp(Color(1, 1, 1), 0.15)
	return HudSkin.HEALTH_HURT if ratio > 0.3 else HudSkin.HEALTH_LOW


## A mouse, in a box. PLACEHOLDER, and the seam where real art arrives: one call, one rect, one
## class, so a texture per class slots in here and nothing else in this file changes.
##
## Built from circles because a mouse at forty pixels is two ears and a nose, and anything more
## detailed is mud. The class shows in the headgear rather than in the face -- four differently
## shaped mice would need four sets of proportions to get wrong, and the point of the row is that
## you recognise a crewmate, not that you appraise their anatomy.
func _portrait(box: Rect2, kind: int, down: bool) -> void:
	HudSkin.well(self, box, 6.0)
	var mid := box.get_center()
	var r := box.size.y * 0.29
	var coat := fur if not down else fur.lerp(Color(0.25, 0.25, 0.28), 0.55)
	var shade := fur_shade if not down else fur_shade.lerp(Color(0.2, 0.2, 0.22), 0.55)

	# Ears first, so the head overlaps them and they read as behind it.
	for side in [-1.0, 1.0]:
		var ear := mid + Vector2(side * r * 0.92, -r * 0.86)
		draw_circle(ear, r * 0.52, shade)
		draw_circle(ear, r * 0.30, Color(ear_inner.r, ear_inner.g, ear_inner.b, coat.a))

	draw_circle(mid, r, coat)
	# Muzzle, offset toward the camera-left so the face has a direction rather than staring out.
	draw_circle(mid + Vector2(-r * 0.36, r * 0.34), r * 0.46, coat.lerp(Color(1, 1, 1), 0.18))
	draw_circle(mid + Vector2(-r * 0.72, r * 0.42), r * 0.14, Color(0.86, 0.55, 0.58, coat.a))
	# One eye. Two at this size, at this spacing, reads as a frog.
	draw_circle(mid + Vector2(-r * 0.06, r * 0.02), r * 0.16, Color(0.09, 0.08, 0.10, coat.a))

	_headgear(box, kind, mid, r, down)


## What tells the four classes apart at a glance. Deliberately the same trick the class bar uses,
## so the wrench on the selector and the wrench on the portrait are the same idea.
func _headgear(box: Rect2, kind: int, mid: Vector2, r: float, down: bool) -> void:
	var tint := Color(0.80, 0.84, 0.92) if not down else Color(0.45, 0.45, 0.48)
	match kind:
		MouseClass.ENGINEER:
			# A cap with a brim, sat over the ears.
			draw_rect(Rect2(mid - Vector2(r * 1.05, r * 1.32), Vector2(r * 2.1, r * 0.62)), tint)
			draw_rect(Rect2(mid - Vector2(r * 1.5, r * 0.78), Vector2(r * 1.3, r * 0.26)), tint)
		MouseClass.SNEAK:
			# A hood: a dark arc over the top of the head.
			draw_arc(mid, r * 1.14, PI, TAU, 16, Color(0.20, 0.24, 0.32), r * 0.52)
		MouseClass.BRUTE:
			# A band across the brow. Blunt, like the class.
			draw_rect(Rect2(mid - Vector2(r * 1.02, r * 0.66), Vector2(r * 2.04, r * 0.34)), Color(0.72, 0.35, 0.28))
		_:
			# The Generalist gets nothing, which is how you know it is the Generalist.
			pass
