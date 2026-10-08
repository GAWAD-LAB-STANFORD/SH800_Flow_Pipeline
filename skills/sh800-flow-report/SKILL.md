---
name: sh800-flow-report
description: Turn Sony SH800 flow cytometry results from the sh800-flow-analysis pipeline into the standard Gawad Lab Results Report (.docx) that a lab member sends to Chuck (the PI). Pre-fills methods, QC, gating numbers, tables and figures straight from the pipeline outputs, interviews the member only for what the files cannot know (samples, staining, sort setup, interpretation, next steps), and checks that no number was invented. Use whenever someone has SH800 or Sony sorter results (a plots/ folder with run_info.json and gate_percent.csv) and wants to write them up, report them, summarize the flow or sort experiment, send results to Chuck, or prepare a lab-meeting update, even if they just say "make the report" or "write this up for Chuck". Prefer this over the generic lab-results-report for SH800 flow outputs.
---

# SH800 flow results report

This skill produces the same **Results Report** every Gawad Lab member sends the PI (identical header block, eight fixed sections, shared Word builder), specialised for SH800 flow cytometry. The PI reads many reports quickly and relies on section N always meaning the same thing, so the structure is fixed. The flow-specific part is that every number comes from the pipeline's own files through a script, so nothing is retyped and nothing is guessed.

Files in this skill:
- `scripts/collect_results.py`: reads the pipeline outputs, writes `report_facts.json` and a draft spec.
- `scripts/check_report.py`: blocks the build on leftover TODOs or format drift; lists every narrative number not traceable to the pipeline.
- `scripts/build_docx.py`: the lab's shared builder. Keep it byte-identical to the copy in the lab's `lab-results-report` skill; that is what makes all lab documents look the same.
- `references/house_style.md`: the block types the builder accepts.

## Step 0: find the results

Locate the `plots/` folder the sh800-flow-analysis pipeline wrote (it contains `run_info.json`, `gate_percent.csv`, `qc_events.csv`, PNG figures). If `run_info.json` is missing, the analysis was run with an older script: re-run the run copy (`Rscript sh800_flow.R` from inside `plots/`) to regenerate it. If there are no pipeline outputs at all, run the sh800-flow-analysis skill first.

## Step 1: collect the facts

```bash
python3 <skill_dir>/scripts/collect_results.py <plots_dir>
```

This writes `<fcs_dir>/report/report_facts.json` and `report_spec_draft.json` (rerunning overwrites both; your filled `report_spec.json` is never touched), and prints the instrument, ranges and QC flags. Read the printout, then open (Read) every figure you will embed. You need to see them to describe them accurately, and the QC figures tell you whether the gates are trustworthy before you write about results.

## Step 2: interview the lab member, briefly

Ask only for what the files cannot know, in clusters of two to four questions, conversationally. Skip anything the member already told you or attached. If the member front-loads everything, do not re-ask.

- **Who and why**: name and role; project or grant aim; dates the experiment covers; the one question this experiment set out to answer.
- **Samples**: cell source (patient/donor/line IDs, tissue, fresh vs frozen vs lyophilized); how many biological replicates versus how many tubes; conditions or timepoints.
- **Staining**: antibodies (marker, clone, fluorochrome, vendor/lot, dilution), viability dye, Fc block. Confirm the panel the pipeline used (`panel` in the facts) matches what was stained.
- **Instrument and sort**: chip size, laser/filter configuration, gain/sensitivity settings, FSC threshold; if sorted: target gate, sort mode, events sorted, plate or tube, index sort, post-sort purity.
- **Meaning and next steps**: what the result means for the question; caveats; anything blocking; any decision Chuck needs to make; next steps with dates; where the raw data are backed up.

## Step 3: fill the draft

Copy `report_spec_draft.json` to `report_spec.json` and replace every `TODO:` with the member's answers or your writing. The pipeline-filled rows, tables and figure captions are already correct: edit their wording if needed, never their numbers.

