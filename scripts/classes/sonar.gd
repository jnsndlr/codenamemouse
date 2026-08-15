class_name Sonar
extends MouseControl
## The Sneak's class ability: sound out the layer directly below and leave thieves' cant.
##
## Q has one meaning per class. For a Brute it is CaveIn; for a Sneak it sends a short-range
## pulse through the floor. Detected tunnel cells shimmer briefly on the ground above, then the
## nearest answer becomes a persistent mark shared with the crew. The mark reveals a PLACE, not
## the connected enemy route, preserving the hidden-information boundary M5 is built around.
##
## Enemy Sneaks can read the cant. Standing beside one and pressing Q erases it instead of
## scanning, making information itself something the two Sneaks contest.
##
## ONE PER MOUSE SINCE M7, not one per arena (see [MouseControl]) -- AND THE MARKS DID NOT COME
## WITH IT. That split is the interesting part of the change. The ability is a thing a Sneak does
## and belongs to that Sneak; a mark is a scratch on the floor of the world, and the moment there
## were several sonars a private `_marks` array per Sneak would have meant an enemy could only rub
## out cant its own node happened to have drawn. They are read from `SonarMark.MARK_GROUP` now --
## already a group, already parented to the network, and already the world's rather than anyone's.

## Emitted when a scan resolves, whatever it found. `cells` is what answered; `owners` is the
## matching crew per cell, in the same order, using [SonarMark]'s BLUE/RED/SHARED encoding.
##
## THE TWO ARRAYS ARE PARALLEL RATHER THAN AN ARRAY OF PAIRS, because the receiving end is the
## wire, and the wire wants to write two runs of fixed-width fields rather than unpack a Variant
## per cell. It is the one place where the transport's shape is allowed to reach back into a
## signal, and it is cheap: they are built together and consumed together.
signal scanned(
	source_plane: int, target_plane: int, cells: Array[Vector2i], owners: Array[int]
)
signal marked(mark: SonarMark)
signal cleared(mark: SonarMark, by_team: int)
signal refused(reason: String)

const SONAR_GROUP: StringName = &"sonar"

@export_group("Ability")
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.SNEAK
## Radius on the layer below, measured from the cell under the Sneak.
@export var radius_cells: float = 5.0
@export var cooldown: float = 6.0
## How long the detected floor plan stays lit.
##
## `[REVISED]` THIRTY SECONDS, UP FROM 1.8. It was a shimmer -- a glimpse you had to read in the
## moment, after which only the single cant mark remained. That made the outline decoration and the
## mark the entire product of the ability, which is backwards: the outline is the part that says
## *what shape the thing is and whose it is*, and a Sneak was being given it for less time than it
## takes to turn round and look.
##
## THE TWO LIFETIMES ARE NOW THE DESIGN. The outline is a **reading**, and readings go stale: half
## a minute is long enough to sound a corridor, walk to your Brute and still have it on screen, and
## short enough that it is never a map. The mark is a **record**, and records persist -- it stays
## until an enemy Sneak rubs it out. Loud and temporary against quiet and permanent, which is the
## same pairing the spotting system already uses for mice.
##
## IT IS STILL ONE SNEAK'S PRIVATE READOUT, not the crew's. Only the mark is shared. So this is
## thirty seconds of detail for the mouse that paid the cooldown, and a place-name for everybody
## else -- which keeps M5's boundary exactly where it was and merely gives the scout time to use
## what it heard.
@export var echo_seconds: float = 30.0
## Arm's reach for rubbing out an enemy mark.
@export var erase_reach_cells: float = 1.6

@export_group("Listen")
## `[ADDED]` How long the pulse keeps finding MICE as well as corridors (GDD section 4).
##
## THE SAME KEYPRESS, DELIBERATELY NOT A SECOND ABILITY. A Sneak pressing Q was asking one question
## -- *what is under this ground* -- and the honest reading of a pulse of sound is that it comes
## back off anything in its way, not only off empty space. Folding it in costs no key, no cooldown
## and no HUD, and it makes the scan worth pressing in the two situations where it previously did
## nothing at all: standing over bedrock, and standing somewhere you already know the floor plan of.
##
## FIVE SECONDS AGAINST THE OUTLINE'S THIRTY, and the gap is the point. A corridor stays where it
## was put and a reading of one goes stale slowly; a mouse is somewhere else almost immediately, so
## a long listen would be a tracker rather than a sounding. Five is long enough to answer *is anyone
## in this room* and far too short to follow anybody with.
##
## A MILD BUFF AND NOT MEANT TO CARRY THE ABILITY. It reveals what is close and already nearby --
## inside the same radius the floor plan uses -- so it tells a scout that the room it is standing in
## is occupied. It does not find the enemy across the yard, and a crew cannot use it to sweep.
@export var listen_seconds: float = 5.0

