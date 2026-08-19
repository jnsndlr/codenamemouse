shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// The top of a seam your crew has found, laid over the ground as a sheet of knowledge.
//
// UNSHADED, which is the whole trick and predates this file: the sheet sits above a lid lit by
// nothing much, so a shaded one came back almost black and the vein you had paid a dig to learn
// about was invisible. Double-sided for the same era's reason -- a generated quad must not be able
// to silently choose the wrong visible side.
//
// CUT BY THE TUNNEL, WHICH IS WHY IT IS A SHADER AT ALL. The sheet is built from whole cells,
// because rock IS per cell; the tunnel stopped being per cell when digging went off-grid. A stroke
// whose rounded end reaches into a rock cell without making any of it walkable is legal, common,
// and leaves the cell's square hanging over open corridor -- a grey slab with a stair-stepped edge
// sitting on top of a smooth curved trench, which is exactly as wrong as it sounds. Discarding
// against the same field the lid discards against costs one texture read and puts the sheet's edge
// on the tunnel wall, wherever that wall actually is.

#include "res://art/shaders/dug_field.gdshaderinc"

uniform sampler2D dug_here : filter_linear, repeat_disable;
uniform vec3 albedo_color : source_color = vec3(0.60, 0.64, 0.70);
// The same grain every other earth surface uses, in WORLD space, so the sheet speckles in step
// with the ground it is lying on rather than reading as a flat decal. Greyscale, so it multiplies
// the tint rather than replacing it; left unset the shader draws flat colour, which is what the
// headless probes get.
uniform sampler2D dirt : filter_nearest, repeat_enable, hint_default_white;
uniform float dirt_tile = 4.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 xz = world_position.xz;
	// The same rim the lid takes back, so the sheet's edge stays on the ground's edge rather than
	// overhanging the bevel the ground has just leaned away from.
	if (sample_dug(dug_here, xz, dug_grow)) {
		discard;
	}
	ALBEDO = albedo_color * texture(dirt, xz / dirt_tile).rgb;
}
