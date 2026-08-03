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


func broadcast(bytes: PackedByteArray, reliable: bool) -> void:
	send(ALL_PEERS, bytes, reliable)
