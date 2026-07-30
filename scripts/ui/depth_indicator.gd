extends Label
## HUD depth readout (GDD section 3 and 10): am I at surface, 1, 2 or 3?
##
## Text, not an icon, and deliberately blunt. This is a spike instrument -- if the 3D
## rendering is doing its job you should already know your depth without reading this,
## and catching yourself glancing at it is itself a result worth recording.

const NAMES: Array[String] = ["SURFACE", "DEPTH 1", "DEPTH 2", "DEPTH 3"]

@export var network_path: NodePath
@export var player_path: NodePath

var _network: TunnelNetwork
var _player: Node3D


func _ready() -> void:
	_network = get_node_or_null(network_path) as TunnelNetwork
	_player = get_node_or_null(player_path) as Node3D


func _process(_delta: float) -> void:
	if _network == null or _player == null:
		return

	var plane := _network.plane_at_height(_player.global_position.y)
	var counts: Array[String] = []
	for index in range(1, TunnelNetwork.PLANE_COUNT):
		var marker := ">" if index == plane else " "
		counts.append("%s%d:%d" % [marker, index, _network.cell_count(index)])

	# Sprint is spelled out because double-tap W is invisible until someone tells you, and
	# not knowing whether you *can* sprint reads as the tunnels being sluggish.
	var hint := (
		"hold E: burrow in     double-tap W: sprint" if plane <= 0
		else "hold E: dig (steer with cursor)     R: ramp down     F: ramp up"
			+ "\ndouble-tap W: sprint     shift: slow"
	)
	text = "%s\n%s\n\n%s" % [
		NAMES[clampi(plane, 0, NAMES.size() - 1)], " ".join(counts), hint
	]
