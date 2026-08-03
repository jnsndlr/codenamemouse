class_name InputCapture
extends RefCounted
## Turns this machine's keyboard, mouse and pad into an [InputFrame]. The only place in the game
## that reads `Input` for a gameplay decision.
##
## THAT SENTENCE IS THE POINT AND IT IS ENFORCEABLE. Before this, six files asked `Input` at the
## moment of acting — `player.gd` and `dig_controller.gd` by polling, and `cave_in.gd`, `sonar.gd`,
## `barricade.gd` and `class_swap.gd` as `_unhandled_input` handlers. Six places is six chances for
## a client to act on its own authority, and the four event handlers are worse than the two polls:
## an `_unhandled_input` fires on *this* machine's event stream, which a server has no equivalent
## of for a peer three hundred miles away.
##
## `camera_rig.gd`, the menus and the screenshot key still read `Input` and always will. They are
## presentation and they are local forever; the rule is about gameplay.
##
## STATIC, AND NOT A NODE. It has no state between ticks — the double-tap timer that looks like
## state belongs to the mouse doing the sprinting, not to the keyboard. A node would need a place
## in the tree, a process order relative to six other nodes, and an answer to "which player is this
## one for" on a machine that may eventually have none.
##
## THE UI GUARD LIVES HERE, deliberately. Whether the cursor is over a slider is a question about
## *this* screen, and the honest reading of a click on a HUD panel is that the player did not mean
## to swing — so it never becomes intent in the first place, rather than being filtered out twice
## further down by two files that each had their own copy of the check.

## Frame button -> the action registered in `input_setup.gd`. One dictionary, so adding a binding
## is one line here and not a search.
##
## `SPRINT` is the pad's L3; the keyboard's double-tap is derived by the mouse from `FORWARD`,
## because you cannot double-tap a stick and the two are genuinely different gestures.
const ACTIONS: Dictionary = {
	InputFrame.Action.ATTACK: &"attack",
	InputFrame.Action.SCURRY: &"scurry",
	InputFrame.Action.SLOW: &"slow",
	InputFrame.Action.SPRINT: &"sprint",
	InputFrame.Action.FORWARD: &"move_forward",
	InputFrame.Action.DIG: &"dig",
	InputFrame.Action.BURROW: &"burrow",
	InputFrame.Action.SHAFT_DOWN: &"shaft_down",
	InputFrame.Action.SHAFT_UP: &"shaft_up",
	InputFrame.Action.ABILITY: &"ability",
	InputFrame.Action.BARRICADE: &"barricade",
	InputFrame.Action.SWAP_CLASS: &"swap_class",
}

## Buttons that a cursor parked over the HUD must not produce. The two that are aimed with the
## mouse; the keyboard ones are unaffected because a keyboard has no cursor to be somewhere.
const POINTER_BUTTONS: Array = [InputFrame.Action.ATTACK, InputFrame.Action.DIG]

## Stick deflection past which the pad takes over aiming from the cursor.
const STICK_AIM: float = 0.25


## Build this tick's frame for `who`.
##
## `last_aim` is carried forward when the ground raycast misses — over the horizon, or during the
## frame a scene is swapped — because a frame with `aim_point` snapped to the origin would swing
## every mouse in the match toward the middle of the map for one tick.
static func read(who: Node3D, last_aim: Vector3) -> InputFrame:
	var frame := InputFrame.new()
	var viewport := who.get_viewport()
	var over_ui := viewport != null and viewport.gui_get_hovered_control() != null

	for action: InputFrame.Action in ACTIONS:
		var binding: StringName = ACTIONS[action]
		if over_ui and POINTER_BUTTONS.has(action):
			continue
		frame.set_held(action, Input.is_action_pressed(binding))
		frame.set_pressed(action, Input.is_action_just_pressed(binding))

	# Radially clamped, so a diagonal is not faster than a straight line. The per-direction
	# penalties are NOT applied here: they depend on facing, which is the sim's business, and
	# applying them before the clamp is how W+D used to launder the strafe penalty away.
	var move := Vector2(
		Input.get_action_strength(&"strafe_right") - Input.get_action_strength(&"strafe_left"),
		Input.get_action_strength(&"move_forward") - Input.get_action_strength(&"move_back")
	)
	if move.length() > 1.0:
		move = move.normalized()
	frame.move = move

	frame.aim_point = _aim_point(who, viewport, last_aim)
	frame.look = _look(viewport)
	return frame


## Where the cursor meets the ground plane the mouse is standing on.
##
## The plane is taken at the mouse's own height rather than at zero, which is what makes aiming
## work identically three planes down: at y=0 a mouse in a deep tunnel would aim at a point on the
## lawn far behind itself.
static func _aim_point(who: Node3D, viewport: Viewport, last_aim: Vector3) -> Vector3:
	if viewport == null:
		return last_aim
	var camera := viewport.get_camera_3d()
	if camera == null:
		return last_aim

	var cursor := viewport.get_mouse_position()
	var ground := Plane(Vector3.UP, who.global_position.y)
	var hit: Variant = ground.intersects_ray(
		camera.project_ray_origin(cursor), camera.project_ray_normal(cursor)
	)
	return hit if hit != null else last_aim


## The right stick's requested facing, in world space, or ZERO for "the cursor decides".
##
## Camera-relative so that up on the stick is up the screen; at the fixed 45 degree yaw a raw
## mapping would send the mouse off diagonally. Resolved here rather than sent raw because the
## camera is local and the server has no idea which way this player is looking at the yard.
static func _look(viewport: Viewport) -> Vector3:
	var stick := Vector2(
		Input.get_action_strength(&"look_right") - Input.get_action_strength(&"look_left"),
		Input.get_action_strength(&"look_down") - Input.get_action_strength(&"look_up")
	)
	if stick.length() <= STICK_AIM:
		return Vector3.ZERO

	var camera := viewport.get_camera_3d() if viewport != null else null
	if camera == null:
		return Vector3(stick.x, 0.0, stick.y).normalized()

	var basis := camera.global_transform.basis
	var forward := basis.z * -1.0
	forward.y = 0.0
	var right := basis.x
	right.y = 0.0
	return (right.normalized() * stick.x - forward.normalized() * stick.y).normalized()
