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

## What would make a System One model worth it

- **Fine-tune one on windows,** not zero-shot. Laya supports fine-tuning on your own decisions
  and re-exporting to Core ML. That needs several hundred labeled windows, which is the
  follow-up that grows the set to 300+.
- **Shrink it first.** Most of Laya's size is a 256k-token multilingual vocabulary. Julia 1
  (144M) converted to Core ML would likely run in a few milliseconds on the Neural Engine, but
  that's unmeasured.
- **Ship it only if** it beats the small classifier on held-out apps, and fits a menu-bar app's
  memory and download budget.

Until then, Tessel's classifier keeps the System One shape (a typed choice with calibrated
probabilities, a confidence gate and the rules as a floor) at 0.04 ms and 45 KB.
