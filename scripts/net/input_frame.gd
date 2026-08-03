class_name InputFrame
extends RefCounted
## One tick of what a player meant, as data rather than as a question asked of the keyboard.
##
## THE WHOLE OF M7's STEP 2 IS THIS TYPE EXISTING. Through M6 every gameplay script read `Input`
## *at the moment of acting* — six of them, and the plan's survey had only found two. That is fine
## while the only intent in the process is the one at this keyboard, and it is unfixable the moment
## a second human's intent has to arrive from a socket: you cannot send a keyboard.
##
## So intent becomes a value. A local capture builds one of these per tick from the real keyboard;
## a server builds one from bytes off the wire; either way the sixteen lines that act on it do not
## know or care which happened. **Single-player runs through the identical path**, which the plan
## names as the thing that stops the networked path from being the one nobody tests.
##
## WHY THIS LIVES IN `scripts/net/` DESPITE HAVING NOTHING TO DO WITH SOCKETS. Because its reason
## for existing is that it can travel. Filed under `player/` it would read as a refactor of the
## controls, and the first person to add a field would reach for whatever was convenient — a
## `Camera3D`, a node reference, a `Callable` — none of which fit in a packet. Its neighbours are
## the reminder.
##
## RESOLVED, NOT RAW. Two fields are already the *answer* to a local question rather than the
## question: `aim_point` is a world position rather than a mouse cursor, and `look` is a direction
## rather than a stick deflection. Both depend on the camera, and the camera is the one thing in
## this game that is permanently local (`camera_rig.gd` is presentation and stays that way). A
## frame carrying screen coordinates would be a frame the server could not interpret.

## Every button that is a *decision*. Movement is analog and lives in `move`; these are the things
## you press.
##
## The order is the wire order and appending is safe; reordering is not, and would silently swap
## two abilities between a client and a server built from different commits. New entries go on the
## end.
enum Action {
	ATTACK,
	SCURRY,
	SLOW,
	SPRINT,
	FORWARD,      ## Held for the ladder, and its *press* is half of the double-tap.
	DIG,
	BURROW,
	SHAFT_DOWN,
	SHAFT_UP,
	ABILITY,
	BARRICADE,
	SWAP_CLASS,
}

## Strafe on x, forward/back on y, already radially clamped. Facing-relative conversion is the
## sim's job, because it needs a facing the client may not agree about.
var move: Vector2 = Vector2.ZERO

## Where the cursor is on the ground, in world space. The aim source for the swing, the dig
## target, the cave-in and the barricade.
var aim_point: Vector3 = Vector3.ZERO

## A facing the stick asked for, or ZERO for "the cursor decides". Not folded into `aim_point`
## because a neutral stick means *hold what you have*, which no point in the world can express.
var look: Vector3 = Vector3.ZERO

var _held: int = 0
var _pressed: int = 0


func set_held(action: Action, on: bool) -> void:
	_held = (_held | (1 << action)) if on else (_held & ~(1 << action))


## "Went down this tick". Separate from held because the two drive genuinely different things — a
## held DIG opens a tile over half a second, a pressed DIG is what says a refusal out loud once
## rather than sixty times a second.
func set_pressed(action: Action, on: bool) -> void:
	_pressed = (_pressed | (1 << action)) if on else (_pressed & ~(1 << action))


func is_held(action: Action) -> bool:
	return (_held & (1 << action)) != 0


func is_pressed(action: Action) -> bool:
	return (_pressed & (1 << action)) != 0


## Nothing pressed, nothing held, no movement. What a mouse nobody is driving should be handed —
## and what a disconnected seat gets, so a dropped player's mouse stands still rather than
## repeating its last input forever.
func clear() -> void:
	move = Vector2.ZERO
	look = Vector3.ZERO
	_held = 0
	_pressed = 0


func duplicate_frame() -> InputFrame:
	var out := InputFrame.new()
	out.move = move
	out.aim_point = aim_point
	out.look = look
	out._held = _held
	out._pressed = _pressed
	return out


# ---------------------------------------------------------------------------------- the wire


## 36 bytes: eight floats and two button masks.
##
## FLOATS RATHER THAN QUANTISED ANYTHING, for now and on purpose. At 30Hz and eight seats this is
## under 9 KB/s of input in the worst case, which is nothing, and the plan is explicit that the
## state payload was never the concern — 4v4 and grid tunnels were chosen so it would not be.
## Quantising is a thing to do when a measurement says to, and there is no measurement yet.
func to_bytes() -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	out.put_float(move.x)
	out.put_float(move.y)
	out.put_float(aim_point.x)
	out.put_float(aim_point.y)
	out.put_float(aim_point.z)
	out.put_float(look.x)
	out.put_float(look.y)
	out.put_float(look.z)
	out.put_u16(_held)
	out.put_u16(_pressed)
	return out.data_array


## Returns null on a short or malformed buffer rather than a half-filled frame.
##
## A CLIENT IS NOT TRUSTED TO SEND A WELL-FORMED PACKET, and this is the first place in the project
## where that sentence applies to anything. A frame built out of whatever bytes happened to arrive
## is a mouse driven by a stranger's typo at best; the length check is the cheapest possible
## version of the habit, and the caller is expected to drop the packet rather than guess.
static func from_bytes(bytes: PackedByteArray) -> InputFrame:
	if bytes.size() != SIZE:
		return null
	var into := StreamPeerBuffer.new()
	into.data_array = bytes
	var frame := InputFrame.new()
	frame.move = Vector2(into.get_float(), into.get_float())
	frame.aim_point = Vector3(into.get_float(), into.get_float(), into.get_float())
	frame.look = Vector3(into.get_float(), into.get_float(), into.get_float())
	frame._held = into.get_u16()
	frame._pressed = into.get_u16()
	return frame


## Eight 32-bit floats plus two 16-bit masks. Stated as a constant so `from_bytes` and the audit
## disagree loudly rather than quietly if a field is ever added without touching both.
const SIZE: int = 8 * 4 + 2 * 2