var _listen_left: float = 0.0
## The mice this listen has picked out, and the pips drawn over them. Rebuilt each sweep rather than
## accumulated: a listen reveals who is there NOW, and somebody who has walked out of range has
## stopped being an answer.
var _pips: Dictionary = {}

@export_group("Listen")
## The pip drawn over a body the pulse found. Deliberately the WAVE's colour rather than a crew
## colour: this is the sound coming back, and what it has found is a mouse rather than a corridor.
## Crew is the echo's question and the minimap answers it -- the pip's question is *there is
## somebody there*, which is a different and more urgent one.
@export var pip_color: Color = Color(0.42, 0.92, 0.94, 0.85)

@export_group("Wave")
## How long the pulse takes to run out to `radius_cells`. Fast: it is the sound leaving, and the
## echo that follows is the part you are meant to read.
@export var wave_seconds: float = 0.55
## Its colour. Deliberately NOT a crew colour and deliberately the same for everybody: the wave is
## the ability firing, and the moment it took a hue it would start answering a question before the
## echo did -- see `_show_wave`.
@export var wave_color: Color = Color(0.42, 0.92, 0.94, 0.8)

var _echo: MeshInstance3D
var _echo_material: StandardMaterial3D
var _echo_left: float = 0.0
var _wave: MeshInstance3D
var _wave_material: StandardMaterial3D
var _wave_left: float = 0.0


func _ready() -> void:
	add_to_group(SONAR_GROUP)
	super()
	if _player == null or _network == null:
		push_warning("sonar: needs a mouse and a network -- the ability is off")
		set_process(false)
		set_physics_process(false)
		return
	refused.connect(explain)


func _process(delta: float) -> void:
	# `super` FIRST: the cooldown lives in [MouseControl] now, and GDScript overrides rather than
	# chains -- an override that forgets this line is an ability that never comes back.
	super(delta)
	_echo_left = maxf(0.0, _echo_left - delta)
	# ON EVERY MACHINE, like the cooldown and unlike the reveal. The listen's *effect* -- putting a
	# contact in the crew's book -- resolves where the simulation is, in `spotting.gd`, which reads
	# this clock through [method is_listening]. The pips below are the local viewer's own picture.
	_listen_left = maxf(0.0, _listen_left - delta)
	_step_pips()
	if is_instance_valid(_echo):
		_echo_material.albedo_color.a = _echo_alpha()
		if _echo_left <= 0.0:
			_echo.queue_free()
			_echo = null
	_step_wave(delta)

	# World marks obey the same visibility rule the minimap asks: yours are crew knowledge;
	# theirs are legible only to a Sneak. Different layers do not bleed through one another.
	#
	# DRIVEN BY THE WATCHED MOUSE'S SONAR ALONE (M7), because "is this mark on screen" is a
	# question about one pair of eyes and every Sneak in the match now owns one of these. Ten
	# sonars each answering it for their own mouse would be ten writes to one `visible` flag every
	# frame, and the mark would show whichever of them Godot ticked last.
	if not watched():
		return
	for mark: SonarMark in _all_marks():
		mark.visible = mark.can_be_seen_by(
			_player.team, _player.mouse_class, _player.get_plane()
		)


## How bright the floor plan is right now: shimmer, hold, then go.
##
## THE SHIMMER HAD TO STOP BEING THE WHOLE LIFE OF IT. At 1.8 seconds a sine pulse across the
## whole outline read as *arriving* -- the sound coming back. Across thirty it reads as a fault:
## something on the floor that will not settle, throbbing in the corner of your eye for half a
## minute while you are trying to fight. So the pulse now belongs to the first second and a half
## only, and decays out of the way.
##
## HELD FLAT IN THE MIDDLE, then faded over the last few seconds. The fade is what stops the
## outline simply vanishing between one frame and the next -- with a mark left behind on the same
## ground, an outline that blinked out would read as the mark having eaten it.
func _echo_alpha() -> float:
	var lived := maxf(echo_seconds, 0.01) - _echo_left
	var shimmer := maxf(0.0, 1.0 - lived / 1.5)
	var going := clampf(_echo_left / 3.0, 0.0, 1.0)
	return going * (0.78 + 0.22 * shimmer * sin(Time.get_ticks_msec() * 0.018))


