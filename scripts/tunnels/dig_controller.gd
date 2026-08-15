class_name DigController
extends MouseControl
## Digging and vertical transit (GDD section 9). Point at a tile, hold the dig button, and it
## opens. E takes whichever shaft the tile you're standing on has; F sinks one down, R breaks
## one up.
##
## ONE PER MOUSE SINCE M7, not one per arena. See [MouseControl]: this used to hang off the arena
## root pointed at `../Player`, which is why a remote human's dig bits arrived at a server with
## nothing to consume them.
##
## POINT AND HOLD, rather than the drive-forward extrusion this replaced. Extruding meant the
## tunnel went wherever you were walking, which is fast but gives you no way to say "that one"
## -- and it shared its key with the shaft, so the tile you most wanted to dig away from was
## the tile that had already claimed the button. Aiming at a tile is slower per cell and much
## more deliberate, and it costs the player nothing to learn because the cursor is already the
## steering wheel.
##
## THE PLANE IS STATE, not a reading taken off the player's height. It used to be derived every
## frame, which was fine until the player was halfway down a ramp and the answer flipped under
## them mid-dig. Nothing walks between planes now -- you are on the layer this controller last
## put you on.

@export_group("Digging")
## Seconds of held input to open one tile. Deliberately brisk for testing; the real number is
## a per-plane balance dial (GDD section 3 gives deeper planes longer dig times).
@export var dig_seconds: float = 0.5
## How far from the mouse a tile can be and still be diggable, in cells. Stops you reaching
## across the map with the cursor -- you dig at arm's length, which is also what keeps the
## Engineer stationary and vulnerable while they work.
@export var dig_reach: float = 2.6

@export_group("Transit")
## How far above the destination floor the mouse is placed when it moves between layers.
@export var arrival_lift: float = 0.05

var _plane: int = 0
## The stroke being aimed at, as a segment id, or -1 for none. An id rather than a cell since the
## unit of digging stopped being square -- and an id rather than an origin-and-angle pair because
## it has to be comparable in one `!=` to notice the aim moving.
var _target: int = -1
var _progress: float = 0.0
## Built on the first frame anybody is looking at this mouse, and never on the other nine. Ten
## shader-material cursors for one pair of eyes is nine wasted meshes in every match.
var _cursor: DigCursor
## Cells this controller has actually opened, and shafts it has sunk.
##
## COUNTED BECAUSE OF WHERE IT IS COUNTED. On a host these are per SEAT, so they say which human's
## controls did the cutting -- and on a client the same controller reports zero, because a puppet
## never reaches for the earth. The pair is what `replication_audit.gd` reads to tell "a remote
## player dug" from "somebody dug", which is otherwise unanswerable: `dig()` records that a cell
## opened and which crew learnt it, never whose hand was on the button.
##
## TWO NUMBERS RATHER THAN ONE, and that is the audit's doing. The first version added them
## together and the suite passed on a run where the client sank a shaft and never opened a single
## cell -- one keypress, credited as if the hold-to-dig path had worked. A shaft is a press and a
## corridor is half a second of holding; they are different claims and they need different columns.
var _cut: int = 0
var _sunk: int = 0


func _ready() -> void:
	super()
	if _network == null or _player == null:
		return
	_apply_plane()


func get_plane() -> int:
	return _plane


## 0..1 while a tile is being opened, for anything that wants to draw it.
func get_dig_progress() -> float:
	return _progress


## Cells opened by holding the dig button. See `_cut`.
func cells_cut() -> int:
	return _cut


## Shafts sunk or broken open with F and R. See `_cut`.
func shafts_cut() -> int:
	return _sunk


func _physics_process(delta: float) -> void:
	if _network == null or _player == null:
		return

	# A PUPPET'S LAYER COMES OFF THE WIRE AND IS NOT THIS NODE'S TO DECIDE. The plane rides in the
	# pose (M7 step 5) and `apply_pose` writes it directly; re-deriving it here and pushing it back
	# through `set_plane` would be two authorities on one number, and the one that is wrong is the
	# one on the machine that cannot see the shaft the mouse just took.
	if acts():
		_resync_plane()
	else:
		_plane = _player.get_plane()

	var standing := _network.world_to_cell(_player.global_position)
	var side := _player.team

	# THE MOUSE'S INTENT, NOT THE KEYBOARD'S (M7). This used to ask `Input` directly, which is
	# fine while the only intent in the process is the one at this keyboard and impossible the
	# moment a second player's has to arrive from a socket. `_player.input()` is the same frame
	# whoever built it -- a capture here, or a packet on a server.
	var frame: InputFrame = _player.input()

	# NOT GUARDED BY `acts()`, on purpose. Both of these end in the network, and the network is
	# where a client is refused -- one guard on the state rather than five on the callers. Leaving
	# the call means the refusal, and the reason for it, comes from the same place on both ends.
	if frame.is_pressed(InputFrame.Action.SHAFT_DOWN):
		if _network.dig_shaft_down(_plane, standing, side):
			_sunk += 1
	if frame.is_pressed(InputFrame.Action.SHAFT_UP):
		if _network.dig_shaft_up(_plane, standing, side):
			_sunk += 1
	if frame.is_pressed(InputFrame.Action.BURROW):
		# GUARDED, because this one does not end in the network: it MOVES THE MOUSE. A client that
		# teleported itself a plane down would spend the next frames being dragged back by the
		# poses, which reads as the shaft being broken rather than as the client overstepping.
		if acts():
			_take_shaft(standing)
		return

	_update_dig(frame, delta)


