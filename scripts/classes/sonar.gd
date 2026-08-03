class_name Sonar
extends Node
## The Sneak's class ability: sound out the layer directly below and leave thieves' cant.
##
## Q has one meaning per class. For an Engineer it is CaveIn; for a Sneak it sends a short-range
## pulse through the floor. Detected tunnel cells shimmer briefly on the ground above, then the
## nearest answer becomes a persistent mark shared with the crew. The mark reveals a PLACE, not
## the connected enemy route, preserving the hidden-information boundary M5 is built around.
##
## Enemy Sneaks can read the cant. Standing beside one and pressing Q erases it instead of
## scanning, making information itself something the two Sneaks contest.

signal scanned(source_plane: int, target_plane: int, cells: Array[Vector2i])
signal marked(mark: SonarMark)
signal cleared(mark: SonarMark, by_team: int)
signal refused(reason: String)

const SONAR_GROUP: StringName = &"sonar"

@export var player_path: NodePath
@export var network_path: NodePath

@export_group("Ability")
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.SNEAK
## Radius on the layer below, measured from the cell under the Sneak.
@export var radius_cells: float = 5.0
@export var cooldown: float = 6.0
## How long the detected floor plan glows before resolving back to a single cant mark.
@export var echo_seconds: float = 1.8
## Arm's reach for rubbing out an enemy mark.
@export var erase_reach_cells: float = 1.6

var _player: Mouse
var _network: TunnelNetwork
var _cooldown_left: float = 0.0
var _marks: Array[SonarMark] = []
var _echo: MeshInstance3D
var _echo_material: StandardMaterial3D
var _echo_left: float = 0.0


func _ready() -> void:
	add_to_group(SONAR_GROUP)
	_player = get_node_or_null(player_path) as Mouse
	_network = get_node_or_null(network_path) as TunnelNetwork
	if _player == null or _network == null:
		push_warning("sonar: needs a player and a network -- the ability is off")
		set_process(false)
		set_process_unhandled_input(false)
		return
	refused.connect(_network.dig_refused.emit)


func _process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_echo_left = maxf(0.0, _echo_left - delta)
	if is_instance_valid(_echo):
		var alpha := clampf(_echo_left / maxf(echo_seconds, 0.01), 0.0, 1.0)
		_echo_material.albedo_color.a = alpha * (0.42 + 0.30 * sin(Time.get_ticks_msec() * 0.018))
		if _echo_left <= 0.0:
			_echo.queue_free()
			_echo = null

	# World marks obey the same visibility rule the minimap asks: yours are crew knowledge;
	# theirs are legible only to a Sneak. Different layers do not bleed through one another.
	for mark: SonarMark in _marks:
		if is_instance_valid(mark):
			mark.visible = (
				mark.plane == _player.get_plane()
				and mark.can_be_seen_by(_player.team, _player.mouse_class)
			)


func cooldown_left() -> float:
	return _cooldown_left


func marks_for(viewer_team: int, viewer_class: int, plane: int) -> Array[SonarMark]:
	var visible_marks: Array[SonarMark] = []
	for mark: SonarMark in _marks:
		if (
			is_instance_valid(mark) and mark.plane == plane
			and mark.can_be_seen_by(viewer_team, viewer_class)
		):
			visible_marks.append(mark)
	return visible_marks


func can_erase_enemy_mark() -> bool:
	return (
		_player != null and _player.mouse_class == owner_class
		and _nearest_enemy_mark() != null
	)


## Scan now. Public so the invariant audit can exercise the rule without faking input routing.
func scan() -> int:
	if _player == null or _network == null or _player.mouse_class != owner_class:
		return 0
	var source_plane := _player.get_plane()
	if source_plane + 1 >= TunnelNetwork.PLANE_COUNT:
		refused.emit("nothing but bedrock below")
		return 0
	if _cooldown_left > 0.0:
		refused.emit("listening for the echo -- %ds" % ceili(_cooldown_left))
		return 0

	var target_plane := source_plane + 1
	var here := _network.world_to_cell(_player.global_position)
	var found: Array[Vector2i] = []
	for cell: Vector2i in _network.dug_cells(target_plane):
		if Vector2(cell - here).length() <= radius_cells:
			found.append(cell)
	_cooldown_left = cooldown
	scanned.emit(source_plane, target_plane, found)

	if found.is_empty():
		refused.emit("nothing answers below")
		return 0

	found.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2(a - here).length_squared() < Vector2(b - here).length_squared()
	)
	_show_echo(source_plane, found)
	_place_mark(source_plane, found[0])
	return found.size()


