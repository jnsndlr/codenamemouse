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
## ONE LAYER AT A TIME, the one you are standing on -- the same rule the world itself follows
## (depth_focus.gd draws the focused plane and nothing else). This used to draw all four at once,
## and stacked they are not a map of anything: two corridors a plane apart cross on the panel
## without touching in the world, so the picture asserts junctions that do not exist, and a deep
## network fills the yard with routes you cannot take from where you are. On the surface it draws
## the shaft mouths instead, which is the only part of the network that means anything from up
## there.
##
## TUNNELS ARE CREW KNOWLEDGE. A cell your crew cuts appears; an enemy cell does not. If the two
## routes meet, the physical intersection exists in the world without donating either connected
## floor plan to the other map. Sonar adds a cant mark at one detected place, never the route.

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
## A shaft mouth, seen from the lawn -- the only part of the network drawn while you are on the
## surface. Bright, because it is a handful of tiles on an otherwise empty panel and it is answering
## "where do I get in", not "what does the network look like".
@export var mouth_color: Color = Color(0.98, 0.86, 0.55, 0.95)
## Thieves' cant left by a Sneak. Large enough to find, small enough not to read as an objective.
@export var cant_size: float = 5.0
## How solid an enemy cell you can currently SEE is drawn, against your own at full strength. It
## multiplies the staleness fade rather than replacing it, so even a fresh sighting reads as the
## weaker fact -- which it is. Your own corridor is a floor plan; theirs is a thing you glimpsed.
@export_range(0.0, 1.0, 0.05) var enemy_seen_alpha: float = 0.55

var _director: MatchDirector
var _network: TunnelNetwork
var _rig: Node3D
var _spotting: Spotting
var _sonar: Sonar
var _sight: TunnelSight
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


func _process(_delta: float) -> void:
	if _spotting == null:
		_spotting = get_tree().get_first_node_in_group(Spotting.SPOTTING_GROUP) as Spotting
	if _sonar == null:
		_sonar = get_tree().get_first_node_in_group(Sonar.SONAR_GROUP) as Sonar
	if _sight == null:
		_sight = get_tree().get_first_node_in_group(TunnelSight.SIGHT_GROUP) as TunnelSight
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
	_cant_marks()
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


## The dug cells on the layer you are standing on, and nothing from the others.
##
## ONE PLANE, and this used to draw all four. Stacked, they are not a map of anything: two corridors
## a plane apart cross on this panel without touching in the world, so the picture asserts a
## junction that does not exist -- and the deeper a network goes, the more of the yard fills with
## routes you cannot take from where you are. The whole point of four floors is that they DIFFER,
## which is the same argument the rock below already makes, and drawing them together throws away
## the one thing the depth is for. What this panel has to answer is "where can I go from here".
##
## The depth tint stays even though only one layer is drawn at a time: it is now telling you HOW
## DEEP the corridors you are looking at are, which is the readout it was always really giving.
##
## ON THE SURFACE it draws the MOUTHS. Plane 0 has no dug cells -- the lawn is not a tunnel -- so
## "the plane you are on" would be blank up there, and the one thing about the network that matters
## from the grass is where you can get into it.
func _tunnel_cells() -> void:
	if _network == null or _director == null:
		return
	var player := _director.get_player()
	var plane := player.get_plane() if player != null else 0
	var team := player.team if player != null else Team.BLUE

	# A touch wider than a cell. Drawn at exactly one cell, adjacent tiles leave hairline seams at
	# this scale and a corridor reads as a dotted line rather than as a route you could take.
	var side := maxf(TunnelNetwork.CELL, _pixel(tunnel_min * _ui)) * 1.15
	var depth := float(plane) / float(TunnelNetwork.PLANE_COUNT)
	var colour := Color(0.50, 0.36, 0.22, 0.85).lerp(Color(0.24, 0.18, 0.13, 0.6), depth)

	if plane <= 0:
		for cell: Vector2i in _network.known_shaft_cells(0, team):
			var mouth := Vector2(cell.x, cell.y) * TunnelNetwork.CELL
			draw_rect(Rect2(mouth - Vector2(side, side) * 0.5, Vector2(side, side)), mouth_color, true)
		# Theirs, if somebody walked past it. Same glyph, thinning out -- an entrance you found is
		# the same KIND of fact as one you cut, and the only difference is how long ago you were
		# sure of it. A different symbol would say it was a different kind of hole.
		if _sight != null:
			var mouths: Dictionary = _sight.seen_mouths(team)
			for cell: Vector2i in mouths:
				var at := Vector2(cell.x, cell.y) * TunnelNetwork.CELL
				var faded := mouth_color
				faded.a *= float(mouths[cell]) * enemy_seen_alpha
				draw_rect(Rect2(at - Vector2(side, side) * 0.5, Vector2(side, side)), faded, true)
		return

	for cell: Vector2i in _network.known_tunnel_cells(plane, team):
		var centre := Vector2(cell.x, cell.y) * TunnelNetwork.CELL
		draw_rect(Rect2(centre - Vector2(side, side) * 0.5, Vector2(side, side)), colour, true)

	# ENEMY GROUND YOU HAVE LAID EYES ON, fading as your crew forgets it (M5). Drawn in the same
	# earth colour rather than in a "them" colour, because the map is not naming an owner -- it is
	# saying THERE IS FLOOR HERE, and the alpha is saying how sure you still are. A corridor that
	# stopped at a bend, thinning out over fifteen seconds, is the honest picture of what a breach
	# actually taught you.
	if _sight == null:
		return
	var remembered: Dictionary = _sight.seen_cells(team, plane)
	for cell: Vector2i in remembered:
		var at := Vector2(cell.x, cell.y) * TunnelNetwork.CELL
		var faded := colour
		faded.a *= float(remembered[cell]) * enemy_seen_alpha
		draw_rect(Rect2(at - Vector2(side, side) * 0.5, Vector2(side, side)), faded, true)


## The seams your crew has found, on the layer you are standing on (GDD section 3).
##
## ONE PLANE, like the tunnels drawn under it. Four layouts stacked on a 200-pixel square is a grey
## smear that says "there is rock somewhere", which is the one thing you already knew -- the value
## of per-plane obstructions is precisely that they DIFFER. What you want to read here is "what is
## in my way, here, now", and the answer changes as you climb.
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


## Persistent tunnel locations sounded out by a Sneak. Your crew sees its own cant; an enemy
## Sneak sees the marks too, because finding and erasing them is the counterplay.
func _cant_marks() -> void:
	if _sonar == null or _director == null:
		return
	var player := _director.get_player()
	if player == null:
		return
	for mark: SonarMark in _sonar.marks_for(player.team, player.mouse_class, player.get_plane()):
		var at := _at(mark.global_position)
		var colour := Team.color_of(mark.owner_team).lerp(Color(0.95, 0.91, 0.72), 0.55)
		var size := cant_size * _ui
		var stroke := 1.5 * _ui
		draw_polyline(
			PackedVector2Array([at + Vector2(-size, -size * 0.35), at, at + Vector2(size, -size * 0.35)]),
			colour, stroke
		)
		draw_line(at, at + Vector2(0.0, size), colour, stroke)


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
