extends Control
## The score bug: both scores, the clock, both banners and both crews' cheese, as one object.
##
## ONE PANEL, NOT FOUR READOUTS. The concept art draws the score and the cheese stores as
## separate furniture in different corners, and that is the version that doesn't work: cheese is
## lives (GDD section 2), so "how are we doing" is a question about the score, the clock and the
## stores at once, and answering it should not cost three glances across the screen. Joining them
## also puts the two numbers next to each other that are most often traded against one another --
## you are three captures from winning and four scruffs from empty, and that is one thought.
##
## LAYOUT IS MIRRORED, so the two scores flank the clock and read as "2 - 1" rather than as two
## unrelated numbers. Crew names sit on the outer edges, cheese under each score, and each crew's
## own banner sits next to its own score.
##
## THE BANNER IS A GLYPH, NOT A SENTENCE. Home is a solid flag, stolen pulses, dropped goes dim.
## Three states you read without reading, which matters because this is the one piece of match
## state that changes while you are busy. The words -- and the return countdown, which is a real
## decision for both crews -- go in a strip under the bug that only exists while something is
## actually wrong. When both banners are home there is nothing to say and the strip is not there.
##
## Drawn rather than assembled from nodes, like the rest of the HUD. See hud_skin.gd.

@export var director_path: NodePath

@export_group("Layout")
@export var width: float = 452.0
@export var height: float = 98.0
@export var top_margin: float = 12.0
## How much of the middle the clock takes. The rest is split between the two crews.
@export var clock_width: float = 124.0

@export_group("Feel")
## How long the cheese well flashes when a crew spends one. GDD section 10 asks for a hard,
## unmissable tick the moment it happens -- the point of a life costing something is that the
## whole team sees it go.
@export var flash_seconds: float = 1.1
## Below this many seconds the clock starts pulsing. Late enough to mean something.
@export var clock_urgent: float = 30.0

var _director: MatchDirector
## Per side, 1 falling to 0 after a spend.
var _flash: Array[float] = [0.0, 0.0]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_director = get_node_or_null(director_path) as MatchDirector
	if _director == null:
		push_warning("score bug: no director at %s" % director_path)
		return
	_director.cheese_changed.connect(_on_cheese_changed)


func _on_cheese_changed(side: int, _amount: int) -> void:
	_flash[side] = 1.0


func _process(delta: float) -> void:
	for side in range(_flash.size()):
		_flash[side] = maxf(0.0, _flash[side] - delta / maxf(flash_seconds, 0.001))
	queue_redraw()


func _draw() -> void:
	if _director == null:
		return

	var screen := get_viewport_rect().size
	var frame := Rect2(Vector2((screen.x - width) * 0.5, top_margin), Vector2(width, height))
	HudSkin.panel(self, frame)

	var inner := frame.grow(-9.0)
	var side_width := (inner.size.x - clock_width) * 0.5
	_crew(Rect2(inner.position, Vector2(side_width, inner.size.y)), Team.BLUE)
	_crew(
		Rect2(inner.position + Vector2(side_width + clock_width, 0.0), Vector2(side_width, inner.size.y)),
		Team.RED
	)
	_clock(Rect2(inner.position + Vector2(side_width, 0.0), Vector2(clock_width, inner.size.y)))
	_status(frame)


## One crew's column: name, banner, score, stores.
##
## `outward` is the whole mirroring rule in one variable -- which way this column's contents lean
## and which edge is its own.
func _crew(cell: Rect2, side: int) -> void:
	var colour := Team.color_of(side)
	var blue := side == Team.BLUE
	var outward := HORIZONTAL_ALIGNMENT_LEFT if blue else HORIZONTAL_ALIGNMENT_RIGHT
	var inward := HORIZONTAL_ALIGNMENT_RIGHT if blue else HORIZONTAL_ALIGNMENT_LEFT

	HudSkin.text(self, Rect2(cell.position, Vector2(cell.size.x, 17.0)), Team.name_of(side), 14, colour, outward)

	var score_row := Rect2(cell.position + Vector2(0.0, 15.0), Vector2(cell.size.x, 40.0))
	HudSkin.text(self, score_row, str(_director.score_of(side)), 34, HudSkin.GOLD, inward)

	# The banner on the outer edge, so the two glyphs sit at the ends of the bug and a change in
	# either is visible in peripheral vision rather than next to a number you are reading.
	var flag_x := cell.position.x + 4.0 if blue else cell.end.x - 22.0
	_banner_glyph(Vector2(flag_x, score_row.end.y - 4.0), _director.banner_of(side), colour)

	# Narrower than the column and pushed to the outer edge: a well as wide as the score above it
	# reads as an empty field somebody forgot to fill in.
	var stores_width := 96.0
	var stores_x := cell.position.x if blue else cell.end.x - stores_width
	_stores(Rect2(Vector2(stores_x, cell.position.y + 58.0), Vector2(stores_width, 22.0)), side, blue)


