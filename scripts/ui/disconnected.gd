extends CanvasLayer
## The host is gone, and this is the arena admitting it.
##
## **WITHOUT THIS THE MATCH SIMPLY STOPPED.** `NetSession._on_connection_lost` calls `go_offline`,
## which closes the transport — so `NetMatch._physics_process` returns at its `is_established` guard
## and never runs again, while the client's `MatchDirector` had already been handed
## `set_simulating(false)` and nothing turns it back on. Every mouse stays a puppet waiting for poses
## that will not arrive. Mice stop moving, the clock stops, the HUD keeps displaying the last numbers
## it was told, and **nothing says a word**. The only way out was the pause menu, if you thought to
## try it.
##
## No suite in `tools/` could have caught that, and it is worth being precise about why: loopback
## never drops. Every audit here begins by getting two processes talking and ends while they still
## are, so `connection lost` appears in their logs exactly once — as the last line, at teardown, where
## nothing is left to observe what follows. Failure had no coverage at all. `drop_audit.gd` is the
## first suite in this project that breaks something on purpose.
##
## IT IS A DIFFERENT STATE FROM OFFLINE, which is the distinction the whole file rests on. Going
## offline is also how a session starts and how "leave the lobby" is expressed — both perfectly
## ordinary. `NetSession.wire_lost` fires only for the failure, and only on a client: a host that
## loses somebody hands their chair to a bot and plays on, which is already right and needs nothing
## here.
##
## THE ARENA STAYS ON SCREEN, PAUSED. Not a snap back to the title — being yanked out of a match
## gives you no idea what happened, and the last thing you saw is information. So the tree pauses, the
## HUD goes (its numbers are now stale, and a live-looking readout that has stopped updating is worse
## than no readout), and this sits over the top with the one thing left to do on it. The same
## reasoning `pause_menu.gd` sets out for its scrim, applied to a stop nobody chose.

const GAP: float = 12.0
const TITLE_SIZE: int = 34

## The match HUD, hidden while this is up. Optional in the same way `pause_menu.gd`'s is: leaving it
## unwired costs the hiding, not the notice.
@export var hud_path: NodePath
## The pause menu, closed on the way in. Reaching this screen through a pause menu that is still open
## would stack two panels that both offer to quit.
@export var pause_path: NodePath

var _hud: CanvasLayer
var _panel: Control
var _back: Button
var _up: bool = false


func _ready() -> void:
	# Runs while the tree is paused, since pausing the tree is what this node does. Without it the
	# notice freezes along with the match it is announcing.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Above the pause menu's 100. If the host vanished while you were staring at a pause screen, the
	# disconnection is the more important of the two things on offer.
	layer = 110
	_hud = get_node_or_null(hud_path) as CanvasLayer

	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	visible = false
	get_viewport().size_changed.connect(_rebuild)
	Net.wire_lost.connect(_on_wire_lost)


## Only ever the failure, and only ever once. A second `wire_lost` cannot arrive -- the transport is
## already closed -- but the guard costs nothing and says the intent.
func _on_wire_lost() -> void:
	if _up:
		return
	_up = true
	Net.log_line("disconnected: the wire died mid-match")

	var pause := get_node_or_null(pause_path)
	if pause != null and pause.has_method("close"):
		pause.call("close")
	if _hud != null:
		_hud.visible = false

	_rebuild()
	visible = true
	get_tree().paused = true
	_back.call_deferred("grab_focus")


func _rebuild() -> void:
	var s := HudSkin.scale_for(get_viewport().get_visible_rect().size)
	for child: Node in _panel.get_children():
		child.queue_free()

	# Heavier than the pause menu's 0.78. A paused match is one you will go back to and should still
	# read as a yard; this one is over, and the yard behind it is a frozen half-second that no longer
	# means anything.
	var scrim := ColorRect.new()
	scrim.color = Color(0.0, 0.0, 0.0, 0.88)
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
	heading.text = "CONNECTION LOST"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_override(&"font", HudSkin.font())
	heading.add_theme_font_size_override(&"font_size", int(TITLE_SIZE * s))
	heading.add_theme_color_override(&"font_color", MenuSkin.WARN)
	heading.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.85))
	heading.add_theme_constant_override(&"outline_size", maxi(4, int(6.0 * s)))
	column.add_child(heading)

	# HONEST ABOUT NOT KNOWING WHICH. From here the two are indistinguishable -- the transport reports
	# one `connection_lost` whether the host quit, crashed, or the network went, and `enet_transport`
	# argues on purpose that a caller's job is the same either way. Naming both beats guessing one.
	column.add_child(_row(MenuSkin.note(
		"The host is no longer reachable. They may have quit, "
		+ "or the connection between you dropped.", s
	)))
	column.add_child(_spacer(s))

	_back = MenuSkin.button("Back to Title", s)
	column.add_child(_row(_back, _on_back))
	_panel.add_child(column)


func _row(what: Control, pressed: Callable = Callable()) -> Control:
	if what is Button and not pressed.is_null():
		(what as Button).pressed.connect(pressed)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(what)
	return row


func _spacer(s: float) -> Control:
	var made := Control.new()
	made.custom_minimum_size = Vector2(0.0, GAP * 2.0 * s)
	return made


func _on_back() -> void:
	Net.log_line("disconnected: back to the title")
	# `Routes.to_title` unpauses on the way, which matters more here than anywhere else: this node is
	# the thing that paused the tree, and it is about to stop existing.
	Routes.to_title(self, "The connection to the host was lost.")


## Escape does not open the pause menu behind this, and does not dismiss it either. There is one way
## out of a match that has ended and it is the button.
func _input(event: InputEvent) -> void:
	if not _up:
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
