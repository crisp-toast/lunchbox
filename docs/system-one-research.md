# An on-device System One model for Tessel: research

2026-10-16. Tyler's direction is a fast, open-source, on-device "System One" decision model
similar to Jev by TypeSafe AI, deciding how each window should behave from its text, not a
JEPA-style model. This is what's out there, what fits Tessel, and what to try first.

## What Jev is

- **Who and when:** TypeSafe AI released Jev on 2026-09-15, in early access.
- **What kind of model:** discriminative and non-generative.
- **How it works:** you send a `state` (text or JSON) and typed questions, and get back one
  calibrated probability distribution per question. The question types are:
  - `noul`: true or false;
  - `choice`: one of a list of options supplied at call time (zero-shot);
  - `score`: a place on an ordinal scale.

  All questions are answered in parallel. The name "System One" is Kahneman's fast,
  intuitive thinking.
- **Closed:** no weights, no on-device or on-prem option, API only, 70–500 ms per call
  ([Wikipedia](https://en.wikipedia.org/wiki/Jev_(AI_model)), [TypeSafe](https://typesafe.ai/)).

Jev itself can't be used: it's closed, it's far slower than a per-window budget, and calling it
would send window titles off the Mac.

## The open, on-device candidates

Thirty-odd open projects copied Jev's interface within weeks
([systemonemodels.org](https://systemonemodels.org/examples/alternatives/)). Most wrap an LLM
(Qwen 0.8B–27B): hundreds of milliseconds and gigabytes of memory, too heavy for a menu-bar app
deciding every new window. The ones that can fit are small non-generative encoders:

| Model | License | Size | On Apple Silicon | Notes |
|---|---|---|---|---|
| **Laya-multilingual, Core ML port** ([laya-coreml](https://github.com/mizorewww/laya-coreml), [HF](https://huggingface.co/aac6fef/laya-multilingual-coreml-ane)) | Apache-2.0 (port and original) | 322M (mmBERT-base); FP16 and W8 | **4.98 ms P50 on the Neural Engine** (M3 Max), 0.15 J per decision | 96-token limit for state, question and options together; macOS 15+; community conversion, matches upstream on 59/59 fixtures |
| **Julia 1** ([HF](https://huggingface.co/SupersonicLabs/Julia-1), [page](https://supersoniclabs.ai/julia-1/)) | Apache-2.0 | 144M (mmBERT-small); 550 MiB FP32 | 33 ms median on M4 CPU (4 threads), 371 MiB RAM; no Core ML port yet | Smallest. Typed decisions 73.2% vs Jev's reference 72.7% (self-reported); ONNX export exists |
| Laya, English ([repo](https://github.com/NandhaKishorM/laya)) | Apache-2.0 code | 421M (ModernBERT-large) | 146–453 ms on an Intel Mac; 33–40 ms on a T4 | The reference open System One model; over-confident as shipped |
| GLiNER2.5-Decide Core ML ([HF](https://huggingface.co/FluidInference/gliner2-5-decide-coreml)) | Apache-2.0 | 340M DeBERTa-v3-large, 1.3 GB | 80–120 ms on M2 Max, about 1.4 GB of memory | Too big and slow |
| Von ([repo](https://github.com/wfzyx/von)) | Apache-2.0 | 395M ModernBERT | 23 ms on A10G, 96–340 ms on CPU | Archived 2026-10-17 |
| Kev, JevK5, mini-jev, jevmlx and other LLM wrappers | mostly MIT or Apache | 0.8B–27B | MLX, tens to hundreds of ms | Too heavy for per-window decisions |

All accuracy, latency and calibration numbers above are the projects' own and unverified. Every
one of these projects is less than six weeks old.

## How it would work in Tessel

The `WindowTraits` reader, the safety floor of the old rules, the panel and the labeled windows
all stay. A System One model would answer, on the window's app queue, at first sight:

- **state:** one short line built from the traits. For example: `Finder window "doc.pdf Info":
  standard, resizable, close/minimize/zoom, 265×565 (8% of screen), normal level`. The title is
  used in memory only.
- **choice:** "How should a tiling window manager handle this window?", with five options:
  - tile it beside the others (a document or main window);
  - float it (a tool panel, inspector or settings);
  - leave it (progress, a splash screen, a pop-up);
  - float it on top (video or a call);
  - center it (it's asking the user something).
- **noul:** "Is this window asking the user to decide something?"
- **The decision:**
  - the old rules' hard floor first;
  - then the System One answer when it's confident;
  - otherwise the rules.
- **Your corrections** refit the confidence (temperature and thresholds) on this Mac, the way
  Von's `calibrate` and Laya's `calibrate.py` do on frozen weights. Nothing is sent anywhere.

Two notes on the format:
- The state has to fit Laya-CoreML's 96-token window.
- The mmBERT tokenizer handles window titles in any language, which the current English word
  list doesn't.

## Costs to weigh

- **Size:** Tessel would bundle the model, because downloading it at runtime would add a network
  call. Laya-multilingual is about 650 MB at FP16 or about 330 MB at W8 (estimated from 322M
  parameters). Julia 1 is about 275 MB at FP16, or about 140 MB at 8 bits, once converted.
- **Memory:** about 370 MB for Julia 1 on CPU. Neural Engine memory still needs measuring.
- **macOS:** the Laya-CoreML Neural Engine package needs macOS 15. On macOS 14, Tessel would fall
  back to the rules.
- **Swift:** neither project ships a Swift API. Tessel would load the `.mlpackage` with Core ML
  and tokenize with a Swift tokenizer (Hugging Face's swift-transformers reads `tokenizer.json`,
  Apache-2.0).

## Results: both models, on this Mac

Run 2026-10-16 on the M4 Mac mini (macOS 27.2):
- **Data:** the 84 hand-labeled windows in `Training/windows.jsonl` (52 apps).
- **Scripts:** `Training/system-one/bench.py` and `hybrid.py`.
- **Downloads:** the models are in `/Volumes/Master Storage/AI-Models/system-one`, and the
  Python environment is in `/Volumes/Master Storage/Dev.noindex/venvs/system-one`.
- **Prompt:** each window became a one-line state, like `Finder "doc.pdf Info": StandardWindow,
  265x565, 8% screen, close minimize zoom`, with one `choice` question, "What kind of window is
  this?", over five short options. The prompt was written once, before any result, and kept short
  to fit Laya's 96-token Neural Engine window (at most 42 state tokens; nothing was cut).
- **Training:** nothing was trained on the windows (zero-shot).

**Zero-shot** (right behavior / right tile-or-not):

| | Behavior | Tile-or-not | Notes |
|---|---|---|---|
| Today's rules | 80% | 88% | |
| Laya-multilingual, Core ML on the Neural Engine | 38% | 45% | calls 51 of 84 windows "tool panel" |
| Julia 1, CPU, short prompt | 51% | 54% | calls 70 of 84 windows "document" |
| Julia 1, CPU, longer prompt | 52% | 54% | |
| Laya + safety floor, acting only when ≥ 90% sure | 79% | 87% | |
| Julia 1 + safety floor, ≥ 90% sure | 76% | 85% | |
| **Tessel's own small classifier** (held out by app) | **85%** | **93%** | **87% / 96% shipped** |

**Speed and size,** measured in the Python runtimes:

| | Per decision | Load | Peak memory (Python process) | Download |
|---|---|---|---|---|
| Laya-multilingual Core ML, Neural Engine | **5.5 ms** median, 5.6 ms p95 | 19 s (Core ML compiles on first load) | 1.57 GB | 648 MiB |
| Julia 1, PyTorch CPU | 13.7 ms (short prompt), 18.8 ms (longer) | 2.4 s | 1.05 GB | 584 MiB |
| Tessel's own classifier, in Swift | 0.04 ms | none (45 KB of weights) | about 5 MB, for Apple's word vectors | none |

Python overstates memory. Natively, Laya's 375 MiB embedding table could be memory-mapped, so
only the rows a title uses would be resident. That's not measured.

**As helpers rather than deciders:** each model's five probabilities were added as extra inputs
to Tessel's small head, again held out by app.

| Head reads | Behavior | Tile-or-not |
|---|---|---|
| Tessel's features | 85% | 92% |
| Tessel's features + Laya | 85% | 92% |
| Tessel's features + Julia 1 | 85–86% | 92% |
| Window structure + Laya, instead of Tessel's title features | 85% | 92% |
| A model's answer alone, recalibrated on the labels | 43–54% | 63–68% |

**What this says:**
1. Out of the box, these System One models don't understand windows. They were trained on
   tickets, intents and emotions, and a window's subrole, buttons and size mean nothing to them.
   Laya's own notes say the same: out-of-domain cases are fixed only with labels and refitting.
2. With Tessel's labels, they add nothing the small classifier doesn't already know. Laya's
   answer can replace Tessel's hand-made title features at equal accuracy, the one place it
   does real work (reading titles), but no better.
3. They cost 100–400× the time per decision, about a gigabyte of memory in these runtimes,
   0.6 GB of download, and macOS 15 for the Neural Engine path.

## Round 2: getting the most out of them

Researched the documented ways to get better answers, then tested each one on both models. All
variants were written down before any was run (`Training/system-one/bench2.py`).

What the sources say:
- **Laya:**
  - stay under 20 options;
  - option order changes answers, and averaging over rotations cut that from 16% to 6%;
  - a yes/no ("noul") question needs explicit true/false criteria;
  - `score` is the weakest question type;
  - split hard label sets into coarse then fine;
  - shipped confidences are over-confident;
  - base checkpoints are "near chance zero-shot" on typed decisions (36%), and fine-tuning took
    them to 77% ([repo](https://github.com/NandhaKishorM/laya)).
- **Julia 1:** describe options clearly and distinctly, and give yes/no questions descriptive
  criteria (483 vs 391 of 600 on its benchmark) ([card](https://huggingface.co/SupersonicLabs/Julia-1)).
- **TypeSafe on Jev:** make questions atomic and combine them in code.
- **Zhao et al., [Calibrate Before Use](https://arxiv.org/pdf/2102.09690):** divide out the model's
  built-in lean, learned from a content-free input or a batch of unlabeled inputs. No labels needed.

Tested, on both models (right behavior / right tile-or-not; old rules 80% / 88%; always answering
"document" 56% / 56%):

| Design | Laya | Julia 1 |
|---|---|---|
| Round 1: five options, numbers in the state | 38% / 45% | 51% / 54% |
| State in plain words (sizes as words, missing buttons spelled out) | 48% / 61% | 36% / 56% |
| Plus descriptive options | 35% / 46% (state cut in 50 of 84) | 54% / 56% |
| Plus averaging over all five option orders | 35–42% / 49–55% | 57% / 57% (calls every document a document, little else) |
| Four atomic yes/no questions, combined in code | 18–27% / 44–55% | 14–25% / 39–45% |
| Coarse then fine: tile or float first, then which kind | 55–56% / 56–64% | 48–54% / 50–54% |
| Batch or contextual calibration (on each of the above) | helps rarely, often hurts | mostly hurts |
| Ask only where the rules would tile: "is this really a document?" | AUROC 0.51–0.75; no threshold fixes more than it breaks | AUROC 0.32–0.49 |
| Best of any design, with the rules as the floor and the model only when ≥ 90% sure | 80% / 88% (equal to the rules) | 81% / 89% (one window better) |

Speed for the richer designs: Laya 6.4 ms (one question), 13 ms (coarse then fine), 25 ms (four
yes/no questions) and 33 ms (five rotations). Julia 1: 12–30 ms, and 82 ms with rotations.

**Conclusion:** no question design, output count or calibration makes either model competitive
zero-shot. The best ones mostly fall back on calling everything a document. Laya's own notes say
the same: these are bases to fine-tune, not zero-shot engines.

## Round 3: other jobs (text, typed by you)

Windows aren't what these models were built for, so round 3 tried them on two jobs that are
made of text and start with something you type. That way, 15–20 ms is fast enough:

- **Find a window by describing it.** 15 windows with realistic titles and three queries each:
  - the title's words ("lunch thursday");
  - part of them ("lunch email");
  - a description only ("the message about where to eat").
- **Plain-English commands.** 12 of Tessel's actions, four phrasings each ("put xcode next to
  terminal"), plus which app and which Workspace a command names.

The baseline is plain word matching. The probe also tried the sentence and contextual embeddings
that macOS already ships, which add nothing to the app's size. All test sentences were written
before any run (`Training/system-one/texttasks.py`, `embedprobe.swift`).

**Finding a window (out of 15)**

| | Title words | Part of them | Description only |
|---|---|---|---|
| Word matching | **15** | **12** | 1 |
| Laya | 5 | 4 | **6** |
| Julia 1 | 9 | 5 | 5 |
| macOS sentence embedding | **15** | 9 | 3 |
| macOS contextual embedding | 11 | 9 | 5 |
| Words first, then contextual meaning | **15** | **13** | 3 |

**Plain-English commands**

| | Action (of 48) | App (of 23) | Workspace (of 8) |
|---|---|---|---|
| Laya | 28 (58%) | 21 | 8 |
| Julia 1 | 18 (38%) | 19 | 5 |
| macOS sentence embedding, nearest of 3 examples per action | 22 (46%) | – | – |
| macOS contextual embedding, same | 25 (52%) | – | – |

**Time per answer:** Laya 17 ms median, Julia 1 19 ms, the macOS embeddings 2–7 ms.

**What it means:**
- **Descriptions:** finding a window from a description alone needs world knowledge (an
  "INV-…pdf" is a bill). None of these small encoders has it; the best got 6 of 15.
- **Words:** for the words people actually type, plain matching wins.
- **Commands:** the app and the Workspace are easy, and simple matching gets them. The action
  is the hard part, and at 38–58% right, a typed command would move the wrong windows about
  half the time.
- **Verdict:** zero-shot, neither model earns its size in Tessel in these jobs either. A
  commands feature would need fine-tuning on a few thousand synthetic phrasings (no user data),
  tested on phrasings written by someone else, with 95% of actions right as the bar.

## How much space one adds to the app

Tessel.app is **6.7 MB** today. The weights hardly compress (lzfse saves 5–8% on them, but takes
the 32 MiB tokenizer down to 5 MiB), so the download grows almost as much as the installed app.

Where the size goes:
- **Laya:** a 240 MiB Core ML encoder (110M parameters), plus a 375 MiB vocabulary table
  (256,000 tokens × 768, FP16), plus a 32 MiB tokenizer.
- **Julia 1:** 144M parameters at FP32, 550 MiB, of which 98M (68%) is the same 256,000-token
  vocabulary at 384 wide; the transformer is only about 46M. Plus the same tokenizer.

| Version | Added to the installed app | Added to the download (est.) |
|---|---|---|
| Laya, as downloaded | **+648 MiB** | +575 MiB |
| Julia 1, as downloaded | **+584 MiB** | +520 MiB |
| Laya, 8-bit encoder (measured: 121 MiB) and 8-bit vocabulary | +342 MiB | +300 MiB |
| Laya, 4-bit encoder (measured: 61 MiB) and vocabulary trimmed to 32k tokens, 8-bit | about +90 MiB | about +85 MiB |
| Julia 1, 8-bit, full vocabulary | about +170 MiB | about +145 MiB |
| Julia 1, 4-bit transformer and vocabulary trimmed to 32k tokens, 8-bit | about +40 MiB | about +35 MiB |

- **Measured:** the 8-bit and 4-bit encoder sizes came from coremltools on this Mac. The trimmed
  rows are estimates.
- **Untested:** how much accuracy the quantized versions lose.
- **Trimming has a cost:** cutting the vocabulary to 32k tokens keeps roughly English and a few
  European languages. The 84 windows' titles and app names used only 180 distinct tokens, but
  real users' titles are in every language. 64k tokens would add about 25 MiB (Laya) or 12 MiB
  (Julia 1).
- **Memory** at runtime is roughly the model's size again.

## What would make a System One model worth it

- **Fine-tune one on windows,** not zero-shot. Laya supports fine-tuning on your own decisions
  and re-exporting to Core ML. That needs several hundred labeled windows, which is the
  follow-up that grows the set to 300+.
- **Shrink it first:** 4-bit weights and a trimmed vocabulary, as in the size table above. Julia 1
  is the better base for size (about 40 MiB at the small end). Laya is the fastest on the Neural
  Engine.
- **Ship it only if** it beats the small classifier on held-out apps, and fits a menu-bar app's
  memory and download budget.

Until then, Tessel's classifier keeps the System One shape (a typed choice with calibrated
probabilities, a confidence gate and the rules as a floor) at 0.04 ms and 45 KB.
