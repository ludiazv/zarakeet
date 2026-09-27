const std = @import("std");
const Allocator = std.mem.Allocator;
/// Raw C bindings (parakeet C API + gguf subset).
pub const c = @import("c.zig");

/// Count of live Models and Streams; shutdown() asserts it is zero.
var live = std.atomic.Value(u32).init(0);

/// Errors returned by the zarakeet API.
pub const Error = error{ LoadFailed, UnsupportedModel, TranscribeFailed, NotStreamingModel, OutOfMemory };

/// Supported model families.
pub const Kind = enum { tdt, nemotron };

/// Per-call transcription options.
pub const Options = struct { lang: ?[:0]const u8 = null };

/// A loaded parakeet model.
pub const Model = struct {
    ctx: *c.parakeet_ctx,
    kind: Kind,

    /// Load a GGUF model, gating on its arch metadata.
    pub fn load(path: [:0]const u8) Error!Model {
        const kind = try detectKind(path);
        const ctx = c.parakeet_capi_load(path.ptr) orelse return error.LoadFailed;
        if (c.parakeet_capi_abi_version() != 6) {
            c.parakeet_capi_free(ctx);
            return error.LoadFailed;
        }
        _ = live.fetchAdd(1, .monotonic);
        return .{ .ctx = ctx, .kind = kind };
    }

    /// Free the model.
    pub fn deinit(self: *Model) void {
        c.parakeet_capi_free(self.ctx);
        _ = live.fetchSub(1, .monotonic);
        self.* = undefined;
    }

    /// Human-readable last error, or "" if none.
    pub fn lastError(self: Model) [:0]const u8 {
        return std.mem.span(c.parakeet_capi_last_error(self.ctx));
    }

    /// Transcribe a WAV file to plain text. Language tags (e.g. <en-US>) are
    /// removed and whitespace is normalized.
    pub fn transcribeFile(self: Model, gpa: Allocator, wav_path: [:0]const u8, opts: Options) Error![]u8 {
        const lang = if (opts.lang) |l| l.ptr else null;
        const p = c.parakeet_capi_transcribe_path_lang(self.ctx, wav_path.ptr, 2, lang);
        var clean = Clean{};
        return takeString(gpa, p, &clean, true);
    }

    /// Transcribe in-memory mono float PCM to plain text. Language tags (e.g.
    /// <en-US>) are removed and whitespace is normalized.
    pub fn transcribePcm(self: Model, gpa: Allocator, pcm: []const f32, sample_rate: u32, opts: Options) Error![]u8 {
        const lang = if (opts.lang) |l| l.ptr else null;
        const n = std.math.cast(c_int, pcm.len) orelse return error.TranscribeFailed;
        const sr = std.math.cast(c_int, sample_rate) orelse return error.TranscribeFailed;
        const p = c.parakeet_capi_transcribe_pcm_lang(self.ctx, pcm.ptr, n, sr, 2, lang);
        var clean = Clean{};
        return takeString(gpa, p, &clean, true);
    }

    /// Transcribe a WAV file to a JSON document (uses the model's default language).
    /// Raw upstream JSON: nemotron language tags remain in text (and, when
    /// streaming, in words with timestamps).
    pub fn transcribeFileJson(self: Model, gpa: Allocator, wav_path: [:0]const u8) Error![]u8 {
        const p = c.parakeet_capi_transcribe_path_json(self.ctx, wav_path.ptr, 2);
        return takeStringRaw(gpa, p);
    }

    /// Transcribe in-memory mono float PCM to a JSON document.
    /// Raw upstream JSON: nemotron language tags remain in text (and, when
    /// streaming, in words with timestamps).
    pub fn transcribePcmJson(self: Model, gpa: Allocator, pcm: []const f32, sample_rate: u32, opts: Options) Error![]u8 {
        const lang = if (opts.lang) |l| l.ptr else null;
        const n = std.math.cast(c_int, pcm.len) orelse return error.TranscribeFailed;
        const sr = std.math.cast(c_int, sample_rate) orelse return error.TranscribeFailed;
        const n_samples = [_]c_int{n};
        const p = c.parakeet_capi_transcribe_pcm_batch_json_lang(self.ctx, pcm.ptr, &n_samples, 1, sr, 2, lang);
        const arr = try takeStringRaw(gpa, p);
        // The result is a JSON array with one element; strip the brackets.
        if (arr.len < 2 or arr[0] != '[' or arr[arr.len - 1] != ']') {
            gpa.free(arr);
            return error.TranscribeFailed;
        }
        const inner = arr[1 .. arr.len - 1];
        const out = try gpa.dupe(u8, inner);
        gpa.free(arr);
        return out;
    }

    /// Begin a streaming session (nemotron models only).
    pub fn stream(self: *Model, opts: Options) Error!Stream {
        if (self.kind != .nemotron) return error.NotStreamingModel;
        const lang = if (opts.lang) |l| l.ptr else null;
        const handle = c.parakeet_capi_stream_begin_lang(self.ctx, lang) orelse return error.TranscribeFailed;
        _ = live.fetchAdd(1, .monotonic);
        return .{ .handle = handle, .clean = .{} };
    }
};

