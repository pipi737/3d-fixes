Texture2D<float> stereo2mono_downscaled_zbuffer : register(t110);

Texture2D<float4> StereoParams : register(t125);
Texture1D<float4> IniParams : register(t120);

#include "auto_convergence_state.hlsl"

RWStructuredBuffer<struct auto_convergence_state> state : register(u1);

// Copied from lighting shaders with 3DMigoto, definition from
// CGIncludes/UnityShaderVariables.cginc:
cbuffer UnityPerCamera : register(b13)
{
	// Time (t = time since current level load) values from Unity
	uniform float4 _Time; // (t/20, t, t*2, t*3)
	uniform float4 _SinTime; // sin(t/8), sin(t/4), sin(t/2), sin(t)
	uniform float4 _CosTime; // cos(t/8), cos(t/4), cos(t/2), cos(t)
	uniform float4 unity_DeltaTime; // dt, 1/dt, smoothdt, 1/smoothdt

	uniform float3 _WorldSpaceCameraPos;

	// x = 1 or -1 (-1 if projection is flipped)
	// y = near plane
	// z = far plane
	// w = 1/far plane
	uniform float4 _ProjectionParams;

	// x = width
	// y = height
	// z = 1 + 1.0/width
	// w = 1 + 1.0/height
	uniform float4 _ScreenParams;

	// Values used to linearize the Z buffer (http://www.humus.name/temp/Linearize%20depth.txt)
	// x = 1-far/near
	// y = far/near
	// z = x/far
	// w = y/far
	uniform float4 _ZBufferParams;

	// x = orthographic camera's width
	// y = orthographic camera's height
	// z = unused
	// w = 1.0 if camera is ortho, 0.0 if perspective
	uniform float4 unity_OrthoParams;
}

float z_to_w(float z)
{
	// This is game specific - adjust as needed.
	// For Unity we use _ZBufferParams:
	return 1 / (_ZBufferParams.z * z + _ZBufferParams.w);
}

// A version of isnan() that cannot be optimised out. Use if the compiler
// throws a warning about isnan.
bool workaround_broken_isnan(float x)
{
       return (((asuint(x) & 0x7f800000) == 0x7f800000) && ((asuint(x) & 0x007fffff) != 0));
}

