class_name ENetTransport
extends NetTransport
## `NetTransport` over ENet: UDP, desktop, and the only implementation M7 ships.
##
## It is deliberately thin. Everything interesting about this milestone happens above it — seats,
## input frames, the per-crew filter — and a transport that also had opinions about those would be
## the place they all got tangled. What this file owns is four things the layer above should never
## have to think about: **polling the socket**, **turning a packet queue into signals**, **noticing
## a connection came up or went away**, and **not letting an id mean two different things**.
##
## POLLED IN `_process`, NOT `_physics_process`, and that is not an oversight. The simulation ticks
## on physics; the socket does not care and should drain as often as the machine will let it, so a
## packet that arrives just after a physics tick is waiting rather than sitting in the kernel for
## another sixteen milliseconds. Nothing here acts on a packet — it emits — so the consumer still
## gets to decide when to apply it.
##
## NOT WIRED TO `MultiplayerAPI` AT ALL. `ENetMultiplayerPeer` is a `PacketPeer`, so this uses it
## as one: no `get_tree().set_multiplayer`, no `@rpc`, no scene-tree replication. That keeps the
## engine from also delivering these packets somewhere we are not looking, and it is what makes
## `net_transport.gd`'s claim — that a browser backend is one class — actually true, since the
## packet API is identical on all three peer types.

var _peer: ENetMultiplayerPeer = null
## Watched for transitions rather than trusted as an event, because `MultiplayerPeer` has no
## "connected" signal of its own -- that one lives on `MultiplayerAPI`, which we are not using.
var _last_status: MultiplayerPeer.ConnectionStatus = MultiplayerPeer.CONNECTION_DISCONNECTED

## Who is on the other end, as a set of ids.
##
## KEPT BY HAND BECAUSE THE PEER DOES NOT KEEP IT. `get_peers()` is a `MultiplayerAPI` method, not
## a `MultiplayerPeer` one -- the roster is something the high-level API assembles from the same
## two signals used below, and skipping that API means assembling it here. Which is fine, and
## better than it looks: it is built from the identical events, it is the same three lines every
## backend would need, and it does not drag in a `MultiplayerAPI` whose scene-tree replication we
## deliberately do not want.
var _roster: Dictionary = {}


func _ready() -> void:
	# Nothing else in this game needs a socket drained while the pause menu is up, but the socket
	# does: a client that stops polling for the length of a pause is a client the server watches
	# time out. Pausing must never drop the connection.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# DERIVED, NOT SET TO FALSE, and the difference is a bug the net audit caught on its first run.
	# `_ready` does not necessarily run inside `add_child` -- when the parent is not yet in the
	# tree it is deferred to the next frame -- so the natural call sequence
	#
	#     var t := ENetTransport.new();  add_child(t);  t.host(port, 8)
	#
	# turns the pump ON in `host` and then a frame later `_ready` turned it back OFF. The socket
	# was open, the client connected, and nothing was ever polled or delivered: a transport that
	# is *silently* deaf, which from above is indistinguishable from a network problem.
	set_process(_peer != null)


# ------------------------------------------------------------------------------------- coming up


func host(port: int, max_peers: int) -> Error:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_peers)
	if err != OK:
		push_warning("enet: could not host on %d (error %d)" % [port, err])
		return err
	_adopt(peer, Mode.SERVER)
	return OK


func join(address: String, port: int) -> Error:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_warning("enet: could not reach %s:%d (error %d)" % [address, port, err])
		return err
	_adopt(peer, Mode.CLIENT)
	return OK


func _adopt(peer: ENetMultiplayerPeer, new_mode: Mode) -> void:
	_peer = peer
	_mode = new_mode
	_last_status = peer.get_connection_status()
	_roster.clear()
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)
	set_process(true)


func close() -> void:
	if _peer == null:
		_mode = Mode.OFFLINE
		set_process(false)
		return
	if _peer.peer_connected.is_connected(_on_peer_connected):
		_peer.peer_connected.disconnect(_on_peer_connected)
		_peer.peer_disconnected.disconnect(_on_peer_disconnected)
	_peer.close()
	_peer = null
	_mode = Mode.OFFLINE
	_last_status = MultiplayerPeer.CONNECTION_DISCONNECTED
	_roster.clear()
	set_process(false)


# --------------------------------------------------------------------------------------- the pump


func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.poll()
	_watch_status()
	# `poll` above can have torn the connection down and `_watch_status` freed the peer with it.
	if _peer == null:
		return
	_drain()


## A client has no "connected" signal to listen to, so the status is compared against last frame.
## Hosting never leaves CONNECTION_CONNECTED, so this costs a comparison and does nothing.
func _watch_status() -> void:
	var status := _peer.get_connection_status()
	if status == _last_status:
		return
	var was := _last_status
	_last_status = status

	if _mode != Mode.CLIENT:
		return
	if status == MultiplayerPeer.CONNECTION_CONNECTED:
		joined_server.emit()
	elif status == MultiplayerPeer.CONNECTION_DISCONNECTED:
		# One signal whether we never got in or got in and were dropped: the caller's job is the
		# same either way, and a lobby that treats them differently is two code paths that both
		# end at the title screen. `was` distinguishes them in the log, which is where the
		# difference actually matters.
		print("enet: connection lost (was %s)" % ("connecting" if was == MultiplayerPeer.CONNECTION_CONNECTING else "connected"))
		close()
		connection_lost.emit()


func _drain() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		# BEFORE `get_packet`, not after. `get_packet_peer` reports the sender of the packet still
		# at the head of the queue; reading the packet first pops it and this returns whoever is
		# next, or 0. It is a one-line ordering mistake that shows up as packets attributed to the
		# wrong player, which looks like a game bug and is not one.
		var from := _peer.get_packet_peer()
		var bytes := _peer.get_packet()
		packet_received.emit(from, bytes)


# ------------------------------------------------------------------------------------ going out


func send(to: int, bytes: PackedByteArray, reliable: bool) -> void:
	if _peer == null:
		return
	_peer.set_transfer_mode(
		MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable
		else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	)
	_peer.set_target_peer(to)
	_peer.put_packet(bytes)


func peers() -> PackedInt32Array:
	var out := PackedInt32Array()
	for id: int in _roster:
		out.append(id)
	return out


func local_id() -> int:
	if _peer == null:
		return SERVER_ID
	return _peer.get_unique_id()


# ------------------------------------------------------------------------------------- forwarding


func _on_peer_connected(id: int) -> void:
	_roster[id] = true
	peer_joined.emit(id)


func _on_peer_disconnected(id: int) -> void:
	# Erased BEFORE the signal, so a handler that asks `peers()` gets the world as it is after the
	# departure rather than one that still contains the peer it is being told about.
	_roster.erase(id)
	peer_left.emit(id)
