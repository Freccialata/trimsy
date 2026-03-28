package ffmpeg

import "core:c"

// ---------------------------------------------------------------------------
// libavformat  (linked via system dylib)
// ---------------------------------------------------------------------------

when ODIN_OS == .Darwin {
	foreign import avformat "system:avformat"
} else {
	foreign import avformat "system:avformat"
}

// -- AVStream -----------------------------------------------------------------
// sizeof(AVStream) is NOT part of public ABI; streams are created by libavformat.
// We define the public fields in order (from avformat.h FFmpeg 8.x).

AVStream :: struct {
	av_class:            rawptr,       // const AVClass*
	index:               c.int,
	id:                  c.int,
	codecpar:            ^AVCodecParameters,
	priv_data:           rawptr,
	time_base:           AVRational,
	start_time:          i64,
	duration:            i64,
	nb_frames:           i64,
	disposition:         c.int,
	discard:             c.int,        // enum AVDiscard
	sample_aspect_ratio: AVRational,
	metadata:            rawptr,       // *AVDictionary
	avg_frame_rate:      AVRational,
	attached_pic:        AVPacket,     // embedded struct
	event_flags:         c.int,
	r_frame_rate:        AVRational,
	pts_wrap_bits:       c.int,
}

// -- AVIOInterruptCB ----------------------------------------------------------

AVIOInterruptCB :: struct {
	callback: rawptr, // int (*)(void*)
	opaque:   rawptr,
}

// -- AVFormatContext ----------------------------------------------------------
// sizeof is NOT part of public ABI; always alloc via avformat_alloc_context().
// We define the public-facing fields up front, matching avformat.h FFmpeg 8.x.

AVFormatContext :: struct {
	av_class:        rawptr,       // const AVClass*
	iformat:         rawptr,       // const AVInputFormat*
	oformat:         rawptr,       // const AVOutputFormat*
	priv_data:       rawptr,
	pb:              rawptr,       // AVIOContext*
	ctx_flags:       c.int,
	nb_streams:      c.uint,
	streams:         [^]^AVStream,
	nb_stream_groups: c.uint,
	stream_groups:   rawptr,       // AVStreamGroup**
	nb_chapters:     c.uint,
	chapters:        rawptr,       // AVChapter**
	url:             cstring,
	start_time:      i64,
	duration:        i64,
	bit_rate:        i64,
	// ... many more fields we don't use
}

// -- Foreign function imports -------------------------------------------------

@(default_calling_convention = "c")
foreign avformat {
	avformat_open_input           :: proc(ps: ^^AVFormatContext, url: cstring, fmt: rawptr, options: rawptr) -> c.int ---
	avformat_close_input          :: proc(s: ^^AVFormatContext) ---
	avformat_find_stream_info     :: proc(ic: ^AVFormatContext, options: rawptr) -> c.int ---
	av_find_best_stream           :: proc(ic: ^AVFormatContext, type_: AVMediaType, wanted_stream_nb: c.int, related_stream: c.int, decoder_ret: ^^AVCodec, flags: c.int) -> c.int ---
	av_read_frame                 :: proc(s: ^AVFormatContext, pkt: ^AVPacket) -> c.int ---
	avformat_network_init         :: proc() -> c.int ---
}
