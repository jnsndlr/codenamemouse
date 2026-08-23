extends SceneTree
## What digging costs, and how that cost grows with what has already been dug.
##
##   godot --headless --path . --script tools/dig_cost_probe.gd
##
## THE NUMBER THAT MATTERS IS THE SLOPE, not the first row. Both halves of this run on the main
## thread, so a dig priced at the size of the MAP rather than at the size of the hole is a dropped
## frame for everybody in the match -- and one that gets worse the longer the match runs. Neither
## fault was visible in a bot soak: the bots never get the network past about forty strokes.
##
## TWO PATHS, BECAUSE THEY COST DIFFERENT THINGS AND ONLY ONE OF THEM IS THE HOT ONE.
##
##   COMMIT  `dig_segment` -- the stroke landing. A handful a second at most, and it is the one that
##           re-composes the earth around it from every stroke that reaches into it.
##
##   CARVE   `carve` -- the trench growing under a held button, sixteen times a second, and by far
##           the bigger bill over a match. It moves one stroke's tip and nothing else, so it should
##           cost a small constant however much has been dug around it. If this row climbs with the
##           network, the committed field is being re-derived when it did not have to be.

const STEP: int = 20
const ROUNDS: int = 12


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var network := scene.get_node("Tunnels") as TunnelNetwork

	var total := 0
	for round_index in range(ROUNDS):
		var commits := 0
		var carves := 0
		var carve_steps := 0
		for i in range(STEP):
			# Walked out along rows so the strokes chain into corridors rather than landing as
			# unconnected pips -- a lone stroke shares its chunk with nothing and hides the slope.
			var row := float(total / 24) * 1.3 - 14.0
			var along := float(total % 24) * 1.05 - 12.0
			var from := Vector2(along, row)
			var id := TunnelNetwork.segment_id(from, 0)

			# The trench growing, a texel at a time, exactly as a held dig drives it.
			var cut := TunnelContour.TEXEL
			while cut < TunnelNetwork.SEG_LENGTH:
				var t := Time.get_ticks_usec()
				network.carve(1, id, cut, 0)
				carves += Time.get_ticks_usec() - t
				carve_steps += 1
				cut += TunnelContour.TEXEL

			var c := Time.get_ticks_usec()
			network.dig_segment(1, from, 0, 0)
			commits += Time.get_ticks_usec() - c
			total += 1
		print("DIG\tsegments=%4d\tcommit=%6.2f ms\tcarve step=%5.2f ms  (%d steps)" % [
			network.segment_count(1),
			float(commits) / 1000.0 / float(STEP),
			float(carves) / 1000.0 / float(maxi(carve_steps, 1)),
			carve_steps,
		])
	quit()
