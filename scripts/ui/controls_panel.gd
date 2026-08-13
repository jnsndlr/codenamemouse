class_name ControlsPanel
extends Control
## The bindings, on screen, in the game. Shared by the title screen and the pause menu.
##
## GENERATED FROM THE LIVE InputMap, NOT FROM A LIST OF STRINGS. There are seventeen actions and
## four of them are each a whole subsystem -- E burrows, F and R are shafts, Q is a class ability
## whose meaning changes with the class -- so a tester who never finds E never sees tunnels, and
## tunnels are the game. That makes this screen load-bearing, and a hand-typed copy of the keys is
## the exact thing that goes stale the first time somebody moves one. `input_setup.gd` already
## claims to be the one place that answers "what is bound"; this file asks it at runtime rather
## than repeating its answer.
##
## So what lives here is ORDER, NAMES AND GROUPING -- the things a binding table cannot know --
## and nothing else. Move a key in `input_setup.gd` and this screen moves with it.
##
## AND IT FAILS LOUD. `_unlisted()` diffs the actions this file groups against the actions that
## actually exist, and anything ungrouped is drawn at the bottom under its raw action name. A new
## binding therefore shows up as ugly rather than as absent, which is the right way round: the
## milestone's question is whether somebody can play without you in the room, and a control that
## silently never appears on the controls screen is the one failure that looks like success.
##
## DRAWN, NOT THEMED, for the reason hud_skin.gd gives -- so it is furniture cut from the same
## wood as the score bug rather than Godot's default grey.

## Actions that are real but are not a row of their own.
##
## The four `look_*` axes are the pad half of aiming, and the "aim" row in THE YARD already says
## "Right stick" for all of them; listed separately they were four rows saying the same thing
## next to a blank keyboard column. `look_panel` is the dev tuning panel, which is not in a
## release build at all.
const HIDDEN: Array[String] = [
	"look_panel", "look_up", "look_down", "look_left", "look_right",
]

## Grouping and order. Every action not named here, and not in HIDDEN, lands under UNLISTED.
const SECTIONS: Array = [
	["MOVING", ["move_forward", "move_back", "strafe_left", "strafe_right", "sprint", "slow", "scurry"]],
	["DIGGING", ["dig", "burrow", "shaft_down", "shaft_up"]],
	["FIGHTING", ["attack", "ability", "barricade", "slam", "toss", "fade", "dust"]],
	["THE YARD", ["aim", "view_left", "view_right", "swap_class", "pause", "screenshot"]],
]

## Action -> what to call it. Written for somebody who has never played, so they say what the
## control DOES rather than what the system is called: "Dig a tunnel", not "Dig".
const LABELS: Dictionary = {
	"move_forward": "Move forward",
	"move_back": "Move back",
	"strafe_left": "Move left",
	"strafe_right": "Move right",
	"sprint": "Sprint",
	"slow": "Walk slowly",
	"scurry": "Scurry — costs 1 cheese",
	"dig": "Dig at the cursor",
	"burrow": "Enter a tunnel",
	"shaft_down": "Go down a level",
	"shaft_up": "Climb back up",
	"attack": "Attack",
	"ability": "Class ability",
	"barricade": "Barricade",
	"slam": "Slam — shove them back",
	"toss": "Throw the banner",
	# THREE ROWS SHARE V AND TWO SHARE X, and the panel prints all five rather than collapsing them.
	# The key is the same and the ability is not, so a Sneak reading "Slam" against V would have
	# learned the wrong thing about their own class -- and a row saying "V: your class's second
	# thing" would be true, useless, and a phrase no player has ever heard. The names are what
	# differ, so the names are what is listed.
	"fade": "Fade — glass for 10 seconds",
	"dust": "Kick up dust — break away",
	"aim": "Aim",
	"view_left": "Turn the view left",
	"view_right": "Turn the view right",
	"swap_class": "Change class (at your nest)",
	"pause": "Pause",
	"screenshot": "Take a screenshot",
}

## For the two controls that are not events, and so cannot be read off the InputMap.
##
## Sprint is a double-tap and aiming is just where the cursor is; both are real controls a player
## has to be told about, and neither has a key to look up. `input_setup.gd` says the same thing in
## its header -- keyboard and pad are one scheme, and these two are where a stick isn't a key.
const OVERRIDES: Dictionary = {
	"sprint": {"key": "Double-tap W"},
	"aim": {"key": "Mouse", "pad": "Right stick"},
}

const PAD_BUTTON_NAMES: Dictionary = {
	JOY_BUTTON_A: "A",
	JOY_BUTTON_B: "B",
	JOY_BUTTON_X: "X",
	JOY_BUTTON_Y: "Y",
	JOY_BUTTON_LEFT_STICK: "L3",
	JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_LEFT_SHOULDER: "LB",
	JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_START: "Start",
	JOY_BUTTON_BACK: "Back",
}

