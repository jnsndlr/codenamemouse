class_name NetMessage
extends RefCounted
## What can travel, and how each thing is packed. The reliability of every kind is a design
## decision rather than a default.
##
## ONE PACKET STREAM, ONE LEADING BYTE. `NetTransport` delivers bytes and says who sent them and
## nothing else, so the first byte says what this is. That is deliberately cruder than Godot's
## RPC dispatch and it is the point: there is exactly one place that decides what a packet means,
## which is the same argument the plan makes for the per-crew filter living at the serializer.
##
## | Kind | Direction | Reliable? | Why |
## |---|---|---|---|
## | `INPUT` | client → server | yes | a lost press is a swing that never happened |
## | `SNAPSHOT` | server → clients | **no** | stale the moment the next one is built |
## | `SEATING` | server → clients | yes | rare, and a client that misses it never knows who it is |
## | `HELLO` | client → server | yes | "I am in a match now" — see below |
## | `MATCH` | server → clients | **no** | the whole scoreboard, resent four times a second |
## | `EVENT` | server → clients | yes | a line of commentary that never comes round again |
## | `TUNNELS` | server → **one** client | yes | the earth, filtered per crew — see below |
## | `CHEESE` | server → clients | **no** | the complete public set of caches, resent twice a second |
## | `BARRICADES` | server → **one** client | **no** | complete visible set, filtered per crew |
## | `SONAR_MARKS` | server → **one** client | **no** | complete readable cant, filtered by crew/class |
## | `SONAR_ECHO` | server → **one** client | yes | one player's private, short-lived scan result |
## | `START` | server → clients | yes | leave the lobby, the match is beginning |
##
## **`START` is the only message in this table that is not about a match already in progress**, and
## it is the only one `NetSession` handles rather than `NetMatch` — because the whole point of it is
## that the receiver has no arena yet, and therefore no `NetMatch` to receive anything. It carries no
## payload today. When the host gains settings to choose — starting cheese, which map — they belong
## here, in the packet that starts the match, rather than in a second message that could arrive after
## it.
##
## **`SNAPSHOT` is unreliable on purpose and that is the important one.** A snapshot resent after a
## drop arrives describing a world that has already moved on, and it holds the queue up behind it
## while doing so. Losing one costs a thirtieth of a second of smoothness; retransmitting one costs
## a visible hitch. This is the classic mistake and it is easiest to make by not choosing.
##
## **`INPUT` is reliable, which is the arguable one.** Reliable-ordered input can head-of-line
## block: one lost packet delays every input behind it. The alternative — resending the last few
## frames in every packet — is what a shipping game does, and it is not worth building against a
## loopback connection with no loss. The plan's own posture is "prediction only if it hurts"; this
## is the same bet on the same reasoning, and **the trigger to revisit is the first playtest with
## real loss**, not a hunch.
##
## **`HELLO` exists because being connected and being in a match are different things**, and the
## seating was originally sent only when the roster changed — which is a moment that belongs to the
## *server's* clock. A client sitting on the title screen, or one that quit to the menu and came
## back, has no arena and therefore nothing listening; the one message telling it who it is went
## into a process that could not use it, and it never asked again. Found by
## `tools/replication_audit.gd` the moment that gap was made to happen on purpose: snapshots
## arriving at a healthy rate, **zero of them applied**, and a mouse the host was walking around a
## yard its owner could not see. So a client says hello when its match comes up, and keeps saying
## it until it is answered — the state it needs is small, and asking for it is cheaper than any
## scheme for delivering it at exactly the right moment.

## **`MATCH` is the whole scoreboard every time, and the plan said "on change".** That instinct was
## about bandwidth, and the numbers do not support it: the entire state — two scores, two cheese
## pools, the clock, the winner, ten respawn timers and both banners — is smaller than one snapshot,
## and a snapshot goes out thirty times a second. What the periodic version buys is that it cannot
## get stuck wrong. An on-change scheme is wrong for the rest of the match if a change is ever
## missed, if a listener is attached late, or if some new rule mutates a field without announcing
## it; a full state four times a second heals from all three by existing. **Idempotent beats
## incremental until bandwidth says otherwise**, and here bandwidth has nothing to say.
##
## That is also why it is unreliable. Losing one costs a quarter-second of a stale scoreboard and
## the next one fixes it, which is exactly the `SNAPSHOT` argument applied to a different payload.

## **Earth, barricades and sonar are addressed to one client on purpose**, and the reason is the
## whole of M5. Two players are owed different worlds; broadcasting any of them can hand somebody
## tunnel locations they are not permitted to know while the game carries on looking perfect.
## `TUNNELS` is still the only payload that is a diff rather than a full state — the earth only
## ever grows, a client that joins late is owed hundreds of cells at once, and resending all of
## them four times a second would be the one thing in this protocol that genuinely could not afford
## to be idempotent. Barricades and cant are few enough to send as filtered full pictures.
## Barricades use `TunnelSight.knows`; cant uses its own literacy rule — owning crew, or a Sneak on
## that mark's plane — because revealing one otherwise-hidden place is the point of the ability.
## An echo is different again: a reliable momentary response sent only to the player who sounded.

enum Kind {
	INPUT,
	SNAPSHOT,
	SEATING,
	HELLO,
	MATCH,
	EVENT,
	TUNNELS,
	CHEESE,
	BARRICADES,
	SONAR_MARKS,
	SONAR_ECHO,
	START,
}


## Whatever `bytes` says it is, or -1 for an empty packet.
##
## Total is asked of every arriving packet before anything else looks at it, so a malformed or
## truncated message is dropped at the door rather than half-applied. A client is not trusted to
## send a well-formed packet and neither, structurally, is a server.
static func kind_of(bytes: PackedByteArray) -> int:
	return -1 if bytes.is_empty() else bytes[0]


static func head(kind: Kind) -> StreamPeerBuffer:
	var out := StreamPeerBuffer.new()
	out.put_u8(kind)
	return out


## A reader positioned just past the kind byte, or null when the packet is too short to be one.
static func body(bytes: PackedByteArray, least: int = 1) -> StreamPeerBuffer:
	if bytes.size() < least:
		return null
	var into := StreamPeerBuffer.new()
	into.data_array = bytes
	into.get_u8()
	return into