## Is this Sneak's pulse still coming back off bodies? Read by `spotting.gd`, which is what turns
## the answer into contacts the whole crew can see.
func is_listening() -> bool:
	return _listen_left > 0.0 and _player != null and not _player.is_scruffed()


## Seconds of listen left, for a HUD.
func listen_left() -> float:
	return _listen_left


## How far the listen reaches, in metres. **The same radius as the floor plan**, converted out of
## cells, so the ability has one range rather than two -- what you hear and what you see are the
## same pulse, and a player who has learned where the outline stops has learned where this stops.
func listen_range() -> float:
	return radius_cells * TunnelNetwork.CELL


func marks_for(viewer_team: int, viewer_class: int, plane: int) -> Array[SonarMark]:
	var visible_marks: Array[SonarMark] = []
	for mark: SonarMark in _all_marks():
		if mark.can_be_seen_by(viewer_team, viewer_class, plane):
			visible_marks.append(mark)
	return visible_marks


## Every piece of cant in the arena, whoever scratched it.
##
## WALKED RATHER THAN FILTERED. `Array.filter` hands back an UNTYPED array, and assigning one to a
## typed variable aborts the call at runtime -- the same GDScript trap `barricade.gd` has a note
## about and the one that let the tunnel audit spend its whole life passing without testing
## anything.
func _all_marks() -> Array[SonarMark]:
	var found: Array[SonarMark] = []
	for node: Node in get_tree().get_nodes_in_group(SonarMark.MARK_GROUP):
		var mark := node as SonarMark
		if mark != null:
			found.append(mark)
	return found


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
	if _cooldown_left > 0.0:
		refused.emit("listening for the echo -- %ds" % ceili(_cooldown_left))
		return 0

	# THE WAVE GOES OUT BEFORE ANYTHING IS KNOWN, which is the same placement rule the stomp's dust
	# follows and for the same reason. It is the pulse LEAVING -- it cannot depend on what comes
	# back, and putting it above every branch below means it structurally cannot start to.
	_show_wave(source_plane)

	# AND THE LISTEN OPENS WITH IT, above every branch below for exactly the same reason. A pulse
	# comes back off bodies whatever the ground under them is doing, so this cannot be inside the
	# half of the ability that is about earth.
	#
	# `[ADDED]` THE BEDROCK REFUSAL MOVED BELOW THIS LINE and stopped being the end of the ability.
	# On the bottom plane there is nothing under your feet to sound, and the whole of Q used to be
	# one line of text saying so -- the same failure the wave was built to fix, left standing in the
	# one place a Sneak most wants an answer. A scan down there now still sounds, still listens, and
	# still says there is no floor plan; what it no longer does is nothing.
	_listen_left = maxf(listen_seconds, 0.0)
	_cooldown_left = cooldown

	if source_plane + 1 >= TunnelNetwork.PLANE_COUNT:
		refused.emit("nothing but bedrock below")
		return 0

	# A PUPPET RUNS THE COOLDOWN AND SOUNDS NOTHING (M7), and this is the one ability where a
	# client MUST NOT evaluate the rule even for its own eyes. A client's tunnel network holds only
	# what its crew is allowed to know (step 5) -- so a scan resolved here would echo back the
	# cells it already had and miss every one that was the point of pressing Q. It would look like
	# a working ability that never finds anything, which is worse than a silent one.
	#
	# The wave above is the exception that proves it: a client may draw the pulse going out,
	# because that is its own mouse doing a thing. What it may not do is draw what answered.
	if not acts():
		return 0

	var target_plane := source_plane + 1
	var here := _network.world_to_cell(_player.global_position)
	var found: Array[Vector2i] = []
	for cell: Vector2i in _network.dug_cells(target_plane):
		if Vector2(cell - here).length() <= radius_cells:
			found.append(cell)

	# Sorted BEFORE the owners are read off, so the two arrays are parallel and the nearest answer
	# -- the one that becomes the mark -- is index 0 of both.
	found.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2(a - here).length_squared() < Vector2(b - here).length_squared()
	)
	var owners: Array[int] = []
	for cell: Vector2i in found:
		owners.append(SonarMark.team_of_bits(_network.tunnel_known_bits(target_plane, cell)))
	scanned.emit(source_plane, target_plane, found, owners)

	if found.is_empty():
		refused.emit("nothing answers below")
		return 0

	_show_echo(source_plane, found, owners)
	_place_mark(source_plane, found[0], owners[0])
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
		# Rubbing out a mark is a change to the world, so it resolves where the world does. A client
		# can read a replicated enemy mark while this mouse is a Sneak, but only the authoritative
		# copy removes it; the next complete picture then removes the replica for everybody else.
		if acts():
			_clear(enemy, _player.team)
		return

	scan()


