shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled;

// The BLOCK OF EARTH you are aiming at, and how far through digging it out you are.
//
// A cube, not a floor tile. What you remove when you dig is the whole cell -- floor to lid --
// and outlining only its base described the hole you would be left with rather than the thing
// you are about to take away. Wrapped around the volume, the highlight also tells you at a
// glance how tall the seam you are cutting is, which a flat square cannot say at all.
//
// EDGES MEASURED IN PIXELS. That is what the shader is for: the strips this replaced were a
// fixed 7cm of world, so at the camera's normal standoff they landed on barely a pixel and the
// highlight dissolved into the ground. fwidth gives metres-per-pixel, so the wireframe is the
// same crisp width whether you are zoomed in on one cell or looking down a whole corridor.
//
// TWO strips, not one: a bright line with a dark line just inside it. Additive-only highlights
// vanish on pale ground and dark-only ones vanish on earth; a light edge backed by a shadow
// edge survives both, which matters because this cursor has to read on a lawn and in an
// unlit tunnel.
//
// DEPTH TEST OFF, and this is the fix that made the cursor visible at all. A diggable cell is
// by definition UNDUG, so the earth lid over it has not been cut away and the cube is buried
// inside solid ground. The old cursor was not dimly visible, it was not visible in any frame.
// The highlight marks a volume inside the earth, so it has to be drawn through that earth, the
// way a targeting reticle is.
//
// The countdown FLOODS THE BLOCK FROM THE FLOOR UP, and the wireframe under the waterline goes
// white-hot with it. It used to sweep around the border of the base tile, which was fine for a
// square and is wrong for a cube: a perimeter has to pick a face to run on, and would read
// differently from every camera angle. Filling upward is the same on all four sides, needs no
// fixed "up" on the compass, and is what digging a block out actually looks like.

uniform vec4 edge_color : source_color = vec4(0.55, 0.95, 1.0, 0.95);
// What the flooded part of the wireframe turns as the dig fills it in.
uniform vec4 progress_color : source_color = vec4(1.0, 0.98, 0.86, 1.0);
// The dark backing strip. Not pure black -- a hard black rim reads as a hole in the floor.
uniform vec4 shadow_color : source_color = vec4(0.03, 0.02, 0.0, 0.6);
// The light filling the block, so a dig has some mass to it and not just a moving line.
uniform vec4 fill_color : source_color = vec4(1.0, 0.66, 0.22, 0.30);

// Half the cube, in metres. Set from the cell size and the plane's wall height.
uniform vec3 half_extent = vec3(0.5, 0.325, 0.5);
uniform float progress : hint_range(0.0, 1.0) = 0.0;
// On-screen thickness of the bright strip. This is the whole point of the shader.
uniform float edge_pixels : hint_range(0.5, 8.0) = 2.0;
uniform float shadow_pixels : hint_range(0.0, 8.0) = 1.5;
// Floor under the pixel width, in metres, so the wireframe does not thin away to nothing when
// the camera is close enough for one pixel to be a fraction of a millimetre.
uniform float min_edge : hint_range(0.0, 0.1) = 0.018;
// Slow breathing while merely hovering. A static line at this size is easy to look past; a
// moving one is not. Killed during a dig, where the flood is the thing that should be moving.
uniform float pulse : hint_range(0.0, 1.0) = 1.0;
// Lets the cursor go over 1.0 and pick up the bloom the scene's glow is already running.
uniform float intensity : hint_range(0.0, 4.0) = 1.4;

varying vec3 local_position;
varying vec3 local_normal;

// Straight "over" compositing. The layers have to stack in a fixed order -- fill, then shadow,
// then bright line on top -- or the backing strip eats the edge it is meant to back.
vec4 over(vec4 dst, vec4 src) {
	float a = src.a + dst.a * (1.0 - src.a);
	vec3 rgb = (src.rgb * src.a + dst.rgb * dst.a * (1.0 - src.a)) / max(a, 0.0001);
	return vec4(rgb, a);
}

void vertex() {
	local_position = VERTEX;
	local_normal = NORMAL;
}

void fragment() {
	// Which way this face points, as a mask over the three axes. On a box it is exactly one of
	// them, which is what lets the other two be treated as the face's own 2D plane.
	vec3 axis = abs(normalize(local_normal));

	// Distance to the nearest edge OF THIS FACE. The face's own normal axis is pushed out of
	// range so the min ignores it -- on that axis the fragment is always at the extent.
	vec3 to_border = half_extent - abs(local_position) + axis * 1000.0;
	float edge_distance = min(to_border.x, min(to_border.y, to_border.z));

	// Metres covered by one screen pixel, over the two axes this face actually spans. Taken
	// from the position rather than from edge_distance, which has creases along the face
	// diagonals that would fatten every corner of the wireframe.
	vec3 span = fwidth(local_position) * (1.0 - axis);
	float pixel = max(max(span.x, span.y), max(span.z, 0.00001));
	float bright = clamp(max(min_edge, edge_pixels * pixel), 0.0, 0.12);
	float backing = shadow_pixels * pixel;

	float line = 1.0 - smoothstep(bright - pixel, bright + pixel, edge_distance);
	float halo = (
		smoothstep(bright - pixel, bright + pixel, edge_distance)
		* (1.0 - smoothstep(bright + backing - pixel, bright + backing + pixel, edge_distance))
	);
	float inside = smoothstep(bright + backing, bright + backing + 0.02, edge_distance);

	// The waterline. Padded past both ends of the cube so that progress 0 floods nothing at all
	// and progress 1 floods the lid -- without the padding the bottom rim sits half-lit before
	// the dig has started, which reads as a dig already in progress.
	float band = max(pixel * 1.5, 0.004);
	float water = -half_extent.y - band + progress * (half_extent.y * 2.0 + band * 2.0);
	float flooded = 1.0 - smoothstep(water - band, water + band, local_position.y);
	// A lit surface on the rising light. Never appears on the lid or the floor, where y is
	// constant across the whole face -- correctly, since the flood passes those in one step.
	float surface = 1.0 - smoothstep(0.0, band * 3.0, abs(local_position.y - water));

	float breathe = 1.0 + pulse * 0.18 * sin(TIME * 3.4);
	vec4 edge = mix(edge_color, progress_color, flooded);

	vec4 colour = vec4(fill_color.rgb, fill_color.a * flooded * inside);
	colour = over(colour, vec4(progress_color.rgb, 0.5 * surface * inside));
	colour = over(colour, vec4(shadow_color.rgb, shadow_color.a * halo));
	colour = over(colour, vec4(edge.rgb, edge.a * line * breathe));

	ALBEDO = colour.rgb * intensity;
	ALPHA = clamp(colour.a, 0.0, 1.0);
}
