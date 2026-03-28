package trimsy

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c/libc"
import ts "trimsync"

// Number of parallel workers is determined dynamically: system cores - 1 (min 1).

// Build_Error classifies ffmpeg runner failures.
Build_Error :: enum {
	None,
	No_Chunks,
	Write_Filter_Script,
	FFmpeg_Execution,
}

// ── Signal handling ──────────────────────────────────────────────────────────
// Package-level state so the SIGINT handler can clean up temp files.

@(private)
g_temp_dir: cstring = nil   // set while processing, nil otherwise

@(private)
sigint_handler :: proc "c" (sig: i32) {
	libc.printf("\n[trimsy] interrupted — cleaning up temp files...\n")
	if g_temp_dir != nil {
		libc.system(g_temp_dir)
	}
	libc.exit(1)
}

// unregister_sigint restores default Ctrl+C behaviour and frees the global.
@(private)
unregister_sigint :: proc() {
	libc.signal(libc.SIGINT, transmute(proc "cdecl" (i32))libc.SIG_DFL)
	if g_temp_dir != nil {
		delete(g_temp_dir)
		g_temp_dir = nil
	}
}

// ffmpeg_process takes an EDL and produces an output video using a
// parallel segment-based pipeline:
//
//   1. Each non-skip chunk → one small ffmpeg call → one .ts segment
//   2. Up to `parallel_workers` segments are processed concurrently
//   3. All segments are joined instantly via the concat demuxer (-c copy)
//
// This replaces the old single-pass filter_complex approach which
// scaled O(N²) with segment count and became unusable for long videos.
ffmpeg_process :: proc(
	input_path: string,
	output_path: string,
	edl: ^ts.Edit_Decision_List,
) -> Build_Error {
	temp_dir := "trimsy_temp"
	mkdir_cmd := strings.clone_to_cstring(fmt.tprintf("mkdir -p \"%s\"", temp_dir))
	libc.system(mkdir_cmd)
	delete(mkdir_cmd)

	// Register Ctrl+C handler so temp files are cleaned on interrupt
	cleanup_cmd := strings.clone_to_cstring(fmt.tprintf("rm -rf \"%s\"", temp_dir))
	g_temp_dir = cleanup_cmd
	libc.signal(libc.SIGINT, sigint_handler)

	// ── Build per-segment ffmpeg commands ────────────────────────────────
	commands := make([dynamic]string, 0, len(edl.chunks))
	defer {
		for cmd in commands do delete(cmd)
		delete(commands)
	}

	seg_idx := 0
	for &chunk in edl.chunks {
		if chunk.speed == ts.SKIP_SPEED do continue
		speed := chunk.speed
		if speed <= 0 do speed = 1.0

		duration := chunk.end_time - chunk.start_time
		if duration <= 0.001 do continue

		// If the resulting output duration is less than a single video frame,
		// ffmpeg will likely drop it entirely and produce an empty/invalid .ts file.
		if duration / f64(speed) < (1.0 / edl.frame_rate) {
			continue
		}

		seg_file := fmt.tprintf("%s/seg_%05d.ts", temp_dir, seg_idx)

		sb := strings.builder_make()

		// Input seeking (-ss before -i) is fast and precise when re-encoding
		// Placing -t BEFORE -i limits the *input* duration, preventing sped-up 
		// segments from bleeding into the next chunks.
		fmt.sbprintf(&sb,
			"ffmpeg -y -nostdin -loglevel error -ss %.6f -t %.6f -i \"%s\"",
			chunk.start_time, duration, input_path,
		)

		// Speed filters (only when speed != 1.0)
		if speed < 0.999 || speed > 1.001 {
			pts_factor := 1.0 / f64(speed)
			// Ensure we maintain the target frame rate after scaling PTS
			fmt.sbprintf(&sb, " -vf \"setpts=%.6f*PTS,fps=%.2f\"", pts_factor, edl.frame_rate)

			atempo := build_atempo_string(f64(speed))
			fmt.sbprintf(&sb, " -af \"%s\"", atempo)
			delete(atempo)
		} else {
			// Even for 1.0x, enforce CFR so segments concatenate flawlessly
			fmt.sbprintf(&sb, " -vf \"fps=%.2f\"", edl.frame_rate)
		}

		// Encoding: ultrafast preset for speed, CRF 18 for quality
		fmt.sbprintf(&sb,
			" -c:v libx264 -preset ultrafast -crf 18 -r %.2f -c:a aac -b:a 192k -f mpegts \"%s\"",
			edl.frame_rate, seg_file,
		)

		append(&commands, strings.clone(strings.to_string(sb)))
		strings.builder_destroy(&sb)
		seg_idx += 1
	}

	total := len(commands)
	if total == 0 {
		fmt.eprintfln("[trimsy] warning: no segments to output (entire video is silent)")
		unregister_sigint()
		cleanup_temp(temp_dir)
		return .No_Chunks
	}

	// ── Calculate parallel workers ───────────────────────────────────────
	parallel_workers := os.processor_core_count() - 1
	if parallel_workers < 1 do parallel_workers = 1

	// ── Process segments in parallel batches ─────────────────────────────
	fmt.printfln("[trimsy] processing %d segments (%d parallel workers)...", total, parallel_workers)

	i := 0
	batch_num := 0
	for i < total {
		batch_end := min(i + parallel_workers, total)
		batch_num += 1

		fmt.printfln("[trimsy]   batch %d: segments %d–%d / %d",
			batch_num, i + 1, batch_end, total,
		)

		// Join commands with " & ", append " & wait" to run in parallel
		batch_sb := strings.builder_make()
		first := true
		for j in i..<batch_end {
			if !first do strings.write_string(&batch_sb, " & ")
			strings.write_string(&batch_sb, commands[j])
			first = false
		}
		strings.write_string(&batch_sb, " & wait")

		batch_cmd := strings.clone_to_cstring(strings.to_string(batch_sb))
		libc.system(batch_cmd)
		delete(batch_cmd)
		strings.builder_destroy(&batch_sb)

		i = batch_end
	}

	// ── Verify and Concatenate ───────────────────────────────────────────
	fmt.printfln("[trimsy] creating concat list...")

	list_sb := strings.builder_make()
	defer strings.builder_destroy(&list_sb)
	
	valid_segments := 0
	for s in 0..<total {
		path := fmt.tprintf("%s/seg_%05d.ts", temp_dir, s)
		
		fd, err := os.open(path)
		if err == os.ERROR_NONE {
			size, _ := os.file_size(fd)
			os.close(fd)
			if size > 100 {
				fmt.sbprintf(&list_sb, "file 'seg_%05d.ts'\n", s)
				valid_segments += 1
			} else {
				fmt.eprintfln("[trimsy] warning: segment %d is empty, skipping", s)
			}
		} else {
			fmt.eprintfln("[trimsy] warning: segment %d missing, skipping", s)
		}
	}

	if valid_segments == 0 {
		fmt.eprintfln("[trimsy] error: all segments failed to generate")
		unregister_sigint()
		cleanup_temp(temp_dir)
		return .FFmpeg_Execution
	}

	concat_list := fmt.tprintf("%s/concat.txt", temp_dir)
	ok := os.write_entire_file(concat_list, transmute([]u8)strings.to_string(list_sb))
	if !ok {
		fmt.eprintfln("[trimsy] error: could not write concat list")
		unregister_sigint()
		cleanup_temp(temp_dir)
		return .FFmpeg_Execution
	}

	concat_cmd := strings.clone_to_cstring(fmt.tprintf(
		"ffmpeg -y -nostdin -loglevel error -f concat -safe 0 -i \"%s\" -c copy \"%s\"",
		concat_list, output_path,
	))
	defer delete(concat_cmd)

	ret := libc.system(concat_cmd)
	if ret != 0 {
		fmt.eprintfln("[trimsy] error: concat failed with code %d", ret)
		unregister_sigint()
		cleanup_temp(temp_dir)
		return .FFmpeg_Execution
	}

	// ── Done ─────────────────────────────────────────────────────────────
	unregister_sigint()
	cleanup_temp(temp_dir)
	fmt.printfln("[trimsy] ✓ output written to: %s", output_path)
	return .None
}

