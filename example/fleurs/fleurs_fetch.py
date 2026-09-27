#!/usr/bin/env python3
"""Fetch a few short test clips per language from Google FLEURS (CC-BY 4.0).

Streams each language's FLEURS test archive (Hugging Face `google/fleurs`) and
stops after the first N matching clips, so only a small part of the archive is
downloaded. FLEURS stores 32-bit float WAV; clips are converted to 16 kHz mono
16-bit PCM WAV (the format the zarakeet example and tests read).

Writes into the output directory (default: this script's directory):
    <lang>_<k>.wav   converted clips
    refs.tsv         file <TAB> language <TAB> seconds <TAB> human transcript
                     (FLEURS `raw_transcription`, punctuated)

Clips are taken in archive order, skipping clips longer than --max-sec and
duplicate sentences, so re-running with the same arguments gives the same files.
Standard library only (no ffmpeg / numpy needed).

Usage:
    python3 example/fleurs/fleurs_fetch.py                      # default languages, 2 clips each
    python3 example/fleurs/fleurs_fetch.py --langs es_419 fr_fr --n 3
"""

import argparse
import array
import csv
import io
import os
import struct
import sys
import tarfile
import urllib.request
import wave

BASE = "https://huggingface.co/datasets/google/fleurs/resolve/main/data"
DEFAULT_LANGS = ["en_us", "es_419", "fr_fr", "de_de", "it_it", "pl_pl", "nl_nl"]


def parse_wav(data: bytes):
    """Return ((format_tag, channels, rate, bits), sample bytes) of a RIFF WAV."""
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    i, fmt, pcm = 12, None, None
    while i + 8 <= len(data):
        cid = data[i:i + 4]
        size = struct.unpack_from("<I", data, i + 4)[0]
        body = data[i + 8:i + 8 + size]
        if cid == b"fmt ":
            tag, ch, rate, _, _, bits = struct.unpack_from("<HHIIHH", body)
            fmt = (tag, ch, rate, bits)
        elif cid == b"data":
            pcm = body
        i += 8 + size + (size & 1)
    if fmt is None or pcm is None:
        raise ValueError("missing fmt or data chunk")
    return fmt, pcm


def to_int16_mono(fmt, pcm):
    """Convert float32 or int16 samples to mono int16. Returns (rate, samples)."""
    tag, ch, rate, bits = fmt
    if tag == 3 and bits == 32:
        samples = array.array("f", pcm)
    elif tag == 1 and bits == 16:
        samples = [x / 32768.0 for x in array.array("h", pcm)]
    else:
        raise ValueError(f"unsupported WAV format tag={tag} bits={bits}")
    if ch > 1:
        samples = samples[::ch]  # first channel
    return rate, array.array("h", (max(-32768, min(32767, round(x * 32767))) for x in samples))


def fetch(lang: str, n: int, outdir: str, max_sec: float):
    """Download the first n usable test clips of `lang`; return [(file, seconds, text)]."""
    tsv = urllib.request.urlopen(f"{BASE}/{lang}/test.tsv").read().decode()
    # test.tsv columns: id, file name, raw transcription, normalized transcription, ...
    rows = {r[1]: r for r in csv.reader(io.StringIO(tsv), delimiter="\t", quoting=csv.QUOTE_NONE)}
    got, seen = [], set()
    with urllib.request.urlopen(f"{BASE}/{lang}/audio/test.tar.gz") as resp, \
            tarfile.open(fileobj=resp, mode="r|gz") as tf:
        for member in tf:
            name = member.name.rsplit("/", 1)[-1]
            if not name.endswith(".wav") or name not in rows:
                continue
            rate, samples = to_int16_mono(*parse_wav(tf.extractfile(member).read()))
            seconds = len(samples) / rate
            text = rows[name][2]
            if rate != 16000 or seconds > max_sec or text in seen:
                continue
            seen.add(text)
            out_name = f"{lang}_{len(got) + 1}.wav"
            with wave.open(os.path.join(outdir, out_name), "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(16000)
                w.writeframes(samples.tobytes())
            got.append((out_name, round(seconds, 1), text))
            if len(got) >= n:
                break
    return got


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--langs", nargs="+", default=DEFAULT_LANGS,
                    help=f"FLEURS language codes (default: {' '.join(DEFAULT_LANGS)})")
    ap.add_argument("--n", type=int, default=2, help="clips per language (default 2)")
    ap.add_argument("--max-sec", type=float, default=12.0, help="skip longer clips (default 12)")
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)),
                    help="output directory (default: this script's directory)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    lines = []
    for lang in args.langs:
        for out_name, seconds, text in fetch(lang, args.n, args.out, args.max_sec):
            lines.append(f"{out_name}\t{lang}\t{seconds}\t{text}")
            print(lines[-1])
    with open(os.path.join(args.out, "refs.tsv"), "w", encoding="utf-8") as f:
        f.write("file\tlanguage\tseconds\ttranscript\n")
        f.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
