extends CanvasLayer
## Live sliders for the pixel pass. F1 shows and hides it.
##
## The reference project this look was ported from (KodyJKing/hello-threejs) ships a dat.GUI
## panel, and that is not incidental to it -- the whole thing is a set of coefficients whose
## right values are a matter of taste, and taste cannot be exercised through a recompile. The
## numbers in the shader are a starting guess. This is how they stop being one.
##
## Built in code rather than in the .tscn on purpose. A dozen sliders is a hundred lines of
## unreadable scene diff, and every one of them would need hand-editing to add a control; here
## the panel is the CONTROLS table below and nothing else.
##
## Deliberately NOT hooked to a save file. A value you like should end up written into the
## scene's shader parameters and the camera rig's exports, where it is reviewable and can be
## explained. A tuning UI that quietly persists is a tuning UI whose numbers nobody can trace.

## One row per tunable. `target` says who owns it:
##   "shader" -- a uniform on the pixel pass material
##   "rig"    -- an exported property on the camera rig
##
## `pixel_size` is the one value both of them need: the shader quantises to it and the camera
## snaps to it, and if they ever disagree the snapping aligns to the wrong grid and makes the
## crawl worse than no snapping at all. So it is written to both, from one slider.
const CONTROLS: Array[Dictionary] = [
	{"name": "pixel_size", "label": "pixelSize", "min": 1.0, "max": 20.0, "step": 1.0,
		"target": "both"},
	{"name": "normal_edge_strength", "label": "normalEdgeStrength", "min": 0.0, "max": 2.0,
		"step": 0.05, "target": "shader"},
	{"name": "depth_edge_strength", "label": "depthEdgeStrength", "min": 0.0, "max": 1.0,
		"step": 0.05, "target": "shader"},
	{"name": "depth_edge_threshold", "label": "depthEdgeThreshold", "min": 0.005, "max": 0.5,
		"step": 0.005, "target": "shader"},
	{"name": "edge_dead_zone", "label": "edgeDeadZone", "min": 0.0, "max": 0.95, "step": 0.05,
		"target": "shader"},
	{"name": "normal_edge_threshold", "label": "normalEdgeThreshold", "min": 0.02, "max": 1.0,
		"step": 0.01, "target": "shader"},
	# Camera motion. Not part of the look pass, but "should the camera move at all" is a
	# question you answer by taking each motion away separately while walking around, and
	# there are three of them: it lags behind you (followSpeed), it leans toward the cursor
	# (aimLead), and it breathes with your speed (speedZoom, below). Zero the first two and
	# clear the third and the camera is welded to the player.
	# Runs to 100 rather than to the rig's own default of 8 because the interesting end of this
	# slider is the far one. The follow is exponential, so it approaches welded-to-the-player
	# without ever arriving: 8 catches up on about an eighth of the gap per frame, 100 on four
	# fifths, which is close enough to rigid to judge whether rigid is what you want.
	{"name": "follow_speed", "label": "followSpeed", "min": 1.0, "max": 100.0, "step": 1.0,
		"target": "rig"},
	{"name": "aim_lead", "label": "aimLead", "min": 0.0, "max": 1.0, "step": 0.01,
		"target": "rig"},
	# Grass (GDD section 8). Split across two owners on purpose: how far and how hard a blade
	# moves is a rendering number and lives on the shader, but WHICH SPEEDS produce a tell is
	# a balance number and lives on the patch node. Tuning the second is a design decision.
	{"name": "radius", "label": "grassRadius", "min": 0.2, "max": 3.0, "step": 0.05,
		"target": "grass_shader"},
	{"name": "interact_power", "label": "grassBend", "min": 0.0, "max": 0.8, "step": 0.01,
		"target": "grass_shader"},
	{"name": "tip_taper", "label": "tipTaper", "min": 0.0, "max": 1.0, "step": 0.05,
		"target": "grass_shader"},
	{"name": "wind_strength", "label": "windStrength", "min": 0.0, "max": 0.3, "step": 0.005,
		"target": "grass_shader"},
	{"name": "springback_seconds", "label": "springbackSecs", "min": 0.0, "max": 6.0,
		"step": 0.1, "target": "grass"},
	{"name": "trail_spacing", "label": "trailSpacing", "min": 0.05, "max": 1.5, "step": 0.05,
		"target": "grass"},
	{"name": "quiet_speed", "label": "quietSpeed", "min": 0.0, "max": 5.0, "step": 0.05,
		"target": "grass"},
	{"name": "loud_speed", "label": "loudSpeed", "min": 0.5, "max": 8.0, "step": 0.05,
		"target": "grass"},
	# The other half of the tell: how visible the mouse itself is while in cover.
	{"name": "hidden_opacity", "label": "hiddenOpacity", "min": 0.0, "max": 1.0, "step": 0.01,
		"target": "camo"},
	{"name": "moving_opacity", "label": "movingOpacity", "min": 0.0, "max": 1.0, "step": 0.01,
		"target": "camo"},
]

## Checkboxes, all of them camera-rig properties.
const TOGGLES: Array[Dictionary] = [
	{"name": "pixel_aligned_panning", "label": "pixelAlignedPanning"},
	{"name": "speed_zoom", "label": "speedZoom"},
]

## Wide enough for "normalEdgeThreshold", which is the longest label and therefore the one that
## sets the column width. A row is never narrower than its label, so guessing this too small
## doesn't clip the text -- it silently pushes the whole panel off the right of the screen.
const LABEL_WIDTH: float = 172.0
const SLIDER_WIDTH: float = 92.0
const READOUT_WIDTH: float = 48.0
const MARGIN: int = 12
const GAP: float = 8.0
const PANEL_WIDTH: float = LABEL_WIDTH + SLIDER_WIDTH + READOUT_WIDTH + GAP * 2.0 + MARGIN * 2

