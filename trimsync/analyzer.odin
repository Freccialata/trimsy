package trimsync

import "core:math"

// analyze_silence takes decoded mono audio and produces a per-frame
// silence map, then applies frame margin and groups into chunks.
//
// This is the core algorithm, matching jumpcutter's approach:
// 1. Compute max amplitude per "video frame" worth of audio
// 2. Compare to threshold → binary sounded/silent per frame
// 3. Spread "sounded" into nearby frames (frame_margin)
// 4. Group consecutive same-type frames into chunks
analyze_silence :: proc(
	audio: ^Decoded_Audio,
	config: ^Config,
) -> Edit_Decision_List {
	frame_rate := config.frame_rate if config.frame_rate > 0 else audio.frame_rate
	sample_rate := config.sample_rate if config.sample_rate > 0 else audio.sample_rate

	// How many audio samples per video frame
	samples_per_frame := f64(sample_rate) / frame_rate
	total_samples := len(audio.samples)
	num_frames := int(math.ceil(f64(total_samples) / samples_per_frame))

	if num_frames == 0 {
		return Edit_Decision_List{
			frame_rate  = frame_rate,
			sample_rate = sample_rate,
			duration    = audio.duration,
			nb_channels = audio.nb_channels,
		}
	}

	// Step 1: compute max amplitude per frame
	frame_max := make([]f32, num_frames)
	defer delete(frame_max)

	for f in 0..<num_frames {
		start_sample := int(f64(f) * samples_per_frame)
		end_sample := min(int(f64(f + 1) * samples_per_frame), total_samples)

		max_amp: f32 = 0
		for s in start_sample..<end_sample {
			amp := abs(audio.samples[s])
			if amp > max_amp do max_amp = amp
		}
		frame_max[f] = max_amp
	}

	// Step 2: binary classification (per original jumpcutter logic)
	is_sounded := make([]bool, num_frames)
	defer delete(is_sounded)

	for f in 0..<num_frames {
		is_sounded[f] = frame_max[f] > config.silent_threshold
	}

	// Step 3: apply frame margin — "spread" sounded frames
	// A silent frame that is within frame_margin frames of a
	// sounded frame becomes sounded. This preserves soft consonants.
	if config.frame_margin > 0 {
		spread := make([]bool, num_frames)
		defer delete(spread)

		// Copy initial classification
		for f in 0..<num_frames do spread[f] = is_sounded[f]

		// Spread sounded into neighbours
		for f in 0..<num_frames {
			if !is_sounded[f] do continue
			for m in 1..=config.frame_margin {
				if f - m >= 0 do spread[f - m] = true
				if f + m < num_frames do spread[f + m] = true
			}
		}

		for f in 0..<num_frames do is_sounded[f] = spread[f]
	}

	// Step 4: group into chunks
	edl := Edit_Decision_List{
		frame_rate  = frame_rate,
		sample_rate = sample_rate,
		duration    = audio.duration,
		nb_channels = audio.nb_channels,
	}

	chunk_start := 0
	chunk_type := is_sounded[0]

	for f in 1..<num_frames {
		if is_sounded[f] != chunk_type {
			// Emit chunk
			speed := config.sounded_speed if chunk_type else config.silent_speed
			append(&edl.chunks, Chunk{
				start_frame = chunk_start,
				end_frame   = f,
				start_time  = f64(chunk_start) / frame_rate,
				end_time    = f64(f) / frame_rate,
				is_sounded  = chunk_type,
				speed       = speed,
			})
			chunk_start = f
			chunk_type = is_sounded[f]
		}
	}

	// Final chunk
	speed := config.sounded_speed if chunk_type else config.silent_speed
	append(&edl.chunks, Chunk{
		start_frame = chunk_start,
		end_frame   = num_frames,
		start_time  = f64(chunk_start) / frame_rate,
		end_time    = f64(num_frames) / frame_rate,
		is_sounded  = chunk_type,
		speed       = speed,
	})

	return edl
}
