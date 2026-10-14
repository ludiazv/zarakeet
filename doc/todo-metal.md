# TODO: Metal backend for macOS

**Status:** assessment only. This is not an approved plan, and none of it is implemented. Metal is currently **out of scope** (see `doc/WORKER_PLAN.md`, rule 1), and macOS builds are CPU-only. This note records the recommended approach so it can become a worker plan later.

Based on the pinned sources: parakeet.cpp `e75de9b`, ggml `e705c5f`.

---

## Summary

| Question | Answer |
|---|---|
| Effort | Moderate: about 1–2 worker tasks. Less than the Vulkan backend: there's no shader generator and no feature tests. |
| Blocker 1 | It can only be **built on a Mac** with the Xcode Command Line Tools, because the macOS SDK frameworks are needed and can't be redistributed. |
| Blocker 2 | parakeet.cpp's two **Metal patches** for ggml (0002, 0003) are needed for good performance, and we can't patch the pinned sources. |
| Blocker 3 | **No Mac is available** for testing; that needs a Mac or a macOS CI runner. |
| API impact | None. parakeet already selects the `Metal` device and honors `PARAKEET_DEVICE`. |
| Runtime requirements | None. Metal is part of macOS. |

---

## Recommended approach

### 1. Build only natively on macOS
- Add a build option `-Dmetal=true` (default `false`).
- Reject it at configure time with `std.process.fatal`, the same style as the Vulkan checks, when:
  - the target isn't macOS (`!target.result.os.tag.isDarwin()`)
  - the host isn't macOS (`!b.graph.host.result.os.tag.isDarwin()`), because cross-compiling needs Apple's SDK, which can't be redistributed
  - it's combined with `-Dvulkan=true`, which is already rejected for macOS
- The macOS SDK becomes the **second allowed system dependency**, next to `glslc` for Vulkan. Zig locates it by itself on a Mac with the Xcode Command Line Tools (`xcode-select --install`). Document this in rule 2 of `doc/WORKER_PLAN.md` and in the README.

### 2. Use ggml's "embed library" mode (no Apple shader compiler)
- With `GGML_METAL_EMBED_LIBRARY`, the `.metal` shader **source** is embedded in the binary, and macOS compiles it at runtime on first use; Metal caches the result.
- So `xcrun metal` / `metallib` are **not** needed at build time. The only cost is a slower first model load.
- Upstream CMake prepares the embedded source (`src/ggml-metal/CMakeLists.txt`, lines 27–58):
  1. Take `ggml-metal.metal` and replace the `__embed_ggml-common.h__` marker line with the contents of `src/ggml-common.h`.
  2. Replace the `#include "ggml-metal-impl.h"` line with the contents of `src/ggml-metal/ggml-metal-impl.h`.
  3. Generate an assembly stub:
     ```
     .section __DATA,__ggml_metallib
     .globl _ggml_metallib_start
     _ggml_metallib_start:
     .incbin "<merged .metal path>"
     .globl _ggml_metallib_end
     _ggml_metallib_end:
     ```
- Zig equivalent: a **tiny host tool written in Zig** (about 40 lines) that takes the 3 input files and writes the merged `.metal` file plus the `.s` stub, using the merged file's path. Run it with `b.addRunArtifact`, and add the generated `.s` to the library as an assembly source. Don't use `sed`; the build stays Zig-only.

### 3. Sources, defines and frameworks
- **Sources** (from `ggml/src/ggml-metal/`), added to the same `zarakeet_c` library:
  - C++: `ggml-metal.cpp`, `ggml-metal-device.cpp`, `ggml-metal-common.cpp`, `ggml-metal-ops.cpp`
  - Objective-C: `ggml-metal-device.m`, `ggml-metal-context.m`. Zig's clang compiles `.m` files. The code does manual retain/release, so **no `-fobjc-arc`** (upstream doesn't set it either).
  - the generated `.s` stub from step 2
