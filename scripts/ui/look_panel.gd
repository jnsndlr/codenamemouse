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

@export var pixel_pass_path: NodePath
@export var camera_rig_path: NodePath
## Whether the panel is up when the game starts. Off, because the first thing you want to see
## is the game, and F1 is one key.
@export var start_visible: bool = false

var _material: ShaderMaterial
var _rig: Node3D
var _readouts: Dictionary = {}


func _ready() -> void:
	var pass_node := get_node_or_null(pixel_pass_path) as MeshInstance3D
	_rig = get_node_or_null(camera_rig_path) as Node3D
	if pass_node != null:
		_material = pass_node.material_override as ShaderMaterial
	if _material == null:
		push_warning("look panel: no pixel pass material at %s -- sliders will do nothing" %
			pixel_pass_path)
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
		_add_slider(column, control)

	_add_toggle(column)

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
	slider.value = _material.get_shader_parameter(control["name"])
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


func _add_toggle(column: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(GAP))
	column.add_child(row)

	var label := Label.new()
	label.text = "pixelAlignedPanning"
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	row.add_child(label)

	var box := CheckBox.new()
	box.button_pressed = _rig.pixel_aligned_panning if _rig != null else false
	box.disabled = _rig == null
	box.toggled.connect(func(on: bool) -> void:
		if _rig != null:
			_rig.pixel_aligned_panning = on)
	row.add_child(box)


func _on_slider_changed(value: float, control: Dictionary) -> void:
	_apply(control, value)


func _apply(control: Dictionary, value: float) -> void:
	var name: String = control["name"]
	var target: String = control["target"]

	if target == "shader" or target == "both":
		_material.set_shader_parameter(name, value)
	if (target == "rig" or target == "both") and _rig != null:
		_rig.set(name, value)

	var readout: Label = _readouts.get(name)
	if readout != null:
		# Whole numbers read as whole numbers. "6" is a pixel count; "6.00" invites you to
		# wonder what a fractional pixel would be.
		readout.text = ("%d" % value) if control["step"] >= 1.0 else ("%.3f" % value)
