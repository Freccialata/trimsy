package trimsync

import "core:c"
import "core:fmt"
import "core:math"
import ff "ffmpeg"

// Decoded_Audio holds the raw audio samples decoded from a video file.
// All channels are mixed down to mono for silence analysis.
Decoded_Audio :: struct {
	samples:     [dynamic]f32, // mono float32 samples in [-1, 1]
	sample_rate: int,
	nb_channels: int,
	frame_rate:  f64,
	duration:    f64,          // total duration in seconds
}

decoded_audio_destroy :: proc(da: ^Decoded_Audio) {
	delete(da.samples)
}

// Decoder_Error classifies decoder failures.
Decoder_Error :: enum {
	None,
	Open_Input,
	Find_Stream_Info,
	No_Audio_Stream,
	No_Decoder,
	Open_Codec,
	Decode,
}

// decode_audio opens a media file and decodes the entire audio stream
// into mono float32 samples for analysis.
decode_audio :: proc(path: string, target_sample_rate: int = 0) -> (result: Decoded_Audio, err: Decoder_Error) {
	// Open input file
	fmt_ctx: ^ff.AVFormatContext = nil
	path_c := cstring(raw_data(path))

	if ff.avformat_open_input(&fmt_ctx, path_c, nil, nil) < 0 {
		fmt.eprintfln("[trimsync] error: could not open input file: %s", path)
		err = .Open_Input
		return
	}
	defer ff.avformat_close_input(&fmt_ctx)

	// Find stream info
	if ff.avformat_find_stream_info(fmt_ctx, nil) < 0 {
		fmt.eprintfln("[trimsync] error: could not find stream info")
		err = .Find_Stream_Info
		return
	}

	// Find best audio stream
	decoder: ^ff.AVCodec = nil
	audio_stream_idx := ff.av_find_best_stream(
		fmt_ctx,
		.AUDIO,
		-1, -1,
		&decoder,
		0,
	)
	if audio_stream_idx < 0 {
		fmt.eprintfln("[trimsync] error: no audio stream found")
		err = .No_Audio_Stream
		return
	}

	if decoder == nil {
		fmt.eprintfln("[trimsync] error: no decoder found for audio stream")
		err = .No_Decoder
		return
	}

	audio_stream := fmt_ctx.streams[audio_stream_idx]
	codecpar := audio_stream.codecpar

	// Allocate codec context and open decoder
	codec_ctx := ff.avcodec_alloc_context3(decoder)
	if codec_ctx == nil {
		fmt.eprintfln("[trimsync] error: could not allocate codec context")
		err = .Open_Codec
		return
	}
	defer ff.avcodec_free_context(&codec_ctx)

	if ff.avcodec_parameters_to_context(codec_ctx, codecpar) < 0 {
		fmt.eprintfln("[trimsync] error: could not copy codec parameters")
		err = .Open_Codec
		return
	}

	if ff.avcodec_open2(codec_ctx, decoder, nil) < 0 {
		fmt.eprintfln("[trimsync] error: could not open audio codec")
		err = .Open_Codec
		return
	}

	// Gather stream metadata
	result.sample_rate = int(codecpar.sample_rate)
	result.nb_channels = int(codecpar.ch_layout.nb_channels)
	if result.nb_channels == 0 do result.nb_channels = 1

	// Frame rate from the video stream (for frame-based analysis)
	result.frame_rate = 30.0 // default
	for i in 0..<fmt_ctx.nb_streams {
		s := fmt_ctx.streams[i]
		if s.codecpar.codec_type == .VIDEO {
			if s.avg_frame_rate.den > 0 {
				result.frame_rate = f64(s.avg_frame_rate.num) / f64(s.avg_frame_rate.den)
			} else if s.r_frame_rate.den > 0 {
				result.frame_rate = f64(s.r_frame_rate.num) / f64(s.r_frame_rate.den)
			}
			break
		}
	}

	// Duration
	if fmt_ctx.duration > 0 {
		result.duration = f64(fmt_ctx.duration) / f64(ff.AV_TIME_BASE)
	}

	// Decode all audio frames
	pkt := ff.av_packet_alloc()
	if pkt == nil {
		err = .Decode
		return
	}
	defer ff.av_packet_free(&pkt)

	frame := ff.av_frame_alloc()
	if frame == nil {
		err = .Decode
		return
	}
	defer ff.av_frame_free(&frame)

	// Pre-allocate roughly
	estimated_samples := int(result.duration * f64(result.sample_rate)) + 1024
	result.samples = make([dynamic]f32, 0, estimated_samples)

	sample_fmt := ff.AVSampleFormat(codecpar.format)
	is_planar := ff.av_sample_fmt_is_planar(sample_fmt) != 0
	bytes_per_sample := int(ff.av_get_bytes_per_sample(sample_fmt))
	nb_channels := result.nb_channels

	for ff.av_read_frame(fmt_ctx, pkt) >= 0 {
		defer ff.av_packet_unref(pkt)

		if int(pkt.stream_index) != int(audio_stream_idx) do continue

		// Send packet to decoder
		if ff.avcodec_send_packet(codec_ctx, pkt) < 0 do continue

		// Receive all decoded frames from this packet
		for ff.avcodec_receive_frame(codec_ctx, frame) >= 0 {
			defer ff.av_frame_unref(frame)

			n := int(frame.nb_samples)

			// Convert each sample to f32, averaging all channels to mono
			for s in 0..<n {
				mono_sample: f32 = 0

				for ch in 0..<nb_channels {
					raw_val := read_sample(frame, sample_fmt, is_planar, bytes_per_sample, ch, s, nb_channels)
					mono_sample += raw_val
				}
				mono_sample /= f32(nb_channels)
				append(&result.samples, mono_sample)
			}
		}
	}

	// Flush the decoder
	ff.avcodec_send_packet(codec_ctx, nil)
	for ff.avcodec_receive_frame(codec_ctx, frame) >= 0 {
		defer ff.av_frame_unref(frame)
		n := int(frame.nb_samples)
		for s in 0..<n {
			mono_sample: f32 = 0
			for ch in 0..<nb_channels {
				raw_val := read_sample(frame, sample_fmt, is_planar, bytes_per_sample, ch, s, nb_channels)
				mono_sample += raw_val
			}
			mono_sample /= f32(nb_channels)
			append(&result.samples, mono_sample)
		}
	}

	fmt.printfln("[trimsync] decoded %d mono samples (%.1fs at %dHz, %d channels)",
		len(result.samples),
		f64(len(result.samples)) / f64(result.sample_rate),
		result.sample_rate,
		nb_channels,
	)
	return
}