- **Defines:** `GGML_USE_METAL` (so `ggml-backend-reg.cpp` registers the backend), `GGML_METAL_EMBED_LIBRARY`, and optionally `GGML_METAL_NDEBUG`.
- **Frameworks:** `Foundation`, `Metal` and `MetalKit`. Link them on the **consumer modules** (test, `zarakeet`, example) with `linkFramework`, not on the static library. That mirrors how Vulkan links `vulkan` / `vulkan-1`. Verify the 0.17 API name (`Module.linkFramework`) first.

### 4. Apply the Metal patches: use a patched ggml fork (recommended)
- **What the patches do.** Both only add ops to what Metal supports:
  - `0002-metal-conv-2d-dw.patch` adds a Metal kernel for `GGML_OP_CONV_2D_DW` (depthwise conv-2D).
  - `0003-metal-pad-leading.patch` lets Metal's `GGML_OP_PAD` handle leading padding; it previously refused to.
- **Without them the results are still correct,** but both ops fall back to the CPU. They occur in **every conformer layer**, so each layer bounces between GPU and CPU. That likely costs a large share of the speed-up; upstream reports Metal at up to ~5× faster than CPU on an M4, measured with the patches.
- **Recommendation:** create a fork of `ggml-org/ggml` at `e705c5f` with parakeet.cpp's patches applied as commits, and point the single `ggml` dependency in `build.zig.zon` at that fork's tarball.
  - Apply **all four** patches (0001–0004). The ggml we build is then identical to what upstream parakeet.cpp builds on every platform.
    - 0001 is a CPU performance change and is a no-op for single-clip transcription.
    - 0004 touches only CUDA files, which we don't build.
  - Document the fork URL, base commit and patch list in `doc/WORKER_PLAN.md` §1.1 and in the README.
  - Re-check the pins whenever parakeet.cpp bumps its ggml submodule or its patches.
- **Alternatives, not recommended:**
  - A patch applier as a Zig build step: more code to maintain (~100+ lines).
  - Copying the 5 patched Metal files into this repo: breaks the "never copy upstream" rule.
  - Shipping unpatched Metal: correct but slow; only acceptable as a first step.
  - Waiting for ggml upstream to merge the patches: they were written by parakeet.cpp's author, so this is plausible. When it happens, return to the official ggml tarball.

### 5. Verification (needs a Mac or a macOS CI runner)
- `zig build test -Dmetal=true -Doptimize=ReleaseFast` with the Stage 7 env vars: 11/11, no leaks.
- `zig build example -Dmetal=true -Doptimize=ReleaseFast`: the log shows the `Metal` device, and all transcripts match `example/out.txt`.
- `PARAKEET_DEVICE=cpu` still works on the Metal build.
- Performance: run `example/sweep.py` with added `metal` configurations, and compare against the CPU numbers on the same Mac.
- Check that the process exits cleanly with and without `zarakeet.shutdown()`. Upstream's shutdown note mentions GPU drivers in general.
- Confirm the configure-time errors: `-Dmetal=true` on a Linux host, for a Linux target, and together with `-Dvulkan=true`.

### 6. Rough size
| Piece | Estimate |
|---|---|
| `build.zig`: option, checks, sources, defines, frameworks | ~40–60 lines |
| Shader-embedding host tool plus build steps | ~40 lines |
| Patch handling via the fork | a `build.zig.zon` URL/hash change, plus maintaining the fork |
| README, `doc/WORKER_PLAN.md`, `sweep.py` configurations | small |

---

## Open decisions before this becomes a plan
1. Is a Mac, or a macOS CI runner such as GitHub Actions `macos-14` (Apple Silicon), available for building and testing?
2. Is a patched ggml fork acceptable, and who owns it? Or should we wait for ggml upstream, or accept an unpatched (slower) Metal first?
3. Should Metal be the default on macOS (`-Dmetal` defaulting to `true` for macOS targets built on a Mac), or stay opt-in like Vulkan?
