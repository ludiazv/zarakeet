# zarakeet — Worker Plan

Staged instructions for building **zarakeet**: Zig bindings for
[mudler/parakeet.cpp](https://github.com/mudler/parakeet.cpp), plus a thin, idiomatic Zig API on top of them.

Do the stages **in order**. Each stage ends with a **Done when** checklist. Do not start the next stage until every item in that checklist passes.

### Status (updated 2026-09-27: all stages done)

| Stage | Status |
|---|---|
| 1–6 | ✅ Done. |
| 7 | ✅ Done (2026-09-27). All four models are in `example/`, SHA-256 verified. The full command passed **9/9 tests, no leaks** at the time (now **11/11**, after the two `cleanText` unit tests were added) on CPU (with both TDT models), on Vulkan, and on Vulkan with `PARAKEET_DEVICE=cpu`. Nemotron offline (`auto` and `en`) and streaming transcripts are correct; the stream drained **0** EOU/EOB events. Upstream quirk: see the "Nemotron language tag" follow-up. |
| 8 | ✅ Done, with the cleanup follow-up and the extras in "Stage 8 additions" (below Stage 8). Builds, runs on the GPU (`Vulkan0`, RADV 780M), and transcripts match `example/out.txt`. |
| 9 | ✅ Done. Cross-builds: `aarch64-linux-gnu` ✅, `x86_64_v3` ✅, Windows (`x86_64-windows-gnu`) CPU ✅ (lib and linked test binary), macOS (`aarch64-macos`) CPU ✅ (lib and linked test binary). Windows **Vulkan** now builds and links (✅, x86_64 and aarch64; import library from `src/vulkan-1.def`); macOS **Vulkan** is rejected at configure time. `README.md` is written and was reviewed and rewritten for users in the final cleanup (2026-09-27). |
| 10 | ✅ Done. `src/shim.cpp`, `setNumThreads`, `shutdown()` (with the live-object assert), and the "shutdown and reload" test pass on CPU and Vulkan. Vulkan (radv) also exits cleanly without calling `shutdown()`. |
| 11 | ✅ Done (2026-09-27). Benchmark is in `example/bench/` (`zig build bench`, `--fleurs` flag, old `example` step removed); `sweep.py` reports WER per model, language and configuration (corpus WER; `--no-wer`, `--max-wer`, FLEURS transcribed once per configuration). Measured: corpus WER **4.4%** (tdt-0.6b-v3) and **11.3–11.6%** (nemotron), worst clip **40%** (nemotron, `pl_pl_2.wav`) — matches §1.3. |
| 12 | ✅ Done (2026-09-27). Standalone consumer project `example/cli/` (`zarakeet-cli <model.gguf> <file.wav>`): relative `.path` dependency, exit codes 0/1/2, transcript-only stdout. Verified on CPU, Vulkan (`Vulkan0`, `libvulkan.so.1`) and an `x86_64-windows-gnu` cross-build (imports `vulkan-1.dll`). |
| Open follow-ups | See "Open follow-ups" at the end of this file. |

Verified on 2026-09-27: the full Stage 7 command (§ Stage 7 "Done when") → **11/11** passed on CPU, Vulkan, and Vulkan with `PARAKEET_DEVICE=cpu`.

This plan now lives in `doc/WORKER_PLAN.md`. The technical reference for maintainers is `doc/notes.md`, and the parked Metal assessment is `doc/todo-metal.md`.

---

## 0. Rules for every worker (read first)

1. **Scope is fixed.** Build only what this document describes. Do not add:
   - CLIs, examples, or helpers beyond the ones in rule 2
   - batch, N-best, CTC, or device-selection APIs
   - CUDA, Metal, or HIP support
   - CI
2. **Zig toolchain only.** The build uses `zig build` and nothing else. No CMake, make, bash scripts, or Python.
   - The single allowed exception is the system `glslc` binary, and only for the Vulkan build (Stage 8).
   - Also allowed, as developer tools outside the library build:
     - `example/bench/` (`zig build bench`, plus `sweep.py`)
     - `example/cli/` (a separate Zig project)
     - `example/download_models.py`
     - `example/fleurs/fleurs_fetch.py`
     None of them is part of the library. The benchmark is `example/bench/` (`zig build bench`, Stage 11); `example/cli/` is a standalone consumer project (Stage 12).
3. **Never modify upstream sources.** parakeet.cpp and ggml come in as `build.zig.zon` dependencies and are compiled exactly as they are. Do not copy them into this repo.
4. **Zig version is 0.17.0** (`~/.local/zig/zig`). The Zig standard library and build APIs change between versions, so **do not guess an API**. Before using one, check the real source:
   - `~/.local/zig/lib/std/Build.zig`
   - `~/.local/zig/lib/std/Build/Module.zig`
   - `~/.local/zig/lib/std/Build/Step/Compile.zig`
   - `~/.local/zig/lib/std/Build/Step/Run.zig`
   - `~/.local/zig/lib/std/process/Child.zig`

   Use `grep -n "pub fn <name>"` on these files to confirm names and signatures.
5. **Stop and report** instead of improvising. Examples:
   - an upstream file listed here does not exist
   - a compile error seems to require changing upstream code
   - an API in this doc does not exist in Zig 0.17

   When you stop, include the exact error output.
6. Keep code small and plain, and match the naming used in this doc.
7. Do not run `git` commit or push unless asked.

---

## 1. Reference facts (use these values exactly)

### 1.1 Upstream pins

| Dependency name | Source | Commit / notes |
|---|---|---|
| `parakeet_cpp` | `https://github.com/mudler/parakeet.cpp/archive/e75de9b6b9b688fd293aa22f7e27aa724ea286f8.tar.gz` | The tarball does **not** contain the ggml submodule. |
| `ggml` | `https://github.com/ggml-org/ggml/archive/e705c5fed490514458bdd2eaddc43bd098fcce9b.tar.gz` | The exact submodule commit used by parakeet.cpp. |
| `vulkan_headers` (lazy) | `https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.364.tar.gz` | Pinned in Stage 8. |
| `spirv_headers` (lazy) | `https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-1.4.357.0.tar.gz` | Pinned in Stage 8. |

Zig stores fetched packages in `zig-pkg/` inside the project. That directory is gitignored.

Other versions: ggml is `0.13.0`, and `PARAKEET_VERSION` is `"0.0.1"`.

### 1.2 Model support rule (the "gate")

Before loading a model, read two keys from its GGUF metadata:

| `parakeet.arch` | `parakeet.prompt.present` | Result |
|---|---|---|
| `tdt` | any | ✅ `Kind.tdt` |
| `hybrid_tdt_ctc` | any | ✅ `Kind.tdt` |
| `rnnt` | `true` | ✅ `Kind.nemotron` |
| `rnnt` | missing / `false` | ❌ `error.UnsupportedModel` (the EOU‑120m model) |
| `hybrid_rnnt_ctc`, `ctc`, missing key, anything else | — | ❌ `error.UnsupportedModel` |

Whenever the C API takes a `decoder` argument, pass **`2`** (transducer), never `0` or `1`.

### 1.3 Test assets

All test assets live in `example/`. Only `example/*.gguf` (and `.part`) is
gitignored; `speech.wav`, `out.txt`, `bench/main.zig` and `bench/sweep.py` are tracked.
Never commit the models.

- **Audio:** `example/speech.wav`, copied from `<parakeet_cpp dep>/tests/fixtures/speech.wav`. It is a RIFF WAV, 16‑bit PCM, mono, 16 kHz, about 7.4 s long.
- **Expected transcripts:** `example/out.txt`, one `<model file>: <text>` line per TDT model. The text comes from upstream `docs/parity.md`, and our q4_k builds reproduce it exactly on both CPU and Vulkan.
- **Multilingual clips:** `example/fleurs/` holds 14 clips (2 each for `en_us`, `es_419`, `fr_fr`, `de_de`, `it_it`, `pl_pl`, `nl_nl`) from Google FLEURS, 16 kHz mono 16-bit, 3.9 MB, tracked in git. `refs.tsv` has the **human** transcripts, so compare them by word error rate (WER), not exact equality. They're CC-BY 4.0; see `ATTRIBUTION.md`. `fleurs_fetch.py` regenerates them reproducibly, using only the Python standard library.
  - WER measured 2026-09-27 (lowercased, punctuation removed): `tdt-0.6b-v3` per clip 0–20% (0% on 8 of 14), corpus **4.4%**; nemotron with `lang=auto` per clip 0–40%, corpus **11.6%**, with Polish and Dutch the worst.
- **Models:** all of them are in the single Hugging Face repo `mudler/parakeet-cpp-gguf`. Download from `https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/<file>`, then check the file's SHA-256 against the `lfs.oid` value from `https://huggingface.co/api/models/mudler/parakeet-cpp-gguf/tree/main`.

  | Role | File in `example/` | Size | Present |
  |---|---|---|---|
  | TDT, pure (`arch = tdt`) | `tdt-1.1b-q4_k.gguf` | 1.09 GB | ✅ |
  | TDT, hybrid (`arch = hybrid_tdt_ctc`) | `tdt-0.6b-v3-q4_k.gguf` | 675 MB | ✅ |
  | Nemotron (streaming) | `nemotron-3.5-asr-streaming-0.6b-q4_k.gguf` | 718 MB | ✅ |
  | CTC (negative test) | `ctc-0.6b-q4_k.gguf` | 610 MB | ✅ |

  If a file is missing from the repo, stop and report.

---

## Final repository layout

```
zarakeet/
├── build.zig
├── build.zig.zon
├── src/
│   ├── c.zig        # raw extern declarations
│   ├── root.zig     # idiomatic API + tests
│   ├── shim.cpp     # Stage 10 only: extern "C" wrappers for two pk:: C++ functions
│   └── vulkan-1.def # Windows: vulkan-1.dll import definitions for zig dlltool
├── example/         # only *.gguf is gitignored; everything else is tracked
│   ├── bench/       # Stage 11: main.zig (benchmark, `zig build bench`) + sweep.py
│   ├── cli/         # Stage 12: standalone consumer project (build.zig, build.zig.zon, src/main.zig)
│   ├── fleurs/      # 14 multilingual clips + refs.tsv + ATTRIBUTION.md + fleurs_fetch.py
│   ├── download_models.py
│   ├── speech.wav, out.txt
│   └── *.gguf       # test models (gitignored)
├── LICENSE          # MIT
├── README.md
├── doc/
│   ├── WORKER_PLAN.md # this file
│   ├── notes.md       # technical notes for maintainers
│   ├── todo-metal.md  # parked Metal assessment
│   ├── zig-facts.md   # Zig API facts and pitfalls (0.16-era + 0.17 addendum)
│   └── logo.svg, logo-icon.svg, logo-icon.png  # project logo: geometric parakeet (full / icon / 512 px preview)
```

`.gitignore` contains exactly: `.zig-cache/`, `zig-out/`, `zig-pkg/`,
`example/*.gguf`, `example/*.gguf.part`, `__pycache__/` (Python bytecode from `sweep.py` and the fetch scripts).

---

## Stage 1 — Scaffold and dependencies

**Goal:** an empty Zig package that fetches both upstream sources.

**Steps**
1. In `/home/ldiaz/projects/zarakeet`, create `build.zig.zon` by hand. Set:
   - `.name = .zarakeet`
   - `.version = "0.1.0"`
   - `.minimum_zig_version = "0.17.0"`
   - `.paths = .{ "build.zig", "build.zig.zon", "src", "README.md" }`
   - an empty `.dependencies = .{}`

   Zig 0.17 requires a `.fingerprint` field. Run `zig build` once; the error message prints the value to use.
2. Add the two deps with `zig fetch --save=<name> <url>`, using the names and URLs from §1.1:
   - `zig fetch --save=parakeet_cpp <parakeet_cpp URL>`
   - `zig fetch --save=ggml <ggml URL>`
3. Create a minimal `build.zig` that:
   - reads the standard target and optimize options
   - calls `b.dependency("parakeet_cpp", .{})` and `b.dependency("ggml", .{})`
   - does nothing else yet
4. Create `.gitignore`.

**Done when**
- [ ] `zig build` exits 0.
- [ ] `build.zig.zon` contains both deps with `.hash` values.
- [ ] You checked that the fetched sources exist. Find them with `ls zig-pkg/` (Zig keeps fetched packages inside the project), then confirm that `include/parakeet_capi.h` is in parakeet_cpp and `src/ggml.c` is in ggml.

---

## Stage 2 — Build ggml (CPU) as a static library

**Goal:** a static library `zarakeet_c` that contains ggml with the CPU backend.

**Steps.** In `build.zig`:
1. Create one module with `link_libc = true` and `link_libcpp = true`, and one static library named `zarakeet_c` built from it (`b.addLibrary(.{ .linkage = .static, ... })`). Verify the exact API names first.
2. Add the include paths, all from the `ggml` dep: `include`, `src`, `src/ggml-cpu`.
3. Add the C macros:
   - Always:
     - `GGML_USE_CPU`
     - `GGML_USE_LLAMAFILE`
     - `GGML_SCHED_MAX_COPIES=4`
     - `GGML_VERSION="0.13.0"`
     - `GGML_COMMIT="e705c5f"`
   - When the target OS is Linux: `_GNU_SOURCE` and `_XOPEN_SOURCE=600`.
   - **Do not** define `GGML_USE_OPENMP` or `GGML_BACKEND_DL`.
4. Add the C sources with flags `-std=c11`. The `.root` is the ggml dep path.
   - `src/ggml.c`, `src/ggml-alloc.c`, `src/ggml-quants.c`
   - `src/ggml-cpu/ggml-cpu.c`, `src/ggml-cpu/quants.c`
5. Add the C++ sources with flags `-std=c++17`:
   - `src/ggml.cpp`, `src/ggml-backend.cpp`, `src/ggml-backend-dl.cpp`, `src/ggml-backend-reg.cpp`, `src/ggml-backend-meta.cpp`, `src/ggml-opt.cpp`, `src/ggml-threading.cpp`, `src/gguf.cpp`
     - `ggml-backend-dl.cpp` is required even though `GGML_BACKEND_DL` is not defined: `ggml-backend-reg.cpp` includes its header, and upstream ggml always compiles it.
   - `src/ggml-cpu/ggml-cpu.cpp`, `src/ggml-cpu/repack.cpp`, `src/ggml-cpu/hbm.cpp`, `src/ggml-cpu/traits.cpp`, `src/ggml-cpu/binary-ops.cpp`, `src/ggml-cpu/unary-ops.cpp`, `src/ggml-cpu/vec.cpp`, `src/ggml-cpu/ops.cpp`
   - `src/ggml-cpu/amx/amx.cpp`, `src/ggml-cpu/amx/mmq.cpp`
   - `src/ggml-cpu/llamafile/sgemm.cpp`
6. Add arch-specific sources based on `target.result.cpu.arch`:
   - `x86_64`: `src/ggml-cpu/arch/x86/quants.c` (C) and `src/ggml-cpu/arch/x86/repack.cpp` (C++).
   - `aarch64`: `src/ggml-cpu/arch/arm/quants.c` (C) and `src/ggml-cpu/arch/arm/repack.cpp` (C++).
   - Any other arch: `@panic("unsupported cpu arch")` at configure time.
   - **Do not** compile `cpu-feats.cpp`. It is only used for dynamic-loading builds.
7. `b.installArtifact(lib)`.

**Notes**
- If you get duplicate-symbol or missing-symbol link errors, stop and report. Do not add or remove files beyond this list without reporting it.
- Zig builds for the native CPU by default, which is equivalent to upstream `-march=native`.
- **CPU features are chosen at compile time.** ggml-cpu selects its SIMD paths with `#if __AVX2__` and similar checks; there is no runtime dispatch in this build. A native build crashes with SIGILL on a CPU that lacks one of its features. For binaries meant to run on other machines, use `-Dcpu=x86_64_v3` (AVX2/FMA/F16C) or `-Dcpu=x86_64_v4` (AVX‑512). **Never ship `-Dcpu=baseline`:** it means plain x86‑64 (SSE2), with every SIMD path disabled.
- **Debug builds compile the C/C++ with optimizations anyway.** `build.zig` builds the upstream C/C++ with `ReleaseFast` when `-Doptimize=Debug` (`c_optimize`), because ggml does null-pointer arithmetic that Zig's Debug safety checks reject. Only the Zig code is built in Debug mode.

**Done when**
- [ ] `zig build` exits 0 and `zig-out/lib/libzarakeet_c.a` exists.
- [ ] `zig build -Doptimize=ReleaseFast` exits 0.

---

## Stage 3 — Add parakeet.cpp to the same library

**Goal:** `libzarakeet_c.a` also contains parakeet and its C API.

**Steps**
1. Add include paths from the `parakeet_cpp` dep: `include`, `src`, `third_party`.
2. Add the macro `PARAKEET_VERSION="0.0.1"`.
3. Add these C++ sources (flags `-std=c++17`, `.root` = parakeet_cpp dep path). This is the exact `PARAKEET_SRC` list from upstream `CMakeLists.txt`:
   ```
   src/parakeet.cpp src/model.cpp src/parakeet_capi.cpp src/common.cpp
   src/audio_io.cpp src/transcription_json.cpp src/model_loader.cpp
   src/backend.cpp src/ggml_graph.cpp src/fft.cpp src/mel.cpp src/mel_gpu.cpp
   src/subsampling.cpp src/relpos_attention.cpp src/conformer.cpp src/pos_enc.cpp
   src/encoder.cpp src/streaming_encoder.cpp src/streaming.cpp src/ctc_decoder.cpp
   src/prediction.cpp src/joint.cpp src/prompt_kernel.cpp src/tdt.cpp src/rnnt.cpp
   src/transducer_batch.cpp src/tokenizer.cpp src/search.cpp src/transcription.cpp
   ```
   Keep the CTC, RNNT and batch source files. The C API needs them to link, even though the Zig API never exposes those features.
4. Create a temporary smoke test in `src/root.zig`:
   ```zig
   extern fn parakeet_capi_abi_version() c_int;
   test "abi version" { try @import("std").testing.expectEqual(@as(c_int, 6), parakeet_capi_abi_version()); }
   ```
5. Add a `test` step. It should:
   - create a test module rooted at `src/root.zig` that links `zarakeet_c`
   - run it through `b.addRunArtifact`
   - hook it up with `b.step("test", ...)`

**Done when**
- [ ] `zig build` exits 0.
- [ ] `zig build test` exits 0, which means the ABI version is 6.

---

## Stage 4 — Raw bindings (`src/c.zig`)

**Goal:** hand-written `extern` declarations. **Do not use `@cImport` or translate-c.**

**Steps**
1. Declare the opaque types:
   `pub const parakeet_ctx = opaque {};`, `pub const parakeet_stream = opaque {};`, `pub const gguf_context = opaque {};`
2. Declare the event struct and the event constants:
   ```zig
   pub const parakeet_stream_event = extern struct {
       token: c_int, is_eob: c_int, encoder_frame: c_int, time_sec: f32,
   };
   pub const PARAKEET_EVENT_EOU: c_int = 1;
   pub const PARAKEET_EVENT_EOB: c_int = 2;
   ```
3. Declare the parakeet C API functions below with `pub extern fn`. Copy each signature **exactly** from `include/parakeet_capi.h`, mapping the types like this:

   | C type | Zig type |
   |---|---|
   | `char*` return | `?[*:0]u8` |
   | `const char*` param | `?[*:0]const u8` (use `[*:0]const u8` where the header says it can't be NULL) |
   | `const float*` | `[*]const f32` |
   | `const int*` | `[*]const c_int` |
   | `int*` out-param | `?*c_int` |
   | `ctx` pointers | `?*parakeet_ctx` |

   Functions:
   - `parakeet_capi_abi_version`
   - `parakeet_capi_load`, `parakeet_capi_free`
   - `parakeet_capi_last_error`, `parakeet_capi_free_string`
   - `parakeet_capi_transcribe_path_lang`, `parakeet_capi_transcribe_pcm_lang`
   - `parakeet_capi_transcribe_path_json`
   - `parakeet_capi_transcribe_pcm_batch_json_lang`
   - `parakeet_capi_stream_begin_lang`, `parakeet_capi_stream_feed`, `parakeet_capi_stream_finalize`
   - `parakeet_capi_stream_feed_json`, `parakeet_capi_stream_finalize_json`
   - `parakeet_capi_stream_drain_events`, `parakeet_capi_free_events`, `parakeet_capi_stream_free`
4. Declare the gguf functions (from ggml `include/gguf.h`):
   ```zig
   pub const gguf_init_params = extern struct { no_alloc: bool, ctx: ?*anyopaque };
   pub extern fn gguf_init_from_file(fname: [*:0]const u8, params: gguf_init_params) ?*gguf_context;
   pub extern fn gguf_init_empty() ?*gguf_context;
   pub extern fn gguf_free(ctx: ?*gguf_context) void;
   pub extern fn gguf_find_key(ctx: *const gguf_context, key: [*:0]const u8) i64;
   pub extern fn gguf_get_val_str(ctx: *const gguf_context, key_id: i64) [*:0]const u8;
   pub extern fn gguf_get_val_bool(ctx: *const gguf_context, key_id: i64) bool;
   pub extern fn gguf_set_val_str(ctx: *gguf_context, key: [*:0]const u8, val: [*:0]const u8) void;
   pub extern fn gguf_set_val_bool(ctx: *gguf_context, key: [*:0]const u8, val: bool) void;
   pub extern fn gguf_write_to_file(ctx: *const gguf_context, fname: [*:0]const u8, only_meta: bool) bool;
   pub extern fn gguf_get_kv_type(ctx: *const gguf_context, key_id: i64) c_int;
   ```
   - **Check before using these:** open ggml's `include/gguf.h` and confirm every signature above, and `gguf_type` (the return type of `gguf_get_kv_type`). If one differs, match the header and note the difference.
   - Also look up the numeric values of `GGUF_TYPE_BOOL` and `GGUF_TYPE_STRING` in the `gguf_type` enum, and add them as `pub const` values.
5. **Do NOT declare** these (they are out of scope):
   - `transcribe_pcm_logits`, `free_logits`
   - the `*_nbest_json` functions
   - `transcribe_pcm_batch` (non-JSON), `transcribe_pcm_batch_json` (non-lang)
   - the non-lang `transcribe_path` and `transcribe_pcm`, and `stream_begin`
6. Move the Stage 3 smoke test to use `c.parakeet_capi_abi_version()`.

**Done when**
- [ ] `zig build test` exits 0.
- [ ] Every declared function is referenced **at runtime** at least once, e.g. `std.mem.doNotOptimizeAway(&c.<fn>);` inside a normal test body. This forces linking and proves each symbol exists.
  - Don't use a `comptime { _ = &c.<fn>; }` block. Its reference only survives through Debug debug info, so a missing symbol still passes silently under `-Doptimize=ReleaseFast` (verified).
- [ ] `parakeet_capi_stream_drain_events` takes `out_events: *?[*]parakeet_stream_event`. The inner pointer must be optional, because C writes NULL there when there are no events.

---

## Stage 5 — Idiomatic API: `Model` + gate + offline transcription

**Goal:** implement the public API below in `src/root.zig`. Keep the signatures **exactly** as written.

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const c = @import("c.zig");

pub const Error = error{ LoadFailed, UnsupportedModel, TranscribeFailed, NotStreamingModel, OutOfMemory };
pub const Kind = enum { tdt, nemotron };
pub const Options = struct { lang: ?[:0]const u8 = null };

pub const Model = struct {
    ctx: *c.parakeet_ctx,
    kind: Kind,

    pub fn load(path: [:0]const u8) Error!Model;
    pub fn deinit(self: *Model) void;
    pub fn lastError(self: Model) [:0]const u8;
    pub fn transcribeFile(self: Model, gpa: Allocator, wav_path: [:0]const u8, opts: Options) Error![]u8;
    pub fn transcribePcm(self: Model, gpa: Allocator, pcm: []const f32, sample_rate: u32, opts: Options) Error![]u8;
    pub fn transcribeFileJson(self: Model, gpa: Allocator, wav_path: [:0]const u8) Error![]u8;
    pub fn transcribePcmJson(self: Model, gpa: Allocator, pcm: []const f32, sample_rate: u32, opts: Options) Error![]u8;
};
```

**Implementation rules**
1. **`fn detectKind(path: [:0]const u8) Error!Kind`.** Make this a private helper, but visible to tests.
   - Open the file with `gguf_init_from_file(path, .{ .no_alloc = true, .ctx = null })`. A null result means `error.LoadFailed`.
   - Always call `gguf_free` (`defer`).
   - Look up `parakeet.arch`. If the key is missing, or its type is not string, return `error.UnsupportedModel`.
   - Look up `parakeet.prompt.present`. It counts as true only if the key exists, its type is bool, and its value is true.
   - Apply the table in §1.2.
2. **`load`:**
   - `kind = try detectKind(path)`.
   - Call `parakeet_capi_load(path)`. A null result means `error.LoadFailed`.
   - If `parakeet_capi_abi_version() != 6`, free the ctx and return `error.LoadFailed`.
3. **`deinit`:** call `parakeet_capi_free(self.ctx)`, then set `self.* = undefined`.
4. **`lastError`:** return `std.mem.span(parakeet_capi_last_error(self.ctx))`.
5. **Owned strings.** Write one private helper:
   ```zig
   fn takeString(gpa: Allocator, p: ?[*:0]u8) Error![]u8 {
       const s = p orelse return error.TranscribeFailed;
       defer c.parakeet_capi_free_string(s);
       return gpa.dupe(u8, std.mem.span(s));
   }
   ```
   Every function that returns text uses it. The caller frees the result with `gpa.free`.
6. **`lang`:** pass `if (opts.lang) |l| l.ptr else null`.
7. **Length and sample rate:** convert with `std.math.cast(c_int, x) orelse return error.TranscribeFailed`.
8. **`decoder`:** always pass `2`.
9. **`transcribeFileJson`:** call `parakeet_capi_transcribe_path_json(ctx, path, 2)`.
   - The C API has no language variant here. Add a doc comment saying it uses the model's default language.
10. **`transcribePcmJson`:** call `parakeet_capi_transcribe_pcm_batch_json_lang` with `n_clips = 1` and `n_samples = &[_]c_int{len}`.
    - The result is a JSON **array** with one element. After `takeString`, check that the first byte is `[` and the last is `]`, then strip them.
    - Return the inner object as a newly allocated slice (dupe, then free the old one), or use `std.mem.trim` plus a copy.
    - If the brackets aren't there, return `error.TranscribeFailed`.
11. Every `pub` declaration gets a one-line `///` doc comment. Keep the comments short.

**Unit tests (no model needed)**
- `abi version == 6`.
- `Model.load("/nonexistent.gguf")` returns `error.LoadFailed`.
- **Gate table test.** For each row of §1.2:
  - Build a synthetic GGUF with `gguf_init_empty`, `gguf_set_val_str("parakeet.arch", …)` and, when the row needs it, `gguf_set_val_bool("parakeet.prompt.present", …)`.
  - Write it with `gguf_write_to_file(ctx, tmp_path, true)` into a `std.testing.tmpDir` path.
  - Call `detectKind` and check the result.
  - Also cover a file with no `parakeet.arch` key.

**Done when**
- [ ] `zig build test` exits 0 and all of the tests above pass.

---

## Stage 6 — Streaming (`Stream`, nemotron only)

**Goal:** add the streaming API. Keep the signatures **exactly** as written.

```zig
pub const Event = struct {
    kind: enum { eou, eob },
    encoder_frame: u32,
    time_sec: f32,
};

pub const Stream = struct {
    handle: *c.parakeet_stream,

    pub fn feed(self: *Stream, gpa: Allocator, pcm16k: []const f32) Error![]u8;
    pub fn finalize(self: *Stream, gpa: Allocator) Error![]u8;
    pub fn feedJson(self: *Stream, gpa: Allocator, pcm16k: []const f32) Error![]u8;
    pub fn finalizeJson(self: *Stream, gpa: Allocator) Error![]u8;
    pub fn drainEvents(self: *Stream, gpa: Allocator) Error![]Event;
    pub fn deinit(self: *Stream) void;
};

// in Model:
pub fn stream(self: *Model, opts: Options) Error!Stream;
```

**Implementation rules**
1. **`Model.stream`:**
   - If `self.kind != .nemotron`, return `error.NotStreamingModel`.
   - Call `parakeet_capi_stream_begin_lang(ctx, lang)`. A null result means `error.TranscribeFailed`.
2. **`feed`:** call `parakeet_capi_stream_feed(handle, pcm.ptr, len, null)` and pass the result through `takeString`.
   - The result may be `""`, and that is valid.
3. **`finalize`, `feedJson`, `finalizeJson`:** call the matching C function and pass the result through `takeString`.
4. **`drainEvents`:**
   - `var raw: ?[*]c.parakeet_stream_event = null;`
   - `n = parakeet_capi_stream_drain_events(handle, &raw)`. If `n < 0`, return `error.TranscribeFailed`.
   - Call `defer parakeet_capi_free_events(raw)`.
   - Allocate `[]Event` of length `n`, convert each record into it, and return it. The caller frees it with `gpa.free`.
5. **`deinit`:** call `parakeet_capi_stream_free(handle)`.
6. **Doc comments must say:**
   - the `Stream` must not outlive the `Model` it came from
   - `pcm16k` must be 16 kHz mono
   - don't mix `drainEvents` with the `*Json` feed functions on the same stream, because they share one event queue
7. **Plain-text cleaning (option B):** `feed`/`finalize` pass the C string through the private `cleanText` helper with a `Clean` state kept on the `Stream` (so whitespace is also clean across chunk boundaries); it removes nemotron locale tags (`<en-US>`, …) and normalizes whitespace. `feedJson`/`finalizeJson` keep the raw upstream text.

**Unit test (no model needed):** none is possible, because a TDT model is needed to get `NotStreamingModel`. That case is covered in Stage 7.

**Done when**
- [ ] `zig build test` exits 0.

---

## Stage 7 — Model integration tests (need downloaded models)

**Goal:** prove the API works end to end on the CPU.

**Steps**
1. Download the missing models from §1.3 (nemotron and CTC) into `example/`, and verify their SHA-256.
2. Add tests in `src/root.zig`. Each test reads its env var and returns `error.SkipZigTest` if the var is not set.
   - Env vars:
     - `ZARAKEET_TDT_MODEL`
     - `ZARAKEET_NEMOTRON_MODEL`
     - `ZARAKEET_CTC_MODEL`
     - `ZARAKEET_WAV` (path to `speech.wav`)
   - The build's test step must pass these env vars through to the test run. Check how `Step.Run` inherits the environment; it inherits by default.
   - **Test-only WAV reader.** Some tests need `speech.wav` as `[]f32`, so write a minimal reader:
     - Parse RIFF and find the `fmt ` chunk. Require PCM, 1 channel, 16 bit, 16000 Hz, or return an error.
     - Find the `data` chunk and convert each `i16` sample to `f32` as `sample / 32768.0`.
     - Keep it under about 40 lines and mark it test-only.
3. **Tests:**
   - **TDT:**
     - `transcribeFile` returns non-empty text.
     - `transcribePcm` on the same WAV returns **identical** text.
     - `transcribePcmJson` starts with `{` and contains `"words"`.
     - `transcribeFileJson` contains `"words"`.
     - `model.stream(.{})` returns `error.NotStreamingModel`.
   - **Nemotron:**
     - `load` gives `kind == .nemotron`.
     - `transcribeFile` with `.lang = "en"` returns non-empty text.
     - Streaming: feed the PCM in 1600-sample chunks, concatenate every `feed` result plus the `finalize` result, and check that the combined text is non-empty.
     - Call `drainEvents` and free the result. Just print the count; don't assert on it.
     - `.lang = "xx-invalid"` returns `error.TranscribeFailed`, and `lastError()` is non-empty.
   - **CTC:** `Model.load` returns `error.UnsupportedModel`.
4. Use `std.testing.allocator` everywhere, so memory leaks fail the test.

**Done when**
- [ ] This command exits 0 with no skipped tests and no leaks. Run it once for each TDT model: `tdt-1.1b-q4_k.gguf` (pure) and `tdt-0.6b-v3-q4_k.gguf` (hybrid).
  ```
  ZARAKEET_TDT_MODEL=example/tdt-1.1b-q4_k.gguf \
  ZARAKEET_NEMOTRON_MODEL=example/nemotron-3.5-asr-streaming-0.6b-q4_k.gguf \
  ZARAKEET_CTC_MODEL=example/ctc-0.6b-q4_k.gguf \
  ZARAKEET_WAV=example/speech.wav \
  zig build test -Doptimize=ReleaseFast
  ```
- [ ] Run the same command with `-Dvulkan=true`, then again with `-Dvulkan=true` and `PARAKEET_DEVICE=cpu`.
- [ ] The TDT transcripts match `example/out.txt`.
- [ ] Put the nemotron offline and streaming transcripts, and the drained event count, in your report.

**Note (2026-09-27):** `example/bench/main.zig` also demonstrates nemotron streaming (0.5 s feed chunks, partial lines, event count); `example/bench/sweep.py` checks all four results against `out.txt`.

---

## Stage 8 — Vulkan build (`-Dvulkan=true`)

**Prerequisites** (on the build host):
- `glslc` on PATH. It comes from the `shaderc` package (Arch: `shaderc`; Debian/Ubuntu: `glslc`).
- To **run** the result, you also need the Vulkan loader (`libvulkan.so.1`) and a GPU driver.
- If `glslc` is missing, stop and report. Do not install anything with sudo unless you are told to.

**Steps**
1. Add build options:
   - `-Dvulkan` (bool, default `false`)
   - `-Dglslc` (string, default `"glslc"`)
2. Add the lazy deps with `zig fetch --save=vulkan_headers <url>` and `zig fetch --save=spirv_headers <url>`, using the tags from §1.1. Then set `.lazy = true` on both in `build.zig.zon`, and load them with `b.lazyDependency` only when `vulkan` is true.
3. **Host tool.** Build an executable `vulkan-shaders-gen`:
   - target: `b.graph.host`, optimize: ReleaseFast, link_libcpp
   - source: ggml `src/ggml-vulkan/vulkan-shaders/vulkan-shaders-gen.cpp`, `-std=c++17`
   - **Do not install it.**
4. **Feature probes**, run at configure time and only when `vulkan` is true. For each pair below, run `glslc -o - -fshader-stage=compute --target-env=vulkan1.3 <ggml>/src/ggml-vulkan/vulkan-shaders/feature-tests/<file>` using `std.process.Child.run` (check its 0.17 signature first). If the command exits 0, define the macro on **both** `vulkan-shaders-gen` and the library module.

   | file | macro |
   |---|---|
   | `coopmat.comp` | `GGML_VULKAN_COOPMAT_GLSLC_SUPPORT` |
   | `coopmat2.comp` | `GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT` |
   | `integer_dot.comp` | `GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT` |
   | `bfloat16.comp` | `GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT` |

   Before implementing, confirm the exact file names in the `feature-tests/` dir and the macro names in ggml's `src/ggml-vulkan/CMakeLists.txt` (`test_shader_extension_support` calls).
5. **Generate the shader header.** Add one run step of the host tool with the args `--output-dir <dir>/spv --target-hpp <hpp>`.
   - Use `addOutputDirectoryArg` / `addOutputFileArg` so Zig tracks the outputs.
   - Read `vulkan-shaders-gen.cpp` `main()` to confirm the argument names and what each mode writes.
6. **Generate the shader sources.** For **every** `*.comp` file directly in `src/ggml-vulkan/vulkan-shaders/` (list the dir at configure time; there are roughly 180), add one run step with:
   `--glslc <glslc> --source <comp> --output-dir <own spv dir> --target-hpp <hpp path> --target-cpp <output .cpp>`
   - Give each step **its own** `--output-dir` with `run.addOutputDirectoryArg("spv")`. Don't reuse the header step's directory: one step must never write into another step's output. The `.spv` files are scratch space, because the generated `.cpp` embeds their bytes.
   - **Cache key hygiene.** Call `run.clearEnvironment()`, then set only `PATH` (from `b.graph.environ_map`) and `GLSLC_VERSION` (the output of `glslc --version`, captured at configure time). This way a `glslc` upgrade regenerates the shaders. Never call `setEnvironmentVariable` without `clearEnvironment` first: it copies and hashes the entire parent environment, so any unrelated variable change regenerates every shader (measured: 66 s instead of about 1 s).
   - Print a feature check's result only when the feature is **not** supported.
   - Add each generated `.cpp` to the library (`-std=c++17`).
   - The generated `.cpp` files `#include` the `.hpp`. Make sure the hpp's directory is an include path, and that every step receives the **same** hpp path as step 5.
   - If a step fails, read `vulkan-shaders-gen.cpp` to understand what it expects, and report before you restructure anything.
7. Compile ggml `src/ggml-vulkan/ggml-vulkan.cpp` (`-std=c++17`) with these include paths:
   - the generated hpp directory
   - Vulkan-Headers `include`
   - SPIRV-Headers `include`
   - the ggml include and src dirs
8. Add the macro `GGML_USE_VULKAN` to the library module, so `ggml-backend-reg.cpp` registers the backend.
9. **Link `libvulkan` on the consumer modules** (the test, `zarakeet` and example modules), **not** on the static library. On the static library, Zig would embed the `.so` as an archive member.
   - It must be linked because `ggml-vulkan.cpp` calls `vkGetInstanceProcAddr`, `vkGetPhysicalDeviceFeatures2` and `vkCmdCopyBuffer` directly, despite `VULKAN_HPP_DISPATCH_LOADER_DYNAMIC`. (An earlier version of this plan said not to link it. That was wrong.)
   - Consequence: `-Dvulkan=true` binaries need `libvulkan.so.1` at startup, even with `PARAKEET_DEVICE=cpu`.
   - Consequence: `-Dvulkan=true` cross-builds of anything that links need a libvulkan for the target.
10. Use `b.createModule` for every internal module, including the `vulkan-shaders-gen` host tool. Only `"zarakeet"` is created with `b.addModule`.

**Done when**
- [ ] `zig build` (without `-Dvulkan`) still works and does **not** fetch the Vulkan deps.
- [ ] `zig build -Dvulkan=true` exits 0.
- [ ] On a host with a Vulkan GPU, the Stage 7 command with `-Dvulkan=true` exits 0. The stderr log from parakeet names a `Vulkan` device.
- [ ] Setting an unrelated environment variable (e.g. `ZARAKEET_PROBE=1 zig build -Dvulkan=true`) regenerates no shaders: every `vulkan-shaders-gen` step is cached.

### Stage 8 additions (implemented and verified)

These went in after the original Stage 8. Keep them when you touch `build.zig`.

- **`glslc` resolved to an absolute path.** At configure time the build searches the parent `PATH` for `glslc` (or uses `-Dglslc` as given if it contains `/`). Shader steps then run with a cleared environment holding only `GLSLC_VERSION`, with no `PATH`.
- **Hollow-output guard.** Each shader step also declares `<shader>.cpp.d` as an output. `glslc` writes that file only when it actually compiled something. Upstream `vulkan-shaders-gen` ignores `glslc`'s exit status, so without this guard a broken `glslc` would produce empty `.cpp` files that Zig caches as a success.
- **`-Dvulkan-require-all=true`:** a build option for portable release builds. It makes the configure step fail if any of the four feature tests fails, and the message lists the glslc path, its full version (the **glslang** line decides the features) and the missing features. It requires `-Dvulkan=true`. Debian 13's glslc (glslang 15.1) fails it on `GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT`.
- **Clean user-facing errors.** Configuration mistakes stop with `std.process.fatal`, which prints `error: …`, exits with code 1 and shows no stack trace. That covers:
  - `-Dvulkan-require-all` without Vulkan
  - an unsupported target CPU architecture
  - `glslc` not found, or not runnable
  - the require-all failure
  - `-Dvulkan=true` on a macOS target

  Internal "can't happen" errors still panic: out-of-memory, a missing lazy dependency, and failing to read the vulkan-shaders directory.
- **Vulkan on Windows (W2) and macOS (M1).** On Windows targets the build generates a `vulkan-1.dll` import library with `zig dlltool` from `src/vulkan-1.def` (only the 3 `vk*` functions ggml calls directly; everything else is resolved at runtime through `vkGetInstanceProcAddr`) and links it onto the consumer modules instead of the system `vulkan` library. On macOS targets `-Dvulkan=true` is rejected at configure time: Vulkan there needs MoltenVK, and the GPU path on macOS would be Metal, which is out of scope.
- **What decides the shader feature set.** With the pinned ggml, the compiled-in Vulkan shader features depend **only** on the `glslc` used at build time. `-Dcpu`, `-Doptimize`, the target and the build machine's GPU don't affect it. At runtime, ggml picks among the compiled variants according to the user's GPU.
- [ ] The same run with `PARAKEET_DEVICE=cpu` also passes.
- [ ] If there is no GPU host, report that only the build was verified.

---

## Stage 9 — Cross-compile checks + README

**Steps**
1. Run each of these commands and record whether it passes or fails:
   - `zig build -Dtarget=aarch64-linux-gnu` — **must pass**.
   - `zig build -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3` — **must pass**. This is the portable AVX2 build.
   - `zig build -Dtarget=x86_64-windows-gnu` — best effort.
   - `zig build -Dtarget=aarch64-macos` — best effort.
2. For the best-effort targets, fix only small `if (os == …)` differences in `build.zig`, such as the `_GNU_SOURCE` define. If a fix needs more than about 10 lines, don't make it; record the failure in the README instead.
3. Write `README.md`, at most about 80 lines:
   - What the library is. Link to upstream and list the pinned commits.
   - **Supported models** (the §1.2 table). State clearly that everything else is **not supported** and is rejected with `error.UnsupportedModel`.
   - How to build: `zig build`, `-Dvulkan=true`, `-Dglslc=`, and `-Dcpu=x86_64_v3` / `x86_64_v4` for portable binaries. Warn that `-Dcpu=baseline` disables all SIMD, and that a native build only runs on CPUs with the same features.
   - Runtime requirements for Vulkan, and the `PARAKEET_DEVICE` override.
   - How to use it as a dependency: `zig fetch --save`, then `b.dependency("zarakeet", …).module("zarakeet")`.
   - A 15-line usage example: load a model, transcribe a file, and stream.
   - Known limitations:
     - `transcribeFileJson` has no language option.
     - Streaming is nemotron-only and needs 16 kHz mono input.
     - Windows and macOS are best effort.
4. Expose the module: `b.addModule("zarakeet", .{ .root_source_file = b.path("src/root.zig"), ... })`, linking `zarakeet_c` (or its module) so consumers get everything.

**Done when**
- [ ] Both must-pass cross builds pass.
- [ ] The README exists and its build commands work when copied as-is.
- [ ] The final report lists the result of every command in step 1.

---

## Stage 10 — Thread count + backend shutdown (C++ shim)

**Why this stage exists.** parakeet.cpp has two process-wide controls that `parakeet_capi.h` does not expose. Both are plain C++ functions in `src/ggml_graph.hpp`:

| C++ function | What it does |
|---|---|
| `pk::set_num_threads(int n)` | Sets the CPU thread count for **every** graph in the process. `0` (or any value ≤ 0) means "use the default", which is **8** (`kDefaultThreads`). Stored atomically and applied on the next graph run, so it can be called at any time. Ignored by the Vulkan device, which applies only to CPU work. |
| `pk::shutdown_backend()` | Frees the single process-global ggml backend. Upstream's CLI and server call it just before `main` returns. Without it, the backend is freed during static destruction at exit, which on GPU backends can run **after** the driver has shut down and abort the process ("driver shutting down" for CUDA). A later model load re-creates the backend. |

**Hard rule for `shutdown_backend`.** Model weights live in buffers on this global backend (`backend.cpp`: `realize_weights(global_backend().handle())`). Calling it while any `Model` or `Stream` is alive is **use-after-free**. `parakeet_capi_free` does **not** call it.

**Steps**
1. Create `src/shim.cpp`. This is the whole file:
   ```cpp
   // extern "C" wrappers for parakeet.cpp functions that parakeet_capi.h does not expose.
   #include "ggml_graph.hpp"

   extern "C" void zarakeet_set_num_threads(int n) { pk::set_num_threads(n); }
   extern "C" void zarakeet_shutdown_backend(void) { pk::shutdown_backend(); }
   ```
   Add it to the `zarakeet_c` library in `build.zig` with `-std=c++17`. `.root` is `b.path("src")`, because this file belongs to our repo and not to a dependency. It relies on the parakeet `src` include path that Stage 3 already added.
2. In `src/c.zig`, declare:
   `pub extern fn zarakeet_set_num_threads(n: c_int) void;` and `pub extern fn zarakeet_shutdown_backend() void;`
   Add both to the "all declared C functions exist" test.
3. In `src/root.zig`, add a private live-object counter: `var live = std.atomic.Value(u32).init(0);`
   - `Model.load` increments it after a successful load, and `Model.deinit` decrements it.
   - `Model.stream` increments it after a successful begin, and `Stream.deinit` decrements it.
   - Use `.fetchAdd(1, .monotonic)` / `.fetchSub(1, .monotonic)`. Check the 0.17 `std.atomic.Value` API first.
4. In `src/root.zig`, add these two public functions:
   ```zig
   /// Process-wide CPU thread count for all models (0 = parakeet default, 8).
   /// Takes effect on the next transcription. No effect on Vulkan compute.
   pub fn setNumThreads(n: u32) void;      // clamp to maxInt(c_int), then call c.zarakeet_set_num_threads

   /// Free the process-global compute backend. Call once before the program
   /// exits, after every Model and Stream has been deinit'ed. Required for clean
   /// exit on GPU (Vulkan) builds; harmless on CPU.
   pub fn shutdown() void;                 // std.debug.assert(live.load(.monotonic) == 0); then c.zarakeet_shutdown_backend()
   ```
5. **Tests**
   - **No model needed:**
     - `setNumThreads(4)` then `setNumThreads(0)` doesn't crash.
     - `shutdown()` with nothing loaded doesn't crash, and calling it twice is fine.
   - **With `ZARAKEET_TDT_MODEL` set:**
     1. Call `setNumThreads(2)`, then load a model, transcribe, and deinit.
     2. Call `shutdown()`.
     3. Load again, transcribe again, and check the text is **identical** to the first result (this proves the backend is re-created).
     4. Deinit and call `shutdown()` once more.
     5. Call `setNumThreads(0)` at the end, so other tests keep the default.
   - Existing tests may run in any order, and they share this global state. Don't assert on thread counts or timing.
6. **README:** add a short "Threads and shutdown" section covering:
   - both functions are **process-wide**, not per model
   - the default is 8 threads
   - `shutdown()` must be called last, after every `deinit`

**Do NOT**
- Expose `pk::num_threads`, `last_graph_alloc_bytes`, `global_backend`, or anything else from `ggml_graph.hpp`. Only the two functions above.
- Call `shutdown` automatically, from `Model.deinit` or anywhere else. The caller decides when the process is done.
- Bind the mangled C++ names (`_ZN2pk…`) directly.

**Done when**
- [ ] `zig build test` exits 0 (model tests skipped).
- [ ] The Stage 7 command (`-Doptimize=ReleaseFast` plus the env vars) exits 0, including the new shutdown and reload test, with no leaks.
- [ ] If a Vulkan host is available: the same run with `-Dvulkan=true` exits 0, and the process exits without an abort. Report whether you also saw a clean exit **without** calling `shutdown()`. That tells us whether shutdown is strictly required for Vulkan.

---

## Stage 11 — Benchmark refactor + multilingual WER check

**Goal.**
- **Move:** the current example becomes the **benchmark** and moves to `example/bench/`, run with `zig build bench`.
- **FLEURS clips:** the benchmark can also transcribe the multilingual clips in `example/fleurs/`, with an opt-in `--fleurs` flag.
- **WER:** `sweep.py` computes and reports **word error rate (WER)** per model, language and configuration, and fails on grossly broken output.

**Scope:** `build.zig` (only the example/bench step), `example/main.zig` → `example/bench/main.zig`, `example/sweep.py` → `example/bench/sweep.py`, `README.md`, and this file. Don't touch `src/` or the library build. Check Zig 0.17 APIs in `~/.local/zig/lib/std/` before using them.

### 11.1 Move the benchmark
1. Move the files; the project isn't a git repository, so use a plain `mv`:
   - `mv example/main.zig example/bench/main.zig`
   - `mv example/sweep.py example/bench/sweep.py`
   - The data stays where it is: `example/*.gguf`, `example/speech.wav`, `example/out.txt`, `example/fleurs/`. The benchmark keeps its repo-root-relative paths (`example/…`), because `zig build` runs it from the repo root.
2. In `build.zig`, rename the example wiring. **Keep the behavior and the Vulkan linking exactly as they are:**
   - variables `example_mod`/`example_exe`/`run_example` → `bench_mod`/`bench_exe`/`run_bench`
   - root source `b.path("example/bench/main.zig")`
   - executable name `zarakeet-bench`
   - step: `b.step("bench", "Build and run the benchmark (example/bench)")`. **Remove** the old `example` step.
   - forward command-line arguments: `if (b.args) |args| run_bench.addArgs(args);`, so `zig build bench -- --fleurs` works.
3. In `example/bench/sweep.py`:
   - `ROOT` is now `Path(__file__).resolve().parents[2]`
   - the command becomes `zig build bench -Doptimize=ReleaseFast …`
   - update the docstring paths (`python3 example/bench/sweep.py`)
4. Update every mention of `zig build example`, `example/main.zig` or `example/sweep.py` in `README.md` and this file. Find them with `grep -rn -E 'zig build example|example/main.zig|example/sweep.py' README.md WORKER_PLAN.md`.

### 11.2 `--fleurs` in the benchmark (`example/bench/main.zig`)
1. Switch `main` to the Zig 0.17 entry point `pub fn main(init: std.process.Init) !void`. Read the args with `init.minimal.args.toSlice(init.arena.allocator())`, and use `init.io`. Keep `std.heap.page_allocator` for the model outputs, as today.
   - The only accepted argument is `--fleurs`.
   - Any other argument prints `usage: zarakeet-bench [--fleurs]` to stderr and exits with code 2.
2. **Without `--fleurs`, the output must be byte-identical to today:** the 4 result lines, each followed by its timing line, plus the streaming partial lines and the events line.
3. **With `--fleurs`**, after all of today's output and **before** `zarakeet.shutdown()`:
   - Read `example/fleurs/refs.tsv`. Skip the header row; the columns are `file`, `language`, `seconds`, `transcript`.
   - For each multilingual model, `example/tdt-0.6b-v3-q4_k.gguf` then `example/nemotron-3.5-asr-streaming-0.6b-q4_k.gguf`:
     - load it once
     - for every row, call `transcribeFile(gpa, "example/fleurs/<file>", .{})` (offline, default language `auto`)
     - print exactly one line per clip: `FLEURS\t<model basename>\t<file>\t<text>\n`
     - deinit the model
   - Plain-text results never contain tabs or newlines, because `cleanText` normalizes whitespace, so each line is safe to split on `\t`.
   - Print **no** timing lines for FLEURS clips; the timing regex in `sweep.py` must keep matching only the speech.wav results.
   - Don't compute WER in Zig; `sweep.py` does that.

### 11.3 WER in `example/bench/sweep.py`
1. **WER function.** Use exactly this normalization, so the numbers are comparable with those recorded in §1.3:
   ```python
   import re, unicodedata
   def norm_words(s: str) -> list[str]:
       s = unicodedata.normalize("NFKC", s).lower().replace("’", "'")
       s = re.sub(r"[^\w\s']", " ", s)   # drop punctuation, keep letters/digits/apostrophes
       return s.split()
   def edit_distance(ref: list[str], hyp: list[str]) -> int:  # word-level Levenshtein
       d = list(range(len(hyp) + 1))
       for i, r in enumerate(ref, 1):
           prev, d[0] = d[0], i
           for j, h in enumerate(hyp, 1):
               prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
       return d[-1]
   ```
   - Per-clip WER = `edit_distance / len(ref)`.
   - A group's WER (per language, or overall) is the **corpus WER**: the sum of the edit distances divided by the sum of the reference word counts, not the mean of per-clip WERs.
2. **When it runs.**
   - FLEURS is enabled by default; `--no-wer` skips it.
   - For each configuration, pass `-- --fleurs` **only on the first run**. Later runs measure speech.wav timing only, so `--runs 3` doesn't triple the WER cost.
   - WER doesn't depend on timing, so a single sample per configuration is enough.
3. **Parse** the `FLEURS\t…` lines from the run's stdout. Every (model, clip) pair from `refs.tsv` must appear exactly once; a missing pair counts as a failure (`MISSING`).
4. **Gate.** Add `--max-wer` (a float, default `0.5`). Any clip whose WER is above it fails the sweep (exit 1), and the script prints each offending clip with its reference and its output.
   - The default is deliberately loose. The worst clip measured so far is nemotron on `pl_pl_2.wav` at 40%. The gate catches broken output (empty, garbage, wrong backend), not model quality.
5. **Report**, after the existing RTF table:
   - One WER table per model: **rows** are the languages (`en_us`, `es_419`, …) plus `all`; **columns** are the configurations. Cells show the corpus WER as a percentage with one decimal, e.g. `6.3%`.
   - Then one line per model: `max clip WER: <x>% (<file>)`.
   - CPU and Vulkan WER are expected to be equal or nearly equal. If a model's `all` WER differs by more than 2 percentage points between configurations, print `note: WER differs across configurations for <model>` as a warning, not a failure.
6. The existing speech.wav checks against `out.txt`, the medians and the exit codes stay as they are. The script exits 1 if either check fails.

### 11.4 Docs
- **README:**
  - The "Building" section lists `zig build bench [-- --fleurs]` and `python3 example/bench/sweep.py [--runs N] [--no-wer] [--max-wer X]`, and mentions the models (`python3 example/download_models.py`) and the FLEURS clips.
  - Add a short "Examples" section with 2 bullets: `example/bench/` (benchmark plus WER) and `example/cli/` (Stage 12).
- **This file:** update the Stage 11 row in the status table when you're done.

### Done when
- [ ] `ls example/main.zig example/sweep.py` reports both missing; `example/bench/main.zig` and `example/bench/sweep.py` exist.
- [ ] `zig build example` fails because the step no longer exists. `zig build bench -Doptimize=ReleaseFast` exits 0, and its 4 result lines are byte-identical to `example/out.txt`:
  `diff <(zig build bench -Doptimize=ReleaseFast 2>&1 | grep -E '^[^ ].*\.gguf( \(stream\))?: ') example/out.txt` prints nothing.
- [ ] `zig build bench -Doptimize=ReleaseFast -- --fleurs` prints exactly 28 `FLEURS\t` lines (2 models × 14 clips). `zig build bench -- --bogus` exits 2 with the usage line.
- [ ] `python3 example/bench/sweep.py --runs 1` exits 0 and prints both WER tables.
  - Reference values measured 2026-09-27 with the pinned models on CPU: `all` corpus WER **4.4%** for `tdt-0.6b-v3` (12/275 words) and **11.6%** for nemotron (32/275), with the worst clip at 40% (nemotron, `pl_pl_2.wav`).
  - Report the actual numbers. If they differ noticeably from §1.3, report that instead of changing the thresholds.
- [ ] `python3 example/bench/sweep.py --runs 1 --max-wer 0.05` exits 1 and lists the offending clips.
- [ ] `python3 example/bench/sweep.py --runs 1 --no-wer` exits 0 and runs no FLEURS transcriptions.
- [ ] `zig build test -Doptimize=ReleaseFast` still passes.
- [ ] Report: the files moved or changed, both WER tables, and the output tail of each command.

---

## Stage 12 — Standalone CLI example project (`example/cli/`)

**Goal.** A minimal, **separate Zig project** that shows how a third party consumes zarakeet: a command-line tool, `zarakeet-cli <model.gguf> <file.wav>`, that transcribes the file **offline** with the given model and prints the text. It checks no results and does no timing or benchmarking.

**Scope:** new files `example/cli/build.zig`, `example/cli/build.zig.zon` and `example/cli/src/main.zig`, plus `README.md` and this file. **Don't touch** the root `build.zig`: the CLI isn't part of the root build, and the root `zig build`/`test`/`bench` must not change. Check Zig 0.17 APIs before using them.

### 12.1 `example/cli/build.zig.zon`
```zig
.{
    .name = .zarakeet_cli,
    .version = "0.1.0",
    .fingerprint = 0x0, // replace with the value `zig build` prints on first run
    .minimum_zig_version = "0.17.0",
    .paths = .{ "build.zig", "build.zig.zon", "src" },
    .dependencies = .{
        .zarakeet = .{ .path = "../.." },
    },
}
```
- `.name` must be an enum literal.
- `.paths` is required.
- The dependency path must be **relative**; that's where the zarakeet repo root is.
- The path dependency needs no hash.

### 12.2 `example/cli/build.zig`
- Use the standard target and optimize options, plus options that are forwarded unchanged to the dependency:
  - `-Dvulkan` (bool, default `false`)
  - `-Dcpu`: nothing to do, since it arrives as part of `target`
- Create the dependency the way the README's "Using as a dependency" section shows:
  `b.dependency("zarakeet", .{ .target = target, .optimize = optimize, .vulkan = vulkan })`
  then `exe.root_module.addImport("zarakeet", dep.module("zarakeet"))`.
- Build an executable named `zarakeet-cli` from `src/main.zig` and install it (`b.installArtifact`).
- Add a `run` step that forwards `b.args`: `zig build run -- <model> <wav>`.
- Nothing else: no tests and no extra steps. It must stay a short, copy-pasteable template (about 25 lines).

### 12.3 `example/cli/src/main.zig`
- Entry point: `pub fn main(init: std.process.Init) !void`. Take the arguments from `init.minimal.args.toSlice(init.arena.allocator())`, and use `init.gpa` for transcripts and `init.io` for stdout.
- **Wrong argument count** (anything other than exactly 2 arguments): print `usage: zarakeet-cli <model.gguf> <file.wav>` to stderr and exit with code **2**.
- `zarakeet.Model.load(model_path)`. On error, print to stderr and exit **1**:
  - `error.UnsupportedModel` → `error: unsupported model '<path>' (supported: TDT models and nemotron-3.5-asr-streaming-0.6b)`
  - `error.LoadFailed` → `error: cannot load model '<path>'`
- `model.transcribeFile(gpa, wav_path, .{})`: offline, default language. On `error.TranscribeFailed`, print `error: transcription failed: <model.lastError()>` to stderr and exit **1**.
- On success, print **only the transcript plus `\n` to stdout**, with no labels or timing, so the output can be piped. Any log lines that parakeet or ggml print go to stderr and are fine.
- Clean up in order: free the text, `model.deinit()`, then `zarakeet.shutdown()`. Use `defer` so the error paths clean up too.
- Keep the whole file under about 60 lines, with a short header comment giving usage and exit codes (0 ok, 1 error, 2 usage).
- It works with any model the library accepts, including nemotron offline. There's no streaming, JSON or language option; that's deliberate.

### 12.4 Docs
- **README "Examples" section:** under the `example/cli/` bullet, add
  ```
  cd example/cli
  zig build -Doptimize=ReleaseFast          # add -Dvulkan=true for the GPU build
  ./zig-out/bin/zarakeet-cli ../tdt-1.1b-q4_k.gguf ../speech.wav
  ```
  and say that it's a standalone project depending on zarakeet by relative path; copy it and change the dependency to a URL (`zig fetch --save`) to start a new project.
- **This file:** update the Stage 12 row in the status table when you're done.

### Done when
All commands run from `example/cli/`.
- [ ] `zig build -Doptimize=ReleaseFast` exits 0. The first run prints the fingerprint to put into `build.zig.zon`.
- [ ] `./zig-out/bin/zarakeet-cli ../tdt-1.1b-q4_k.gguf ../speech.wav 2>/dev/null` prints exactly the `tdt-1.1b-q4_k.gguf` text from `../out.txt`. Check with `diff` against `grep '^tdt-1.1b' ../out.txt | cut -d' ' -f2-`.
- [ ] `./zig-out/bin/zarakeet-cli ../nemotron-3.5-asr-streaming-0.6b-q4_k.gguf ../fleurs/es_419_1.wav 2>/dev/null` prints the Spanish sentence (nemotron's WER on this clip is 0%).
- [ ] `zig build run -Doptimize=ReleaseFast -- ../tdt-0.6b-v3-q4_k.gguf ../fleurs/de_de_1.wav` prints the German sentence.
- [ ] Error paths:
  - no arguments → exit 2 plus the usage line
  - `../ctc-0.6b-q4_k.gguf ../speech.wav` → exit 1, `error: unsupported model …`
  - `../tdt-1.1b-q4_k.gguf /nonexistent.wav` → exit 1, `error: transcription failed: …`
  - `/nonexistent.gguf ../speech.wav` → exit 1, `error: cannot load model …`
  - none of them prints a stack trace
- [ ] `zig build -Doptimize=ReleaseFast -Dvulkan=true` followed by the tdt-1.1b command: same text on stdout, with `pk::Backend using device: Vulkan0` on stderr. `ldd zig-out/bin/zarakeet-cli` shows `libvulkan.so.1`.
- [ ] Cross-build: `zig build -Dtarget=x86_64-windows-gnu -Dcpu=x86_64_v3 -Dvulkan=true` exits 0, and `zig-out/bin/zarakeet-cli.exe` imports `vulkan-1.dll` (`grep -a -c vulkan-1.dll` ≥ 1).
- [ ] Back in the repo root: `zig build`, `zig build test -Doptimize=ReleaseFast` and `zig build bench -Doptimize=ReleaseFast` still behave exactly as after Stage 11.
- [ ] `example/cli/.zig-cache/` and `example/cli/zig-out/` are ignored by the existing `.gitignore` patterns. Check with `git check-ignore` if the project has become a git repository by then; otherwise confirm the patterns have no leading `/`.
- [ ] Report: the files created, the CLI's stdout for each command above, and the exit codes.

---

## Open follow-ups

These are small fixes found in review. Do each one when you touch the file it's in, and tick it off in your report.

- [x] **`src/root.zig`, test "all declared C functions exist":** now uses runtime references (`std.mem.doNotOptimizeAway`), including the two Stage 10 functions. Done.
- [x] **`.gitignore`:** stray `zig-out-*` line removed; the file now contains exactly the lines listed under "Final repository layout" (`__pycache__/` added 2026-09-27; stale `example/__pycache__/` deleted).
- [x] **`.gitignore` + `example/`:** resolved: only `example/*.gguf` (and `.part`) is ignored; `speech.wav`, `out.txt`, `main.zig` and `sweep.py` are tracked (they're small).
- [x] **Stage 7 completion:** models downloaded and verified; 9/9 tests pass in all three configurations. Done.
- [x] **Deleted stray `__.SYMDEF`** (ar-unpack leftover in the project root).
- [x] **Nemotron language tag (upstream behavior, needs a decision from the project owner).** Resolved: option B — plain text cleaned in the Zig layer, JSON raw. On `example/speech.wav` with `lang=en`:
  - offline: `Well, I don't wish to see it any more, observed Phoebe, turning away her eyes.  It is certainly very like the old portrait. ` (double space, trailing space)
  - streaming: `Well, I don't wish to see it any more, observed Phoebe, turning away her eyes. <en-US> It is certainly very like the old portrait. <en-US>`
  - Cause: upstream's offline path removes every `<...>`/`[...]` token (`strip_special_tokens`, `src/tokenizer.cpp:42`); the streaming path only removes `<EOU>`/`<EOB>`. The leftover spaces come from removing the tag.
  - Options: leave it as upstream does (document it), or clean it in the Zig layer (remove `<xx-YY>` tags and collapse whitespace in `Stream.feed`/`finalize`). **Decision: option B** — the private `cleanText` in `src/root.zig` removes the tags and normalizes whitespace in the four plain-text functions (`transcribeFile`, `transcribePcm`, `Stream.feed`, `Stream.finalize`); the `*Json` functions keep upstream's raw output, so the language information remains available there. `example/out.txt` gained the cleaned nemotron reference line.
- [x] **Windows/macOS Vulkan linking.** Resolved: W2 + M1 — Windows links a `zig dlltool`-generated import lib from `src/vulkan-1.def`; macOS `-Dvulkan=true` rejected at configure time.
  - Windows: the import library names the 3 `vk*` functions ggml calls directly (`vkGetInstanceProcAddr`, `vkGetPhysicalDeviceFeatures2`, `vkCmdCopyBuffer`); everything else is resolved at runtime. Cross-verified on `x86_64-windows-gnu` and `aarch64-windows-gnu` (the .exe imports `vulkan-1.dll`); not yet run on real hardware.
  - macOS: `-Dvulkan=true` fails at configure time (Vulkan there needs MoltenVK; the GPU path on macOS would be Metal, out of scope). macOS stays CPU only.
- [x] **README review:** every build command in `README.md` verified as-is, including the require-all and portable-build commands and the dependency/usage snippets (the latter via a scratch consumer build). Done.
- [x] **`example/bench/sweep.py`** (moved from `example/sweep.py` in Stage 11): compares each model's transcript against `example/out.txt` (mismatch → `WRONG` cell + exit 1; missing reference → `NO-REF`), reports the median of N runs per configuration (`--runs`, default 3), and notes that the first model's time includes backend warm-up. Done.


- [x] **Final cleanup (2026-09-27):** plan moved to `doc/`; `README.md` rewritten for users (models, platforms, usage, benchmark, credits); `doc/notes.md` written (technical reference and maintenance playbooks); logo added (`doc/logo.svg`, `doc/logo-icon.svg`).

### Not done yet (next steps, each needs the project owner's decision)

- [x] **License:** MIT (`LICENSE`, "the zarakeet authors", 2026), added 2026-09-27; the README has a License section.
- [ ] **Publishing.** The project isn't a git repository and has no package URL yet. The README's `zig fetch --save <zarakeet package url>` is a placeholder.
- [ ] **CI.** Nothing runs automatically. A minimal CI would cover:
  - `zig build test`, without models
  - cross-builds for `x86_64-windows-gnu`, `aarch64-linux-gnu` and `aarch64-macos`
  - optionally, a model-test job that caches `example/*.gguf`
- [ ] **Real-hardware runs.** Windows (CPU and Vulkan), Linux aarch64 and macOS have only been cross-compiled and linked, never run.
- [ ] **Upstream reports** (optional; any fix would let us simplify):
  - parakeet.cpp's streaming text keeps language tags (`<en-US>`).
  - parakeet.cpp has no language-aware `transcribe_path_json`.
  - ggml's `vulkan-shaders-gen` ignores glslc's exit status.
- [ ] **Metal on macOS:** assessed in `doc/todo-metal.md`; waiting on its three open decisions.

---

## Final report (every worker, every stage)

Reply with:
1. Stage number and **Done when** checklist, each item ✅ or ❌.
2. The files you changed.
3. Exact commands run, with the tail of the output for any failure.
4. Anything you deviated from, or the question that made you stop.
