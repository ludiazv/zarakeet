<p align="center">
  <img src="doc/logo.svg" alt="zarakeet: a geometric parakeet speaking a waveform while perched on a line of text" width="560">
</p>

<p align="center">
  <b>Local speech-to-text for Zig.</b><br>
  NVIDIA Parakeet and Nemotron speech recognition, powered by
  <a href="https://github.com/mudler/parakeet.cpp">parakeet.cpp</a> and
  <a href="https://github.com/ggml-org/ggml">ggml</a>, and built with nothing but the Zig toolchain.
</p>

---

zarakeet turns audio into text on your own machine, on the CPU or on the GPU
through Vulkan. It wraps the excellent C++ engine
[parakeet.cpp](https://github.com/mudler/parakeet.cpp) in a small, idiomatic Zig
API. The engine is compiled from source by `zig build`: no CMake, no system
C++ compiler, no prebuilt binaries.

- **Offline transcription** of WAV files or raw audio samples.
- **Live streaming** with NVIDIA's Nemotron model: feed audio in chunks and get
  text as it's recognized.
- **Many languages:** English, plus 25+ European languages with the multilingual models.
- **Word timestamps and confidence** as JSON.
- **CPU or GPU (Vulkan)**, chosen with one build flag.
- **Cross-compiles** to Linux, Windows and macOS from any machine that has Zig.

## Quick start

**Requirements:** [Zig 0.16](https://ziglang.org/download/). For GPU builds you
also need `glslc`, the Vulkan shader compiler (Debian/Ubuntu package `glslc`,
Arch `shaderc`, or any Vulkan SDK).

1. Add zarakeet to your project:

   ```sh
   zig fetch --save <zarakeet package url>
   ```

   ```zig
   // build.zig
   const zarakeet = b.dependency("zarakeet", .{
       .target = target,
       .optimize = optimize,
       .vulkan = false, // true = GPU build (needs glslc)
   });
   exe.root_module.addImport("zarakeet", zarakeet.module("zarakeet"));
   ```

2. Get a model. The ready-to-use GGUF files are in
   [mudler/parakeet-cpp-gguf](https://huggingface.co/mudler/parakeet-cpp-gguf).
   The `q4_k` files are small and accurate; for example `tdt-0.6b-v3-q4_k.gguf`
   (675 MB, multilingual).

3. Transcribe:

   ```zig
   const std = @import("std");
   const zarakeet = @import("zarakeet");

   pub fn main() !void {
       const gpa = std.heap.page_allocator;
       defer zarakeet.shutdown(); // runs last, after every deinit below

       var model = try zarakeet.Model.load("tdt-0.6b-v3-q4_k.gguf");
       defer model.deinit();

       const text = try model.transcribeFile(gpa, "speech.wav", .{});
       defer gpa.free(text);
       std.debug.print("{s}\n", .{text});
   }
   ```

   ```
   Well, I don't wish to see it any more, observed Phoebe, turning away her eyes. It is certainly very like the old portrait.
   ```

## Supported models

zarakeet supports NVIDIA's **TDT** Parakeet models and **Nemotron streaming**.
Download them as GGUF files from
[mudler/parakeet-cpp-gguf](https://huggingface.co/mudler/parakeet-cpp-gguf).

| Model | Languages | Offline | Streaming |
|---|---|:---:|:---:|
| [parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | 25 European languages (detected automatically) | ✅ | — |
| [parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) | English | ✅ | — |
| [parakeet-tdt-1.1b](https://huggingface.co/nvidia/parakeet-tdt-1.1b) | English | ✅ | — |
| [parakeet-tdt_ctc-110m](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m), [parakeet-tdt_ctc-1.1b](https://huggingface.co/nvidia/parakeet-tdt_ctc-1.1b) | English | ✅ | — |
| [nemotron-3.5-asr-streaming-0.6b](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) | 40+ locales (automatic, or chosen) | ✅ | ✅ |

**Other models aren't supported.** That includes CTC-only Parakeet models and
the end-of-utterance model `parakeet_realtime_eou_120m`. zarakeet checks the
model file when loading it, and returns `error.UnsupportedModel` instead of
guessing.

## Platforms

| Platform | CPU | GPU (Vulkan) |
|---|:---:|:---:|
| Linux x86_64 | ✅ tested | ✅ tested (AMD Radeon, Mesa radv) |
| Linux aarch64 | ✅ builds | ✅ library builds (build your app on the device, where an arm64 `libvulkan` is available) |
| Windows x86_64 / aarch64 | ✅ builds | ✅ builds |
| macOS Apple Silicon | ✅ builds | ❌ not supported |

"Builds" means it cross-compiles and links, but hasn't been run on that platform
yet. Reports are welcome.

**At runtime:**
- CPU builds need nothing extra.
- GPU builds need the Vulkan loader and a driver:
  - **Linux:** `libvulkan.so.1`, i.e. the `libvulkan1` package plus Mesa or the
    NVIDIA driver.
  - **Windows:** `vulkan-1.dll`, which comes with every current GPU driver.
  - **macOS:** there's no Vulkan; use the CPU build.

## Usage

### Offline transcription

```zig
var model = try zarakeet.Model.load("tdt-0.6b-v3-q4_k.gguf");
defer model.deinit();

// From a WAV file: any sample rate, mono or stereo
const a = try model.transcribeFile(gpa, "talk.wav", .{});
defer gpa.free(a);

// From samples you already have: mono f32, any sample rate
const b = try model.transcribePcm(gpa, samples, 44100, .{});
defer gpa.free(b);
```

Every returned string belongs to you; free it with `gpa.free(...)`.

**Choosing a language.**
- **Nemotron** accepts a language code such as `"en"`, `"de"`, `"es"` or
  `"ja-JP"`. The default, `"auto"`, detects the language:
  `.{ .lang = "es" }`.
- **TDT models** ignore this option. `tdt-0.6b-v3` detects the language by
  itself.

### Live streaming (Nemotron)

```zig
var model = try zarakeet.Model.load("nemotron-3.5-asr-streaming-0.6b-q4_k.gguf");
defer model.deinit();

var stream = try model.stream(.{ .lang = "en" });
defer stream.deinit();

while (nextChunk()) |pcm16k| {             // mono f32 at 16 kHz, e.g. 0.5 s at a time
    const text = try stream.feed(gpa, pcm16k);
    defer gpa.free(text);
    if (text.len > 0) std.debug.print("{s}", .{text});   // newly recognized text
}
const rest = try stream.finalize(gpa);      // flush the end of the audio
defer gpa.free(rest);
```

Calling `stream()` on a TDT model returns `error.NotStreamingModel`.

### Timestamps and confidence

`transcribeFileJson` / `transcribePcmJson` (and `feedJson` / `finalizeJson` when
streaming) return parakeet.cpp's JSON, with per-word start and end times and
confidence:

```json
{"text":"Well, I don't wish…","frame_sec":0.080000,
 "words":[{"w":"Well,","start":0.720,"end":0.800,"conf":0.6218}, …]}
```

### Threads and shutdown

- `zarakeet.setNumThreads(n)` sets the number of CPU threads for the whole
  process; 0 means the default, 8.
- `zarakeet.shutdown()` releases the compute backend. Call it once, at the end,
  after every model and stream is closed. It's recommended for GPU builds.

### Errors

| Error | Meaning |
|---|---|
| `error.UnsupportedModel` | The model file isn't one of the supported models. |
| `error.LoadFailed` | The file is missing or can't be read. |
| `error.TranscribeFailed` | For example: the audio couldn't be read, or an unknown language code was given. `model.lastError()` gives the details. |
| `error.NotStreamingModel` | `stream()` was called on a TDT model. |

## Building from source

```sh
zig build                              # library for this machine's CPU
zig build -Doptimize=ReleaseFast       # optimized
zig build -Dvulkan=true                # with the Vulkan GPU backend
zig build test                         # tests (model tests need downloaded models)
```

| Option | Default | What it does |
|---|---|---|
| `-Dvulkan=true` | `false` | Adds the Vulkan GPU backend. Needs `glslc`. |
| `-Dglslc=/path/to/glslc` | from `PATH` | Chooses which shader compiler to use. |
| `-Dvulkan-require-all=true` | `false` | Fails the build if your `glslc` is too old to compile every GPU shader. Use it for release builds. |
| `-Dcpu=x86_64_v3` | this machine | Target CPU level. See below. |
| `-Dtarget=x86_64-windows-gnu`, `aarch64-linux-gnu`, `aarch64-macos`, … | this machine | Cross-compile. |

**Building for other machines.** By default the build is tuned for *your* CPU,
and may crash on older ones. For binaries you'll hand out, pick a CPU level:
- `-Dcpu=x86_64_v3`: AVX2, supported by almost every x86 CPU from the last
  decade. This is the recommended choice.
- `-Dcpu=x86_64_v4`: AVX-512. It gave no gain in our tests.
- `-Dcpu=baseline`: avoid it; it's about 5× slower.

A portable GPU release build looks like this:

```sh
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v3 -Dvulkan=true -Dvulkan-require-all=true
```

Debian 13's `glslc` is slightly too old for `-Dvulkan-require-all`. It lacks
bfloat16 support, which only a few recent GPUs use. A current
[Vulkan SDK](https://vulkan.lunarg.com/) passes. Without the flag, the build just
skips those shaders with a warning.

## Examples

**Command-line tool:** [`example/cli/`](example/cli) is a complete, separate
project that uses zarakeet as a dependency. Copy it as a starting point for your
own project.

```sh
cd example/cli
zig build -Doptimize=ReleaseFast            # add -Dvulkan=true for the GPU
./zig-out/bin/zarakeet-cli ../tdt-0.6b-v3-q4_k.gguf ../fleurs/es_419_1.wav
# Fue tanta la cantidad de gente que se concentró que no todos pudieron acceder al funeral en la plaza de San Pedro.
```

**Benchmark:** [`example/bench/`](example/bench) measures speed and accuracy
(next section).

## Benchmark

Measured on an **AMD Ryzen 7 8700G** (Zen 4) with its built-in **Radeon 780M** GPU
(Mesa radv), Debian 13, `-Doptimize=ReleaseFast`, `q4_k` models.

**Speed** is shown as the real-time factor (RTF): processing time divided by audio
length, so lower is better. `0.040` means 7.4 s of audio takes 0.3 s, which is
25× faster than real time. Each value is the median of 3 runs on `example/speech.wav`.

| Model | CPU `x86_64_v3` | CPU `x86_64_v4` | GPU (Vulkan) |
|---|---:|---:|---:|
| tdt-0.6b-v3 | 0.062 (16×) | 0.063 (16×) | **0.042 (24×)** |
| tdt-1.1b | 0.076 (13×) | 0.083 (12×) | **0.050 (20×)** |
| nemotron, offline | 0.092 (11×) | 0.096 (10×) | **0.071 (14×)** |
| nemotron, streaming in 0.5 s chunks | 0.230 (4.3×) | 0.246 (4.1×) | **0.210 (4.8×)** |

The GPU builds above use `-Dcpu=x86_64_v3`. A `-Dcpu=baseline` build is about
5× slower on the CPU (RTF 0.28 for tdt-0.6b-v3), which is why it isn't
recommended.

**Accuracy** is shown as the word error rate (WER) against human transcripts of
14 clips from the [FLEURS](https://huggingface.co/datasets/google/fleurs) test
set. The rate is computed ignoring case and punctuation, and lower is better.
The results are the same on CPU and GPU (±0.3 points).

| Language | tdt-0.6b-v3 | nemotron (`auto`) |
|---|---:|---:|
| English | 5.0 % | 15.0 % |
| Spanish | 0.0 % | 0.0 % |
| French | 9.1 % | 11.4 % |
| German | 0.0 % | 5.8 – 7.7 % |
| Italian | 0.0 % | 6.5 – 8.7 % |
| Polish | 14.8 % | 25.9 % |
| Dutch | 6.9 % | 20.7 % |
| **All** | **4.4 %** | **11.3 – 11.6 %** |

Two clips per language is enough to catch regressions, but it's not a formal
accuracy benchmark. For that, see NVIDIA's model cards.

**What a run looks like** (`zig build bench -Dvulkan=true -Doptimize=ReleaseFast`,
with the streaming partial results shown as they arrive):

```
tdt-0.6b-v3-q4_k.gguf: Well, I don't wish to see it any more, observed Phoebe, turning away her eyes. It is certainly very like the old portrait.
  load 0.536s | transcribe 0.297s for 7.44s audio | RTF 0.040 (25.1x faster than real-time)
tdt-1.1b-q4_k.gguf: well i don't wish to see it any more observed phoebe turning away her eyes it is certainly very like the old portrait
  load 0.892s | transcribe 0.361s for 7.44s audio | RTF 0.049 (20.6x faster than real-time)
nemotron-3.5-asr-streaming-0.6b-q4_k.gguf: Well, I don't wish to see it any more, observed Phoebe, turning away her eyes. It is certainly very like the old portrait.
  load 0.547s | transcribe 0.431s for 7.44s audio | RTF 0.058 (17.2x faster than real-time)
  [1.0s] +"Well"
  [1.5s] +", I don't"
  [2.0s] +" wish to see"
  …
  [7.0s] +" the old port"
  [7.4s] +"rait"
  [7.4s] +"."
nemotron-3.5-asr-streaming-0.6b-q4_k.gguf (stream): Well, I don't wish to see it any more, observed Phoebe, turning away her eyes. It is certainly very like the old portrait.
  load 0.535s | transcribe 1.411s for 7.44s audio | RTF 0.190 (5.3x faster than real-time)
```

**Run it yourself:**

```sh
python3 example/download_models.py      # the 4 test models (~3 GB, checksum-verified)
zig build bench -Doptimize=ReleaseFast   # add -Dvulkan=true for the GPU; `-- --fleurs` adds the multilingual clips
python3 example/bench/sweep.py           # full sweep: 3 CPU levels × CPU/GPU, speed + WER tables
```

## Limitations

- Only the models listed under [Supported models](#supported-models) work.
- Streaming works only with Nemotron, and needs 16 kHz mono audio.
- `transcribeFileJson` always uses the model's default language. Use
  `transcribePcmJson` if you need to choose one.
- Nemotron marks each sentence with a language tag such as `<en-US>`. The plain
  text results remove these tags; the JSON results keep them, which is handy if
  you want to know which language was detected.
- GPU acceleration uses Vulkan only: no CUDA, and no Metal on macOS.
- Windows, aarch64 and macOS builds haven't been tested on real hardware yet.

## Credits

zarakeet is a thin layer; the real work is done by these projects:

- **[parakeet.cpp](https://github.com/mudler/parakeet.cpp)** by Ettore Di Giacinto
  and contributors (MIT): the C++ speech recognition engine and the GGUF model
  conversions.
- **[ggml](https://github.com/ggml-org/ggml)** by the ggml authors (MIT): the
  tensor library behind it, with its CPU and Vulkan backends.
- **NVIDIA** for the [Parakeet](https://huggingface.co/collections/nvidia/parakeet)
  and [Nemotron](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
  models. Each model has its own license; check its model card.
- **Khronos Group**: [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers)
  and [SPIRV-Headers](https://github.com/KhronosGroup/SPIRV-Headers).
- **Test audio:**
  - `example/speech.wav` is from [LibriSpeech](https://www.openslr.org/12)
    (CC BY 4.0), via parakeet.cpp's test fixtures.
  - `example/fleurs/` holds clips from Google's
    [FLEURS](https://huggingface.co/datasets/google/fleurs) (CC BY 4.0); see
    its [ATTRIBUTION.md](example/fleurs/ATTRIBUTION.md).

## License

zarakeet is released under the [MIT License](LICENSE).

The upstream projects keep their own licenses: parakeet.cpp and ggml are MIT.
The models are licensed by NVIDIA; check each model card. The test audio is
CC BY 4.0 (see [Credits](#credits)).

## Further reading

- [`doc/notes.md`](doc/notes.md): how zarakeet is built and organized, and how
  to maintain it (with the most detail on the Vulkan build).
- [`doc/zig-facts.md`](doc/zig-facts.md): Zig 0.16 notes and pitfalls.

<sub>The logo is a green geometric parakeet, the "keet" in zarakeet, drawn in Zig's
slanted, low-poly style. Its Zig-orange beak speaks a waveform, it perches on a
line of text, and its wing feathers form a zig-zag.</sub>
