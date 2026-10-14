#!/usr/bin/env python3
"""Sweep the zarakeet benchmark across x86 CPU feature levels and backends.

For each configuration runs:
    zig build bench -Doptimize=ReleaseFast <flags>
N times (default 3; the first run builds, the rest reuse the cached build)
and reports the median RTF and transcribe time, plus a comparison table.

Each model's transcript is checked against example/out.txt (one
"<model file>: <text>" line per model): a mismatch marks the cell WRONG and
makes the script exit 1; a model missing from out.txt is marked NO-REF and
does not fail the run.

Word error rate (WER) on the multilingual clips in example/fleurs/
(references in refs.tsv) is reported per model, language and configuration.
Only the first run of each configuration passes -- --fleurs, so --runs N
does not multiply the WER cost; one sample per configuration is enough
because WER does not depend on timing. The normalization matches the values
recorded in doc/WORKER_PLAN.md section 1.3. Any clip whose WER is above
--max-wer (default 0.5) fails the sweep, as does a missing (model, clip)
pair.

Zig 0.17 names: "portable" is spelled "baseline"; the microarchitecture
levels are "x86_64_v3" / "x86_64_v4". The "vulkan+..." configurations
add -Dvulkan=true: they need glslc at build time and libvulkan.so.1 plus
a Vulkan driver at runtime, and transcribe on the GPU (the -Dcpu level
then only affects the CPU-side code).

Run from anywhere (paths are resolved relative to this file):
    python3 example/bench/sweep.py [--runs N] [--no-wer] [--max-wer X]
"""

import argparse
import os
import re
import statistics
import subprocess
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ZIG = os.environ.get("ZIG", "zig")
OUT_FILE = ROOT / "example" / "out.txt"
REFS_FILE = ROOT / "example" / "fleurs" / "refs.tsv"
FLEURS_MODELS = ["tdt-0.6b-v3-q4_k.gguf", "nemotron-3.5-asr-streaming-0.6b-q4_k.gguf"]

# (label, build flags)
CONFIGS = [
    ("portable", ["-Dcpu=baseline"]),
    ("x86_v3", ["-Dcpu=x86_64_v3"]),
    ("x86_v4", ["-Dcpu=x86_64_v4"]),
    ("vulkan+portable", ["-Dvulkan=true", "-Dcpu=baseline"]),
    ("vulkan+x86_v3", ["-Dvulkan=true", "-Dcpu=x86_64_v3"]),
    ("vulkan+x86_v4", ["-Dvulkan=true", "-Dcpu=x86_64_v4"]),
]

PERF_RE = re.compile(
    r"load (\d+\.\d+)s \| transcribe (\d+\.\d+)s for (\d+\.\d+)s audio"
    r" \| RTF (\d+\.\d+) \((\d+\.\d+)x faster than real-time\)"
)


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


def load_reference() -> dict[str, str]:
    """example/out.txt: one '<model file>: <text>' line per model."""
    ref = {}
    for line in OUT_FILE.read_text().splitlines():
        if ": " in line:
            model, text = line.split(": ", 1)
            ref[model] = text
    return ref


def load_refs() -> list[tuple[str, str, str]]:
    """example/fleurs/refs.tsv: (file, language, transcript) per row."""
    rows = []
    for line in REFS_FILE.read_text().splitlines():
        if not line:
            continue
        parts = line.split("\t")
        if parts[0] == "file":
            continue  # header
        rows.append((parts[0], parts[1], parts[3]))
    return rows


def run_once(flags: list[str], fleurs: bool) -> tuple[dict[str, dict] | None, dict[str, dict[str, str]]]:
    """Build and run the benchmark once.

    Returns ({model: perf_dict}, {model: {file: text}}). The FLEURS dict is
    only filled when `fleurs` is true (-- --fleurs).
    """
    cmd = [ZIG, "build", "bench", "-Doptimize=ReleaseFast"] + flags
    if fleurs:
        cmd += ["--", "--fleurs"]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"  FAILED (exit {proc.returncode})", file=sys.stderr)
        sys.stderr.write(proc.stderr)
        return None, {}

    results = {}
    fleurs_results: dict[str, dict[str, str]] = {}
    lines = proc.stdout.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("FLEURS\t"):
            _, model, file, text = line.split("\t", 3)
            fleurs_results.setdefault(model, {})[file] = text
            continue
        m = PERF_RE.search(line)
        if m and i > 0 and ": " in lines[i - 1]:
            model, text = lines[i - 1].split(": ", 1)
            results[model] = {
                "text": text,
                "load": float(m.group(1)),
                "transcribe": float(m.group(2)),
                "audio": float(m.group(3)),
                "rtf": float(m.group(4)),
                "speedup": float(m.group(5)),
            }
    return (results or None), fleurs_results


