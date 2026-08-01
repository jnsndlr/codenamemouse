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


func _ready() -> void:
	_network = get_node_or_null(network_path) as TunnelNetwork
	_player = get_node_or_null(player_path) as Node3D
	if _network != null:
		_network.dig_refused.connect(_on_dig_refused)


## The tunnel has real placement rules -- no shaft without floor to sink it from, none on a
## cell another shaft already reaches, none from the deepest plane. Every one refuses a
## keypress, and a refused keypress with no feedback is indistinguishable from a broken
## control. Saying why costs one line of HUD.
func _on_dig_refused(reason: String) -> void:
	_refusal = reason
	_refusal_left = refusal_seconds


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
		else "aim + hold LMB: dig a tile     F: shaft down     R: shaft up"
			+ "\narrows: turn view     double-tap W: sprint     shift: slow"
	)
	var blocked := "\n\nBLOCKED: %s" % _refusal if _refusal_left > 0.0 else ""
	text = "%s\n%s\n\n%s%s" % [
		NAMES[clampi(plane, 0, NAMES.size() - 1)], " ".join(counts), hint, blocked
	]
