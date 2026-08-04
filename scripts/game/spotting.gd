class_name Spotting
extends Node
## Who your crew can see, and for how long they remember it.
##
## WHY THIS EXISTS AT ALL. The minimap needed a rule for enemy markers, and the two obvious
## answers are both wrong. Showing every enemy hands you the board and quietly cancels the bet
## M5 is built on -- that not knowing where they are is the tension. Showing none makes the map
## a decoration you glance at once. So: an enemy appears when one of your crew can actually see
## them, and stays on the map for a while after they can't.
##
## THAT DELAY IS THE MECHANIC, not a smoothing hack. A contact you can see is information; a
## contact you saw fifteen seconds ago is a GUESS, and the interesting part of a chase is that
## the guess goes stale while you act on it. So a live contact tracks the mouse, and the moment
## line of sight breaks the marker FREEZES where it was last seen and fades out from there. It
## is never a lie -- it says "they were here", which is exactly what your crew mate knows.
##
## VISIBILITY IS THE SAME NUMBER THE GRASS USES. A mouse crouched still in deep cover is at a
## tenth opacity on screen, and asking grass_camouflage.gd for that same figure means the map
## and your eyes can never disagree about whether someone is hidden. Sneaking past a defender
## keeps you off the map for the same reason and by the same amount that it keeps you off the
## screen -- one number, one mechanic, teachable by playing.
##
## PER CREW, both of them. Red spots blue exactly as blue spots red, because the day bots read
## this (they should -- a defender that reacts to a contact rather than to omniscience is the
## whole point) it has to already be true for their side.
##
## Cheap: three observers against three enemies is nine rays, four times a second.

## So the HUD can find it without being wired to it. Same convention as the director.
const SPOTTING_GROUP: StringName = &"spotting"

@export var camouflage_path: NodePath

@export_group("Sight")
## How far a mouse can pick someone out. Generous compared to what fits on screen -- the camera
## sees about eleven metres of yard, so this is roughly "anywhere you could be looking".
@export var sight_range: float = 14.0
## How visible a mouse has to be to register, on grass_camouflage.gd's 0..1 scale. Below this
## they are a shape in the grass you haven't resolved. Not zero: perfect concealment would make
## the fringe of a patch a hard line to sit exactly on.
@export_range(0.0, 1.0, 0.01) var reveal_opacity: float = 0.35
## Seconds between sweeps. Doubles as how long it takes to notice someone, which is why it is
## not once a frame: instant spotting on the exact frame someone clips a corner reads as the
## defence cheating.
@export var interval: float = 0.25

@export_group("Memory")
## How long a contact stays on the map after it was last actually seen.
@export var memory_seconds: float = 15.0
## The last fraction of that, over which the marker fades. A contact that vanishes at full
## strength reads as a bug; one that thins out reads as certainty running out, which is what is
## happening.
@export_range(0.0, 1.0, 0.05) var fade_fraction: float = 0.45

var _camouflage: Node
## Per side: enemy Mouse -> {at: Vector3, plane: int, age: float, live: bool}.
var _contacts: Array[Dictionary] = [{}, {}]
var _since_sweep: float = 999.0


func _ready() -> void:
	add_to_group(SPOTTING_GROUP)
	_camouflage = get_node_or_null(camouflage_path)


# --------------------------------------------------------------------------------- queries


## What `side` currently believes about the other crew. Keys are enemy mice, values carry where
## they were last seen and how stale that is. Read by the minimap; meant for bots at M4.
func contacts_for(side: int) -> Dictionary:
	return _contacts[side]


## Is this mouse currently too well hidden to have been picked out?
##
## PUBLIC, because the bots have to be asking the same question the sweep asks. A bot that walks
## at someone it cannot see is not a hard opponent, it is a bot that reads the scene tree -- and
## it quietly deletes the mechanic for the human, who is doing everything right and being chased
## anyway. Sharing `reveal_opacity` rather than giving the AI its own threshold is what stops the
## grass meaning one thing on the minimap and another to the thing walking toward you.
##
## Only about being SEEN. Range, line of sight and which plane you are on are the sweep's
## business; a caller that wants those wants `_can_see`.
func hidden(mouse: Mouse) -> bool:
	return _opacity_of(mouse) < reveal_opacity


## 1 while a contact is fresh, falling to 0 as it is forgotten. The marker's alpha, and the
## honest answer to "how much should I trust this".
func confidence(entry: Dictionary) -> float:
	var age: float = entry.get("age", 0.0)
	var fade := maxf(memory_seconds * fade_fraction, 0.001)
	return clampf((memory_seconds - age) / fade, 0.0, 1.0)


# ------------------------------------------------------------------------------ the sweep


