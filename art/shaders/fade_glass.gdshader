shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_never, specular_disabled;

// A FADED SNEAK (GDD section 4): the octopus trick, done as glass rather than as transparency.
//
// WHY NOT SIMPLY ALPHA. The mouse already has a working fade -- grass_camouflage.gd drives
// `albedo_color.a` down to a tenth in deep cover -- and running that to zero for the ability
// would have been one line. It would also have been the wrong ability. A mouse at zero alpha is
// GONE: there is no observation to make, no flicker to catch, and the counterplay is "hope".
// GDD section 8's whole argument for concealment never reaching zero is that hidden information
// is about not being FOUND, and a thing that cannot be found by looking is not hidden, it is
// absent.
//
// So this draws nothing of its own and everything of what is behind it, displaced. The Sneak is
// a lens: the lawn, the fence and the dirt keep being drawn where the mouse is, bent by the shape
// of a mouse. Standing still against flat ground it is very nearly perfect, which is correct --
// there is nothing for the distortion to bite on. MOVING ACROSS A BOUNDARY IS WHAT GIVES IT AWAY,
// because a straight edge dragged through the lens visibly kinks. That is the tell, it costs the
// player nothing to learn, and it rewards exactly the thing the concealment model already rewards:
// looking at the ground rather than at the mice.
//
// THE PIXEL PASS CANNOT SEE THIS, and that is deliberate rather than lucky. `depth_draw_never`
// keeps the body out of the depth buffer, so pixel_edges_effect.gd -- which finds silhouettes in
// depth and normals -- has nothing to draw an outline around. A faded mouse wearing the same crisp
// black rim as every other object in the game would have been a shape with a hole in it, which is
// more visible than the mouse was to start with.
//
// AND IT IS NOT A CLASS SECRET AT THE SHADER LEVEL. Every machine draws this, for every faded
// mouse, friend or enemy. The information rules live in spotting.gd and grass_camouflage.gd, where
// the rest of them are; what happens here is only how it looks. A shader that decided who may see
// it would be a second, quieter copy of the visibility rules, and the two would drift.

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

// How far the lens bends what is behind it, in screen widths at the reference distance. Small:
// the eye finds distortion far more easily than it finds a faint shape, so this is the dial that
// decides whether the ability works, and turning it up is turning the Sneak off.
uniform float refraction : hint_range(0.0, 0.2) = 0.055;
// The slow crawl over the surface, so a STATIONARY faded Sneak is not a perfectly static pane.
// A still lens over still ground is genuinely invisible, and this ability is meant to be beatable
// by a patient defender. Slow enough that it reads as heat off the lawn rather than as an effect.
uniform float shimmer : hint_range(0.0, 4.0) = 1.1;
uniform float shimmer_speed : hint_range(0.0, 4.0) = 0.9;
// The rim: a thin fresnel edge where the body turns away from the camera. This is the OTHER half
// of being findable, and it is the half that works when the mouse is standing on flat colour and
// there is nothing for the refraction to bend.
// TUNED DOWN FROM 0.16 AND SHARPENED FROM 3.2 BY LOOKING AT IT, which is what `tools/fade_shot.gd`
// is for, and then down again for a reason no amount of reading this file would have found.
//
// THE FIRST MISTAKE WAS THE CAMERA ANGLE. This game is watched from almost overhead, so a large
// share of a rounded body is at a grazing angle and a generous fresnel painted most of the mouse
// pale blue rather than drawing an edge around it. The screenshot was a translucent blue ghost --
// legible at a glance, which is the ability not working at all.
//
// THE SECOND WAS THAT THE MODEL IS NOT ONE MESH. Body, ears, nose and tail are separate
// `MeshInstance3D`s and they overlap on screen; with the veil not quite opaque -- the grass's own
// concealment keeps `ALPHA` a shade under 1 -- every tint below is laid down once per layer where
// they cross. Whatever number looks right on a single surface is two or three times that over the
// middle of the mouse, which is exactly where a searcher is looking. So both dials are set well
// below what one flat face would want.
uniform vec4 rim_color : source_color = vec4(0.78, 0.90, 0.96, 1.0);
uniform float rim_strength : hint_range(0.0, 1.0) = 0.045;
uniform float rim_sharpness : hint_range(1.0, 8.0) = 6.0;
// HOW FAR THROUGH THE TRANSITION THE VEIL IS: 0 is an ordinary solid mouse, 1 is pure lens. This
// is the whole of the arriving and leaving, and it is one uniform rather than a second material
// crossfaded against the first because there is only ever one mesh to hang a material on. At 0
// this shader draws exactly what the standard material would, which is the property that lets the
// swap happen off screen and a frame early without anybody seeing a flicker.
uniform float veil : hint_range(0.0, 1.0) = 1.0;
// The team colour, which is what the mouse is when `veil` is 0 and a barely-there tint when it is
// 1. The tint is NOT for the enemy's benefit -- at `body_bleed` it is a few percent -- but so that
// the player driving the mouse can tell which end of the lens is the front, and so a crew mate can
// keep track of an ally that just vanished from beside them.
uniform vec4 body_color : source_color = vec4(0.4, 0.55, 0.9, 1.0);
uniform float body_bleed : hint_range(0.0, 1.0) = 0.012;

