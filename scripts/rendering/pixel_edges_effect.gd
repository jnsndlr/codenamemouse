@tool
class_name PixelEdgesEffect
extends CompositorEffect
## Runs the pixel pass after the transparent pass, so translucent things survive it.
##
## The pass began as a full-screen quad with a spatial shader (art/shaders/pixel_edges.gdshader)
## and that worked until something needed to FADE. A quad in the transparent queue reads its
## screen texture from a capture taken after the opaque pass, then repaints the whole frame from
## it -- so a translucent object is absent from that capture and gets erased rather than blended.
## The mouse's grass concealment (GDD section 8) hit this as "I am always invisible now", at
## every opacity including fully solid.
##
## Dithering dodges it by staying opaque, and looks like dithering. Recolouring dodges it by
## staying opaque, and cannot fade against anything but a known backdrop. Both are workarounds
## for the pass running too early. This is the pass running at the right time instead, and it
## makes ordinary alpha work everywhere -- for the mouse now, and for the Scout's camouflage
## when M5 arrives.
##
## The cost is that a CompositorEffect is compute rather than a fragment shader: explicit
## bindings, an intermediate image, and a manual dispatch. The maths in the .glsl is unchanged.

## Must match the compute shader's local_size_x/y.
const GROUP_SIZE: int = 8
## Push-constant block, in floats. Must match the Params struct exactly, padding included.
const PUSH_FLOATS: int = 28

@export_range(1.0, 20.0, 1.0) var pixel_size: float = 1.0
@export_range(0.0, 1.0, 0.05) var depth_edge_strength: float = 0.4
@export_range(0.0, 2.0, 0.05) var normal_edge_strength: float = 0.3
@export_range(0.005, 0.5, 0.005) var depth_edge_threshold: float = 0.1
@export_range(0.0, 0.95, 0.05) var edge_dead_zone: float = 0.5
@export_range(0.02, 1.0, 0.01) var normal_edge_threshold: float = 0.25
## 0 ships, 1 paints the two edge indicators into red and green, 2 shows the raw normals.
@export_range(0, 2) var debug_view: int = 0

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _sampler: RID
var _normals_missing_reported: bool = false


func _init() -> void:
	# After transparency is the whole point -- see the class comment.
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# The normal-roughness buffer is only allocated when something asks for it. The old quad
	# asked implicitly by declaring hint_normal_roughness_texture; removing it took the buffer
	# away with it, and the crease highlights went silently dead. This is the explicit ask.
	needs_normal_roughness = true
	RenderingServer.call_on_render_thread(_build)


## RIDs belong to the rendering device and have to be handed back on the render thread. Godot
## will not do it for us, and a leaked shader survives across editor runs.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	for rid: RID in [_shader, _sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)


func _build() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return

	var file := load("res://art/shaders/pixel_edges_compute.glsl") as RDShaderFile
	if file == null:
		push_error("pixel edges: compute shader failed to load")
		return
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("pixel edges: %s" % spirv.compile_error_compute)
		return

	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)

	# NEAREST, and not as a detail. The pass quantises to fat pixels by sampling one texel per
	# block; a linear sampler would average the neighbours back in and give soft blocks, which
	# is the one thing pixelation must not do.
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	if _rd == null or not _pipeline.is_valid():
		return

	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data()
	if buffers == null or scene == null:
		return

	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return

	# Somewhere to read that is not what we are writing. The frame is copied out to this
	# scratch first, then the dispatch reads the scratch and writes the real colour buffer.
	#
	# That direction, and not the other way round: the colour buffer is a storage image the
	# compute pass may write, but it is NOT a valid copy destination, so resolving into a
	# scratch and copying home fails outright. Copying out and writing home works, and is one
	# copy either way.
	if not buffers.has_texture(&"pixel_edges", &"scratch"):
		buffers.create_texture(&"pixel_edges", &"scratch",
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
			RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)

	var groups_x := int(ceil(float(size.x) / GROUP_SIZE))
	var groups_y := int(ceil(float(size.y) / GROUP_SIZE))

	var has_normals := buffers.has_texture(&"forward_clustered", &"normal_roughness")
	if not has_normals and not _normals_missing_reported:
		_normals_missing_reported = true
		push_warning("pixel edges: no normal_roughness buffer -- crease highlights are off")

	for view in range(buffers.get_view_count()):
		var colour := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		var scratch := buffers.get_texture_slice(&"pixel_edges", &"scratch", view, 0, 1, 1)
		# Bind SOMETHING valid in the normals slot even when there is no normal buffer -- a
		# compute set with a hole in it fails to create, and `has_normals` already tells the
		# shader to ignore whatever is bound there.
		var normals := depth
		if has_normals:
			normals = buffers.get_texture_slice(&"forward_clustered", &"normal_roughness",
				view, 0, 1, 1)

		var set := UniformSetCacheRD.get_cache(_shader, 0, [
			_sampled(colour, 0), _sampled(depth, 1), _sampled(normals, 2),
			_storage(colour, 3), _storage(scratch, 4)
		])

		# Two dispatches with a barrier between them: resolve into the scratch, then move the
		# scratch home. Ending and reopening the compute list is what supplies the barrier.
		for mode in [0.0, 1.0]:
			var list := _rd.compute_list_begin()
			_rd.compute_list_bind_compute_pipeline(list, _pipeline)
			_rd.compute_list_bind_uniform_set(list, set, 0)
			_rd.compute_list_set_push_constant(list,
				_push_constants(scene.get_view_projection(view), size, has_normals, mode),
				PUSH_FLOATS * 4)
			_rd.compute_list_dispatch(list, groups_x, groups_y, 1)
			_rd.compute_list_end()


func _push_constants(projection: Projection, size: Vector2i, has_normals: bool,
		mode: float) -> PackedByteArray:
	var inverse := projection.inverse()
	var values := PackedFloat32Array()
	for column: Vector4 in [inverse.x, inverse.y, inverse.z, inverse.w]:
		values.append_array([column.x, column.y, column.z, column.w])
	values.append_array([
		float(size.x), float(size.y),
		pixel_size, depth_edge_strength, normal_edge_strength,
		depth_edge_threshold, edge_dead_zone, normal_edge_threshold,
		1.0 if has_normals else 0.0, float(debug_view),
		mode, 0.0,
	])
	return values.to_byte_array()


func _sampled(texture: RID, binding: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(_sampler)
	uniform.add_id(texture)
	return uniform


func _storage(texture: RID, binding: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform
