shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled, fog_disabled;

// The pixel-art pass: chunky pixels, and edges found from depth and normals.
//
// Ported from KodyJKing/hello-threejs (src/RenderPixelatedPass.ts), whose real insight is
// what it DOESN'T do. It draws no outlines. There is no black line anywhere in it. Instead
// it takes the lit image the renderer already produced and MULTIPLIES it -- darker where a
// silhouette steps away from you, brighter where a surface creases toward you. So the edges
// are made of the scene's own colour and stay in its own palette, which is why the result
// reads as hand-placed pixel art rather than as a cel-shading filter bolted on top.
//
// That mechanism is also why this is safe for the M2 trench work rather than in tension with
// it. Every trench wall meets its floor at a depth step and meets the lid at another; the
// M2 findings rest on exactly those big luminance shapes, not on thin detail (the emissive
// rim was retired long ago). This pass darkens every one of those steps. The trench outline
// gets STRONGER, not softer -- the filter and the level geometry want the same thing.
//
// TWO EDGE KINDS, and they are deliberately opposite in sign:
//
//   Depth edges    a real discontinuity -- the far side of a wall top, the lip of a shaft.
//                  DARKENED. This is a silhouette, and silhouettes read as shadow.
//   Normal edges   surface turning where depth is continuous -- the inside corner where a
//                  trench floor becomes a trench wall. BRIGHTENED. This is a catchlight,
//                  and it's what puts a bright seam along the bottom of every wall.
//
// Only counting a normal edge when the neighbour is FURTHER AWAY is what stops both sides of
// every crease lighting up. One side gets the highlight, the other stays plain, and the crease
// acquires a direction -- which is the difference between "this is a corner" and "something
// happened here".

// Width of one fat pixel, in real screen pixels. 4 against a 1280x720 window is a 320x180
// virtual screen. Quantising the SAMPLE rather than rendering the scene small keeps the HUD
// and the mouse cursor crisp, and costs nothing here because the edge tests below read the
// same quantised grid -- they compare block to block, so the edges land on block boundaries
// exactly as they would if the whole frame had been rasterised at 320x180.
uniform float pixel_size : hint_range(1.0, 12.0, 1.0) = 4.0;

// How hard a silhouette is darkened. The reference's 0.4.
uniform float depth_edge_strength : hint_range(0.0, 1.0) = 0.4;
// How hard a crease is brightened. The reference's 0.3.
uniform float normal_edge_strength : hint_range(0.0, 1.0) = 0.3;

// How far, IN METRES, a neighbour must fall behind the surface we're standing on before it
// counts as a silhouette.
//
// Note "behind the surface", not "further than this pixel" -- that distinction is the whole
// trick, and getting it wrong is the one bug this port actually had. The reference compares
// raw depth differences against magic constants (0.01, 0.0025). Our ground plane is enormous
// and viewed at 48 degrees, so its depth climbs steadily up the screen: at a 4-pixel block
// that is ~0.05m of honest gradient between neighbours, which any fixed threshold either
// reads as an edge EVERYWHERE or is too coarse to catch a real step. The first version of
// this shader painted the entire lawn as one giant silhouette.
//
// So each neighbour is compared against where it WOULD be if the centre pixel's surface
// simply continued -- a plane through the centre point with the centre normal. A flat floor
// predicts itself perfectly and scores zero at any angle, any zoom, any camera distance,
// which is what makes this threshold mean something physical rather than something tuned.
uniform float depth_edge_threshold : hint_range(0.005, 1.0, 0.005) = 0.1;

// Fraction of that threshold below which a step is ignored outright.
//
// The flatness prediction gets a flat floor almost right, not exactly right -- the normal it
// reads back is quantised to 8 bits per channel, and a slightly wrong normal is a slightly
// wrong prediction. Measured down a clear stretch of lawn that residual runs about 0.010m,
// with occasional rows reaching 0.038m, while a rock silhouette clears 0.06m and a trench
// wall is 0.65m. So there is most of a decade of daylight between the noise and the signal,
// and all this has to do is sit in it. Without the dead zone the lawn picks up a faint
// all-over darkening plus a few crisp horizontal bands at the unlucky rows.
//
// The reference does the same thing with smoothstep(0.01, 0.02, diff); this is that idea
// with the numbers moved into world units and measured rather than guessed.
uniform float edge_dead_zone : hint_range(0.0, 0.95, 0.05) = 0.5;
// How much of a turn counts as a crease, as the straight-line distance between the two unit
// normals -- so a turn of theta measures 2*sin(theta/2), and 0.25 is about 14 degrees. The
// 90-degree floor-to-wall junction that matters here measures 1.41 and saturates immediately;
// the threshold's real job is deciding how much of a rock's faceting also counts.
uniform float normal_edge_threshold : hint_range(0.02, 1.0, 0.01) = 0.25;

// 0 ships. 1 paints the two edge indicators into red and green, 2 shows the raw view normals.
// Both edge kinds are invisible by construction when they work -- they only ever nudge the
// brightness of a surface that was already there -- so "is this doing anything at all" is a
// question you cannot answer by looking at the finished frame. Worth keeping.
uniform int debug_view : hint_range(0, 2) = 0;

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D depth_buffer : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D normal_buffer : hint_normal_roughness_texture, filter_nearest, repeat_disable;

