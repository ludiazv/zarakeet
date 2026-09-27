const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vulkan = b.option(bool, "vulkan", "Build the ggml Vulkan backend (requires glslc)") orelse false;
    const glslc = b.option([]const u8, "glslc", "Path to the glslc binary for Vulkan shader generation") orelse "glslc";
    const vulkan_require_all = b.option(bool, "vulkan-require-all",
        "Fail the build unless glslc supports every optional Vulkan shader feature (use for portable release builds)") orelse false;

    if (vulkan_require_all and !vulkan) std.process.fatal("-Dvulkan-require-all requires -Dvulkan=true", .{});

    if (vulkan and target.result.os.tag.isDarwin()) std.process.fatal(
        "-Dvulkan=true is not supported for macOS targets (Vulkan there needs MoltenVK; the GPU path on macOS would be Metal, which is out of scope). Build without -Dvulkan.",
        .{},
    );

    const ggml_dep = b.dependency("ggml", .{});
    const parakeet_dep = b.dependency("parakeet_cpp", .{});

    // Upstream ggml/parakeet C code performs null-pointer arithmetic (legal in
    // C, e.g. ggml_graph_nbytes walks from a null pointer to size a graph)
    // that Zig's Debug safety checks reject at runtime, and 0.16 has no
    // per-module no_safety. All Release* modes have safety off, so when the
    // user requests Debug, build the frozen upstream C/C++ with ReleaseFast.
    const c_optimize = switch (optimize) {
        .Debug => .ReleaseFast,
        else => optimize,
    };

    const module = b.createModule(.{
        .target = target,
        .optimize = c_optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Include paths (ggml).
    module.addIncludePath(ggml_dep.path("include"));
    module.addIncludePath(ggml_dep.path("src"));
    module.addIncludePath(ggml_dep.path("src/ggml-cpu"));

    // Include paths (parakeet).
    module.addIncludePath(parakeet_dep.path("include"));
    module.addIncludePath(parakeet_dep.path("src"));
    module.addIncludePath(parakeet_dep.path("third_party"));

    // C macros. Note: addCMacro emits -DNAME=value, so bare upstream macros
    // (value 1 per C standard 5.1.1.2.1) are passed with an explicit "1".
    module.addCMacro("GGML_USE_CPU", "1");
    module.addCMacro("GGML_USE_LLAMAFILE", "1");
    module.addCMacro("GGML_SCHED_MAX_COPIES", "4");
    module.addCMacro("GGML_VERSION", "\"0.13.0\"");
    module.addCMacro("GGML_COMMIT", "\"e705c5f\"");
    module.addCMacro("PARAKEET_VERSION", "\"0.0.1\"");
    if (target.result.os.tag == .linux) {
        module.addCMacro("_GNU_SOURCE", "1");
        module.addCMacro("_XOPEN_SOURCE", "600");
    }

    // ggml C sources.
    module.addCSourceFiles(.{
        .root = ggml_dep.path(""),
        .files = &.{
            "src/ggml.c",
            "src/ggml-alloc.c",
            "src/ggml-quants.c",
            "src/ggml-cpu/ggml-cpu.c",
            "src/ggml-cpu/quants.c",
        },
        .flags = &.{ "-std=c11" },
    });

    // ggml C++ sources.
    module.addCSourceFiles(.{
        .root = ggml_dep.path(""),
        .files = &.{
            "src/ggml.cpp",
            "src/ggml-backend.cpp",
            "src/ggml-backend-dl.cpp",
            "src/ggml-backend-reg.cpp",
            "src/ggml-backend-meta.cpp",
            "src/ggml-opt.cpp",
            "src/ggml-threading.cpp",
            "src/gguf.cpp",
            "src/ggml-cpu/ggml-cpu.cpp",
            "src/ggml-cpu/repack.cpp",
            "src/ggml-cpu/hbm.cpp",
            "src/ggml-cpu/traits.cpp",
            "src/ggml-cpu/binary-ops.cpp",
            "src/ggml-cpu/unary-ops.cpp",
            "src/ggml-cpu/vec.cpp",
            "src/ggml-cpu/ops.cpp",
            "src/ggml-cpu/amx/amx.cpp",
            "src/ggml-cpu/amx/mmq.cpp",
            "src/ggml-cpu/llamafile/sgemm.cpp",
        },
        .flags = &.{ "-std=c++17" },
    });

    // ggml arch-specific sources.
    switch (target.result.cpu.arch) {
        .x86_64 => {
            module.addCSourceFiles(.{
                .root = ggml_dep.path(""),
                .files = &.{ "src/ggml-cpu/arch/x86/quants.c" },
                .flags = &.{ "-std=c11" },
            });
            module.addCSourceFiles(.{
                .root = ggml_dep.path(""),
                .files = &.{ "src/ggml-cpu/arch/x86/repack.cpp" },
                .flags = &.{ "-std=c++17" },
            });
        },
        .aarch64 => {
            module.addCSourceFiles(.{
                .root = ggml_dep.path(""),
                .files = &.{ "src/ggml-cpu/arch/arm/quants.c" },
                .flags = &.{ "-std=c11" },
            });
            module.addCSourceFiles(.{
                .root = ggml_dep.path(""),
                .files = &.{ "src/ggml-cpu/arch/arm/repack.cpp" },
                .flags = &.{ "-std=c++17" },
            });
        },
        else => std.process.fatal("unsupported target CPU architecture '{s}' (supported: x86_64, aarch64)", .{@tagName(target.result.cpu.arch)}),
    }

    // parakeet C++ sources (exact PARAKEET_SRC list from upstream CMakeLists.txt).
    module.addCSourceFiles(.{
        .root = parakeet_dep.path(""),
        .files = &.{
            "src/parakeet.cpp",
            "src/model.cpp",
            "src/parakeet_capi.cpp",
            "src/common.cpp",
            "src/audio_io.cpp",
            "src/transcription_json.cpp",
            "src/model_loader.cpp",
            "src/backend.cpp",
            "src/ggml_graph.cpp",
            "src/fft.cpp",
            "src/mel.cpp",
            "src/mel_gpu.cpp",
            "src/subsampling.cpp",
            "src/relpos_attention.cpp",
            "src/conformer.cpp",
            "src/pos_enc.cpp",
            "src/encoder.cpp",
            "src/streaming_encoder.cpp",
            "src/streaming.cpp",
            "src/ctc_decoder.cpp",
            "src/prediction.cpp",
            "src/joint.cpp",
            "src/prompt_kernel.cpp",
            "src/tdt.cpp",
            "src/rnnt.cpp",
            "src/transducer_batch.cpp",
            "src/tokenizer.cpp",
            "src/search.cpp",
            "src/transcription.cpp",
        },
        .flags = &.{ "-std=c++17" },
    });

    // zarakeet shim: extern "C" wrappers for two pk:: functions that
    // parakeet_capi.h does not expose (src/shim.cpp, our repo).
    module.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{ "shim.cpp" },
        .flags = &.{ "-std=c++17" },
    });

    var vk_implib: ?std.Build.LazyPath = null;

    // Vulkan backend (opt-in via -Dvulkan=true).
    if (vulkan) {
        const vulkan_headers_dep = b.lazyDependency("vulkan_headers", .{}) orelse
            @panic("vulkan_headers dependency missing from build.zig.zon");
        const spirv_headers_dep = b.lazyDependency("spirv_headers", .{}) orelse
            @panic("spirv_headers dependency missing from build.zig.zon");

        // Configure-time glslc feature probes (same command as upstream
        // CMake test_shader_extension_support): define the macro when glslc
        // compiles the feature-test shader with exit code 0.
        var io_instance = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer io_instance.deinit();
        const io = io_instance.io();
        const gpa = std.heap.page_allocator;

        // Resolve glslc to an absolute path. The per-shader steps run the
        // generator with a minimal environment, and the generator launches
        // glslc via execvp, which searches only that environment's PATH:
        // with a bare name, any session whose PATH lacks glslc would fail
        // every shader step. (Worse, the upstream generator ignores glslc's
        // exit status and exits 0 even when glslc cannot run, so Zig would
        // cache the hollow .cpp output as a success and only fail much
        // later, at link time, with thousands of undefined shader symbols.)
        // If -Dglslc has no '/', search the parent PATH; otherwise fail at
        // configure time.
        const glslc_path: []const u8 = if (std.mem.indexOfScalar(u8, glslc, '/') != null)
            glslc
        else blk: {
            var found: ?[]const u8 = null;
            var splitter = std.mem.splitScalar(u8, b.graph.environ_map.get("PATH") orelse "", ':');
            while (splitter.next()) |dir| {
                if (dir.len == 0) continue;
                const candidate = std.fs.path.join(gpa, &.{ dir, "glslc" }) catch @panic("OOM");
                const res = std.process.run(gpa, io, .{ .argv = &.{ candidate, "--version" } }) catch continue;
                const ok = switch (res.term) {
                    .exited => |code| code == 0,
                    else => false,
                };
                if (ok) {
                    found = candidate;
                    break;
                }
            }
            const f = found orelse std.process.fatal("glslc not found in PATH — install glslc (shaderc) or pass -Dglslc=PATH", .{});
            break :blk f;
        };

        // glslc --version: kept as the version string and fed to every shader
        // step as a cache-only input (environment variable, which the build
        // system hashes into the step's cache key), so the shaders are
        // regenerated when glslc changes.
        const version_result = std.process.run(gpa, io, .{ .argv = &.{ glslc_path, "--version" } }) catch |err| std.process.fatal(
            "cannot run glslc ('{s}'): {s} — install glslc (shaderc) or pass -Dglslc=PATH",
            .{ glslc_path, @errorName(err) },
        );
        const version_ok = switch (version_result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!version_ok) std.process.fatal("cannot run glslc ('{s}'): {s} — install glslc (shaderc) or pass -Dglslc=PATH", .{ glslc_path, "non-zero exit from --version" });
        const glslc_version = version_result.stdout;

        const FeatureTest = struct { file: []const u8, macro: []const u8 };
        const feature_tests: []const FeatureTest = &.{
            .{ .file = "coopmat.comp", .macro = "GGML_VULKAN_COOPMAT_GLSLC_SUPPORT" },
            .{ .file = "coopmat2.comp", .macro = "GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT" },
            .{ .file = "integer_dot.comp", .macro = "GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT" },
            .{ .file = "bfloat16.comp", .macro = "GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT" },
        };
        var macros = std.ArrayList([]const u8).empty;
        defer macros.deinit(gpa);
        var missing = std.ArrayList([]const u8).empty;
        defer missing.deinit(gpa);
        for (feature_tests) |ft| {
            const sub = std.fs.path.join(gpa, &.{ "src/ggml-vulkan/vulkan-shaders/feature-tests", ft.file }) catch @panic("OOM");
            const cache_path = ggml_dep.path(sub).getPath3(b, null);
            const test_path = cache_path.joinString(gpa, "") catch @panic("OOM");
            const argv = [_][]const u8{ glslc_path, "-o", "-", "-fshader-stage=compute", "--target-env=vulkan1.3", test_path };
            const result = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| std.process.fatal(
                "cannot run glslc ('{s}'): {s} — install glslc (shaderc) or pass -Dglslc=PATH",
                .{ glslc_path, @errorName(err) },
            );
            const ok = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (ok) {
                macros.append(gpa, ft.macro) catch @panic("OOM");
            } else {
                missing.append(gpa, ft.macro) catch @panic("OOM");
                std.debug.print("glslc: {s} not supported (shaders for it are skipped)\n", .{ft.macro});
            }
        }

        if (vulkan_require_all and missing.items.len > 0) {
            var msg = std.ArrayList(u8).empty;
            defer msg.deinit(gpa);
            msg.print(gpa, "-Dvulkan-require-all: glslc cannot compile all optional Vulkan shader features.\n", .{}) catch @panic("OOM");
            msg.print(gpa, "glslc: {s}\n", .{glslc_path}) catch @panic("OOM");
            msg.print(gpa, "glslc version:\n", .{}) catch @panic("OOM");
            var version_split = std.mem.splitScalar(u8, glslc_version, '\n');
            while (version_split.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                msg.print(gpa, "  {s}\n", .{trimmed}) catch @panic("OOM");
            }
            msg.print(gpa, "missing features:\n", .{}) catch @panic("OOM");
            for (missing.items) |m| msg.print(gpa, "  {s}\n", .{m}) catch @panic("OOM");
            msg.print(gpa, "Use a newer glslc (e.g. from a current Vulkan SDK) via -Dglslc=PATH, or drop -Dvulkan-require-all.\n", .{}) catch @panic("OOM");
            std.process.fatal("{s}", .{msg.items});
        }

        // Host tool: vulkan-shaders-gen (built for the host, not installed).
        const gen_mod = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .link_libcpp = true,
        });
        for (macros.items) |m| gen_mod.addCMacro(m, "1");
        gen_mod.addCSourceFiles(.{
            .root = ggml_dep.path(""),
            .files = &.{ "src/ggml-vulkan/vulkan-shaders/vulkan-shaders-gen.cpp" },
            .flags = &.{ "-std=c++17" },
        });
        const gen_tool = b.addExecutable(.{
            .name = "vulkan-shaders-gen",
            .root_module = gen_mod,
        });

        // Step 1: generate the shader header (header mode; no glslc runs).
        const gen_header = b.addRunArtifact(gen_tool);
        gen_header.addArg("--output-dir");
        _ = gen_header.addOutputDirectoryArg("vulkan-shaders.spv");
        gen_header.addArg("--target-hpp");
        const hpp = gen_header.addOutputFileArg("ggml-vulkan-shaders.hpp");

        // Step 2: one run step per .comp template (listed at configure time),
        // each generating the .cpp that embeds that template's shader bytes.
        const shaders_dir = ggml_dep.path("src/ggml-vulkan/vulkan-shaders");
        const dir_path = shaders_dir.getPath3(b, null).joinString(gpa, "") catch @panic("OOM");
        const dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| std.debug.panic("failed to open vulkan-shaders dir: {s}", .{@errorName(err)});
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch |err| std.debug.panic("vulkan-shaders dir iterate: {s}", .{@errorName(err)})) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".comp")) continue;
            const run = b.addRunArtifact(gen_tool);
            run.addArg("--glslc");
            run.addArg(glslc_path);
            run.addArg("--source");
            run.addPrefixedFileArg("", shaders_dir.path(b, entry.name));
            run.addArg("--output-dir");
            _ = run.addOutputDirectoryArg("spv");
            run.addArg("--target-hpp");
            run.addPrefixedFileArg("", hpp);
            run.addArg("--target-cpp");
            const cpp_name = std.mem.concat(gpa, u8, &.{ entry.name, ".cpp" }) catch @panic("OOM");
            const cpp = run.addOutputFileArg(cpp_name);
            // glslc writes this .d file only when it actually compiled a
            // shader. Declaring it as an output makes the step fail (instead
            // of caching a hollow .cpp) when glslc fails: the upstream
            // generator ignores glslc's exit status and exits 0 even when
            // glslc cannot run, leaving a .cpp with no embedded shader bytes.
            const d_name = std.mem.concat(gpa, u8, &.{ cpp_name, ".d" }) catch @panic("OOM");
            _ = run.addOutputFileArg(d_name);
            // Cache-only input: regenerates the shaders when glslc changes.
            // (No PATH: glslc is an absolute path, so execvp does no search.)
            run.clearEnvironment();
            run.setEnvironmentVariable("GLSLC_VERSION", glslc_version);
            module.addCSourceFile(.{ .file = cpp, .flags = &.{ "-std=c++17" } });
        }

        // The Vulkan backend itself.
        module.addCSourceFiles(.{
            .root = ggml_dep.path(""),
            .files = &.{ "src/ggml-vulkan/ggml-vulkan.cpp" },
            .flags = &.{ "-std=c++17" },
        });
        module.addIncludePath(hpp.dirname());
        module.addIncludePath(vulkan_headers_dep.path("include"));
        module.addIncludePath(spirv_headers_dep.path("include"));
        for (macros.items) |m| module.addCMacro(m, "1");
        module.addCMacro("GGML_USE_VULKAN", "1");

        // Windows: the Vulkan loader is vulkan-1.dll (installed by GPU
        // drivers). Generate an import library naming the 3 vk* functions
        // ggml calls directly (everything else is resolved at runtime through
        // vkGetInstanceProcAddr) with zig dlltool from src/vulkan-1.def.
        if (target.result.os.tag == .windows) {
            const machine: []const u8 = switch (target.result.cpu.arch) {
                .x86_64 => "i386:x86-64",
                .aarch64 => "arm64",
                else => unreachable, // already rejected by the arch switch above
            };
            const dlltool = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-d" });
            dlltool.addFileArg(b.path("src/vulkan-1.def"));
            dlltool.addArgs(&.{ "-m", machine, "-l" });
            vk_implib = dlltool.addOutputFileArg("libvulkan-1.a");
        }

        // The loader is linked on the consumer modules below, not on this
        // static library (Zig would embed the .so as an archive member): on
        // Windows it is the generated import library libvulkan-1.a, on Linux
        // the system library `vulkan`. External users of libzarakeet_c.a on
        // Windows can build the same import library from src/vulkan-1.def
        // with `zig dlltool`.
    }

    const lib = b.addLibrary(.{
        .name = "zarakeet_c",
        .root_module = module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Tests.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.linkLibrary(lib);
    const tests = b.addTest(.{
        .name = "zarakeet tests",
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the tests").dependOn(&run_tests.step);

    // Benchmark: transcription + timing program (example/bench/).
    const zarakeet_mod = b.addModule("zarakeet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zarakeet_mod.linkLibrary(lib);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("example/bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zarakeet", zarakeet_mod);

    // Vulkan: consumer modules link the loader (see the Vulkan block above).
    if (vulkan) {
        if (vk_implib) |implib| {
            // Windows: generated import library for vulkan-1.dll (see src/vulkan-1.def).
            test_module.addObjectFile(implib);
            zarakeet_mod.addObjectFile(implib);
            bench_mod.addObjectFile(implib);
        } else {
            test_module.linkSystemLibrary("vulkan", .{});
            zarakeet_mod.linkSystemLibrary("vulkan", .{});
            bench_mod.linkSystemLibrary("vulkan", .{});
        }
    }

    const bench_exe = b.addExecutable(.{
        .name = "zarakeet-bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Build and run the benchmark (example/bench)").dependOn(&run_bench.step);
}