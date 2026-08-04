class_name MatchState
extends RefCounted
## Everything on the HUD that is not a mouse: the score, the stores, the clock, who is down and
## for how long, and where both banners are.
##
## THE WHOLE THING, FOUR TIMES A SECOND, rather than a change at a time — see `net_message.gd` for
## why that is the better trade here and not merely the lazier one. The short version is that a
## full state cannot get stuck wrong and a delta can.
##
## WHY THE HUD NEEDS NO CHANGES AT ALL, which is the part worth noticing: `score_bug`, `match_hud`
## and `roster` all ask `MatchDirector` for these numbers, so a client whose director holds the
## right numbers has a correct HUD without a single UI file learning that a network exists. That is
## the survey's "MatchDirector is already the sim" paying out a second time — it was already the
## one place these values lived, so it is the one place the wire has to write.
##
## **This packet goes to everyone unfiltered, so nothing crew-private may ever be added to it.**
## The same sentence `snapshot.gd` carries, and for the same reason: scores and stores are public
## in this game, and the moment something here is not, it belongs in step 5's filtered payload
## instead. A dropped banner's position is public *by design* — GDD section 2 says a carrier is
## visible to everyone, and a banner lying in the open is the decision both crews are making.

## Deciseconds, so the clock and the respawn timers survive as integers. A match is eight minutes
## and the HUD rounds to whole seconds, so a tenth is already finer than anything anybody reads.
const TENTHS: float = 10.0
## Ten seats, one byte of respawn each. Fixed rather than sized by the roster, because a packet
## whose length depends on a number the other end might disagree about is a packet that can be
## misparsed into something plausible.
const SEATS: int = 10
## No carrier. 255 rather than 0, because 0 is blue seat 0 and a "nobody" that collides with a real
## seat is the kind of encoding bug that shows up as one specific player carrying a phantom banner.
const NOBODY: int = 255

const BANNERS: int = 2
## kind, 2 score, 2 cheese, clock, playing+winner, then the seats and the banners.
const HEAD_SIZE: int = 1 + 2 + 2 + 2 + 1
const BANNER_SIZE: int = 1 + 1 + 4 * 3
const TOTAL_SIZE: int = HEAD_SIZE + SEATS + BANNERS * BANNER_SIZE

## Where a banner is and whose head it is on. `carrier` is a snapshot seat key, so the two payloads
## agree about who anybody is without either having to name a node.
class Flag:
	var state: int = 0
	var carrier: int = NOBODY
	var position: Vector3 = Vector3.ZERO

var score: Array[int] = [0, 0]
var cheese: Array[int] = [0, 0]
var clock: float = 0.0
var playing: bool = true
## `Team.BLUE`, `Team.RED`, or `MatchDirector.DRAW`.
var winner: int = -1
## Seconds until each seat is back up, indexed the way `Snapshot` keys them. Zero means standing.
var respawns: PackedByteArray = []
var flags: Array[Flag] = []


func _init() -> void:
	respawns.resize(SEATS)
	for i: int in range(BANNERS):
		flags.append(Flag.new())


## The winner packed into the same byte as the playing flag. Three states in two bits, and a match
## that has not ended has no winner to disagree about.
func _verdict() -> int:
	if playing:
		return 0
	return 1 if winner == Team.BLUE else (2 if winner == Team.RED else 3)


func _read_verdict(byte: int) -> void:
	playing = byte == 0
	winner = [-1, Team.BLUE, Team.RED, -1][byte % 4]


func to_bytes() -> PackedByteArray:
	var out := NetMessage.head(NetMessage.Kind.MATCH)
	out.put_u8(score[Team.BLUE])
	out.put_u8(score[Team.RED])
	out.put_u8(cheese[Team.BLUE])
	out.put_u8(cheese[Team.RED])
	out.put_u16(int(maxf(0.0, clock) * TENTHS))
	out.put_u8(_verdict())
	out.put_data(respawns)
	for flag: Flag in flags:
		out.put_u8(flag.state)
		out.put_u8(flag.carrier)
		out.put_float(flag.position.x)
		out.put_float(flag.position.y)
		out.put_float(flag.position.z)
	return out.data_array


## Null on anything that is not exactly a well-formed state.
##
## Fixed length, so this is a single comparison rather than a running check — and a state that
## half-parses is worse than one that is dropped, because the half that survives is a scoreboard
## somebody will believe.
static func from_bytes(bytes: PackedByteArray) -> MatchState:
	if bytes.size() != TOTAL_SIZE:
		return null
	var into := NetMessage.body(bytes, TOTAL_SIZE)
	if into == null:
		return null

	var state := MatchState.new()
	state.score[Team.BLUE] = into.get_u8()
	state.score[Team.RED] = into.get_u8()
	state.cheese[Team.BLUE] = into.get_u8()
	state.cheese[Team.RED] = into.get_u8()
	state.clock = into.get_u16() / TENTHS
	state._read_verdict(into.get_u8())
	state.respawns = into.get_data(SEATS)[1]
	for flag: Flag in state.flags:
		flag.state = into.get_u8()
		flag.carrier = into.get_u8()
		flag.position = Vector3(into.get_float(), into.get_float(), into.get_float())
	return state
