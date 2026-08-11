extends Label
## HUD depth readout (GDD section 3 and 10): am I at surface, 1, 2 or 3?
##
## Text, not an icon, and deliberately blunt. This is a spike instrument -- if the 3D
## rendering is doing its job you should already know your depth without reading this,
## and catching yourself glancing at it is itself a result worth recording.

const NAMES: Array[String] = ["SURFACE", "DEPTH 1", "DEPTH 2", "DEPTH 3"]

@export var network_path: NodePath
@export var player_path: NodePath
## How long a refusal stays on screen. Long enough to read, short enough that holding dig
## against a blocked face doesn't leave a message stuck there after you walk away.
@export var refusal_seconds: float = 1.6

var _network: TunnelNetwork
var _player: Node3D
var _refusal: String = ""
var _refusal_left: float = 0.0
## Whether the line currently showing is something that DIDN'T happen or something that did. One
## slot, two voices: they are the same piece of screen and they are never both true at once,
## because both are answers to the same keypress.
var _refusal_blocked: bool = true


func _ready() -> void:
	_network = get_node_or_null(network_path) as TunnelNetwork
	_player = get_node_or_null(player_path) as Node3D
	if _network != null:
		_network.dig_refused.connect(_on_dig_refused)
		_network.dig_noted.connect(_on_dig_noted)


## The tunnel has real placement rules -- no shaft without floor to sink it from, none on a
## cell another shaft already reaches, none from the deepest plane. Every one refuses a
## keypress, and a refused keypress with no feedback is indistinguishable from a broken
## control. Saying why costs one line of HUD.
func _on_dig_refused(reason: String) -> void:
	_refusal = reason
	_refusal_left = refusal_seconds
	_refusal_blocked = true


## The same line, for something that DID happen -- the stomp's "there was nothing under there",
## which is news rather than a refusal. Unlabelled, because the label is the difference.
func _on_dig_noted(what: String) -> void:
	_refusal = what
	_refusal_left = refusal_seconds
	_refusal_blocked = false


func _process(delta: float) -> void:
	if _network == null or _player == null:
		return

	_refusal_left = maxf(0.0, _refusal_left - delta)

	# Scales with the rest of the HUD. This is a spike instrument in the corner, but a spike
	# instrument you cannot read on a big monitor is not doing its job either.
	var ui := HudSkin.scale_for(get_viewport_rect().size)
	if label_settings != null and label_settings.font_size != int(19.0 * ui):
		label_settings.font_size = int(19.0 * ui)
		label_settings.outline_size = maxi(3, int(5.0 * ui))
		size.x = 436.0 * ui

	var plane := _network.plane_at_height(_player.global_position.y)
	var counts: Array[String] = []
	for index in range(1, TunnelNetwork.PLANE_COUNT):
		var marker := ">" if index == plane else " "
		counts.append("%s%d:%d" % [marker, index, _network.cell_count(index)])

	# Sprint is spelled out because double-tap W is invisible until someone tells you, and
	# not knowing whether you *can* sprint reads as the tunnels being sluggish.
	# The E prompt is NOT here. It is contextual -- true on one tile out of a thousand -- and
	# appending it to this permanent list of bindings is what made it invisible. It lives in
	# shaft_prompt.gd now, on its own line at the bottom of the screen.
	var hint := (
		"F: sink a shaft     arrows: turn view     double-tap W: sprint" if plane <= 0
		else "aim + hold RMB: dig a tile     F: shaft down     R: shaft up"
			+ "\narrows: turn view     double-tap W: sprint     shift: slow"
	)
	# The class line, and the Brute's is the only one that changes with where it is standing --
	# because its ability does. Q on the lawn is a stomp and Q in a corridor is a cave-in, and a
	# binding whose meaning moves under you has to say which one it currently means.
	var kind: int = int(_player.get("mouse_class"))
	if kind == MouseClass.GENERALIST:
		hint += "\nQ: second wind"
		# Only while you have something to throw. The Generalist's two keys are unlike the Brute's:
		# Q is always available and V is meaningless nine tenths of the match, so a permanent line
		# for it would be teaching a binding at every moment except the one where it matters.
		if bool(_player.call("is_carrying")):
			hint += "     V: throw the banner"
	elif kind == MouseClass.SNEAK:
		hint += "\nQ: sound below / erase enemy cant"
	elif kind == MouseClass.ENGINEER and plane > 0:
		# BOTH KEYS, and the Q line is new: until the shoring landed the Engineer was the one class
		# whose ability key did nothing, and this line said so by being absent. Ordered ability-key
		# first, like every other class, so the four hints line up rather than the Engineer's
		# reading as the odd one out for a second reason.
		hint += "\nQ: hold to shore this tunnel     X: barricade"
	elif kind == MouseClass.BRUTE:
		hint += "\nQ: stomp the ground" if plane <= 0 else "\nQ: cave in the tunnel beside you"
		# Slam does NOT move with the plane, and saying so on the same line as the one that does is
		# most of the point: the Brute's two keys differ in exactly one respect and a player
		# learning the class should be able to see which one it is.
		hint += "     V: slam"
	var blocked := ""
	if _refusal_left > 0.0:
		blocked = "\n\nBLOCKED: %s" % _refusal if _refusal_blocked else "\n\n%s" % _refusal
	text = "%s\n%s\n\n%s%s" % [
		NAMES[clampi(plane, 0, NAMES.size() - 1)], " ".join(counts), hint, blocked
	]