def run_config(label: str, flags: list[str], runs: int, do_wer: bool) -> tuple[dict[str, dict] | None, dict[str, dict[str, str]]]:
    """Run one configuration `runs` times; report medians.

    The first run passes -- --fleurs when do_wer, so the WER cost is paid
    once per configuration.
    """
    print(f"=== {label} ({' '.join(flags)}) ===")
    samples: dict[str, list[dict]] = {}
    fleurs_results: dict[str, dict[str, str]] = {}
    for run in range(1, runs + 1):
        print(f"  run {run}/{runs}")
        res, fl = run_once(flags, fleurs=(do_wer and run == 1))
        if res is None:
            return None, {}
        if fl:
            fleurs_results = fl
        for model, p in res.items():
            samples.setdefault(model, []).append(p)

    medians = {}
    for model, plist in samples.items():
        medians[model] = {
            "text": plist[-1]["text"],
            "load": statistics.median(p["load"] for p in plist),
            "transcribe": statistics.median(p["transcribe"] for p in plist),
            "audio": plist[0]["audio"],
            "rtf": statistics.median(p["rtf"] for p in plist),
            "speedup": statistics.median(p["speedup"] for p in plist),
        }
    for model, p in medians.items():
        print(f"{model}: RTF {p['rtf']:.3f} "
              f"({p['speedup']:.1f}x, transcribe {p['transcribe']:.3f}s)")
    print()
    return medians, fleurs_results


def wer_for_model(model: str,
                  texts: dict[str, str] | None,
                  refs: list[tuple[str, str, str]]) -> dict | None:
    """Corpus WER for one model in one configuration.

    Returns None when the configuration produced no FLEURS output, or a dict
    with:
      missing: True when a (model, clip) pair is absent
      groups:  {language: (edits, ref_words), "all": (edits, ref_words)}
      clips:   {file: (wer, ref_text, hyp_text)}
      worst:   (wer, file)
    """
    if texts is None:
        return None
    groups: dict[str, tuple[int, int]] = {}
    clips: dict[str, tuple[float, str, str]] = {}
    total_edits = 0
    total_words = 0
    worst = (0.0, "")
    missing = False
    for file, lang, ref in refs:
        if file not in texts:
            missing = True
            continue
        refw = norm_words(ref)
        hypw = norm_words(texts[file])
        d = edit_distance(refw, hypw)
        wer = d / len(refw) if refw else 0.0
        e, w = groups.get(lang, (0, 0))
        groups[lang] = (e + d, w + len(refw))
        total_edits += d
        total_words += len(refw)
        clips[file] = (wer, ref, texts[file])
        if wer > worst[0]:
            worst = (wer, file)
    groups["all"] = (total_edits, total_words)
    return {"missing": missing, "groups": groups, "clips": clips, "worst": worst}


