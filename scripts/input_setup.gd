extends Node
## Registers gameplay input actions at startup.
##
## These live in code rather than in project.godot's [input] section because that
## section serializes as one long line of InputEventKey objects, which is miserable to
## read in a diff. Move them into Project Settings > Input Map whenever you want
## in-editor rebinding.
##
## Keyboard and pad bind to the SAME actions, because they are the same scheme rather
## than two schemes (GDD section 9). Left stick is W/S/A/D with analog in between, right
## stick is the cursor. Only two things differ, and both are because a stick isn't a key:
##
##   Sprint — double-tap W on keyboard, L3 on pad. You can't double-tap a stick.
##   Slow   — Shift on keyboard, but on pad you just feather the stick, so there's no
##            button for it. That's why "slow" has no joypad binding below.

## Deadzone applied to the STICK ACTIONS. Godot's per-action deadzone is per-axis, which
## squares off the diagonals; the player script re-clamps the combined vector so the real
## deadzone is radial. This value only exists to stop a worn stick from creeping.
const STICK_DEADZONE: float = 0.18

const KEYS: Dictionary = {
	"move_forward": [KEY_W],
	"move_back": [KEY_S],
	"strafe_left": [KEY_A],
	"strafe_right": [KEY_D],
	"slow": [KEY_SHIFT],
	# M2 dig spike. Dig is a hold, per GDD section 9's continuous drive.
	"dig": [KEY_E],
	"ramp": [KEY_R],
}

## action -> [axis, direction]. Direction is the sign of the axis that triggers it.
const PAD_AXES: Dictionary = {
	"move_forward": [JOY_AXIS_LEFT_Y, -1.0],
	"move_back": [JOY_AXIS_LEFT_Y, 1.0],
	"strafe_left": [JOY_AXIS_LEFT_X, -1.0],
	"strafe_right": [JOY_AXIS_LEFT_X, 1.0],
	"look_up": [JOY_AXIS_RIGHT_Y, -1.0],
	"look_down": [JOY_AXIS_RIGHT_Y, 1.0],
	"look_left": [JOY_AXIS_RIGHT_X, -1.0],
	"look_right": [JOY_AXIS_RIGHT_X, 1.0],
}

const PAD_BUTTONS: Dictionary = {
	"sprint": [JOY_BUTTON_LEFT_STICK],
}

## Actions with no keyboard binding still need to exist, or is_action_pressed() throws.
const PAD_ONLY: Array[String] = [
	"look_up", "look_down", "look_left", "look_right", "sprint",
]


func _enter_tree() -> void:
	for action_name: String in KEYS:
		_ensure(action_name)
		for keycode: Key in KEYS[action_name]:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			InputMap.action_add_event(action_name, event)

	for action_name: String in PAD_ONLY:
		_ensure(action_name)

	for action_name: String in PAD_AXES:
		var axis: JoyAxis = PAD_AXES[action_name][0]
		var direction: float = PAD_AXES[action_name][1]
		var event := InputEventJoypadMotion.new()
		event.axis = axis
		event.axis_value = direction
		InputMap.action_add_event(action_name, event)
		InputMap.action_set_deadzone(action_name, STICK_DEADZONE)

	for action_name: String in PAD_BUTTONS:
		for button: JoyButton in PAD_BUTTONS[action_name]:
			var event := InputEventJoypadButton.new()
			event.button_index = button
			InputMap.action_add_event(action_name, event)


func _ensure(action_name: String) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
