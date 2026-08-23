extends SceneTree
## Does repainting the cutaway for the cells that moved give the same picture as repainting the lot?
##
##   godot --headless --path . --script tools/fog_repaint_probe.gd
##
## `show_glimpsed` used to call [method TunnelNetwork._rebuild_mask], which re-contours EVERY chunk
## of a plane. It runs from `tunnel_sight._publish` on every physics frame and fires whenever the
## seen set moves by one cell, which measured at just over 100ms on plane 1 -- the single biggest
## hitch in an underground match. It now dirties only the chunks the changed cells can reach.
##
## THAT MAKES THE REACH THE WHOLE RISK, and it is a silent one: too short and a corridor keeps a
## sliver of lid over it, or stays open after the crew forgot it, until something else happens to
## dirty that chunk. Nothing errors and no rule is broken -- the fog simply lies, in a way that is
## only visible if you are looking at that spot when it happens.
##
## SO THE CHECK IS THE TEXTURE ITSELF, TEXEL FOR TEXEL, against the wholesale repaint it replaced.
## `is_cut_away` samples one point per cell and would agree with a picture that was wrong a
## centimetre either side of it; the image is what the shader actually reads.
##
## BOTH DIRECTIONS, because seeing and forgetting are different code paths through the same diff:
## cells arrive, cells leave, and cells do both at once while the set stays the same size.
##
## VERIFIED BY BREAKING IT: cutting the reach in `_remask_cells` down to the cell's own square
## makes this go red on the first sighting.

const STROKES: int = 120


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var network := scene.get_node("Tunnels") as TunnelNetwork

	# Two crews, so the viewing crew has somebody else's corridors to NOT be shown -- against one
	# crew's own network every stroke is wanted and the fog has nothing to hide.
	#
	# AND THE TWO NETWORKS ARE KEPT WELL APART, which the first version did not do: interleaving the
	# crews along the same rows made every cell a shared junction (see `_learn_tunnel_cell`), blue
	# was told about almost all of red's corridor, and four hidden cells is not a fog to test.
	for total in range(STROKES / 2):
		var row := float(total / 20) * 1.4 - 12.0
		var along := float(total % 20) * 1.05 - 14.0
		network.dig_segment(1, Vector2(along, row), 0, Team.BLUE)
	for total in range(STROKES / 2):
		var row := float(total / 20) * 1.4 + 4.0
		var along := float(total % 20) * 1.05 + 4.0
		network.dig_segment(1, Vector2(along, row), 0, Team.RED)
	network.show_crew_knowledge(Team.BLUE)

	var red: Array[Vector2i] = []
	for cell: Vector2i in network.dug_cells(1):
		if not network.is_tunnel_known(1, cell, Team.BLUE):
			red.append(cell)
	red.sort()
	if red.size() < 12:
		print("BROKEN: only %d cells are hidden from blue, so the fog had nothing to uncover."
			% red.size())
		quit(1)
		return

	var bad := 0
	var rounds := 0
	# Arriving, growing, moving sideways, shrinking, gone -- the last of which is the case that only
	# exercises the leaving half of the diff.
	var scripts := [
		red.slice(0, 4),
		red.slice(0, 9),
		red.slice(5, 14),
		red.slice(10, 14),
		[],
	]
	for seen: Array in scripts:
		rounds += 1
		network.show_glimpsed(Team.BLUE, 1, seen)
		var scoped := (network.get("_mask_images")[1] as Image).get_data()

		# The picture the old wholesale path would have drawn, from the same state.
		network.call("_rebuild_mask", 1)
		var whole := (network.get("_mask_images")[1] as Image).get_data()

		if scoped != whole:
			var differing := 0
			for i in range(mini(scoped.size(), whole.size())):
				if scoped[i] != whole[i]:
					differing += 1
			print("ROUND %d (%d cells seen): %d texels of %d disagree"
				% [rounds, seen.size(), differing, whole.size()])
			bad += 1
		else:
			print("round %d (%d cells seen): identical" % [rounds, seen.size()])

	if bad == 0:
		print("\nFOG REPAINT OK -- %d sightings, the scoped repaint matches the wholesale one."
			% rounds)
	else:
		print("\n=== %d of %d sightings drew a different cutaway. ===" % [bad, rounds])
	quit(0 if bad == 0 else 1)