func _place_mark(source_plane: int, cell: Vector2i, whose: int) -> SonarMark:
	for existing: SonarMark in _all_marks():
		if (
			existing.owner_team == _player.team
			and existing.plane == source_plane and existing.cell == cell
		):
			return existing

	var mark := SonarMark.new()
	_network.add_child(mark)
	mark.configure(_network, _player.team, source_plane, cell, whose)
	marked.emit(mark)
	return mark


func _nearest_enemy_mark() -> SonarMark:
	var nearest: SonarMark
	var nearest_distance := INF
	var here := _network.world_to_cell(_player.global_position)
	for mark: SonarMark in _all_marks():
		if mark.owner_team == _player.team or mark.plane != _player.get_plane():
			continue
		var distance := Vector2(mark.cell - here).length()
		if distance <= erase_reach_cells and distance < nearest_distance:
			nearest = mark
			nearest_distance = distance
	return nearest


func _clear(mark: SonarMark, by_team: int) -> bool:
	if not is_instance_valid(mark) or mark.owner_team == by_team:
		return false
	# Out of the group before it is out of the tree, so a scan later in the same frame cannot find
	# a mark that is on its way to being freed.
	mark.discard()
	cleared.emit(mark, by_team)
	return true


## A remote player's private scan result, delivered by `NetMatch`. It goes through the same local
## presentation path as a listen-server player's scan and cannot mutate tunnel knowledge.
func reproduce_echo(source_plane: int, cells: Array[Vector2i], owners: Array[int]) -> void:
	if _player == null or _network == null or not watched():
		return
	_show_echo(source_plane, cells, owners)


## The temporary shimmer of the detected floor plan. LOCAL VIEWER ONLY (M7): it is a picture of
## what one Sneak just heard, and a host running this ability for four people would otherwise draw
## all four echoes in its own yard.
##
## `[REVISED]` COLOURED BY WHOSE CORRIDOR EACH CELL IS. It was one flat white outline per cell,
## which described geometry and nothing else -- and geometry is the half a Sneak least needs help
## with, because the shape is right there under the glow. The crew is the half that decides what
## anyone does next: a blue Sneak reading a blue floor plan has found the way home, and reading a
## red one has found the thing its Brute should be standing on.
##
## THE COLOUR COMES FROM THE SERVER, not from this end's own network, and that distinction is
## load-bearing on a client. A client's tunnel network holds what its own crew knows -- so a cell
## found by sonar is very often a cell it has never heard of, whose `tunnel_known_bits` here are
## zero. Reading them locally would paint every enemy corridor as SHARED, which is the one wrong
## answer that looks plausible. The owners ride in with the cells.
func _show_echo(source_plane: int, cells: Array[Vector2i], owners: Array[int]) -> void:
	if not watched():
		return
	if is_instance_valid(_echo):
		_echo.queue_free()
	_echo = MeshInstance3D.new()
	_echo.name = "SonarEcho"
	_echo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_network.add_child(_echo)

	_echo_material = StandardMaterial3D.new()
	_echo_material.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	_echo_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_echo_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_echo_material.vertex_color_use_as_albedo = true
	_echo_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	# TRIANGLES RATHER THAN LINES, and the crew colour is why. `PRIMITIVE_LINES` draws a hairline
	# a pixel wide whatever the zoom, and a pixel of 70%-alpha colour over pale ground is measurably
	# the ground: sampling the first build of this gave 0.88,0.77,0.74 for what should have been a
	# strong red -- a hue technically present and practically invisible. A wash with a thick border
	# gives the colour somewhere to be, which is the entire point of colouring it.
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_material(_echo_material)
	var half := TunnelNetwork.CELL * 0.43
	var y := _network.plane_y(source_plane) + 0.045
	for index in range(cells.size()):
		var cell: Vector2i = cells[index]
		# SHARED when the wire said nothing about this cell, which is what an older packet or a
		# truncated one looks like. Claiming least is the right failure: it names no crew.
		var whose: int = owners[index] if index < owners.size() else SonarMark.SHARED
		var colour := _echo_color(whose)
		var centre := _network.cell_to_world(source_plane, cell)
		var at := Vector2(centre.x, centre.z)
		# The wash first, then the border over it. Low alpha on the fill so overlapping cells in a
		# corridor do not stack into a solid slab -- what should read is a row of tiles.
		_echo_quad(tool, at, half, y, Color(colour.r, colour.g, colour.b, 0.30))
		_echo_border(tool, at, half, y, colour)
	_echo.mesh = tool.commit()
	_echo_left = echo_seconds


