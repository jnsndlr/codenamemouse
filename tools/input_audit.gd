extends SceneTree
## Asserts the two claims M7's step 2 is actually making, neither of which any existing suite
## can see.
##
## **One: a frame survives the wire.** `to_bytes` / `from_bytes` round-trips every field. The
## other audits drive mice with frames built in-process, so a serializer that dropped `look`
## entirely would pass all nineteen match invariants and then quietly disable pad aiming for every
## remote player on the day the first packet is sent.
##
## **Two: a driven frame really is indistinguishable from a keyboard.** The whole justification
## for the refactor is that the sim cannot tell which happened. That is a claim about
## `Player.drive`, and the specific way it can be false is subtle: `Player` captures lazily and
## would otherwise overwrite a handed-in frame the instant anything asked. So the assertion is
## that a mouse handed an intent *acts on that intent* and not on the empty keyboard underneath.
##
## Runs headless -- no camera, which is also the case the capture's `last_aim` fallback exists for.
##   godot --headless --path . --script res://tools/input_audit.gd

var _failures: int = 0


func _initialize() -> void:
	_check_round_trip()
	await _check_driving()

	print("")
	if _failures > 0:
		print("=== %d FAILED. Intent is not travelling intact. ===" % _failures)
		quit(1)
		return
	print("==============================================================================")
	print("INTENT TRAVELS: every field survives the wire, and a driven frame drives.")
	print("==============================================================================")
	quit()


# ------------------------------------------------------------------------------------ the wire


func _check_round_trip() -> void:
	print("-- a frame survives being bytes")

	var sent := InputFrame.new()
	sent.move = Vector2(-0.5, 0.75)
	sent.aim_point = Vector3(12.5, -1.25, -30.0)
	sent.look = Vector3(0.0, 0.0, -1.0)
	# Deliberately the first and last actions plus one in the middle: an off-by-one in the mask
	# loses an end, and SWAP_CLASS is the highest bit there is.
	sent.set_held(InputFrame.Action.ATTACK, true)
	sent.set_held(InputFrame.Action.DIG, true)
	sent.set_pressed(InputFrame.Action.SWAP_CLASS, true)

	var bytes := sent.to_bytes()
	_check("the packet is the size it says it is (%d)" % bytes.size(), bytes.size() == InputFrame.SIZE)

	var got := InputFrame.from_bytes(bytes)
	if got == null:
		_check("it decodes at all", false)
		return

	_check("move survives", got.move.is_equal_approx(sent.move))
	_check("the aim point survives", got.aim_point.is_equal_approx(sent.aim_point))
	_check("the look direction survives", got.look.is_equal_approx(sent.look))
	_check("held actions survive", got.is_held(InputFrame.Action.ATTACK) and got.is_held(InputFrame.Action.DIG))
	_check("the highest bit survives", got.is_pressed(InputFrame.Action.SWAP_CLASS))

	# The half that would otherwise pass by accident: held and pressed are different words, and a
	# serializer that wrote one mask twice would satisfy every line above.
	_check("held is not pressed", not got.is_pressed(InputFrame.Action.ATTACK))
	_check("pressed is not held", not got.is_held(InputFrame.Action.SWAP_CLASS))
	_check("an action nobody touched is off", not got.is_held(InputFrame.Action.SCURRY))

	print("-- and a malformed one is refused rather than half-read")
	_check("a short buffer is refused", InputFrame.from_bytes(PackedByteArray([1, 2, 3])) == null)
	_check("an empty buffer is refused", InputFrame.from_bytes(PackedByteArray()) == null)
	var padded := bytes.duplicate()
	padded.append(0)
	_check("a long buffer is refused", InputFrame.from_bytes(padded) == null)


# --------------------------------------------------------------------------------- the driving


func _check_driving() -> void:
	print("\n-- a driven frame drives")

	# A BARE PLAYER, NOT THE ARENA, and its own ticking switched off. Both are about ORDER, which
	# is the only thing that can be wrong here: `Player` captures on the FIRST ask of each physics
	# tick, so anything that asks before this test does hides the bug being hunted. In the arena
	# the four ability nodes and the dig controller all ask, every tick.
	var player: Node = (load("res://scenes/player/player.tscn") as PackedScene).instantiate()
	root.add_child(player)
	player.set_physics_process(false)
	await physics_frame

	# Nothing is touching a keyboard in a headless run, so a captured frame is the empty one.
	# Asserted first, because otherwise "the driven frame arrived" and "everything is on anyway"
	# look identical.
	var idle: InputFrame = player.call("input")
	_check("an untouched keyboard produces nothing", not idle.is_pressed(InputFrame.Action.ATTACK))

	# ON A FRESH TICK, and this line is the whole test. Driving during a tick that has already
	# captured would pass whether or not `drive` marks the tick as spoken for -- which is exactly
	# how the first version of this check passed with the mechanism deleted.
	await physics_frame

	var wanted := InputFrame.new()
	wanted.aim_point = Vector3(4.0, 0.0, 5.0)
	wanted.move = Vector2(0.0, 1.0)
	wanted.set_pressed(InputFrame.Action.ATTACK, true)
	wanted.set_held(InputFrame.Action.SLOW, true)
	player.call("drive", wanted)

	var got: InputFrame = player.call("input")
	_check("the player reports the intent it was handed", got.is_pressed(InputFrame.Action.ATTACK))
	_check("and its held actions", got.is_held(InputFrame.Action.SLOW))
	_check("and its aim", got.aim_point.is_equal_approx(wanted.aim_point))
	_check("which is also what get_aim_point answers", player.call("get_aim_point").is_equal_approx(wanted.aim_point))

	# And it is one tick only: a dropped player must not repeat their last input forever.
	await physics_frame
	var after: InputFrame = player.call("input")
	_check("the intent does not outlive its tick", not after.is_pressed(InputFrame.Action.ATTACK))

	player.queue_free()
	await physics_frame


func _check(what: String, ok: bool) -> void:
	print("   %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
