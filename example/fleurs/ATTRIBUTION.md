# Attribution: FLEURS test clips

The `*.wav` files and the transcripts in `refs.tsv` in this folder come from
**FLEURS** (Few-shot Learning Evaluation of Universal Representations of Speech)
by Google. They're licensed under
[Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).

- Dataset: <https://huggingface.co/datasets/google/fleurs>
- Paper: A. Conneau, M. Ma, S. Khanuja, Y. Zhang, V. Axelrod, S. Dalmia, J. Riesa,
  C. Rivera, A. Bapna. *FLEURS: Few-shot Learning Evaluation of Universal
  Representations of Speech.* 2022. <https://arxiv.org/abs/2205.12446>

**Changes made:** we took the first clips (12 s or shorter) of each language's
**test** split and converted them from 32-bit float WAV to 16 kHz mono 16-bit PCM
WAV. The audio content and the transcripts (`raw_transcription`) are unchanged.
`fleurs_fetch.py` reproduces them exactly.

| Language code | Clips |
|---|---|
| `en_us` | `en_us_1.wav`, `en_us_2.wav` |
| `es_419` | `es_419_1.wav`, `es_419_2.wav` |
| `fr_fr` | `fr_fr_1.wav`, `fr_fr_2.wav` |
| `de_de` | `de_de_1.wav`, `de_de_2.wav` |
| `it_it` | `it_it_1.wav`, `it_it_2.wav` |
| `pl_pl` | `pl_pl_1.wav`, `pl_pl_2.wav` |
| `nl_nl` | `nl_nl_1.wav`, `nl_nl_2.wav` |

The transcripts are human references, so model output isn't expected to match
them exactly. Compare using word error rate (WER), not exact equality.