## One flat square, centred on `at`.
func _echo_quad(tool: SurfaceTool, at: Vector2, half: float, y: float, colour: Color) -> void:
	var points: Array[Vector3] = [
		Vector3(at.x - half, y, at.y - half),
		Vector3(at.x + half, y, at.y - half),
		Vector3(at.x + half, y, at.y + half),
		Vector3(at.x - half, y, at.y + half),
	]
	for corner: int in [0, 1, 2, 0, 2, 3]:
		tool.set_normal(Vector3.UP)
		tool.set_color(colour)
		tool.add_vertex(points[corner])


## A square outline with real width, built as four overlapping bars. Thickness in world units
## rather than in pixels, so it stays the same fraction of a cell at every zoom.
func _echo_border(tool: SurfaceTool, at: Vector2, half: float, y: float, colour: Color) -> void:
	var width := TunnelNetwork.CELL * 0.055
	var inner := half - width
	# Top, bottom, left, right. The two verticals are shortened by the horizontals' width so the
	# corners do not double up their alpha and read as four bright dots.
	_echo_bar(tool, at + Vector2(0.0, -half + width * 0.5), Vector2(half, width * 0.5), y, colour)
	_echo_bar(tool, at + Vector2(0.0, half - width * 0.5), Vector2(half, width * 0.5), y, colour)
	_echo_bar(tool, at + Vector2(-half + width * 0.5, 0.0), Vector2(width * 0.5, inner), y, colour)
	_echo_bar(tool, at + Vector2(half - width * 0.5, 0.0), Vector2(width * 0.5, inner), y, colour)


func _echo_bar(
	tool: SurfaceTool, at: Vector2, extents: Vector2, y: float, colour: Color
) -> void:
	var points: Array[Vector3] = [
		Vector3(at.x - extents.x, y, at.y - extents.y),
		Vector3(at.x + extents.x, y, at.y - extents.y),
		Vector3(at.x + extents.x, y, at.y + extents.y),
		Vector3(at.x - extents.x, y, at.y + extents.y),
	]
	for corner: int in [0, 1, 2, 0, 2, 3]:
		tool.set_normal(Vector3.UP)
		tool.set_color(colour)
		tool.add_vertex(points[corner])


## The outline colour for one crew's corridor.
##
## BRIGHTER AND LESS CHALKY THAN THE CANT MARK'S. A mark is scratched into a floor and lives there
## for the rest of the match, so it wants to sit into the ground; the echo is a sound heard through
## a layer of earth for under two seconds, and it wants to be unmistakable in that time. Same two
## hues, different jobs, different treatment -- which is why they are two functions rather than one
## shared helper with a flag.
func _echo_color(whose: int) -> Color:
	if whose == SonarMark.SHARED:
		# Junction cells take the wave's own colour. Neither crew, and visibly so -- and it doubles
		# as the reading for "the packet did not say", which should never look like an accusation.
		return Color(wave_color.r, wave_color.g, wave_color.b, 1.0)
	# Barely lightened. The crew hue is the message here, and every step toward white is a step
	# toward the pale ground it is being read against.
	return Team.color_of(whose).lerp(Color.WHITE, 0.10)


# ------------------------------------------------------------------------------- the pips


