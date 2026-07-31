extends Control
## The yard from above: nests, banners, your crew, the tunnels, and whatever you've spotted.
##
## IT TURNS WITH THE VIEW. The camera swivels in quarter turns (arrows), and a fixed north-up
## map would mean that after one turn every direction on the map is a translation away from the
## direction you would actually run. Rotating the map keeps "up on the map" and "up the screen"
## the same thing, which is the only property that makes a minimap usable at a glance rather
## than a puzzle. It also produces the diamond the concept art draws, for free: the yard is a
## square seen at forty-five degrees, which is exactly how it appears on screen.
##
## THE GROUND TURNS; THE MARKERS DO NOT. The yard and the tunnels are drawn under a transform
## that carries the rotation, because they are terrain and rotating them is the whole point. The
## markers on top are drawn in screen space through `_at`, because a flag glyph lying on its side
## after two quarter turns is not a flag any more. Only the player's wedge takes the rotation,
## and it takes it deliberately: it is a heading, and a heading is terrain.
##
## WHAT IT SHOWS OF THE ENEMY IS A DESIGN DECISION, and it lives in spotting.gd rather than
## here: contacts your crew has actually seen, held for a while after they break line of sight,
## and frozen at the last place they were seen rather than tracking them through a wall. This
## file only draws the difference between a live contact and a stale one -- filled versus hollow
## -- because that difference is the one you act on.
##
## Tunnels are drawn for BOTH crews at all four planes, which is more than M5 will allow once
## per-team tunnel visibility lands. It is the right amount for a spike: the whole point of
## having dug something is being able to see that you have.

@export var director_path: NodePath
@export var network_path: NodePath
@export var camera_rig_path: NodePath

@export_group("Layout")
## Outer edge of the panel, in pixels. Square.
@export var map_size: float = 206.0
@export var margin: float = 18.0
## Half the arena, in metres -- the walls sit at plus and minus this.
@export var world_extent: float = 40.0

@export_group("Markers")
@export var crew_dot: float = 3.4
## Height of a banner glyph, in pixels. The banners are what the match is about and they are
## drawn last, over everything.
@export var banner_glyph: float = 15.0
## Smallest a nest may draw, in pixels. Its actual radius comes out around four pixels on a map
## this size, which is a dot -- and a dot that looks exactly like a mouse.
@export var nest_min: float = 9.0
## Screen pixels a dug cell draws as, at minimum. Below about this a corridor stops reading as
## a line and starts reading as noise.
@export var tunnel_min: float = 1.6

var _director: MatchDirector
var _network: TunnelNetwork
var _rig: Node3D
var _spotting: Spotting
## Per plane: the cell centres, in world XZ. Rebuilt only when the count changes -- the map is
## redrawn sixty times a second and the network changes a few times a minute.
var _tunnels: Array[PackedVector2Array] = []
var _counted: Array[int] = []
## Metres to pixels, and where the middle of the yard sits on screen. Both settled once a frame
## in `_draw`, because `_at` is called a few dozen times after that.
var _scale: float = 1.0
var _origin: Vector2 = Vector2.ZERO
var _yaw: float = 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_director = get_node_or_null(director_path) as MatchDirector
	_network = get_node_or_null(network_path) as TunnelNetwork
	_rig = get_node_or_null(camera_rig_path) as Node3D
	for plane in range(TunnelNetwork.PLANE_COUNT):
		_tunnels.append(PackedVector2Array())
		_counted.append(-1)


func _process(_delta: float) -> void:
	if _spotting == null:
		_spotting = get_tree().get_first_node_in_group(Spotting.SPOTTING_GROUP) as Spotting
	queue_redraw()