@export var camera_path: NodePath
@export var camera_rig_path: NodePath
@export var grass_path: NodePath
@export var camouflage_path: NodePath
## Whether the panel is up when the game starts. Off, because the first thing you want to see
## is the game, and F1 is one key.
@export var start_visible: bool = false

## The pixel pass is a CompositorEffect resource now, not a material -- so its tunables are
## plain properties and the "shader" target sets them like any other object's.
var _effect: CompositorEffect
var _rig: Node3D
var _grass: Node3D
var _grass_material: ShaderMaterial
var _camo: Node
var _readouts: Dictionary = {}


func _ready() -> void:
	# NOT IN A RELEASE BUILD. This is a dev tuning UI on F1, and F1 is a key people press. M6.5
	# ships to somebody who has never seen the game, and a stranger who lands in a panel of
	# twelve shader coefficients has been handed the impression that this is what the game is.
	# Freed rather than hidden: the sliders drive a CompositorEffect every frame they exist.
	if not OS.is_debug_build():
		queue_free()
		return

	var camera := get_node_or_null(camera_path) as Camera3D
	if camera != null and camera.compositor != null \
			and not camera.compositor.compositor_effects.is_empty():
		_effect = camera.compositor.compositor_effects[0]
	_rig = get_node_or_null(camera_rig_path) as Node3D
	_grass = get_node_or_null(grass_path) as Node3D
	_camo = get_node_or_null(camouflage_path)
	if _grass != null and _grass.has_method("get_material"):
		_grass_material = _grass.get_material()
	if _effect == null:
		push_warning("look panel: no pixel pass effect on %s -- sliders will do nothing" %
			camera_path)
		return

	_build()
	visible = start_visible


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("look_panel"):
		visible = not visible
		get_viewport().set_input_as_handled()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-PANEL_WIDTH - 16.0, 16.0)
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	add_child(panel)

	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)

	var title := Label.new()
	title.text = "Controls        F1"
	column.add_child(title)

	for control: Dictionary in CONTROLS:
		if _owner_of(control) != null:
			_add_slider(column, control)

	for toggle: Dictionary in TOGGLES:
		_add_toggle(column, toggle)

	var note := Label.new()
	note.text = "values are not saved"
	note.modulate = Color(1.0, 1.0, 1.0, 0.45)
	column.add_child(note)


func _add_slider(column: VBoxContainer, control: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(GAP))
	column.add_child(row)

	var label := Label.new()
	label.text = control["label"]
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = control["min"]
	slider.max_value = control["max"]
	slider.step = control["step"]
	slider.value = _initial(control)
	slider.custom_minimum_size = Vector2(SLIDER_WIDTH, 0.0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var readout := Label.new()
	readout.custom_minimum_size = Vector2(READOUT_WIDTH, 0.0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(readout)
	_readouts[control["name"]] = readout

	slider.value_changed.connect(_on_slider_changed.bind(control))
	_apply(control, slider.value)


## Whichever of the shader or the rig owns this value is the one that knows its real current
## setting. Reading it back rather than restating it here is what stops the panel opening with
## a slider that disagrees with what is actually on screen.
func _initial(control: Dictionary) -> float:
	var owner: Object = _owner_of(control)
	if owner == null:
		return 0.0
	var name: String = control["name"]
	if owner is ShaderMaterial:
		var material := owner as ShaderMaterial
		var value: Variant = material.get_shader_parameter(name)
		# A ShaderMaterial only reports uniforms somebody has explicitly SET. The pixel pass
		# has its values written into the scene file, so it answers; the grass material is
		# built in code and carries only the shader's own declared defaults, so it returns
		# null and the slider would open at zero -- flattening the grass the moment the panel
		# is built. The default has to be asked of the shader itself.
		if value == null:
			value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), name)
		return float(value) if value != null else 0.0
	return float(owner.get(name))


## Which object actually holds this value. Returns null when the scene has no such node, which
## is how the panel stays usable in a scene with no grass rather than erroring on startup.
func _owner_of(control: Dictionary) -> Object:
	match control["target"]:
		"rig", "both":
			return _rig
		"grass":
			return _grass
		"grass_shader":
			return _grass_material
		"camo":
			return _camo
		_:
			return _effect


func _add_toggle(column: VBoxContainer, toggle: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(GAP))
	column.add_child(row)

	var label := Label.new()
	label.text = toggle["label"]
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	row.add_child(label)

	var property: String = toggle["name"]
	var box := CheckBox.new()
	box.button_pressed = bool(_rig.get(property)) if _rig != null else false
	box.disabled = _rig == null
	box.toggled.connect(func(on: bool) -> void:
		if _rig != null:
			_rig.set(property, on))
	row.add_child(box)


func _on_slider_changed(value: float, control: Dictionary) -> void:
	_apply(control, value)


func _apply(control: Dictionary, value: float) -> void:
	var name: String = control["name"]
	var target: String = control["target"]

	if target == "shader" or target == "both":
		_effect.set(name, value)
	if target == "grass_shader" and _grass_material != null:
		_grass_material.set_shader_parameter(name, value)
	if (target == "rig" or target == "both") and _rig != null:
		_rig.set(name, value)
	if target == "grass" and _grass != null:
		_grass.set(name, value)
	if target == "camo" and _camo != null:
		_camo.set(name, value)

	var readout: Label = _readouts.get(name)
	if readout != null:
		# Whole numbers read as whole numbers. "6" is a pixel count; "6.00" invites you to
		# wonder what a fractional pixel would be.
		readout.text = ("%d" % value) if control["step"] >= 1.0 else ("%.3f" % value)
