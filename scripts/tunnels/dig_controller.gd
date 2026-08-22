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
## Seconds between one stroke and the next, at a dig speed of 1.0. Deliberately brisk for testing;
## the real number is a per-plane balance dial (GDD section 3 gives deeper planes longer dig times).
##
## `[REVISED]` A RECHARGE RATHER THAN A HOLD, which is the whole shape of digging now. This used to
## be how long you had to keep the button down before a stroke landed; it is now how long you wait
## after one has. The metre itself is instant.
##
## WHY THAT IS NOT THE SAME PACING WEARING A DIFFERENT HAT. A stroke costing half a second of
## holding and a stroke costing half a second of waiting open the same amount of ground per minute,
## and feel nothing like each other, because of WHEN the earth moves relative to the button. Held,
## every dig begins with a stretch in which you have pressed the button and nothing has happened
## yet -- and that stretch is the entire first impression of the control, repeated on every stroke.
## Instant, the answer arrives on the press and the cost is paid afterwards, while you are already
## looking at the metre you just took. The player is never once waiting to find out whether the
## button worked.
##
## AND IT IS WHAT MAKES DIGGING WHILE MOVING POSSIBLE. Under the hold, walking away mid-stroke was
## walking away from the dig; the control wanted you standing still, which fought the Engineer's
## own job of cutting a corridor. A recharge does not care where you are when it expires.
@export var dig_seconds: float = 0.5
## How far from the mouse a stroke may START, in metres. Stops you reaching across the map with
## the cursor -- you dig at arm's length, which is also what keeps the Engineer stationary and
## vulnerable while they work.
##
## `[REVISED]` DELIBERATELY JUST UNDER A STROKE LENGTH, down from 2.6. The old number let you
## stand well back and eat forward with the cursor, which made the Engineer a turret: the mouse
## barely moved, and the corridor grew away from it. Under a metre the rule becomes one you can
## state in a sentence -- **a stroke never starts further from you than the stroke is long** --
## and it has to be re-earned every stroke, because opening one puts the new face a metre further
## on. Holding the button now walks you into your own tunnel, which is what the recharge was
## built for (see [method _update_dig]) and what the reach was quietly cancelling out.
##
## Branching sideways is untouched by this, and that is worth knowing before tuning it: the root
## is the nearest point of EXISTING tunnel to the cursor, so a stroke off the corridor wall you
## are standing in starts at your feet whatever this says. The number only rations reaching
## FORWARD, into ground nobody has opened yet.
@export var dig_reach: float = 0.9
## How far from existing tunnel the CURSOR may point and still name a stroke, in metres.
##
## `[SPLIT OUT OF dig_reach]`, and the split is the whole reason shortening the reach was safe.
## One number used to do both jobs: it capped how far the cut may start from the mouse AND how
## far from the tunnel the cursor could be and still find a branch root. Those read as the same
## rule and are not, because they are measured from different things -- one from the mouse, one
## from the cursor -- and taking the shared number under a metre broke aiming outright: pointing
## at the very next cell puts the cursor a metre from the tunnel you are standing in, so the root
## search came back empty and the ground would not open at all. The audit caught it as "one press
## did not open the tile it was aimed at", which is a sentence about digging and was really a
## sentence about pointing.
##
## SO AIMING KEEPS THE OLD 2.6 AND ONLY STANDING GOT STRICTER. You may still point well out into
## the dark and have a stroke run that way; what you may no longer do is start that stroke from a
## piece of tunnel you are not standing next to. Reach is about where your paws are.
@export var aim_range: float = 2.6
## How far the cursor may wander, in metres along the corridor wall and in angle steps, before it
## counts as pointing at a different stroke. See [method _drifted] -- without a band here the aim
## changes several times a second on a still hand and nothing is ever dug.
@export var aim_slack: float = 0.35
@export_range(0, 16) var aim_slack_steps: int = 4

@export_group("Transit")
## How far above the destination floor the mouse is placed when it moves between layers.
@export var arrival_lift: float = 0.05