func _draw() -> void:
	if _director == null:
		return

	var frame := Rect2(
		Vector2(margin, get_viewport_rect().size.y - map_size - margin), Vector2(map_size, map_size)
	)
	HudSkin.panel(self, frame)
	var map := frame.grow(-7.0)
	HudSkin.well(self, map, 4.0)

	# Fits the arena at any quarter turn: rotated forty-five degrees a square is its own diagonal
	# across, so scaling to that keeps the yard inside the well however the camera is pointing.
	_scale = (map.size.x * 0.5) / (world_extent * sqrt(2.0))
	_origin = map.get_center()
	_yaw = _rig.rotation.y if _rig != null else 0.0

	draw_set_transform(_origin, _yaw, Vector2(_scale, _scale))
	_ground()
	_tunnel_cells()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	_nests()
	_mice()
	_contacts()
	_banners()


## A world position as a point on the map. The rotation is the camera's, so up here is up there.
func _at(world: Vector3) -> Vector2:
	return _origin + Vector2(world.x, world.z).rotated(_yaw) * _scale


## World metres per screen pixel, for the two things still drawn under the transform.
func _pixel(pixels: float) -> float:
	return pixels / maxf(_scale, 0.0001)


func _ground() -> void:
	var e := world_extent
	draw_colored_polygon(
		PackedVector2Array([Vector2(-e, -e), Vector2(e, -e), Vector2(e, e), Vector2(-e, e)]),
		Color(0.19, 0.21, 0.14, 0.9)
	)
	draw_polyline(
		PackedVector2Array([
			Vector2(-e, -e), Vector2(e, -e), Vector2(e, e), Vector2(-e, e), Vector2(-e, -e)
		]),
		Color(0.36, 0.30, 0.20, 0.8), _pixel(1.5)
	)


## Every dug cell, deeper planes dimmer -- so a network you have driven three planes down reads
## as depth rather than as one flat blob.
func _tunnel_cells() -> void:
	if _network == null:
		return
	# A touch wider than a cell. Drawn at exactly one cell, adjacent tiles leave hairline seams at
	# this scale and a corridor reads as a dotted line rather than as a route you could take.
	var side := maxf(TunnelNetwork.CELL, _pixel(tunnel_min)) * 1.15
	for plane in range(TunnelNetwork.PLANE_COUNT):
		_refresh_plane(plane)
		if _tunnels[plane].is_empty():
			continue
		var depth := float(plane) / float(TunnelNetwork.PLANE_COUNT)
		var colour := Color(0.50, 0.36, 0.22, 0.85).lerp(Color(0.24, 0.18, 0.13, 0.6), depth)
		for centre: Vector2 in _tunnels[plane]:
			draw_rect(Rect2(centre - Vector2(side, side) * 0.5, Vector2(side, side)), colour, true)


func _refresh_plane(plane: int) -> void:
	var count := _network.cell_count(plane)
	if count == _counted[plane]:
		return
	_counted[plane] = count
	var points := PackedVector2Array()
	for cell: Vector2i in _network.dug_cells(plane):
		points.append(Vector2(cell.x, cell.y) * TunnelNetwork.CELL)
	_tunnels[plane] = points


## A nest is a PLATE, not a circle. At this scale its real radius comes out about the size of a
## mouse marker, and two things that mean completely different things must not be the same dot.
func _nests() -> void:
	for side in [Team.BLUE, Team.RED]:
		var nest := _director.nest_of(side)
		if nest == null:
			continue
		var at := _at(nest.global_position)
		var colour := Team.color_of(side)
		var reach := maxf(nest.radius * _scale, nest_min)
		draw_rect(
			Rect2(at - Vector2(reach, reach), Vector2(reach, reach) * 2.0),
			Color(colour.r, colour.g, colour.b, 0.28), true
		)
		draw_rect(
			Rect2(at - Vector2(reach, reach), Vector2(reach, reach) * 2.0),
			Color(colour.r, colour.g, colour.b, 0.85), false, 1.5
		)


