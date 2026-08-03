extends SceneTree
## Stands up a real server and two real clients on a real socket, and makes them talk.
##
## WHY THIS EXISTS BEFORE ANYTHING USES THE TRANSPORT. `net_transport.gd` is an interface with one
## implementation and no consumer yet, which is the state in which a wrapper is least trustworthy
## and most likely to be wrong in a way nobody notices for a week — by which point five other files
## have been written against its behaviour. Every other `tools/` suite in this project was written
## after the thing it checks. This one is written first on purpose, because the layer above it is
## the whole rest of M7.
##
## TWO CLIENTS, NOT ONE, AND THAT IS THE POINT OF THE FILE. With a single client every packet the
## server receives came from the only peer there is, so "who sent this" is right by luck. The
## ordering bug this guards — reading `get_packet` before `get_packet_peer`, which pops the packet
## and then reports the *next* sender — is invisible with one client and misattributes every packet
## with two. In a match that reads as one player's inputs driving another player's mouse, which
## looks like a gameplay bug and is not one.
##
## Runs headless; ENet needs no renderer.
##   godot --headless --path . --script res://tools/net_audit.gd

## High and unloved. Retried upward if something else has it, because a busy port must fail as
## "try again" rather than as "the transport is broken" -- the two look identical in a CI log.
const FIRST_PORT: int = 47921
const PORT_TRIES: int = 12
## Generous: this is a loopback connection, and a slow machine under load is not a failure.
const CONNECT_FRAMES: int = 240
const DELIVER_FRAMES: int = 90

var _failures: int = 0
var _inbox: Dictionary = {}


func _initialize() -> void:
	var server := ENetTransport.new()
	var alice := ENetTransport.new()
	var bob := ENetTransport.new()
	for node: NetTransport in [server, alice, bob]:
		root.add_child(node)
		node.packet_received.connect(_remember.bind(node))

	print("-- offline is a mode, not an error")
	_check("a fresh transport is offline", server.mode() == NetTransport.Mode.OFFLINE)
	_check("and is still the authority", server.is_server())
	_check("and calls itself the server id", server.local_id() == NetTransport.SERVER_ID)
	# Every failure path calls close(); it must be safe on something that never opened.
	server.close()
	_check("closing an unopened transport is harmless", server.mode() == NetTransport.Mode.OFFLINE)
	# Sending into the void must not raise -- offline, the game still calls broadcast every tick.
	server.broadcast(_say("into the void"), false)
	_check("sending while offline is a no-op rather than a crash", true)

	var port := await _host_somewhere(server)
	if port < 0:
		print("BROKEN: could not open any port in %d tries" % PORT_TRIES)
		quit(1)
		return

	print("\n-- two clients connect")
	_check("the host is a server", server.mode() == NetTransport.Mode.SERVER and server.is_server())
	alice.join("127.0.0.1", port)
	bob.join("127.0.0.1", port)
	var joined := await _await_until(func() -> bool: return server.peers().size() >= 2, CONNECT_FRAMES)
	_check("the server sees both of them", joined)
	if not joined:
		_finish(server, alice, bob)
		return

	_check("a client is not a server", not alice.is_server() and alice.mode() == NetTransport.Mode.CLIENT)
	_check("the server keeps id 1", server.local_id() == NetTransport.SERVER_ID)
	_check("the clients do not", alice.local_id() != NetTransport.SERVER_ID and bob.local_id() != NetTransport.SERVER_ID)
	_check("and are not each other", alice.local_id() != bob.local_id())
	_check("a client's peer list is the server", alice.peers().size() == 1 and alice.peers()[0] == NetTransport.SERVER_ID)

	print("\n-- bytes arrive, attributed to whoever sent them")
	_inbox.clear()
	alice.send(NetTransport.SERVER_ID, _say("alice"), true)
	bob.send(NetTransport.SERVER_ID, _say("bob"), true)
	await _await_until(func() -> bool: return _mail(server).size() >= 2, DELIVER_FRAMES)

	var at_server := _mail(server)
	_check("the server got both packets", at_server.size() == 2)
	# The assertion the file exists for.
	_check(
		"alice's packet is credited to alice",
		_sender_of(at_server, "alice") == alice.local_id()
	)
	_check(
		"bob's packet is credited to bob",
		_sender_of(at_server, "bob") == bob.local_id()
	)

	print("\n-- the server can answer one client, or all of them")
	_inbox.clear()
	server.send(alice.local_id(), _say("for alice only"), true)
	await _await_until(func() -> bool: return not _mail(alice).is_empty(), DELIVER_FRAMES)
	_check("alice got hers", _bodies(_mail(alice)).has("for alice only"))
	_check("and bob did NOT", not _bodies(_mail(bob)).has("for alice only"))
	_check("from the server id", _sender_of(_mail(alice), "for alice only") == NetTransport.SERVER_ID)

	_inbox.clear()
	server.broadcast(_say("everyone"), true)
	await _await_until(
		func() -> bool: return not _mail(alice).is_empty() and not _mail(bob).is_empty(),
		DELIVER_FRAMES
	)
	_check("a broadcast reaches alice", _bodies(_mail(alice)).has("everyone"))
	_check("a broadcast reaches bob", _bodies(_mail(bob)).has("everyone"))

	print("\n-- unreliable packets are still packets")
	_inbox.clear()
	server.broadcast(_say("unreliable"), false)
	var got_unreliable := await _await_until(
		func() -> bool: return not _mail(alice).is_empty(), DELIVER_FRAMES
	)
	# Over loopback an unreliable packet has nothing to be lost to. If this ever flakes on a real
	# network that is the protocol working, not this failing -- which is why it is the only check
	# here that would be wrong to tighten.
	_check("an unreliable broadcast arrives over loopback", got_unreliable)

	print("\n-- leaving")
	var alice_id := alice.local_id()
	var seen_leave: Array[int] = []
	server.peer_left.connect(func(id: int) -> void: seen_leave.append(id))
	alice.close()
	_check("a closed client is offline again", alice.mode() == NetTransport.Mode.OFFLINE)
	await _await_until(func() -> bool: return not seen_leave.is_empty(), CONNECT_FRAMES)
	_check("the server is told who left", seen_leave.has(alice_id))
	_check("and still has bob", server.peers().size() == 1 and server.peers()[0] == bob.local_id())

	_finish(server, alice, bob)