/// A single <EOU>/<EOB> event drained from a stream.
pub const Event = struct {
    kind: enum { eou, eob },
    encoder_frame: u32,
    time_sec: f32,
};

/// A streaming session. Must not outlive the Model it came from.
pub const Stream = struct {
    handle: *c.parakeet_stream,
    clean: Clean = .{},

    /// Feed 16 kHz mono float PCM; returns newly-finalized text ("" if none).
    /// Language tags (e.g. <en-US>) are removed and whitespace is normalized.
    pub fn feed(self: *Stream, gpa: Allocator, pcm16k: []const f32) Error![]u8 {
        const n = std.math.cast(c_int, pcm16k.len) orelse return error.TranscribeFailed;
        const p = c.parakeet_capi_stream_feed(self.handle, pcm16k.ptr, n, null);
        return takeString(gpa, p, &self.clean, false);
    }

    /// Flush the end-of-stream tail; returns the final newly-finalized text.
    /// Language tags (e.g. <en-US>) are removed and whitespace is normalized.
    pub fn finalize(self: *Stream, gpa: Allocator) Error![]u8 {
        const p = c.parakeet_capi_stream_finalize(self.handle);
        return takeString(gpa, p, &self.clean, true);
    }

    /// Like feed but returns a JSON document. pcm16k must be 16 kHz mono.
    /// Raw upstream JSON: nemotron language tags remain in text (and, when
    /// streaming, in words with timestamps).
    pub fn feedJson(self: *Stream, gpa: Allocator, pcm16k: []const f32) Error![]u8 {
        const n = std.math.cast(c_int, pcm16k.len) orelse return error.TranscribeFailed;
        const p = c.parakeet_capi_stream_feed_json(self.handle, pcm16k.ptr, n);
        return takeStringRaw(gpa, p);
    }

    /// Like finalize but returns a JSON document.
    /// Raw upstream JSON: nemotron language tags remain in text (and, when
    /// streaming, in words with timestamps).
    pub fn finalizeJson(self: *Stream, gpa: Allocator) Error![]u8 {
        const p = c.parakeet_capi_stream_finalize_json(self.handle);
        return takeStringRaw(gpa, p);
    }

    /// Drain accumulated <EOU>/<EOB> events. Don't mix with the *Json feed
    /// functions on the same stream; they share one event queue. Caller frees.
    pub fn drainEvents(self: *Stream, gpa: Allocator) Error![]Event {
        var raw: ?[*]c.parakeet_stream_event = null;
        const n = c.parakeet_capi_stream_drain_events(self.handle, &raw);
        if (n < 0) return error.TranscribeFailed;
        defer c.parakeet_capi_free_events(raw);
        const count = @as(usize, @intCast(n));
        const out = try gpa.alloc(Event, count);
        if (count > 0) {
            const events = raw.?[0..count];
            for (out, events) |*o, e| {
                o.* = .{
                    .kind = if (e.is_eob == 1) .eob else .eou,
                    .encoder_frame = @intCast(e.encoder_frame),
                    .time_sec = e.time_sec,
                };
            }
        }
        return out;
    }

    /// Free the streaming session.
    pub fn deinit(self: *Stream) void {
        c.parakeet_capi_stream_free(self.handle);
        _ = live.fetchSub(1, .monotonic);
    }
};

