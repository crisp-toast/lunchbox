# Benchmarking open System One models on Tessel's windows

`bench.py` asks an open System One decision model (Laya-multilingual Core ML on the Neural Engine,
or Julia 1 on CPU) what kind of window each labeled window is, zero-shot, and compares it with
Tessel's rules. `hybrid.py` checks whether those answers help Tessel's own small classifier,
leave-one-app-out. The results are in docs/system-one-research.md.

```bash
V="/Volumes/Master Storage/Dev.noindex/venvs/system-one"
"$V/bin/python" -I bench.py laya ../windows.jsonl --prompt A --out laya-A.json
"$V/bin/python" -I bench.py julia ../windows.jsonl --prompt A --out julia-A.json
"$V/bin/python" -I bench.py julia ../windows.jsonl --prompt B --out julia-B.json
swift run -c release TesselTrain Training/windows.jsonl --features features.json   # from the repo root
"$V/bin/python" -I hybrid.py ../windows.jsonl features.json laya-A.json julia-A.json julia-B.json
```

The models live in `/Volumes/Master Storage/AI-Models/system-one` (`hf download
aac6fef/laya-multilingual-coreml-ane`, `hf download SupersonicLabs/Julia-1`). The environment
has `laya-coreml` 0.4.0 and Julia 1's own runtime (`pip install -e Julia-1`, PyTorch CPU).
