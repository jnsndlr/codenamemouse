#[compute]
#version 450

// The pixel pass, as a compute shader run by a CompositorEffect after the transparent pass.
//
// SAME MATHS as art/shaders/pixel_edges.gdshader, which this replaces -- quantise to fat
// pixels, darken depth steps, brighten creases. What changed is only WHEN it runs, and that
// was worth a rewrite for one reason: the quad version sampled a screen texture captured
// after the OPAQUE pass, so anything translucent was missing from the image it resampled and
// got painted out of existence. Concealment (GDD section 8) is the whole grass mechanic and
// it wants real transparency, so the pass had to move to where transparency has already
// happened. Running here, it sees the final frame and fades work normally.
//
// Reads one image and writes another rather than editing in place. Every thread samples its
// BLOCK's centre and that block's four neighbours, so threads share texels constantly -- in
// place, a thread would read texels a neighbouring thread had already overwritten, and the
// result would depend on scheduling order.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D colour_tex;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2D normal_tex;
layout(rgba16f, set = 0, binding = 3) uniform restrict image2D colour_image;
layout(rgba16f, set = 0, binding = 4) uniform restrict image2D scratch_image;

layout(push_constant, std430) uniform Params {
	mat4 inv_projection;
	vec2 raster_size;
	float pixel_size;
	float depth_edge_strength;
	float normal_edge_strength;
	float depth_edge_threshold;
	float edge_dead_zone;
	float normal_edge_threshold;
	// Whether the renderer actually handed us a normal-roughness buffer. It is a Forward+
	// texture and the lookup is by name, so treating its absence as "no crease highlights"
	// rather than as a crash keeps the pass working on a renderer that lacks it.
	float has_normals;
	float debug_view;
	// 0 resolves the frame into the scratch, 1 moves the scratch back into the frame. Two
	// dispatches rather than one because a thread reads its block's NEIGHBOURS, so writing
	// into the buffer being read would make the result depend on scheduling order -- and
	// Godot's colour buffer turns out to be neither a valid copy source nor destination, so
	// the round trip has to happen in compute rather than as a texture copy.
	float mode;
	float pad0;
} params;


vec3 view_position(vec2 uv) {
	float raw = texture(depth_tex, uv).r;
	vec4 view = params.inv_projection * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return view.xyz / view.w;
}


vec3 view_normal(vec2 uv) {
	return texture(normal_tex, uv).xyz * 2.0 - 1.0;
}


void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	if (coord.x >= size.x || coord.y >= size.y) {
		return;
	}

	if (params.mode > 0.5) {
		imageStore(colour_image, coord, imageLoad(scratch_image, coord));
		return;
	}

	vec2 uv = (vec2(coord) + 0.5) / params.raster_size;
	vec2 block = vec2(params.pixel_size) / params.raster_size;
	// Snap to the centre of the fat pixel. Colour and both edge tests read this same grid, so
	// they all agree about where one block ends and the next begins.
	vec2 quv = (floor(uv / block) + 0.5) * block;

	vec4 colour = texture(colour_tex, quv);

	// Sky, where nothing was drawn. Godot uses a REVERSED depth buffer, so the far plane is
	// 0.0, not 1.0. Running the reconstruction on the clear value paints a band of nonsense
	// along every horizon.
	bool is_geometry = texture(depth_tex, quv).r > 0.0;

	float depth_edge = 0.0;
	float normal_edge = 0.0;

	if (is_geometry) {
		vec3 position = view_position(quv);
		vec3 normal = view_normal(quv);

		vec2 offsets[4] = {
			vec2(block.x, 0.0), vec2(-block.x, 0.0),
			vec2(0.0, block.y), vec2(0.0, -block.y)
		};

		// A surface seen nearly edge-on predicts its own continuation badly -- the plane races
		// away from the viewer, so a tiny sideways step implies an enormous depth change and
		// the prediction runs to infinity as normal.z reaches zero. Floor it.
		float facing = max(abs(normal.z), 0.2);

		for (int i = 0; i < 4; i++) {
			vec2 neighbour_uv = quv + offsets[i];
			vec3 neighbour = view_position(neighbour_uv);

			// Where the neighbour would sit if this pixel's surface just kept going. A flat
			// floor predicts itself perfectly and scores zero at any angle or zoom, which is
			// what stops the whole lawn reading as one giant silhouette.
			vec2 across = neighbour.xy - position.xy;
			float flat_z = position.z - dot(normal.xy, across) / facing;
			float behind = flat_z - neighbour.z;

			depth_edge = max(depth_edge, smoothstep(
				params.depth_edge_threshold * params.edge_dead_zone,
				params.depth_edge_threshold, behind));

			// Creases only count where the surface is CONTINUOUS, and only on the side whose
			// neighbour reads very slightly behind it -- that picks which face of a corner
			// lights up, and picks the right one.
			if (params.has_normals > 0.5 && behind > 0.0
					&& behind < params.depth_edge_threshold) {
				float turn = distance(normal, view_normal(neighbour_uv));
				normal_edge = max(normal_edge,
					clamp(turn / params.normal_edge_threshold, 0.0, 1.0));
			}
		}
	}

	// Depth wins where both fire. A silhouette says one surface ends and another begins; a
	// crease only says one surface turned.
	float gain = depth_edge > 0.0
		? 1.0 - params.depth_edge_strength * depth_edge
		: 1.0 + params.normal_edge_strength * normal_edge;

	vec3 result = colour.rgb * gain;
	if (params.debug_view > 1.5) {
		result = texture(normal_tex, quv).xyz;
	} else if (params.debug_view > 0.5) {
		result = vec3(depth_edge, normal_edge, 0.0);
	}

	imageStore(scratch_image, coord, vec4(result, colour.a));
}