## Aim, hold, open. The target is re-chosen every frame from where the cursor is, and moving
## off a tile abandons it -- progress is a property of the tile you are pointing at, not of how
## long the button has been down.
func _update_dig(frame: InputFrame, delta: float) -> void:
	var wanted := _aimed_id()
	if wanted != _target:
		_target = wanted
		_progress = 0.0

	# The cursor-over-HUD guard lives in the capture now: a click on a slider never becomes a DIG
	# in the first place, rather than being filtered out here and again in `player.gd`.
	var held := frame.is_held(InputFrame.Action.DIG)

	# ROCK GETS ITS OWN CURSOR (GDD section 3). A seam is refused by the network, so without this
	# the cursor simply vanishes over it -- which is what "out of reach" and "not adjacent" and
	# "already dug" all look like, and the player is left to guess which of the four they have hit.
	# Pressing on it says so out loud, once per press, through the network's own refusal.
	if _target < 0:
		var rock := _blocked_cell()
		if rock != Vector2i.MAX:
			if frame.is_pressed(InputFrame.Action.DIG):
				# Said out loud through the network's own refusal, which is what tells the player
				# the controls are working and the ground is not.
				_network.dig_refused.emit("solid rock -- go round it, or go under it")
				_learn_vein(rock)
			_show_blocked(rock)
			_progress = 0.0
			return

	var digging := _target >= 0 and held
	if digging:
		_progress += delta * _dig_rate() / maxf(dig_seconds, 0.01)
		if _progress >= 1.0:
			if acts():
				var cut := _target
				if _network.dig_segment(
					_plane,
					TunnelNetwork.segment_origin(cut),
					TunnelNetwork.segment_angle(cut),
					_player.team
				):
					_cut += 1
				_learn_exposed(cut)
				_progress = 0.0
				# Re-aim immediately: the stroke just landed, so it is no longer a valid target and
				# holding the button should move on to the next one rather than stall.
				_target = _aimed_id()
			else:
				# A PUPPET HOLDS THE BAR FULL RATHER THAN RESTARTING IT. The cell is the server's
				# to cut and arrives on the next earth tick, at which point `_aimed_cell` stops
				# offering an already-dug cell and the target clears itself. Zeroing here instead
				# would fill the bar a second time in the half-second of the round trip, which
				# reads as a dig that did not take.
				_progress = 1.0
	elif not held:
		_progress = 0.0

	_show(_target, _progress, _target >= 0 and held)


## Running into a seam teaches your crew where it goes (GDD section 3).
##
## HERE RATHER THAN IN `dig()`, because the network knows what the rock is and this knows who hit
## it. Passing a team down into every dig and shaft call would put a parameter that only rock cares
## about on four functions that mostly don't, and bots -- which never dig -- would have to supply it
## anyway. The dig controller is already the one object that pairs a player with a cell.
##
## Cutting a cell open exposes whatever it now backs onto, and a face you can SEE is a face you
## have found.
##
## THE PRESS ALONE WAS NEARLY NEVER ENOUGH, which only showed up on screen. Digging a corridor
## along a seam draws its face in stone -- you are standing there looking at it -- and none of that
## counted, because the reveal hung off deliberately pressing dig INTO the rock. The cursor tells
## you not to do that: it goes grey and stops pulsing precisely to say holding the button will
## achieve nothing. So the one action the feature waited for was the one action the interface talks
## you out of, and the vein you had plainly found stayed dark.
##
## Both paths reveal now. Running into it head-on still works and is what a player does when they
## want to know how far it goes; exposing the face is what actually happens.
func _learn_exposed(id: int) -> void:
	for cell: Vector2i in _network.segment_cells(id):
		for side: Vector2i in TunnelNetwork.SIDES:
			_learn_vein(cell + side)


## ON THE PRESS, not on the hover. Pointing at rock already greys the cursor, and that is the right
## amount to give away for free: one cubic metre, while you look at it. Learning the shape of the
## whole vein costs a cell -- either the one you swung at it with, or the one you opened beside it.
func _learn_vein(cell: Vector2i) -> void:
	if _player == null:
		return
	_network.reveal_vein(_plane, cell, _player.team)