const PAD_AXIS_NAMES: Dictionary = {
	JOY_AXIS_LEFT_X: "Left stick",
	JOY_AXIS_LEFT_Y: "Left stick",
	JOY_AXIS_RIGHT_X: "Right stick",
	JOY_AXIS_RIGHT_Y: "Right stick",
	JOY_AXIS_TRIGGER_LEFT: "LT",
	JOY_AXIS_TRIGGER_RIGHT: "RT",
}

const MOUSE_BUTTON_NAMES: Dictionary = {
	MOUSE_BUTTON_LEFT: "Left click",
	MOUSE_BUTTON_RIGHT: "Right click",
	MOUSE_BUTTON_MIDDLE: "Middle click",
}

# Laid out at this window size and multiplied by HudSkin.scale_for on the way to the screen, the
# same as every other piece of furniture in this game.
const TITLE_SIZE: int = 24
const HEADING_SIZE: int = 14
const ROW_SIZE: int = 15
const ROW_HEIGHT: float = 23.0
const HEADING_HEIGHT: float = 30.0
const PAD: float = 22.0
const COLUMN_GAP: float = 30.0
const LABEL_WIDTH: float = 210.0
const KEY_WIDTH: float = 120.0
const PAD_WIDTH: float = 92.0

## One drawable line. `heading` rows carry a title and no bindings.
class Row:
	var heading: String = ""
	var label: String = ""
	var key: String = ""
	var pad: String = ""

	static func of_heading(title: String) -> Row:
		var row := Row.new()
		row.heading = title
		return row


var _columns: Array[Array] = []


func _ready() -> void:
	# No interactive children, and it sits over a menu that does have them.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_columns = _build()
	get_viewport().size_changed.connect(queue_redraw)


# ------------------------------------------------------------------------------------ the table


## Every row, split into the two columns it gets drawn in.
func _build() -> Array[Array]:
	var rows: Array[Row] = []
	for section: Array in SECTIONS:
		rows.append(Row.of_heading(section[0]))
		for action: String in section[1]:
			rows.append(_row(action))

	var unlisted := _unlisted()
	if not unlisted.is_empty():
		rows.append(Row.of_heading("UNLISTED"))
		for action: String in unlisted:
			rows.append(_row(action))

	# Split at a heading rather than at the halfway row, so a group is never cut in two.
	var target: int = int(ceil(rows.size() / 2.0))
	var split: int = rows.size()
	for i: int in range(rows.size()):
		if i >= target and rows[i].heading != "":
			split = i
			break

	var columns: Array[Array] = []
	columns.append(rows.slice(0, split))
	columns.append(rows.slice(split))
	return columns


func _row(action: String) -> Row:
	var row := Row.new()
	row.label = LABELS.get(action, action)
	var override: Dictionary = OVERRIDES.get(action, {})
	row.key = override.get("key", _binding(action, false))
	row.pad = override.get("pad", _binding(action, true))
	return row


## Actions that exist but that no section claims. The drift guard -- see the class comment.
func _unlisted() -> Array[String]:
	var claimed: Array[String] = []
	claimed.append_array(HIDDEN)
	for section: Array in SECTIONS:
		claimed.append_array(section[1])

	var missing: Array[String] = []
	for action: StringName in InputMap.get_actions():
		var name := String(action)
		# Godot's own ui_* actions are not this game's controls.
		if name.begins_with("ui_") or claimed.has(name):
			continue
		missing.append(name)
	missing.sort()
	return missing


## What `action` is bound to, on the keyboard-and-mouse side or the pad side.
func _binding(action: String, want_pad: bool) -> String:
	if not InputMap.has_action(action):
		return ""
	var found: Array[String] = []
	for event: InputEvent in InputMap.action_get_events(action):
		var text := _pad_text(event) if want_pad else _key_text(event)
		# One stick drives four actions, so the same name arrives more than once.
		if text != "" and not found.has(text):
			found.append(text)
	return " / ".join(found)


func _key_text(event: InputEvent) -> String:
	if event is InputEventKey:
		var key := event as InputEventKey
		# input_setup.gd binds physical keycodes, so that is the one to read; the fallback is
		# for anything bound through the editor's Input Map instead.
		var code: Key = key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
		return OS.get_keycode_string(code)
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		return MOUSE_BUTTON_NAMES.get(button.button_index, "Mouse %d" % button.button_index)
	return ""


func _pad_text(event: InputEvent) -> String:
	if event is InputEventJoypadButton:
		var button := event as InputEventJoypadButton
		return PAD_BUTTON_NAMES.get(button.button_index, "Button %d" % button.button_index)
	if event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		return PAD_AXIS_NAMES.get(motion.axis, "Axis %d" % motion.axis)
	return ""


