class_name Player
extends Mouse
## The mouse you are driving. Everything a mouse can DO lives in `mouse.gd`; this is only the
## half that reads a keyboard -- steering, the speed ladder, and the swing.
##
## THE CURSOR IS THE STEERING WHEEL (GDD section 9). The mouse turns to face the cursor at a
## capped rate, and W drives it that way. W/S/A/D are relative to FACING, not to the camera --
## so S is a backpedal and A/D are sidesteps, and all three keep you pointed at whatever you
## were pointed at.
##
## The thing that makes this work: movement is DERIVED FROM facing, so the two can never
## disagree. The old camera-relative scheme turned velocity almost instantly while the body
## turned at a capped rate, so the mouse visibly crabbed sideways through every direction
## change. Here the turn-rate cap still supplies the weight, but as a body that takes a moment
## to swing around -- and W pushing along a swinging facing is what produces the arcs.
##
## Speed ladder: Slow (hold Shift) < Run (default) < Sprint (double-tap W, costs personal
## stamina). Sprint never costs cheese -- that's Scurry, which is a separate, bigger thing and
## doesn't exist yet.
##
## LEFT CLICK IS THE ATTACK, and digging moved to right click. GDD section 9's table always
## said so; through M2 there was nothing to fight, so the dig hold took the primary button by
## default and it would have quietly become the convention. Right click is the ability button
## in that same table, and digging is the Engineer's ability (section 4) -- so this is the
## binding the design already had, arrived at as soon as there was a reason to care.

@export_group("Sprint stamina")
## How quickly the second W tap has to land.
##
## THE ONLY ONE OF THESE LEFT HERE, and the split is the point: a double tap is a fact about a
## keyboard, and everything else about sprinting is a fact about a mouse. The tank, its duration,
## its refill and the refusal on fumes moved to [Mouse] at M8 so bots could climb the same ladder
## -- see the note on `Mouse.sprint_seconds`.
@export var double_tap_window: float = 0.28

@export_group("Aim")
## Cursor closer than this to the mouse stops steering it. Without this the facing spins
## wildly whenever the cursor passes over the body.
@export var aim_deadzone: float = 0.45

var _aim_point: Vector3 = Vector3.ZERO
var _since_forward_tap: float = 999.0
## The physics frame `_input` was last built on. See `input()`.
var _captured_on: int = -1
## A player sitting at a different keyboard (M7). Same class, same rules, same stamina -- the only
## difference is where the intent comes from, which is the entire point of the input frame.
##
## WITHOUT THIS FLAG A REMOTE PLAYER MIRRORS THE HOST'S KEYBOARD, because `input()` captures on the
## first ask of each tick and the host's `_control` is an ask. The seat would be driven by whoever
## is sitting at the server. It is the same hazard `drive()` guards against for one tick, made
## permanent for a mouse that must never read this machine's input at all.
var _remote: bool = false


func _ready() -> void:
	super()
	# THE CONTROLS COME WITH THE MOUSE (M7). Digging, the two Engineer abilities, the Sneak's sonar
	# and the swap point used to be five nodes in `arena.tscn` pointed at `../Player` -- fine while
	# there was one, and the reason a remote human could press dig and have nothing happen at all.
	# A `Player` is a mouse somebody is driving, wherever that somebody is sitting, so it is the
	# one place that knows a set is wanted. See [MouseControls].
	MouseControls.fit(self)


## Where the cursor currently sits on the ground plane. This is the aim source -- thrown
## acorns, barricade placement and dig target all want it. The camera does NOT read it; it
## works out its own lead from screen space (see camera_rig.gd).
func get_aim_point() -> Vector3:
	return input().aim_point


## This machine's keyboard, as data, built AT MOST ONCE PER PHYSICS TICK and then handed to
## everyone who asks.
##
## LAZY RATHER THAN CAPTURED IN `_control`, and that is a correctness fix rather than a style
## choice. Six nodes read this intent and they are spread across the scene tree: `dig_controller`
## and the four abilities have their own `_physics_process`, and Godot runs them in tree order.
## Capturing inside `_control` would mean whichever of them happens to be readied *above* the
## player reads last tick's frame — a one-frame lag that is invisible in single-player, differs by
## scene layout, and is the exact species of bug that gets blamed on the network later.
##
## Keyed on the frame counter, so the first ask in a tick builds it and the rest get the same
## object. Nobody has to be ordered.
## Never capture; only ever be driven. For a seat whose human is somewhere else.
func set_remote(on: bool) -> void:
	_remote = on