var _plane: int = 0
## The stroke being aimed at, as a segment id, or -1 for none. An id rather than a cell since the
## unit of digging stopped being square -- and an id rather than an origin-and-angle pair because
## it has to be comparable in one `!=` to notice the aim moving.
var _target: int = -1
## Where the cursor was the last time it named a stroke at all, on the XZ plane.
##
## WHAT TELLS A STILL HAND FROM A HAND THAT HAS MOVED ON, and the only thing that can. `_aimed_id`
## answers -1 for two situations that have nothing in common: the reading flickered (the candidate
## landed exactly on a stroke already dug, the branch root swapped between two segments the same
## distance from the cursor, the player's own footfall walked the root a hair past reach) and the
## player is genuinely pointing at something undiggable, like a seam. The first must not lose the
## dig; the second must lose it, or the rock never gets to refuse out loud. The stroke cannot tell
## them apart because in both cases there is no stroke -- but the cursor can, because in the first
## case it has not gone anywhere.
var _aimed_at: Vector2 = Vector2.ZERO
## Seconds left before this digger may cut again. Zero is ready.
##
## ON THE DIGGER, NOT ON THE STROKE, and that is the difference between a cooldown and the progress
## bar it replaced. Progress belonged to what you were pointing at, so looking away lost it and
## every re-aim was a fresh start; a recharge belongs to the paws doing the work, so it runs down
## while you walk, while you turn round, and while you decide where the next metre goes. Nothing
## you do with the cursor can spend it or refund it.
var _cooldown: float = 0.0
## The earth coming off the face while this mouse digs. UNLIKE THE CURSOR, NOT GATED ON
## `watched()`: the cursor is aiming UI and belongs to the one pair of eyes steering it, but dust
## is a thing happening in the world -- on a host, a remote player's dig should throw earth on
## every screen that can see the corridor, exactly as their strokes open it. Built on demand, on
## the first frame this mouse actually digs.
var _dust: DigDust
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


## How ready this digger is for its next stroke: 0 the instant one lands, 1 when it may cut again.
##
## `[RENAMED]` FROM `get_dig_progress`, because it now means the opposite thing and a reader who
## did not know that would draw the bar backwards. Under the hold it filled as a stroke was being
## opened and emptied when it landed; it now empties when a stroke lands and fills while you wait
## for the next. The bar looks much the same in motion, which is exactly why the name had to stop
## saying "progress" -- the one way to get this wrong is to assume it was left alone.
func get_dig_charge() -> float:
	return 1.0 - clampf(_cooldown / maxf(_dig_cooldown(), 0.0001), 0.0, 1.0)


## Seconds this mouse waits between strokes. See [member dig_seconds].
##
## DERIVED FROM THE CLASS'S DIG SPEED rather than being a fifth number on every class, so there is
## still ONE dial per class for how fast it digs and the two cannot drift apart. An Engineer's 1.0
## is [member dig_seconds] flat; everybody else's 0.35 is nearly three times that (GDD section 4,
## revised) -- the same spread the held version charged, arriving in whole metres instead of in
## fractions of one.
##
## Asked of the mouse rather than looked up here, so the number arrives with whoever is driving and
## a class swap is felt on the very next stroke.
func _dig_cooldown() -> float:
	return maxf(dig_seconds, 0.0) / _dig_rate()


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
		# Taking a shaft skips the dig update below, so the scrabble and the dust are told to
		# stop here -- a mouse arriving on a new plane still wearing last frame's pose would be
		# digging at a wall that is now a layer away.
		_dress(false, -1)
		return

	_update_dig(frame, delta)


