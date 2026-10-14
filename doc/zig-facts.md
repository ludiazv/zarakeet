# Zig 0.16/0.17 — facts and lessons learned (zarakeet project)

> **Migrated to Zig 0.17.0 (2026-10).** The body below was verified against
> **0.16.0** and is kept as a historical record; where 0.17 changed an API the
> project uses, the **0.17 addendum** at the end of this file has the verified
> replacement. Line numbers refer to the 0.16.0 std files and are a shortcut
> for re-verification; the API can change between Zig versions, so when in
> doubt, grep the real source before using an API.

---

## 1. `std.Build` (build.zig)

### 1.1 Options and targets

- `b.standardTargetOptions(.{})` → `ResolvedTarget`; `b.standardOptimizeOption(.{})` → `std.builtin.OptimizeMode`.
- `b.option(T, name, desc)` returns `?T` (use `orelse default`). Works with `bool`, `[]const u8`, enums, ints.
- `b.args` is `?[]const u8`: the args after `--` on the `zig build` command line. Forward to a run step with `if (b.args) |args| run.addArgs(args);` so `zig build bench -- --fleurs` works.
- `target.result.os.tag` — compare with `== .linux`, `== .windows`, or call `.isDarwin()` (`Target.zig:79`).
- `target.result.cpu.arch` — `switch` on `.x86_64`, `.aarch64`, etc.
- **Dependency options:** `b.dependency(name, .{ .field = value, ... })` converts the struct fields into the dependency's option map (`userInputOptionsFromArgs`):
  - `ResolvedTarget` → serialized to the `target` option (zig triple) plus a `cpu` option
  - `bool` → `"true"` / `"false"` scalar
  - enum → `@tagName`
  - int → `{d}`
  The dependency's `b.option(T, name, ...)` / `standardTargetOptions` / `standardOptimizeOption` then read them. So a consumer does `b.dependency("zarakeet", .{ .target = target, .optimize = optimize, .vulkan = vulkan })` and zarakeet's `b.option(bool, "vulkan", ...)` sees it.
- `standardTargetOptionsQueryOnly` reads `b.option([]const u8, "target"/"cpu"/"ofmt", ...)`; `standardOptimizeOption` reads `b.option(bool, "release", ...)` plus the preferred mode.

### 1.2 Modules

