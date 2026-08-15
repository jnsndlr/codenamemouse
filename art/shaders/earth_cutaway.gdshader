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

// LINEAR, NOT NEAREST, and that one word is most of what makes an angled tunnel read as angled
// from above. The field these sample is a signed distance (see TunnelContour), so interpolating
// between texels interpolates the DISTANCE and the 0.5 crossing lands on the true surface --
// the same trick the contour uses to put a wall on a straight line instead of a staircase. With
// nearest sampling the hole in the lid would step in 12.5cm blocks around a corridor whose walls
// are smooth, which is worse than the old whole-cell steps: it reads as a rendering fault rather
// than as a grid.
uniform sampler2D dug_here : filter_linear, repeat_disable;
uniform sampler2D dug_above : filter_linear, repeat_disable;
uniform bool cut_above = true;
// Whether to cut at all. The ground has to CLOSE UP when the player is standing on it: left
// cutting, the whole tunnel network was legible as a black trench snaking across the lawn from
// a surface view, which hands away the hidden-information pillar the entire game is built on
// (GDD section 3 -- entrances are meant to be visually subtle). You only see into a layer once
// you are in it.
uniform bool cutting = true;
// Half-extent of the dug field in METRES, and how many texels it stores per metre. Together
// they give the field's pixel size; kept as two numbers because the network exports the extent
// and TunnelContour owns the resolution, and a single baked-in size would silently go wrong the
// day either moves.
uniform float field_half_metres = 64.0;
uniform float field_texels_per_metre = 8.0;

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

// Matches TunnelNetwork's field addressing exactly: texel i holds the distance sampled at world
// (i - half) / texels_per_metre. If these two ever disagree the holes land off the tunnels they
// belong to -- which used to be half a cell and would now be a smaller, subtler, harder-to-spot
// fraction of a metre, so it is worth stating the mapping in one line in both places.
//
// The half-texel is what makes LINEAR filtering land correctly: a texel's stored value belongs at
// its CENTRE, and sampling without the offset shifts the whole cutaway half a texel north-west.
bool sample_mask(sampler2D mask, vec2 xz) {
	float size = field_half_metres * field_texels_per_metre * 2.0;
	vec2 texel = xz * field_texels_per_metre + vec2(field_half_metres * field_texels_per_metre);
	return texture(mask, (texel + vec2(0.5)) / size).r > 0.5;
}

void fragment() {
	vec2 xz = world_position.xz;
	if (cutting && (sample_mask(dug_here, xz) || (cut_above && sample_mask(dug_above, xz)))) {
		discard;
	}
	ALBEDO = albedo_color * dim * texture(dirt, xz / dirt_tile).rgb;
	ROUGHNESS = surface_roughness;
}