## A ring over every body the pulse is currently finding, for as long as it keeps finding it.
##
## THE SAME SPLIT THE REST OF THE ABILITY MAKES, and it is the reason the listen is worth building
## as part of Q rather than as a new thing. The MARK is a record and is shared with the crew; the
## ECHO is a reading and is one Sneak's alone. A contact in the book (`spotting.gd`) is the shared
## half of the listen -- it goes on everybody's minimap, because that is what the book is for -- and
## this is the private half: the thing only the mouse that pressed the key can see, in the world,
## where it is standing.
##
## WHICH MEANS THE SNEAK GETS SOMETHING ITS CREW DOES NOT, exactly as it does with the floor plan.
## A crew mate reading the minimap knows a mouse is over there. The Sneak can see, without looking
## away from the fight, that the thing it is about to walk into is a body.
##
## REBUILT AGAINST THE CURRENT ANSWER EVERY FRAME rather than placed once and left. A pip is a live
## reading of where somebody is now, so it follows them -- and a mouse that walks out of range loses
## its pip, which is the honest picture: the pulse has stopped coming back off them.
func _step_pips() -> void:
	if not watched() or _listen_left <= 0.0 or _player == null:
		_drop_pips()
		return

	var reach := listen_range()
	var heard: Dictionary = {}
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var other := node as Mouse
		# ENEMIES ONLY. Your own crew is already drawn on the minimap unconditionally and is
		# standing in front of you in team colour; a pip over a team mate would be the ability
		# reporting something the player cannot fail to know.
		if other == null or other == _player or other.team == _player.team:
			continue
		if other.is_scruffed():
			continue
		var gap := _player.global_position - other.global_position
		gap.y = 0.0
		if gap.length() > reach:
			continue
		heard[other] = true

	for gone: Variant in _pips.keys():
		if not heard.has(gone):
			var stale: Node3D = _pips[gone]
			if is_instance_valid(stale):
				stale.queue_free()
			_pips.erase(gone)

	for found: Variant in heard:
		var target := found as Mouse
		if not _pips.has(target):
			_pips[target] = _make_pip(target)
		var pip: Node3D = _pips[target]
		if not is_instance_valid(pip):
			_pips.erase(target)
			continue
		# Over the head rather than under the feet, because a mouse in a tunnel below has a floor
		# between it and the pip and a ring drawn on ITS floor would be invisible from up here.
		# `no_depth_test` on the material is what carries it through the earth; the lift is what
		# stops it sitting inside the body it is describing.
		pip.global_position = target.global_position + Vector3.UP * (target.model_radius * 3.0)
		# Fading out over the last second, so the listen ends rather than stops.
		var going := clampf(_listen_left / 1.0, 0.0, 1.0)
		# A slow throb, so a pip is legible against a moving background without being a flashing
		# light. Half a second a cycle -- a heartbeat rather than an alarm.
		var beat := 0.82 + 0.18 * sin(Time.get_ticks_msec() * 0.009)
		var wide := target.model_radius * 2.2 * beat
		pip.scale = Vector3(wide, 1.0, wide)
		var material := (pip as MeshInstance3D).material_override as StandardMaterial3D
		if material != null:
			material.albedo_color.a = pip_color.a * going


func _drop_pips() -> void:
	for pip: Variant in _pips.values():
		if is_instance_valid(pip):
			(pip as Node3D).queue_free()
	_pips.clear()


## One ring, parented to the NETWORK rather than to the mouse it describes.
##
## NOT A CHILD OF THE TARGET, which is the obvious construction and would have been a leak. A pip
## parented to an enemy is a node inside that enemy's subtree -- it would ride their scruff
## animation onto its side, and more to the point it would still be there, owned by them, if this
## Sneak's listen ended between two frames of something else freeing it. Parented to the world and
## moved by hand, the ability owns its own picture and can always take it away.
func _make_pip(target: Mouse) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = pip_color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# THROUGH THE EARTH, and this is the one place in the project that turns depth testing off for
	# a thing about a mouse. `SecondWind`'s rings deliberately keep it, on the argument that a ring
	# drawn through a floor is a free tell that somebody is on the layer below. That argument is
	# exactly right for a ring anybody can see -- and this is a readout private to one Sneak who has
	# just spent a cooldown asking what is down there. Being able to see the answer through a floor
	# is what was bought.
	material.no_depth_test = true

	var pip := MeshInstance3D.new()
	pip.name = "SonarPip"
	pip.mesh = _pip_mesh()
	pip.material_override = material
	pip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var parent: Node = _network if _network != null else get_tree().current_scene
	parent.add_child(pip)
	pip.global_position = target.global_position
	return pip


