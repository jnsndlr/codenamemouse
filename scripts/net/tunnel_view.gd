class_name TunnelView
extends RefCounted
## What one crew is allowed to be told about the earth, and what a given peer has been told so far.
##
## **THIS IS THE FILE THE MILESTONE'S RISK REGISTER IS ABOUT.** M5 spent a week establishing that a
## crew maps what it cut and sees what it can see, and the whole of that pillar can be undone by
## one broadcast: a client that receives every cell has the enemy's floor plan in memory whether it
## draws it or not, and **the game plays perfectly while the pillar is gone**. There is no playtest
## that catches that. So the filter lives in exactly one place — here — and
## `tools/replication_audit.gd` asserts across two real processes that a client holds nothing its
## crew has not earned.
##
## THE PREDICATE IS NOT NEW AND THAT IS THE POINT. `TunnelSight.knows(side, plane, cell)` already
## answers "does this crew have this cell on its map at all, by either route" — it was written for
## the minimap at M5, with the ownership rule folded in *so that neither the minimap nor an audit
## could forget it*. Inventing a second, network-flavoured version of that question would be
## inventing a way for the two to disagree, and the day they disagreed the wire would be the one
## that was wrong.
##
## WHAT IT SENDS IS A DIFF, and the state it diffs against is per-peer, because two clients on
## opposite crews are owed different worlds. That is also why none of this can be a broadcast:
## there is no packet that is correct for both of them.
##
## WHAT IS DELIBERATELY NOT FILTERED, so the boundary is written down rather than assumed: mice go
## to everybody (grass camouflage and `spotting.gd` decide what a player can make out, and both run
## on the client because a position is not a secret in a game with a minimap that shows contacts),
## and the scoreboard goes to everybody because scores and stores are public. **Anything added to
## either of those payloads is a decision to make it public.**

## What one entry of the packet is about.
enum Kind {
	CELL,     ## Dug floor, with its knowledge bits.
	SHAFT,    ## A shaft descending from this plane, with its knowledge bits.
	ROCK,     ## A seam this crew has found. The stone itself is generated, not sent.
	FORGET,   ## A cell that has aged out of the fog and must leave the client's world.
	## A shaft that is GONE -- the Brute filled it in. Its own kind rather than a FORGET on the
	## cell, because a shaft is recorded at the UPPER of the two planes it joins: the FORGET
	## entries for the two cells it came down with name planes the shaft is not stored under, and
	## a client acting on those alone would keep drawing the ladder.
	FORGET_SHAFT,
	## Timbers in a cell (GDD section 4). Sent under exactly the same permission as the cell they
	## are in -- `_gather_shoring` reads the shored book through the same `TunnelSight.knows` gate
	## as the floor -- so shoring can never be the thing that reveals a corridor. It is a property
	## of a cell you were already allowed to know about.
	SHORED,
	## Timbers gone: broken by a collapse, or aged out of the fog with the cell. Its own kind
	## rather than a `SHORED` with zero bits, because absence in `wanted` is how everything else
	## here signals removal and shoring should not be the one entry that encodes it in a payload
	## byte instead.
	UNSHORED,
}

## Plane, x, y, kind, bits. Cells are signed and can exceed a byte in a large arena.
const ENTRY_SIZE: int = 1 + 2 + 2 + 1 + 1

## How many entries may go in one packet.
##
## AN OPENING NETWORK IS THE SPIKE, not steady play: a client that joins ten minutes into a match
## is owed every cell its crew has cut, which is hundreds at once, while an ordinary tick carries
## one or two. Capped so that first packet becomes a handful of ordinary ones instead of a single
## fragmented giant — ENet will happily fragment a large reliable packet and then hold the whole
## channel up behind it, which would show as the new arrival's mice freezing on the way in.
const MAX_ENTRIES: int = 96

var _network: TunnelNetwork
var _sight: TunnelSight
## peer -> {"%d:%d:%d" % [kind, plane, cell]: bits}. What each client has already been told, so a
## corridor is sent once rather than four times a second forever.
var _told: Dictionary = {}


func _init(network: TunnelNetwork, sight: TunnelSight) -> void:
	_network = network
	_sight = sight


func forget_peer(peer: int) -> void:
	_told.erase(peer)