// read_sample reads a single sample from an AVFrame, handling all common
// sample formats (S16, S32, FLT, FLTP, S16P, etc.) and returning it as f32.
@(private)
read_sample :: proc(
	frame: ^ff.AVFrame,
	fmt_: ff.AVSampleFormat,
	is_planar: bool,
	bytes_per_sample: int,
	channel: int,
	sample_idx: int,
	nb_channels: int,
) -> f32 {

	if is_planar {
		// Planar: frame.data[channel] points at contiguous samples for that channel
		plane := frame.data[channel]
		if plane == nil do return 0

		offset := sample_idx * bytes_per_sample
		ptr := rawptr(uintptr(plane) + uintptr(offset))

		#partial switch fmt_ {
		case .U8P:
			val := (^u8)(ptr)^
			return (f32(val) - 128.0) / 128.0
		case .S16P:
			val := (^i16)(ptr)^
			return f32(val) / 32768.0
		case .S32P:
			val := (^i32)(ptr)^
			return f32(val) / 2147483648.0
		case .FLTP:
			return (^f32)(ptr)^
		case .DBLP:
			return f32((^f64)(ptr)^)
		case .S64P:
			val := (^i64)(ptr)^
			return f32(f64(val) / 9223372036854775808.0)
		case:
			return 0
		}
	} else {
		// Packed/interleaved: all channel samples are interleaved in data[0]
		plane := frame.data[0]
		if plane == nil do return 0

		offset := (sample_idx * nb_channels + channel) * bytes_per_sample
		ptr := rawptr(uintptr(plane) + uintptr(offset))

		#partial switch fmt_ {
		case .U8:
			val := (^u8)(ptr)^
			return (f32(val) - 128.0) / 128.0
		case .S16:
			val := (^i16)(ptr)^
			return f32(val) / 32768.0
		case .S32:
			val := (^i32)(ptr)^
			return f32(val) / 2147483648.0
		case .FLT:
			return (^f32)(ptr)^
		case .DBL:
			return f32((^f64)(ptr)^)
		case .S64:
			val := (^i64)(ptr)^
			return f32(f64(val) / 9223372036854775808.0)
		case:
			return 0
		}
	}
}
