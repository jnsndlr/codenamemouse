shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// Grass that bends away from the mice standing in it, by an amount that depends on how fast
// they are moving. GDD section 8's tell, and section 9's speed ladder is what drives it.
//
// Ported from Arnklit/TutorialResources/grass_interact, which is Godot 3 and single-actor.
// The port kept its core -- push blades radially away from an influence, scaled by
// (1.0 - UV.y) so the tip moves and the root doesn't -- and changed two things it had to:
//
//   EIGHT ACTORS, NOT ONE. The original takes `uniform vec3 player_pos`. This game is 4v4,
//   and grass that only reacts to you is worse than no grass at all: the entire mechanic is
//   reading where SOMEONE ELSE is. One uniform became an array and one distance test became
//   a loop, which is the whole change.
//
//   SPEED DRIVES THE BEND. The original bends by distance alone, so a mouse standing still
//   parts the grass exactly as hard as one sprinting through it. That erases the mechanic --
//   GDD section 8 is a four-rung ladder from "tears an unmistakable wake" to "bends nothing
//   at all", and the rung you are on is the information. Each influence carries its own bend
//   strength in .w, computed on the CPU from the speed of whatever left it.
//
//   INFLUENCES ARE NOT ACTORS. The original pushes from where the player IS. Grass that only
//   knows that springs back the instant a mouse leaves, and section 8 asks for a WAKE -- the
//   gap closing slowly behind someone is the tell, more than the gap itself is. So the CPU
//   drops a mark every `trail_spacing` metres travelled and decays it over `springback_
//   seconds`, and this array holds the live positions AND the fading marks behind them. The
//   shader is unchanged in shape by that -- it still just sums pushes -- which is exactly why
//   the trail was cheap to add.
//
// Bounded, and that is the honest limit of this approach: a long trail from eight mice at
// once will run out of slots and start forgetting its oldest marks. Accumulating influences
// into a fading TEXTURE instead has no such ceiling and is where this ends up if the mechanic
// survives evaluation. For one to four mice at these spacings it does not bind.
const int MAX_INFLUENCES = 48;

uniform vec4 albedo : source_color = vec4(0.36, 0.45, 0.22, 1.0);
// Blade tips, blended toward at the top. Real grass is lighter where the light gets through.
uniform vec4 tip_albedo : source_color = vec4(0.55, 0.63, 0.31, 1.0);

// xyz is a world position, w is how hard that actor bends grass, already folded down to
// 0-1 on the CPU. Packing them together keeps this to one uniform upload per frame.
uniform vec4 influences[MAX_INFLUENCES];
uniform int influence_count = 0;

// How far an actor's influence reaches, in metres. At mouse scale this wants to be close to
// the body -- a wide radius reads as a shockwave rather than as something pushing past.
uniform float radius = 0.7;
// How far the tip is displaced at full strength, in metres. Held well under a blade height:
// at 0.45 a sprinting mouse laid the grass out flat in a radial starburst, which reads as an
// explosion going off rather than as something running past.
uniform float interact_power = 0.18;

// How sharply the blade narrows toward its tip. 0 is the source tutorial's rectangle, 1 is a
// true point. Done in the shader rather than in the mesh so it stays one shared blade for all
// tens of thousands of instances -- baking the taper would mean a different mesh per taper value,
// which is the one thing that cannot be a live slider. At 0.7 the wider mesh keeps its base while the top
// finishes at thirty percent of that width.
uniform float tip_taper : hint_range(0.0, 1.0) = 0.7;

uniform float wind_strength = 0.035;
uniform float wind_speed = 1.4;

varying float tip_blend;


void vertex() {
	vec3 world_vert = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// UV.y is 0 at the tip and 1 at the root for a QuadMesh, so this is "how free is this
	// vertex to move". Squared, so the blade CURVES instead of shearing -- a straight lean
	// reads as a hinge, and grass doesn't have one.
	float freedom = 1.0 - UV.y;
	tip_blend = freedom;

	// Narrow the blade toward the tip. VERTEX.x is the across-blade axis of the source quad,
	// so scaling it pulls the two edges together without moving the spine.
	VERTEX.x *= mix(1.0, 1.0 - tip_taper, freedom);

	freedom *= freedom;

	vec3 push = vec3(0.0);
	float radius_squared = radius * radius;
	for (int i = 0; i < influence_count; i++) {
		vec3 away = world_vert - influences[i].xyz;
		away.y = 0.0;
		float dist_squared = dot(away, away);
		// Almost every blade is outside almost every actor's tiny influence radius. Reject on a
		// dot product first, so background grass does not pay for a square root and normalization
		// dozens of times per vertex just to feed zero into smoothstep.
		if (dist_squared >= radius_squared) {
			continue;
		}
		// Standing exactly on a blade gives no direction to push it in. Skip rather than
		// normalize a zero vector, which is a NaN and takes the whole blade off screen.
		if (dist_squared < 0.00000001) {
			continue;
		}
		float dist = sqrt(dist_squared);
		push += (away / dist) * smoothstep(radius, 0.0, dist) * influences[i].w;
	}

	// Two mice either side of one blade would otherwise bend it twice as far as one mouse
	// can, which looks like a bug and misreports how many people are there.
	float crowding = length(push);
	if (crowding > 1.0) {
		push /= crowding;
	}

	// Idle motion, so a still field doesn't read as plastic. Deliberately weak: this is the
	// noise floor the tell has to be legible ABOVE, and turning it up far enough to look
	// pretty is the same as turning the mechanic down.
	float phase = TIME * wind_speed + world_vert.x * 0.7 + world_vert.z * 0.55;
	push.x += sin(phase) * wind_strength;
	push.z += cos(phase * 0.7) * wind_strength;

	// World-space displacement back into the blade's own space. The original multiplies the
	// vector by the matrix from the left, a Godot 3 idiom for the inverse rotation; spelling
	// it as the basis transpose says what it means and drops the stray translation term that
	// the original's vec4(dir, 1.0) quietly picks up.
	vec3 local_push = push * mat3(MODEL_MATRIX);

	VERTEX += local_push * interact_power * freedom;
}


void fragment() {
	ALBEDO = mix(albedo.rgb, tip_albedo.rgb, tip_blend) * COLOR.rgb;
	ROUGHNESS = 0.9;
}