func input() -> InputFrame:
	if _remote:
		return _input
	var now := Engine.get_physics_frames()
	if now != _captured_on:
		_captured_on = now
		_input = InputCapture.read(self, _aim_point)
		_aim_point = _input.aim_point
	return _input


## Intent from somewhere other than this keyboard, for this tick only.
##
## The base class just stores it; a `Player` additionally has to be told **not to capture over the
## top of it**, or the frame it was handed is replaced by whatever the real keyboard is doing the
## moment anything asks. Marking the tick as spoken for is the whole override.
##
## Not a test seam, though the audits are its first user: this is the shape a replay needs, and
## the shape a listen-server host needs the day it drives a seat whose player has dropped. The
## capture resumes by itself next tick, because `_captured_on` stops matching.
func drive(frame: InputFrame) -> void:
	super(frame)
	_captured_on = Engine.get_physics_frames()
	_aim_point = _input.aim_point




## The one method the base class asks for. Aim, then the ladder, then a heading.
func _control(delta: float) -> void:
	var frame := input()
	_update_sprint(frame, delta)
	_face_toward(_aim_direction(frame), delta)

	if frame.is_pressed(InputFrame.Action.ATTACK):
		swing()

	# ASKED OF THE DIRECTOR, not done here. The price is a cheese out of the crew's pool and the
	# pool is the director's, so the only thing this end owns is the keypress -- a mouse that
	# could boost itself would be a mouse that could spend its team's lives without the thing
	# holding the ledger ever hearing about it. That shape is why Scurry needs no work at M7:
	# it was already a request rather than an act.
	if frame.is_pressed(InputFrame.Action.SCURRY):
		var director := get_tree().get_first_node_in_group(MatchDirector.DIRECTOR_GROUP)
		if director != null:
			director.try_scurry(self)

	_wish = _wish_direction(frame)


## Double-tap W. Sprint holds while W is held and dies the moment you stop pushing forward, run
## dry, or drop to Slow -- so it can never be left on by accident, which is why it doesn't need to
## be a toggle.
##
## PURELY THE READING NOW. Since M8 this decides what the keyboard is ASKING for and hands it to
## [Mouse]; the tank, the refusal on fumes and the drain live there, so a bot climbing the same
## ladder cannot end up on a second copy of the rules that drifts.
func _update_sprint(frame: InputFrame, delta: float) -> void:
	if frame.is_pressed(InputFrame.Action.FORWARD):
		if _since_forward_tap <= double_tap_window:
			request_sprint(true)
		_since_forward_tap = 0.0
	else:
		_since_forward_tap += delta

	# L3 on a pad, because you can't double-tap a stick.
	if frame.is_pressed(InputFrame.Action.SPRINT):
		request_sprint(true)

	# Read off `move` rather than off the FORWARD bit, because a stick pushed a third of the way
	# is forward without the action's threshold being crossed -- and letting it drift back to
	# centre has to end a sprint, or a pad player sprints until the stamina runs out.
	var quiet := frame.is_held(InputFrame.Action.SLOW)
	set_creeping(quiet)
	if frame.move.y <= 0.0 or quiet:
		request_sprint(false)


## Facing-relative, which is the whole scheme. Note the penalties are applied AFTER the radial
## clamp, so holding W+D doesn't launder the strafe penalty away by renormalising.
func _wish_direction(frame: InputFrame) -> Vector3:
	# Already radially clamped by the capture; the penalties below are still applied after it.
	var raw := frame.move
	if raw.length_squared() < 0.0001:
		return Vector3.ZERO

	var forward := get_facing_direction()
	var right := forward.cross(Vector3.UP)
	var ahead := raw.y * (1.0 if raw.y >= 0.0 else back_multiplier)
	return forward * ahead + right * raw.x * strafe_multiplier


## Right stick wins when it's deflected; otherwise the cursor. A neutral stick returns zero,
## which `_face_toward` reads as "hold what you've got" -- that's what lets a pad player let
## go of the stick without the mouse snapping to a default heading.
## The camera-relative conversion the stick needs is resolved by the capture, because the camera
## is local and a server has no idea which way this player is looking at the yard. What is left
## here is the choice between the two aim sources, which is a rule and belongs on this side.
func _aim_direction(frame: InputFrame) -> Vector3:
	if frame.look != Vector3.ZERO:
		return frame.look

	# Measured against the mouse's OWN position, not the client's idea of it: this runs wherever
	# the sim runs, so it has to use the authoritative body rather than the point the aim was
	# taken from.
	var to_cursor := frame.aim_point - global_position
	to_cursor.y = 0.0
	if to_cursor.length() < aim_deadzone:
		return Vector3.ZERO
	return to_cursor.normalized()
