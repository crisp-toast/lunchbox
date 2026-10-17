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
all stay. The JEPA-style encoder and the home-made softmax head go. In their place, on the
window's app queue, at first sight:

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

## Next step

Benchmark both front-runners zero-shot on this Mac (an M4) against the 84 labeled windows in
`Training/windows.jsonl`. Measure accuracy against the old rules, latency on the Neural Engine
and CPU, and memory. Then build the winner into Tessel through Core ML. That needs downloading:
- `aac6fef/laya-multilingual-coreml-ane` (Apache-2.0, a few hundred MB) and the `laya-coreml`
  Python package, for the benchmark only;
- `SupersonicLabs/Julia-1` (Apache-2.0, about 550 MiB) and its Python runtime with PyTorch CPU.

Both would go in `/Volumes/Master Storage/AI-Models/`.