## The cursor, and the two rules about it.
##
## BUILT ON DEMAND AND ONLY FOR THE MOUSE THIS MACHINE IS LOOKING AT. Every driven mouse in the
## match carries one of these controllers now, so an unconditional cursor would be a box of earth
## lit up on the host's screen for every corridor every other player is standing in.
##
## A PUPPET STILL GETS ONE, though, and that is the other half. On a client the local mouse is a
## puppet -- its rules resolve on the host -- but the reach and adjacency rules are exactly what
## the cursor exists to teach, and they are the same rules on both machines. What a client must
## not do is *cut*, and it cannot: the network refuses it.
func _show(id: int, progress: float, digging: bool) -> void:
	var cursor := _cursor_for()
	if cursor == null:
		return
	cursor.show_stroke(_network, _plane, id, progress, digging)


func _show_blocked(cell: Vector2i) -> void:
	var cursor := _cursor_for()
	if cursor == null:
		return
	cursor.show_blocked(_network, _plane, cell)


func _cursor_for() -> DigCursor:
	if not watched():
		if _cursor != null:
			# Hidden through its own door rather than by setting `visible`, so there is one place
			# that decides what an absent target looks like.
			_cursor.show_stroke(_network, _plane, -1, 0.0, false)
		return null
	if _cursor == null and _network != null:
		# Parented to the network rather than to this node, so it sits in tunnel space -- a control
		# is a plain Node with no transform of its own.
		_cursor = DigCursor.new()
		_network.add_child(_cursor)
	return _cursor


## How fast whoever is driving opens a tile, as a multiplier on `dig_seconds`.
##
## THE ENGINEER IS THE DIGGER, BUT NOT THE ONLY ONE. GDD section 4 made terrain alteration the
## Engineer's exclusive capability; this is a deliberate revision, recorded in that section. An
## Engineer opens a tile in `dig_seconds`; everyone else takes about three times as long, which
## is slow enough that you would not choose to tunnel as a Generalist and fast enough that you
## CAN when it is the only way through. The alternative -- nobody else digs at all -- makes a
## crew that has lost its Engineer unable to use a third of the map, and turns one seat into a
## requirement rather than a choice.
##
## Asked of the mouse rather than looked up here, so the number arrives with whoever is driving
## and a class swap is felt on the very next tile.
func _dig_rate() -> float:
	return maxf(0.01, _player.get_dig_speed()) if _player != null else 1.0


## The stroke the cursor is asking for, as a segment id, or -1.
##
## `[REVISED]` FREE BRANCHING, WHICH IS THE WHOLE POINT OF THE CHANGE. This used to pick one of the
## four cells beside a dug one; it now finds the nearest point on tunnel you already have and runs
## a stroke from there toward the cursor, at whatever angle that is. Two consequences worth being
## explicit about, because both are design and not accident:
##
## THE STROKE STARTS INSIDE THE EXISTING TUNNEL, not against its wall. Starting on the boundary
## would leave the join to floating-point luck -- a stroke that begins a millimetre out is a
## corridor with a seam of earth across it that you can see and cannot walk through. Beginning at
## the centreline means the new capsule always overlaps the old one by half a width, so the union
## is continuous by construction and connectivity is not something that can be got wrong.
##
## YOU CAN BRANCH ANYWHERE ALONG A CORRIDOR, not only at its end. That is a deliberate departure
## from GDD section 3's "pivots off the end of the previous one" -- side passages are cheap now,
## and a network is a tree rather than a snake. What it does NOT allow is a room: every stroke is
## still one length, one width, and rooted in tunnel that already exists.
func _aimed_id() -> int:
	if _plane <= 0:
		return -1

	var aim := _player.get_aim_point()
	var at := Vector2(aim.x, aim.z)
	var root := _network.nearest_segment_point(_plane, at, dig_reach)
	if root.is_empty():
		return -1

	var from: Vector2 = root[0]
	# Reach is measured from the MOUSE to where the cut happens, which is what keeps an Engineer
	# standing still and vulnerable while it works (GDD section 3). Measuring to the cursor instead
	# would let you stand back and reach along a corridor you are not in.
	var here := _player.global_position
	if Vector2(here.x, here.z).distance_to(from) > dig_reach:
		return -1

	var heading := at - from
	if heading.length_squared() < 0.0001:
		return -1
	var id := TunnelNetwork.segment_id(from, TunnelNetwork.direction_angle(heading))
	if _network.has_segment(_plane, id):
		return -1

	# Nothing to gain from a stroke lying wholly inside tunnel that is already open -- pointing
	# back down your own corridor -- and the cursor should not sit there pulsing, promising it.
	#
	# ASKED OF THE EARTH, NOT OF THE END CELL. Judging by whether the stroke FINISHED in a dug cell
	# refused the one dig that matters most: a stroke that joins two corridors always ends inside
	# the one it is reaching for, so two tunnels within a stroke of each other could never be
	# connected at all. See TunnelNetwork.opens_ground.
	if not _network.opens_ground(_plane, from, TunnelNetwork.segment_angle(id)):
		return -1
	# MIRRORS `TunnelNetwork.dig_segment`'S OWN REFUSALS, and must keep doing so. A stroke this
	# offers but the network would refuse is a cursor that pulses invitingly over ground that will
	# never open -- and worse here than merely misleading, because falling through to `-1` is what
	# hands the frame to the rock branch below. Without the stone test the seam got no cursor, no
	# refusal and no reveal: the player held the button on rock and the game said nothing at all.
	for cell: Vector2i in _network.segment_cells(id):
		if not _network.in_bounds(cell) or _network.is_rock(_plane, cell):
			return -1
	return id


