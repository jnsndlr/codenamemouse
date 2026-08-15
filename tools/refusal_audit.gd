extends SceneTree
## Invariant audit for the three shared ability keys: does a class ever hear about somebody else's
## ability? (GDD section 4.)
##
##   godot --headless --script res://tools/refusal_audit.gd
##
## WHY THIS IS ITS OWN FILE. Q, V and X are each one key with a different meaning per class, and
## every ability node is fitted to EVERY mouse (see [MouseControls]) and gates on `owner_class`. So
## one keypress runs through up to four nodes and exactly one of them is meant to answer. The other
## three must not merely decline -- they must decline **in silence**, because `refused` is wired
## straight to the one line on the HUD that explains a control which just did nothing.
##
## THE BUG THIS EXISTS TO CATCH HAS HAPPENED TWICE, once on each shared key, and it is invisible to
## every other audit in the project. Both times the ability worked perfectly and the HUD lied about
## it: [ShoreUp] told every Brute, Sneak and Generalist that pressed Q that only an Engineer may
## shore a tunnel -- printed OVER the cave-in or sonar that had just fired, because that node sits
## last in the control list -- and [Barricade] told every Sneak that kicked up dust that only an
## Engineer may set a barricade. Nothing failed. A rule was simply announced to the three people it
## was not about, and the ability that HAD worked was the message that got overwritten.
##
## IT GETS WORSE AS THE DESIGN GROWS, which is the real argument for a permanent check. Every key
## here started out belonging to one class and picked up a second or a third owner later -- X was
## the Engineer's alone until the Sneak wanted a third ability, Q belonged to two classes until the
## shore-up landed. Each of those additions turns a harmless refusal into a lying one, and the
## person making it has no reason to look at the class that already owned the key.
##
## WHAT COUNTS AS A LEAK is deliberately not "the string mentions a class name". It is: this mouse
## pressed a key, and something spoke that is not the node this mouse's class owns. That catches a
## politely worded leak as readily as a blunt one, and it needs no list of forbidden phrases to keep
## up to date.

## Key -> the ability node each class answers it with. `null` means the class does not own the key
## at all, and must therefore hear NOTHING when it presses it.
##
## The one place in the project that writes the section 4 table out as data. It is a duplicate of
## what the nodes' own `owner_class` fields say, and here that is the point rather than a smell: an
## audit that asked the nodes would agree with them by construction and could never catch a node
## that had been given to the wrong class.
const OWNERS: Dictionary = {
	InputFrame.Action.ABILITY: {
		MouseClass.GENERALIST: "SecondWind",
		MouseClass.ENGINEER: "ShoreUp",
		MouseClass.SNEAK: "Sonar",
		MouseClass.BRUTE: "CaveIn",
	},
	InputFrame.Action.BARRICADE: {
		MouseClass.GENERALIST: null,
		MouseClass.ENGINEER: "Barricade",
		MouseClass.SNEAK: null,
		MouseClass.BRUTE: null,
	},
	InputFrame.Action.DUST: {
		MouseClass.GENERALIST: null,
		MouseClass.ENGINEER: null,
		MouseClass.SNEAK: "DustKick",
		MouseClass.BRUTE: null,
	},
	InputFrame.Action.SLAM: {
		MouseClass.GENERALIST: null,
		MouseClass.ENGINEER: null,
		MouseClass.SNEAK: null,
		MouseClass.BRUTE: "Slam",
	},
	InputFrame.Action.TOSS: {
		MouseClass.GENERALIST: "BannerToss",
		MouseClass.ENGINEER: null,
		MouseClass.SNEAK: null,
		MouseClass.BRUTE: null,
	},
	InputFrame.Action.FADE: {
		MouseClass.GENERALIST: null,
		MouseClass.ENGINEER: null,
		MouseClass.SNEAK: "Fade",
		MouseClass.BRUTE: null,
	},
}

## Which physical key each action rides, for a failure message somebody can act on.
const KEYCAP: Dictionary = {
	InputFrame.Action.ABILITY: "Q",
	InputFrame.Action.BARRICADE: "X",
	InputFrame.Action.DUST: "X",
	InputFrame.Action.SLAM: "V",
	InputFrame.Action.TOSS: "V",
	InputFrame.Action.FADE: "V",
}

## And which BIT it is, because three of them share a key and two of those share a keycap. A run
## with three sections headed "X" would be a run nobody could read a failure out of -- the whole
## reason each of these is its own bit rather than a second reading of another one is written at
## `InputFrame.Action.TOSS`, and the report should say which bit it pressed.
const BIT_NAMES: Dictionary = {
	InputFrame.Action.ABILITY: "the ability bit",
	InputFrame.Action.BARRICADE: "the barricade bit",
	InputFrame.Action.DUST: "the dust bit",
	InputFrame.Action.SLAM: "the slam bit",
	InputFrame.Action.TOSS: "the toss bit",
	InputFrame.Action.FADE: "the fade bit",
}

