class_name HudSkin
extends RefCounted
## What the HUD is made of: one panel, one well, one bar, two glyphs, and the text.
##
## WHY A SKIN FILE. The HUD is now four separate pieces -- score bug, minimap, roster, feed --
## drawn by four scripts that have nothing else to say to each other. Without a shared skin
## they drift: three slightly different browns, two corner radii, a bar that is 4px here and
## 5px there. That drift is exactly what makes a UI read as assembled rather than designed, and
## it is invisible in any one file and obvious on screen.
##
## DRAWN, NOT THEMED. Every piece of this HUD is immediate-mode `_draw` on a Control, so the
## skin is static functions rather than a Theme resource. The pieces are a dozen rectangles
## that change every frame; a Theme would mean a node per rectangle and a scene to keep in
## sync with them, for furniture that has no interaction and no layout to inherit.
##
## The look comes from the concept art: dark slate panels in chunky wooden frames, cream text,
## and the two numbers that matter -- score and cheese -- in gold. Rounded and bordered because
## at a glance a HUD element has to read as a THING sitting on top of the yard rather than as
## text floating over it; the arena is bright dirt and dark trenches and unbacked text loses
## against one or the other.

## Panel body. Not opaque: this is furniture laid over a game you still need to see.
const PANEL: Color = Color(0.10, 0.09, 0.08, 0.88)
## Sunk areas inside a panel -- the readouts, the map, a roster row.
const WELL: Color = Color(0.05, 0.045, 0.04, 0.92)
## The wooden frame, lit from above.
const FRAME: Color = Color(0.42, 0.31, 0.19)
const FRAME_SHADE: Color = Color(0.20, 0.14, 0.09)

const TEXT: Color = Color(0.94, 0.91, 0.84)
## Labels and anything the eye should skip over on the way to a number.
const TEXT_DIM: Color = Color(0.60, 0.57, 0.51)
## Scores, the clock, anything you are actually reading.
const GOLD: Color = Color(0.98, 0.86, 0.47)
const CHEESE: Color = Color(0.97, 0.79, 0.26)
const CHEESE_DARK: Color = Color(0.72, 0.54, 0.13)

## Health, in the only three states worth telling apart at a glance.
const HEALTH_FULL: Color = Color(0.48, 0.76, 0.36)
const HEALTH_HURT: Color = Color(0.92, 0.74, 0.26)
const HEALTH_LOW: Color = Color(0.86, 0.31, 0.24)

static var _panel_box: StyleBoxFlat
static var _well_box: StyleBoxFlat


# ---------------------------------------------------------------------------------- panels


## A framed panel. The single shape every piece of this HUD sits inside.
static func panel(on: CanvasItem, rect: Rect2, radius: float = 10.0) -> void:
	if _panel_box == null:
		_panel_box = StyleBoxFlat.new()
		_panel_box.bg_color = PANEL
		_panel_box.border_color = FRAME
		_panel_box.set_border_width_all(3)
		# The bottom edge is the shaded one, so the frame reads as lit from above and matches
		# the light in the yard. One line, and it is most of why this looks carved rather than
		# stroked.
		_panel_box.shadow_color = Color(0, 0, 0, 0.45)
		_panel_box.shadow_size = 4
	_panel_box.set_corner_radius_all(int(radius))
	on.draw_style_box(_panel_box, rect)


## A sunk area inside a panel: a readout, a map, a roster row.
static func well(on: CanvasItem, rect: Rect2, radius: float = 6.0) -> void:
	if _well_box == null:
		_well_box = StyleBoxFlat.new()
		_well_box.bg_color = WELL
		_well_box.border_color = FRAME_SHADE
		_well_box.set_border_width_all(2)
	_well_box.set_corner_radius_all(int(radius))
	on.draw_style_box(_well_box, rect)


# ------------------------------------------------------------------------------------ text


static func font() -> Font:
	return ThemeDB.fallback_font


## Text laid out inside a box, vertically centred, with an outline.
##
## A BOX RATHER THAN A POINT, because every label here is positioned relative to a cell it sits
## in -- centred in the clock well, right-aligned against the edge of a roster row -- and doing
## that from a point means every caller measures the string itself and gets the arithmetic
## subtly wrong in its own way.
static func text(
	on: CanvasItem,
	box: Rect2,
	body: String,
	size: int,
	colour: Color,
	align: int = HORIZONTAL_ALIGNMENT_LEFT
) -> void:
	if body.is_empty():
		return
	var typeface := font()
	var baseline := box.position.y + (box.size.y + typeface.get_ascent(size) - typeface.get_descent(size)) * 0.5
	var at := Vector2(box.position.x, baseline)
	# Outlined rather than shadowed, for the same reason vitals.gd is: text has to survive both
	# bright dirt and black trenches, and a panel dark enough to guarantee it would be a panel
	# you cannot see through.
	on.draw_string_outline(
		typeface, at, body, align, box.size.x, size, maxi(3, size / 5),
		Color(0, 0, 0, 0.85 * colour.a)
	)
	on.draw_string(typeface, at, body, align, box.size.x, size, colour)


