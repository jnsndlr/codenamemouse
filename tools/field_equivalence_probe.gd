extends SceneTree
## Does composing a chunk incrementally give the same field as composing it from nothing?
##
##   godot --headless --path . --script tools/field_equivalence_probe.gd
##
## `_rebuild_chunk` now keeps a composed committed field across a dig and paints only the strokes
## that arrived, instead of throwing the window away and walking every stroke again. That is only
## sound because the field is a `max` union -- so the check is the direct one: dig a network the
## long way round, then for every chunk compare the entry that was grown incrementally against one
## composed from scratch, texel for texel.
##
## RUN WITH A VIEWING CREW AS WELL AS WITHOUT, because the incremental path has a second premise --
## that no stroke already in the window changed what it is SHOWN as. `_segment_wants` is constant
## on a server (`_view_team < 0`) and is not on a client, so a run without a crew cannot fail the
## half of this that is about knowledge.
##
## AND KNOWLEDGE IS MOVED UNDER IT ON PURPOSE, by digging with both crews and letting the fog
## reveal cells as it goes -- a check that never changes what the viewer knows would agree with
## itself no matter what the stamp did.

const STROKES: int = 200


func _initialize() -> void:
	var bad := 0
	var checked := 0
	for viewer in [-1, 0]:
		var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
		root.add_child(scene)
		await process_frame
		await process_frame
		var network := scene.get_node("Tunnels") as TunnelNetwork
		if viewer >= 0:
			network.show_crew_knowledge(viewer)

		for total in range(STROKES):
			var row := float(total / 24) * 1.3 - 14.0
			var along := float(total % 24) * 1.05 - 12.0
			var from := Vector2(along, row)
			var id := TunnelNetwork.segment_id(from, 0)
			var cut := TunnelContour.TEXEL
			while cut < TunnelNetwork.SEG_LENGTH:
				network.carve(1, id, cut, total % 2)
				cut += TunnelContour.TEXEL
			# Both crews dig, so what the viewer knows keeps moving underneath the cache.
			network.dig_segment(1, from, 0, total % 2)

		# EVERY CHUNK BROUGHT UP TO DATE FIRST, or this compares a chunk nothing has dirtied since
		# the last stroke against one composed a moment ago. A stroke is gathered from the window's
		# cells PLUS A RING, which reaches a little further than the dirtying does -- so a chunk can
		# legitimately be carrying a composition that predates a stroke sitting just outside it, and
		# will pick it up on whatever dirties it next. That is the state the old path left too; it
		# is not what this probe is asking about.
		var all_dirty: Dictionary = network.get("_dirty_chunks")[1]
		for k: int in (network.get("_chunk_cache")[1] as Dictionary):
			all_dirty[k] = true
		network.call("_rebuild_walls", 1, false)

		var grown: Dictionary = network.get("_committed_field")[1]
		var keys: Array = grown.keys()
		var mine := {}
		for key: int in keys:
			mine[key] = (grown[key] as Dictionary).duplicate(true)

		# Compose every one of them again from nothing, which is what the old path did on any dig.
		grown.clear()
		for key: int in keys:
			network.call("_rebuild_chunk", 1, key)

		for key: int in keys:
			var was: Dictionary = mine[key]
			var now: Variant = grown.get(key)
			checked += 1
			if now == null:
				print("MISSING chunk %d (view_team=%d)" % [key, viewer])
				bad += 1
				continue
			var fresh: Dictionary = now as Dictionary
			for field: String in ["shape", "seen"]:
				var a: PackedFloat32Array = was[field]
				var b: PackedFloat32Array = fresh[field]
				if a.size() != b.size():
					print("SIZE chunk %d %s (view_team=%d)" % [key, field, viewer])
					bad += 1
					continue
				var worst := 0.0
				for i in range(a.size()):
					worst = maxf(worst, absf(a[i] - b[i]))
				if worst > 0.0:
					print("DIFF chunk %d %s worst=%f (view_team=%d)" % [key, field, worst, viewer])
					bad += 1
			if bool(was["hidden"]) != bool(fresh["hidden"]):
				print("HIDDEN chunk %d grown=%s fresh=%s ids=%d (view_team=%d)" % [
					key, was["hidden"], fresh["hidden"], (was["ids"] as Dictionary).size(), viewer])
				var old_ids: Dictionary = was["ids"]
				var new_ids: Dictionary = fresh["ids"]
				for oid: int in new_ids:
					var stored_now := int(new_ids[oid]) != 0
					var stored_then := int(old_ids.get(oid, 1)) != 0
					if stored_now != stored_then:
						print("   id %d: grown said shown=%s, fresh says shown=%s, present_then=%s"
							% [oid, stored_then, stored_now, old_ids.has(oid)])
				bad += 1
		print("view_team=%d: %d chunks compared" % [viewer, keys.size()])
		scene.queue_free()
		await process_frame

	if bad == 0:
		print("\nFIELD EQUIVALENCE OK -- %d chunks, grown and from-scratch agree exactly." % checked)
	else:
		print("\n=== %d DISAGREEMENTS across %d chunks. ===" % [bad, checked])
	quit(0 if bad == 0 else 1)
