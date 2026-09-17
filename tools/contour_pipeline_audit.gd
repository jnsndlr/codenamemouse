extends SceneTree
## Differential reference: full partial-stroke scan, no processed-input reuse, one segment per batch.
class Reference extends TunnelNetwork:
	func _carves_in_box(plane: int, _box: Rect2) -> Dictionary:
		return _carving[plane]
	func _rebuild_chunk(plane: int, key: int, mask_only: bool = false, upload: bool = true) -> bool:
		_chunk_inputs[plane].erase(key)
		return super._rebuild_chunk(plane, key, mask_only, upload)
	func adopt_segments(entries: Array) -> int:
		var count := 0
		for entry in entries:
			count += super.adopt_segments([entry])
		return count

var failures := 0
var fast: TunnelNetwork
var reference: TunnelNetwork

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _run() -> void:
	fast = TunnelNetwork.new()
	reference = Reference.new()
	for network in [fast, reference]:
		network.rock_density = 0.0
		network.rock_density_deeper = 0.0
		root.add_child(network)
	var rng := RandomNumberGenerator.new()
	rng.seed = 76543
	var cuts: Array[int] = []
	for i in range(96):
		var from := Vector2(rng.randf_range(-12.0, 12.0), rng.randf_range(-8.0, 8.0))
		var id := TunnelNetwork.segment_id(from, i % TunnelNetwork.ANGLE_STEPS)
		cuts.append(id)
		for network in [fast, reference]:
			network.carve(1, id, 0.25, i % 2)
	_same("96 partial strokes across positive/negative bucket boundaries")
	for i in range(24):
		for network in [fast, reference]:
			network.carve(1, cuts[i], 0.875, i % 2)
	_same("resumed strokes extend beyond original tips")
	for i in range(24):
		for network in [fast, reference]:
			network.dig_segment(1, TunnelNetwork.segment_origin(cuts[i]), TunnelNetwork.segment_angle(cuts[i]), i % 2)
	_same("commits remove indexed partials")
	for network in [fast, reference]:
		network.show_crew_knowledge(Team.RED)
		network.show_glimpsed(Team.RED, 1, [Vector2i.ZERO, Vector2i(1, 1)])
	_same("fog-only changes")
	for network in [fast, reference]:
		network.call("_rebuild_mask", 1)
	_same("full mask clearing/repaint preserves cached texels")
	# Repeat an unchanged physical rebuild: cache hits must preserve meshes AND unpaid collision.
	for network in [fast, reference]:
		var dirty: Dictionary = network.get("_dirty_chunks")[1]
		for key in network.get("_chunk_cache")[1]:
			dirty[key] = true
		network.call("_rebuild_walls", 1, true)
	_same("unchanged rebuild and pending collision flush")
	var meshes := {}
	for nodes: Array in (fast.get("_render_regions")[1] as Dictionary).values():
		for node in nodes:
			if node != null:
				meshes[node] = node.mesh
	for key in fast.get("_chunk_cache")[1]:
		fast.get("_dirty_chunks")[1][key] = true
	fast.call("_rebuild_walls", 1, true)
	var reused := true
	for node in meshes:
		reused = reused and node.mesh == meshes[node]
	_check(reused, "unchanged inputs preserve mesh resource identity")
	for network in [fast, reference]:
		network.earth_min_thickness += 0.125
		network.island_max_area += 0.25
		for key in network.get("_chunk_cache")[1]:
			network.get("_dirty_chunks")[1][key] = true
		network.call("_rebuild_walls", 1)
	_same("runtime shape settings invalidate reuse")
	for network in [fast, reference]:
		for cell in network.dug_cells(1).slice(0, 8):
			network.collapse(1, cell)
	_same("collapse removes partials and invalidates affected chunks")
	# No reference to a removed partial stroke may remain in a bucket.
	var valid := true
	for bucket: Dictionary in (fast.get("_carve_buckets")[1] as Dictionary).values():
		for id in bucket:
			valid = valid and fast.carving(1).has(id)
	_check(valid, "partial index contains no committed/collapsed IDs")
	var entries: Array[Dictionary] = []
	for i in range(48):
		entries.append({"plane": 2, "origin": Vector2(-12.0 + i % 24, -2.0 + i / 24), "angle": 0, "bits": 1})
	var a := Time.get_ticks_usec()
	fast.adopt_segments(entries)
	var batched := Time.get_ticks_usec() - a
	a = Time.get_ticks_usec()
	reference.adopt_segments(entries)
	var uncached := Time.get_ticks_usec() - a
	var sequential := TunnelNetwork.new()
	sequential.rock_density = 0.0
	sequential.rock_density_deeper = 0.0
	sequential.earth_min_thickness = fast.earth_min_thickness
	sequential.island_max_area = fast.island_max_area
	root.add_child(sequential)
	sequential.show_crew_knowledge(Team.RED)
	a = Time.get_ticks_usec()
	for entry in entries:
		sequential.adopt_segment(entry["plane"], entry["origin"], entry["angle"], entry["bits"])
	print("BATCH 48 strokes batched=%.2f sequential_same_caches=%.2f uncached_reference=%.2f ms" % [
		batched / 1000.0, (Time.get_ticks_usec() - a) / 1000.0, uncached / 1000.0])
	sequential.queue_free()
	_same("48-stroke terrain batch vs sequential application", 2)
	var route := fast.graph().route(2, Vector2i(-10, -2), 2, Vector2i(8, -2))
	_check(not route.is_empty() and route == reference.graph().route(2, Vector2i(-10, -2), 2, Vector2i(8, -2)), "batch publishes equivalent reachable routing graph")
	# Rock edits can leave the raw tunnel field unchanged; their revision must invalidate reuse.
	for network in [fast, reference]:
		var stone_rng := RandomNumberGenerator.new()
		stone_rng.seed = 43
		var rock := RockBody.grow(2, Vector2(-4.0, -2.0), 0.8, true, stone_rng)
		var rocks: Array = network.get("_rock_bodies")[2]
		rock.index = rocks.size()
		rocks.append(rock)
		network.call("_register_rock", rock)
		network.call("_touch_box", 2, rock.bounds())
		network.call("_rebuild_walls", 2)
	_same("rock changes invalidate cached inputs", 2)
	for network in [fast, reference]:
		network.clear_rock_at(2, Vector2i(-4, -2))
	_same("rock removal restores identical geometry", 2)
	var packet := NetMessage.head(NetMessage.Kind.TUNNELS)
	var rows := [
		[TunnelView.Kind.SEGMENT, 2, 256, -32, 0, 1],
		[TunnelView.Kind.SEGMENT, 2, 272, -32, 0, 1],
		[TunnelView.Kind.FORGET, 2, 256, -32, 0, 0],
		[TunnelView.Kind.SEGMENT, 2, 256, -32, 0, 2]]
	packet.put_u8(rows.size())
	for row in rows:
		packet.put_u8(row[0])
		packet.put_u8(row[1])
		packet.put_16(row[2])
		packet.put_16(row[3])
		packet.put_u8(row[4])
		packet.put_u8(row[5])
	for network in [fast, reference]:
		var receiver := (load("res://scripts/net/net_match.gd") as GDScript).new() as Node
		receiver.set("_tunnels", network)
		receiver.call("_apply_earth", packet.data_array)
		_check(int(receiver.get("_earth_taken")) == rows.size(), "packet counts every entry")
		receiver.free()
	_same("mixed segment/forget/re-add packet preserves entry order", 2)
	for network in [fast, reference]:
		network.queue_free()
	await process_frame
	print("CONTOUR PIPELINE failures=%d" % failures)
	quit(1 if failures else 0)

func _same(label: String, plane: int = 1) -> void:
	var ac: Dictionary = fast.get("_chunk_cache")[plane]
	var bc: Dictionary = reference.get("_chunk_cache")[plane]
	var equal := ac.size() == bc.size()
	for key in ac:
		if not bc.has(key):
			equal = false
			continue
		for field in ["floors", "walls", "stone", "bedrock", "collision", "field", "islands"]:
			if ac[key][field] != bc[key][field]:
				print("DIFF %s chunk=%d field=%s" % [label, key, field])
				equal = false
	var ai: Image = fast.get("_mask_images")[plane]
	var bi: Image = reference.get("_mask_images")[plane]
	equal = equal and ai.get_data() == bi.get_data()
	_check(equal, label)
