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
## THE CARRIER ROW IS THE WHOLE FEATURE. The concept art gives the bottom-right to carrier
## portraits with health, and that is the right instinct expressed as furniture -- a flag pip
## next to a health bar answers "is our run going to make it" in one glance, which is the only
## question this HUD element has to answer.
##
## HEALTH BARS HERE AND ALSO OVER HEADS, deliberately, and they are not redundant. The bar over
## a mouse is about the scrap in front of you; this list is about the four fights you are NOT
## looking at. Same number, two different questions.
##
## Rows are built from the mouse group every frame rather than cached, because the roster
## genuinely changes -- bots spawn a frame late, and M7 has players joining mid-match.

@export var director_path: NodePath

@export_group("Layout")
@export var width: float = 216.0
@export var margin: float = 18.0
@export var row_height: float = 34.0
@export var row_gap: float = 4.0

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

	var head := 18.0
	var tall := head + float(crew.size()) * (row_height + row_gap) - row_gap + 16.0
	var screen := get_viewport_rect().size
	var frame := Rect2(
		Vector2(screen.x - width - margin, screen.y - tall - margin), Vector2(width, tall)
	)
	HudSkin.panel(self, frame)

	var inner := frame.grow(-8.0)
	var player := _director.get_player()
	var side := player.team if player != null else Team.BLUE
	HudSkin.text(
		self, Rect2(inner.position, Vector2(inner.size.x, head)),
		"%s CREW" % Team.name_of(side), 12, Team.color_of(side)
	)

	var y := inner.position.y + head
	for mouse in crew:
		_row(Rect2(Vector2(inner.position.x, y), Vector2(inner.size.x, row_height)), mouse, mouse == player)
		y += row_height + row_gap


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


func _row(row: Rect2, mouse: Mouse, is_player: bool) -> void:
	HudSkin.well(self, row)
	if is_player:
		# A gold edge rather than a brighter row. You need to find yourself in the list instantly,
		# and lightening the whole row would make your own health bar read as a different colour
		# from everyone else's.
		draw_rect(Rect2(row.position + Vector2(2.0, 4.0), Vector2(3.0, row.size.y - 8.0)), HudSkin.GOLD, true)

	var down := mouse.is_scruffed()
	var body := row.grow_side(SIDE_LEFT, -10.0).grow_side(SIDE_RIGHT, -8.0)
	var carried := mouse.get_carried() as Banner
	# The banner gets its own column down the right of the row rather than a pip dropped on top
	# of whatever is already there. Everything else in the row is then laid out against a width
	# that already knows about it, which is the only way two overlapping things never happen.
	var tail := 20.0 if carried != null else 0.0
	var text_width := body.size.x - tail
	var name_row := Rect2(body.position + Vector2(0.0, 2.0), Vector2(text_width, 15.0))

	HudSkin.text(
		self, name_row, mouse.get_display_name(), 14,
		HudSkin.TEXT_DIM if down else (HudSkin.GOLD if is_player else HudSkin.TEXT)
	)

	# The class tag doubles as the respawn clock. It is the same slot because they are the same
	# question -- what can this mouse do for me right now -- and nothing is lost by not knowing
	# someone's class for six seconds while they are flat on their back.
	if down:
		HudSkin.text(
			self, name_row, "DOWN %ds" % ceili(_director.respawn_left(mouse)), 12,
			HudSkin.HEALTH_LOW, HORIZONTAL_ALIGNMENT_RIGHT
		)
	else:
		HudSkin.text(
			self, name_row, MouseClass.tag_of(mouse.mouse_class), 11, HudSkin.TEXT_DIM,
			HORIZONTAL_ALIGNMENT_RIGHT
		)

	var ratio := mouse.get_health_ratio()
	var colour := HudSkin.health_color(ratio)
	if down:
		colour = Color(HudSkin.HEALTH_LOW.r, HudSkin.HEALTH_LOW.g, HudSkin.HEALTH_LOW.b, 0.45)
	HudSkin.bar(self, Rect2(body.position + Vector2(0.0, 20.0), Vector2(text_width, 6.0)), ratio, colour)

	# Whose banner, not just "a banner". On a four-crew map later it is the only thing that says
	# which run this is, and it costs nothing to be right about it now.
	if carried != null:
		HudSkin.flag(
			self, Vector2(body.end.x - 15.0, body.position.y + 26.0), 21.0,
			Team.color_of(carried.team)
		)