## The cell a refused stroke ran into, when what stopped it was stone.
##
## Everything `_aimed_id` asks except "is it soft", so the cursor only calls a seam out where the
## alternative really was a dig. A grey box lighting up over rock across the arena would say the
## seam mattered from there, and it doesn't -- you cannot reach it.
func _blocked_cell() -> Vector2i:
	if _plane <= 0:
		return Vector2i.MAX

	var aim := _player.get_aim_point()
	var at := Vector2(aim.x, aim.z)
	var root := _network.nearest_segment_point(_plane, at, dig_reach)
	if root.is_empty():
		return Vector2i.MAX

	var from: Vector2 = root[0]
	var here := _player.global_position
	if Vector2(here.x, here.z).distance_to(from) > dig_reach:
		return Vector2i.MAX

	var heading := at - from
	if heading.length_squared() < 0.0001:
		return Vector2i.MAX

	# Walked along the stroke it WOULD have cut, and the first stone on it is the one to name.
	# A seam a stroke merely passes near is not what stopped you.
	var id := TunnelNetwork.segment_id(from, TunnelNetwork.direction_angle(heading))
	var a := TunnelNetwork.segment_origin(id)
	var b := TunnelNetwork.segment_end(id)
	for i in range(1, 9):
		var point := a.lerp(b, float(i) / 8.0)
		var cell := _network.world_to_cell(Vector3(point.x, 0.0, point.y))
		if _network.is_rock(_plane, cell):
			return cell
	return Vector2i.MAX


## Step into the shaft under or over you.
##
## No hole is opened and nothing is dropped through: the floor stays solid and the mouse is
## placed on the layer it arrived at. That keeps the ground something you can always run over
## -- you enter a tunnel because you chose to, not because you walked across the wrong tile.
func _take_shaft(_cell: Vector2i) -> void:
	if TunnelTransit.destination(_network, _player, _plane) < 0:
		return

	# THE FLAG CANNOT ENTER A TUNNEL (GDD section 2, decided). The rule itself lives in
	# TunnelTransit, which is the one door between the surface and the network and refuses
	# everybody equally. Said out loud HERE, though, and only here: this is where a player meets
	# it, and a refusal you can hear is a rule you can learn. A bot hitting the same wall says
	# nothing, or the one channel that explains the controls fills up with AI chatter.
	var why := TunnelTransit.refusal(_player)
	if why != "":
		explain(why)
		return

	var arrived := TunnelTransit.take(_network, _player, _plane, arrival_lift)
	if arrived < 0:
		return
	_plane = arrived
	_target = -1
	_progress = 0.0


## Keep the remembered plane honest if the player ends up somewhere it doesn't explain.
##
## Holding the plane as state is what removed the mid-transit ambiguity, but state can go stale
## in ways a derived value never could: fall_guard respawns you on the lawn without telling
## anyone, and the controller would go on believing you were three layers down -- masked to a
## collision layer you had left, digging into a plane you were not on.
func _resync_plane() -> void:
	var expected := _network.plane_y(_plane)
	if absf(_player.global_position.y - expected) <= TunnelNetwork.SPACING * 0.5:
		return
	_plane = _network.plane_at_height(_player.global_position.y)
	_apply_plane()
	_target = -1
	_progress = 0.0


## Tell the body which layer it is on.
##
## THROUGH THE MOUSE, not by setting the mask here, because a mouse's collision mask carries a
## second thing this controller knows nothing about: the crew layers that make enemies body-block
## and allies pass through (GDD section 6). Setting the mask straight from the network would wipe
## them, and the bug that produces -- teammates suddenly solid, enemies suddenly not -- looks
## nothing like a digging bug and would be hunted for in the wrong file.
func _apply_plane() -> void:
	_player.set_plane(_plane)