/// Process-wide CPU thread count for all models (0 = parakeet default, 8).
/// Takes effect on the next transcription. No effect on Vulkan compute.
pub fn setNumThreads(n: u32) void {
    const v = @min(n, @as(u32, std.math.maxInt(c_int)));
    c.zarakeet_set_num_threads(@as(c_int, @intCast(v)));
}

/// Free the process-global compute backend. Call once before the program
/// exits, after every Model and Stream has been deinit'ed. Required for clean
/// exit on GPU (Vulkan) builds; harmless on CPU.
pub fn shutdown() void {
    std.debug.assert(live.load(.monotonic) == 0);
    c.zarakeet_shutdown_backend();
}

/// Plain-text cleanup state. Offline calls use a fresh one; a Stream keeps one
/// across feed()/finalize() so whitespace is also clean across chunk boundaries.
const Clean = struct {
    started: bool = false,       // a non-space char has been emitted
    pending_space: bool = false, // a space is owed before the next non-space char
};

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn isTagChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_' or ch == '-';
}

/// Copy `raw` into a new exact-size allocation, with every tag removed and
/// whitespace normalized. `final` drops an owed trailing space.
fn cleanText(gpa: Allocator, raw: []const u8, st: *Clean, final: bool) Error![]u8 {
    // Pass 1: compute the output length without allocating.
    var len: usize = 0;
    var started = st.started;
    var pending = st.pending_space;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const ch = raw[i];
        if (ch == '<') {
            // A tag: '<', 1-16 chars from [A-Za-z0-9_-], then '>'.
            const start = i + 1;
            var j = start;
            while (j < raw.len and j < start + 16 and isTagChar(raw[j])) j += 1;
            if (j > start and j < raw.len and raw[j] == '>') {
                i = j; // skip the whole tag; the loop's i += 1 lands after '>'
                continue;
            }
        }
        if (isSpace(ch)) {
            if (started) pending = true;
        } else {
            if (pending) {
                len += 1;
                pending = false;
            }
            len += 1;
            started = true;
        }
    }

    // Pass 2: fill an exact-size allocation.
    const out = try gpa.alloc(u8, len);
    var k: usize = 0;
    started = st.started;
    pending = st.pending_space;
    i = 0;
    while (i < raw.len) : (i += 1) {
        const ch = raw[i];
        if (ch == '<') {
            const start = i + 1;
            var j = start;
            while (j < raw.len and j < start + 16 and isTagChar(raw[j])) j += 1;
            if (j > start and j < raw.len and raw[j] == '>') {
                i = j;
                continue;
            }
        }
        if (isSpace(ch)) {
            if (started) pending = true;
        } else {
            if (pending) {
                out[k] = ' ';
                k += 1;
                pending = false;
            }
            out[k] = ch;
            k += 1;
            started = true;
        }
    }
    st.started = started;
    st.pending_space = if (final) false else pending;
    return out;
}

/// Copy a C-returned NUL-terminated string into the allocator through
/// cleanText; frees the C string.
fn takeString(gpa: Allocator, p: ?[*:0]u8, st: *Clean, final: bool) Error![]u8 {
    const s = p orelse return error.TranscribeFailed;
    defer c.parakeet_capi_free_string(s);
    return cleanText(gpa, std.mem.span(s), st, final);
}

/// Like takeString but keeps the upstream text byte-for-byte (JSON functions).
fn takeStringRaw(gpa: Allocator, p: ?[*:0]u8) Error![]u8 {
    const s = p orelse return error.TranscribeFailed;
    defer c.parakeet_capi_free_string(s);
    return gpa.dupe(u8, std.mem.span(s));
}

