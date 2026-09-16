extends SceneTree
## Regression coverage for state that a client cannot infer from poses or its own keyboard.

var failures: int = 0
var checks: int = 0

class RecordingTransport extends ENetTransport:
	var packets: Array[Dictionary] = []
	func send(to: int, bytes: PackedByteArray, reliable: bool) -> void:
		packets.append({"to": to, "bytes": bytes, "reliable": reliable})


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(scene)
	await process_frame
	await process_frame
	var mouse := scene.get_node("Player") as Mouse
	var net := scene.get_node("NetMatch")
	var tunnels := scene.get_node("Tunnels") as TunnelNetwork
	var shot := Snapshot.new()
	shot.tick = 10
	shot.add(0, mouse.global_position, 0, 0, 200, 64, 7.0, true)
	shot.add(1, mouse.global_position, 0, 0, 255, 12, 0.0, false)
	var decoded := Snapshot.from_bytes(shot.to_bytes(0))
	check("owner receives stamina", decoded != null and decoded.poses[0].stamina == 64)
	check("other seats do not reveal stamina", decoded != null and decoded.poses[1].stamina == 255)
	if decoded == null:
		quit(1)
		return
	var pose := decoded.poses[0]
	mouse.set_puppet(true)
	mouse.apply_pose(pose.position, pose.facing, pose.flags, pose.health, pose.stamina, pose.speed, pose.boosting)
	check("puppet reports authoritative speed without simulating velocity", mouse.velocity == Vector3.ZERO and is_equal_approx(mouse.get_horizontal_speed(), 7.0))
	check("puppet stamina bar reflects the server", absf(mouse.get_stamina_ratio() - 64.0 / 255.0) < 0.001)
	check("puppet knows it is scurrying", mouse.is_boosting())
	var grass := GrassPatch.new()
	check("running puppet makes the same grass tell as a running body", grass.speed_tell(mouse) > 0.99)
	grass.free()
	mouse.apply_pose(pose.position, 0, 0, 255, 255, 0.0, false)
	check("next pose clears the movement and boost", mouse.get_horizontal_speed() == 0 and not mouse.is_boosting())
	check("new snapshot length rejects old/truncated packets", Snapshot.from_bytes(shot.to_bytes(0).slice(0, -1)) == null)

	# The receiver has never pressed DUST. Only the server's serialized state may create it.
	var source := DustScreen.raise(tunnels, Vector3(6, 0, 6), 0, 0, 4.0)
	source.adopt_age(0.35)
	var state: DustState = net._dust_for(Team.RED, 5)
	state.revision = 1
	check("surface cloud is offered to the opposing crew", state.clouds.size() == 1)
	var id := source.get_instance_id()
	var bytes := state.to_bytes()
	source.free()
	net._apply_dust(bytes)
	var replica: DustScreen = net._dust_replicas.get(id)
	check("server picture creates dust without local input", is_instance_valid(replica))
	if is_instance_valid(replica):
		check("replica blocks sight and retains age", replica.is_opaque() and absf(replica.age() - 0.35) < 0.001)
		state.revision = 2
		net._apply_dust(state.to_bytes())
		check("repeated picture reuses the cloud", net._dust_replicas.get(id) == replica)
		var empty := DustState.new()
		empty.revision = 3
		net._apply_dust(empty.to_bytes())
		check("empty picture removes expired or hidden clouds", replica.is_queued_for_deletion() and net._dust_replicas.is_empty())
		net._apply_dust(bytes)
		check("late packet cannot resurrect old dust", net._dust_replicas.is_empty())
	await process_frame
	var hidden := DustScreen.raise(tunnels, Vector3(25, tunnels.plane_y(2), 25), 0, 2, 4.0)
	check("unknown underground cloud is not leaked", net._dust_for(Team.RED, 5).clouds.is_empty())
	hidden.free()
	check("truncated dust picture is rejected", DustState.from_bytes(bytes.slice(0, -1)) == null)
	var broken := state.clouds[0]
	broken.radius = NAN
	check("nonfinite dust radius is rejected", DustState.from_bytes(state.to_bytes()) == null)
	_check_wire_paths(net, tunnels)
	print("REMOTE STATE: %d checks, %d failures" % [checks, failures])
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)


func _check_wire_paths(net: Node, tunnels: TunnelNetwork) -> void:
	# Capture the actual sender, then enter through the authenticated receive dispatcher.
	# A codec-only round trip would miss a field omitted by NetMatch on either side.
	var original_session: NetSession = net._net
	var original_transport: NetTransport = net._transport
	var wire := RecordingTransport.new()
	var session := NetSession.new()
	session._transport = wire
	session._seats = Seats.new(5)
	session._seats.sit(Team.BLUE, 0, 1)
	session._seats.sit(Team.RED, 0, 22)
	net._net = session
	net._transport = wire
	net._client_seats = session._seats
	var remote: Mouse = net._director.seat_mouse(Team.RED, 0)
	check("wire fixture has the remote seat", remote != null)
	if remote == null:
		net._net = original_session
		net._transport = original_transport
		session.free()
		wire.free()
		return
	wire._mode = NetTransport.Mode.SERVER
	remote.velocity = Vector3(3, 0, 4)
	remote._stamina = remote.sprint_seconds * 0.25
	remote._boost_left = 1.0
	net._broadcast_snapshot()
	check("snapshot sender addresses the remote peer", wire.packets.size() == 1 and wire.packets[0].to == 22)
	if wire.packets.is_empty():
		failures += 1
	else:
		remote.set_puppet(true)
		remote.refill_stamina()
		wire._mode = NetTransport.Mode.CLIENT
		net._tick = 0
		net._on_packet(999, wire.packets[0].bytes)
		check("another peer cannot write the snapshot", remote.get_stamina_ratio() == 1.0)
		net._on_packet(1, wire.packets[0].bytes)
		check("sender and receiver carry stamina end to end", absf(remote.get_stamina_ratio() - 0.25) < 0.005)
		check("sender and receiver carry movement and boost", remote.get_horizontal_speed() == 5.0 and remote.is_boosting())

	wire.packets.clear()
	wire._mode = NetTransport.Mode.SERVER
	var source := DustScreen.raise(tunnels, Vector3(6, 0, 6), 0, 0, 4)
	source.owner_mouse = remote
	var id := source.get_instance_id()
	net._send_dust()
	check("dust sender addresses the remote peer", wire.packets.size() == 1 and wire.packets[0].to == 22)
	source.free()
	var predicted := DustScreen.raise(tunnels, Vector3(6.1, 0, 6), 0, 0, 4)
	predicted.owner_mouse = remote
	wire._mode = NetTransport.Mode.CLIENT
	net._dust_tick = 0
	if not wire.packets.is_empty():
		net._on_packet(999, wire.packets[0].bytes)
		check("another peer cannot spawn dust", not net._dust_replicas.has(id))
		net._on_packet(1, wire.packets[0].bytes)
		check("authoritative dust reuses the local prediction", net._dust_replicas.get(id) == predicted)
		check("prediction is corrected to server position", predicted.global_position == Vector3(6, 0, 6))
	predicted.free()
	net._dust_replicas.clear()
	net._net = original_session
	net._transport = original_transport
	session.free()
	wire.free()


func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])
