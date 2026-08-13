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
	# E is now ONLY the way into a shaft. It used to double as dig, with the cell deciding
	# which -- unambiguous, but it meant the one key you press while standing still was also
	# the key you hold while steering, and digging out of a shaft cell was awkward because the
	# tile you were on had already claimed the key.
	"burrow": [KEY_E],
	"shaft_down": [KEY_F],
	"shaft_up": [KEY_R],
	# Change class, at your own nest only (GDD section 4). C for class, and it is deliberately
	# nowhere near the movement keys: it is a thing you do while standing still at home, and a
	# misfire mid-chase would be the worst possible moment to become a Brute.
	"swap_class": [KEY_C],
	# The primary class ability. One key, one meaning for the class you chose: the Brute caves in
	# an aimed cell underground and stomps the ground on the surface; the Sneak sounds the layer
	# below or erases nearby enemy cant.
	"ability": [KEY_Q],
	# The Engineer's ability. Section 9's table offers "Q, E, F" and E and F are both shafts,
	# so the table is out of seats -- X is the next key the left hand can reach without leaving
	# WASD, and it is far enough from Q that the two abilities can't be fat-fingered into each
	# other. They are opposites (one seals a corridor for good, one holds it for a while) and
	# misfiring either while the other was wanted is a wasted cooldown.
	"barricade": [KEY_X],
	# The Brute's second ability: Slam (GDD section 4). Its own action rather than a third meaning
	# for Q, because Q already carries two -- the cave-in and the stomp, chosen by which plane you
	# are standing on -- and a key whose meaning moves under you can afford one axis of that, not
	# two. A Brute holding a chokepoint has to be able to shove without first checking where its
	# feet are.
	#
	# V, and it is chosen the same way X was: the far side of the left hand's reach from Q, so the
	# two things a Brute presses under pressure cannot be fat-fingered into each other. One is a
	# cooldown you spend on a guess and the other is the answer to somebody already on top of you;
	# misfiring either while the other was wanted is the worst moment in the class.
	"slam": [KEY_V],
	# The Generalist's second ability: the banner toss (GDD section 4). THE SAME KEY AS SLAM, and
	# that is the rule rather than a collision -- V means "your class's second thing", the way Q
	# means "your class's ability". A Brute shoves with it and a Generalist throws the banner with
	# it, and no mouse is ever both, so no press is ever ambiguous.
	#
	# Two registered actions on one key rather than one action read twice, because the two
	# abilities are not the same slot and should not have to pretend to be -- the argument is
	# written out at `InputFrame.Action.TOSS`. Both bits go down on a V press and exactly one node
	# is listening, since each gates on `owner_class` and silently ignores the wrong class.
	"toss": [KEY_V],
	# The Sneak's second ability: Fade (GDD section 4). THE SAME KEY AGAIN, for the third time, and
	# the rule is unchanged by the third tenant -- V is "your class's second thing" and a mouse is
	# one class. A Brute shoves, a Generalist throws, a Sneak goes to glass.
	#
	# Its own registered action rather than a third reading of `slam`, for the argument written out
	# at `InputFrame.Action.TOSS`: a bit is an INTENT. Reading the Brute's bit to fade would mean
	# the day somebody rebinds the shove, the Sneak's stealth moves with it.
	"fade": [KEY_V],
	# The Sneak's dust screen (GDD section 4). X, which was "the Engineer's ability" and is now
	# *your class's other thing* -- the same generalisation V went through the moment a second class
	# wanted a second ability. The Sneak is the first class in the game with three, and the two it
	# does not share with the Engineer are on the two keys the left hand already knows.
	#
	# FAR FROM Q AND FROM V ON PURPOSE, which is the reasoning barricade was placed with and matters
	# more here than it did there: a Sneak under pressure has three keys to choose between, and the
	# panic button (this) and the ambush setup (V) are the two that must never be confused. Q is the
	# scan, which is the one you press when nothing is happening yet.
	"dust": [KEY_X],
	# Scurry -- the cheese boost (GDD sections 2 and 9). Space, and the thumb is the right home
	# for it: it is available to every class, it is not an ability, and it wants to be pressable
	# without any finger leaving WASD or the mouse. It is also the only key in the game that
	# spends a team resource, which is why it is nowhere near the ones you mash.
	"scurry": [KEY_SPACE],
	# Quarter-turn the view. Arrows rather than Q/E because both hands are already busy --
	# left on WASD and abilities, right on the mouse, which is the steering wheel.
	"view_left": [KEY_LEFT],
	"view_right": [KEY_RIGHT],
	# Show/hide the look panel. Not a gameplay binding -- it lives here anyway so there is
	# one place that answers "what is bound", and it costs nothing in a build where the
	# panel is absent.
	"look_panel": [KEY_F1],
	# Pause. Bound here rather than leaning on Godot's built-in `ui_cancel` for the same reason
	# look_panel is here: one file answers "what is bound", and the controls screen reads that
	# file's answer. `ui_cancel` also carries Escape's other job -- dismissing focus in a
	# Control tree -- and the pause menu is a Control tree, so sharing the action would mean
	# the key that opens the menu is the key the menu's own buttons consume.
	"pause": [KEY_ESCAPE],
	# Photograph the screen (M6.5 -- see `scripts/game/screenshot.gd` for why the build needs to
	# keep its own evidence).
	#
	# P AND NOT F2, WHICH IS THE OBVIOUS CHOICE AND IS WRONG ON THIS TARGET. macOS maps the top
	# row to brightness and volume unless the tester has turned on "Use F1, F2, etc. as standard
	# function keys" -- off by default -- so F2 on somebody else's Mac dims their display and
	# takes no photograph. That is survivable for `look_panel` on F1, which is dev-only and never
	# leaves this machine; it is not survivable for the one key whose entire job is to work in a
	# stranger's hands on the first press.
	#
	# P for photo, and it is nowhere near WASD or the abilities -- same reasoning as C: a shot is
	# something you take deliberately, and a misfire mid-chase should be impossible rather than
	# merely unlikely.
	"screenshot": [KEY_P],
}

