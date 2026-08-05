class_name MenuSkin
extends RefCounted
## What the menus are made of: a button, a heading, and the same wood as the HUD.
##
## WHY THIS IS NOT IN hud_skin.gd. That file's header is explicit that the HUD is immediate-mode
## `_draw` rather than a Theme, and gives the reason: its pieces are a dozen rectangles that
## change every frame, with no interaction and no layout to inherit. A menu is the opposite on
## all three counts -- it is static, it is entirely interaction, and its layout is a container's
## job. So a Theme is the right tool here for the same reasoning that made it the wrong tool
## there, and keeping the two files apart is what stops that argument from being re-litigated
## every time somebody adds a button.
##
## It borrows every colour from `HudSkin` rather than picking its own, because a title screen in
## slightly different browns from the score bug is exactly the drift that file exists to prevent.
##
## SCALED THE SAME WAY, through `HudSkin.scale_for`, so the menus and the HUD grow together and a
## Retina panel does not leave the buttons behind. Themes cannot express that, so the callers ask
## for a theme at a scale and rebuild it when the window changes size.

const BUTTON_HEIGHT: float = 46.0
const BUTTON_WIDTH: float = 300.0
const BUTTON_SIZE: int = 19
const TITLE_SIZE: int = 46
const NOTE_SIZE: int = 14

## Lit from above, like the HUD's frames.
const BUTTON_FACE: Color = Color(0.17, 0.14, 0.11, 0.94)
const BUTTON_HOVER: Color = Color(0.26, 0.20, 0.14, 0.96)
const BUTTON_DOWN: Color = Color(0.12, 0.10, 0.08, 0.98)
## Darker than any button state, so a field reads as a hole rather than a disabled control.
const FIELD_FACE: Color = Color(0.09, 0.07, 0.06, 0.96)
## For a failed connect. Borrowed from the HUD rather than picked, per this file's whole argument.
const WARN: Color = Color(0.86, 0.44, 0.32)


static func theme(s: float) -> Theme:
	var built := Theme.new()
	_dress_field(built, s)
	built.set_font(&"font", &"Button", HudSkin.font())
	built.set_font_size(&"font_size", &"Button", int(BUTTON_SIZE * s))
	built.set_color(&"font_color", &"Button", HudSkin.TEXT)
	built.set_color(&"font_hover_color", &"Button", HudSkin.GOLD)
	built.set_color(&"font_pressed_color", &"Button", HudSkin.GOLD)
	built.set_color(&"font_focus_color", &"Button", HudSkin.GOLD)
	built.set_color(&"font_disabled_color", &"Button", HudSkin.TEXT_DIM)
	built.set_stylebox(&"normal", &"Button", _box(BUTTON_FACE, HudSkin.FRAME_SHADE, s))
	built.set_stylebox(&"hover", &"Button", _box(BUTTON_HOVER, HudSkin.FRAME, s))
	built.set_stylebox(&"pressed", &"Button", _box(BUTTON_DOWN, HudSkin.FRAME, s))
	built.set_stylebox(&"disabled", &"Button", _box(BUTTON_FACE, HudSkin.FRAME_SHADE, s))
	# Keyboard focus has to be visible: this menu is reachable on a pad, and a pad has no cursor
	# to tell you which button you are on.
	built.set_stylebox(&"focus", &"Button", _box(Color(0, 0, 0, 0), HudSkin.GOLD, s))
	return built


## A place to type a server address, in the same wood as everything else.
##
## Its own `LineEdit` entries in the shared Theme rather than per-node overrides, for the reason this
## file exists at all: a menu is static and a container lays it out, so the styling belongs in the
## Theme where the buttons' already is. Sunk rather than lit -- a field you type into should read as
## a hole in the panel, where a button reads as something sitting on it.
static func _dress_field(built: Theme, s: float) -> void:
	built.set_font(&"font", &"LineEdit", HudSkin.font())
	built.set_font_size(&"font_size", &"LineEdit", int(BUTTON_SIZE * s))
	built.set_color(&"font_color", &"LineEdit", HudSkin.TEXT)
	built.set_color(&"font_placeholder_color", &"LineEdit", HudSkin.TEXT_DIM)
	built.set_color(&"caret_color", &"LineEdit", HudSkin.GOLD)
	built.set_color(&"selection_color", &"LineEdit", Color(HudSkin.GOLD, 0.28))
	built.set_stylebox(&"normal", &"LineEdit", _box(FIELD_FACE, HudSkin.FRAME_SHADE, s))
	built.set_stylebox(&"focus", &"LineEdit", _box(FIELD_FACE, HudSkin.GOLD, s))


## A field sized like a button, so a Join row reads as one piece of furniture.
static func field(placeholder: String, s: float) -> LineEdit:
	var made := LineEdit.new()
	made.placeholder_text = placeholder
	made.custom_minimum_size = Vector2(BUTTON_WIDTH * s, BUTTON_HEIGHT * s)
	made.alignment = HORIZONTAL_ALIGNMENT_CENTER
	made.caret_blink = true
	return made


## One line of explanation under a menu. Dim by default; `tone` carries a warning or a success.
static func note(text: String, s: float, tone: Color = HudSkin.TEXT_DIM) -> Label:
	var made := Label.new()
	made.text = text
	made.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	made.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	made.custom_minimum_size = Vector2(BUTTON_WIDTH * 1.9 * s, 0.0)
	made.add_theme_font_override(&"font", HudSkin.font())
	made.add_theme_font_size_override(&"font_size", int(NOTE_SIZE * s))
	made.add_theme_color_override(&"font_color", tone)
	return made


static func _box(face: Color, edge: Color, s: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = face
	box.border_color = edge
	box.set_border_width_all(maxi(2, int(3.0 * s)))
	box.set_corner_radius_all(int(8.0 * s))
	box.content_margin_top = 10.0 * s
	box.content_margin_bottom = 10.0 * s
	box.content_margin_left = 22.0 * s
	box.content_margin_right = 22.0 * s
	return box


## A menu button, sized in the same reference pixels every other piece of furniture uses.
static func button(label: String, s: float) -> Button:
	var made := Button.new()
	made.text = label
	made.custom_minimum_size = Vector2(BUTTON_WIDTH * s, BUTTON_HEIGHT * s)
	made.focus_mode = Control.FOCUS_ALL
	return made
