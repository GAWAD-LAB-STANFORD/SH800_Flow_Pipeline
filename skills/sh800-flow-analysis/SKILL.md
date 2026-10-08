---
name: sh800-flow-analysis
description: Analyze Sony SH800 flow cytometry data. Requests the specific input files first, validates the FCS exports, then runs an R/Bioconductor pipeline with saturation removal, debris and doublet gating, optional control-matched positive gates, tables and publication-style PNG figures. Use when the user mentions SH800, Sony sorter data, or wants FCS files analyzed and plotted in R.
---

# SH800 flow analysis

The pipeline script is `scripts/sh800_flow.R` in this skill's folder. Copy it next to the user's data and edit ONLY its settings block (between `# ---- settings` and `# ---- end settings`); never edit the skill's own copy for a single run. Run it with `Rscript sh800_flow.R` or `Rscript sh800_flow.R /path/to/fcs`. Outputs land in `<fcs_dir>/plots/`. A run copy saved in `<fcs_dir>/plots/` also finds its data when rerun from inside that folder, so results folders stay portable between computers.

## 1. Ask for the inputs first

Ask for the following and wait for the answers. Do not start the analysis until the required items are in hand, unless the user tells you to proceed; then resolve what you can from step 3 and state each assumption.

**Required**
- **FCS 3.1 exports** from the SH800 Cell Sorter Software, one per sample or tube. Native experiment files (.info, .t, .tp, .fmt) can't be read; they must be exported as FCS.
- **Panel map**: channel to marker/fluor (e.g. `FL1-A = CD34 FITC`). Put ONLY stained channels in `panel`.
- **Compensation status**: were the exports compensated in the SH800 software? If not, request unstained and single-stain controls, or the compensation matrix (`spill_csv`).

**Optional**
- Negative controls (unstained / FMO) and how they pair with samples (`control_pattern`, `match_by`). These set the positive-gate thresholds.
- Sample metadata encoded in file names (`meta_regex`, `meta_labels`), used for facet grids and short sample labels.
- Index-sort export (plate/well positions) to join per-cell phenotypes to downstream single-cell sequencing.
- Extra gates; a FlowJo workspace (`.wsp`, import with CytoML); which comparisons matter most.

## 2. Environment

- Check for R (`which Rscript`, `R --version`). If missing, suggest R from CRAN (Apple Silicon build) or `brew install --cask r`. Ask before installing anything system-wide.
- The script installs what it needs via `BiocManager::install(..., update = FALSE, ask = FALSE)`:
  Bioconductor `flowCore`, `flowWorkspace`, `openCyto`, `PeacoQC`; CRAN `ggplot2`, `dplyr`, `tidyr`, `ggridges`, `MASS`, `scales`, `patchwork`, `ragg`. `CytoML` only for a FlowJo workspace; `CATALYST`/`FlowSOM`/`uwot` only for high-dimensional clustering.
- **Do not use ggcyto.** ggcyto 1.38 cannot render any plot with ggplot2 >= 4.0 (error: "comparison (!=) is possible only for atomic and list types"). All figures are plain ggplot2.

## 3. Validate the files and report before analyzing

Read the FCS headers (a 64 KB range read is enough; `$CYT` identifies the instrument, e.g. `LE-SH800SZFCPL`). For each file report: event count; channel names; `$PnS` values; spillover keyword present; time channel; inconsistencies across files (channel sets, very low counts).

Then reconcile:
- **Side scatter is `BSC-A` on some SH800 exports and `SSC-A` on others.** The script accepts both.
- **The time channel is `TIME`** (upper case). PeacoQC defaults to `"Time"`; the script passes the real name.
- **`$PnS` is often a filter name, not a stain** (`FITC-A`, `Brilliant Violet 421-A`). A stained channel reads `Marker: Fluor-A` (e.g. `CD4: PE-A`). With an empty `panel`, the script treats only the `Marker: Fluor` channels as stained.
- **An identity `$SPILLOVER` means the export is UNCOMPENSATED**, not compensated. The script detects it, applies nothing, and says so in the figures. **Never double-compensate.**
- **`$PnR` is not the true maximum** (declared 1e6; FSC-A and SSC-A reach 1.6e7 to 1.9e7). Always read with `truncate_max_range = FALSE`, and never use keyword-range margin removal such as `PeacoQC::RemoveMargins`: it would delete real cells.

## 4. Run and adapt the script

