package ffmpeg

import "core:c"

// ---------------------------------------------------------------------------
// libavutil  (linked via system dylib)
// ---------------------------------------------------------------------------

when ODIN_OS == .Darwin {
	foreign import avutil "system:avutil"
} else when ODIN_OS == .Windows {
	foreign import avutil "system:avutil.lib"
} else {
	foreign import avutil "system:avutil"
}

// -- AVRational ---------------------------------------------------------------

AVRational :: struct {
	num: c.int,
	den: c.int,
}

// -- AVMediaType --------------------------------------------------------------

AVMediaType :: enum c.int {
	UNKNOWN    = -1,
	VIDEO      =  0,
	AUDIO      =  1,
	DATA       =  2,
	SUBTITLE   =  3,
	ATTACHMENT =  4,
}

// -- AVSampleFormat -----------------------------------------------------------

AVSampleFormat :: enum c.int {
	NONE = -1,
	U8,          // unsigned 8 bits
	S16,         // signed 16 bits
	S32,         // signed 32 bits
	FLT,         // float
	DBL,         // double
	U8P,         // unsigned 8 bits, planar
	S16P,        // signed 16 bits, planar
	S32P,        // signed 32 bits, planar
	FLTP,        // float, planar
	DBLP,        // double, planar
	S64,         // signed 64 bits
	S64P,        // signed 64 bits, planar
}

// -- AVChannelOrder -----------------------------------------------------------

AVChannelOrder :: enum c.int {
	UNSPEC,
	NATIVE,
	CUSTOM,
	AMBISONIC,
}

// -- AVChannelLayout ----------------------------------------------------------
// sizeof(AVChannelLayout) is part of the public ABI.
// Layout: order(4) + pad(4) + nb_channels(4) + pad(4) + u.mask(8) + opaque(8) = 32 bytes

AVChannelLayout :: struct {
	order:       AVChannelOrder,
	nb_channels: c.int,
	u:           struct #raw_union {
		mask: u64,
		map_: rawptr, // *AVChannelCustom
	},
	opaque:      rawptr,
}

// -- AVBufferRef (opaque for us) -----------------------------------------------

AVBufferRef :: struct {
	_opaque: [32]u8, // we never touch internals
}

// -- AVFrame ------------------------------------------------------------------
// We define only the fields we access. The struct is bigger but we only read
// from the start, which is safe because sizeof(AVFrame) is NOT part of ABI —
// frames are always heap-allocated by av_frame_alloc().

AV_NUM_DATA_POINTERS :: 8

AVFrame :: struct {
	data:          [AV_NUM_DATA_POINTERS][^]u8,
	linesize:      [AV_NUM_DATA_POINTERS]c.int,
	extended_data: [^][^]u8,
	width:         c.int,
	height:        c.int,
	nb_samples:    c.int,
	format:        c.int, // AVPixelFormat or AVSampleFormat
	pict_type:     c.int, // AVPictureType enum
	sample_aspect_ratio: AVRational,
	pts:           i64,
	pkt_dts:       i64,
	time_base:     AVRational,
	quality:       c.int,
	opaque:        rawptr,
	repeat_pict:   c.int,
	sample_rate:   c.int,
	buf:           [AV_NUM_DATA_POINTERS]^AVBufferRef,
	extended_buf:  ^(^AVBufferRef),
	nb_extended_buf: c.int,
	side_data:     rawptr, // **AVFrameSideData — we don't use
	nb_side_data:  c.int,
	flags:         c.int,
	color_range:   c.int,
	color_primaries: c.int,
	color_trc:     c.int,
	colorspace:    c.int,
	chroma_location: c.int,
	best_effort_timestamp: i64,
	metadata:      rawptr, // *AVDictionary
	decode_error_flags: c.int,
	hw_frames_ctx: ^AVBufferRef,
	opaque_ref:    ^AVBufferRef,
	crop_top:      c.size_t,
	crop_bottom:   c.size_t,
	crop_left:     c.size_t,
	crop_right:    c.size_t,
	private_ref:   rawptr,
	ch_layout:     AVChannelLayout,
	duration:      i64,
}

// -- Constants ----------------------------------------------------------------

AV_NOPTS_VALUE :: transmute(i64)u64(0x8000000000000000)
AV_TIME_BASE   :: 1000000

// -- Foreign function imports -------------------------------------------------

@(default_calling_convention = "c")
foreign avutil {
	av_frame_alloc       :: proc() -> ^AVFrame ---
	av_frame_free        :: proc(frame: ^^AVFrame) ---
	av_frame_unref       :: proc(frame: ^AVFrame) ---

	av_get_bytes_per_sample   :: proc(sample_fmt: AVSampleFormat) -> c.int ---
	av_sample_fmt_is_planar   :: proc(sample_fmt: AVSampleFormat) -> c.int ---
	av_get_sample_fmt_name    :: proc(sample_fmt: AVSampleFormat) -> cstring ---

	av_channel_layout_default :: proc(ch_layout: ^AVChannelLayout, nb_channels: c.int) ---

	@(link_name = "av_log_set_level")
	av_log_set_level :: proc(level: c.int) ---
}

AV_LOG_QUIET :: -8
AV_LOG_ERROR :: 16
AV_LOG_WARNING :: 24
AV_LOG_INFO :: 32