## READ ON THE PHYSICS TICK, NOT FROM AN INPUT EVENT (M7).
##
## This was an `_unhandled_input` handler, which is the natural way to write it and the one shape
## that cannot survive a server: an event handler fires on *this* machine's event stream, and a
## server has no such stream for a peer three hundred miles away. It now reads the same
## [InputFrame] everything else does, so a packet drives it exactly as a keyboard does.
##
## `_physics_process` AND NOT `_process`, and that distinction is load-bearing. The frame is built
## once per physics tick and its pressed bits stay latched for that whole tick; idle frames can run
## more than once per physics tick on a fast display, and this ability would fire twice from one
## keypress at 120Hz and once at 60Hz. Cooldown ticking stays in `_process` -- that is a wall
## clock, and it does not care.
##
## Nothing consumes the press any more. `set_input_as_handled` used to stop two ability nodes
## reacting to the same key; the class gate below was always what actually did that work, since
## only one node's `owner_class` can match the mouse.
func _physics_process(_delta: float) -> void:
	if _player == null:
		return
	if not _player.input().is_pressed(InputFrame.Action.ABILITY):
		return
	if _player.is_scruffed() or _player.mouse_class != owner_class:
		return

	var enemy := _nearest_enemy_mark()
	if enemy != null:
		_clear(enemy, _player.team)
		return

	scan()


func _place_mark(source_plane: int, cell: Vector2i) -> SonarMark:
	for existing: SonarMark in _marks:
		if (
			is_instance_valid(existing) and existing.owner_team == _player.team
			and existing.plane == source_plane and existing.cell == cell
		):
			return existing

	var mark := SonarMark.new()
	_network.add_child(mark)
	mark.configure(_network, _player.team, source_plane, cell)
	_marks.append(mark)
	marked.emit(mark)
	return mark


func _nearest_enemy_mark() -> SonarMark:
	var nearest: SonarMark
	var nearest_distance := INF
	var here := _network.world_to_cell(_player.global_position)
	for mark: SonarMark in _marks:
		if (
			not is_instance_valid(mark) or mark.owner_team == _player.team
			or mark.plane != _player.get_plane()
		):
			continue
		var distance := Vector2(mark.cell - here).length()
		if distance <= erase_reach_cells and distance < nearest_distance:
			nearest = mark
			nearest_distance = distance
	return nearest


func _clear(mark: SonarMark, by_team: int) -> bool:
	if not is_instance_valid(mark) or mark.owner_team == by_team:
		return false
	_marks.erase(mark)
	cleared.emit(mark, by_team)
	mark.queue_free()
	return true


func _show_echo(source_plane: int, cells: Array[Vector2i]) -> void:
	if is_instance_valid(_echo):
		_echo.queue_free()
	_echo = MeshInstance3D.new()
	_echo.name = "SonarEcho"
	_echo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_network.add_child(_echo)

	_echo_material = StandardMaterial3D.new()
	_echo_material.albedo_color = Color(0.42, 0.92, 0.94, 0.7)
	_echo_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_echo_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_echo_material.vertex_color_use_as_albedo = true
	_echo_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_LINES)
	tool.set_material(_echo_material)
	var half := TunnelNetwork.CELL * 0.43
	var y := _network.plane_y(source_plane) + 0.045
	for cell: Vector2i in cells:
		var centre := _network.cell_to_world(source_plane, cell)
		var corners := [
			Vector3(centre.x - half, y, centre.z - half),
			Vector3(centre.x + half, y, centre.z - half),
			Vector3(centre.x + half, y, centre.z + half),
			Vector3(centre.x - half, y, centre.z + half),
		]
		for edge in [[0, 1], [1, 2], [2, 3], [3, 0]]:
			for index: int in edge:
				tool.set_color(Color.WHITE)
				tool.add_vertex(corners[index])
	_echo.mesh = tool.commit()
	_echo_left = echo_seconds