// build_atempo_string returns a standalone atempo filter chain.
// Each atempo instance is clamped to [0.5, 2.0], so we chain them.
//
//   speed=6.0  → "atempo=2.0,atempo=2.0,atempo=1.5"
//   speed=0.25 → "atempo=0.5,atempo=0.5"
@(private)
build_atempo_string :: proc(speed: f64) -> string {
	sb := strings.builder_make()
	remaining := speed
	first := true

	if remaining > 1.0 {
		for remaining > 2.0 {
			if !first do strings.write_byte(&sb, ',')
			fmt.sbprintf(&sb, "atempo=2.0")
			remaining /= 2.0
			first = false
		}
		if remaining > 1.001 {
			if !first do strings.write_byte(&sb, ',')
			fmt.sbprintf(&sb, "atempo=%.4f", remaining)
		}
	} else if remaining < 1.0 {
		for remaining < 0.5 {
			if !first do strings.write_byte(&sb, ',')
			fmt.sbprintf(&sb, "atempo=0.5")
			remaining /= 0.5
			first = false
		}
		if remaining < 0.999 {
			if !first do strings.write_byte(&sb, ',')
			fmt.sbprintf(&sb, "atempo=%.4f", remaining)
		}
	}

	result := strings.clone(strings.to_string(sb))
	strings.builder_destroy(&sb)
	return result
}

// default output filename: insert "_trimmed" before extension
default_output_path :: proc(input_path: string) -> string {
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

// cleanup_temp removes the temporary segment directory.
@(private)
cleanup_temp :: proc(dir: string) {
	cmd := strings.clone_to_cstring(fmt.tprintf("rm -rf \"%s\"", dir))
	defer delete(cmd)
	libc.system(cmd)
}
