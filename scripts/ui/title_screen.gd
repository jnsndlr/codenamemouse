extends Control
## The first thing anybody sees, and now the front door to a match with somebody else in it.
##
## Play used to sit where Host and Join would sit, and this file said so. They sit there now, one
## page down: **Play** is one human and nine bots with no socket, **Multiplayer** opens a page with
## Host and Join on it, and either of those lands you in [Routes.to_lobby] rather than straight in an
## arena — because connecting and entering a match are two moments and the gap between them is where
## the interesting bugs live.
##
## TWO PAGES, ONE `_rebuild`, and no second scene. The page is a variable and the menu is built from
## it, which keeps the file's original bargain: the `.tscn` is a root node and a script, and adding an
## entry is adding a line here rather than hand-editing a scene diff. A separate Multiplayer *scene*
## would have needed its own backdrop, its own logo, its own resize handling and its own copy of the
## controls sheet, to show three buttons.
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

enum Page {
	MAIN,
	MULTIPLAYER,
}

var _controls: ControlsPanel
var _menu: VBoxContainer
var _version: Label
var _focus_first: Button
var _fullscreen: Button
var _page: int = Page.MAIN
var _address: LineEdit
## Survives `_rebuild`, so a resize mid-typing does not eat what you typed.
var _typed: String = ""
## Why the last attempt to open a socket failed, shown under the Multiplayer page. Empty is normal.
var _trouble: String = ""


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

	# Arrived here from a dropped match or a closed lobby: open on the page you would retry from, with
	# the reason on it. Set before the first `_rebuild` so the page is drawn once rather than flashing
	# the main menu and then replacing it.
	var why := Routes.take_why()
	if not why.is_empty():
		_trouble = why
		_page = Page.MULTIPLAYER

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
##
## `--host` AND `--join` NOW LAND IN THE LOBBY, which is where the buttons land, and that matters
## more than the convenience. `NetSession` opened the socket during autoload — before this scene
## existed — so a flagged process is in exactly the state a clicked one is, and the audits therefore
## exercise the real door rather than a private entrance beside it. `--play` still overrides, because
## the replication suites want the arena and not a room with a button in it.
func _apply_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--play")
	if at < 0:
		if Net.is_online():
			Routes.to_lobby(self)
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

	if _page == Page.MAIN:
		_build_main(s)
	else:
		_build_multiplayer(s)

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

	if not _controls.visible and _focus_first != null:
		_focus_first.grab_focus()


func _build_main(s: float) -> void:
	_focus_first = MenuSkin.button("Play", s)
	_fullscreen = MenuSkin.button(_fullscreen_label(), s)
	_menu.add_child(_row(_focus_first, _on_play))
	_menu.add_child(_row(MenuSkin.button("Multiplayer", s), _show_multiplayer))
	_menu.add_child(_row(MenuSkin.button("Controls", s), _show_controls))
	_menu.add_child(_row(_fullscreen, _on_fullscreen))
	_menu.add_child(_row(MenuSkin.button("Quit", s), _on_quit))


## Host, then Join with somewhere to type. One page rather than two, because "host" and "join" are
## the same decision made two ways and splitting them would put a screen between a player and the
## only field on it.
func _build_multiplayer(s: float) -> void:
	_focus_first = MenuSkin.button("Host a Match", s)
	_menu.add_child(_row(_focus_first, _on_host))

	_address = MenuSkin.field("address, or address:port", s)
	_address.text = _typed
	_address.text_changed.connect(func(now: String) -> void: _typed = now)
	# Enter in the field joins, because that is what Enter means in a field you just typed an address
	# into. The button stays for anybody who reached it with a pad.
	_address.text_submitted.connect(func(_now: String) -> void: _on_join())
	_menu.add_child(_row(_address, Callable()))
	_menu.add_child(_row(MenuSkin.button("Join", s), _on_join))
	_menu.add_child(_row(MenuSkin.button("Back", s), _show_main))

	if not _trouble.is_empty():
		_menu.add_child(_row(MenuSkin.note(_trouble, s, MenuSkin.WARN), Callable()))
	_menu.add_child(_row(MenuSkin.note(
		"Hosting opens port %d. Whoever joins types your address."
		% NetSession.DEFAULT_PORT, s
	), Callable()))