# ---------------------------------------------------------------------------------- the drawing


func _draw() -> void:
	var screen := get_viewport_rect().size
	var s := HudSkin.scale_for(screen)

	var footer := _footer()
	var column_width := (LABEL_WIDTH + KEY_WIDTH + PAD_WIDTH) * s
	var body_height := maxf(_height_of(_columns[0]), _height_of(_columns[1])) * s
	var title_block := (TITLE_SIZE + 18.0) * s
	var footer_block := (ROW_SIZE * float(footer.size()) + 16.0) * s

	var frame := Rect2(
		Vector2.ZERO,
		Vector2(
			column_width * 2.0 + COLUMN_GAP * s + PAD * s * 2.0,
			title_block + body_height + footer_block + PAD * s * 2.0
		)
	)
	frame.position = ((screen - frame.size) * 0.5).floor()

	# The yard is still running behind this on the pause menu, and a panel you can read through
	# is a panel you cannot read.
	draw_rect(Rect2(Vector2.ZERO, screen), Color(0.0, 0.0, 0.0, 0.55), true)
	HudSkin.panel(self, frame, 12.0 * s)

	var inner := frame.grow(-PAD * s)
	HudSkin.text(
		self,
		Rect2(inner.position, Vector2(inner.size.x, TITLE_SIZE * s)),
		"CONTROLS", int(TITLE_SIZE * s), HudSkin.GOLD, HORIZONTAL_ALIGNMENT_CENTER
	)

	var top := inner.position.y + title_block
	for column: int in range(2):
		var left := inner.position.x + (column_width + COLUMN_GAP * s) * float(column)
		_draw_column(_columns[column], Vector2(left, top), column_width, s)

	var line_y := inner.end.y - ROW_SIZE * s * float(footer.size())
	for line: String in footer:
		HudSkin.text(
			self,
			Rect2(Vector2(inner.position.x, line_y), Vector2(inner.size.x, ROW_SIZE * s)),
			line, int(ROW_SIZE * s * 0.85), HudSkin.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER
		)
		line_y += ROW_SIZE * s


func _draw_column(rows: Array, at: Vector2, width: float, s: float) -> void:
	var y := at.y
	for row: Row in rows:
		if row.heading != "":
			HudSkin.text(
				self,
				Rect2(Vector2(at.x, y + 8.0 * s), Vector2(width, HEADING_SIZE * s)),
				row.heading, int(HEADING_SIZE * s), HudSkin.TEXT_DIM
			)
			y += HEADING_HEIGHT * s
			continue

		var height := ROW_HEIGHT * s
		# A sunk row behind the bindings, so the eye can run down the key column without
		# tracking back across to the label it belongs to.
		HudSkin.well(
			self,
			Rect2(Vector2(at.x + LABEL_WIDTH * s - 6.0 * s, y), Vector2((KEY_WIDTH + PAD_WIDTH) * s, height)),
			4.0 * s
		)
		HudSkin.text(
			self, Rect2(Vector2(at.x, y), Vector2(LABEL_WIDTH * s, height)),
			row.label, int(ROW_SIZE * s), HudSkin.TEXT
		)
		HudSkin.text(
			self, Rect2(Vector2(at.x + LABEL_WIDTH * s, y), Vector2(KEY_WIDTH * s, height)),
			row.key, int(ROW_SIZE * s), HudSkin.GOLD
		)
		HudSkin.text(
			self, Rect2(Vector2(at.x + (LABEL_WIDTH + KEY_WIDTH) * s, y), Vector2(PAD_WIDTH * s, height)),
			row.pad, int(ROW_SIZE * s), HudSkin.TEXT_DIM
		)
		y += height


## The two controls that are not keys, and then where the evidence goes.
##
## The second line is the point of the screenshot key existing at all (M6.5): a tester on another
## Mac who cannot find the shots afterwards has taken none. The toast says the same path when a
## shot lands, but that is only useful to somebody who has already pressed the key -- this is
## where you find out *before*, which is also where you find out the game keeps a log at all.
##
## Read off the autoload rather than rebuilt from `user://`, so the folder is named once. The
## guard is for the visual probes in `tools/`, which build this panel without a SceneTree that
## has run the autoloads.
func _footer() -> PackedStringArray:
	var lines := PackedStringArray(["Sprint is a double-tap, and the cursor is the steering wheel."])
	var shots := get_node_or_null(^"/root/Screenshot")
	if shots != null:
		lines.append("Screenshots and the log file are saved under %s" % shots.user_folder())
	return lines


func _height_of(rows: Array) -> float:
	var total := 0.0
	for row: Row in rows:
		total += HEADING_HEIGHT if row.heading != "" else ROW_HEIGHT
	return total