static func measure(body: String, size: int) -> Vector2:
	return font().get_string_size(body, HORIZONTAL_ALIGNMENT_LEFT, -1, size)


# ------------------------------------------------------------------------------------ bars


## A health bar: sunk track, filled portion, and the colour saying how bad it is.
static func bar(on: CanvasItem, rect: Rect2, fill: float, colour: Color) -> void:
	on.draw_rect(rect.grow(1.0), Color(0.0, 0.0, 0.0, 0.55 * colour.a), true)
	on.draw_rect(rect, Color(WELL.r, WELL.g, WELL.b, 0.9 * colour.a), true)
	var amount := clampf(fill, 0.0, 1.0)
	if amount <= 0.0:
		return
	on.draw_rect(Rect2(rect.position, Vector2(rect.size.x * amount, rect.size.y)), colour, true)


## Green down to yellow down to red. Stepped rather than a gradient: the question a health bar
## answers across the room is "can they take another swing", which has three answers.
static func health_color(ratio: float) -> Color:
	if ratio > 0.6:
		return HEALTH_FULL
	return HEALTH_HURT if ratio > 0.3 else HEALTH_LOW


# ---------------------------------------------------------------------------------- glyphs


## A wedge of cheese, about `size` tall. The concept art's cheese counter is a wedge and a
## number, and the wedge is what makes the number instantly not-a-score.
static func cheese(on: CanvasItem, at: Vector2, size: float, alpha: float = 1.0) -> void:
	var wide := size * 1.25
	var face := Color(CHEESE.r, CHEESE.g, CHEESE.b, alpha)
	var rind := Color(CHEESE_DARK.r, CHEESE_DARK.g, CHEESE_DARK.b, alpha)

	# Front face and the lighter top, which is the whole of the 3D read at this size.
	on.draw_colored_polygon(PackedVector2Array([
		at + Vector2(0.0, size * 0.42),
		at + Vector2(wide, size * 0.20),
		at + Vector2(wide, size),
		at + Vector2(0.0, size),
	]), rind)
	on.draw_colored_polygon(PackedVector2Array([
		at + Vector2(0.0, size * 0.42),
		at + Vector2(wide * 0.30, size * 0.10),
		at + Vector2(wide, size * 0.0),
		at + Vector2(wide, size * 0.20),
	]), face)
	on.draw_colored_polygon(PackedVector2Array([
		at + Vector2(0.0, size * 0.42),
		at + Vector2(wide, size * 0.20),
		at + Vector2(wide, size * 0.62),
		at + Vector2(0.0, size * 0.80),
	]), face)

	# The holes. Two is enough to read as cheese; three starts to look like damage.
	var hole := Color(rind.r * 0.6, rind.g * 0.6, rind.b * 0.55, alpha)
	on.draw_circle(at + Vector2(wide * 0.34, size * 0.62), size * 0.11, hole)
	on.draw_circle(at + Vector2(wide * 0.70, size * 0.48), size * 0.08, hole)


## A banner on its pole, in a crew's colour. `at` is the foot of the pole.
static func flag(on: CanvasItem, at: Vector2, height: float, colour: Color) -> void:
	var pole := Color(0.34, 0.27, 0.18, colour.a)
	on.draw_rect(Rect2(at + Vector2(0.0, -height), Vector2(maxf(2.0, height * 0.10), height)), pole, true)
	on.draw_colored_polygon(PackedVector2Array([
		at + Vector2(height * 0.10, -height),
		at + Vector2(height * 0.78, -height * 0.86),
		at + Vector2(height * 0.78, -height * 0.44),
		at + Vector2(height * 0.10, -height * 0.58),
	]), colour)


## A slow breath, 0..1. Everything on this HUD that has to catch the eye without shouting
## pulses on the same clock, so two alarms at once read as one state of affairs rather than as
## a strobing corner.
static func pulse(speed: float = 2.4) -> float:
	return 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) * 0.001 * speed)