/// Classify a GGUF model from its parakeet.arch / parakeet.prompt.present metadata.
fn detectKind(path: [:0]const u8) Error!Kind {
    const ctx = c.gguf_init_from_file(path.ptr, .{ .no_alloc = true, .ctx = null }) orelse return error.LoadFailed;
    defer c.gguf_free(ctx);

    const arch_id = c.gguf_find_key(ctx, "parakeet.arch");
    if (arch_id < 0) return error.UnsupportedModel;
    if (c.gguf_get_kv_type(ctx, arch_id) != c.GGUF_TYPE_STRING) return error.UnsupportedModel;
    const arch = std.mem.span(c.gguf_get_val_str(ctx, arch_id));

    const prompt_id = c.gguf_find_key(ctx, "parakeet.prompt.present");
    var prompt_present = false;
    if (prompt_id >= 0 and c.gguf_get_kv_type(ctx, prompt_id) == c.GGUF_TYPE_BOOL) {
        prompt_present = c.gguf_get_val_bool(ctx, prompt_id);
    }

    if (std.mem.eql(u8, arch, "tdt") or std.mem.eql(u8, arch, "hybrid_tdt_ctc")) {
        return Kind.tdt;
    } else if (std.mem.eql(u8, arch, "rnnt")) {
        return if (prompt_present) Kind.nemotron else error.UnsupportedModel;
    } else {
        return error.UnsupportedModel;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "abi version" {
    try std.testing.expectEqual(@as(c_int, 6), c.parakeet_capi_abi_version());
}

// Reference every declared extern so the linker proves each symbol exists.
// Runtime references (not comptime): the symbols must reach the object file
// so linking fails loudly if any is missing from the C library.
test "all declared C functions exist" {
    // parakeet C API
    std.mem.doNotOptimizeAway(&c.parakeet_capi_abi_version);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_load);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_free);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_last_error);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_free_string);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_transcribe_path_lang);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_transcribe_pcm_lang);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_transcribe_path_json);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_transcribe_pcm_batch_json_lang);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_stream_begin_lang);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_stream_feed);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_stream_finalize);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_stream_feed_json);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_stream_finalize_json);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_stream_drain_events);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_free_events);
    std.mem.doNotOptimizeAway(&c.parakeet_capi_stream_free);
    // zarakeet shim
    std.mem.doNotOptimizeAway(&c.zarakeet_set_num_threads);
    std.mem.doNotOptimizeAway(&c.zarakeet_shutdown_backend);
    // gguf
    std.mem.doNotOptimizeAway(&c.gguf_init_from_file);
    std.mem.doNotOptimizeAway(&c.gguf_init_empty);
    std.mem.doNotOptimizeAway(&c.gguf_free);
    std.mem.doNotOptimizeAway(&c.gguf_find_key);
    std.mem.doNotOptimizeAway(&c.gguf_get_kv_type);
    std.mem.doNotOptimizeAway(&c.gguf_get_val_str);
    std.mem.doNotOptimizeAway(&c.gguf_get_val_bool);
    std.mem.doNotOptimizeAway(&c.gguf_set_val_str);
    std.mem.doNotOptimizeAway(&c.gguf_set_val_bool);
    std.mem.doNotOptimizeAway(&c.gguf_write_to_file);
}

test "setNumThreads and shutdown without models" {
    setNumThreads(4);
    setNumThreads(0);
    shutdown();
    shutdown();
}

test "load nonexistent" {
    const err = Model.load("/nonexistent.gguf") catch |e| e;
    try std.testing.expectError(error.LoadFailed, err);
}

// --- Gate table (section 1.2) ---

const Expected = enum { tdt, nemotron, unsupported };

const GateCase = struct {
    arch: ?[*:0]const u8,
    prompt_present: ?bool,
    expected: Expected,
};

const gate_cases = [_]GateCase{
    .{ .arch = "tdt", .prompt_present = null, .expected = .tdt },
    .{ .arch = "tdt", .prompt_present = true, .expected = .tdt },
    .{ .arch = "hybrid_tdt_ctc", .prompt_present = null, .expected = .tdt },
    .{ .arch = "rnnt", .prompt_present = true, .expected = .nemotron },
    .{ .arch = "rnnt", .prompt_present = null, .expected = .unsupported },
    .{ .arch = "rnnt", .prompt_present = false, .expected = .unsupported },
    .{ .arch = "hybrid_rnnt_ctc", .prompt_present = null, .expected = .unsupported },
    .{ .arch = "ctc", .prompt_present = null, .expected = .unsupported },
    .{ .arch = null, .prompt_present = null, .expected = .unsupported },
};