## Digging moved to the mouse: point at a tile, hold, watch it open. The cursor is already the
## steering wheel (GDD section 9), so it is the thing that knows where you're looking -- which
## makes it the only sensible way to say "that tile, there".
##
## LEFT IS THE ATTACK AND RIGHT IS THE DIG, reversing what M2 shipped. Section 9's table always
## read "left click: primary attack, right click: abilities" -- but through M2 there was nothing
## to fight, so the dig hold took the primary button unopposed and would quietly have become the
## convention. Digging is the Engineer's ability (section 4), so right click is where the design
## already put it; M3 is simply the first milestone with a reason to care.
const MOUSE: Dictionary = {
	"attack": [MOUSE_BUTTON_LEFT],
	"dig": [MOUSE_BUTTON_RIGHT],
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
	# The triggers, in the same order as the mouse buttons they mirror: attack right, dig left.
	"attack": [JOY_AXIS_TRIGGER_RIGHT, 1.0],
	"dig": [JOY_AXIS_TRIGGER_LEFT, 1.0],
}

const PAD_BUTTONS: Dictionary = {
	"sprint": [JOY_BUTTON_LEFT_STICK],
	# Same thumb, same idea as Space.
	"scurry": [JOY_BUTTON_A],
	"view_left": [JOY_BUTTON_LEFT_SHOULDER],
	"view_right": [JOY_BUTTON_RIGHT_SHOULDER],
	"pause": [JOY_BUTTON_START],
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

	for action_name: String in MOUSE:
		_ensure(action_name)
		for button: MouseButton in MOUSE[action_name]:
			var event := InputEventMouseButton.new()
			event.button_index = button
			InputMap.action_add_event(action_name, event)

	for action_name: String in PAD_ONLY:
		_ensure(action_name)

	for action_name: String in PAD_AXES:
		_ensure(action_name)
		var axis: JoyAxis = PAD_AXES[action_name][0]
		var direction: float = PAD_AXES[action_name][1]
		var event := InputEventJoypadMotion.new()
		event.axis = axis
		event.axis_value = direction
		InputMap.action_add_event(action_name, event)
		InputMap.action_set_deadzone(action_name, STICK_DEADZONE)

	for action_name: String in PAD_BUTTONS:
		_ensure(action_name)
		for button: JoyButton in PAD_BUTTONS[action_name]:
			var event := InputEventJoypadButton.new()
			event.button_index = button
			InputMap.action_add_event(action_name, event)


func _ensure(action_name: String) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