func _physics_process(delta: float) -> void:
	_forget(delta)
	_since_sweep += delta
	if _since_sweep < interval:
		return
	_since_sweep = 0.0
	for side in [Team.BLUE, Team.RED]:
		_look(side)


## Age every contact, and drop the ones nobody remembers. Runs every frame rather than on the
## sweep so a marker fades smoothly instead of in quarter-second steps.
##
## AGEING IS EVERY FRAME; `live` IS NOT TOUCHED HERE. Clearing the flag here and setting it in
## the sweep made every contact flicker: false for the three frames between sweeps, true for the
## one frame after. `live` means "seen in the most recent sweep", and only the sweep may say so.
func _forget(delta: float) -> void:
	for side in [Team.BLUE, Team.RED]:
		var book: Dictionary = _contacts[side]
		for key: Variant in book.keys():
			# VALIDITY BEFORE THE CAST. `key as Mouse` performs the cast on assignment and throws
			# outright on a freed object, so the guard below it never got the chance to run -- the
			# check was written the right way round and evaluated the wrong way round.
			#
			# Nothing had ever exercised it: through M6 a mouse was scruffed and respawned but
			# never *freed*, so the contact book only ever held live nodes. M7 frees one every time
			# somebody joins and a bot gives up its chair, which is the first mid-match free in the
			# game's history and turned this into an error every frame for every stale contact.
			if key == null or not is_instance_valid(key):
				book.erase(key)
				continue
			var mouse := key as Mouse
			if mouse == null:
				book.erase(key)
				continue
			var entry: Dictionary = book[key]
			entry["age"] = entry["age"] + delta
			if entry["age"] > memory_seconds:
				book.erase(key)


## One crew's turn to look. Everyone on the side contributes to one shared picture, which is
## what makes a crew mate holding a lane worth something to you rather than only to themselves.
func _look(side: int) -> void:
	var book: Dictionary = _contacts[side]
	# Everything goes stale at the top of the sweep; whatever is still visible is refreshed
	# below. Doing it here rather than per-frame is what keeps `live` from flickering.
	for entry: Variant in book.values():
		(entry as Dictionary)["live"] = false

	var watchers: Array[Mouse] = []
	var quarry: Array[Mouse] = []
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null or mouse.is_scruffed():
			continue
		if mouse.team == side:
			watchers.append(mouse)
		else:
			quarry.append(mouse)

	for enemy in quarry:
		# CARRYING YOUR BANNER IS BEING SEEN (GDD section 2). It rides on a pole above their
		# head, above the grass line, glowing -- the one object in the match everyone is looking
		# for at once. Making the crew squint at it through line of sight would contradict the
		# thing the world is already saying out loud.
		if enemy.is_carrying():
			_mark(book, enemy)
			continue
		for watcher in watchers:
			if _can_see(watcher, enemy):
				_mark(book, enemy)
				break


func _mark(book: Dictionary, enemy: Mouse) -> void:
	book[enemy] = {
		"at": enemy.global_position,
		"plane": enemy.get_plane(),
		"age": 0.0,
		"live": true,
	}


## Same layer, close enough, visible enough, and nothing solid in between.
##
## The plane test comes first and is not a shortcut: without it a defender on the lawn spots
## someone crawling directly beneath them through a metre of earth, which is the single thing
## the whole tunnel layer exists to prevent.
func _can_see(watcher: Mouse, enemy: Mouse) -> bool:
	if watcher.get_plane() != enemy.get_plane():
		return false
	var gap := watcher.global_position - enemy.global_position
	if gap.length() > sight_range:
		return false
	if hidden(enemy):
		return false
	return _clear_line(watcher, enemy)


## How visible this mouse is right now, on the grass's own scale. Asked rather than recomputed,
## so concealment can never mean two different things.
func _opacity_of(mouse: Mouse) -> float:
	if _camouflage == null or not _camouflage.has_method("opacity_of"):
		return 1.0
	return _camouflage.call("opacity_of", mouse)


## Props and walls block; mice do not. Crews sit on their own collision layers rather than on
## the world bit, so a body between you and a target never hides them -- which is right: you can
## see over a mouse, and a spot that flickered as your own crew walked past would be maddening.
func _clear_line(watcher: Mouse, enemy: Mouse) -> bool:
	var space := get_tree().root.world_3d.direct_space_state
	if space == null:
		return true
	var eye := Vector3.UP * 0.25
	var query := PhysicsRayQueryParameters3D.create(
		watcher.global_position + eye,
		enemy.global_position + eye,
		TunnelNetwork.WORLD_BIT | TunnelNetwork.plane_bit(watcher.get_plane())
	)
	return space.intersect_ray(query).is_empty()
