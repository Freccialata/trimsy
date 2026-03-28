package trimsy

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c/libc"
import ts "trimsync"

// Build_Error classifies ffmpeg runner failures.
Build_Error :: enum {
	None,
	No_Chunks,
	Write_Filter_Script,
	FFmpeg_Execution,
}

// ffmpeg_process takes an EDL and produces an output video file by invoking
// the system ffmpeg CLI with a filter_complex that trims, speeds, and
// concatenates the segments.
ffmpeg_process :: proc(
	input_path: string,
	output_path: string,
	edl: ^ts.Edit_Decision_List,
) -> Build_Error {
	// Count segments that will appear in the output
	output_segments: int = 0
	for &chunk in edl.chunks {
		if chunk.speed == ts.SKIP_SPEED do continue
		output_segments += 1
	}

	if output_segments == 0 {
		fmt.eprintfln("[trimsy] warning: no segments to output (entire video is silent)")
		return .No_Chunks
	}

	// Build the filter_complex string
	// For each segment, we create:
	//   [0:v]trim=start:end,setpts=PTS-STARTPTS[,setpts=N*PTS][vN];
	//   [0:a]atrim=start:end,asetpts=PTS-STARTPTS[,atempo=X...][aN];
	// Then concat all segments.

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	seg_idx := 0
	for &chunk in edl.chunks {
		if chunk.speed == ts.SKIP_SPEED do continue

		start := chunk.start_time
		end := chunk.end_time
		speed := chunk.speed
		if speed <= 0 do speed = 1.0

		// Video filter chain for this segment
		fmt.sbprintf(&sb, "[0:v]trim=%.4f:%.4f,setpts=PTS-STARTPTS", start, end)
		if speed != 1.0 {
			// setpts=PTS/speed to speed up video
			pts_factor := 1.0 / f64(speed)
			fmt.sbprintf(&sb, ",setpts=%.6f*PTS", pts_factor)
		}
		fmt.sbprintf(&sb, "[v%d];\n", seg_idx)

		// Audio filter chain for this segment
		fmt.sbprintf(&sb, "[0:a]atrim=%.4f:%.4f,asetpts=PTS-STARTPTS", start, end)
		if speed != 1.0 {
			// Chain atempo filters (each limited to 0.5–2.0 range)
			append_atempo(&sb, f64(speed))
		}
		fmt.sbprintf(&sb, "[a%d];\n", seg_idx)

		seg_idx += 1
	}

	// Concat filter
	for i in 0..<seg_idx {
		fmt.sbprintf(&sb, "[v%d][a%d]", i, i)
	}
	fmt.sbprintf(&sb, "concat=n=%d:v=1:a=1[outv][outa]", seg_idx)

	filter_str := strings.to_string(sb)

	// For long filter strings, write to a temp file to avoid shell limits
	filter_script_path := "/tmp/trimsync_filter.txt"
	ok := os.write_entire_file(filter_script_path, transmute([]u8)filter_str)
	if !ok {
		fmt.eprintfln("[trimsy] error: could not write filter script to %s", filter_script_path)
		return .Write_Filter_Script
	}
	defer os.remove(filter_script_path)

	// Build ffmpeg command
	fmt.printfln("[trimsy] processing %d segments...", seg_idx)
	fmt.printfln("[trimsy] filter_complex has %d bytes", len(filter_str))

	// Some ffmpeg arguments
	args := make([dynamic]string, 0, 20)
	defer delete(args)

	append(&args, "ffmpeg")
	append(&args, "-y")                    // overwrite output
	append(&args, "-i")
	append(&args, input_path)
	append(&args, "-/filter_complex")
	append(&args, filter_script_path)
	append(&args, "-map")
	append(&args, "[outv]")
	append(&args, "-map")
	append(&args, "[outa]")
	append(&args, output_path)

	// Print the command for debugging
	cmd_sb := strings.builder_make()
	defer strings.builder_destroy(&cmd_sb)
	for i in 0..<len(args) {
		arg := args[i]
		if i > 0 do strings.write_byte(&cmd_sb, ' ')
		// Quote args with special chars
		if strings.contains(arg, " ") || strings.contains(arg, "[") || strings.contains(arg, "]") {
			fmt.sbprintf(&cmd_sb, "\"%s\"", arg)
		} else {
			strings.write_string(&cmd_sb, arg)
		}
	}
	fmt.printfln("[trimsy] running: %s", strings.to_string(cmd_sb))

	// Run ffmpeg as subprocess
	// Convert our dynamic array to a proper slice for os.process_exec
	args_cstrs := make([]cstring, len(args))
	defer delete(args_cstrs)
	for &arg, i in args {
		args_cstrs[i] = cstring(raw_data(arg))
	}

	// Use libc system() for simplicity
	full_cmd := strings.to_string(cmd_sb)
	full_cmd_c := strings.clone_to_cstring(full_cmd)
	defer delete(full_cmd_c)

	ret := libc.system(full_cmd_c)
	if ret != 0 {
		fmt.eprintfln("[trimsy] error: ffmpeg exited with code %d", ret)
		return .FFmpeg_Execution
	}

	fmt.printfln("[trimsy] ✓ output written to: %s", output_path)
	return .None
}

// append_atempo adds the appropriate chain of atempo filters to achieve
// a target speed. Each atempo instance is limited to 0.5–2.0 range,
// so we chain them for higher speeds.
//
// E.g. speed=8.0 → atempo=2.0,atempo=2.0,atempo=2.0
// E.g. speed=0.25 → atempo=0.5,atempo=0.5
@(private)
append_atempo :: proc(sb: ^strings.Builder, speed: f64) {
	remaining := speed

	if remaining > 1.0 {
		// Speed up: chain atempo=2.0 until remaining < 2.0
		for remaining > 2.0 {
			fmt.sbprintf(sb, ",atempo=2.0")
			remaining /= 2.0
		}
		if remaining > 1.001 {
			fmt.sbprintf(sb, ",atempo=%.4f", remaining)
		}
	} else if remaining < 1.0 {
		// Slow down: chain atempo=0.5 until remaining > 0.5
		for remaining < 0.5 {
			fmt.sbprintf(sb, ",atempo=0.5")
			remaining /= 0.5
		}
		if remaining < 0.999 {
			fmt.sbprintf(sb, ",atempo=%.4f", remaining)
		}
	}
}

// default output filename: insert "_trimmed" before extension
default_output_path :: proc(input_path: string) -> string {
	// Find last dot
	dot_idx := -1
	for i := len(input_path) - 1; i >= 0; i -= 1 {
		if input_path[i] == '.' {
			dot_idx = i
			break
		}
	}

	if dot_idx < 0 {
		return strings.concatenate({input_path, "_trimmed"})
	}

	base := input_path[:dot_idx]
	ext := input_path[dot_idx:]
	return strings.concatenate({base, "_trimmed", ext})
}
