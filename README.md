# SH800_Flow_Pipeline

Gawad Lab tools for **Sony SH800** flow cytometry data: an R/Bioconductor QC-and-gating pipeline, and a report builder that turns its results into the lab's standard Results Report. Both are packaged as **Claude Code skills**, so a lab member can say "analyze my SH800 data" or "write up these results" and get the same method every time. The pipeline also runs on its own with `Rscript`.

> **Status (2026-10-08):** validated on one public single-color SH800 dataset (BD Cytotrol PBMC, CD4-PE, three instrument settings; see [Example](#example)). Multicolor compensation and index-sort export have not yet been exercised on lab data. Check the first runs on new data figure by figure.

**User guide (PDF):** [docs/SH800_Flow_Skills_Guide.pdf](docs/SH800_Flow_Skills_Guide.pdf)

## Layout

```
skills/sh800-flow-analysis/   SKILL.md + scripts/sh800_flow.R   QC, gating, figures, tables
skills/sh800-flow-report/     SKILL.md + scripts/               Results Report (.docx) from the pipeline outputs
docs/                         user guide (PDF)
example/                      download script, example outputs (plots/), example report (report/)
```

## What the pipeline does

1. Reads FCS 3.1 exports with `truncate_max_range = FALSE`. SH800 values exceed the range declared in the file (`$PnR` says 1e6; scatter reaches ~1.9e7), so truncating would distort real events.
2. Removes saturated events piled up at a detector maximum (SH800 FSC-H clips near 1.06e6).
3. Compensates only when needed. An identity `$SPILLOVER` matrix means the export is uncompensated; the pipeline never double-compensates.
4. Applies a logicle transform to fluorescence, estimated on a pooled subsample of all files.
5. Runs PeacoQC on the time channel (the SH800 calls it `TIME`).
6. Gates debris with openCyto `mindensity` on FSC-A.
7. Gates singlets with a **size-aware FSC-A/FSC-H ratio band**. On real SH800 PBMC, openCyto `singletGate` kept 95-96% of cells and 11-16% of what it kept had A/H > 1.5 (doublets). The band follows the singlet ratio's slow rise with cell size and takes its width from the side of the singlet peak that doublets never reach. It reports a doublet-leak check for every tube.
8. Optionally gates a marker-positive population at a quantile of the **matched negative control** (unstained or FMO).
9. Writes seven PNG figures, CSV tables, and `run_info.json` (settings, instrument, dates, compensation status, thresholds, software versions). All figures are made in R (ggplot2, patchwork, ggridges, ragg); Python is used only to assemble the Word report.

ggcyto is not used: ggcyto 1.38 cannot render with ggplot2 4.0.

## Quick start with Claude Code

```bash
mkdir -p ~/.claude/skills
cp -R skills/sh800-flow-analysis skills/sh800-flow-report ~/.claude/skills/
```

Then, in Claude Code, in the folder holding your FCS exports:

- "Analyze my SH800 data in this folder." Claude asks for the panel, compensation status and controls, validates every file header, runs the pipeline and checks every figure.
- "Write up these results for Chuck." Claude fills the lab's eight-section Results Report from the pipeline files, asks only for what the files cannot know, flags any number it cannot trace, and builds the .docx.

## Quick start with R only

```bash
mkdir -p /path/to/fcs/plots
cp skills/sh800-flow-analysis/scripts/sh800_flow.R /path/to/fcs/plots/
# edit only the block between "# ---- settings" and "# ---- end settings"
cd /path/to/fcs/plots && Rscript sh800_flow.R
```

Requires R 4.4 or newer. Missing Bioconductor and CRAN packages install on the first run.

## Example

```bash
cd example
./download_example_data.sh                       # 18 SH800 FCS files, ~14 MB, from figshare
cd SH800_uOttawa_figshare_30584678/plots && Rscript sh800_flow.R
```

The `plots/` folder in this repo already holds the outputs of that run. On the six Cytotrol tubes:

| Measure | Result |
|---|---|
| Cells, % of events | 15.1-18.1 |
| Singlets, % of cells | 76.9-79.9 |
| Kept singlets with FSC-A/FSC-H > 1.5 | 0 |
| CD4+, % of singlets (Low, Medium, High) | 57.2, 58.0, 59.7 |
| CD4+, % of singlets, unstained controls | 0.5 (by construction) |
| Stain index (Low, Medium, High) | 71.8, 95.7, 99.6 |

[`example/report/`](example/report/) holds the Results Report built from these outputs.

**Data credit:** Tang V. *Flow cytometry data from uOttawa Flow Cytometry & Virometry Core Facility Aurora, CytoFLEX S, SH800, and LSR Fortessa.* figshare, 2025. [doi:10.6084/m9.figshare.30584678](https://doi.org/10.6084/m9.figshare.30584678). CC BY 4.0. Only the files acquired on the SH800 (`$CYT` = `LE-SH800SZFCPL`) are used.

## Known limitations

- Multicolor compensation from single-stain controls is implemented but has not been tested on lab data.
- Index-sort: joining per-cell phenotypes to plate wells (for PTA / ResolveOME) is not built into the script yet.
- Not included: FlowJo workspace import, bead (MESF) calibration, high-dimensional clustering.

## Contact

Gawad Lab, Stanford · [gawadlab.org](https://gawadlab.org) · cgawad@stanford.edu
