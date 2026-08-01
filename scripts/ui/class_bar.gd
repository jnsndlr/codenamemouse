extends Control
## The class selector: four cards, an icon each, the one you are lit up.
##
## ONLY AT THE SWAP POINT. It slides in when you are standing in your own nest and goes away when
## you leave, because that is precisely when the choice exists (GDD section 4) and a permanent
## bar of four classes you cannot pick is furniture that teaches you the wrong thing. It asks
## class_swap.gd whether it is on offer rather than re-deriving the rule -- one rule, one owner.
##
## ICONS ARE DRAWN, NOT IMPORTED, like everything else on this HUD. Four little shapes -- shield,
## wrench, hood, hammer -- in about forty lines of polygons. They exist because the row has to be
## readable at a glance from the middle of a match: four words in a row all start looking the
## same at speed, and the silhouette is what you actually recognise. When there is real art they
## become textures and this file loses `_icon` and nothing else.
##
## THE POINTER ABOVE THE SELECTED CARD is doing more work than it looks. The blue fill alone
## reads as "this one is highlighted" -- which, on a row you are cycling through, is ambiguous
## between "what you are" and "what you would become". The tick mark says: this is you, here,
## now. What you would become is one card to the right, and pressing C moves both.

@export var player_path: NodePath
@export var swap_path: NodePath

@export_group("Layout")
@export var card_size: Vector2 = Vector2(126.0, 96.0)
@export var card_gap: float = 8.0
## Distance from the bottom of the screen to the bottom of the panel.
@export var bottom_margin: float = 96.0
## How fast it arrives and leaves. Quick, because it is a response to you walking onto a spot.
@export var slide_speed: float = 9.0

var _player: Mouse
var _swap: ClassSwap
## 0 hidden, 1 fully out. Smoothed so it slides rather than blinks.
var _shown: float = 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player = get_node_or_null(player_path) as Mouse
	_swap = get_node_or_null(swap_path) as ClassSwap


func _process(delta: float) -> void:
	var wanted := 1.0 if (_swap != null and _swap.available()) else 0.0
	_shown = lerpf(_shown, wanted, 1.0 - exp(-slide_speed * delta))
	if absf(_shown - wanted) < 0.002:
		_shown = wanted
	queue_redraw()


func _draw() -> void:
	if _player == null or _shown <= 0.01:
		return

	var screen := get_viewport_rect().size
	var s := HudSkin.scale_for(screen)
	var card := card_size * s
	var gap := card_gap * s
	var count := MouseClass.COUNT
	var inner := Vector2(float(count) * card.x + float(count - 1) * gap, card.y)
	var frame := Rect2(Vector2.ZERO, inner + Vector2(24.0, 24.0) * s)
	# Slides up from under the bottom edge, so arriving reads as the thing coming to you.
	frame.position = Vector2(
		(screen.x - frame.size.x) * 0.5,
		screen.y - bottom_margin * s - frame.size.y * _shown
	)

	var fade := clampf(_shown, 0.0, 1.0)
	# The whole panel dims together on the way in and out. Drawn through modulate rather than by
	# threading an alpha into every polygon below, which would be forty parameters for one fade.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	modulate.a = fade

	HudSkin.panel(self, frame, 14.0 * s)
	for kind in range(count):
		var at := frame.position + Vector2(12.0 * s + float(kind) * (card.x + gap), 12.0 * s)
		_card(Rect2(at, card), kind, s)


## One card. Selected means "this is what you are", which is why the pointer sits above it.
func _card(card: Rect2, kind: int, s: float) -> void:
	var chosen := kind == _player.mouse_class
	var body := card.grow(-2.0 * s)

	if chosen:
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.10, 0.22, 0.42, 0.95)
		box.border_color = Color(0.45, 0.72, 1.0)
		box.set_border_width_all(int(maxf(2.0, 2.0 * s)))
		box.set_corner_radius_all(int(8.0 * s))
		draw_style_box(box, body)
		_pointer(Vector2(card.get_center().x, card.position.y - 9.0 * s), s)
	else:
		HudSkin.well(self, body, 8.0 * s)

	var tint := Color(0.80, 0.88, 1.0) if chosen else Color(0.62, 0.62, 0.60)
	_icon(kind, Vector2(card.get_center().x, card.position.y + 34.0 * s), 21.0 * s, tint)

	HudSkin.text(
		self,
		Rect2(card.position + Vector2(0.0, card.size.y - 30.0 * s), Vector2(card.size.x, 22.0 * s)),
		MouseClass.name_of(kind).capitalize(), int(17.0 * s),
		HudSkin.TEXT if chosen else HudSkin.TEXT_DIM,
		HORIZONTAL_ALIGNMENT_CENTER
	)


