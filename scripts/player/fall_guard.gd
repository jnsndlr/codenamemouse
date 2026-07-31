extends Node
## Puts the player back on the surface if they end up below the world.
##
## The holes that used to exist -- oversized entrance cuts, unwalled ramp flanks -- went with
## ramps themselves, and tools/tunnel_audit.gd now walks the player's own capsule out of every
## cell in eight directions looking for more. Even so: a spike where every geometry bug ends
## in falling forever is miserable to iterate on, and the network gains new ways to have gaps
## every time it grows. This is the backstop, not the fix.
##
## Deliberately a respawn rather than a solid floor under the map. A floor stops the fall
## and then leaves you standing in a sealed void with no way back, which is a worse bug
## than the one it hides. Respawning is recoverable and it's loud -- the counter makes it
## obvious something is leaking rather than quietly papering over it.

@export var player_path: NodePath
## Anything below this is out of the world. Comfortably under the deepest tunnel, which now
## sits at -1.95 -- nothing descends gradually any more, so no legitimate movement approaches it.
@export var kill_y: float = -5.0
@export var respawn_at: Vector3 = Vector3(0.0, 0.6, 0.0)

var _player: Node3D
var _falls: int = 0


func _ready() -> void:
	_player = get_node_or_null(player_path) as Node3D


func get_fall_count() -> int:
	return _falls


func _physics_process(_delta: float) -> void:
	if _player == null or _player.global_position.y > kill_y:
		return

	_falls += 1
	push_warning("fell out of the world at %v -- respawning (fall %d)" % [
		_player.global_position, _falls
	])
	_player.global_position = respawn_at
	if _player is CharacterBody3D:
		(_player as CharacterBody3D).velocity = Vector3.ZERO