def report_wer(all_fleurs: dict[str, dict | None],
               refs: list[tuple[str, str, str]],
               max_wer: float) -> bool:
    """Print the WER tables; return True when the sweep must fail."""
    failed = False
    labels = [label for label, _ in CONFIGS]
    col_w = max(10, max(len(m) for m in FLEURS_MODELS) + 2)
    langs = []
    for _, lang, _ in refs:
        if lang not in langs:
            langs.append(lang)

    computed = {}
    for model in FLEURS_MODELS:
        for label in labels:
            fl = all_fleurs.get(label)
            texts = fl.get(model) if fl else None
            computed[(model, label)] = wer_for_model(model, texts, refs)

    for model in FLEURS_MODELS:
        print(f"=== WER: {model} (corpus WER per language, lower is better) ===")
        print(" " * col_w + "".join(f"{l:>16}" for l in labels))
        for row in langs + ["all"]:
            cells = []
            for label in labels:
                c = computed[(model, label)]
                if c is None:
                    cells.append("FAILED")
                elif c["missing"]:
                    cells.append("MISSING")
                    failed = True
                else:
                    edits, words = c["groups"][row]
                    cells.append(f"{100.0 * edits / words:.1f}%" if words else "-")
            print(f"{row:<{col_w}}" + "".join(f"{c:>16}" for c in cells))

        # Worst clip across all configurations for this model.
        worst = (0.0, "")
        for label in labels:
            c = computed[(model, label)]
            if c is not None and not c["missing"] and c["worst"][0] > worst[0]:
                worst = c["worst"]
        print(f"max clip WER: {100.0 * worst[0]:.1f}% ({worst[1]})" if worst[1] else "max clip WER: -")

        # Gate: any clip above --max-wer fails the sweep.
        for label in labels:
            c = computed[(model, label)]
            if c is None or c["missing"]:
                continue
            for file, (wer, ref, hyp) in c["clips"].items():
                if wer > max_wer:
                    failed = True
                    print(f"  {label}: {file} WER {100.0 * wer:.1f}% > {100.0 * max_wer:.1f}%")
                    print(f"    ref: {ref}")
                    print(f"    hyp: {hyp}")

        # CPU and Vulkan WER are expected to be equal or nearly equal.
        all_wers = []
        for label in labels:
            c = computed[(model, label)]
            if c is None or c["missing"]:
                continue
            edits, words = c["groups"]["all"]
            if words:
                all_wers.append(100.0 * edits / words)
        if all_wers and max(all_wers) - min(all_wers) > 2.0:
            print(f"note: WER differs across configurations for {model}")
        print()
    return failed


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Sweep the zarakeet benchmark across CPU levels and backends.")
    parser.add_argument("--runs", type=int, default=3,
                        help="runs per configuration (default 3); medians are reported")
    parser.add_argument("--no-wer", action="store_true",
                        help="skip the FLEURS WER check (no FLEURS transcriptions)")
    parser.add_argument("--max-wer", type=float, default=0.5,
                        help="fail if any clip's WER exceeds this (default 0.5)")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be >= 1")

    reference = load_reference()
    refs = [] if args.no_wer else load_refs()

    all_results = {}
    all_fleurs = {}
    for label, flags in CONFIGS:
        results, fl = run_config(label, flags, args.runs, do_wer=not args.no_wer)
        if results is None:
            all_results[label] = None
            all_fleurs[label] = None
            print("  (failed or no output)")
            print()
            continue
        all_results[label] = results
        all_fleurs[label] = fl

    # Comparison table: RTF (speedup) per model per configuration.
    models = []
    for results in all_results.values():
        if results:
            for model in results:
                if model not in models:
                    models.append(model)

    labels = [label for label, _ in CONFIGS]
    col_w = max(10, max(len(m) for m in models) + 2) if models else 10
    print("Note: each run's first model includes backend warm-up (device init / shader pipelines).")
    print("=== RTF comparison (lower is better) ===")
    print(" " * col_w + "".join(f"{l:>16}" for l in labels))
    wrong = False
    for model in models:
        cells = []
        for label in labels:
            results = all_results[label]
            if results and model in results:
                p = results[model]
                if model in reference:
                    if p["text"] != reference[model]:
                        cells.append("WRONG")
                        wrong = True
                    else:
                        cells.append(f"{p['rtf']:.3f} ({p['speedup']:.1f}x)")
                else:
                    cells.append("NO-REF")
            else:
                cells.append("FAILED")
        print(f"{model:<{col_w}}" + "".join(f"{c:>16}" for c in cells))

    if not args.no_wer:
        if report_wer(all_fleurs, refs, args.max_wer):
            print("WER gate failed (clip above --max-wer or missing FLEURS results)",
                  file=sys.stderr)
            return 1

    if wrong:
        print("transcript mismatch against example/out.txt", file=sys.stderr)
        return 1
    return 0 if all(r is not None for r in all_results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())