- `b.createModule(.{...})` — **no name argument** (that's `b.addModule`).
- `b.addModule(name, .{...})` — public module, referenceable by consumers via `dep.module(name)`.
- Module options: `.root_source_file = b.path("src/root.zig")`, `.target`, `.optimize`, `.link_libc`, `.link_libcpp`.
- `module.addIncludePath(LazyPath)`, `module.addCMacro(name, value)`, `module.addCSourceFiles(.{ .root, .files, .flags })`, `module.addCSourceFile(.{ .file, .flags })`.
- **`addCMacro` always emits `-DNAME=value`** — bare C macros (value 1 per C standard 5.1.1.2.1) must be passed as `addCMacro("GGML_USE_CPU", "1")`.
- `module.linkLibrary(artifact)` — link a library artifact (e.g. our static lib) into the module.
- `module.linkSystemLibrary("vulkan", .{})` — **on a module that builds a static library this embeds the `.so` as an archive member** and breaks lld later. Link system libraries on the *consumer* modules (test/exe modules), not on the static-lib module.
- `module.addObjectFile(LazyPath)` (`Build/Module.zig:460`) — add a raw object/import library (used for the Windows `libvulkan-1.a`).
- `module.addImport("zarakeet", other_module)` — or after creating an exe: `exe.root_module.addImport(...)` (`Step.Compile.root_module` is a `*Module`).

### 1.3 Artifacts and steps

- `b.addLibrary(.{ .name, .root_module, .linkage = .static })` → `*Step.Compile`.
- **`b.addExecutable(.{ .name, .root_module, ... })` — there is NO `root_source_file` field in `ExecutableOptions`** (`Build.zig:770`). Create a module first:
  ```zig
  const exe = b.addExecutable(.{
      .name = "zarakeet-cli",
      .root_module = b.createModule(.{
          .root_source_file = b.path("src/main.zig"),
          .target = target,
          .optimize = optimize,
      }),
  });
  exe.root_module.addImport("zarakeet", dep.module("zarakeet"));
  ```
- `b.addTest(.{ .name, .root_module })`.
- `b.addRunArtifact(artifact)` → `*Step.Run`; hook with `b.step("name", "desc").dependOn(&run.step)`.
- `b.addSystemCommand(&.{ path, "arg", ... })` (`Build.zig:927`) — e.g. `&.{ b.graph.zig_exe, "dlltool", "-d" }` (`b.graph.zig_exe` at `Build.zig:120`).
- `b.installArtifact(artifact)` — `zig build` installs only what is installed; run-only steps (test/example/bench) install nothing.
- Run-step args: `run.addArg(s)`, `run.addArgs(&[_][]const u8{...})`, `run.addFileArg(LazyPath)`, `run.addPrefixedFileArg("", LazyPath)`.
- Run-step outputs: `run.addOutputFileArg(name)` and `run.addOutputDirectoryArg(name)` both return `LazyPath` — declare **every** file a step writes as an output, and never let one step write into another step's output dir.
- **Cache hygiene:** `run.clearEnvironment()` (`void`), then `run.setEnvironmentVariable(k, v)` for a minimal env. Without `clearEnvironment` first, `setEnvironmentVariable` copies and hashes the *entire* parent environment — any unrelated env change regenerates everything (measured: 66 s vs ~1 s for 154 shader steps). We set only `GLSLC_VERSION` (the `glslc --version` output) so a glslc upgrade regenerates shaders.
- `b.graph.host` — host target (for host tools like `vulkan-shaders-gen`).
- `b.graph.environ_map` — `std.process.Environ.Map` of the build environment (use `.get("PATH")`).
- `b.dependency(name, args)` → `*Dependency`; `b.lazyDependency(name, .{})` → `?*Dependency` (`.lazy = true` in the zon; loaded only when needed). `dep.path("sub/dir")` → `LazyPath`.

### 1.4 Paths

- `b.path("rel/path")` → `LazyPath`.
- `LazyPath.getPath3(b, null)` → `std.Build.Cache.Path` (concrete cached path).
- `Cache.Path.joinString(gpa, "")` → `[]const u8`.
- `LazyPath.dirname()` → `LazyPath`.
- `std.fs.path.join(gpa, &.{ "a", "b" })` → `[]u8` (no NUL); `std.fs.path.basename(p)`.

### 1.5 `build.zig.zon` (0.16 format)

- Root `.name` must be an **enum literal** (`.zarakeet`), not a string.
- Top-level `.paths` is **required** (e.g. `.{ "build.zig", "build.zig.zon", "src", "README.md" }`).
- Root package **requires `.fingerprint`**; if wrong/missing, `zig build` prints the value to use (`invalid fingerprint: 0x0; if this is a new or forked package, use this value: 0x…`).
- `.dependencies`:
  - fetched: `.name = .{ .url = "…", .hash = "…" }` (via `zig fetch --save=name <url>`); `.lazy = true` optional.
  - local: `.name = .{ .path = "../.." }` — **relative** path, **no fingerprint/hash needed**.
- Fetched packages are stored in `zig-pkg/` inside the project (gitignored). A path-dependency consumer gets its **own** `.zig-cache/`, `zig-out/`, `zig-pkg/` in its own directory.

### 1.6 Configure-time user errors

- `std.process.fatal(comptime format, args)` — logs via `std.log.err` (prints `error: …`), **exits 1, no stack trace**. Use for every user-caused configuration error (missing glslc, bad target, option combos).
- `std.debug.panic(...)` / `@panic("…")` — for internal "can't happen" errors (OOM, missing lazy dep, unreadable dir).
- `std.debug.print(...)` writes to **stderr**.

---

## 2. `std.Io` (the 0.16 I/O model)

- An `std.Io` instance is passed around explicitly (no implicit global).
  - Own instance: `var io_instance = std.Io.Threaded.init(std.heap.page_allocator, .{}); const io = io_instance.io();` (deinit at scope end).
  - From the process entry point: `init.io` (see §3).
- **Files:** `std.Io.File.stdout()`, `std.Io.File.stderr()` (`Io/File.zig:91/104`).
  - `std.Io.File.writeStreamingAll(file, io, bytes: []const u8) Writer.Error!void` (`Io/File.zig:623`) — **no format args**; pre-format with `std.fmt.allocPrint` if needed.
- **Dirs:** `std.Io.Dir.cwd()`.
  - `dir.readFileAlloc(io, path, gpa, limit)` — **io is the 2nd argument**; limit e.g. `std.Io.Limit.unlimited`. (There is no `std.fs.cwd().readFileAlloc` in 0.16.)
  - `dir.openDir(io, path, .{ .iterate = true })` — **`.iterate = true` is REQUIRED**; without it iteration crashes with BADF.
  - `var it = dir.iterate(); while (it.next(io)) |entry| { entry.name, entry.kind (== .file) }`; `defer dir.close(io)`.
- **Clock:** `std.Io.Clock.Timestamp.now(io, .boot)`; `t0.durationTo(t1)` → `Duration`; nanoseconds via `d.raw.nanoseconds` (convert with `@as(f64, @floatFromInt(d.raw.nanoseconds)) / 1e9`).

---

## 3. `std.process`

### 3.1 The `main(init: std.process.Init) !void` entry point

`std.process.Init` (`process.zig:30`):

```zig
pub const Init = struct {
    minimal: Minimal,          // struct { environ: Environ, args: Args }
    arena: *std.heap.ArenaAllocator,  // call .allocator()
    gpa: Allocator,            // default allocator (leak-checked in Debug)
    io: Io,                    // default Io
    environ_map: *Environ.Map,
    preopens: Preopens,
};
```

- Args: `const args = try init.minimal.args.toSlice(init.arena.allocator());` — `Args.toSlice(a: Args, arena: Allocator) ToSliceError![]const [:0]const u8` (`process/Args.zig:479`). **Elements are `[:0]const u8`** (already NUL-terminated — pass straight to C-style APIs). `args[0]` is the program name.
- There is **no `std.process.argsAlloc`** in 0.16.
- `std.process.exit(status: u8) noreturn` (`process.zig:854`).
- Returning an error from `main` prints `error: <Name>` to stderr and exits 1 — acceptable for OOM-style propagation.
- Arena allocations (`init.arena.allocator()`) are freed automatically at exit — fine for error messages you print immediately.

### 3.2 Spawning processes (configure-time)

- `std.process.run(gpa, io, .{ .argv = &[_][]const u8{ "cmd", "arg" } })` → `RunResult { term: Child.Term, stdout: []const u8, stderr: []const u8 }`.
- **`Child.Term` is a `union(enum)`** — test with `switch (res.term) { .exited => |code| code == 0, else => false }`, not `==`.

---

## 4. `std.mem`

- **`std.mem.readInt(comptime T, buffer: *const [N]u8, endian) T`** — takes a **pointer to a fixed-size array**, NOT a slice. From a byte slice: `std.mem.readInt(u16, &.{ b[2], b[3] }, .little)`.
- `std.mem.eql(comptime T, a: []const T, b: []const T) bool` — the only string compare (switch-on-strings is gone).
- `std.mem.splitScalar(u8, s, delim)` — returns an iterator; **`next` takes `*Self`**, so bind it: `var it = …; while (it.next()) |piece|`.
- `std.mem.indexOfScalar(u8, s, byte) ?usize`; `std.mem.endsWith(u8, s, suffix) bool`; `std.mem.trim(u8, s, " \t\r")`.
- `std.mem.sliceTo(ptr, comptime end)` (`mem.zig:952`) — slice up to (not including) the first `end` byte.
- `std.mem.concat(gpa, u8, &.{ "a", "b" })` → `[]u8`.
- `std.mem.span(p)` — `[*:0]u8` / `[*:0]const u8` → `[]u8` (uses the NUL sentinel).
- `std.mem.doNotOptimizeAway(&value)` — keep a runtime reference alive (used to force-link every declared C function; see §7.4).

### 4.1 `std.mem.Allocator` (0.16)

- `alloc(T, n) Error![]T`, `free(slice)`, `dupe(T, m) Error![]T`.
- **`dupeZ(allocator, T, m) Error![:0]T`** (`Allocator.zig:461`) — NUL-terminated copy; the clean way to turn a `[]u8` path into a `[:0]const u8` for C APIs. Also `allocSentinel` (246) and `dupeSentinel` (466).
- **There is NO `appendSlice`** on `mem.Allocator` in 0.16 (compiling against it: `no field or member function named 'appendSlice'`).

---

## 5. `std.fmt`, `std.ArrayList`, `std.atomic`, misc

- `std.fmt.allocPrint(gpa, comptime fmt, args)` → `[]u8`.
- Format specifiers: `{d}` (int), `{d:.3}` / `{d:.1}` (float — **`{d:.1f}` is INVALID** in 0.16), `{s}` (string), `{s}` works on `[]const u8` and `[:0]const u8`.
- `std.ArrayList(T)` = `array_list.Aligned(T, null)`:
  - `var list = std.ArrayList(u8).empty; defer list.deinit(gpa);`
  - `list.appendSlice(gpa, items)`, `list.append(gpa, item)`, `list.items`.
  - `list.print(gpa, fmt, args)` exists; **there is no `writer` method**.
- `std.atomic.Value(u32)`: `var v = std.atomic.Value(u32).init(0);` — `v.load(.monotonic)`, `v.fetchAdd(1, .monotonic)`, `v.fetchSub(1, .monotonic)`.
- `std.math.cast(c_int, x) ?c_int` — `orelse return error.…` on overflow.
- `std.testing`: `std.testing.allocator` (leaks fail the test), `std.testing.tmpDir`, `std.testing.expectEqual`, and `error.SkipZigTest` to skip a test at runtime.

---

## 6. Language semantics (0.16)

### 6.1 `try` / `catch` — the one that bit us

- **`try f() catch |err| { … }` is a COMPILE ERROR** ("expected error union type, found 'T'"): `catch` already unwraps the error union, so the operand of `try` is the payload type.
- Correct patterns:
  ```zig
  // noreturn handler → expression type is the payload
  var model = zarakeet.Model.load(path) catch |err| {
      …print…;
      std.process.exit(1);
  };

  // selective handler, propagate the rest out of the function
  const text = model.transcribeFile(gpa, wav, .{}) catch |err| {
      if (err == error.TranscribeFailed) { …; std.process.exit(1); }
      return err;
  };
  ```
- A catch block whose every path is noreturn (`std.process.exit`, `return err`) makes the whole `f() catch …` expression have the payload type — no `try` needed.

### 6.2 Other semantics

- **`defer` runs LIFO** — declare `defer zarakeet.shutdown()` *before* `defer model.deinit()` so shutdown runs *last*.
- **Switch on strings does not exist** — use `std.mem.eql(u8, a, b)`.
- **No `for (integer)`** — write `for (0..n) |i|`.
- `@as(f64, i96_val)` is invalid for int→float — use `@as(f64, @floatFromInt(i96_val))`. `@floatFromInt` is single-arg with destination inferred from `@as`.
- **String literals coerce to `[*:0]const u8`, not to `[]u8`** (mutable). To get a mutable `[]u8`, allocate.
- `[:0]u8` (from `dupeZ`) coerces to `[:0]const u8` freely.
- Anonymous-struct return types with error unions work: `fn f() !struct { pcm: []f32, seconds: f64 }`.
- Multi-operand `for`: `for (slice, 0..) |*elem, i|`.
- Labeled blocks: `blk: { … break :blk value; }`.
- `unreachable` / `@panic("…")` for impossible paths.
- Quoted identifiers for hyphenated names in struct literals: `.@"vulkan-require-all" = true`.
- `@tagName(enum_value)`, `@errorName(err)`, `@TypeOf(x)`, `@min(a, b)`.
- `orelse`, `catch`, `switch` on error sets: `switch (err) { error.Foo => …, else => |e| e }`.
- Top-level `pub const c = @import("c.zig");` — **a loop variable named `c` shadows it** ("capture shadows declaration of 'c'"); rename the loop var.
- **Two-pass algorithms:** if pass 2 reuses locals mutated by pass 1, re-seed them from the source state (we shipped a bug where pass 2 kept pass 1's `started`/`pending` flags → spurious leading space + 1-byte OOB write; caught by the first test run).
- Inline `if` with a runtime condition inside an arithmetic expression → compile error; use an explicit `var` + `if` statement.
- `&.{ a, b, c }` — pointer to an anonymous array literal (used to feed `std.mem.readInt`).

---

## 7. C interop (hand-written externs — no `@cImport`/translate-c, per project rule)

### 7.1 Type mapping (C → Zig)

| C | Zig |
|---|---|
| `char*` return | `?[*:0]u8` |
| `const char*` param | `?[*:0]const u8` (or `[*:0]const u8` when non-NULL) |
| `const float*` | `[*]const f32` |
| `const int*` | `[*]const c_int` |
| `int*` out-param | `?*c_int` |
| `T*` out-param that may be NULL | `*?[*]T` — **the inner pointer must be optional** (C writes NULL when there are no events; e.g. `parakeet_capi_stream_drain_events(handle, &raw)` with `var raw: ?[*]parakeet_stream_event = null`) |
| opaque struct | `pub const name = opaque {};` |
| C struct | `pub const name = extern struct { … };` |
| `int` | `c_int` |

### 7.2 String ownership

- C returns heap strings → copy then free:
  ```zig
  fn takeString(gpa: Allocator, p: ?[*:0]u8) Error![]u8 {
      const s = p orelse return error.TranscribeFailed;
      defer c.parakeet_capi_free_string(s);
      return gpa.dupe(u8, std.mem.span(s));
  }
  ```

### 7.3 Macros for C sources

- `module.addCMacro(name, "value")` always emits `-DNAME=value` (see §1.2).
- Upstream C doing null-pointer arithmetic (legal in C) is rejected by Zig **Debug safety** at runtime; 0.16 has **no per-module `no_safety`** (safety is tied to the optimize mode) → build the frozen upstream C/C++ with `c_optimize = .ReleaseFast` when the user picks Debug.

### 7.4 Forcing link of every declared symbol

- `std.mem.doNotOptimizeAway(&c.<fn>)` **inside a normal test body** (runtime reference) forces the symbol to be linked.
- A `comptime { _ = &c.<fn>; }` block is NOT enough: the reference only survives through Debug debug info, so a missing symbol passes silently under `-Doptimize=ReleaseFast` (verified).

---

## 8. Build / link / toolchain behavior

- **`zig build` does not propagate a run-step child's exit code.** `std/Build/Step.zig:729`: `.exited => |code| if (code != 0) s.fail("process exited with error code {d}", .{code})` — `zig build` exits **1** and the child's code only appears in the message. To check a program's real exit code, run the built binary from `.zig-cache/o/<hash>/` directly.
- **Cross-target run steps fail by design**: `zig build test -Dtarget=x86_64-windows-gnu` links fine, then the run step fails with `unable to spawn foreign binary …` (same-arch, wrong OS) or `the host system (…) is unable to execute binaries from the target (…)`. The *link* succeeding is the signal; the .exe lives in `.zig-cache/o/<hash>/`.
- **Windows import libraries:** `zig dlltool -d file.def -m i386:x86-64|arm64 -l out.a` (keep `-l <output>` last). The linker pulls import-library members **only when referenced** — an empty `main` produces an exe with zero `vulkan-1.dll` refs; a real program that uses the API pulls all members and gets the import-table entry. Verify with `grep -a -c 'vulkan-1.dll' <exe>`.
- **macOS cross-builds** produce BSD-style ar archives containing a `__.SYMDEF` member — an artifact, not an error (a stray one was once found unpacked in the repo root and deleted).
- **Windows cross-builds** install COFF `.lib` archives.
- `zig build test` cosmetic quirk: under `--listen` the stderr may show `failed command` + a `w` marker even when everything passed — **exit 0 = all pass**; for explicit counts run the cached test binary directly (`.zig-cache/o/<hash>/zarakeet tests --cache-dir=./.zig-cache`).
- `zig build` installs only artifacts passed to `b.installArtifact`; run-only steps (test/bench) don't install.
- Cache keys: run steps hash their declared outputs, args, environment (post-`clearEnvironment`), and input files. Declaring a side-output (e.g. glslc's `.d` file) as a step output turns "silent hollow output" into a step failure.
- A `zig build` failure at configure time via `std.process.fatal` prints `error: …` and exits 1 — no stack trace, no build-graph noise.
- `zig fetch --save=name <url>` writes the dep + hash into `build.zig.zon`; fetched sources land in `zig-pkg/`.
- A `.path` dependency builds the referenced project's `build.zig` as a function with the forwarded options; its own `-D`-style options come from the args struct (§1.1), and its cache lives in the *consumer's* `.zig-cache`.

---

## 9. Quick gotcha list (things that actually broke a build)

1. `openDir` without `.iterate = true` → BADF crash at iterate.
2. `std.mem.readInt` with a slice arg → compile error; use `&.{ b[i], b[i+1] }`.
3. `readFileAlloc` arg order: `(io, path, gpa, limit)` on `std.Io.Dir` — io is 2nd.
4. `for (integer)` → error; `for (0..n) |i|`.
5. `@as(f64, intValue)` → error; `@as(f64, @floatFromInt(intValue))`.
6. `{d:.1f}` → error; `{d:.1}`.
7. `try f() catch |err| {…}` → "expected error union type"; drop the `try`.
8. `mem.Allocator.appendSlice` → doesn't exist in 0.16; use `dupeZ`/`concat`.
9. `addExecutable(.{ .root_source_file = … })` → no such field; use `root_module`.
10. `std.fs.cwd().readFileAlloc` → doesn't exist; `std.Io.Dir.cwd().readFileAlloc(io, …)`.
11. `std.process.argsAlloc` → doesn't exist; `init.minimal.args.toSlice(init.arena.allocator())`.
12. `linkSystemLibrary` on the static-lib module → `.so` embedded in the archive → lld failure.
13. `setEnvironmentVariable` without `clearEnvironment` → whole parent env hashed into the step → mass shader regeneration.
14. Loop var shadowing a top-level `pub const c` → "capture shadows declaration".
15. Two-pass function reusing pass-1 locals in pass 2 → wrong output + OOB write; re-seed from source state.
16. `build.zig.zon`: string `.name` → error (enum literal); missing `.paths` → error; wrong `.fingerprint` → error that prints the right value.
17. Bare `char*`/`int*` C out-params declared non-optional → UB when C writes NULL; use `?*T` / `*?[*]T`.
18. `Child.Term` compared with `==` → it's a `union(enum)`; `switch` on it.
19. Expecting `zig build` to exit with the child's code → it exits 1; run the binary directly to verify program exit codes.
20. `std.debug.print` goes to **stderr** (fine for tests; don't use it for program stdout).

---

## 10. 0.17 addendum (verified against 0.17.0, 2026-07)

The project was migrated from 0.16 to 0.17.0. Every item below was verified
against the 0.17.0 std sources and by building/running this project.

### 10.1 `std.Build` (build.zig)

- **`b.args` is gone.** Args after `--` are no longer observable at configure
  time. Use `run.addPassthruArgs()` on the run step instead of
  `if (b.args) |args| run.addArgs(args);`. The step becomes always-uncached.
- **`LazyPath.getPath3` is removed.** There is no configure-time path resolver
  for lazy paths. For the glslc probes, `build.zig` uses the dependency's own
  builder instead: `ggml_dep.builder.root` is the `Cache.Path` of the
  directory the toolchain actually fetched ggml into, so
  `ggml_dep.builder.root.joinString(gpa, "src/…")` works from any CWD, with
  `ZIG_LOCAL_PKG_DIR`, and even when this package is built as a path
  dependency (the fetch then lands in the *main* build's `zig-pkg/`, not
  this package's own root — `b.root` points at the wrong directory there).
  Note: a slice obtained from `b.available_deps` (anonymous-struct element)
  cannot be used in a `"…" ++ hash` concat ("slice being concatenated must be
  comptime-known" — a general Zig rule, not a 0.17 delta; the migration just
  exposed it) — join through `Cache.Path` instead.
- **`b.lazyDependency` is subsumed by `b.dependency`.** In 0.17, calling
  `b.dependency` on an unfetched lazy dep exits the configure phase, the
  toolchain fetches it, and build.zig re-runs (`serializeConfigurationExiting`
  is `noreturn`). The `orelse @panic` guards are gone.
- **`build.zig` now runs as a cached *configurer* process.** On a warm cache
  the configurer is skipped entirely (warm `zig build` ≈ 0.04s). Any
  configure-time side effect (process runs, PATH scans) must call
  `b.graph.poisonCache()` or the build silently reuses stale configuration;
  `zig build --cache-poison=disallowed` turns *any* poisoning into a hard
  error (panic at the `poisonCache()` call site), including an explicit one —
  so a build whose configurer re-runs and poisons always fails under that
  flag. The Vulkan block poisons explicitly (it fails under the flag by
  design); the default build is pure and passes it.
- **`std.lang.Optimize` tags are lowercase**: `.debug`, `.fast`, `.safe`,
  `.small` (uppercase `.Debug` etc. remain only as deprecated *const values*,
  not enum members, so `switch` prongs and `==` break). `standardOptimizeOption`
  still parses legacy spellings like `-Doptimize=ReleaseFast` at the CLI.
- **`addOutputFileArg`/`addOutputDirectoryArg`/`addFileArg`/`addPrefixedFileArg`
  are deprecated** in favor of `addOutputFileArg2(arg, opts)` /
  `addOutputDirectoryArg2(name, opts)` / `addFileArg2(file, opts)` — the `*Arg2`
  variants merge plain and prefixed forms (`addPrefixedFileArg("", x)` ≡
  `addFileArg2(x, .{})`). The path variants (`addFileArg2`,
  `addOutputFileArg2`, `addOutputDirectoryArg2`, `addDirectoryArg2`,
  `addArtifactArg2`, `addDepFileOutputArg2`) take a `Run.PathArgOptions`
  `{ prefix, suffix, make_absolute }`; only `addFileContentArg2` takes the
  plain `Run.ArgOptions` `{ prefix, suffix }`.
- **`--pkg-path` is gone**; the 0.17 flag is `--fork=[path]` (override one or
  more projects from the dependency tree). `--system [pkgdir]` disables
  fetching.
- URL deps are still fetched into `zig-pkg/<hash>/` under the build root
  (same as 0.16); `b.available_deps` lists `.{name, hash}` pairs.

### 10.2 `std` library

- **`std.mem.indexOf` is removed** → `std.mem.find(haystack, needle: []const T)`
  (slice needle) or `std.mem.findScalar(haystack, needle: T)` (single element).
- **`std.fmt.allocPrint` is removed** → `allocator.print(comptime fmt, args)`
  (on `mem.Allocator`; `std.Io.Writer.print` for writers).
- **`Allocator.dupeZ` is removed** → `allocator.dupeSentinel(T, m, sentinel)`
  (the sentinel is now an explicit argument); likewise `allocSentinel`.
- `std.math.cast` and `std.debug.panic` still exist in 0.17.0 (left unchanged
  in the codebase).

### 10.3 Behavior / tooling

- **Test binaries are BSP servers**: `zig build test` runs them with
  `--listen=-` and drives them over the build server protocol. Running a test
  binary manually with `--listen=-` and no client on stdin panics with
  `EndOfStream` — that is expected, not a bug.
- **Known upstream bug #35202**: when the test child writes to stderr, a
  stale `failed command: … --listen=-` line is printed even on success; exit
  codes stay correct (verified: failing test → exit 1). Our
  `load nonexistent` test triggers it via the C library's stderr line.
- The `--listen=-` suffix on every command in `--verbose` output is a maker
  display artifact; child argv is clean (verified with an argv-dumping
  build).
- **0.17.0 known regressions** (release notes): #37006 (compiler-rt soft-float
  x86), #36986 (`std.debug.simple_panic` compile failure / weak libc
  symbols), #36444 (maker/configurer separation breaks response-file use in
  `Step.Run` — not used here), #37050 (SPIR-V backend).
- **Run-step caching ignores the inherited environment.** `zig build test`
  can replay a cached run even when env vars change (the model-gated tests
  read `ZARAKEET_*` env vars). To force a re-run, clear `.zig-cache` (a
  *failed* run step is not cached, so a failing run does re-run next time).
- **ZLS does not work with 0.17.0** (per the migration reference).
- `build.zig.zon` still requires `.fingerprint` (error prints the value to
  use), and `zig fmt` now formats `.zon` files too.