## The tick above the card you are.
func _pointer(tip: Vector2, s: float) -> void:
	draw_colored_polygon(PackedVector2Array([
		tip + Vector2(0.0, 7.0 * s), tip + Vector2(-9.0 * s, -4.0 * s), tip + Vector2(9.0 * s, -4.0 * s),
	]), Color(0.45, 0.72, 1.0))


## Four silhouettes, centred on `at`, about `size` tall. Crude on purpose -- at this scale the
## outline is the whole of the recognition and detail only muddies it.
func _icon(kind: int, at: Vector2, size: float, tint: Color) -> void:
	match kind:
		MouseClass.ENGINEER:
			_wrench(at, size, tint)
		MouseClass.SNEAK:
			_hood(at, size, tint)
		MouseClass.BRUTE:
			_hammer(at, size, tint)
		_:
			_shield(at, size, tint)


## Generalist: a shield. The reliable one, the one who actually scores.
func _shield(at: Vector2, size: float, tint: Color) -> void:
	var w := size * 0.78
	draw_colored_polygon(PackedVector2Array([
		at + Vector2(-w, -size * 0.82),
		at + Vector2(w, -size * 0.82),
		at + Vector2(w, size * 0.16),
		at + Vector2(0.0, size),
		at + Vector2(-w, size * 0.16),
	]), tint)
	# Split down the middle, which is what makes it read as a heraldic shield rather than a
	# rounded box at sixteen pixels.
	draw_colored_polygon(PackedVector2Array([
		at + Vector2(0.0, -size * 0.82),
		at + Vector2(w, -size * 0.82),
		at + Vector2(w, size * 0.16),
		at + Vector2(0.0, size),
	]), Color(tint.r * 0.62, tint.g * 0.62, tint.b * 0.68, tint.a))


## Engineer: a spanner, on the diagonal.
func _wrench(at: Vector2, size: float, tint: Color) -> void:
	var along := Vector2(0.62, -0.78)
	var across := Vector2(-along.y, along.x)
	# The shaft.
	draw_colored_polygon(PackedVector2Array([
		at - along * size * 0.95 + across * size * 0.17,
		at + along * size * 0.35 + across * size * 0.17,
		at + along * size * 0.35 - across * size * 0.17,
		at - along * size * 0.95 - across * size * 0.17,
	]), tint)
	# The open jaw: a ring with a bite taken out of the far side.
	draw_circle(at + along * size * 0.62, size * 0.42, tint)
	draw_circle(at + along * size * 0.62, size * 0.21, HudSkin.WELL)
	draw_colored_polygon(PackedVector2Array([
		at + along * size * 0.62 + across * size * 0.20,
		at + along * size * 1.15 + across * size * 0.20,
		at + along * size * 1.15 - across * size * 0.20,
		at + along * size * 0.62 - across * size * 0.20,
	]), HudSkin.WELL)


## Sneak: a hood with nothing in it.
func _hood(at: Vector2, size: float, tint: Color) -> void:
	var points := PackedVector2Array()
	# A dome for the head, then shoulders -- drawn as an arc so the curve is smooth at any size.
	for i in range(13):
		var angle := PI + PI * float(i) / 12.0
		points.append(at + Vector2(cos(angle), sin(angle)) * Vector2(size * 0.82, size * 0.86))
	points.append(at + Vector2(size * 0.95, size * 0.9))
	points.append(at + Vector2(-size * 0.95, size * 0.9))
	draw_colored_polygon(points, tint)
	# The face, in shadow. Two thirds down and small: a hood is mostly hood.
	draw_circle(at + Vector2(0.0, size * 0.16), size * 0.44, Color(0.08, 0.09, 0.11, tint.a))


## Brute: a mallet.
func _hammer(at: Vector2, size: float, tint: Color) -> void:
	var along := Vector2(0.58, 0.81)
	var across := Vector2(-along.y, along.x)
	draw_colored_polygon(PackedVector2Array([
		at - along * size * 0.25 + across * size * 0.14,
		at + along * size * 1.05 + across * size * 0.14,
		at + along * size * 1.05 - across * size * 0.14,
		at - along * size * 0.25 - across * size * 0.14,
	]), tint)
	var head := at - along * size * 0.52
	draw_colored_polygon(PackedVector2Array([
		head + across * size * 0.78 - along * size * 0.42,
		head + across * size * 0.78 + along * size * 0.42,
		head - across * size * 0.78 + along * size * 0.42,
		head - across * size * 0.78 - along * size * 0.42,
	]), tint)
