// Reading the dug field, for every surface that has to have tunnels punched out of it.
//
// SHARED BECAUSE GETTING IT WRONG IS INVISIBLE UNTIL IT IS BAFFLING. The addressing here has to
// match TunnelNetwork's field exactly; a copy that drifts by a texel does not fail, it puts every
// hole slightly off the tunnel it belongs to, and the symptom -- earth hanging over a corridor on
// one side and a sliver of nothing on the other -- looks like a geometry bug rather than like an
// arithmetic one. There were two copies of this in the project when a second surface needed it.
// One is the right number.

// Half-extent of the dug field in METRES, and how many texels it stores per metre. Together they
// give the field's pixel size; kept as two numbers because the network exports the extent and
// TunnelContour owns the resolution, and a single baked-in size would silently go wrong the day
// either moves.
uniform float field_half_metres = 64.0;
uniform float field_texels_per_metre = 8.0;

// Texel i holds the distance sampled at world (i - half) / texels_per_metre.
//
// The half-texel is what makes LINEAR filtering land correctly: a texel's stored value belongs at
// its CENTRE, and sampling without the offset shifts the whole cutaway half a texel north-west.
//
// The caller supplies the sampler, which must be declared `filter_linear` -- the field is a signed
// distance (see TunnelContour), so interpolating between texels interpolates the DISTANCE and the
// 0.5 crossing lands on the true surface. With nearest sampling a hole steps in 12.5cm blocks
// around a corridor whose walls are smooth, which reads as a rendering fault rather than as a grid.
bool sample_dug(sampler2D mask, vec2 xz) {
	float size = field_half_metres * field_texels_per_metre * 2.0;
	vec2 texel = xz * field_texels_per_metre + vec2(field_half_metres * field_texels_per_metre);
	return texture(mask, (texel + vec2(0.5)) / size).r > 0.5;
}