## The next batch for one peer: everything its crew may know that it has not been told, and
## everything it was told that its crew may no longer know.
##
## THE SECOND HALF IS THE FOG AND IT IS EASY TO LEAVE OUT. Without it a client keeps every cell it
## ever glimpsed for the rest of the match, which is a slow leak rather than a loud one: the map
## would quietly become more complete than the rules say a crew's map may be, and nothing in the
## game would look wrong while it happened.
func batch(peer: int, side: int) -> Array:
	if _network == null or _sight == null:
		return []
	var told: Dictionary = _told.get(peer, {})
	var out: Array = []
	var wanted: Dictionary = {}

	for plane: int in range(1, TunnelNetwork.PLANE_COUNT):
		_gather_cells(side, plane, wanted)
		_gather_shafts(side, plane, wanted)
		_gather_rock(side, plane, wanted)
		_gather_shoring(side, plane, wanted)

	for key: String in wanted:
		if out.size() >= MAX_ENTRIES:
			break
		if told.get(key) == wanted[key]:
			continue
		var entry: Array = _unkey(key)
		entry.append(int(wanted[key]))
		out.append(entry)
		told[key] = wanted[key]

	# CELLS AND SHAFTS ARE FORGOTTEN; ROCK IS NOT. A seam a crew has run into is something it KNOWS
	# rather than something it can currently see, and knowing does not age -- nor can the stone stop
	# being there.
	#
	# `[REVISED]` SHAFTS USED TO BE IN THE SECOND CAMP and are not any more, because the Brute can
	# now fill one in (see [method TunnelNetwork.collapse_shaft]). A shaft that leaves the host's
	# world simply stops appearing in `wanted`, and without this it would sit in `told` for the rest
	# of the match: the client would draw a ladder into solid earth, and the failure is silent on
	# the machine that is right.
	if out.size() < MAX_ENTRIES:
		for key: String in told.keys():
			if out.size() >= MAX_ENTRIES:
				break
			if wanted.has(key):
				continue
			var entry: Array = _unkey(key)
			if entry[0] == Kind.CELL:
				entry[0] = Kind.FORGET
			elif entry[0] == Kind.SHAFT:
				entry[0] = Kind.FORGET_SHAFT
			elif entry[0] == Kind.SHORED:
				# THE SAME CAMP AS CELLS AND SHAFTS, and for the stronger version of the reason:
				# shoring is not merely forgettable, it is *destructible*. A Brute spending a
				# cave-in on an Engineer's timbers is the whole point of the mechanic, and without
				# this line the client that watched them go in would keep drawing them standing --
				# over a corridor its own crew is about to walk down believing is braced.
				entry[0] = Kind.UNSHORED
			else:
				continue
			entry.append(0)
			out.append(entry)
			told.erase(key)

	_told[peer] = told
	return out


## Every dug cell this crew may know about, own or glimpsed, with the bits to record it under.
##
## THE BITS ARE THE SERVER'S OWN. A cell a crew can merely SEE is not a cell it owns, so it travels
## with the owner's bits and the client records it exactly as the host has it — which is what makes
## the client's minimap draw a glimpse as a glimpse rather than as one of its own corridors.
func _gather_cells(side: int, plane: int, into: Dictionary) -> void:
	for cell: Vector2i in _network.dug_cells(plane):
		if not _sight.knows(side, plane, cell):
			continue
		into[_key(Kind.CELL, plane, cell)] = _network.tunnel_known_bits(plane, cell)


func _gather_shafts(side: int, plane: int, into: Dictionary) -> void:
	for cell: Vector2i in _network.known_shaft_cells(plane, side):
		into[_key(Kind.SHAFT, plane, cell)] = _network.shaft_known_bits(plane, cell)


## Every shored cell this crew may know about. **Gated on `knows` for the CELL**, which is the one
## thing to be sure of here: shoring must never be a second, weaker route to a coordinate. If the
## crew may see the floor it may see the timbers standing on it, and if it may not, this sends
## nothing and the client never hears that anybody was down there.
##
## The bits are a constant 1 rather than knowledge bits. Shoring has no per-crew reading -- timbers
## are timbers, and who put them in is not a fact this payload carries -- but the entry still needs
## a value, because `batch` diffs on it and an entry whose bits never change is one that is sent
## once and then left alone, which is exactly the behaviour wanted.
func _gather_shoring(side: int, plane: int, into: Dictionary) -> void:
	for cell: Vector2i in _network.shored_cells(plane):
		if not _sight.knows(side, plane, cell):
			continue
		into[_key(Kind.SHORED, plane, cell)] = 1


func _gather_rock(side: int, plane: int, into: Dictionary) -> void:
	for cell: Vector2i in _network.known_rock_cells(plane, side):
		into[_key(Kind.ROCK, plane, cell)] = _network.rock_known_bits(plane, cell)


func _key(kind: int, plane: int, cell: Vector2i) -> String:
	return "%d:%d:%d:%d" % [kind, plane, cell.x, cell.y]


func _unkey(key: String) -> Array:
	var parts := key.split(":")
	return [parts[0].to_int(), parts[1].to_int(), Vector2i(parts[2].to_int(), parts[3].to_int())]
