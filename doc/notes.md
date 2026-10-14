# zarakeet — technical notes

These notes are for people who maintain zarakeet, or who want to understand how it
works under the hood. They explain how the repository is organized, what
`zig build` actually does (the Vulkan part in the most detail), why things are
done the way they are, and what to do when something upstream changes.

For **using** the library, read the [README](../README.md). For the history of
how it was built, stage by stage, see [`WORKER_PLAN.md`](WORKER_PLAN.md). For
Zig API details and pitfalls we ran into, see [`zig-facts.md`](zig-facts.md) (0.16-era, with a 0.17 addendum).

---

## 1. The big picture

zarakeet makes [parakeet.cpp](https://github.com/mudler/parakeet.cpp), a C++
speech-to-text engine built on [ggml](https://github.com/ggml-org/ggml), usable
from Zig, **built by the Zig toolchain alone**. There's no CMake, no system
compiler and no prebuilt binaries.

It's built in four layers:

```
 your Zig program
        │  @import("zarakeet")
        ▼
 src/root.zig      idiomatic Zig API: Model, Stream, errors, allocators,
                   model gate, text cleanup, setNumThreads/shutdown
        │
        ▼
 src/c.zig         hand-written `extern` declarations of the C API
        │
        ▼
 libzarakeet_c.a   one static library, compiled by `zig build` from:
                   ├── parakeet.cpp  (C++17 engine + its flat C API, parakeet_capi.h)
                   ├── ggml          (tensor library: CPU backend, optional Vulkan backend)
                   └── src/shim.cpp  (2 tiny extern "C" wrappers we add)
```

Three principles run through everything:

1. **Upstream code is compiled exactly as it is.** parakeet.cpp and ggml come in as
   pinned `build.zig.zon` dependencies. We never patch or copy their sources.
   Everything we need is either in upstream's public C API, or in our own tiny
   `src/shim.cpp`.
2. **Zig toolchain only.** The only exception is the system `glslc` shader
   compiler, which is needed for Vulkan builds only (§5).
3. **Deliberately small scope.** The library supports TDT models and
   `nemotron-3.5-asr-streaming-0.6b`, and exposes offline transcription,
   nemotron streaming and raw JSON. Batch transcription, N-best, the CTC head
   and device-selection APIs are left out on purpose.

---

## 2. Repository map

```
zarakeet/
├── build.zig            the whole build: library, Vulkan pipeline, tests, benchmark
├── build.zig.zon        pinned dependencies (parakeet.cpp, ggml, Vulkan/SPIR-V headers)
├── src/
│   ├── root.zig         public API + all tests (unit tests and env-gated model tests)
│   ├── c.zig            extern declarations (parakeet C API + a gguf subset)
│   ├── shim.cpp         extern "C" wrappers: set_num_threads, shutdown_backend
│   └── vulkan-1.def     Windows import definitions for the Vulkan loader
├── example/
│   ├── bench/           benchmark program (`zig build bench`) + sweep.py
│   ├── cli/             standalone consumer project (its own build.zig/.zon)
│   ├── fleurs/          14 multilingual test clips (CC-BY 4.0) + refs + fetch script
│   ├── download_models.py   downloads + SHA-256-verifies the test models
│   ├── speech.wav, out.txt  English test clip + exact expected transcripts
│   └── *.gguf           test models (gitignored, ~3 GB)
├── doc/
│   ├── notes.md         this file
│   ├── WORKER_PLAN.md   staged build plan + status (historical record)
│   ├── zig-facts.md     Zig API facts and pitfalls (0.16-era + 0.17 addendum)
│   ├── todo-metal.md    assessment of a possible Metal backend (not implemented)
│   └── logo.svg, logo-icon.svg, logo-icon.png
├── LICENSE              MIT
└── README.md
```

Generated or fetched directories you'll see locally, all gitignored:
- `.zig-cache/`: build cache.
- `zig-out/`: installed artifacts.
- `zig-pkg/`: fetched dependency sources. Zig keeps them **inside the
  project**. `example/cli/` gets its own copy, since it's a separate project.

---

## 3. The Zig layer (`src/`)

### 3.1 Bindings: `c.zig`

The C API (`include/parakeet_capi.h`, ABI version **6**) is declared **by hand**,
without `@cImport` or translate-c. That keeps the bindings to exactly the
functions we use, avoids depending on translate-c behavior across Zig versions,
and makes every C-to-Zig type decision explicit:
- nullable strings are `?[*:0]u8`
- out-pointers that C may set to NULL are `*?[*]T`

Only the functions the supported models can use are declared. The CTC-logits,
batch and N-best entry points are deliberately missing.

`c.zig` also declares a few functions from ggml's `gguf.h`. The model gate uses
them, and the tests use them to write small fake model files.

A test (`"all declared C functions exist"`) references every declared function at
**runtime** with `std.mem.doNotOptimizeAway`. That forces the linker to resolve
each symbol in every optimize mode. A `comptime` reference wouldn't be enough: it
only survives through debug info, so a missing symbol would pass silently in
ReleaseFast.

### 3.2 API: `root.zig`

- **`Model.load` runs the model gate first.** It reads two GGUF metadata keys,
  `parakeet.arch` and `parakeet.prompt.present`, and accepts:
  - `tdt` or `hybrid_tdt_ctc` → `Kind.tdt`
  - `rnnt` with a prompt → `Kind.nemotron`

  Everything else gets `error.UnsupportedModel`. That includes CTC-only models
  and the EOU-120m model, which is `rnnt` without a prompt.

  After the gate, it calls `parakeet_capi_load` and checks the ABI version is 6.
- **The transducer head is always forced** (`decoder = 2`), so hybrid TDT+CTC
  models never use their CTC head.
- **Strings.** Every string C returns is copied into the caller's allocator and
  freed on the C side immediately, so callers only deal with plain Zig slices.
- **Text cleanup (plain-text functions only).** Nemotron emits a language tag
  (`<en-US>`, `<de-DE>`, …) after each sentence; that's its language
  identification. Upstream removes it from offline text but leaves double or
  trailing spaces, and keeps it in streaming text.

  The private `cleanText` removes `<…>` tags (1–16 characters from
  `[A-Za-z0-9_-]`) and normalizes whitespace. A `Stream` carries a small state,
  so chunk boundaries never produce double spaces, and `finalize` drops the
  trailing one. The `*Json` functions return upstream's JSON untouched, so the
  language information is still available there.
- **PCM JSON workaround.** `transcribePcmJson` goes through upstream's batch
  JSON function with a single clip, and strips the surrounding `[`…`]`.
  Upstream has no single-clip PCM JSON function that accepts a language.

### 3.3 Process-wide state: `shim.cpp`

parakeet keeps **one compute backend per process**: a single thread pool, with
all model weights living on it. Two C++ functions control it, and neither is in
the C API, so `shim.cpp` wraps them as `extern "C"`:

| Zig | C++ | Notes |
|---|---|---|
| `setNumThreads(n)` | `pk::set_num_threads` | Default **8**, whatever the core count. Upstream measured 8 as faster than using every core on large desktop CPUs, because of cross-chiplet traffic. Applies to CPU work only. |
| `shutdown()` | `pk::shutdown_backend` | Frees the backend. It must run **after** every `Model`/`Stream` is deinitialized, because the weights live on the backend. `root.zig` counts live objects and asserts that in Debug. A later model load creates a new backend. Upstream needs it on CUDA to avoid an abort at exit; on Vulkan (radv) we observed a clean exit without it. |

---

## 4. The build, step by step (CPU)

### 4.1 Dependencies

`build.zig.zon` pins four tarballs:

| Name | What | Loaded |
|---|---|---|
| `parakeet_cpp` | parakeet.cpp at commit `e75de9b` | always |
| `ggml` | ggml at `e705c5f`, the **exact** commit of parakeet.cpp's submodule; GitHub tarballs don't include submodules | always |
| `vulkan_headers` | Khronos Vulkan-Headers `v1.4.364` | lazily, only with `-Dvulkan=true` |
| `spirv_headers` | Khronos SPIRV-Headers `vulkan-sdk-1.4.357.0` | lazily, only with `-Dvulkan=true` |

Lazy dependencies aren't even downloaded for CPU builds.

### 4.2 One static library, one C module

`build.zig` creates a single module, with libc and libc++ linked, that compiles
every C and C++ file into `libzarakeet_c.a`:

- **ggml core:** `ggml.c`, `ggml-alloc.c`, `ggml-quants.c`, `ggml.cpp`,
  `ggml-backend*.cpp`, `ggml-opt.cpp`, `ggml-threading.cpp` and `gguf.cpp`.
  `ggml-backend-dl.cpp` is needed even though we don't load backends
  dynamically: the registry code includes its header.
- **ggml CPU backend:** the core files, the AMX files (they compile to nothing
  unless the CPU has AMX), and llamafile's `sgemm.cpp`, the fast matrix kernels.
  Architecture files come from `arch/x86/` or `arch/arm/`, depending on the
  target. Any other architecture stops the configure step with a clear error.
- **parakeet.cpp:** exactly the `PARAKEET_SRC` list from its `CMakeLists.txt`.
  That includes the CTC, RNNT and batch sources: the C API references them, even
  though the Zig API never uses them.
- **`src/shim.cpp`.**

**Defines**, which mirror what upstream's CMake passes:

| Define | Why |
|---|---|
| `GGML_USE_CPU=1` | registers the CPU backend |
| `GGML_USE_LLAMAFILE=1` | enables llamafile's matrix kernels |
| `GGML_SCHED_MAX_COPIES=4` | ggml's default |
| `GGML_VERSION`, `GGML_COMMIT` | reported by ggml; keep them in sync with the pin |
| `PARAKEET_VERSION` | reported by parakeet |
| `_GNU_SOURCE`, `_XOPEN_SOURCE=600` | Linux only, as in upstream |

`addCMacro` always emits `-DNAME=value`, so bare flags are passed as `"1"`.

**Not defined, on purpose:**
- `GGML_USE_OPENMP`: ggml uses its own thread pool instead, so there's no
  libgomp dependency.
- `GGML_BACKEND_DL`: backends are linked statically, not loaded as shared
  libraries at runtime.

### 4.3 CPU features are chosen at compile time

ggml-cpu picks its SIMD code with `#if defined(__AVX2__)` and similar checks. The
target CPU chosen at build time decides which paths exist, and there's **no
runtime dispatch** in our build. (Upstream can build several CPU variants and
choose one at runtime with `GGML_BACKEND_DL`, but that means shared libraries and
several builds, which we don't want.)

| `-Dcpu=` | Meaning | Measured (tdt-0.6b-v3, `speech.wav`) |
|---|---|---|
| *(default, native)* | everything the build machine supports; **crashes (SIGILL) on CPUs without those features** | — |
| `x86_64_v3` | AVX2, FMA, F16C, BMI2: the recommended portable level | RTF 0.059 |
| `x86_64_v4` | adds AVX-512; no gain on Zen 4 | RTF 0.062 |
| `baseline` | SSE2 only: **don't ship this** | RTF 0.279 (~5× slower) |

RTF (real-time factor) is processing time divided by audio length, so lower is
faster.

### 4.4 Debug builds still optimize the C/C++

ggml does pointer arithmetic on null pointers, which is legal in practice in C but
trapped by Zig's Debug safety checks. Zig 0.17 can't turn safety off per module,
so `build.zig` compiles **the upstream C/C++ with ReleaseFast whenever
`-Doptimize=Debug`** (`c_optimize`). Only our Zig code gets Debug mode. That also
avoids UBSan symbols ending up in the static library.

### 4.5 Upstream's ggml patches aren't applied

parakeet.cpp's CMake applies four patches to its ggml submodule with `git apply`.
We don't, since we never modify upstream:

| Patch | Effect on us |
|---|---|
| 0001 CPU: merge broadcast GEMM calls | Speed only. It never triggers for single-clip transcription, because it needs a batch dimension. |
| 0002, 0003 Metal kernels | Metal isn't built (see `todo-metal.md`). |
| 0004 CUDA | CUDA isn't built. |

Transcripts are identical to upstream's on CPU and Vulkan.

### 4.6 What the output links against

- The C++ runtime (Zig's bundled libc++) is linked **statically**.
- glibc is **dynamic** on `*-linux-gnu` targets. A fully static `*-linux-musl`
  CPU build is possible in principle, but musl static binaries can't `dlopen`, so
  it isn't an option for Vulkan.

### 4.7 Build steps

| Command | What it does |
|---|---|
| `zig build` | Builds and installs `libzarakeet_c.a`. |
| `zig build test` | Runs unit tests. The model tests run only when their env vars are set: `ZARAKEET_TDT_MODEL`, `ZARAKEET_NEMOTRON_MODEL`, `ZARAKEET_CTC_MODEL` and `ZARAKEET_WAV`. |
| `zig build bench [-- --fleurs]` | Runs the benchmark program. |

The public module `zarakeet` (`b.addModule`) is what consumers import. It links
the static library and, for Vulkan builds, the loader (§5.6). Every other module
is internal (`b.createModule`).

---

## 5. The Vulkan build (`-Dvulkan=true`) in depth

This is the most involved part of the build. ggml's Vulkan backend ships its GPU
kernels as ~150 GLSL compute-shader templates. At build time they must be
expanded into many variants and compiled to SPIR-V, and the bytes are embedded
into C++ source that's compiled into the library. Upstream does this with CMake
custom commands; we do it with Zig build steps.

### 5.1 The pipeline at a glance

```
configure time (runs every `zig build -Dvulkan=true`, before any step)
  1. -Dvulkan on a macOS target?            → error (§5.8)
  2. resolve glslc to an absolute path      (-Dglslc, or search PATH)
  3. glslc --version                        → GLSLC_VERSION (cache key)
  4. 4 feature tests with glslc             → list of GGML_VULKAN_*_GLSLC_SUPPORT macros
  5. -Dvulkan-require-all and a test failed? → error listing what's missing
  6. list the *.comp files (154 of them)    → one build step per file

build time (cached steps)
  A. compile vulkan-shaders-gen             (a C++ host tool from ggml; built for the
                                             build machine, with the macros from 4)
  B. vulkan-shaders-gen --target-hpp        → ggml-vulkan-shaders.hpp
     (header mode: declarations only)
  C. 154 × vulkan-shaders-gen --source X.comp --glslc <abs path> ...
        → runs glslc on every variant of X  → X.comp.cpp (SPIR-V bytes as C arrays)
                                            + X.comp.cpp.d (glslc's depfile)
  D. compile ggml-vulkan.cpp + the 154 .cpp files into libzarakeet_c.a
     with -DGGML_USE_VULKAN and the macros from 4
  E. consumers link the Vulkan loader       (Linux: libvulkan, Windows: generated
                                             import library; §5.6)
```

### 5.2 Finding `glslc`

`glslc` is the one tool outside Zig. It comes from shaderc; install the `glslc`
package on Debian/Ubuntu or `shaderc` on Arch, or use a Vulkan SDK.

- `-Dglslc=/path/to/glslc` is used as given if it contains a `/`.
- Otherwise the build searches the parent environment's `PATH` and keeps the
  first `glslc` that runs `--version` successfully.
- If none is found, the configure step stops: `error: glslc not found in PATH …`.

**Why an absolute path matters.** The shader steps run with a **cleared
environment** (§5.4), so `glslc` must be found without `PATH`. There's a second,
nastier reason: upstream's generator **ignores glslc's exit status**. If glslc
couldn't run, the generator would still exit 0 and write a `.cpp` with no shader
bytes. Zig would cache that as a success, and the build would fail much later at
link time, with thousands of undefined shader symbols.

### 5.3 Feature tests: compile-time capability vs runtime capability

ggml has four optional shader families. Each needs a GLSL extension that older
`glslc` versions can't compile:

| Test shader | Extension | Macro | Enables |
|---|---|---|---|
| `coopmat.comp` | `GL_KHR_cooperative_matrix` | `GGML_VULKAN_COOPMAT_GLSLC_SUPPORT` | matrix multiply on hardware matrix units (any vendor) |
| `coopmat2.comp` | `GL_NV_cooperative_matrix2` | `GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT` | NVIDIA's second-generation version, also used for flash attention |
| `integer_dot.comp` | `GL_EXT_integer_dot_product` | `GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT` | int8 dot products for quantized weights (q4/q5/q8) |
| `bfloat16.comp` | `GL_EXT_bfloat16` | `GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT` | native bf16 shaders |

Each test runs the exact command upstream CMake uses:
`glslc -o - -fshader-stage=compute --target-env=vulkan1.3 <test>.comp`. Exit code 0
means supported. The resulting macro list goes to **both** the shader generator
(which variants to create) and `ggml-vulkan.cpp` (which variants to use). The
two lists must match, or the build fails with link errors, or leaves shaders unused.

Two separate questions are involved:
- **Compile time** (these tests): can this `glslc` *build* the shaders? With the
  pinned ggml, **the shader set depends only on the `glslc` used.** `-Dcpu`,
  `-Doptimize`, the target and the build machine's GPU don't matter.
- **Runtime** (ggml): does the user's GPU *support* the feature? ggml checks
  the device (e.g. `device->integer_dot_product`) and picks among the compiled
  variants. So a build with everything compiled in is portable across GPUs.

A missing feature never breaks the build; it just gives up some speed. Debian
13's `glslc` (glslang 15.1) lacks `GL_EXT_bfloat16`, which prints a single
warning. For release builds, `-Dvulkan-require-all=true` turns any missing
feature into a configure-time error. The error prints the `glslc` path and its
full `--version` output: the **glslang** line is the one that matters, not the
shaderc version.

### 5.4 Cache keys and the per-shader steps

Every one of the 154 steps is an ordinary Zig `Run` step, and the details of how
it's set up are what keep incremental builds fast and correct:

- **Separate output folders.** Each step gets **its own** `--output-dir` for
  scratch `.spv` files (`addOutputDirectoryArg("spv")`). No step may write into
  another step's output; Zig treats outputs as immutable. The generated `.cpp`
  embeds the SPIR-V bytes, so the `.spv` files are never read afterwards.
- **The generated header** (`ggml-vulkan-shaders.hpp`) is produced once, by the
  header step. Each shader step only receives its path (it `#include`s it by name).
- **Minimal environment.** `run.clearEnvironment()` followed by setting a single
  variable, `GLSLC_VERSION`. By default a run step's environment isn't part of
  its cache key. But as soon as you set *any* variable without clearing first,
  Zig copies **and hashes** the entire parent environment. Then any unrelated
  change (a new terminal, `PARAKEET_DEVICE=cpu`, a test env var) re-runs all 154
  steps: we measured 66 s, versus about 1 s cached. Clearing first means only
  `GLSLC_VERSION` is hashed, which is exactly what should force a rebuild:
  upgrading `glslc` regenerates the shaders.
- **Hollow-output guard.** Each step also declares `<shader>.cpp.d` as an output.
  glslc writes that depfile only when it actually compiled something, so a
  silently failed `glslc` makes the step fail instead of caching an empty `.cpp`.
- **Parallelism.** The generator runs several `glslc` processes at once, and Zig
  runs steps in parallel as well. A first build keeps all cores busy for a while.
  After that, everything is cached until `glslc`, the generator or ggml changes.

### 5.5 Headers

`ggml-vulkan.cpp` includes `vulkan/vulkan.hpp` and SPIR-V's `spirv.hpp`. Both come
from the **pinned** header dependencies, not from the system (`libvulkan-dev` /
`spirv-headers` may also be installed but are ignored). That gives identical
builds on every machine, and it lets cross-compiling work, since Zig doesn't
search `/usr/include` when building for another target.

### 5.6 Linking the Vulkan loader

`ggml-vulkan.cpp` uses Vulkan-Hpp's dynamic dispatcher, so almost every Vulkan
function is looked up at runtime. Exactly **three** are called directly and
therefore need the loader at link time: `vkGetInstanceProcAddr`,
`vkGetPhysicalDeviceFeatures2` and `vkCmdCopyBuffer`.

| Target | How the loader is linked | At runtime |
|---|---|---|
| Linux | `linkSystemLibrary("vulkan")` | `libvulkan.so.1` + a driver (Mesa radv, NVIDIA, …) |
| Windows | a build step runs **`zig dlltool`** on `src/vulkan-1.def` (the 3 functions) to make `libvulkan-1.a`, an import library for `vulkan-1.dll` (`-m i386:x86-64` or `arm64`) | `vulkan-1.dll`, installed by every GPU driver |
| macOS | not supported (§5.8) | — |

The loader is linked on the **consumer modules** (tests, benchmark and the public
`zarakeet` module), **never on the static library**. Zig would put the shared
library into the `.a` as an archive member, and the final link would then fail.
Someone using `libzarakeet_c.a` directly must link the loader themselves; on
Windows, `zig dlltool -d src/vulkan-1.def` produces the import library.

Consequences:
- A Vulkan build **needs the loader just to start**, even with
  `PARAKEET_DEVICE=cpu`.
- Cross-building anything that *links* for Linux needs a libvulkan for the
  target. Building the library alone doesn't.
- Windows doesn't need an SDK at all: everything, including the import library,
  comes from Zig. The Windows build is cross-verified (the `.exe` imports
  `vulkan-1.dll`) but **hasn't been run on real Windows hardware yet**.

### 5.7 At runtime

- **Device choice.** parakeet uses the first GPU that ggml's registry reports
  (log line: `pk::Backend using device: Vulkan0`). `PARAKEET_DEVICE=cpu` or
  `PARAKEET_DEVICE=Vulkan1` overrides it.
- **CPU fallback per operation.** Any operation the Vulkan backend has no kernel
  for runs on the CPU automatically.
- **Speed on the reference machine** (Radeon 780M iGPU, radv): about
  **1.4–1.7× faster** than the best CPU build, and the CPU level no longer
  matters (see the README's benchmark).

### 5.8 macOS

On macOS, Vulkan only exists through MoltenVK (Vulkan translated to Metal).
`-Dvulkan=true` with a macOS target stops at configure time with a clear error.
The right GPU path on a Mac would be ggml's Metal backend; its assessment is in
[`todo-metal.md`](todo-metal.md).

### 5.9 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `error: glslc not found in PATH` | Install glslc (shaderc), or pass `-Dglslc=/abs/path`. |
| One `glslc: … not supported` line | That shader family is skipped. Normal with older glslc; use `-Dvulkan-require-all` to make it an error. |
| All shaders regenerate on every build | An environment variable is being hashed. Check that every shader step calls `clearEnvironment()` before setting variables (§5.4). |
| Thousands of undefined `*_data`/`*_len` symbols at link time | The generator produced empty `.cpp` files (glslc failed). The `.d` guard should catch this. Check that glslc runs by itself. |
| `unable to find dynamic system library 'vulkan'` | Install the loader (`libvulkan-dev` / `libvulkan1`), or you're cross-building for Linux without a target libvulkan. |
| Undefined `vk*` symbol on Windows after a ggml update | ggml now calls another Vulkan function directly: add it to `src/vulkan-1.def`. |
| Log shows the CPU device instead of `Vulkan0` | No Vulkan driver is visible (check `vulkaninfo --summary`), or `PARAKEET_DEVICE` is set. |

---

## 6. Why these Zig choices

- **Hand-written externs rather than `@cImport`** (§3.1): explicit types, only the
  API we support, and no dependency on translate-c changes.
- **One static library plus one public module.** Consumers do one
  `addImport("zarakeet", …)` and get the C++ code, libc++ and (for Vulkan) the
  loader.
- **`std.process.fatal` for configuration mistakes, panics for "can't happen".**
  A missing `glslc`, a bad target or a bad combination of options prints
  `error: …` and exits 1, with no stack trace. Out-of-memory and missing
  dependency files still panic, because they indicate a bug.
- **Lazy dependencies** for the Vulkan headers, so CPU builds never download them.
- **A Python helper for the sweep only.** `sweep.py`, `download_models.py` and
  `fleurs_fetch.py` are developer tools and use only the standard library. The
  library build never needs Python.
- **Zig specifics** (the `std.Io` model, `main(init: std.process.Init)`,
  the `build.zig.zon` format, and so on) are collected in
  [`zig-facts.md`](zig-facts.md).

---

## 7. Testing and verification

| Layer | How | Needs |
|---|---|---|
| Unit tests | `zig build test`: ABI version, symbol existence, the model gate (on fake GGUF files), `cleanText`, threads and shutdown | nothing |
| Model tests | the same command plus 4 env vars: TDT offline/PCM/JSON, nemotron offline + streaming + invalid language, CTC rejection, shutdown and reload | models (`example/download_models.py`) |
| Benchmark | `zig build bench`: exact transcripts vs `example/out.txt` plus timing; `-- --fleurs` adds 14 multilingual clips | models |
| Sweep | `example/bench/sweep.py`: 6 configurations (3 CPU levels × CPU/Vulkan), median RTF, exact-transcript check, FLEURS WER per language, `--max-wer` gate | models, glslc for the Vulkan configurations |
| Consumer | `example/cli/`: a separate project that builds against the library by path | models |

The full model-test command:

```
ZARAKEET_TDT_MODEL=example/tdt-1.1b-q4_k.gguf \
ZARAKEET_NEMOTRON_MODEL=example/nemotron-3.5-asr-streaming-0.6b-q4_k.gguf \
ZARAKEET_CTC_MODEL=example/ctc-0.6b-q4_k.gguf ZARAKEET_WAV=example/speech.wav \
zig build test -Doptimize=ReleaseFast            # add -Dvulkan=true for the GPU path
```

**Reference values.** `example/out.txt` holds exact expected transcripts; our
q4_k builds reproduce them on CPU and Vulkan. FLEURS transcripts are written by
humans, so they're compared by word error rate. The reference corpus WER is
**4.4 %** for tdt-0.6b-v3 and **~11.5 %** for nemotron (`lang=auto`); the worst
clip is 40 % (Polish).

---

## 8. Maintenance playbooks

### 8.1 Bumping parakeet.cpp

1. `zig fetch --save=parakeet_cpp https://github.com/mudler/parakeet.cpp/archive/<commit>.tar.gz`.
2. Diff upstream's `CMakeLists.txt` `PARAKEET_SRC` list against `build.zig`.
   Add or remove files, keeping the same order as upstream.
3. Diff `include/parakeet_capi.h`:
   - **ABI version changed?** Read upstream's changelog comment at the top of the
     header, update `c.zig`, and change the `!= 6` check in `Model.load`.
   - Signatures of the functions we declare must match exactly.
4. Check the gate keys (`parakeet.arch`, `parakeet.prompt.present`) in
   `src/model_loader.cpp`, and whether new architecture names exist.
5. **Check the ggml submodule commit** (`git ls-tree <commit> third_party/ggml`,
   or the GitHub tree view). If it moved, do §8.2 as well.
6. Check `third_party/ggml-patches/`. New patches may matter for correctness;
   decide case by case, as in §4.5.
7. Run the model tests, the benchmark and the sweep. If transcripts change on
   purpose, update `example/out.txt` (and the nemotron reference string in
   `src/root.zig`'s test).

### 8.2 Bumping ggml

1. Use **the commit parakeet.cpp's submodule points to**, not ggml's latest.
   `zig fetch --save=ggml https://github.com/ggml-org/ggml/archive/<commit>.tar.gz`.
2. Update `GGML_VERSION` / `GGML_COMMIT` in `build.zig` (`ggml/CMakeLists.txt`
   has the version).
3. Diff the source lists in `ggml/src/CMakeLists.txt` (core) and
   `ggml/src/ggml-cpu/CMakeLists.txt` (CPU, arch files, llamafile) against
   `build.zig`.
4. **Vulkan** (`ggml/src/ggml-vulkan/CMakeLists.txt`):
   - the list of `test_shader_extension_support(...)` calls → our `feature_tests`
     table (file names and macros)
   - the `vulkan-shaders-gen` arguments (`--glslc --source --output-dir
     --target-hpp --target-cpp`), and whether it still writes the `.d` depfile
     next to the `.cpp` (§5.4 relies on it)
   - build with `-Dtarget=x86_64-windows-gnu -Dvulkan=true`. Any undefined `vk*`
     symbol means ggml calls a new Vulkan function directly: add it to
     `src/vulkan-1.def`.
5. Rebuild CPU and Vulkan, then run the tests and the sweep.

### 8.3 Bumping the Vulkan / SPIR-V headers

Pick a newer tag, update it with `zig fetch --save=vulkan_headers …` /
`--save=spirv_headers …`, and keep `.lazy = true` in `build.zig.zon`. The two
should come from the same SDK generation. Newer ggml versions can require
newer headers, and older headers usually show up as compile errors in
`ggml-vulkan.cpp`.

### 8.4 Bumping Zig

The build uses many 0.17-specific APIs: `std.Io`, the `Run` step's environment
handling, `std.process.Init` and the `build.zig.zon` format. Read the release
notes, then work through [`zig-facts.md`](zig-facts.md) section by section. Pay
particular attention to cache hashing of run-step environments (§5.4), since a
change there could silently bring back the shader-regeneration problem. Since
0.17, `build.zig` runs as a cached *configurer* process; any configure-time
side effect (the glslc probes) must keep `b.graph.poisonCache()` honest, and
configure-time paths must not use `LazyPath` (see the 0.17 addendum in
`zig-facts.md`).

### 8.5 Supporting another model family

Extend the gate in `root.zig` (`detectKind`) and its table test, add a model test,
and document the model in the README. Check first that the model works through
the transducer head (`decoder = 2`). CTC-only models would need the CTC decoder,
which is deliberately left out of this API.

### 8.6 Test assets

- **Models:** `python3 example/download_models.py` downloads the models and
  verifies their SHA-256 against Hugging Face's own checksums.
- **FLEURS clips:** `python3 example/fleurs/fleurs_fetch.py [--langs …] [--n N]`
  reproduces the set deterministically. Keep `ATTRIBUTION.md` in sync when
  adding languages; the license is CC-BY 4.0.

---

## 9. Known limitations and open ends

- **Windows Vulkan** is built and linked, but hasn't been run on real hardware.
- **macOS** is CPU only. Metal has been assessed ([`todo-metal.md`](todo-metal.md)):
  it's feasible, but it needs a Mac for building and testing, and a decision on
  upstream's Metal patches.
- **aarch64** builds but has never been run; no ARM host was available.
- `transcribeFileJson` has no language option, because upstream has none.
- The CPU thread count is process-wide (upstream design) and defaults to 8.
- There's no CI, and the project isn't a git repository yet.
