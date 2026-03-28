package trimsync

import "core:fmt"

// Speed value that means "skip this segment entirely" (jump-cut mode).
SKIP_SPEED :: f32(-1)

// Config holds all user-configurable parameters for silence analysis.
Config :: struct {
	silent_threshold: f32,  // 0.0–1.0, volume ratio below which a frame is "silent". Default: 0.03
	sounded_speed:    f32,  // Playback speed for sounded segments. Default: 1.0
	silent_speed:     f32,  // Playback speed for silent segments. SKIP_SPEED = jump-cut. Default: 5.0
	frame_margin:     int,  // Frames of context to keep on either side of speech. Default: 1
	sample_rate:      int,  // Override sample rate (0 = auto-detect from file). Default: 0
	frame_rate:       f64,  // Override frame rate (0 = auto-detect from file). Default: 0
	audio_fade_size:  int,  // Samples for fade-in/fade-out at cut boundaries. Default: 400
}

// default_config returns a Config with sensible defaults matching jumpcutter.
default_config :: proc() -> Config {
	return Config{
		silent_threshold = 0.03,
		sounded_speed    = 1.00,
		silent_speed     = 5.00,
		frame_margin     = 1,
		sample_rate      = 0,
		frame_rate       = 0,
		audio_fade_size  = 400,
	}
}

// Chunk represents a contiguous region of the input video that is either
// entirely sounded or entirely silent.
Chunk :: struct {
	start_frame: int,
	end_frame:   int,
	start_time:  f64,   // in seconds
	end_time:    f64,   // in seconds
	is_sounded:  bool,
	speed:       f32,   // playback speed for this chunk
}

// Edit_Decision_List is the output of the analysis pass.
// It describes how to reassemble the video at different speeds.
Edit_Decision_List :: struct {
	chunks:      [dynamic]Chunk,
	frame_rate:  f64,
	sample_rate: int,
	duration:    f64,        // original video duration in seconds
	nb_channels: int,        // number of audio channels
}

// edl_destroy frees the memory held by an EDL.
edl_destroy :: proc(edl: ^Edit_Decision_List) {
	delete(edl.chunks)
}

// edl_print_summary prints a human-readable summary of the EDL.
edl_print_summary :: proc(edl: ^Edit_Decision_List) {
	sounded_time: f64 = 0
	silent_time:  f64 = 0
	output_time:  f64 = 0

	for &chunk in edl.chunks {
		dur := chunk.end_time - chunk.start_time
		if chunk.is_sounded {
			sounded_time += dur
		} else {
			silent_time += dur
		}
		if chunk.speed != SKIP_SPEED && chunk.speed > 0 {
			output_time += dur / f64(chunk.speed)
		}
		// chunks with SKIP_SPEED => removed entirely (0 output time)
	}

	fmt.printfln("=== TrimSync Edit Decision List ===")
	fmt.printfln("  Total start frames: %d", int(edl.duration * edl.frame_rate))
	fmt.printfln("  Original duration:  %.1fs", edl.duration)
	fmt.printfln("  Frame rate:         %.2f fps", edl.frame_rate)
	fmt.printfln("  Sample rate:        %d Hz", edl.sample_rate)
	fmt.printfln("  Channels:           %d", edl.nb_channels)
	fmt.printfln("  Chunks:             %d", len(edl.chunks))
	fmt.printfln("  Sounded time:       %.1fs", sounded_time)
	fmt.printfln("  Silent  time:       %.1fs", silent_time)
	fmt.printfln("  Estimated output:   %.1fs", output_time)
	if edl.duration > 0 {
		savings := (1.0 - output_time / edl.duration) * 100.0
		fmt.printfln("  Time saved:         %.1f%%", savings)
	}
}
