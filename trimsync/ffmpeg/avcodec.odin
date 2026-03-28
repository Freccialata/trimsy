package ffmpeg

import "core:c"

// ---------------------------------------------------------------------------
// libavcodec  (linked via system dylib)
// ---------------------------------------------------------------------------

when ODIN_OS == .Darwin {
	foreign import avcodec "system:avcodec"
} else when ODIN_OS == .Windows {
	foreign import avcodec "system:avcodec.lib"
} else {
	foreign import avcodec "system:avcodec"
}

// -- AVCodecID (we only enumerate the ones we may encounter) ------------------

AVCodecID :: enum c.int {
	NONE = 0,
	// We don't need to enumerate all — we just pass the id around.
}

// -- AVPacketSideData ---------------------------------------------------------

AVPacketSideData :: struct {
	data:  [^]u8,
	size:  c.size_t,
	type_: c.int,       // enum AVPacketSideDataType
}

// -- AVPacket -----------------------------------------------------------------
// sizeof(AVPacket) IS currently part of ABI (but deprecated).
// Layout verified against /opt/homebrew/include/libavcodec/packet.h FFmpeg 8.x.

AVPacket :: struct {
	buf:            ^AVBufferRef,
	pts:            i64,
	dts:            i64,
	data:           [^]u8,
	size:           c.int,
	stream_index:   c.int,
	flags:          c.int,
	side_data:      ^AVPacketSideData,
	side_data_elems: c.int,
	duration:       i64,
	pos:            i64,
	opaque:         rawptr,
	opaque_ref:     ^AVBufferRef,
	time_base:      AVRational,
}

// -- AVCodecParameters --------------------------------------------------------
// sizeof is NOT part of public ABI; alloc via avcodec_parameters_alloc().
// We define the fields up to what we need.

AVCodecParameters :: struct {
	codec_type:         AVMediaType,
	codec_id:           AVCodecID,
	codec_tag:          u32,
	extradata:          [^]u8,
	extradata_size:     c.int,
	coded_side_data:    ^AVPacketSideData,
	nb_coded_side_data: c.int,
	format:             c.int,                    // AVPixelFormat or AVSampleFormat
	bit_rate:           i64,
	bits_per_coded_sample: c.int,
	bits_per_raw_sample:   c.int,
	profile:            c.int,
	level:              c.int,
	width:              c.int,
	height:             c.int,
	sample_aspect_ratio: AVRational,
	framerate:          AVRational,
	field_order:        c.int,                    // AVFieldOrder
	color_range:        c.int,
	color_primaries:    c.int,
	color_trc:          c.int,
	color_space:        c.int,
	chroma_location:    c.int,
	video_delay:        c.int,
	ch_layout:          AVChannelLayout,
	sample_rate:        c.int,
	block_align:        c.int,
	frame_size:         c.int,
	initial_padding:    c.int,
	trailing_padding:   c.int,
	seek_preroll:       c.int,
}

// -- AVCodecContext (opaque — always heap-allocated) ----------------------------
// We never access fields directly; always use avcodec_* functions.

AVCodecContext :: struct {
	_opaque: [1]u8, // opaque; never instantiated on the stack
}

// -- AVCodec (opaque) ---------------------------------------------------------

AVCodec :: struct {
	_opaque: [1]u8,
}

// -- Foreign function imports -------------------------------------------------

@(default_calling_convention = "c")
foreign avcodec {
	av_packet_alloc      :: proc() -> ^AVPacket ---
	av_packet_free       :: proc(pkt: ^^AVPacket) ---
	av_packet_unref      :: proc(pkt: ^AVPacket) ---

	avcodec_alloc_context3      :: proc(codec: ^AVCodec) -> ^AVCodecContext ---
	avcodec_free_context        :: proc(avctx: ^^AVCodecContext) ---
	avcodec_parameters_to_context :: proc(codec: ^AVCodecContext, par: ^AVCodecParameters) -> c.int ---
	avcodec_open2               :: proc(avctx: ^AVCodecContext, codec: ^AVCodec, options: rawptr) -> c.int ---
	avcodec_send_packet         :: proc(avctx: ^AVCodecContext, avpkt: ^AVPacket) -> c.int ---
	avcodec_receive_frame       :: proc(avctx: ^AVCodecContext, frame: ^AVFrame) -> c.int ---

	avcodec_find_decoder :: proc(id: AVCodecID) -> ^AVCodec ---
}
