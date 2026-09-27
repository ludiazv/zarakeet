const std = @import("std");
const zarakeet = @import("zarakeet");

// zarakeet-cli: transcribe a WAV file offline with a zarakeet model.
//
//   zarakeet-cli <model.gguf> <file.wav>
//
// Prints only the transcript (plus a newline) to stdout, so the output can
// be piped; parakeet/ggml log lines go to stderr.
// Exit codes: 0 ok, 1 error, 2 usage.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        const stderr = std.Io.File.stderr();
        try std.Io.File.writeStreamingAll(stderr, init.io, "usage: zarakeet-cli <model.gguf> <file.wav>\n");
        std.process.exit(2);
    }
    const model_path: [:0]const u8 = args[1];
    const wav_path: [:0]const u8 = args[2];

    // Defers run in reverse order: free the text, deinit the model, then
    // shut down the process-global backend.
    defer zarakeet.shutdown();
    var model = zarakeet.Model.load(model_path) catch |err| {
        const stderr = std.Io.File.stderr();
        const msg = if (err == error.UnsupportedModel)
            try std.fmt.allocPrint(init.arena.allocator(), "error: unsupported model '{s}' (supported: TDT models and nemotron-3.5-asr-streaming-0.6b)\n", .{model_path})
        else
            try std.fmt.allocPrint(init.arena.allocator(), "error: cannot load model '{s}'\n", .{model_path});
        try std.Io.File.writeStreamingAll(stderr, init.io, msg);
        std.process.exit(1);
    };
    defer model.deinit();

    const text = model.transcribeFile(init.gpa, wav_path, .{}) catch |err| {
        if (err == error.TranscribeFailed) {
            const stderr = std.Io.File.stderr();
            const msg = try std.fmt.allocPrint(init.arena.allocator(), "error: transcription failed: {s}\n", .{model.lastError()});
            try std.Io.File.writeStreamingAll(stderr, init.io, msg);
            std.process.exit(1);
        }
        return err;
    };
    defer init.gpa.free(text);

    const stdout = std.Io.File.stdout();
    try std.Io.File.writeStreamingAll(stdout, init.io, text);
    try std.Io.File.writeStreamingAll(stdout, init.io, "\n");
}