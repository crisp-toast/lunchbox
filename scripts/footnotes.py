"""Numbers the site's footnotes in the order they first appear, apple.com style.
Superscripts are <sup class="fn" data-fn="key"></sup>; notes are <li id="fn-key"> in #footnotes.
Rerun after adding or moving one:  python3 scripts/footnotes.py site/index.html"""
import re, sys, pathlib

path = pathlib.Path(sys.argv[1]); s = path.read_text()
order = []
for key in re.findall(r'<sup class="fn" data-fn="([a-z0-9-]+)">', s):
    if key not in order:
        order.append(key)
number = {k: i + 1 for i, k in enumerate(order)}
s = re.sub(r'<sup class="fn" data-fn="([a-z0-9-]+)">.*?</sup>',
           lambda m: f'<sup class="fn" data-fn="{m[1]}"><a href="#fn-{m[1]}" aria-label="Footnote {number[m[1]]}">{number[m[1]]}</a></sup>', s)
block = re.search(r'(<section class="footnotes"[^>]*>\s*<ol>)(.*?)(\s*</ol>)', s, re.S)
items = {key: text for text, key in re.findall(r'(\s*<li id="fn-([a-z0-9-]+)">.*?</li>)', block[2], re.S)}
missing = [k for k in order if k not in items]
unused = [k for k in items if k not in order]
if missing or unused:
    sys.exit(f"footnotes out of sync: missing {missing}, unused {unused}")
s = s[:block.start(2)] + "".join(items[k] for k in order) + s[block.end(2):]
path.write_text(s)
print("numbered:", ", ".join(f"{number[k]} {k}" for k in order))