/// Allocate a NUL-terminated copy of `s`.
fn toCStr(allocator: Allocator, s: []const u8) Error![:0]u8 {
    const buf = try allocator.alloc(u8, s.len + 1);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

fn checkGate(allocator: Allocator, tmp: *std.testing.TmpDir, index: usize, tc: GateCase) !void {
    var base_buf: [4096]u8 = undefined;
    const base_len = tmp.dir.realPath(std.testing.io, &base_buf) catch return error.TestUnexpectedResult;
    const base = base_buf[0..base_len];
    var fname_buf: [64]u8 = undefined;
    const fname = std.fmt.bufPrint(&fname_buf, "gate_{d}.gguf", .{index}) catch return error.TestUnexpectedResult;
    const full = std.fs.path.join(allocator, &.{ base, fname }) catch return error.OutOfMemory;
    defer allocator.free(full);
    const cpath = try toCStr(allocator, full);
    defer allocator.free(cpath);

    // Build the synthetic GGUF.
    const ctx = c.gguf_init_empty() orelse return error.LoadFailed;
    defer c.gguf_free(ctx);
    if (tc.arch) |a| c.gguf_set_val_str(ctx, "parakeet.arch", a);
    if (tc.prompt_present) |pp| c.gguf_set_val_bool(ctx, "parakeet.prompt.present", pp);
    if (!c.gguf_write_to_file(ctx, cpath.ptr, true)) return error.TestUnexpectedResult;

    switch (tc.expected) {
        .tdt, .nemotron => {
            const kind = detectKind(cpath) catch |e| {
                std.debug.print("gate case {d}: expected success, got {any}\n", .{ index, e });
                return error.TestUnexpectedResult;
            };
            const want = if (tc.expected == .tdt) Kind.tdt else Kind.nemotron;
            try std.testing.expectEqual(want, kind);
        },
        .unsupported => {
            const err = detectKind(cpath) catch |e| e;
            try std.testing.expectError(error.UnsupportedModel, err);
        },
    }
}

test "gate table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (gate_cases, 0..) |tc, i| {
        try checkGate(std.testing.allocator, &tmp, i, tc);
    }
}

// --- cleanText (no model needed) ---

const CleanCase = struct { input: []const u8, expected: []const u8 };

test "cleanText offline" {
    const allocator = std.testing.allocator;
    const cases = [_]CleanCase{
        .{ .input = "Well.  It is. ", .expected = "Well. It is." },
        .{ .input = "eyes. <en-US> It", .expected = "eyes. It" },
        .{ .input = "<en-US>", .expected = "" },
        .{ .input = "  a <unk> b  ", .expected = "a b" },
        .{ .input = "5 < 6 > 4", .expected = "5 < 6 > 4" },
        .{ .input = "x <not a tag> y", .expected = "x <not a tag> y" },
    };
    for (cases) |case| {
        var st = Clean{};
        const out = try cleanText(allocator, case.input, &st, true);
        defer allocator.free(out);
        try std.testing.expectEqualStrings(case.expected, out);
    }
}

test "cleanText stream sequence" {
    const allocator = std.testing.allocator;
    var st = Clean{};
    const chunks = [_][]const u8{
        "Well, I", " don't", " eyes. <en-US>", "", " It is", " portrait. <en-US>",
    };
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(allocator);
    for (chunks) |chunk| {
        const out = try cleanText(allocator, chunk, &st, false);
        defer allocator.free(out);
        // No chunk ends with a space, and no chunk contains a double space.
        if (out.len > 0) {
            try std.testing.expect(out[out.len - 1] != ' ');
        }
        try std.testing.expect(std.mem.indexOf(u8, out, "  ") == null);
        try combined.appendSlice(allocator, out);
    }
    const final = try cleanText(allocator, "", &st, true);
    defer allocator.free(final);
    try std.testing.expectEqualStrings("Well, I don't eyes. It is portrait.", combined.items);
}

// ---------------------------------------------------------------------------
// Model integration tests (need downloaded models; see doc/WORKER_PLAN.md stage 7).
// Each skips (error.SkipZigTest) when its env var is unset.
// ---------------------------------------------------------------------------

/// Test-only: read an env var as a NUL-terminated string, or null if unset/empty.
fn envCStr(name: [*:0]const u8) ?[:0]const u8 {
    const p = std.c.getenv(name) orelse return null;
    const s = std.mem.span(p);
    if (s.len == 0) return null;
    return s;
}

