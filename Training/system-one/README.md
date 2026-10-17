# Benchmarking open System One models on Tessel's windows

`bench.py` asks an open System One decision model (Laya-multilingual Core ML on the Neural Engine,
or Julia 1 on CPU) what kind of window each labeled window is, zero-shot, and compares it with
Tessel's rules. `hybrid.py` checks whether those answers help Tessel's own small classifier,
leave-one-app-out. `bench2.py` and `eval2.py` try other question designs and label-free
calibration. `texttasks.py` tries the models on two text jobs instead (finding a window by
describing it, and plain-English commands), and `embedprobe.swift` runs the same jobs with the
embeddings macOS already ships. The results are in docs/system-one-research.md.

```bash
V="/Volumes/Master Storage/Dev.noindex/venvs/system-one"
"$V/bin/python" -I bench.py laya ../windows.jsonl --prompt A --out laya-A.json
"$V/bin/python" -I bench.py julia ../windows.jsonl --prompt A --out julia-A.json
"$V/bin/python" -I bench.py julia ../windows.jsonl --prompt B --out julia-B.json
swift run -c release TesselTrain Training/windows.jsonl --features features.json   # from the repo root
"$V/bin/python" -I hybrid.py ../windows.jsonl features.json laya-A.json julia-A.json julia-B.json
"$V/bin/python" -I texttasks.py laya          # and julia
python3 -I texttasks.py dump texttasks.json && swiftc -O embedprobe.swift -o /tmp/embedprobe && /tmp/embedprobe texttasks.json
```

The models live in `/Volumes/Master Storage/AI-Models/system-one` (`hf download
aac6fef/laya-multilingual-coreml-ane`, `hf download SupersonicLabs/Julia-1`). The environment
has `laya-coreml` 0.4.0 and Julia 1's own runtime (`pip install -e Julia-1`, PyTorch CPU).
