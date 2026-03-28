package trimsy

import "core:fmt"
import "core:os"
import "core:strings"
import ts "trimsync"

TRIMSY_VERSION :: "0.1.0"

// ─── Presets ────────────────────────────────────────────────────────────────────

// A Preset bundles a name, description, and pre-configured settings.
Preset :: struct {
	name:        string,
	description: string,
	config:      ts.Config,
}

PRESETS := [?]Preset{
	{
		name        = "lecture",
		description = "Optimized for recorded lectures / talking heads.\n                         Low threshold, generous margin, sped-up silence.",
		config      = ts.Config{
			silent_threshold = 0.02,
			sounded_speed    = 1.0,
			silent_speed     = 6.0,
			frame_margin     = 2,
			audio_fade_size  = 400,
		},
	},
	{
		name        = "jumpcut",
		description = "Removes all silence completely (hard jump cuts).",
		config      = ts.Config{
			silent_threshold = 0.03,
			sounded_speed    = 1.0,
			silent_speed     = ts.SKIP_SPEED,
			frame_margin     = 1,
			audio_fade_size  = 400,
		},
	},
	{
		name        = "gentle",
		description = "Light touch — silence sped up 2×.\n                         Good for podcasts and interviews.",
		config      = ts.Config{
			silent_threshold = 0.025,
			sounded_speed    = 1.0,
			silent_speed     = 2.0,
			frame_margin     = 2,
			audio_fade_size  = 400,
		},
	},
	{
		name        = "aggressive",
		description = "Hard cuts + sounded segments at 1.5× speed.\n                         Maximum time savings.",
		config      = ts.Config{
			silent_threshold = 0.04,
			sounded_speed    = 1.5,
			silent_speed     = ts.SKIP_SPEED,
			frame_margin     = 1,
			audio_fade_size  = 400,
		},
	},
}

// ─── Help ───────────────────────────────────────────────────────────────────────

print_help :: proc() {
	fmt.printfln("trimsy v%s — TrimSync CLI video speed editor", TRIMSY_VERSION)
	fmt.println("")
	fmt.println("Usage:")
	fmt.println("  trimsy <input_file> [options]")
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  -o, --output <file>          Output file (default: input_trimmed.ext)")
	fmt.println("  -t, --threshold <0.03>       Silent threshold (0.0–1.0)")
	fmt.println("  -s, --sounded-speed <1.0>    Speed multiplier for sounded segments")
	fmt.println("  -ss, --silent-speed <5.0>    Speed multiplier for silent segments")
	fmt.println("  --skip, --jumpcut            Remove silent segments entirely (jump cut)")
	fmt.println("  -m, --margin <1>             Frames of safety margin around speech")
	fmt.println("  -p, --preset <name>          Use a preset (see below)")
	fmt.println("  --analyze                    Analyze only — show timing breakdown, no output")
	fmt.println("  --help, -h                   Show this help")
	fmt.println("")
	fmt.println("Presets:")
	for &p in PRESETS {
		fmt.printfln("  %-12s  %s", p.name, p.description)
	}
	fmt.println("")
	fmt.println("Examples:")
	fmt.println("  trimsy lecture.mp4                        # default settings")
	fmt.println("  trimsy lecture.mp4 --skip                 # remove all silence")
	fmt.println("  trimsy lecture.mp4 -p lecture              # lecture preset")
	fmt.println("  trimsy lecture.mp4 --analyze -t 0.05       # test threshold=0.05")
	fmt.println("  trimsy lecture.mp4 -ss 8 -s 1.5 -m 2      # custom speeds")
}

// ─── Analyze-only output ────────────────────────────────────────────────────────

