#!/usr/bin/env python3
"""
Collect sh800-flow-analysis outputs into report facts and a draft Gawad Lab
Results Report spec.

Usage:
    python3 collect_results.py <plots_dir> [--out <report_dir>]

Reads from <plots_dir> (written by the sh800-flow-analysis pipeline):
    run_info.json, gate_percent.csv, qc_events.csv,
    singlet_gate_parameters.csv, stain_index.csv (optional)
Writes to <report_dir> (default: <plots_dir>/../report):
    report_facts.json       every number the report may cite, each with its source
    report_spec_draft.json  lab-format spec for build_docx.py: filled in where the
                            pipeline knows the answer, "TODO:" where only the lab
                            member does

Nothing here is invented: every value comes from a pipeline file. Fields only the
lab member can supply are left as TODO for the interview.
"""

import argparse
import csv
import datetime
import json
import os
import re
import sys

SECTION_TITLES = [
    "1. Objective this period",
    "2. Summary",
    "3. Methods & samples",
    "4. Results",
    "5. Interpretation",
    "6. Blockers / decisions needed",
    "7. Next steps",
    "8. Data & code availability",
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


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def cap(t):
    """Sentence case for pipeline strings shown as table values."""
    t = str(t)
    return t[:1].upper() + t[1:]


def as_list(v):
    """run_info.json may hold a one-element vector as a bare string; always return a list."""
    if v is None:
        return []
    return list(v) if isinstance(v, (list, tuple)) else [v]


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def f1(x):
    return f"{x:.1f}"


def fint(x):
    return f"{int(round(x)):,}"


def span(vals, fmt=f1, unit=""):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "n/a"
    lo, hi = fmt(min(vals)), fmt(max(vals))
    return f"{lo}{unit}" if lo == hi else f"{lo}-{hi}{unit}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("plots_dir")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    plots = os.path.abspath(a.plots_dir)
    info_path = os.path.join(plots, "run_info.json")
    if not os.path.exists(info_path):
        sys.exit(f"No run_info.json in {plots}. Re-run the sh800-flow-analysis script (current version writes it).")
    with open(info_path) as f:
        info = json.load(f)
    for k in ("instrument", "instrument_serial", "fcs_version", "stained_channels", "controls", "figures", "tables", "files"):
        info[k] = as_list(info.get(k))
    out = os.path.abspath(a.out or os.path.join(os.path.dirname(plots), "report"))
    os.makedirs(out, exist_ok=True)

    gates = read_csv(os.path.join(plots, "gate_percent.csv"))
    qc = {r["sample"]: r for r in read_csv(os.path.join(plots, "qc_events.csv"))}
    sg = {r["sample"]: r for r in read_csv(os.path.join(plots, "singlet_gate_parameters.csv"))}
    si = {r["sample"]: r for r in read_csv(os.path.join(plots, "stain_index.csv"))}

    pg = info.get("positive_gate") or None
    pos = pg["name"] if pg else None
    leaf = info.get("leaf_population", "singlets")

    def gate(sample, pop, field):
        for r in gates:
            if r["sample"] == sample and r["pop"] == pop:
                return num(r[field])
        return None

    # ---- per-sample facts -------------------------------------------------
    samples = []
    for m in info["samples"]:
        s = m["sample"]
        q = qc.get(s, {})
        row = {
            "sample": s, "label": m.get("label", s), "control": bool(m.get("control", False)),
            "events_acquired": num(q.get("events_in")), "margin_removed": num(q.get("margin_removed")),
            "peacoqc_removed": num(q.get("peacoqc_removed")), "events_after_qc": num(q.get("events_kept")),
            "pct_removed_qc": num(q.get("pct_removed")),
            "cells_pct_of_events": gate(s, "cells", "percent"), "cells_n": gate(s, "cells", "count"),
            "singlets_pct_of_cells": gate(s, "singlets", "percent"), "singlets_n": gate(s, "singlets", "count"),
            "doublet_leak_pct": num(sg.get(s, {}).get("pct_kept_ratio_gt_1.5")),
            "max_ratio_kept": num(sg.get(s, {}).get("max_ratio_kept")),
        }
        if pos:
            row["pos_pct_of_parent"] = gate(s, pos, "percent")
            row["pos_n"] = gate(s, pos, "count")
        if s in si:
            for k in ("median_pos", "median_neg", "rSD_neg", "stain_index"):
                row[k] = num(si[s][k])
        samples.append(row)

    stained = [r for r in samples if not r["control"]]
    controls = [r for r in samples if r["control"]]

    # ---- QC flags (rules; Claude decides how to word them) ------------------
    flags = []
    def flag(level, text):
        flags.append({"level": level, "text": text})

    for r in samples:
        if r["doublet_leak_pct"] is not None and r["doublet_leak_pct"] > 1:
            flag("flag", f"{r['label']}: {f1(r['doublet_leak_pct'])}% of gated singlets have FSC-A/FSC-H > 1.5 (doublet leak); inspect 03_qc_singlets.png.")
        if r["pct_removed_qc"] is not None and r["pct_removed_qc"] > 10:
            flag("flag", f"{r['label']}: QC removed {f1(r['pct_removed_qc'])}% of events (margin + PeacoQC); check flow stability / clogs.")
        if r["singlets_n"] is not None and r["singlets_n"] < 1000:
            flag("flag", f"{r['label']}: only {fint(r['singlets_n'])} singlets; frequencies below ~5% are unreliable at this count.")
    cells = [r["cells_pct_of_events"] for r in samples]
    if cells and max(c for c in cells if c is not None) < 30:
        flag("note", f"Most acquired events are debris: cells were {span(cells, unit='%')} of events. Typical for lyophilized or fragile material, or a low FSC threshold.")
    comp = info.get("compensation_short", "")
    n_stained_ch = len(info.get("stained_channels") or [])
    if comp == "uncompensated" and n_stained_ch > 1:
        flag("flag", f"Data are uncompensated with {n_stained_ch} stained channels: multicolor results need single-stain controls or a matrix before interpretation.")
    elif comp == "uncompensated":
        flag("note", "Data are uncompensated (identity spillover). Acceptable for a single-color readout; spillover into other detectors is visible in 05_all_detectors.png.")
    elif comp == "compensation unknown":
        flag("flag", "Compensation status unknown (no spillover keyword). Confirm whether exports were compensated in the SH800 software.")
    if pg and pg.get("thresholds_logicle") == "mindensity fallback":
        flag("note", f"No negative controls matched; the {pos} gate used mindensity instead of a control-based threshold.")
    dates = sorted(set(v for v in (info.get("acquisition_dates") or {}).values() if v))
    if len(dates) > 1:
        flag("note", f"Files were acquired on {len(dates)} dates ({', '.join(dates)}); check instrument settings were matched.")
    if pos and controls:
        flag("note", f"Controls read about {f1(100 * (1 - pg['quantile']))}% {pos} by construction ({100 * pg['quantile']:g}th-percentile threshold).")

    # ---- numbers the report may cite (for check_report.py) ------------------
    numbers = set()
    def add(v):
        if v is None:
            return
        if float(v).is_integer():
            numbers.update({f"{int(v)}", f"{int(v):,}"})
        else:
            numbers.update({f"{v:.1f}", f"{v:.2f}"})
    for r in samples:
        for k, v in r.items():
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                add(v)
    for v in (info.get("n_files"), len(stained), len(controls), n_stained_ch):
        add(v)
    if pg:
        add(pg["quantile"] * 100); add(100 * (1 - pg["quantile"]))
    for d in dates:
        numbers.update(number_tokens(d))

    # ---- methods rows ---------------------------------------------------------
    inst = ", ".join(info.get("instrument") or ["not recorded"])
    serial = ", ".join(info.get("instrument_serial") or [])
    labels = lambda rows: "; ".join(r["label"] for r in rows) or "none"
    panel = info.get("panel") or {}
    panel_txt = "; ".join(f"{v} ({k})" for k, v in panel.items()) or "not specified"
    unstained = [lbl for ch, lbl in (info.get("channel_labels") or {}).items() if ch not in panel]
    qc_span = span([r["pct_removed_qc"] for r in samples], unit="%")
    leaks = [r["doublet_leak_pct"] for r in samples if r["doublet_leak_pct"] is not None]
    leak_txt = ("not recorded" if not leaks else f"{f1(leaks[0])}% in every tube" if len(set(f1(v) for v in leaks)) == 1
                else f"at most {f1(max(leaks))}% per tube")
    sw = info.get("software", {})
    inst_txt = (f"Sony SH800 (instrument code {inst}" if "SH800" in inst else f"{inst} (instrument code") + (f", serial {serial})" if serial else ")")
    methods_rows = [
        ["Instrument", inst_txt],
        ["Acquisition date(s)", ", ".join(dates) or "not recorded"],
        ["Files analyzed", f"{info.get('n_files')} FCS {', '.join(info.get('fcs_version') or [])} files: {len(stained)} stained, {len(controls)} negative control"],
        ["Stained samples", labels(stained)],
        ["Negative controls", labels(controls)],
        ["Panel (stained channels)", panel_txt],
        ["Other detectors", "; ".join(unstained) or "none"],
        ["Compensation", cap(info.get("compensation", "not recorded"))],
        ["Event QC", f"Saturated events removed: {info.get('margin_rule')}. Then PeacoQC on the time channel. {qc_span} of events removed per tube"],
        ["Debris gate", f"{cap(info.get('debris_gate'))}; cells = {span(cells, unit='%')} of events"],
        ["Singlet gate", f"{cap(info.get('singlet_gate'))}; singlets = {span([r['singlets_pct_of_cells'] for r in samples], unit='%')} of cells; "
                         f"kept events with FSC-A/FSC-H > 1.5: {leak_txt}"],
    ]
    if pg:
        thr_rule = (f"{pg['marker']} above the {100 * pg['quantile']:g}th percentile of the matched negative control"
                    + (f" (matched by {pg['match_by']})" if pg.get("match_by") else ""))
        if pg.get("thresholds_logicle") == "mindensity fallback":
            thr_rule = f"{pg['marker']}: openCyto mindensity (no matched controls)"
        methods_rows.append([f"{pos} gate", thr_rule])
    methods_rows += [
        ["Transform", cap(info.get("transform", ""))],
        ["Software", f"{sw.get('R', 'R')}; flowCore {sw.get('flowCore', '?')}, flowWorkspace {sw.get('flowWorkspace', '?')}, "
                     f"openCyto {sw.get('openCyto', '?')}, PeacoQC {sw.get('PeacoQC', '?')}; {info.get('script')}"],
        ["Samples & biological replicates", "TODO: cell source (patient/donor/line IDs, tissue, fresh vs frozen/lyophilized), n biological replicates vs n tubes"],
        ["Staining", "TODO: antibodies (marker, clone, fluorochrome, vendor/lot, dilution), viability dye, Fc block, stain time/temp"],
        ["Instrument setup", "TODO: chip size, laser/filter configuration, sensitivity/gain settings, FSC threshold, sort mode"],
        ["Sort details", "TODO: target gate, events sorted, plate/tube, index sort yes/no, post-sort purity; or 'Analysis only, no sort'"],
    ]

    # ---- results tables -------------------------------------------------------
    cols = ["Sample", "Events", "QC removed (%)", "Cells (% events)", "Singlets (% cells)", "Singlets (n)"]
    if pos:
        cols.append(f"{pos} (% {leaf})")
    rows = []
    for r in samples:
        row = [r["label"] + (" †" if r["control"] else ""),
               fint(r["events_acquired"]) if r["events_acquired"] is not None else "n/a",
               f1(r["pct_removed_qc"]) if r["pct_removed_qc"] is not None else "n/a",
               f1(r["cells_pct_of_events"]) if r["cells_pct_of_events"] is not None else "n/a",
               f1(r["singlets_pct_of_cells"]) if r["singlets_pct_of_cells"] is not None else "n/a",
               fint(r["singlets_n"]) if r["singlets_n"] is not None else "n/a"]
        if pos:
            row.append(f1(r["pos_pct_of_parent"]) if r.get("pos_pct_of_parent") is not None else "n/a")
        rows.append(row)
    si_rows = [[r["label"], f1(r["pos_pct_of_parent"]), fint(r["median_pos"]), fint(r["median_neg"]), fint(r["rSD_neg"]), f1(r["stain_index"])]
               for r in stained if r.get("stain_index") is not None]
    neg = (pos[:-1] + "−") if pos and pos.endswith("+") else f"not {pos}"

    figs = set(info.get("figures") or [])
    exp = os.path.basename(os.path.normpath(info.get("fcs_dir") or os.path.dirname(plots)))
    def fig(name, caption):
        return {"type": "figure", "path": os.path.join(plots, name), "caption": caption} if name in figs else None

    ex_label = next((m.get("label", m["sample"]) for m in info["samples"] if m["sample"] == info.get("example_sample")), info.get("example_sample"))
    gate_desc = "debris (mindensity on FSC-A), singlets (size-aware FSC-A/FSC-H band)" + (f", {pos} ({100 * pg['quantile']:g}th percentile of the matched negative control)" if pg else "")
    results_blocks = [
        {"type": "paragraph", "text": "TODO: Finding 1, QC and gating. One short paragraph: events acquired, debris and doublet removal, and whether the gates sit on the populations (cite the table)."},
        {"type": "table", "columns": cols, "rows": rows},
        *([{"type": "paragraph", "text": "† Negative control."}] if controls else []),
        fig("01_gating_strategy.png", f"Figure 1. Gating strategy for {ex_label}: {gate_desc}."),
        fig("03_qc_singlets.png", "Figure 2. Singlet gate for every tube (FSC-A vs FSC-H). Events below the band are doublets and aggregates."),
    ]
    if pos:
        results_blocks += [
            {"type": "paragraph", "text": f"TODO: Finding 2, the {pos} result. What fraction is {pos}, how it compares across samples/conditions, and how well the stain separates from the control."},
            fig("04_marker_histograms.png", f"Figure 3. {pg['marker']} in stained tubes (blue) against the matched negative control (grey); orange line = {pos} threshold."),
        ]
        if si_rows:
            ch = pg["channel"]
            results_blocks += [
                {"type": "table", "columns": ["Sample", f"{pos} (%)", f"Median {pos}", f"Median {neg}", f"rSD {neg}", "Stain index"], "rows": si_rows},
                {"type": "paragraph", "text": f"Medians are linear-scale {ch} values of the {pos} and {neg} {leaf} in the same stained tube; "
                                              f"rSD is the median absolute deviation scaled to a standard deviation. Medians depend on the instrument "
                                              f"settings and are not comparable across settings; the stain index, (median {pos} - median {neg}) / "
                                              f"(2 x rSD {neg}), is."},
            ]
    else:
        results_blocks += [
            {"type": "paragraph", "text": "TODO: Finding 2, marker distributions across samples."},
            fig("04_marker_histograms.png", "Figure 3. Stained-marker distributions across samples."),
        ]
    results_blocks = [b for b in results_blocks if b]

    qc_bullets = [f["text"] for f in flags] or ["No automated QC flags."]
    spec = {
        "doc_type": "Results Report",
        "title": "TODO: short descriptive title, e.g. 'SH800 CD4 staining of donor PBMC'",
        "footer": "Gawad Lab · Stanford",
        "meta": {
            "Lab member": "TODO: name, role",
            "Date": datetime.date.today().isoformat(),
            "Project / Aim": "TODO: project / grant aim",
            "Reporting period": "TODO: dates the experiment covers",
            "Assay / platform": f"Flow cytometry, Sony {inst}; analysis with the sh800-flow-analysis pipeline",
            "Status": "TODO: On track | On track — decision needed | Behind | Blocked | Complete",
        },
        "sections": [
            {"heading": SECTION_TITLES[0], "blocks": [{"type": "paragraph", "text": "TODO: the specific question this experiment set out to answer."}]},
            {"heading": SECTION_TITLES[1], "blocks": [{"type": "bullets", "items": ["TODO: 3-5 bullets; the PI should get the whole story from these."]}]},
            {"heading": SECTION_TITLES[2], "blocks": [{"type": "keyvalue", "rows": methods_rows}]},
            {"heading": SECTION_TITLES[3], "blocks": results_blocks},
            {"heading": SECTION_TITLES[4], "blocks": [
                {"type": "paragraph", "text": "TODO: what the results mean for the question; caveats and alternative explanations."},
                {"type": "bullets", "items": qc_bullets}]},
            {"heading": SECTION_TITLES[5], "blocks": [{"type": "paragraph", "text": "TODO: blockers and decisions for the PI (use a callout labelled DECISION NEEDED), or 'None this period.'"}]},
            {"heading": SECTION_TITLES[6], "blocks": [{"type": "numbered", "items": ["TODO: next steps with target dates where known."]}]},
            {"heading": SECTION_TITLES[7], "blocks": [{"type": "keyvalue", "rows": [
                ["FCS files", f"{exp}/ (experiment folder)"],
                ["Pipeline outputs", f"{exp}/plots/"],
                ["Run script", f"{exp}/plots/sh800_flow.R"],
                ["Run record", f"{exp}/plots/run_info.json"],
                ["Figures not embedded", ", ".join(sorted(figs - {"01_gating_strategy.png", "03_qc_singlets.png", "04_marker_histograms.png"})) or "none"],
                ["Tables", ", ".join(info.get("tables") or [])],
                ["Raw-data backup", "TODO: lab server / Oak / Drive location of the FCS files and the SH800 experiment file"],
            ]}]},
        ],
    }

    facts = {
        "source": {"plots_dir": plots, "run_info": info_path},
        "run": {k: info.get(k) for k in ("analysis_date", "instrument", "instrument_serial", "acquisition_dates", "fcs_version",
                                         "panel", "channel_labels", "compensation", "transform", "singlet_gate", "debris_gate",
                                         "positive_gate", "controls", "example_sample", "software", "figures", "tables")},
        "samples": samples,
        "ranges": {
            "cells_pct_of_events": span(cells),
            "singlets_pct_of_cells": span([r["singlets_pct_of_cells"] for r in samples]),
            "pct_removed_qc": span([r["pct_removed_qc"] for r in samples]),
            "doublet_leak_pct": span([r["doublet_leak_pct"] for r in samples]),
            **({"pos_pct_stained": span([r.get("pos_pct_of_parent") for r in stained]),
                "pos_pct_controls": span([r.get("pos_pct_of_parent") for r in controls])} if pos else {}),
            **({"stain_index": span([r.get("stain_index") for r in stained])} if si_rows else {}),
        },
        "qc_flags": flags,
        "numbers": sorted(numbers),
    }
    auto = set(facts["numbers"])
    for _, text in spec_strings(spec):            # everything the pipeline-filled draft already says
        auto.update(number_tokens(text.replace("TODO", "")) if "TODO" not in text else [])
    auto.update(number_tokens(datetime.date.today().isoformat()))
    facts["numbers"] = sorted(auto)

    for name in ("report_facts.json", "report_spec_draft.json"):
        if os.path.exists(os.path.join(out, name)):
            print(f"Overwriting {name} (pipeline-derived; report_spec.json is never touched)")
    with open(os.path.join(out, "report_facts.json"), "w") as f:
        json.dump(facts, f, indent=2)
    with open(os.path.join(out, "report_spec_draft.json"), "w") as f:
        json.dump(spec, f, indent=2, ensure_ascii=False)

    print(f"Wrote {os.path.join(out, 'report_facts.json')}")
    print(f"Wrote {os.path.join(out, 'report_spec_draft.json')}")
    print(f"\nInstrument: Sony {inst} | files: {info.get('n_files')} ({len(stained)} stained, {len(controls)} controls) | compensation: {comp}")
    for k, v in facts["ranges"].items():
        print(f"  {k}: {v}")
    print("QC flags:")
    for fl in flags:
        print(f"  [{fl['level']}] {fl['text']}")
    if not flags:
        print("  none")


if __name__ == "__main__":
    main()