## Aim, click, and the metre is gone. Then wait.
##
## `[REVISED]` THE STROKE IS INSTANT AND THE COST IS A COOLDOWN. Two models came before this one and
## both charged for a stroke BEFORE giving it: the original held the button for `dig_seconds` and
## popped a whole metre out at the end, and the carve that replaced it fed the same metre out
## continuously over the same half second. The second is much the better picture of the two and it
## did not fix the thing that was actually wrong, which neither model could: the button and the
## earth were never in the same instant. Every stroke opened with a stretch of pressing and waiting,
## and on a control you use several hundred times a match that stretch IS the control.
##
## So the order is reversed. The press cuts, at once, in full; the wait happens afterwards, while
## you are looking at the metre you just took and choosing the next one. Same ground per minute,
## same spread between the classes, and the player is never once left wondering whether the button
## registered -- which was the complaint under both of the others, arriving in different words.
##
## HOLDING REPEATS, and that is not a separate feature. A recharge that fires on the press and a
## recharge that fires the moment it expires are the same rule read at two speeds: click and you
## dig once, lean on it and you dig as fast as the class can, which is what "walk up to the dirt
## and start moving" needs. The alternative -- clicking once per metre -- is the same corridor with
## a repetitive strain injury attached.
func _update_dig(frame: InputFrame, delta: float) -> void:
	# BEFORE ANYTHING ELSE, AND OUTSIDE EVERY GUARD BELOW. The recharge is a property of the paws
	# (see [member _cooldown]), so it must run down while the cursor is over rock, over nothing, over
	# the HUD, or over a stroke this mouse is not allowed to cut. Ticking it inside the digging
	# branch would make looking away a way to pause your own cooldown.
	_cooldown = maxf(0.0, _cooldown - delta)

	var at := _aim_flat()
	var wanted := _aimed_id()
	if wanted != _target and _drifted(wanted, at):
		_target = wanted
	# Only a frame that named a stroke moves the mark, so the frames that name nothing are measured
	# against the last one that did rather than against each other. See [member _aimed_at].
	if wanted >= 0 or _target < 0:
		_aimed_at = at

	# The cursor-over-HUD guard lives in the capture now: a click on a slider never becomes a DIG
	# in the first place, rather than being filtered out here and again in `player.gd`.
	var held := frame.is_held(InputFrame.Action.DIG)

	# WHY A PRESS THAT DOES NOTHING HAS TO SAY SOMETHING, and why that matters more now than it
	# did. The rock refusal below used to be a second opinion: the hover box had already gone grey
	# over the seam, and this only put words to it. With the box gone (see [DigCursor]) the words
	# are the ONLY feedback a refused press gets, so both refusals -- stone, and simply being too
	# far from the earth -- are said out loud on the press.
	if _target < 0:
		var rock := _blocked_cell()
		if rock != Vector2i.MAX:
			if frame.is_pressed(InputFrame.Action.DIG):
				# Said out loud through the network's own refusal, which is what tells the player
				# the controls are working and the ground is not.
				_network.dig_refused.emit("solid rock -- go round it, or go under it")
				_learn_vein(rock)
			# No dust and no scrabble on rock, deliberately: pressing on a seam achieves nothing,
			# and paws visibly working it would promise otherwise.
			_dress(false, -1)
			return
		if frame.is_pressed(InputFrame.Action.DIG):
			_explain_reach(at)

	if _target >= 0 and held and _cooldown <= 0.0:
		# CHARGED WHETHER OR NOT THIS MACHINE IS THE ONE THAT CUTS, which is what keeps a client
		# honest. A puppet's stroke is the server's to make and arrives on the next earth tick; if
		# the cooldown only started on a successful cut, a client would sit at full charge for the
		# length of the round trip and fire again the instant its finger twitched, asking for two
		# strokes and being told about one. The recharge is the CONTROL's, and a client's controls
		# work exactly like everybody else's -- it is the earth that is not its to move.
		_cooldown = _dig_cooldown()
		if acts():
			var cut := _target
			if _network.dig_segment(
				_plane,
				TunnelNetwork.segment_origin(cut),
				TunnelNetwork.segment_angle(cut),
				_player.team
			):
				_cut += 1
				# Aimed before it kicks, because on the very first press the emitter has never
				# been pointed at anything -- a kick with no face to come off is no kick at all.
				_aim_dust(cut)
				_dust.kick()
			_learn_exposed(cut)
		# Re-aim immediately: the stroke just landed, so it is no longer a valid target and a held
		# button should move on to the next one rather than sit on a stroke that no longer exists.
		_target = _aimed_id()

	_dress(_target >= 0 and held, _target)


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
## counted, because the reveal hung off deliberately pressing dig INTO the rock, which is the one
## thing the game tells you not to bother doing: back when the hover box existed it went grey over
## stone, and now the refusal says so in words. So the one action the feature waited for was the
## action the interface talks you out of, and the vein you had plainly found stayed dark.
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


## Why a press that named no stroke did nothing, when the answer is distance.
##
## `[ADDED WITH THE CURSOR'S REMOVAL]` and only worth having because of it. A refused press used
## to be self-explanatory: the box was either sitting on a stroke or it wasn't, so "out of reach"
## was something you learnt by waving the cursor around with no button pressed. Nothing draws that
## rule any more, and the reach is now short enough that walking a step too far back silently
## stops the ground opening -- which is the exact failure a player reads as the button being
## broken. So distance gets said out loud, on the press, the way stone already was.
##
## SEARCHED WIDER THAN THE REACH, deliberately: a cursor further from the tunnel than a mouse may
## dig finds no root at all, which is the commonest way to be too far and would otherwise be the
## one case that stayed silent. Beyond three times the reach the player is pointing at open lawn
## or across the map, and has not asked a question this can answer.
##
## THROUGH `explain` RATHER THAN THE NETWORK'S SIGNAL DIRECTLY, so a remote player's fumbled press
## does not print on the host's HUD. See [method MouseControl.explain].
func _explain_reach(at: Vector2) -> void:
	if _plane <= 0 or _player == null:
		return
	var root := _network.nearest_segment_point(_plane, at, aim_range)
	if root.is_empty():
		return
	var from: Vector2 = root[0]
	var here := _player.global_position
	if Vector2(here.x, here.z).distance_to(from) > dig_reach:
		explain("too far -- dig at arm's length")


