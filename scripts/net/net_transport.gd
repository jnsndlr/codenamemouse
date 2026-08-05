@abstract
class_name NetTransport
extends Node
## The wire, with no opinion about what runs over it — and no mention of ENet anywhere above it.
##
## THIS IS THE ONE PIECE OF EARLY ARCHITECTURE THE PLAN ASKED FOR, and it is worth being precise
## about what it buys, because a wrapper that buys nothing is just a layer. **Browsers cannot do
## raw UDP.** Whether this game is ever a web build is an M9 question, and the cost of keeping
## that question open is exactly this file: game code says `transport.send(...)`, so the day the
## answer is "yes, over WebSockets" the change is one class, not a search for every place a peer
## was touched. The plan priced it at a day. It is worth a day.
##
##     NetTransport (here)
##       ├── ENetTransport       desktop, UDP -- ships first, and is the only one so far
##       ├── WebSocketTransport  web, TCP, adequate for a prototype
##       └── WebRTCTransport     web, UDP-ish, only if competitive play ever demands it
##
## WHY THE INTERFACE IS SHAPED LIKE `MultiplayerPeer` AND NOT LIKE GODOT'S RPCs. All three
## candidate backends are `MultiplayerPeer` subclasses with identical packet APIs, so an interface
## in that shape makes the swap genuinely one line rather than aspirationally one line.
##
## The alternative — `@rpc` and `MultiplayerSynchronizer` — was rejected for a reason specific to
## this game rather than out of taste. **Every client is owed a different payload.** M5's whole
## pillar is that a crew sees the tunnels it dug and not the ones it didn't, and the plan is
## explicit that the filter lives where the packet is built and nowhere else, so there is exactly
## one place to audit for "did we just send them the enemy's floor plan". A synchronizer replicates
## a property to everyone by construction; making it lie to one peer and not another is fighting
## the tool. Bytes we build ourselves are the tool that fits.
##
## OFFLINE IS A REAL MODE, not an error state. Almost every session of this game is one human and
## nine bots, and that has to keep working without a socket. `MatchDirector` asks `is_server()`,
## which is true offline, so the single-player path and the host path are the same path — the plan
## calls that out as the thing that stops the networked code being the code nobody tests.

## What the server always is. ENet, WebSocket and WebRTC all agree on this, which is why it is
## stated here rather than in an implementation.
const SERVER_ID: int = 1

## A packet aimed at everybody. `MultiplayerPeer`'s own convention.
const ALL_PEERS: int = 0

enum Mode {
	OFFLINE,  ## No socket. One human, nine bots. Still the authority.
	SERVER,   ## Listen server: this machine simulates and everyone else asks it to.
	CLIENT,   ## Sends intent, receives truth.
}

## Somebody arrived. On a client this fires for the server itself (`SERVER_ID`).
signal peer_joined(id: int)
## Somebody left, by any means including the socket dropping.
signal peer_left(id: int)
## Bytes, and who sent them. The only way anything gets in.
signal packet_received(from: int, bytes: PackedByteArray)
## Client only: the connection came up. Seat negotiation starts here.
signal joined_server()
## Client only: it did not come up, or it came up and then went away. One signal for both,
## because a lobby has the same job either way — say so, and go back to the title screen.
signal connection_lost()

var _mode: Mode = Mode.OFFLINE
## First payload byte -> bytes sent since the last `clear_traffic`. Kept as the raw byte because the
## transport genuinely does not know what a kind is, and should not start now: `NetMatch` owns the
## enum and can put names to these on the way to a log line. The wire counts, the protocol labels.
var _out: Dictionary = {}
var _in: Dictionary = {}


# ----------------------------------------------------------------------------- what implementations owe


## Start listening. Returns OK, or an error the caller should show the player rather than swallow —
## `ERR_ALREADY_IN_USE` is somebody's other copy of the game and is worth saying out loud.
@abstract func host(port: int, max_peers: int) -> Error

@abstract func join(address: String, port: int) -> Error

## Hang up. Must be safe to call when nothing is connected, because every failure path calls it.
@abstract func close() -> void

## `to` is a peer id, or `ALL_PEERS`.
##
## `reliable` is a per-packet decision and not a connection setting: a snapshot is stale the moment
## the next one is built and must never hold up the queue, while "you were scruffed" has to arrive.
## Getting this backwards is the classic way to build a laggy game on a fast connection.
@abstract func send(to: int, bytes: PackedByteArray, reliable: bool) -> void

## Everyone currently connected, not counting us.
@abstract func peers() -> PackedInt32Array

## Ours. `SERVER_ID` when hosting; offline this is still `SERVER_ID`, because offline we *are* the
## authority and every rule that asks "is this mine" should answer yes.
@abstract func local_id() -> int


# ------------------------------------------------------------------------------------ what everyone gets


func mode() -> Mode:
	return _mode


## True when this machine owns the simulation — hosting **or** offline.
##
## This is the single most-called question in the milestone and the reason offline is a mode rather
## than a null transport: `MatchDirector` guards every rule with it, and a single-player match must
## take the same branch a host does or the authoritative path is the one nobody plays.
func is_server() -> bool:
	return _mode != Mode.CLIENT


func is_connected_up() -> bool:
	return _mode != Mode.OFFLINE


## Whether there is actually somebody on the other end yet.
##
## DIFFERENT FROM `is_connected_up`, AND THE DIFFERENCE IS A BUG THIS FILE SHIPPED. A client is
## "online" the instant `join()` returns — the socket exists and the mode is CLIENT — but the
## handshake takes a moment, and on a slow start it takes several seconds while the arena loads.
## Anything that sent during that window got a wall of *"The multiplayer instance isn't currently
## connected"*, once per physics tick, which is alarming, useless, and entirely self-inflicted.
##
## Overridden where a backend can tell; the default is honest about not knowing.
func is_established() -> bool:
	return is_connected_up()


func broadcast(bytes: PackedByteArray, reliable: bool) -> void:
	send(ALL_PEERS, bytes, reliable)


# ---------------------------------------------------------------------------------------- what it costs


## Bytes on the wire since the last reset, per payload kind, each way.
##
## **THE PROTOCOL HAS BEEN MAKING BANDWIDTH ARGUMENTS SINCE M7 STEP 1 WITHOUT A SINGLE NUMBER IN IT.**
## `net_match.gd` explains that twenty snapshots a second is "deliberately below the physics rate"
## because sending every tick "would double the bandwidth to buy smoothness the interpolation already
## provides", and that the earth is a diff because resending it four times a second "genuinely could
## not afford to be idempotent". Both are probably right. Neither was ever measured, and by the end of
## step 6 there were **four** separate per-peer periodic full pictures plus snapshots plus the earth
## going out to every client — a set nobody had added up.
##
## Counted here rather than in `NetMatch` because this is where a packet becomes bytes: a count kept
## next to the code that *builds* payloads measures intent, and a count kept at the socket measures
## what actually left.
func traffic_out() -> Dictionary:
	return _out.duplicate()


func traffic_in() -> Dictionary:
	return _in.duplicate()


func clear_traffic() -> void:
	_out.clear()
	_in.clear()


## For implementations to call as bytes actually go out and come in. Not abstract and not automatic:
## `send` is the implementation's own, and a base class cannot count what it does not carry.
func _note_out(bytes: PackedByteArray) -> void:
	if not bytes.is_empty():
		_out[bytes[0]] = int(_out.get(bytes[0], 0)) + bytes.size()


func _note_in(bytes: PackedByteArray) -> void:
	if not bytes.is_empty():
		_in[bytes[0]] = int(_in.get(bytes[0], 0)) + bytes.size()