Set the settings block, run, and read the console summary. Pipeline order:
1. Read with `read.flowSet(transformation = FALSE, truncate_max_range = FALSE)`.
2. **Remove saturated (margin) events**: values piled up at a detector's maximum. SH800 FSC-H clips near 1.06e6 (about 20 to 45 events per 40k-event tube), and their FSC-A/FSC-H ratio is meaningless. Reported in `qc_events.csv`.
3. Compensate only if needed (see step 3).
4. Logicle on fluorescence, estimated on a pooled subsample of all files so every sample shares one scale; arcsinh (cofactor ~150) fallback. Scatter stays linear.
5. PeacoQC on the time channel; % removed per sample goes to `qc_events.csv`. The warning "not enough bins for a robust isolation tree" on ~40k-event files is expected.
6. Debris: openCyto `mindensity` on FSC-A. Verify on the log-log FSC/SSC figure: the cut must sit in the valley between the debris cloud and the cell cluster. Lyophilized material (e.g. Cytotrol) can be 80 to 85% debris; that is the sample, not a gate failure.
7. **Singlets: a size-aware FSC-A/FSC-H ratio band, not `openCyto::singletGate`.** On real SH800 PBMC, `singletGate` kept 95-96% of cells, and 11-16% of what it kept had A/H > 1.5, i.e. doublets. Its regression band is inflated by the doublet fan, and the same fan drags any fitted H-vs-A line too shallow. The script instead:
   - finds the singlet A/H mode;
   - models the slow rise of singlet A/H with cell size. Larger singlets such as monocytes have longer pulses, about 1.04 for lymphocytes against 1.12-1.15 for the largest cells, so a flat ratio cut would wrongly drop them;
   - sets the band from the robust SD of the low-ratio side of that trend, which doublets never reach (`singlet_k = 4`).

   `singlet_gate_parameters.csv` reports `pct_kept_ratio_gt_1.5`, which should be about 0; the script warns above 1%. On the reference data the band kept 77-80% of cells with 0% above A/H 1.5. Always look at the zoomed FSC-A vs FSC-H figure: the band must hug the dense diagonal streak and exclude the fan below it.
8. Optional positive gate (`pos_gate`): threshold = a quantile (default 99.5th) of the matched negative control's singlets, matched by `match_by` (e.g. instrument setting). Controls read 0.5% positive by construction. State what the gate includes: in PBMC, CD4-dim monocytes straddle a CD4 threshold, so "CD4+ % of singlets" is not "CD4 T cells". Add a lymphocyte scatter gate if that is the question.

## 5. Figures (PNG only, 300 dpi)

The user wants **PNG only, no PDF**, and **every figure made in R** (ggplot2 and R packages such as patchwork, ggridges, ragg), never in Python (matplotlib, seaborn, plotly). If a new figure is needed, add it to the R script with the existing theme. Every label must be readable: no text on top of other text, gate lines, or panel edges. **Open every PNG with Read and look before reporting.** These traps are already handled in the script and must stay handled when editing it:
- `gs_pop_get_stats()` returns a **data.table**. Inside `st[st$pop == pop, ]` the name `pop` resolves to the COLUMN, not the function argument, so every population's label is drawn in every panel. The script converts to `data.frame` first.
- Joining a table that has a `label` column onto metadata that also has one renames both (`label.x`, `label.y`); gate text uses the column name `txt`.
- Gate percentages use white-backed `geom_label` in an empty corner. Singlets go bottom-right, because the band's upper edge crosses the top-left.
- Logicle axes use decade labels (0, 10^2 to 10^6) with minor ticks from 10^2 up; labels within 4% of a panel edge are dropped.
- Ridgelines use `scale = 0.9` so rows do not overlap. Dot-plot value labels sit a fixed distance from their dots so values near 0 do not touch them.
- Density colouring is a single-hue blue ramp from a 2-D KDE computed over the central 99% of events (a full-range grid turns blocky). Gates are orange, controls grey, stained samples blue.

Figure set:
1. `01_gating_strategy.png`: one representative sample (`example_sample`): debris, then singlets, then the positive gate (or the first two stained markers).
2. `02_qc_debris.png`: every sample, log-log FSC-A vs SSC-A with the debris cut.
3. `03_qc_singlets.png`: every sample, FSC-A vs FSC-H with the singlet band.
4. `04_marker_histograms.png`: stained vs matched negative control with the threshold (ridgelines of stained markers when there are no controls).
5. `05_all_detectors.png`: every detector, stained vs control. Stain signal in an unstained detector is spillover.
6. `06_population_frequencies.png`: dot plot of each gate's % of parent.
7. `07_stain_index.png`: stain index per stained sample (when a positive gate and controls exist).

## 6. Tables

`gate_percent.csv` (percent, count, parent), `qc_events.csv` (margin and PeacoQC removal), `singlet_gate_parameters.csv` (band parameters and the doublet-leak check), `median_intensity.csv` (linear-scale median and robust SD per sample, population and detector), `stain_index.csv`, and `run_info.json` (settings, instrument, acquisition dates, compensation status, thresholds, software versions), which the sh800-flow-report skill reads.

**Index sort is not implemented in the script yet.** If an index-sort export is provided, write the per-well join (well, sample, marker intensities, gate membership) as new, clearly labelled code; check the well mapping against the plate layout; and tell the user it has not been validated on real index-sort data.

## Deliverables (in `<fcs_dir>/plots/`)

- The PNG figures and CSV tables above.
- The run copy of `sh800_flow.R`, which differs from the skill copy only in its settings block.
- A 3-5 sentence summary: compensation status; event removal (margin, PeacoQC, debris); singlet % and the doublet-leak check; positive-gate frequencies and what the gate does and does not mean; low counts or questionable gates.
- To write the results up for Chuck in the standard lab format, use the **sh800-flow-report** skill next; it reads these outputs directly.

## Reference dataset

Real SH800 test data: figshare 10.6084/m9.figshare.30584678 (Tang, uOttawa Flow Cytometry & Virometry Core; CC BY 4.0). Use the files whose `$CYT` is `LE-SH800SZFCPL`: Cytotrol PBMC (CD4-PE and unstained), BD CompBeads, QBrite PE and Spherotech rainbow beads, each at Low, Medium and High settings. Expected results on the six Cytotrol tubes: cells 15-18% of events, singlets 77-80% of cells, CD4+ 57-60% of singlets, stain index 72 (Low), 96 (Medium), 100 (High).