## Everything cosmetic that says "this mouse is digging", switched as one thing: the toon
## scrabble the body wears and the dust coming off the face. One door, so the two cannot
## disagree -- paws working a wall that sheds nothing, or a wall shedding under idle paws, are
## both the same bug and this is where it would live.
##
## `digging` means the button is down on a stroke the network would cut. It stays true through
## the cooldown between strokes on purpose -- the recharge is part of the effort, and dust that
## started and stopped twice a second would flicker in exactly the rhythm the instant-stroke
## model was built to remove.
##
## SINCE THE HOVER BOX WENT, THIS IS THE ONLY THING THAT DRAWS A DIG. Worth saying plainly here,
## because it changes what a bug in this function costs: dust and pose used to be the decoration
## on top of the cursor, and they are now the whole of the picture.
func _dress(digging: bool, id: int) -> void:
	if _player != null:
		_player.set_digging(digging)
	if digging and id >= 0 and _network != null:
		_aim_dust(id)
		_dust.set_active(true)
	elif _dust != null:
		_dust.set_active(false)


## Point the emitter at the stroke being worked: at the WALL, and thrown back along the stroke
## toward the digger, because that is the open side of it.
##
## A THIRD OF THE WAY ALONG, WHICH IS NOT WHERE THE STROKE IS. The obvious spot is the middle of
## the earth being bought -- that is what the cursor's far half draws and what the dig actually
## removes -- and it is wrong, because until the stroke lands that point is INSIDE SOLID GROUND.
## Dust born there is depth-tested against the terrain and simply does not exist on screen; the
## first version emitted at 0.55 and produced a perfectly healthy emitter, correctly aimed,
## holding ten live puffs, that photographed as nothing at all.
##
## The stroke's origin is the centreline of the tunnel you are branching from (see
## [method _aimed_id]), so the wall stands about half a width along it -- which is why the puffs
## belong just short of that, in the open air the digger is standing in.
func _aim_dust(id: int) -> void:
	if _dust == null:
		_dust = DigDust.new()
		_dust.name = "DigDust"
		# Parented to the network, like the cursor: dust stands in tunnel space, and a puff
		# must hang where it was thrown rather than follow a mouse that walks off mid-dig.
		_network.add_child(_dust)
	var a := TunnelNetwork.segment_origin(id)
	var b := TunnelNetwork.segment_end(id)
	var face := a.lerp(b, 0.35)
	_dust.aim(Vector3(face.x, _network.plane_y(_plane) + 0.12, face.y), a - b)


func _exit_tree() -> void:
	# The dust lives under the network, not under this controller, so a mouse leaving the match
	# would otherwise strand its emitter there -- inert, invisible, and one per respawned seat.
	if is_instance_valid(_dust):
		_dust.queue_free()
	_dust = null


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


## Where the cursor is, flattened to the plane everything here is measured on.
func _aim_flat() -> Vector2:
	var aim := _player.get_aim_point()
	return Vector2(aim.x, aim.z)


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

	var at := _aim_flat()
	var root := _network.nearest_segment_point(_plane, at, aim_range)
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
	return id if _offers(id) else -1


## Would the network really cut this stroke if the button went down on it?
##
## SPLIT OUT SO A HELD TARGET CAN BE RE-ASKED. The aim is sticky now (see [method _drifted]), which
## means the stroke being dug is one chosen on some earlier frame -- and the world moves underneath
## it: somebody else's corridor arrives, a cave-in fills it, a seam is revealed. A target held
## without re-asking is a cursor promising a dig that has quietly become impossible.
func _offers(id: int) -> bool:
	if id < 0 or _network.has_segment(_plane, id):
		return false

	# Nothing to gain from a stroke lying wholly inside tunnel that is already open -- pointing
	# back down your own corridor -- and the cursor should not sit there pulsing, promising it.
	#
	# ASKED OF THE EARTH, NOT OF THE END CELL. Judging by whether the stroke FINISHED in a dug cell
	# refused the one dig that matters most: a stroke that joins two corridors always ends inside
	# the one it is reaching for, so two tunnels within a stroke of each other could never be
	# connected at all. See TunnelNetwork.opens_ground.
	if not _network.opens_ground(
		_plane, TunnelNetwork.segment_origin(id), TunnelNetwork.segment_angle(id)
	):
		return false
	# MIRRORS `TunnelNetwork.dig_segment`'S OWN REFUSALS, and must keep doing so. A stroke this
	# offers but the network would refuse is a cursor that pulses invitingly over ground that will
	# never open -- and worse here than merely misleading, because falling through to `-1` is what
	# hands the frame to the rock branch. Without the stone test the seam got no cursor, no refusal
	# and no reveal: the player held the button on rock and the game said nothing at all.
	for cell: Vector2i in _network.segment_cells(id):
		if not _network.in_bounds(cell) or _network.is_rock(_plane, cell):
			return false
	return true