// Print a rich analysis view that helps users understand the EDL and tune params.
print_analysis :: proc(edl: ^ts.Edit_Decision_List, config: ^ts.Config) {
	fmt.println("")
	fmt.println("╔══════════════════════════════════════════════════════════════╗")
	fmt.println("║                    TrimSync Analysis                        ║")
	fmt.println("╚══════════════════════════════════════════════════════════════╝")
	fmt.println("")

	// ── Summary stats ──
	sounded_time: f64 = 0
	silent_time:  f64 = 0
	output_time:  f64 = 0
	sounded_chunks := 0
	silent_chunks  := 0

	for &chunk in edl.chunks {
		dur := chunk.end_time - chunk.start_time
		if chunk.is_sounded {
			sounded_time += dur
			sounded_chunks += 1
		} else {
			silent_time += dur
			silent_chunks += 1
		}
		if chunk.speed != ts.SKIP_SPEED && chunk.speed > 0 {
			output_time += dur / f64(chunk.speed)
		}
	}

	fmt.printfln("  Input duration     %.1fs", edl.duration)
	fmt.printfln("  Frame rate         %.2f fps", edl.frame_rate)
	fmt.printfln("  Sample rate        %d Hz", edl.sample_rate)
	fmt.printfln("  Audio channels     %d", edl.nb_channels)
	fmt.println("")
	fmt.printfln("  Sounded segments   %d  (%.1fs)", sounded_chunks, sounded_time)
	fmt.printfln("  Silent segments    %d  (%.1fs)", silent_chunks, silent_time)
	if edl.duration > 0 {
		sil_pct := silent_time / edl.duration * 100.0
		fmt.printfln("  Silence ratio      %.1f%%", sil_pct)
	}
	fmt.println("")

	// ── What would happen ──
	skip_mode := config.silent_speed == ts.SKIP_SPEED
	if skip_mode {
		fmt.printfln("  Mode               jump-cut (silent segments removed)")
	} else {
		fmt.printfln("  Sounded speed      %.1fx", config.sounded_speed)
		fmt.printfln("  Silent speed       %.1fx", config.silent_speed)
	}
	fmt.printfln("  Threshold          %.3f", config.silent_threshold)
	fmt.printfln("  Frame margin       %d frames", config.frame_margin)
	fmt.println("")
	fmt.printfln("  Estimated output   %.1fs", output_time)
	if edl.duration > 0 {
		savings := (1.0 - output_time / edl.duration) * 100.0
		fmt.printfln("  Time saved         %.1f%%", savings)
	}
	fmt.println("")

	// ── Visual timeline ──
	TIMELINE_WIDTH :: 60
	fmt.println("  Timeline:")
	fmt.print("  │")
	for col in 0..<TIMELINE_WIDTH {
		t := f64(col) / f64(TIMELINE_WIDTH) * edl.duration
		// Find which chunk this falls in
		is_sounded := true
		for &chunk in edl.chunks {
			if t >= chunk.start_time && t < chunk.end_time {
				is_sounded = chunk.is_sounded
				break
			}
		}
		if is_sounded {
			fmt.print("█")
		} else {
			fmt.print("░")
		}
	}
	fmt.println("│")
	fmt.printfln("  0s%*s%.1fs", TIMELINE_WIDTH - 3, "", edl.duration)
	fmt.println("  █ = sounded   ░ = silent")
	fmt.println("")

	// ── Chunk table (first 30) ──
	max_show := min(len(edl.chunks), 30)
	fmt.println("  #    Type     Time                  Speed")
	fmt.println("  ─── ──────── ─────────────────────  ──────")
	for idx in 0..<max_show {
		c := edl.chunks[idx]
		kind := "SOUND" if c.is_sounded else "QUIET"
		if c.speed == ts.SKIP_SPEED {
			fmt.printfln("  %d\t %s    %.2fs – %.2fs\t   SKIP",
				idx, kind, c.start_time, c.end_time)
		} else {
			fmt.printfln("  %d\t %s    %.2fs – %.2fs\t   %.1fx",
				idx, kind, c.start_time, c.end_time, c.speed)
		}
	}
	if len(edl.chunks) > max_show {
		fmt.printfln("  ... and %d more segments", len(edl.chunks) - max_show)
	}
	fmt.println("")

	// ── Tuning hints ──
	fmt.println("  Tuning hints:")
	if silent_chunks > sounded_chunks * 3 {
		fmt.println("  ⚠ Lots of small silent gaps — try raising --threshold or --margin")
	}
	if sounded_chunks > 0 && sounded_time / f64(sounded_chunks) < 0.5 {
		fmt.println("  ⚠ Very short sounded segments — threshold may be too high")
	}
	if edl.duration > 0 && silent_time / edl.duration < 0.1 {
		fmt.println("  ✓ Little silence detected — video is already tight")
	}
	if edl.duration > 0 && silent_time / edl.duration > 0.5 {
		fmt.println("  💡 Over half the video is silence — try --skip for big savings")
	}
	fmt.println("  💡 Run with different -t values to compare (lower = more aggressive)")
	fmt.println("  💡 Remove --analyze to process the video when you're happy with settings")
	fmt.println("")
}

