extends SceneTree
## Rendered-region geometry must equal the complete chunk cache, including after removals.
## Also checks that distant meshes survive local edits and fog changes preserve all meshes.
var failures: int = 0
const FIELDS := ["floors", "walls", "stone", "bedrock"]
const NORMALS := ["floor_normals", "wall_normals", "stone_normals", "bedrock_normals"]

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _run() -> void:
	var network := TunnelNetwork.new()
	network.rock_density = 0.0
	network.rock_density_deeper = 0.0
	root.add_child(network)
	network.set_focus_plane(1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	for side in [-1, 1]:
		var rock := RockBody.grow(1, Vector2(side * 8.0, 0.3), 0.8, side < 0, rng)
		var rocks: Array = network.get("_rock_bodies")[1]
		rock.index = rocks.size()
		rocks.append(rock)
		network.call("_register_rock", rock)
	# Cross chunk/region boundaries, on both sides of the origin and at multiple angles.
	for plane in [1, 2]:
		for i in range(24):
			network.dig_segment(plane, Vector2(-12.0 + i, -0.3), 0, Team.BLUE)
		for i in range(8):
			network.dig_segment(plane, Vector2(7.8, -4.0 + i), 3, Team.RED)
	_check_geometry(network, "initial")
	var counts := [0, 0, 0, 0]
	for chunk: Dictionary in (network.get("_chunk_cache")[1] as Dictionary).values():
		for kind in range(4):
			counts[kind] += chunk[FIELDS[kind]].size()
	_check(counts.min() > 0, "fixture exercises floor, earth, stone, and bedrock geometry")
	var before := _meshes(network, 1)
	network.carve(1, TunnelNetwork.segment_id(Vector2(-12.0, -1.3), 0), 0.5, Team.BLUE)
	var after := _meshes(network, 1)
	var kept := 0
	var changed := 0
	for key in before:
		if after.get(key) == before[key]:
			kept += 1
		else:
			changed += 1
	_check(kept > 0 and changed > 0, "local carving updates nearby meshes and preserves distant meshes")
	_check_geometry(network, "carve")
	before = _meshes(network, 1)
	network.show_crew_knowledge(Team.RED)
	network.show_glimpsed(Team.RED, 1, [Vector2i.ZERO])
	_check(before == _meshes(network, 1), "fog changes preserve physical meshes")
	for focused in [0, 1, 2, 3]:
		network.set_focus_plane(focused)
		var correct := true
		for plane in [1, 2]:
			for parent in [network._floors[plane], network._walls[plane],
				network._rock_faces[plane], network._bedrock_faces[plane]]:
				for mesh in parent.get_children():
					correct = correct and (mesh.is_visible_in_tree() == (plane == focused))
		_check(correct, "plane %d focus propagates to every region" % focused)
	_check(network.collapse(2, Vector2i.ZERO), "collapse removes geometry")
	_check_geometry(network, "collapse")
	_check(network.dig(2, Vector2i.ZERO, Team.BLUE), "collapsed ground can be re-dug")
	_check_geometry(network, "re-dig")
	_check(network.clear_rock_at(1, Vector2i(-8, 0)), "breakable rock can be removed")
	_check_geometry(network, "rock removal")
	# Forget every committed stroke on a plane with no partial cuts: no stale meshes remain.
	var segments: Dictionary = network.get("_segments")[2]
	for id: int in segments.keys():
		network.forget_segment(2, TunnelNetwork.segment_origin(id), TunnelNetwork.segment_angle(id))
	await process_frame
	_check_geometry(network, "forgotten")
	_check((network.get("_render_regions")[2] as Dictionary).is_empty(), "empty regions release their nodes and meshes")
	network.queue_free()
	await process_frame
	print("REGION MESH failures=%d" % failures)
	quit(1 if failures else 0)

func _meshes(network: TunnelNetwork, plane: int) -> Dictionary:
	var result := {}
	var regions: Dictionary = network.get("_render_regions")[plane]
	for key: int in regions:
		var nodes: Array = regions[key]
		for kind in range(4):
			if nodes[kind] != null:
				result[Vector2i(key, kind)] = nodes[kind].mesh
	return result

func _check_geometry(network: TunnelNetwork, label: String) -> void:
	var correct := true
	for plane in [1, 2]:
		var cache: Dictionary = network.get("_chunk_cache")[plane]
		var regions: Dictionary = network.get("_render_regions")[plane]
		var expected := {}
		var keys := cache.keys()
		keys.sort()
		for key: int in keys:
			var region := int(network.call("_render_region_key", key))
			if not expected.has(region):
				expected[region] = [[], []]
				for kind in range(4):
					expected[region][0].append(PackedVector3Array())
					expected[region][1].append(PackedVector3Array())
			for kind in range(4):
				expected[region][0][kind].append_array(cache[key][FIELDS[kind]])
				expected[region][1][kind].append_array(cache[key][NORMALS[kind]])
		for region: int in expected:
			for kind in range(4):
				var vertices: PackedVector3Array = expected[region][0][kind]
				var normals: PackedVector3Array = expected[region][1][kind]
				var mesh: MeshInstance3D = regions[region][kind] if regions.has(region) else null
				if vertices.is_empty():
					correct = correct and mesh == null
					continue
				if mesh == null or mesh.mesh == null:
					correct = false
					continue
				var arrays := mesh.mesh.surface_get_arrays(0)
				if arrays[Mesh.ARRAY_VERTEX] != vertices:
					print("VERTICES plane=%d region=%d kind=%d expected=%d actual=%d" % [plane, region, kind, vertices.size(), arrays[Mesh.ARRAY_VERTEX].size()])
					correct = false
				# Compare through the same engine packing as the old combined mesh. Degenerate
				# triangles have zero input normals, which ArrayMesh encodes as a unit vector.
				var reference := network.call("_commit", vertices, normals,
					mesh.mesh.surface_get_material(0)) as ArrayMesh
				normals = reference.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
				var actual: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				if actual.size() != normals.size():
					correct = false
				else:
					for i in range(normals.size()):
						if actual[i].distance_to(normals[i]) > 0.001:
							print("NORMAL plane=%d region=%d kind=%d vertex=%d expected=%s actual=%s" % [plane, region, kind, i, normals[i], actual[i]])
							correct = false
							break
				var materials := [network.get("_floor_materials")[plane], network.get("_wall_materials")[plane],
					network.get("_rock_materials")[plane], network.get("_bedrock_materials")[plane]]
				correct = correct and mesh.mesh.surface_get_material(0) == materials[kind]
				correct = correct and mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				correct = correct and is_equal_approx(mesh.global_position.y, network.plane_y(plane))
		for region in regions:
			correct = correct and expected.has(region)
	_check(correct, "%s: all region vertices/normals match the complete chunk cache" % label)