void fragment() {
	// The offset is the surface normal IN VIEW SPACE, which is what makes the distortion follow the
	// curve of the body from every camera angle. A world-space normal would bend one way when you
	// rotated the yard and another way when you did not, and this camera does quarter turns.
	vec2 bend = NORMAL.xy;

	// A little travelling noise on top, built out of sines rather than a texture: one more image to
	// keep in art/ for something that wants to be barely perceptible is the wrong trade, and the
	// beat between two incommensurate frequencies is irregular enough at this amplitude.
	float wave = sin(VERTEX.y * 18.0 + TIME * shimmer_speed * 3.0)
		+ sin(VERTEX.x * 13.0 - TIME * shimmer_speed * 2.3);
	bend += vec2(wave, -wave) * shimmer * 0.004;

	// Clamped to the screen, so a mouse at the edge of the viewport samples its own frame rather
	// than smearing the border pixel down the side of the picture.
	vec2 at = clamp(SCREEN_UV + bend * refraction * veil, vec2(0.001), vec2(0.999));
	vec3 behind = texture(screen_texture, at).rgb;

	// Fresnel: near 1 where the surface faces away from the eye, which on a rounded body is its
	// outline. Powered up so it is a rim and not a general haze over the whole silhouette -- a haze
	// is a shape, and a shape is the thing being avoided.
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_sharpness);

	vec3 lens = mix(behind, body_color.rgb, body_bleed);
	lens = mix(lens, rim_color.rgb, rim * rim_strength);

	// The crossfade, in colour rather than in alpha. At `veil` 0 this is the plain team colour and
	// the mouse looks like every other mouse; at 1 it is the lens.
	ALBEDO = mix(body_color.rgb, lens, veil);

	// OPAQUE ONCE THE VEIL IS UP, and that is not a contradiction of the word "fade". The lens has
	// to REPLACE the pixels it covers: what makes it invisible is that the colour it writes is the
	// colour that was already there. Blending it would mix the mouse's own shape into the frame at
	// whatever strength the alpha allowed, which is a translucent mouse -- the exact thing this
	// ability was built specifically not to be.
	//
	// AND THE GRASS'S ALPHA IS DELIBERATELY LET GO OF AT FULL VEIL, which is the one line in this
	// file that was wrong in the first build and only a screenshot could have said so. `body_color`
	// carries the concealment `grass_camouflage.gd` writes for every mouse (GDD section 8), and
	// handing it straight to `ALPHA` meant a faded Sneak -- which that same model drops to a tenth
	// -- drew its lens at a tenth. The picture was not a mouse-shaped hole in the world, it was a
	// pale blue ghost: ninety percent background plus ten percent of a distorted, tinted mouse,
	// which is more visible than the ordinary translucent mouse it replaced.
	//
	// The two concealments have to COMPOSE, not multiply. Below the veil the grass alpha is the
	// whole story, because that is an ordinary mouse; at full veil it has nothing left to say,
	// because there is no more hidden to be -- which is the same thing `_wanted_opacity` says in
	// GDScript when it returns the concealed figure for a faded mouse and stops looking at cover.
	ALPHA = mix(body_color.a, 1.0, veil);
}