Section by section:
1. **Objective this period**: one sentence or two; the question, not the method.
2. **Summary**: three to five bullets carrying the whole story: what was measured, the headline result with its number, the main QC caveat, the decision or next step.
3. **Methods & samples**: fill the four TODO rows (samples and replicates, staining, instrument setup, sort details). Write "not provided" for anything the member does not know; do not guess.
4. **Results**: one short paragraph per finding before its figure/table. Cite numbers from the tables in the same section.
5. **Interpretation**: what it means; then the automated QC notes, reworded only for clarity. Keep every flag the member cannot refute.
6. **Blockers / decisions needed**: a `callout` labelled `DECISION NEEDED` for each decision Chuck must make; bullets for other blockers. With a decision but no blockers, follow the callout with the paragraph "No other blockers this period." With neither, write "None this period."
7. **Next steps**: a numbered list, target dates where known. Use `numbered` blocks only here: the shared builder continues numbering from one numbered list to the next, so a second list would start at the wrong number.
8. **Data & code availability**: fill the raw-data backup row.

Header: set `Status` to exactly one of `On track`, `On track — decision needed`, `Behind`, `Blocked`, `Complete`. Title: short and descriptive.

Where numbers and claims may come from:
- **Numbers**: only `report_facts.json` (the pipeline) or the member. Other files in `plots/` (`SUMMARY.md`, `run.log`, archived runs) are not sources: they can be stale. If a number from them matters, ask the member or re-derive it into the facts.
- **Observations you read off the figures** (for example "the CD4- peak sits above the unstained peak") are allowed when you can see them. List them for the member to confirm before building.
- **Instrument model**: the file records an instrument code (e.g. `LE-SH800SZFCPL`), not a model name. Write the code unless the member names the model.

What Chuck looks for in a flow report, so make these visible:
- **n biological versus n events.** Thousands of events from one donor is n = 1. Say which it is.
- **What the gate means.** A threshold set at the 99.5th percentile of an unstained control makes controls read 0.5% positive by construction, and a CD4 gate on PBMC includes CD4-dim monocytes. State what the population is and is not.
- **Doublets and debris.** Give the singlet % and the doublet-leak check; a high debris fraction is a sample property worth one clause.
- **Compensation.** State whether data were compensated. Uncompensated multicolor data cannot support marker co-expression claims.
- **Controls.** Which negative controls set which gates.
- **Plain register.** Measured facts, no adjectives doing the work of numbers.

## Step 4: check, then build

```bash
python3 <skill_dir>/scripts/check_report.py <fcs_dir>/report/report_spec.json <fcs_dir>/report/report_facts.json
```

Fix every ERROR. For every CHECK line, confirm the number came from the member (a date, a donor count, a dilution) or remove it. A number that appears in neither the facts nor the member's answers is fabricated and must go. Then build:

```bash
python3 <skill_dir>/scripts/build_docx.py <fcs_dir>/report/report_spec.json "<fcs_dir>/report/<Member>_<Project>_results_<YYYY-MM-DD>.docx"
```

Filename: `<Member>_<Project>_results_<YYYY-MM-DD>.docx`, where Member is the member's first name (or a short label such as `Example` for a non-personal report), Project is a short hyphenated slug, and the date is the report date. No spaces or parentheses. This keeps Chuck's folder sorted.

## Step 5: look at it

Render a preview and read every page: `soffice --headless --convert-to pdf --outdir <fcs_dir>/report <docx>`. LibreOffice's `soffice` may not be on PATH: try `/opt/homebrew/bin/soffice` or `/Applications/LibreOffice.app/Contents/MacOS/soffice`. Without LibreOffice, `qlmanage -t -s 1400 -o <dir> <docx>` gives a first-page thumbnail on a Mac. Confirm the figures appear (not placeholders), the tables fit, and nothing overlaps. Fix the spec and rebuild if not.

## Step 6: hand it over

Give the member the .docx path and a two-line summary of what it says. The member sends it to Chuck; do not email it on their behalf unless they explicitly ask in this conversation.

## Rules

- Never invent numbers, sample counts, dates, reagents or conclusions. Pipeline facts come from `report_facts.json`; everything else comes from the member or reads "not provided".
- Do not regenerate or restyle the pipeline figures; embed the PNGs it produced. If the report needs a figure the pipeline does not make, make it in R (ggplot2) with the pipeline's theme and save it as PNG in `plots/`; never draw figures in Python. Python here only assembles the Word document.
- Keep the member's scientific voice and the fixed structure. Report what was found; leave judgment to Chuck.
- A finished example built from public test data is in the shared folder's `sample_data/SH800_uOttawa_figshare_30584678/report/` (`Example_SH800-pipeline-validation_results_2026-10-08.docx` and its PDF preview).