/// Test-only: minimal RIFF WAV reader (16-bit PCM, mono, 16 kHz).
fn readWavPcm(allocator: Allocator, data: []const u8) error{ InvalidWav, OutOfMemory }![]f32 {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE"))
        return error.InvalidWav;
    var i: usize = 12;
    var fmt_ok = false;
    var data_start: usize = 0;
    var data_len: usize = 0;
    var have_data = false;
    while (i + 8 <= data.len) {
        const id = data[i .. i + 4];
        const chunk_size = std.mem.readInt(u32, &.{ data[i + 4], data[i + 5], data[i + 6], data[i + 7] }, .little);
        const body = i + 8;
        if (body + chunk_size > data.len) return error.InvalidWav;
        if (std.mem.eql(u8, id, "fmt ")) {
            const b = data[body .. body + chunk_size];
            if (b.len < 16) return error.InvalidWav;
            const audio_format = std.mem.readInt(u16, &.{ b[0], b[1] }, .little);
            const channels = std.mem.readInt(u16, &.{ b[2], b[3] }, .little);
            const sample_rate = std.mem.readInt(u32, &.{ b[4], b[5], b[6], b[7] }, .little);
            const bits = std.mem.readInt(u16, &.{ b[14], b[15] }, .little);
            if (audio_format != 1 or channels != 1 or sample_rate != 16000 or bits != 16)
                return error.InvalidWav;
            fmt_ok = true;
        } else if (std.mem.eql(u8, id, "data")) {
            data_start = body;
            data_len = chunk_size;
            have_data = true;
        }
        i = body + chunk_size;
        if (chunk_size % 2 != 0) i += 1;
    }
    if (!fmt_ok or !have_data) return error.InvalidWav;
    const n_samples = data_len / 2;
    const out = try allocator.alloc(f32, n_samples);
    for (out, 0..) |*o, s| {
        const raw = std.mem.readInt(i16, &.{ data[data_start + s * 2], data[data_start + s * 2 + 1] }, .little);
        o.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }
    return out;
}

/// Test-only: read and parse a WAV file to 16 kHz mono float PCM.
fn loadWavPcm(allocator: Allocator, path: [:0]const u8) ![]f32 {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(std.testing.io, path, allocator, std.Io.Limit.unlimited);
    defer allocator.free(bytes);
    return readWavPcm(allocator, bytes);
}

test "tdt integration" {
    const allocator = std.testing.allocator;
    const model_path = envCStr("ZARAKEET_TDT_MODEL") orelse return error.SkipZigTest;
    const wav_path = envCStr("ZARAKEET_WAV") orelse return error.SkipZigTest;

    var model = try Model.load(model_path);
    defer model.deinit();

    const pcm = try loadWavPcm(allocator, wav_path);
    defer allocator.free(pcm);

    // transcribeFile returns non-empty text.
    const text = try model.transcribeFile(allocator, wav_path, .{});
    defer allocator.free(text);
    try std.testing.expect(text.len > 0);

    // transcribePcm on the same WAV returns identical text.
    const pcm_text = try model.transcribePcm(allocator, pcm, 16000, .{});
    defer allocator.free(pcm_text);
    try std.testing.expectEqualStrings(text, pcm_text);

    // transcribePcmJson starts with { and contains "words".
    const pcm_json = try model.transcribePcmJson(allocator, pcm, 16000, .{});
    defer allocator.free(pcm_json);
    try std.testing.expect(pcm_json.len > 0 and pcm_json[0] == '{');
    try std.testing.expect(std.mem.indexOf(u8, pcm_json, "\"words\"") != null);

    // transcribeFileJson contains "words".
    const file_json = try model.transcribeFileJson(allocator, wav_path);
    defer allocator.free(file_json);
    try std.testing.expect(std.mem.indexOf(u8, file_json, "\"words\"") != null);

    // A TDT model is not a streaming model.
    const stream_err = model.stream(.{}) catch |e| e;
    try std.testing.expectError(error.NotStreamingModel, stream_err);
}

