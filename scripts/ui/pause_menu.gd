extends CanvasLayer
## Stop the yard, and offer the four things you can do about it.
##
## A CanvasLayer with `PROCESS_MODE_WHEN_PAUSED`, which is the whole trick: `get_tree().paused`
## stops the match, the physics, the bots and the clock, and this node keeps running so there is
## something left to un-pause with. Every other node in `arena.tscn` inherits the default and
## stops, which is what we want -- the pause has to freeze the sim, not just hide it, or a tester
## who steps away comes back scruffed.
##
## IT EATS THE INPUT THAT OPENED IT. `_input` rather than `_unhandled_input`, and the event is
## marked handled: the gameplay scripts read `Input` directly at the moment of acting
## (`player.gd`, `dig_controller.gd`), so a pause key that travels on would open the menu and
## then be seen by whatever else is listening. Marking it handled is also why `pause` is its own
## action in `input_setup.gd` rather than a second job for `ui_cancel`, which the menu's own
## buttons consume.
##
## THE MOUSE COMES BACK. The cursor is the steering wheel in this game (GDD section 9), so it is
## already visible -- but it is also confined by the window when fullscreen, and a menu you cannot
## get the pointer out of is a menu you cannot leave on a second monitor.
##
## Built in code, same as the title screen and for the same reason.

const GAP: float = 12.0
const TITLE_SIZE: int = 34

## The match HUD, hidden while the menu is up. Optional, in the same way `contextual_hint.gd`'s
## paths are: leaving it unwired costs the hiding, not the menu.
##
## A scrim alone does not do this job. The score bug, the roster and the class bar are dark
## panels with cream and gold on them -- `hud_skin.gd` built them that way on purpose, to survive
## both bright dirt and black trenches -- so they survive a tint too, and the menu ends up as one
## more panel among six rather than the thing the screen is now about. Turning them off is also
## the more honest signal: the readouts are live numbers, and while the tree is paused they are
## not telling you anything.
@export var hud_path: NodePath

var _hud: CanvasLayer
var _panel: Control
var _controls: ControlsPanel
var _resume: Button
var _open: bool = false


func _ready() -> void:
	# Runs while the tree is paused; without this the menu freezes with everything else.
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	layer = 100
	_hud = get_node_or_null(hud_path) as CanvasLayer

	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	_controls = ControlsPanel.new()
	_controls.visible = false
	add_child(_controls)

	_rebuild()
	visible = false
	get_viewport().size_changed.connect(_rebuild)


func _rebuild() -> void:
	var s := HudSkin.scale_for(get_viewport().get_visible_rect().size)
	for child: Node in _panel.get_children():
		child.queue_free()

	# The match is still on screen behind this and must read as stopped rather than as running
	# under a transparent overlay.
	#
	# 0.78 rather than the half-and-half that looks right on paper. The yard at midday is bright
	# dirt and lit grass -- the same brightness `hud_skin.gd` had to design its panels against --
	# and at 0.6 the grass still reads as a running game with a tint on it. Checked against 0.95,
	# which goes too far the other way: the match disappears, and then this is a screen you have
	# been sent to rather than a game you have stopped.
	var scrim := ColorRect.new()
	scrim.color = Color(0.0, 0.0, 0.0, 0.78)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(scrim)

	var column := VBoxContainer.new()
	column.theme = MenuSkin.theme(s)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override(&"separation", int(GAP * s))
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var heading := Label.new()
	heading.text = "PAUSED"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_override(&"font", HudSkin.font())
	heading.add_theme_font_size_override(&"font_size", int(TITLE_SIZE * s))
	heading.add_theme_color_override(&"font_color", HudSkin.GOLD)
	heading.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.85))
	heading.add_theme_constant_override(&"outline_size", maxi(4, int(6.0 * s)))
	column.add_child(heading)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, GAP * 2.0 * s)
	column.add_child(spacer)

	_resume = MenuSkin.button("Resume", s)
	column.add_child(_row(_resume, close))
	column.add_child(_row(MenuSkin.button("Controls", s), _show_controls))
	column.add_child(_row(MenuSkin.button("Quit to Title", s), _on_title))
	column.add_child(_row(MenuSkin.button("Quit Game", s), _on_quit))

	_panel.add_child(column)

	var version := Label.new()
	version.text = "v%s" % ProjectSettings.get_setting("application/config/version", "dev")
	version.add_theme_font_override(&"font", HudSkin.font())
	version.add_theme_font_size_override(&"font_size", int(MenuSkin.NOTE_SIZE * s))
	version.add_theme_color_override(&"font_color", HudSkin.TEXT_DIM)
	version.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT, true)
	version.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	version.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version.offset_left = -120.0 * s
	version.offset_top = -28.0 * s
	version.offset_right = -16.0 * s
	version.offset_bottom = -10.0 * s
	version.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(version)

	if _open and not _controls.visible:
		_resume.call_deferred("grab_focus")


func _row(what: Button, pressed: Callable) -> Control:
	what.pressed.connect(pressed)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(what)
	return row


# -------------------------------------------------------------------------------------- opening


func _input(event: InputEvent) -> void:
	# While the controls sheet is up, any of the three ways out of it -- the pause key, accept, or
	# a click anywhere -- closes it, matching the title screen. Somebody who opened it by accident
	# should not have to hunt for the one button that closes it.
	if _controls.visible:
		var clicked := event is InputEventMouseButton and (event as InputEventMouseButton).pressed
		if clicked or event.is_action_pressed("pause") or event.is_action_pressed("ui_accept"):
			get_viewport().set_input_as_handled()
			_hide_controls()
		return

	if not event.is_action_pressed("pause"):
		return
	get_viewport().set_input_as_handled()
	if _open:
		close()
	else:
		open()


func open() -> void:
	_open = true
	visible = true
	if _hud != null:
		_hud.visible = false
	get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_resume.grab_focus()


func close() -> void:
	_open = false
	visible = false
	_controls.visible = false
	_panel.visible = true
	if _hud != null:
		_hud.visible = true
	get_tree().paused = false


func _show_controls() -> void:
	_controls.visible = true
	_panel.visible = false


func _hide_controls() -> void:
	_controls.visible = false
	_panel.visible = true
	_resume.grab_focus()


func _on_title() -> void:
	Routes.to_title(self)


func _on_quit() -> void:
	# Unpause first: quitting a paused tree is fine today, but every other exit from this menu
	# goes through the same door and one of them will not be.
	get_tree().paused = false
	get_tree().quit()
