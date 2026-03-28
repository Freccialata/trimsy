package trimsync

import "core:fmt"

// analyze is the public entry point for the TrimSync library.
// It decodes audio from the input file and analyzes it for silence.
//
// Usage:
//   config := trimsync.default_config()
//   config.silent_threshold = 0.04
//   edl, err := trimsync.analyze("lecture.mp4", config)
//   defer trimsync.edl_destroy(&edl)
//
analyze :: proc(input_path: string, config: Config) -> (Edit_Decision_List, Decoder_Error) {
	fmt.printfln("[trimsync] analyzing: %s", input_path)
	fmt.printf("[trimsync] config: threshold=%.3f sounded_speed=%.1fx silent_speed=",
		config.silent_threshold, config.sounded_speed)
	if config.silent_speed == SKIP_SPEED {
		fmt.printf("skip")
	} else {
		fmt.printf("%.1fx", config.silent_speed)
	}
	fmt.printfln(" margin=%d", config.frame_margin)

	// Decode audio to mono float32
	audio, decode_err := decode_audio(input_path, config.sample_rate)
	if decode_err != .None {
		return {}, decode_err
	}
	defer decoded_audio_destroy(&audio)

	// Run silence analysis
	cfg := config  // copy to stack so we can take address
	edl := analyze_silence(&audio, &cfg)

	return edl, .None
}