void main(out float auto_convergence : SV_Target0)
{
	float target_convergence, convergence_difference;
	float current_convergence;
	float target_popout_bias;
	float z, zr, zl, w;

	// Since there is some lag between setting the auto-convergence and it
	// taking effect, the convergence from this frame may not be the
	// convergence we previously set (which may still be in flight to the
	// CPU). This can lead to the slow convergence transitions appearing to
	// stutter, since although we are using the same convergence in the
	// calculation as last time, the depth buffer (and in particular, the
	// small subset of points we sample from it) is different and we may
	// come up with a different result (even sometimes going backwards).
	// To counter this and eliminate the stutter, if we tried to set a
	// convergence in the last frame we will use it as a starting point for
	// the calculations in this frame instead of the current convergence.
	//
	// FIXME: This worked pretty well in DOAXVV, but falls short for me in
	// LiSBtS. We need to be a bit more intelligent here based on whether
	// the auto_convergence had sucesfully been staged or is still pending.
	//
	//current_convergence = state[0].last_set_convergence;
	//if (workaround_broken_isnan(current_convergence))
		current_convergence = StereoParams.Load(0).y;
	//else
		//state[0].last_set_convergence = 1.#QNAN;

	if (state[0].prev_auto_convergence_enabled != auto_convergence_enabled) {
		state[0].last_convergence.xyzw = 0;
		state[0].last_adjust_time = time;
		state[0].show_hud = true;
	}
	state[0].prev_auto_convergence_enabled = auto_convergence_enabled;

	if (!auto_convergence_enabled) {
		auto_convergence = 1.#SNAN;
		return;
	}

	float4 stereo = StereoParams.Load(0);
	float separation = stereo.x, convergence = stereo.y, eye = stereo.z, raw_sep = stereo.w;
	bool user_updated_convergence = separation && prev_stereo_active && convergence != prev_convergence;

	zr = stereo2mono_downscaled_zbuffer.Load(int3(0, 0, 0));
	zl = stereo2mono_downscaled_zbuffer.Load(int3(1, 0, 0));

	// stereo2mono will only work in SLI if StereoFlagsDX10=0x00000008 or
	// the profile supports CM, so we might not have data from the left
	// eye here and check that it is valid before using it - that way at
	// least we will have some auto-convergence, but objects that only
	// obscure the camera in the left eye won't trigger auto-convergence:
	z = (zl ? max(zl, zr) : zr);

	w = z_to_w(z);

	if (isinf(w)) {
		// No depth buffer, auto-convergence cannot work. Bail now,
		// otherwise we would set the hard maximum convergence limit
		auto_convergence = 1.#QNAN;
		// Display a notice in the HUD if the user tries to change the
		// convergence:
		if (user_updated_convergence || warn_no_z_buffer)
			state[0].last_adjust_time = time;
		state[0].no_z_buffer = true;
		return;
	}
	state[0].no_z_buffer = false;

	// A lot of the maths below is experimental to try to find a good
	// auto-convergence algorithm that works well with a wide variety of
	// screen sizes, seating distances, and varying scenes in the game.

	// Apply the max convergence now, before we apply the popout bias, on
	// the theory that the max suitable convergence is going to vary based
	// on screen size
	target_convergence = min(w, max_convergence_soft);

	if (user_updated_convergence) {
		// User adjusted the convergence. Convert this to an equivalent
		// popout bias for auto-convergence that we save in a buffer on
		// the GPU. This is the below formula re-arranged:
		target_popout_bias = (separation*(convergence - target_convergence)/(raw_sep*w));
		target_popout_bias = min(max(target_popout_bias, -1), 1) - ini_popout_bias;
		state[0].user_popout_bias = target_popout_bias;
		state[0].last_adjust_time = time;
		state[0].show_hud = true;
	}

	// Apply the popout bias. This experimental formula is derived by
	// taking the nvidia formula with the perspective divide and the
	// original x=0:
	//
	//   x' = x + separation * (depth - convergence) / depth
	//   x' = separation * (depth - convergence) / depth
	//
	// That gives us our original stereo corrected X value using a
	// convergence that would place the closest object at screen depth
	// (barring the result of capping the convergence). We want to find a
	// new convergence value that would instead position the object
	// slightly popped out - to do so in a way that is comfortable
	// regardless of scene, screen size, and player distance from the
	// screen we apply the popout bias to the x', call it x''. Because we
	// are modifying this post-separation, we will need to multiply by the
	// raw separation value so that it scales with separation (otherwise we
	// would always end with the full pop-out regardless of separation -
	// which is actually kind of cool - people who like toyification might
	// appreciate it, but we do want turning the stereo effect down to
	// reduce the stereo effect):
	//
	//   x'' = x' - (popout_bias * raw_separation)
	//
	// Then we rearrange the nvidia formula and substitute in the two
	// previous formulas to find the new convergence:
	//
	//   x'' = separation * (depth - convergence') / depth
	//   convergence' = depth * (1 - (x'' / separation))
	//   convergence' = depth * (((popout_bias * raw_separation) - x') / separation + 1)
	//   convergence' = depth * popout * raw_separation / separation + convergence
	//
	float new_convergence = w * (ini_popout_bias + state[0].user_popout_bias) * raw_sep / separation + target_convergence;

	// Apply the minimum convergence now to ensure we can't go negative
	// regardless of what the popout bias did, and a hard maximum
	// convergence to prevent us going near infinity:
	new_convergence = min(max(new_convergence, min_convergence), max_convergence_hard);

	// The *2 here is to compensate for the lag in setting the
	// convergence due to the asynchronous transfer.
	float diff = slow_convergence_rate * (time - prev_time) * 2;

	convergence_difference = new_convergence - current_convergence;
	if (abs(convergence_difference) >= instant_convergence_threshold) {

		// The anti-judder countermeasure aims to detect situations
		// where the auto-convergence makes an adjustment that moves
		// something on or off screen, that in turn triggers another
		// auto-convergence correction causing an oscillation between
		// two or more convergence values. In this situation we want to
		// stop trying to set the convergence back to a value it
		// recently was, but we also have to choose which state we stop
		// in. To try to avoid the camera being obscured, we try to
		// stop in the lower convergence state
		if (any(abs(new_convergence - state[0].last_convergence.xyzw) < anti_judder_threshold)) {
			if (new_convergence < current_convergence) {
				auto_convergence = new_convergence;
				//state[0].last_set_convergence = auto_convergence; FIXME
				state[0].last_convergence.xyzw = float4(current_convergence, state[0].last_convergence.xyz);
				return;
			}
			auto_convergence = 1.#SNAN;
			return;
		}

		auto_convergence = new_convergence;
	} else if (-convergence_difference > slow_convergence_threshold_near) {
		auto_convergence = max(new_convergence, current_convergence - diff);
	} else if (convergence_difference > slow_convergence_threshold_far) {
		auto_convergence = min(new_convergence, current_convergence + diff);
	} else {
		auto_convergence = 1.#QNAN;
	}

	state[0].last_convergence.xyzw = float4(current_convergence, state[0].last_convergence.xyz);
	//state[0].last_set_convergence = auto_convergence; FIXME
}
