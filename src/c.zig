//! Raw extern declarations for the parakeet.cpp C API (include/parakeet_capi.h)
//! and the gguf subset from ggml (include/gguf.h). Hand-written; no @cImport.

// Opaque types.
pub const parakeet_ctx = opaque {};
pub const parakeet_stream = opaque {};
pub const gguf_context = opaque {};

// One <EOU>/<EOB> event emitted by the streaming decoder.
pub const parakeet_stream_event = extern struct {
    token: c_int,
    is_eob: c_int,
    encoder_frame: c_int,
    time_sec: f32,
};

// Bits for the event mask.
pub const PARAKEET_EVENT_EOU: c_int = 1;
pub const PARAKEET_EVENT_EOB: c_int = 2;

// ---------------------------------------------------------------------------
// parakeet C API (include/parakeet_capi.h, ABI version 6).
// ---------------------------------------------------------------------------

/// ABI version of the parakeet C API.
pub extern fn parakeet_capi_abi_version() c_int;

/// Load a GGUF model. Returns an owning context, or null on failure.
pub extern fn parakeet_capi_load(gguf_path: [*:0]const u8) ?*parakeet_ctx;

/// Free a context obtained from parakeet_capi_load. Safe on null.
pub extern fn parakeet_capi_free(ctx: ?*parakeet_ctx) void;

/// Human-readable last error on ctx, or "" if none (owned by the context).
pub extern fn parakeet_capi_last_error(ctx: ?*parakeet_ctx) [*:0]const u8;

/// Free a string returned by a parakeet_capi_* function. Safe on null.
pub extern fn parakeet_capi_free_string(s: ?[*:0]u8) void;

/// Transcribe a WAV file with an explicit language prompt.
pub extern fn parakeet_capi_transcribe_path_lang(
    ctx: ?*parakeet_ctx,
    wav_path: [*:0]const u8,
    decoder: c_int,
    target_lang: ?[*:0]const u8,
) ?[*:0]u8;

/// Transcribe in-memory mono float PCM with an explicit language prompt.
pub extern fn parakeet_capi_transcribe_pcm_lang(
    ctx: ?*parakeet_ctx,
    samples: [*]const f32,
    n_samples: c_int,
    sample_rate: c_int,
    decoder: c_int,
    target_lang: ?[*:0]const u8,
) ?[*:0]u8;

/// Transcribe a WAV file, returning a JSON document with word timestamps.
pub extern fn parakeet_capi_transcribe_path_json(
    ctx: ?*parakeet_ctx,
    wav_path: [*:0]const u8,
    decoder: c_int,
) ?[*:0]u8;

/// Transcribe one or more concatenated mono float PCM clips, returning a JSON
/// array with one document per clip.
pub extern fn parakeet_capi_transcribe_pcm_batch_json_lang(
    ctx: ?*parakeet_ctx,
    samples_concat: [*]const f32,
    n_samples: [*]const c_int,
    n_clips: c_int,
    sample_rate: c_int,
    decoder: c_int,
    target_lang: ?[*:0]const u8,
) ?[*:0]u8;

/// Begin a streaming session with an explicit language prompt.
pub extern fn parakeet_capi_stream_begin_lang(
    ctx: ?*parakeet_ctx,
    target_lang: ?[*:0]const u8,
) ?*parakeet_stream;

/// Feed 16 kHz mono float PCM; returns newly-finalized text ("" if none).
pub extern fn parakeet_capi_stream_feed(
    s: ?*parakeet_stream,
    pcm: [*]const f32,
    n_samples: c_int,
    eou_out: ?*c_int,
) ?[*:0]u8;

/// Flush the end-of-stream tail; returns the final newly-finalized text.
pub extern fn parakeet_capi_stream_finalize(s: ?*parakeet_stream) ?[*:0]u8;

/// Like parakeet_capi_stream_feed but returns a JSON document.
pub extern fn parakeet_capi_stream_feed_json(
    s: ?*parakeet_stream,
    pcm: [*]const f32,
    n_samples: c_int,
) ?[*:0]u8;

/// Like parakeet_capi_stream_finalize but returns a JSON document.
pub extern fn parakeet_capi_stream_finalize_json(s: ?*parakeet_stream) ?[*:0]u8;

/// Drain accumulated <EOU>/<EOB> events; returns the count, or -1 on error.
pub extern fn parakeet_capi_stream_drain_events(
    s: ?*parakeet_stream,
    out_events: *?[*]parakeet_stream_event,
) c_int;

/// Free an event array returned by parakeet_capi_stream_drain_events.
pub extern fn parakeet_capi_free_events(events: ?[*]parakeet_stream_event) void;

/// Free a streaming session. Safe on null.
pub extern fn parakeet_capi_stream_free(s: ?*parakeet_stream) void;

// ---------------------------------------------------------------------------
// zarakeet shim (src/shim.cpp): process-wide controls not in parakeet_capi.h.
// ---------------------------------------------------------------------------

/// Set the process-wide CPU thread count for every graph (0 = default, 8).
/// Applied on the next graph run; ignored by the Vulkan device.
pub extern fn zarakeet_set_num_threads(n: c_int) void;

/// Free the process-global compute backend. Must be called only when no
/// Model or Stream is alive (their weights live on that backend).
pub extern fn zarakeet_shutdown_backend() void;

// ---------------------------------------------------------------------------
// gguf (ggml include/gguf.h).
// ---------------------------------------------------------------------------

/// Parameters for gguf_init_from_file. Note: the C field is
/// `struct ggml_context **`; we only ever pass null, so a single-level
/// optional pointer is ABI-equivalent here.
pub const gguf_init_params = extern struct {
    no_alloc: bool,
    ctx: ?*anyopaque,
};

/// gguf_type values (see the gguf_type enum in gguf.h).
pub const GGUF_TYPE_BOOL: c_int = 7;
pub const GGUF_TYPE_STRING: c_int = 8;

/// Open a GGUF file for reading. Returns null on failure.
pub extern fn gguf_init_from_file(fname: [*:0]const u8, params: gguf_init_params) ?*gguf_context;

/// Create an empty GGUF context.
pub extern fn gguf_init_empty() ?*gguf_context;

/// Free a GGUF context.
pub extern fn gguf_free(ctx: ?*gguf_context) void;

/// Find a key by name; returns -1 if not found.
pub extern fn gguf_find_key(ctx: *const gguf_context, key: [*:0]const u8) i64;

/// Get the type of a key's value.
pub extern fn gguf_get_kv_type(ctx: *const gguf_context, key_id: i64) c_int;

/// Get a string value.
pub extern fn gguf_get_val_str(ctx: *const gguf_context, key_id: i64) [*:0]const u8;

/// Get a bool value.
pub extern fn gguf_get_val_bool(ctx: *const gguf_context, key_id: i64) bool;

/// Set a string value.
pub extern fn gguf_set_val_str(ctx: *gguf_context, key: [*:0]const u8, val: [*:0]const u8) void;

/// Set a bool value.
pub extern fn gguf_set_val_bool(ctx: *gguf_context, key: [*:0]const u8, val: bool) void;

/// Write the context (metadata only when only_meta) to a file.
pub extern fn gguf_write_to_file(ctx: *const gguf_context, fname: [*:0]const u8, only_meta: bool) bool;