extends SceneTree
## Photographs the ability chip row under your own bars, so "the HUD greys out" can be looked at
## rather than asserted.
##
## THE SNEAK IS THE SUBJECT because it is the only class with three chips, and because two of its
## three can be fired from a standing start on bare lawn -- Q sounds out bedrock and still pays its
## cooldown, X throws the screen at your feet. That leaves V lit, so one frame carries all three
## states the row can be in: spent, part way back, and ready.
##
## THE GENERALIST IS THE SECOND FRAME, for the opposite reading: two chips rather than three, and
## Second Wind is the longest cooldown in the game (40s), so its chip is the one that spends real
## time visibly empty. A row that is legible at 40 seconds and at 6 is a row that does not need a
## number on it.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --resolution 1100x760 --script res://tools/ability_pips_shot.gd

const OUT := "user://"


func _initialize() -> void:
	var scene: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in range(40):
		await process_frame

	var player := scene.get_node("Player") as Mouse
	var rig: Node3D = scene.get_node("CameraRig")
	rig.set("zoom_idle", 4.5)
	rig.set("speed_zoom", false)

	await _shoot(player, MouseClass.SNEAK, ["Sonar", "DustKick"], "ability_pips_sneak.png")
	await _shoot(player, MouseClass.GENERALIST, ["SecondWind"], "ability_pips_generalist.png")

	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()


## Wear a class, spend the named abilities, let them come part way back, and take the picture.
##
## FIRED THROUGH THE ABILITIES' OWN PUBLIC DOORS -- `scan`, `kick`, `take_breath` -- which exist for
## exactly this and are what the audits use. Reaching into `_cooldown_left` would photograph a
## number this file had written rather than one the game had.
func _shoot(player: Mouse, kind: int, spend: Array, file: String) -> void:
	player.set_class(kind)
	player.revive_at(Vector3.ZERO, 0.0)
	for i in range(20):
		await process_frame
	# Second Wind refuses at full health with a full tank -- "you have breath to spare" -- so a
	# Generalist photographed untouched has a chip that never left the lit state. Taking a bite out
	# of it first is the difference between a shot of the row and a shot of the row doing its job.
	player.take_hit(45.0, player.global_position + Vector3.FORWARD, 0.0)

	for node_name: String in spend:
		var ability := player.get_node_or_null(NodePath(node_name))
		if ability == null:
			print("%s: no %s on this mouse" % [file, node_name])
			continue
		for door: String in ["scan", "kick", "take_breath", "go_to_glass"]:
			if ability.has_method(door):
				ability.call(door)
				break

	# Long enough for a 6s chip to be visibly part way back and a 40s one to be visibly not.
	for i in range(110):
		await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(OUT + file)

	var report := PackedStringArray()
	for node_name: String in ["SecondWind", "ShoreUp", "Sonar", "CaveIn", "BannerToss", "Fade",
			"Slam", "Barricade", "DustKick"]:
		var ability := player.get_node_or_null(NodePath(node_name))
		if ability == null or int(ability.get("owner_class")) != player.mouse_class:
			continue
		var left: float = ability.call("cooldown_left") if ability.has_method("cooldown_left") else 0.0
		report.append("%s %.1fs" % [node_name, left])
	print("%s: %s -- %s" % [file, MouseClass.name_of(kind), ", ".join(report)])