func _finish(server: NetTransport, alice: NetTransport, bob: NetTransport) -> void:
	for node: NetTransport in [server, alice, bob]:
		node.close()
	print("")
	if _failures > 0:
		print("=== %d FAILED. The transport is not carrying what it says it is. ===" % _failures)
		quit(1)
		return
	print("==============================================================================")
	print("THE WIRE HOLDS: connect, attribute, address, broadcast and leave.")
	print("==============================================================================")
	quit()


# ---------------------------------------------------------------------------------------- helpers


## A port nobody else is on. Reported as BROKEN rather than FAILED if none is free, because "the
## machine is busy" and "the code is wrong" must not print the same word.
func _host_somewhere(server: NetTransport) -> int:
	for i: int in range(PORT_TRIES):
		var port := FIRST_PORT + i
		if server.host(port, 8) == OK:
			print("-- hosting on %d" % port)
			return port
		await process_frame
	return -1


func _say(body: String) -> PackedByteArray:
	return body.to_utf8_buffer()


func _remember(from: int, bytes: PackedByteArray, who: NetTransport) -> void:
	if not _inbox.has(who):
		_inbox[who] = []
	_inbox[who].append({"from": from, "body": bytes.get_string_from_utf8()})


func _mail(who: NetTransport) -> Array:
	return _inbox.get(who, [])


func _bodies(mail: Array) -> Array:
	return mail.map(func(m: Dictionary) -> String: return m["body"])


## Who sent the packet with this body, or -1. Returning the id rather than a bool is what lets the
## attribution checks name the peer they expected instead of just saying "wrong".
func _sender_of(mail: Array, body: String) -> int:
	for m: Dictionary in mail:
		if m["body"] == body:
			return m["from"]
	return -1


func _await_until(done: Callable, frames: int) -> bool:
	for i: int in range(frames):
		if done.call():
			return true
		await process_frame
	return done.call()


func _check(what: String, ok: bool) -> void:
	print("   %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