## Your own crew, always. The player is a wedge rather than a dot, because on a map where every
## marker is a circle you spend the first half-second finding yourself.
func _mice() -> void:
	var player := _director.get_player()
	var side := player.team if player != null else Team.BLUE
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or mouse.team != side:
			continue
		var at := _at(mouse.global_position)
		var colour := Team.color_of(side)
		if mouse.is_scruffed():
			colour = colour.lerp(Color(0.3, 0.3, 0.3), 0.6)

		if mouse == player:
			_wedge(at, mouse.get_facing_direction(), Color(0.98, 0.98, 0.94))
		elif mouse.get_plane() > 0:
			# Underground reads as hollow, for crew and contacts alike. Same rule twice, so a
			# ring anywhere on this map means "not on the surface".
			draw_arc(at, crew_dot, 0.0, TAU, 14, colour, 1.6)
		else:
			draw_circle(at, crew_dot, colour)
			draw_arc(at, crew_dot, 0.0, TAU, 14, Color(0, 0, 0, 0.5), 1.0)


## What your crew has seen of theirs. Filled while somebody can see them; hollow, fading, and
## pinned where they were last seen once nobody can.
func _contacts() -> void:
	if _spotting == null or _director == null:
		return
	var player := _director.get_player()
	var side := player.team if player != null else Team.BLUE
	var colour := Team.color_of(Team.other(side))

	for key: Variant in _spotting.contacts_for(side).keys():
		var entry: Dictionary = _spotting.contacts_for(side)[key]
		var trust := _spotting.confidence(entry)
		if trust <= 0.0:
			continue
		var at := _at(entry["at"])
		var shade := Color(colour.r, colour.g, colour.b, trust)
		if entry["live"]:
			draw_circle(at, crew_dot, shade)
			if int(entry["plane"]) > 0:
				draw_arc(at, crew_dot + 2.5, 0.0, TAU, 14, shade, 1.2)
		else:
			draw_arc(at, crew_dot, 0.0, TAU, 14, shade, 1.8)


## Both banners, over the top of everything, because they are what the match is about. Drawn as
## the same little flag the score bug uses, so the thing you are looking for on the map and the
## thing you are watching in the corner are visibly the same object.
func _banners() -> void:
	for side in [Team.BLUE, Team.RED]:
		var banner := _director.banner_of(side)
		if banner == null:
			continue
		var colour := Team.color_of(side)
		var at := _at(banner.global_position)
		if banner.state == Banner.DROPPED:
			# A dropped banner is a clock running for both crews. It should be the thing your eye
			# lands on when you check the map.
			var beat := lerpf(0.25, 0.9, HudSkin.pulse(3.6))
			draw_circle(at, banner_glyph * 0.75, Color(colour.r, colour.g, colour.b, beat * 0.5))
			draw_arc(at, banner_glyph * 0.75, 0.0, TAU, 18, Color(colour.r, colour.g, colour.b, beat), 1.4)
		# The foot of the pole is the banner's actual spot; the cloth flies up and to the right.
		HudSkin.flag(self, at + Vector2(-1.0, banner_glyph * 0.4), banner_glyph, colour)


## You, pointing where you are pointing. The heading is turned by the same yaw the ground is, so
## the wedge on the map and the mouse on the screen face the same way.
func _wedge(at: Vector2, facing: Vector3, colour: Color) -> void:
	var ahead := Vector2(facing.x, facing.z).rotated(_yaw)
	if ahead.length_squared() < 0.0001:
		ahead = Vector2.UP
	ahead = ahead.normalized()
	var across := Vector2(-ahead.y, ahead.x)
	draw_colored_polygon(PackedVector2Array([
		at + ahead * 7.0,
		at - ahead * 4.0 + across * 4.2,
		at - ahead * 4.0 - across * 4.2,
	]), Color(0, 0, 0, 0.55))
	draw_colored_polygon(PackedVector2Array([
		at + ahead * 5.5,
		at - ahead * 3.0 + across * 3.2,
		at - ahead * 3.0 - across * 3.2,
	]), colour)
