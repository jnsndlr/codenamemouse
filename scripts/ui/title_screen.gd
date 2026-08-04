extends Control
## The first thing anybody sees, and the skeleton of M7's lobby.
##
## Play sits where Host and Join will sit. That is the actual reason this exists: M7 turns joining
## a match into "swap the scene under the player", and `Routes` (see that file) is the seam. A
## title screen is what makes that seam get exercised before netcode is leaning on it.
##
## BUILT IN CODE RATHER THAN IN THE .tscn, following `look_panel.gd`: a column of buttons is a
## hundred lines of unreadable scene diff, and every one of them would need hand-editing in the
## editor to add an entry. The scene file is a root node and a script, and the menu is `_rebuild`
## and nothing else.
##
## REBUILT ON RESIZE, because `MenuSkin` bakes a scale into its Theme -- the same
## `HudSkin.scale_for` the in-game furniture uses, so the menu and the HUD agree about how big a
## Retina panel is.

const LOGO: String = "res://assets/branding/png/app-icon-512.png"
## The mark is square; this is how tall it sits at the reference window size.
const LOGO_HEIGHT: float = 190.0
const GAP: float = 14.0

## Deep and warm, taken from the icon's own backdrop so the mark sits on the screen rather than
## on a rectangle of a slightly different red.
const BACKDROP: Color = Color(0.13, 0.06, 0.06)

var _controls: ControlsPanel
var _menu: VBoxContainer
var _version: Label
var _play: Button
var _fullscreen: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# A title screen that arrives paused is what you get when the last thing you did was quit to
	# it from a pause menu and something on that path did not unpause. Cheap insurance.
	get_tree().paused = false
	Settings.apply_fullscreen(Settings.fullscreen())

	var backdrop := ColorRect.new()
	backdrop.color = BACKDROP
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	# Bottom right, dim, and read from project.godot rather than typed here -- one source of truth
	# for the number that has to appear in a bug report. A child of the screen and not of the
	# menu, because a container would overrule its anchors.
	_version = Label.new()
	_version.text = "v%s" % ProjectSettings.get_setting("application/config/version", "dev")
	_version.add_theme_font_override(&"font", HudSkin.font())
	_version.add_theme_color_override(&"font_color", HudSkin.TEXT_DIM)
	_version.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT, true)
	_version.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_version.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_version.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_version)

	_controls = ControlsPanel.new()
	_controls.visible = false
	add_child(_controls)

	_rebuild()
	get_viewport().size_changed.connect(_rebuild)

	_apply_command_line()


## `--play [seconds]`: press Play without a person, optionally after waiting here a while.
##
## THE SAME ARGUMENT `--host` AND `--join` MAKE, one screen later. Those two get a process onto a
## socket; neither gets it into an arena, and replication only exists inside one. A headless
## process has nobody to press Play, so without this the only way to test two ends of the wire is
## a human clicking through two windows -- a demonstration rather than a check.
##
## THE OPTIONAL DELAY IS NOT A CONVENIENCE. Connecting and *entering a match* are separate moments
## and a real player leaves a gap between them: they join from the command line and then sit on
## this screen, or they quit a match to the title and go back in. Anything the server says during
## that gap is said to a process with no arena in it, and the bug that hides there looks like a
## working game right up until you check whose mouse is whose. Without a way to make the gap
## happen on purpose, the only run this suite could ever produce is the lucky one.
func _apply_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--play")
	if at < 0:
		return
	var next := String(args[at + 1]) if at + 1 < args.size() else ""
	var delay := next.to_float() if next.is_valid_float() else 0.0
	if delay <= 0.0:
		_on_play()
		return
	get_tree().create_timer(delay).timeout.connect(_on_play)


# ------------------------------------------------------------------------------------ the menu


func _rebuild() -> void:
	var s := HudSkin.scale_for(get_viewport_rect().size)
	if _menu != null:
		_menu.queue_free()

	_menu = VBoxContainer.new()
	_menu.theme = MenuSkin.theme(s)
	_menu.alignment = BoxContainer.ALIGNMENT_CENTER
	_menu.add_theme_constant_override(&"separation", int(GAP * s))
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The backdrop and the version label are behind and in front of nothing; the menu just needs
	# to not swallow the clicks meant for its own buttons.
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var logo := TextureRect.new()
	logo.texture = load(LOGO)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(0.0, LOGO_HEIGHT * s)
	_menu.add_child(logo)

	var name_label := Label.new()
	name_label.text = ProjectSettings.get_setting("application/config/name", "Codename: Mouse")
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_override(&"font", HudSkin.font())
	name_label.add_theme_font_size_override(&"font_size", int(MenuSkin.TITLE_SIZE * s))
	name_label.add_theme_color_override(&"font_color", HudSkin.GOLD)
	name_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.85))
	name_label.add_theme_constant_override(&"outline_size", maxi(4, int(8.0 * s)))
	_menu.add_child(name_label)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, GAP * 1.5 * s)
	_menu.add_child(spacer)

	_play = MenuSkin.button("Play", s)
	_fullscreen = MenuSkin.button(_fullscreen_label(), s)
	_menu.add_child(_row(_play, _on_play))
	_menu.add_child(_row(MenuSkin.button("Controls", s), _show_controls))
	_menu.add_child(_row(_fullscreen, _on_fullscreen))
	_menu.add_child(_row(MenuSkin.button("Quit", s), _on_quit))

	add_child(_menu)
	# Backdrop, menu, version, controls -- the controls sheet covers everything.
	move_child(_menu, 1)
	move_child(_controls, get_child_count() - 1)

	_version.add_theme_font_size_override(&"font_size", int(MenuSkin.NOTE_SIZE * s))
	_version.offset_left = -120.0 * s
	_version.offset_top = -28.0 * s
	_version.offset_right = -16.0 * s
	_version.offset_bottom = -10.0 * s
	_version.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	if not _controls.visible:
		_play.grab_focus()


## Buttons in a VBoxContainer stretch to its width, and its width is the screen. One centring row
## each keeps them the size MenuSkin asked for.
func _row(what: Button, pressed: Callable) -> Control:
	what.pressed.connect(pressed)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(what)
	return row


# -------------------------------------------------------------------------------------- actions


func _on_play() -> void:
	Routes.to_match(self)


func _on_quit() -> void:
	get_tree().quit()


func _on_fullscreen() -> void:
	Settings.set_fullscreen(not Settings.fullscreen())
	_fullscreen.text = _fullscreen_label()


func _fullscreen_label() -> String:
	return "Fullscreen: On" if Settings.fullscreen() else "Fullscreen: Off"


func _show_controls() -> void:
	_controls.visible = true
	_menu.visible = false


func _hide_controls() -> void:
	_controls.visible = false
	_menu.visible = true
	_play.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not _controls.visible:
		return
	# Any way out of the controls sheet: the pause key, the accept key, or a click. Somebody who
	# opened it by accident should not have to hunt for the one button that closes it.
	var clicked := event is InputEventMouseButton and (event as InputEventMouseButton).pressed
	if clicked or event.is_action_pressed("pause") or event.is_action_pressed("ui_accept") \
			or event.is_action_pressed("ui_cancel"):
		_hide_controls()
		get_viewport().set_input_as_handled()