## Controls in a VBoxContainer stretch to its width, and its width is the screen. One centring row
## each keeps them the size MenuSkin asked for.
##
## Takes a `Control` rather than a `Button` since the Join row has a field in it, and an empty
## `Callable` for the things that are not pressed.
##
## THE NOTES GO THROUGH HERE TOO, and they have to: a `Label` with `AUTOWRAP_WORD_SMART` added straight
## to the column is stretched to the column's width, which is the screen, so it never reaches a wrap
## point and runs off both edges on a wide window. `custom_minimum_size` cannot fix that -- a minimum
## is not a maximum. The centring row is what actually constrains it.
func _row(what: Control, pressed: Callable) -> Control:
	if what is Button and not pressed.is_null():
		(what as Button).pressed.connect(pressed)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(what)
	return row


# -------------------------------------------------------------------------------------- actions


## Straight into a match with whatever session is already open.
##
## **IT MUST NOT TOUCH THE SESSION**, and that is worth a comment because the obvious tidy-up here is
## a bug. Play is "one human, nine bots, no socket", so calling `go_offline` first reads as belt and
## braces -- and it closes the socket that `--host` opened during autoload, seconds before `--play`
## walks into the arena expecting to be a server. Every replication suite failed at once, which is the
## only reason it was a five-minute mistake instead of a confusing afternoon. Nothing is needed here:
## a *failed* Host or Join has already gone offline inside `NetSession`, and a successful one goes to
## the lobby instead of here.
func _on_play() -> void:
	Routes.to_match(self)


## Open the socket first, THEN move. If the port is taken there is no point being in a lobby, and the
## `Error` both of these return is the only thing that knows -- it has been returned and dropped on
## the floor since the flags were written, which is why a typo'd `--join` fails in silence.
func _on_host() -> void:
	var err := Net.host()
	if err != OK:
		_trouble = "Could not open port %d (%s). Something else may already be hosting." % [
			NetSession.DEFAULT_PORT, error_string(err),
		]
		_rebuild()
		return
	_trouble = ""
	Routes.to_lobby(self)


func _on_join() -> void:
	var where := _typed.strip_edges()
	if where.is_empty():
		_trouble = "Type the address your host gave you."
		_rebuild()
		return
	var err := Net.join(where)
	if err != OK:
		_trouble = "Could not reach %s (%s)." % [where, error_string(err)]
		_rebuild()
		return
	_trouble = ""
	# `join` returning OK means the socket was created, NOT that anybody answered -- the handshake
	# finishes seconds later or never. The lobby is what waits, and what says so if it never does.
	Routes.to_lobby(self)


func _show_multiplayer() -> void:
	_page = Page.MULTIPLAYER
	_trouble = ""
	_rebuild()


func _show_main() -> void:
	_page = Page.MAIN
	_trouble = ""
	_rebuild()


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
	if _focus_first != null:
		_focus_first.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not _controls.visible:
		# Escape backs out of the Multiplayer page rather than doing nothing. NOT while a field has
		# focus-and-text, because there Escape is plausibly "clear what I typed" and taking the whole
		# page away instead is the kind of surprise that loses an address somebody read off a phone.
		var backing_out := (
			_page == Page.MULTIPLAYER and event.is_action_pressed("ui_cancel")
			and not (_address != null and _address.has_focus() and not _typed.is_empty())
		)
		if backing_out:
			_show_main()
			get_viewport().set_input_as_handled()
		return
	# Any way out of the controls sheet: the pause key, the accept key, or a click. Somebody who
	# opened it by accident should not have to hunt for the one button that closes it.
	var clicked := event is InputEventMouseButton and (event as InputEventMouseButton).pressed
	if clicked or event.is_action_pressed("pause") or event.is_action_pressed("ui_accept") \
			or event.is_action_pressed("ui_cancel"):
		_hide_controls()
		get_viewport().set_input_as_handled()