varying flat vec2 texel;

// A screen-filling triangle-ish quad written straight to clip space. Standard Godot
// full-screen trick: a 1x1 QuadMesh has corners at +/-0.5, so doubling reaches the whole
// NDC square regardless of where the node sits or what the camera is doing. With an
// orthographic camera whose SIZE changes every frame under the speed zoom, anything that
// tried to fit a quad to the frustum in world space would need rescaling per frame.
void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
	texel = 1.0 / VIEWPORT_SIZE;
}

// Where a screen pixel actually is, in metres, in view space.
//
// Godot 4 keeps depth in [0,1] rather than OpenGL's [-1,1], so only XY get remapped here.
// Reconstructing the full POSITION rather than just the distance is what lets the flatness
// prediction below work for any projection: the neighbour's real X and Y come back from the
// buffer, so nothing here assumes the view rays are parallel and the same code is correct
// under the orthographic camera we ship and a perspective one if that ever changes.
vec3 view_position(vec2 uv, mat4 inv_projection) {
	float raw = texture(depth_buffer, uv).r;
	vec4 view = inv_projection * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return view.xyz / view.w;
}

vec3 view_normal(vec2 uv) {
	return texture(normal_buffer, uv).rgb * 2.0 - 1.0;
}

void fragment() {
	// Snap to the centre of the fat pixel. Everything below reads from this grid, so the
	// colour and both edge tests all agree about where one block ends and the next begins.
	vec2 block = texel * pixel_size;
	vec2 uv = (floor(SCREEN_UV / block) + 0.5) * block;

	vec4 colour = texture(screen_texture, uv);

	// Sky, where nothing was drawn. Godot 4 uses a REVERSED depth buffer, so the far plane is
	// 0.0, not 1.0. Everything below is skipped there rather than returned out of, because
	// GDShader forbids `return` inside fragment() -- run the reconstruction on the clear
	// value instead and you get a band of nonsense along every horizon.
	bool is_geometry = texture(depth_buffer, uv).r > 0.0;

	float depth_edge = 0.0;
	float normal_edge = 0.0;

	if (is_geometry) {
		vec3 position = view_position(uv, INV_PROJECTION_MATRIX);
		vec3 normal = view_normal(uv);

		vec2 offsets[4] = {
			vec2(block.x, 0.0), vec2(-block.x, 0.0),
			vec2(0.0, block.y), vec2(0.0, -block.y)
		};

		// A surface seen nearly edge-on predicts its own continuation badly -- the plane is
		// racing away from the viewer, so a tiny sideways step implies an enormous depth
		// change, and the prediction runs to infinity as normal.z reaches zero. Floor it,
		// which turns a blown-up prediction into merely a generous one.
		float facing = max(abs(normal.z), 0.2);

		for (int i = 0; i < 4; i++) {
			vec2 neighbour_uv = uv + offsets[i];
			vec3 neighbour = view_position(neighbour_uv, INV_PROJECTION_MATRIX);

			// Where the neighbour would sit if this pixel's surface just kept going: the
			// plane through `position` with normal `normal`, at the neighbour's own XY.
			vec2 across = neighbour.xy - position.xy;
			float flat_z = position.z - dot(normal.xy, across) / facing;

			// Positive means the neighbour fell BEHIND that plane -- further away than the
			// surface we are on can account for, so we are looking over an edge at something
			// beyond it. Keeping only the positive side puts the darkening on the near lip,
			// so a wall shades its own top edge rather than smearing onto the floor behind
			// it. Use the absolute value and every edge doubles, one dark line either side.
			float behind = flat_z - neighbour.z;
			depth_edge = max(depth_edge, smoothstep(
				depth_edge_threshold * edge_dead_zone, depth_edge_threshold, behind));

			// A crease only counts where the surface is CONTINUOUS. Without that gate every
			// silhouette also reports a normal edge -- whatever lies beyond it faces
			// somewhere else entirely -- and the brightening fights the darkening along
			// every wall top. Requiring the neighbour to read very slightly behind also
			// picks WHICH face of the crease lights up, and picks the right one: at a
			// trench's floor-to-wall junction the wall sees the floor fall away behind it,
			// so the highlight runs along the foot of the wall and the floor stays plain.
			// Without it both faces brighten and one crisp line becomes a two-block band.
			if (behind > 0.0 && behind < depth_edge_threshold) {
				float turn = distance(normal, view_normal(neighbour_uv));
				normal_edge = max(normal_edge, clamp(turn / normal_edge_threshold, 0.0, 1.0));
			}
		}
	}

	// Depth wins where both fire. A silhouette is the stronger statement -- it says one
	// surface ends and another begins, where a crease only says one surface turned.
	float gain = depth_edge > 0.0
		? 1.0 - depth_edge_strength * depth_edge
		: 1.0 + normal_edge_strength * normal_edge;

	if (debug_view == 1) {
		ALBEDO = vec3(depth_edge, normal_edge, 0.0);
	} else if (debug_view == 2) {
		ALBEDO = texture(normal_buffer, uv).rgb;
	} else {
		ALBEDO = colour.rgb * gain;
	}
}
