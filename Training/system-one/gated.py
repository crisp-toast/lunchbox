"""Ask the model only where the rules would tile, one question: is this really a document? Score
how well its answer separates real documents from the rest (AUROC), and what overriding does."""
import json, sys
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from bench import by_rules
traits = {json.loads(l)["id"]: json.loads(l)["traits"] for l in open(sys.argv[1])}
for path in sys.argv[2:]:
    run = json.load(open(path))
    rows = [r for r in run["windows"] if by_rules(traits[r["id"]]) == "document"]
    print(f"\n{run['model']}: {len(rows)} windows the rules tile, {sum(r['label'] != 'document' for r in rows)} of them wrongly")
    signals = {
        "P(main) atomic": lambda r: r["answers"]["S2.atomic"]["main"]["true"],
        "P(document) choice5 S2": lambda r: r["answers"]["S2.choice5"]["q"]["document"],
        "P(document) choice5 S1": lambda r: r["answers"]["S1.choice5"]["q"]["document"],
        "P(tile) coarse": lambda r: r["answers"]["S2.coarse"]["tile"]["tile"],
        "P(document) desc rot": lambda r: r["answers"]["S2.choice5desc.rot"]["q"]["document"],
    }
    for name, f in signals.items():
        pos = [f(r) for r in rows if r["label"] == "document"]; neg = [f(r) for r in rows if r["label"] != "document"]
        auroc = sum((p > q) + 0.5 * (p == q) for p in pos for q in neg) / (len(pos) * len(neg))
        best = []
        for th in sorted(set([0.02, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5])):
            fixed = sum(x < th for x in neg); broke = sum(x < th for x in pos)
            best.append(f"<{th}: +{fixed}/-{broke}")
        print(f"  {name:26} AUROC {auroc:.2f}   override to float when " + "  ".join(best))