// ─── Main ───────────────────────────────────────────────────────────────────────

main :: proc() {
	args := os.args

	if len(args) < 2 {
		print_help()
		os.exit(1)
	}

	// Check for --help anywhere in args
	for i in 1..<len(args) {
		if args[i] == "--help" || args[i] == "-h" {
			print_help()
			return
		}
	}

	input_file := args[1]
	config := ts.default_config()
	output_file := ""
	analyze_only := false
	used_preset := false

	// Argument parsing
	i := 2
	for i < len(args) {
		switch args[i] {
		case "--threshold", "-t":
			if i + 1 < len(args) {
				val, ok := parse_f32(args[i + 1])
				if ok do config.silent_threshold = val
				i += 2
			} else {
				i += 1
			}
		case "--silent-speed", "-ss":
			if i + 1 < len(args) {
				val, ok := parse_f32(args[i + 1])
				if ok do config.silent_speed = val
				i += 2
			} else {
				i += 1
			}
		case "--sounded-speed", "-s":
			if i + 1 < len(args) {
				val, ok := parse_f32(args[i + 1])
				if ok do config.sounded_speed = val
				i += 2
			} else {
				i += 1
			}
		case "--margin", "-m":
			if i + 1 < len(args) {
				val, ok := parse_int(args[i + 1])
				if ok do config.frame_margin = val
				i += 2
			} else {
				i += 1
			}
		case "--output", "-o":
			if i + 1 < len(args) {
				output_file = args[i + 1]
				i += 2
			} else {
				i += 1
			}
		case "--skip", "--jumpcut":
			config.silent_speed = ts.SKIP_SPEED
			i += 1
		case "--preset", "-p":
			if i + 1 < len(args) {
				preset_name := args[i + 1]
				found := false
				for &p in PRESETS {
					if p.name == preset_name {
						config = p.config
						found = true
						used_preset = true
						fmt.printfln("[trimsy] using preset: %s", p.name)
						break
					}
				}
				if !found {
					fmt.eprintfln("error: unknown preset '%s'", preset_name)
					fmt.eprintln("available presets:")
					for &p in PRESETS {
						fmt.eprintfln("  %s", p.name)
					}
					os.exit(1)
				}
				i += 2
			} else {
				i += 1
			}
		case "--analyze", "--analyze-only":
			analyze_only = true
			i += 1
		case:
			fmt.eprintfln("warning: unknown argument '%s' (use --help for usage)", args[i])
			i += 1
		}
	}

	// Analyze
	edl, err := ts.analyze(input_file, config)
	if err != .None {
		fmt.eprintfln("error: analysis failed: %v", err)
		os.exit(1)
	}
	defer ts.edl_destroy(&edl)

	if analyze_only {
		print_analysis(&edl, &config)
		return
	}

	// Print summary
	ts.edl_print_summary(&edl)

	// Process video
	if output_file == "" {
		output_file = default_output_path(input_file)
	}

	process_err := ffmpeg_process(input_file, output_file, &edl)
	if process_err != .None {
		fmt.eprintfln("error: processing failed: %v", process_err)
		os.exit(1)
	}
}

// ─── Parsers ────────────────────────────────────────────────────────────────────

@(private)
parse_f32 :: proc(s: string) -> (f32, bool) {
	if len(s) == 0 do return 0, false

	negative := false
	start := 0
	if s[0] == '-' {
		negative = true
		start = 1
	}

	result: f64 = 0
	decimal_place: f64 = 0
	found_dot := false

	for idx in start..<len(s) {
		ch := s[idx]
		if ch == '.' {
			if found_dot do return 0, false
			found_dot = true
			decimal_place = 0.1
			continue
		}
		if ch < '0' || ch > '9' do return 0, false
		digit := f64(ch - '0')
		if found_dot {
			result += digit * decimal_place
			decimal_place *= 0.1
		} else {
			result = result * 10 + digit
		}
	}

	if negative do result = -result
	return f32(result), true
}

@(private)
parse_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 do return 0, false
	result := 0
	for ch in s {
		if ch < '0' || ch > '9' do return 0, false
		result = result * 10 + int(ch - '0')
	}
	return result, true
}
