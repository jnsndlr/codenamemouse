extends Node
## Registers gameplay input actions at startup.
##
## These live in code rather than in project.godot's [input] section because that
## section serializes as one long line of InputEventKey objects, which is miserable to
## read in a diff. Move them into Project Settings > Input Map whenever you want
## in-editor rebinding.

const ACTIONS: Dictionary = {
	"move_up": [KEY_W],
	"move_down": [KEY_S],
	"move_left": [KEY_A],
	"move_right": [KEY_D],
	"sprint": [KEY_SHIFT],
}


func _enter_tree() -> void:
	for action_name: String in ACTIONS:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
		for keycode: Key in ACTIONS[action_name]:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			InputMap.action_add_event(action_name, event)
