const std = @import("std");
const zarakeet = @import("zarakeet");

// Benchmark: transcribes example/speech.wav with the two TDT models in
// example/ (offline) and with nemotron (offline and streaming). Per result
// it prints a result line "<key>: <text>" (keys and texts in
// example/out.txt) immediately followed by a timing line (load, transcribe,
// real-time factor); the streaming run additionally prints partial lines
// '  [X.Xs] +"<text>"' as text arrives, and the event count after the
// timing line.
//
// With --fleurs it additionally transcribes the 14 multilingual clips in
// example/fleurs/ (rows of refs.tsv) with the two multilingual models, one
// line per clip: FLEURS\t<model basename>\t<file>\t<text> (no timing lines).
//
// Run from the repo root: zig build bench [-- --fleurs]
const chunk_samples: usize = 8000; // 0.5 s of 16 kHz audio per stream feed

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const io = init.io;
    const stdout = std.Io.File.stdout();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var fleurs = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--fleurs")) {
            fleurs = true;
        } else {
            const stderr = std.Io.File.stderr();
            try std.Io.File.writeStreamingAll(stderr, io, "usage: zarakeet-bench [--fleurs]\n");
            std.process.exit(2);
        }
    }

    const wav: [:0]const u8 = "example/speech.wav";
    const nemotron: [:0]const u8 = "example/nemotron-3.5-asr-streaming-0.6b-q4_k.gguf";
    const models = [_][:0]const u8{
        "example/tdt-0.6b-v3-q4_k.gguf",
        "example/tdt-1.1b-q4_k.gguf",
        nemotron,
    };

    const wavdata = try readWav(io, gpa, wav);
    defer gpa.free(wavdata.pcm);
    const audio_secs = wavdata.seconds;

    for (models) |model_path| {
        const t0 = std.Io.Clock.Timestamp.now(io, .boot);
        var model = try zarakeet.Model.load(model_path);
        const t1 = std.Io.Clock.Timestamp.now(io, .boot);
        const text = try model.transcribeFile(gpa, wav, .{});
        const t2 = std.Io.Clock.Timestamp.now(io, .boot);
        model.deinit();

        const load_secs = secs(t0.durationTo(t1));
        const trans_secs = secs(t1.durationTo(t2));
        const rtf = trans_secs / audio_secs;

        const line = try std.fmt.allocPrint(gpa, "{s}: {s}\n", .{ std.fs.path.basename(model_path), text });
        gpa.free(text);
        try std.Io.File.writeStreamingAll(stdout, io, line);
        gpa.free(line);
        const perf = try std.fmt.allocPrint(gpa,
            "  load {d:.3}s | transcribe {d:.3}s for {d:.2}s audio | RTF {d:.3} ({d:.1}x faster than real-time)\n",
            .{ load_secs, trans_secs, audio_secs, rtf, audio_secs / trans_secs });
        try std.Io.File.writeStreamingAll(stdout, io, perf);
        gpa.free(perf);
    }

    // Streaming: feed the same audio to nemotron in 0.5 s chunks, as fast as
    // possible (not paced in real time). Time only the feed/finalize calls.
    const t0 = std.Io.Clock.Timestamp.now(io, .boot);
    var model = try zarakeet.Model.load(nemotron);
    const t1 = std.Io.Clock.Timestamp.now(io, .boot);
    var stream = try model.stream(.{});

    var trans_secs: f64 = 0;
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(gpa);
    var offset: usize = 0;
    while (offset < wavdata.pcm.len) : (offset += chunk_samples) {
        const end = @min(offset + chunk_samples, wavdata.pcm.len);
        const c0 = std.Io.Clock.Timestamp.now(io, .boot);
        const piece = try stream.feed(gpa, wavdata.pcm[offset..end]);
        const c1 = std.Io.Clock.Timestamp.now(io, .boot);
        trans_secs += secs(c0.durationTo(c1));
        if (piece.len > 0) {
            const line = try std.fmt.allocPrint(gpa, "  [{d:.1}s] +\"{s}\"\n", .{ @as(f64, @floatFromInt(end)) / 16000.0, piece });
            try std.Io.File.writeStreamingAll(stdout, io, line);
            gpa.free(line);
        }
        try combined.appendSlice(gpa, piece);
        gpa.free(piece);
    }
    const c0 = std.Io.Clock.Timestamp.now(io, .boot);
    const final = try stream.finalize(gpa);
    const c1 = std.Io.Clock.Timestamp.now(io, .boot);
    trans_secs += secs(c0.durationTo(c1));
    if (final.len > 0) {
        const line = try std.fmt.allocPrint(gpa, "  [{d:.1}s] +\"{s}\"\n", .{ audio_secs, final });
        try std.Io.File.writeStreamingAll(stdout, io, line);
        gpa.free(line);
    }
    try combined.appendSlice(gpa, final);
    gpa.free(final);

    const load_secs = secs(t0.durationTo(t1));
    const rtf = trans_secs / audio_secs;

    const line = try std.fmt.allocPrint(gpa, "{s} (stream): {s}\n", .{ std.fs.path.basename(nemotron), combined.items });
    try std.Io.File.writeStreamingAll(stdout, io, line);
    gpa.free(line);
    const perf = try std.fmt.allocPrint(gpa,
        "  load {d:.3}s | transcribe {d:.3}s for {d:.2}s audio | RTF {d:.3} ({d:.1}x faster than real-time)\n",
        .{ load_secs, trans_secs, audio_secs, rtf, audio_secs / trans_secs });
    try std.Io.File.writeStreamingAll(stdout, io, perf);
    gpa.free(perf);

    const events = try stream.drainEvents(gpa);
    const evline = try std.fmt.allocPrint(gpa, "  eou/eob events: {d}\n", .{events.len});
    try std.Io.File.writeStreamingAll(stdout, io, evline);
    gpa.free(evline);
    gpa.free(events);

    stream.deinit();
    model.deinit();

    if (fleurs) {
        // Multilingual WER input: one FLEURS line per clip, no timing lines.
        // Plain-text results never contain tabs or newlines (cleanText
        // normalizes whitespace), so each line is safe to split on '\t'.
        const refs = try std.Io.Dir.cwd().readFileAlloc(io, "example/fleurs/refs.tsv", gpa, std.Io.Limit.unlimited);
        defer gpa.free(refs);
        const bench_models = [_][:0]const u8{
            "example/tdt-0.6b-v3-q4_k.gguf",
            "example/nemotron-3.5-asr-streaming-0.6b-q4_k.gguf",
        };
        for (bench_models) |model_path| {
            var m = try zarakeet.Model.load(model_path);
            var lines = std.mem.splitScalar(u8, refs, '\n');
            var first = true;
            while (lines.next()) |row| {
                if (first) {
                    first = false;
                    continue; // header
                }
                if (row.len == 0) continue;
                const file = std.mem.sliceTo(row, '\t');
                const joined = try std.fs.path.join(gpa, &.{ "example/fleurs", file });
                const wav_path: [:0]const u8 = try gpa.dupeZ(u8, joined);
                gpa.free(joined);
                defer gpa.free(wav_path);
                const text = try m.transcribeFile(gpa, wav_path, .{});
                defer gpa.free(text);
                const out = try std.fmt.allocPrint(gpa, "FLEURS\t{s}\t{s}\t{s}\n", .{ std.fs.path.basename(model_path), file, text });
                try std.Io.File.writeStreamingAll(stdout, io, out);
                gpa.free(out);
            }
            m.deinit();
        }
    }

    // Recommended exit: free the process-global backend after every model
    // and stream has been deinitialized.
    zarakeet.shutdown();
}

fn secs(d: std.Io.Clock.Duration) f64 {
    return @as(f64, @floatFromInt(d.raw.nanoseconds)) / 1e9;
}

/// Read a 16 kHz mono 16-bit PCM WAV file; returns float samples in [-1, 1]
/// and the audio duration in seconds. The caller frees pcm.
fn readWav(io: std.Io, gpa: std.mem.Allocator, path: [:0]const u8) !struct {
    pcm: []f32,
    seconds: f64,
} {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.unlimited);
    defer gpa.free(data);
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
    const pcm = try gpa.alloc(f32, n_samples);
    for (pcm, 0..) |*o, s| {
        const raw = std.mem.readInt(i16, &.{ data[data_start + s * 2], data[data_start + s * 2 + 1] }, .little);
        o.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }
    return .{ .pcm = pcm, .seconds = @as(f64, @floatFromInt(n_samples)) / 16000.0 };
}