## Home is solid, stolen breathes, dropped is dim. Nothing here spells the state out -- the strip
## under the bug does that, and only when there is something to say.
func _banner_glyph(foot: Vector2, banner: Banner, colour: Color) -> void:
	var shade := colour
	match banner.state:
		Banner.CARRIED:
			shade.a = lerpf(0.35, 1.0, HudSkin.pulse(3.2))
		Banner.DROPPED:
			shade = colour.lerp(Color(0.5, 0.48, 0.45), 0.55)
			shade.a = 0.75
		_:
			shade.a = 1.0
	HudSkin.flag(self, foot, 30.0, shade)


## The stores. A wedge and a number, because a bare number next to a score reads as a second
## score, and the wedge is the whole of the difference.
func _stores(row: Rect2, side: int, blue: bool) -> void:
	HudSkin.well(self, row)

	var flash := _flash[side]
	if flash > 0.0:
		# Squared, so the tick is a hit rather than a slow glow.
		self.draw_rect(row, Color(1.0, 0.92, 0.72, 0.42 * flash * flash), true)

	var count := _director.cheese_of(side)
	var colour := HudSkin.GOLD.lerp(Color(1, 1, 1), flash)
	if count <= 0:
		colour = HudSkin.HEALTH_LOW
	var wedge_x := row.position.x + 6.0 if blue else row.end.x - 22.0
	HudSkin.cheese(self, Vector2(wedge_x, row.position.y + 4.0), 14.0)
	HudSkin.text(
		self, row.grow_side(SIDE_LEFT, -26.0).grow_side(SIDE_RIGHT, -26.0), str(count), 17, colour,
		HORIZONTAL_ALIGNMENT_LEFT if blue else HORIZONTAL_ALIGNMENT_RIGHT
	)


func _clock(cell: Rect2) -> void:
	HudSkin.text(self, Rect2(cell.position, Vector2(cell.size.x, 16.0)), "TIME", 12, HudSkin.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)

	var well := Rect2(cell.position + Vector2(4.0, 16.0), Vector2(cell.size.x - 8.0, 38.0))
	HudSkin.well(self, well)

	var left := _director.time_left()
	var colour := HudSkin.TEXT
	if not _director.is_playing():
		colour = HudSkin.TEXT_DIM
	elif left <= clock_urgent:
		colour = HudSkin.TEXT.lerp(HudSkin.HEALTH_LOW, 0.4 + 0.6 * HudSkin.pulse(4.0))
	HudSkin.text(self, well, _as_clock(left), 26, colour, HORIZONTAL_ALIGNMENT_CENTER)

	# First to three, under the clock. The score alone doesn't say what winning is, and a match
	# whose finish line you have to be told once is a match you explain to every new player.
	HudSkin.text(
		self, Rect2(cell.position + Vector2(0.0, 56.0), Vector2(cell.size.x, 22.0)),
		"FIRST TO %d" % _director.capture_limit, 11, HudSkin.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER
	)


## The strip under the bug, which exists only while a banner is away from its nest.
##
## THE COUNTDOWN IS THE POINT. A dropped banner is a decision for both crews -- sprint for it or
## let it return -- and neither crew can make that call without the number. It is the one piece
## of match state that is invisible from looking at the field.
func _status(frame: Rect2) -> void:
	var parts: Array[String] = []
	for side in [Team.BLUE, Team.RED]:
		var banner := _director.banner_of(side)
		if banner.state == Banner.AT_NEST:
			continue
		var who := "OURS" if side == Team.BLUE else "THEIRS"
		if banner.state == Banner.CARRIED:
			parts.append("%s STOLEN" % who)
		else:
			parts.append("%s DOWN %ds" % [who, ceili(banner.return_countdown())])
	if parts.is_empty():
		return

	# Terse on purpose. The flags directly above say which banner is which, and a strip long
	# enough to spell it out runs into the permanent bindings in the top-left corner.
	var body := "   ".join(parts)
	var size := HudSkin.measure(body, 14)
	var strip := Rect2(
		Vector2(frame.get_center().x - size.x * 0.5 - 16.0, frame.end.y + 3.0),
		Vector2(size.x + 32.0, 26.0)
	)
	HudSkin.panel(self, strip, 6.0)
	HudSkin.text(self, strip, body, 14, HudSkin.GOLD, HORIZONTAL_ALIGNMENT_CENTER)


func _as_clock(seconds: float) -> String:
	var whole := int(ceilf(seconds))
	return "%d:%02d" % [whole / 60, whole % 60]
