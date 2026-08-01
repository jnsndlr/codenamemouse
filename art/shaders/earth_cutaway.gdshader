shader_type spatial;
render_mode depth_draw_opaque, cull_back, diffuse_burley;

// The lid over a tunnel layer: solid earth with that layer's tunnels punched out of it.
//
// This is what replaces ghosting the surface to near-invisible. You are not looking THROUGH
// the ground at a tunnel below it, you are looking DOWN INTO an open trench cut in it, which
// is how a tunnel actually looks from above and why the reference art reads instantly.
//
// Cut in the shader rather than in geometry, and rather than in CSG. Per-cell CSG subtraction
// on an 80x80 slab is hundreds of operations; a regenerated mesh is a rebuild on every dig.
// Here digging sets ONE TEXEL and the cutaway is already correct -- nothing to schedule, and
// crucially the collision mesh never changes, so the ground stays solid underfoot. Burrowing
// is an interaction, not a hole you can fall down.
//
// TWO masks, not one. `dug_here` is the layer you are looking down into: discard there and the
// tunnel is revealed. `dug_above` is the layer whose floor sits at exactly this height -- its
// own floor tiles get drawn in that space, so the lid has to move aside or the two z-fight
// along the whole length of every corridor.

uniform sampler2D dug_here : filter_nearest, repeat_disable;
uniform sampler2D dug_above : filter_nearest, repeat_disable;
uniform bool cut_above = true;
// Whether to cut at all. The ground has to CLOSE UP when the player is standing on it: left
// cutting, the whole tunnel network was legible as a black trench snaking across the lawn from
// a surface view, which hands away the hidden-information pillar the entire game is built on
// (GDD section 3 -- entrances are meant to be visually subtle). You only see into a layer once
// you are in it.
uniform bool cutting = true;
uniform float cell_size = 1.0;
uniform float mask_half_cells = 64.0;

uniform vec3 albedo_color : source_color = vec3(0.26, 0.19, 0.14);
// The same grain every other earth surface uses (scripts/rendering/dirt_texture.gd), mapped in
// WORLD space so the lawn, the trench floor and the wall between them share one continuous
// speckle rather than three that stop at each other's edges. Greyscale, so it multiplies the
// tint above rather than replacing it. Left unset the shader draws flat colour, which is what
// the audits get and what this looked like before.
uniform sampler2D dirt : filter_nearest, repeat_enable, hint_default_white;
uniform float dirt_tile = 4.0;
uniform float surface_roughness : hint_range(0.0, 1.0) = 1.0;
// Layers out of focus are pushed back with LIGHT, never with alpha. Alpha put the ground in
// the transparent pass with depth-write off, which is what made the wall rims flicker as the
// camera moved and let the 80x80 slab paint straight over all 760 rocks.
uniform float dim : hint_range(0.0, 1.0) = 1.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Matches TunnelNetwork.world_to_cell exactly: cell (x,z) owns world [x-0.5, x+0.5]. If these
// two ever disagree the holes land half a cell off the tunnels they belong to.
bool sample_mask(sampler2D mask, vec2 xz) {
	vec2 cell = floor(xz / cell_size + 0.5);
	vec2 uv = (cell + vec2(mask_half_cells)) / (mask_half_cells * 2.0);
	return texture(mask, uv).r > 0.5;
}

void fragment() {
	vec2 xz = world_position.xz;
	if (cutting && (sample_mask(dug_here, xz) || (cut_above && sample_mask(dug_above, xz)))) {
		discard;
	}
	ALBEDO = albedo_color * dim * texture(dirt, xz / dirt_tile).rgb;
	ROUGHNESS = surface_roughness;
}
