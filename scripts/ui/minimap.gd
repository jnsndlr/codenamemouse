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
## Rock your crew has found. Cool and pale against the warm dirt of the panel, the same argument
## the seam faces make in the world -- and deliberately NOT the colour a tunnel is, because the two
## are drawn on top of each other and the question they answer together is where a corridor had to
## stop.
@export var rock_color: Color = Color(0.44, 0.48, 0.55, 0.85)

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
## The HUD's own size multiplier, so markers stay the same size RELATIVE TO THE PANEL rather
## than staying the same number of pixels while the map around them grows.
var _ui: float = 1.0


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

	var screen := get_viewport_rect().size
	# Written against a 1280x720 window and scaled out, like the rest of the HUD.
	var ui := HudSkin.scale_for(screen)
	var side := map_size * ui
	var edge := margin * ui
	var frame := Rect2(Vector2(edge, screen.y - side - edge), Vector2(side, side))
	HudSkin.panel(self, frame, 10.0 * ui)
	var map := frame.grow(-7.0 * ui)
	HudSkin.well(self, map, 4.0 * ui)
	_ui = ui

	# Fits the arena at any quarter turn: rotated forty-five degrees a square is its own diagonal
	# across, so scaling to that keeps the yard inside the well however the camera is pointing.
	_scale = (map.size.x * 0.5) / (world_extent * sqrt(2.0))
	_origin = map.get_center()
	_yaw = _rig.rotation.y if _rig != null else 0.0

	draw_set_transform(_origin, _yaw, Vector2(_scale, _scale))
	_ground()
	# Under the tunnels, because a corridor is a route and a seam is the ground it was cut through
	# -- and where the two meet, what you want to see is that the corridor stops.
	_known_rock()
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
		Color(0.36, 0.30, 0.20, 0.8), _pixel(1.5 * _ui)
	)


## Every dug cell, deeper planes dimmer -- so a network you have driven three planes down reads
## as depth rather than as one flat blob.
func _tunnel_cells() -> void:
	if _network == null:
		return
	# A touch wider than a cell. Drawn at exactly one cell, adjacent tiles leave hairline seams at
	# this scale and a corridor reads as a dotted line rather than as a route you could take.
	var side := maxf(TunnelNetwork.CELL, _pixel(tunnel_min * _ui)) * 1.15
	for plane in range(TunnelNetwork.PLANE_COUNT):
		_refresh_plane(plane)
		if _tunnels[plane].is_empty():
			continue
		var depth := float(plane) / float(TunnelNetwork.PLANE_COUNT)
		var colour := Color(0.50, 0.36, 0.22, 0.85).lerp(Color(0.24, 0.18, 0.13, 0.6), depth)
		for centre: Vector2 in _tunnels[plane]:
			draw_rect(Rect2(centre - Vector2(side, side) * 0.5, Vector2(side, side)), colour, true)


## The seams your crew has found, on the layer you are standing on (GDD section 3).
##
## ONE PLANE, NOT ALL FOUR, which is the opposite of what the tunnels do a few lines below and is
## deliberate. Tunnels are drawn at every depth because seeing the network you have built is the
## point of having built it; rock is drawn at one depth because its whole value is that the layouts
## DIFFER between layers -- four of them stacked on a 200-pixel square is a grey smear that says
## "there is rock somewhere", which is the one thing you already knew. What you want to read here
## is "what is in my way, here, now", and the answer changes as you climb.
##
## YOUR CREW'S KNOWLEDGE, not the map's. The rock that has not been found is not drawn faintly or
## drawn differently -- it is not drawn, because this panel is the one place a leak would be
## invisible, and the same rule governs enemy contacts a few lines further down.
func _known_rock() -> void:
	if _network == null:
		return
	var player := _director.get_player()
	if player == null:
		return
	var plane := player.get_plane()
	if plane <= 0:
		return

	var side := player.team
	# Refreshed every frame rather than cached against a count like the tunnels are: a reveal
	# changes dozens of cells at once and the count would have to be per team as well, which is
	# more bookkeeping than walking a dictionary of a few dozen keys once a frame.
	var side_length := maxf(TunnelNetwork.CELL, _pixel(tunnel_min * _ui)) * 1.15
	var box := Vector2(side_length, side_length)
	for cell: Vector2i in _network.known_rock_cells(plane, side):
		var centre := Vector2(cell.x, cell.y) * TunnelNetwork.CELL
		draw_rect(Rect2(centre - box * 0.5, box), rock_color, true)


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
		var reach := maxf(nest.radius * _scale, nest_min * _ui)
		draw_rect(
			Rect2(at - Vector2(reach, reach), Vector2(reach, reach) * 2.0),
			Color(colour.r, colour.g, colour.b, 0.28), true
		)
		draw_rect(
			Rect2(at - Vector2(reach, reach), Vector2(reach, reach) * 2.0),
			Color(colour.r, colour.g, colour.b, 0.85), false, 1.5 * _ui
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
			draw_arc(at, crew_dot * _ui, 0.0, TAU, 14, colour, 1.6 * _ui)
		else:
			draw_circle(at, crew_dot * _ui, colour)
			draw_arc(at, crew_dot * _ui, 0.0, TAU, 14, Color(0, 0, 0, 0.5), 1.0 * _ui)


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
			draw_circle(at, crew_dot * _ui, shade)
			if int(entry["plane"]) > 0:
				draw_arc(at, (crew_dot + 2.5) * _ui, 0.0, TAU, 14, shade, 1.2 * _ui)
		else:
			draw_arc(at, crew_dot * _ui, 0.0, TAU, 14, shade, 1.8 * _ui)


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
			draw_circle(at, banner_glyph * 0.75 * _ui, Color(colour.r, colour.g, colour.b, beat * 0.5))
			draw_arc(at, banner_glyph * 0.75 * _ui, 0.0, TAU, 18, Color(colour.r, colour.g, colour.b, beat), 1.4 * _ui)
		# The foot of the pole is the banner's actual spot; the cloth flies up and to the right.
		HudSkin.flag(self, at + Vector2(-1.0 * _ui, banner_glyph * 0.4 * _ui), banner_glyph * _ui, colour)


## You, pointing where you are pointing. The heading is turned by the same yaw the ground is, so
## the wedge on the map and the mouse on the screen face the same way.
func _wedge(at: Vector2, facing: Vector3, colour: Color) -> void:
	var ahead := Vector2(facing.x, facing.z).rotated(_yaw)
	if ahead.length_squared() < 0.0001:
		ahead = Vector2.UP
	ahead = ahead.normalized()
	var across := Vector2(-ahead.y, ahead.x)
	draw_colored_polygon(PackedVector2Array([
		at + ahead * 7.0 * _ui,
		at - ahead * 4.0 * _ui + across * 4.2 * _ui,
		at - ahead * 4.0 * _ui - across * 4.2 * _ui,
	]), Color(0, 0, 0, 0.55))
	draw_colored_polygon(PackedVector2Array([
		at + ahead * 5.5 * _ui,
		at - ahead * 3.0 * _ui + across * 3.2 * _ui,
		at - ahead * 3.0 * _ui - across * 3.2 * _ui,
	]), colour)