## Has the aim moved far enough to count as pointing somewhere else?
##
## WHY THE CURSOR NEEDED THIS AT ALL. A stroke's identity is its origin snapped to sixteenths of a
## metre and its angle snapped to a sixty-fourth of a turn, and BOTH of those slide continuously as
## the mouse moves: the origin runs along the corridor wall under the cursor, the angle sweeps with
## it. So the packed id changes every few centimetres of cursor travel -- and the old rule, "a
## different id means a different target, start the bar again", meant a hand that was not perfectly
## still never finished a dig at all. The cube jittered between quantised placements and the
## progress bar reset under it, which reads as the dig button not working.
##
## MEASURED IN WORLD UNITS, NOT IN IDS, which is the fix. Two ids a texel apart describe the same
## intention; the player is pointing at the same piece of earth. The aim only counts as having
## moved when the stroke it would cut is somewhere a player could actually mean differently -- a
## third of a metre along the wall, or twenty degrees round.
##
## The band is deliberately wider than the quantisation rather than a hair over it. Sized to the
## quantisation it would still flicker, because the id changes once per sixteenth of a metre and a
## mouse in a hand moves further than that between two frames.
func _drifted(wanted: int, at: Vector2) -> bool:
	if _target < 0:
		return true
	# The world may have taken the target away since it was chosen, and it may have walked out of
	# reach under its own steam.
	if not _offers(_target):
		return true
	var from := TunnelNetwork.segment_origin(_target)
	var here := _player.global_position
	if Vector2(here.x, here.z).distance_to(from) > dig_reach:
		return true
	# `[REVISED]` NOTHING TO POINT AT IS NOT THE SAME AS POINTING SOMEWHERE ELSE, and conflating the
	# two is what made a still hand dig twice for one metre of corridor. `_aimed_id` returns -1 for a
	# whole family of momentary conditions -- the candidate stroke landing exactly on one that is
	# already dug, the branch root flickering between two segments equidistant from the cursor, the
	# root stepping a hair past reach as the player's own footfall moves the camera -- and any single
	# frame of that used to drop the target and everything cut on it.
	#
	# SO THE CURSOR ANSWERS IT INSTEAD (see [member _aimed_at]), against the same band the rest of
	# this measures drift in. A hand that has not moved means the same stroke it meant last frame;
	# a hand that HAS moved and now names nothing has genuinely left, which is what has to keep
	# happening for a seam to get its refusal in.
	if wanted < 0:
		return at.distance_to(_aimed_at) > aim_slack
	if TunnelNetwork.segment_origin(wanted).distance_to(from) > aim_slack:
		return true
	var half := TunnelNetwork.ANGLE_STEPS / 2
	var turned := absi(wrapi(
		TunnelNetwork.segment_angle(wanted) - TunnelNetwork.segment_angle(_target), -half, half
	))
	return turned > aim_slack_steps


## The cell a refused stroke ran into, when what stopped it was stone.
##
## Everything `_aimed_id` asks except "is it soft", so the cursor only calls a seam out where the
## alternative really was a dig. A grey box lighting up over rock across the arena would say the
## seam mattered from there, and it doesn't -- you cannot reach it.
func _blocked_cell() -> Vector2i:
	if _plane <= 0:
		return Vector2i.MAX

	var at := _aim_flat()
	var root := _network.nearest_segment_point(_plane, at, aim_range)
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
	# THE COOLDOWN IS DELIBERATELY LEFT RUNNING. Everything else here is stale belief being
	# corrected; the recharge is not belief, it is a debt already incurred, and clearing it would
	# make a shaft -- or a respawn -- a way to buy back a stroke you have already spent.


## Tell the body which layer it is on.
##
## THROUGH THE MOUSE, not by setting the mask here, because a mouse's collision mask carries a
## second thing this controller knows nothing about: the crew layers that make enemies body-block
## and allies pass through (GDD section 6). Setting the mask straight from the network would wipe
## them, and the bug that produces -- teammates suddenly solid, enemies suddenly not -- looks
## nothing like a digging bug and would be hunted for in the wrong file.
func _apply_plane() -> void:
	_player.set_plane(_plane)