## Every node that can speak, so a leak can be attributed to the node that leaked rather than only
## detected. Keyed by name because that is what `MouseControls` names them.
const SPEAKERS: Array[String] = [
	"SecondWind", "ShoreUp", "Sonar", "CaveIn",
	"BannerToss", "Fade", "Slam",
	"Barricade", "DustKick",
]

var _checks: int = 0
var _failures: Array[String] = []

var _scene: Node
var _mouse: Mouse
## node name -> what it said this press.
var _heard: Dictionary = {}


func _initialize() -> void:
	await _arena()
	if _mouse == null:
		print("FAIL -- no arena to audit")
		quit(1)
		return

	await _check_every_class_owns_the_node_the_table_says()
	await _check_nobody_hears_another_class()

	print("\n" + "=".repeat(78))
	if _failures.is_empty():
		print("NO CLASS HEARS ANOTHER CLASS'S ABILITY, across %d checks." % _checks)
	else:
		print("%d of %d REFUSAL CHECKS FAILED:" % [_failures.size(), _checks])
		for failure: String in _failures:
			print("  - %s" % failure)
	print("=".repeat(78))
	quit(0 if _failures.is_empty() else 1)


func _ok(what: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("   ok  %s" % what)
		return
	_failures.append("%s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])
	print("   FAIL %s  %s" % [what, detail])


func _arena() -> void:
	_scene = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(_scene)
	for i in range(30):
		await process_frame

	# THE PLAYER, because it is the one mouse that carries a control set -- bots do not get one
	# (see [MouseControls]), so a bot cannot be asked to press Q.
	_mouse = _scene.get_node("Player") as Mouse
	# DRIVEN AS A REMOTE SEAT, which is the supported way to put a frame into a mouse from a script:
	# without it `Player.input()` recaptures this machine's keyboard on the first ask of every tick
	# and throws away the frame handed to it. Same rung `vitals_shot.gd` climbs, same reason.
	_mouse.set_remote(true)

	for node_name: String in SPEAKERS:
		var ability := _mouse.get_node_or_null(NodePath(node_name))
		if ability == null:
			continue
		ability.connect(
			"refused", func(reason: String) -> void: _heard[node_name] = reason
		)


## The table above against the nodes themselves. If these disagree, every check below is asking the
## wrong question and would pass while doing it.
func _check_every_class_owns_the_node_the_table_says() -> void:
	print("\n-- the roster the table thinks it is auditing")
	for action: int in OWNERS:
		for kind: int in OWNERS[action]:
			var expected: Variant = OWNERS[action][kind]
			if expected == null:
				continue
			var ability := _mouse.get_node_or_null(NodePath(String(expected)))
			_ok(
				"%s answers %s with %s" % [MouseClass.name_of(kind), KEYCAP[action], expected],
				ability != null and int(ability.get("owner_class")) == kind,
				"node missing" if ability == null else "owner_class is %d" % int(
					ability.get("owner_class")
				)
			)


## The whole point of the file: press each shared key as each class, and insist that the only node
## which spoke is the one that class owns.
func _check_nobody_hears_another_class() -> void:
	for action: int in OWNERS:
		print("\n-- %s (%s) pressed by everybody" % [KEYCAP[action], BIT_NAMES[action]])
		for kind: int in OWNERS[action]:
			var owner_node: Variant = OWNERS[action][kind]
			await _press(kind, action)

			var strangers := PackedStringArray()
			for node_name: String in _heard:
				if owner_node == null or node_name != String(owner_node):
					strangers.append("%s: \"%s\"" % [node_name, _heard[node_name]])

			var who := _the(kind)
			var label: String = (
				"%s pressing %s hears only its own %s" % [who, KEYCAP[action], owner_node]
				if owner_node != null
				else "%s pressing %s hears nothing" % [who, KEYCAP[action]]
			)
			_ok(label, strangers.is_empty(), ", ".join(strangers))


## "an ENGINEER", "a BRUTE". One line, and without it every second row of this report reads like a
## typo -- which is the sort of thing that quietly teaches people to skim an audit.
func _the(kind: int) -> String:
	var body := MouseClass.name_of(kind)
	return "%s %s" % ["an" if body.left(1) in ["A", "E", "I", "O", "U"] else "a", body]


## Wear a class, stand up, and hold a key down for long enough that a physics tick is guaranteed to
## have seen it.
##
## HELD AND PRESSED ON EVERY FRAME, rather than pressed once. An idle frame and a physics tick are
## not the same clock -- a frame handed over between ticks can have its pressed bit consumed before
## any `_physics_process` reads it, which makes a once-pressed test pass or fail on frame timing.
## Repeating the press costs nothing here: what is being collected is whether a node speaks AT ALL,
## and [ShoreUp] wants the key held anyway.
func _press(kind: int, action: int) -> void:
	_mouse.set_class(kind)
	_mouse.revive_at(Vector3.ZERO, 0.0)
	for i in range(4):
		await process_frame
	# After the revive, so the standing-up itself cannot be what was heard.
	_heard.clear()
	for i in range(10):
		var frame := InputFrame.new()
		frame.set_pressed(action, true)
		frame.set_held(action, true)
		_mouse.drive(frame)
		await process_frame