test "nemotron integration" {
    const allocator = std.testing.allocator;
    const model_path = envCStr("ZARAKEET_NEMOTRON_MODEL") orelse return error.SkipZigTest;
    const wav_path = envCStr("ZARAKEET_WAV") orelse return error.SkipZigTest;

    var model = try Model.load(model_path);
    defer model.deinit();
    try std.testing.expectEqual(Kind.nemotron, model.kind);

    const pcm = try loadWavPcm(allocator, wav_path);
    defer allocator.free(pcm);

    // transcribeFile with .lang = "en" returns clean text: no '<', no double
    // space, no leading/trailing space, and exactly the nemotron reference
    // line from example/out.txt.
    const text = try model.transcribeFile(allocator, wav_path, .{ .lang = "en" });
    defer allocator.free(text);
    try std.testing.expect(text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "<") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  ") == null);
    try std.testing.expect(text[0] != ' ');
    try std.testing.expect(text[text.len - 1] != ' ');
    try std.testing.expectEqualStrings(
        "Well, I don't wish to see it any more, observed Phoebe, turning away her eyes. It is certainly very like the old portrait.",
        text);

    // Streaming: feed in 1600-sample chunks, concatenate feed + finalize.
    var stream = try model.stream(.{ .lang = "en" });
    defer stream.deinit();
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(allocator);
    const chunk: usize = 1600;
    var offset: usize = 0;
    while (offset < pcm.len) : (offset += chunk) {
        const end = @min(offset + chunk, pcm.len);
        const piece = try stream.feed(allocator, pcm[offset..end]);
        try combined.appendSlice(allocator, piece);
        allocator.free(piece);
    }
    const final = try stream.finalize(allocator);
    try combined.appendSlice(allocator, final);
    allocator.free(final);
    try std.testing.expect(combined.items.len > 0);

    // The concatenated stream text is clean too, and equals the offline text.
    // Holds for this clip; upstream emits the same sentences per path.
    try std.testing.expect(std.mem.indexOf(u8, combined.items, "<") == null);
    try std.testing.expect(std.mem.indexOf(u8, combined.items, "  ") == null);
    try std.testing.expect(combined.items[0] != ' ');
    try std.testing.expect(combined.items[combined.items.len - 1] != ' ');
    try std.testing.expectEqualStrings(text, combined.items);

    // Drain events; just print the count (no assertion).
    const events = try stream.drainEvents(allocator);
    std.debug.print("nemotron: drained {d} events\n", .{events.len});
    allocator.free(events);

    // JSON stays raw: in a separate stream, at least one feedJson chunk must
    // still contain the <en-US> tag.
    var jstream = try model.stream(.{ .lang = "en" });
    defer jstream.deinit();
    var saw_tag = false;
    var printed = false;
    offset = 0;
    while (offset < pcm.len) : (offset += chunk) {
        const end = @min(offset + chunk, pcm.len);
        const piece = try jstream.feedJson(allocator, pcm[offset..end]);
        if (std.mem.indexOf(u8, piece, "<en-US>") != null) {
            saw_tag = true;
            if (!printed) {
                printed = true;
                std.debug.print("nemotron raw feedJson with tag: {s}\n", .{piece});
            }
        }
        allocator.free(piece);
    }
    try std.testing.expect(saw_tag);

    // An invalid locale fails with a non-empty last error.
    const err = model.transcribeFile(allocator, wav_path, .{ .lang = "xx-invalid" }) catch |e| e;
    try std.testing.expectError(error.TranscribeFailed, err);
    const le = model.lastError();
    try std.testing.expect(le.len > 0);
}

test "ctc integration (unsupported)" {
    const model_path = envCStr("ZARAKEET_CTC_MODEL") orelse return error.SkipZigTest;
    const err = Model.load(model_path) catch |e| e;
    try std.testing.expectError(error.UnsupportedModel, err);
}

test "shutdown and reload" {
    const allocator = std.testing.allocator;
    const model_path = envCStr("ZARAKEET_TDT_MODEL") orelse return error.SkipZigTest;
    const wav_path = envCStr("ZARAKEET_WAV") orelse return error.SkipZigTest;

    setNumThreads(2);

    var model = try Model.load(model_path);
    const first = try model.transcribeFile(allocator, wav_path, .{});
    model.deinit();

    shutdown();

    // Loading again re-creates the backend; the text must be identical.
    var model2 = try Model.load(model_path);
    const second = try model2.transcribeFile(allocator, wav_path, .{});
    model2.deinit();

    try std.testing.expectEqualStrings(first, second);
    allocator.free(first);
    allocator.free(second);

    shutdown();
    setNumThreads(0);
}