## A flat ring, one metre across at scale 1. Triangles rather than `PRIMITIVE_LINES` for the reason
## the echo has the receipts for: a hairline one pixel wide over a mouse the same size as it is
## invisible in a screenshot and worse in motion.
func _pip_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments := 20
	var inner := 0.62
	for index in range(segments):
		var a := TAU * float(index) / float(segments)
		var b := TAU * float(index + 1) / float(segments)
		var outer_a := Vector3(cos(a), 0.0, sin(a))
		var outer_b := Vector3(cos(b), 0.0, sin(b))
		for corner: Vector3 in [
			outer_a * inner, outer_a, outer_b, outer_a * inner, outer_b, outer_b * inner
		]:
			tool.set_normal(Vector3.UP)
			tool.add_vertex(corner)
	return tool.commit()


## The pulse leaving: a ring on the Sneak's own floor, running out to the scan radius.
##
## LOCAL VIEWER ONLY, like the echo, and for the same reason -- a host runs this ability for every
## human in the match and would otherwise draw four pulses in its own yard.
##
## IT PLAYS ON EVERY SCAN, INCLUDING THE ONES THAT FIND NOTHING, and that is the point of building
## it. The Sneak's Q had exactly the failure the stomp has: press it over bare earth and the whole
## ability was one line of text. Now the pulse goes out either way and only the echo differs, so
## the shape of the feedback matches the shape of the mechanic -- you always sound, you do not
## always hear something.
##
## AND IT IS THE SAME COLOUR EVERY TIME, which is a rule rather than a default. The moment the wave
## took the hue of what it found, it would be answering before the echo did -- and worse, it would
## be answering during the half second when the answer is still travelling. A Sneak should learn
## what is down there from the thing that comes back.
func _show_wave(source_plane: int) -> void:
	if not watched() or _network == null or _player == null:
		return
	if is_instance_valid(_wave):
		_wave.queue_free()

	var segments := 48
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_LINES)
	for index in range(segments):
		var a := TAU * float(index) / float(segments)
		var b := TAU * float(index + 1) / float(segments)
		tool.set_color(Color.WHITE)
		tool.add_vertex(Vector3(cos(a), 0.0, sin(a)))
		tool.set_color(Color.WHITE)
		tool.add_vertex(Vector3(cos(b), 0.0, sin(b)))

	_wave_material = StandardMaterial3D.new()
	_wave_material.albedo_color = wave_color
	_wave_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_wave_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_wave_material.vertex_color_use_as_albedo = true
	_wave_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_wave = MeshInstance3D.new()
	_wave.name = "SonarWave"
	_wave.mesh = tool.commit()
	_wave.material_override = _wave_material
	_wave.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_network.add_child(_wave)
	# Parked at the Sneak's cell rather than following the mouse. The pulse left from where you
	# stood; walking away from your own sound would read as carrying it.
	var here := _network.world_to_cell(_player.global_position)
	_wave.global_position = _network.cell_to_world(source_plane, here) + Vector3.UP * 0.05
	_wave.scale = Vector3(0.05, 1.0, 0.05)
	_wave_left = wave_seconds


func _step_wave(delta: float) -> void:
	if not is_instance_valid(_wave):
		return
	_wave_left = maxf(0.0, _wave_left - delta)
	var through := 1.0 - clampf(_wave_left / maxf(wave_seconds, 0.01), 0.0, 1.0)
	# Eased out: a pulse leaves fast and slows as it spreads. Linear reads as a growing circle,
	# which is a shape rather than a sound.
	var radius := maxf(radius_cells * TunnelNetwork.CELL, 0.01) * (1.0 - pow(1.0 - through, 2.2))
	_wave.scale = Vector3(radius, 1.0, radius)
	# Held bright for the first third and then let go, so the ring is legible while it is small
	# and does not linger as a faint circle after the echo has already answered.
	_wave_material.albedo_color.a = wave_color.a * (1.0 - smoothstep(0.35, 1.0, through))
	if _wave_left <= 0.0:
		_wave.queue_free()
		_wave = null
