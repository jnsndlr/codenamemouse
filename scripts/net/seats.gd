class_name Seats
extends RefCounted
## Who is in which chair. Ten of them — five a crew — each holding either a peer id or a bot.
##
## M7's step 3, and the plan states it in one line: *a seat is a team, an index, and an occupant
## that is either a peer id or a bot; joining takes a seat, leaving hands it back to a bot
## mid-match.* This is that sentence, and nothing else. It does not spawn anything, does not know
## what a `Mouse` is, and cannot reach the scene tree.
##
## WHY THAT RESTRAINT IS THE POINT. Through M6 a crew's composition was an emergent property of
## `for seat in range(first, crew_size)` with `first` being 1 when a player happened to exist —
## which is a perfectly good line of code and is unanswerable when the question becomes "seat 3
## just disconnected mid-match, whose bot is that now". Occupancy has to be a thing you can ask
## about, assert on, and hand to a serializer. So it is a table, and the table is the truth.
##
## THE OCCUPANT IS A PEER ID, and `BOT` is zero because `NetTransport` already promises ids start
## at 1 for the server. That means "is this seat human" is `> 0` rather than a parallel boolean
## nobody remembers to keep in step, and it means an offline match — where the host is peer 1 and
## everything else is a bot — needs no special case at all. **Offline is the same table with one
## human in it.**
##
## `crew_size` STOPS BEING A BOT COUNT and becomes a seat count. The plan calls this out: bots
## fill empty slots, so the number of bots is seats minus humans and is derived rather than set.

## Nobody human. Zero, so `occupant > 0` is the whole test for "is this a player".
const BOT: int = 0

## Blue seat 0. The host's chair, because `_spawn_bots` has always given the local player blue 0
## and because the seat table's own comment says seat 0 is the on-ramp Generalist.
const HOST_TEAM: int = Team.BLUE
const HOST_SEAT: int = 0

var _crew_size: int
## team -> Array[int] of occupants, indexed by seat.
var _rows: Dictionary = {}


func _init(crew_size: int = 5) -> void:
	_crew_size = maxi(1, crew_size)
	for side: int in [Team.BLUE, Team.RED]:
		var row: Array[int] = []
		row.resize(_crew_size)
		row.fill(BOT)
		_rows[side] = row


func crew_size() -> int:
	return _crew_size


func occupant(side: int, seat: int) -> int:
	if not _rows.has(side) or seat < 0 or seat >= _crew_size:
		return BOT
	return _rows[side][seat]


func is_human(side: int, seat: int) -> bool:
	return occupant(side, seat) > BOT


# ------------------------------------------------------------------------------- sitting down


## Put `peer` in the emptiest crew's lowest free seat. Returns `[team, seat]`, or an empty array
## when the match is full.
##
## THE HOST DOES NOT GO THROUGH HERE — it calls `seat_host()`, because blue 0 is not a preference
## it should have to win a tie-break for.
##
## BALANCED BY HUMAN COUNT, NOT BY FREE SEATS. Every seat is always occupied by somebody (that is
## the point of bots filling them), so "which crew has more room" is meaningless; the question that
## matters is which crew has fewer *people*, since a bot is not the opponent anyone came for.
## Blue wins an exact tie, which is arbitrary and needs to be, or two peers arriving in the same
## millisecond both get sent to whichever side the comparison happens to favour.
func claim(peer: int) -> Array:
	if peer <= BOT:
		return []
	var seated := seat_of(peer)
	if not seated.is_empty():
		return seated

	var side := Team.BLUE if humans(Team.BLUE) <= humans(Team.RED) else Team.RED
	var seat := _first_free(side)
	if seat < 0:
		# The emptier crew is full, so the other one is too -- but ask rather than assume it,
		# because that is only true while both crews are the same size.
		side = Team.other(side)
		seat = _first_free(side)
		if seat < 0:
			return []
	_rows[side][seat] = peer
	return [side, seat]


## Sit the host down in blue 0. Separate from `claim` so the chair cannot be taken by a client
## that connected before the host finished starting up.
func seat_host(peer: int) -> Array:
	_rows[HOST_TEAM][HOST_SEAT] = peer
	return [HOST_TEAM, HOST_SEAT]


## Hand a seat back to a bot. Returns the seat that was freed, or an empty array.
##
## MID-MATCH, AND THAT IS THE HARD REQUIREMENT. A crew that loses a human must not lose a mouse —
## it plays four against five for the rest of the match, and the person who quit has effectively
## picked their opponent's team. The seat stays; only its occupant changes.
func release(peer: int) -> Array:
	if peer <= BOT:
		return []
	var seated := seat_of(peer)
	if seated.is_empty():
		return []
	_rows[seated[0]][seated[1]] = BOT
	return seated


## Put a specific peer in a specific chair, with no balancing and no questions.
##
## For a CLIENT rebuilding the roster it was sent, which must land exactly as the server has it --
## `claim` would re-derive the seating from its own balancing rules and could disagree, and two
## machines disagreeing about who is in which chair is every desync at once.
func sit(side: int, seat: int, peer: int) -> void:
	if not _rows.has(side) or seat < 0 or seat >= _crew_size:
		return
	_rows[side][seat] = peer


func clear() -> void:
	for side: int in _rows:
		_rows[side].fill(BOT)


# ---------------------------------------------------------------------------------- asking


## `[team, seat]` for a peer, or an empty array. Empty rather than a sentinel pair, so a caller
## that forgets to check gets an index error rather than quietly editing blue seat 0.
func seat_of(peer: int) -> Array:
	if peer <= BOT:
		return []
	for side: int in _rows:
		var at: int = _rows[side].find(peer)
		if at >= 0:
			return [side, at]
	return []


func humans(side: int) -> int:
	var count := 0
	for occupied: int in _rows[side]:
		if occupied > BOT:
			count += 1
	return count


func total_humans() -> int:
	return humans(Team.BLUE) + humans(Team.RED)


## Every peer with a chair. The list a serializer walks.
func peers() -> PackedInt32Array:
	var out := PackedInt32Array()
	for side: int in [Team.BLUE, Team.RED]:
		for occupied: int in _rows[side]:
			if occupied > BOT:
				out.append(occupied)
	return out


func is_full() -> bool:
	return _first_free(Team.BLUE) < 0 and _first_free(Team.RED) < 0


## For the log and the audits: one line saying who is where.
func describe() -> String:
	var parts: Array[String] = []
	for side: int in [Team.BLUE, Team.RED]:
		var cells: Array[String] = []
		for seat: int in range(_crew_size):
			var who: int = _rows[side][seat]
			cells.append("bot" if who == BOT else str(who))
		parts.append("%s[%s]" % [Team.name_of(side), ",".join(cells)])
	return " ".join(parts)


func _first_free(side: int) -> int:
	return _rows[side].find(BOT)
