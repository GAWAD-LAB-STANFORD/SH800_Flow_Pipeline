#!/usr/bin/env python3
"""
Check a filled Results Report spec before building the .docx.

Usage:
    python3 check_report.py <spec.json> <report_facts.json>

Errors (exit 1): leftover "TODO", wrong doc_type, missing or out-of-order header
fields or sections, invalid Status, figure files that do not exist.
Checks (exit 0): numbers anywhere in the report (title, header, prose, Methods
rows, tables, captions) that the pipeline did not produce. Each one must have
come from the lab member; confirm it with them or remove it.
"""

import json
import os
import re
import sys

META_KEYS = ["Lab member", "Date", "Project / Aim", "Reporting period", "Assay / platform", "Status"]
STATUSES = ["On track", "On track — decision needed", "Behind", "Blocked", "Complete"]
SECTIONS = [
    "1. Objective this period", "2. Summary", "3. Methods & samples", "4. Results",
    "5. Interpretation", "6. Blockers / decisions needed", "7. Next steps", "8. Data & code availability",
]


# ---- shared with check_report.py: keep the two copies identical ----------------
SKIP_BEFORE = ("Figure ", "Figures ", "Fig. ", "Section ", "Step ", "step ", "Table ")


def number_tokens(text):
    """Numbers a reader takes as data. Skips identifiers (FL3-A, CD4, SK3), file names
    (02_qc_debris.png), version fragments, and figure/section/step/table numbers.
    Ranges such as 37,276-44,499 give both ends."""
    out = []
    for m in re.finditer(r"\d[\d,]*(?:\.\d+)?", text):
        i, j = m.start(), m.end()
        tok = m.group().rstrip(",")
        prev = text[i - 1] if i else " "
        nxt = text[j] if j < len(text) else " "
        if prev.isalnum() or prev in "._^/,":
            continue
        if prev == "-" and i >= 2 and text[i - 2].isalpha():
            continue
        if nxt.isalpha() or nxt == "_":
            continue
        if any(text[:i].endswith(w) for w in SKIP_BEFORE):
            continue
        out.append(tok)
    return out


def spec_strings(spec):
    """Every string a reader sees in a spec, with where it sits."""
    yield "title", spec.get("title", "")
    for k, v in spec.get("meta", {}).items():
        yield f"meta:{k}", str(v)
    for sec in spec.get("sections", []):
        h = sec.get("heading", "")
        for b in sec.get("blocks", []):
            t = b.get("type")
            if t in ("paragraph", "callout"):
                yield h, b.get("text", "")
            elif t in ("bullets", "numbered"):
                for it in b.get("items", []):
                    yield h, str(it)
            elif t == "keyvalue":
                for row in b.get("rows", []):
                    yield h, " | ".join(map(str, row))
            elif t == "table":
                for row in [b.get("columns", [])] + b.get("rows", []):
                    yield h, " | ".join(map(str, row))
            elif t == "figure":
                yield h, b.get("caption", "")
# ---- end shared --------------------------------------------------------------


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    spec = json.load(open(sys.argv[1]))
    facts = json.load(open(sys.argv[2]))
    known = set(facts.get("numbers", []))
    known |= {n.replace(",", "") for n in known}
    errors, checks = [], []

    if spec.get("doc_type") != "Results Report":
        errors.append('doc_type must be "Results Report"')
    keys = list(spec.get("meta", {}).keys())
    if keys != META_KEYS:
        errors.append(f"meta fields must be exactly, in order: {META_KEYS} (got {keys})")
    status = spec.get("meta", {}).get("Status", "")
    if status not in STATUSES:
        errors.append(f"Status must be one of {STATUSES} (got {status!r})")
    heads = [s.get("heading") for s in spec.get("sections", [])]
    if heads != SECTIONS:
        errors.append(f"sections must be exactly, in order: {SECTIONS} (got {heads})")
    for sec in spec.get("sections", []):
        for b in sec.get("blocks", []):
            if b.get("type") == "figure" and not os.path.exists(b.get("path", "")):
                errors.append(f"figure not found: {b.get('path')}")

    for where, text in spec_strings(spec):
        if "TODO" in text:
            errors.append(f"TODO left in {where}: {text[:90]}")
        for n in number_tokens(text):
            if n not in known and n.replace(",", "") not in known:
                checks.append(f"{where}: '{n}' in \"{text[:90]}\"")

    for e in errors:
        print("ERROR  ", e)
    for c in checks:
        print("CHECK  ", c)
    if checks:
        print(f"\n{len(checks)} number(s) did not come from the pipeline. Each must come from the lab member "
              "(a date, donor count, dilution, chip size). Confirm each one with them, or remove it.")
    print("\nOK to build." if not errors else f"\n{len(errors)} error(s): fix before building.")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
