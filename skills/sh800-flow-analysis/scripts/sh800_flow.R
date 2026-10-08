## sh800_flow.R - QC, gating, tables and figures for Sony SH800 FCS exports
## Part of the sh800-flow-analysis skill. Copy next to the data, edit ONLY the settings block, then run:
##   Rscript sh800_flow.R              (uses fcs_dir from the settings block)
##   Rscript sh800_flow.R /path/to/fcs (overrides fcs_dir)
## Outputs go to <fcs_dir>/plots: figures as PNG (300 dpi), CSV tables, and run_info.json (settings, instrument,
## compensation status, thresholds, software versions) that the sh800-flow-report skill reads.
## Run from inside an existing <fcs_dir>/plots folder and fcs_dir is found automatically.
##
## Method (SKILL.md explains why each step exists):
##  1 read with truncate_max_range = FALSE: SH800 values exceed the $PnR keyword range
##  2 drop saturated "margin" events piled up at a detector maximum (SH800 FSC-H clips near 1.06e6)
##  3 compensate only when needed: an identity $SPILLOVER means an uncompensated export; never double-compensate
##  4 logicle on fluorescence, estimated on a pooled subsample of all files; scatter stays linear
##  5 PeacoQC on the time channel (SH800 calls it "TIME", PeacoQC defaults to "Time")
##  6 debris: openCyto mindensity on FSC-A, verified on log-scale scatter
##  7 singlets: size-aware FSC-A/FSC-H ratio band. openCyto singletGate is NOT used: on real SH800 PBMC
##    it kept 95-96% of cells, and 11-16% of what it kept had A/H > 1.5 (doublets)
##  8 optional positive gate: threshold = quantile of the matched negative control (unstained / FMO)
##  ggcyto is not used: ggcyto 1.38 cannot render with ggplot2 >= 4.0

# ---- packages -------------------------------------------------------------
pkgs_bioc <- c("flowCore", "flowWorkspace", "openCyto", "PeacoQC")
pkgs_cran <- c("ggplot2", "dplyr", "tidyr", "ggridges", "MASS", "scales", "patchwork", "ragg", "jsonlite")
if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager")
need <- setdiff(c(pkgs_bioc, pkgs_cran), rownames(installed.packages()))
if (length(need)) BiocManager::install(need, update = FALSE, ask = FALSE)
suppressPackageStartupMessages(invisible(lapply(c(pkgs_bioc, pkgs_cran), library, character.only = TRUE)))
select <- dplyr::select; filter <- dplyr::filter

# ---- settings -------------------------------------------------------------
fcs_dir      <- "~/flow/sh800_run"   # folder of exported .fcs files
file_pattern <- "\\.fcs$"            # which files to analyze
panel        <- c()                  # STAINED channels only, e.g. c("FL1-A" = "CD34 FITC"); empty = read "Marker: Fluor" $PnS values
already_compensated <- FALSE         # TRUE if compensated in the SH800 software before export
spill_csv    <- NULL                 # optional spillover matrix CSV (first column = detector names)
cofactor     <- 150                  # arcsinh fallback if logicle estimation fails
singlet_k    <- 4                    # singlet band half-width, in robust SDs of the clean (low A/H) side
meta_regex   <- NULL                 # metadata parsed from file names, e.g. c(stain = "CD4|Unst", setting = "Low|Medium|High")
meta_labels  <- NULL                 # relabel parsed values, e.g. list(stain = c(CD4 = "CD4-PE", Unst = "Unstained"))
facet_rows   <- NULL                 # metadata column for facet rows in all-sample figures
facet_cols   <- NULL                 # metadata column for facet columns
control_pattern <- NULL              # regex for negative-control samples (unstained / FMO), e.g. "Unst"
match_by     <- NULL                 # metadata column pairing each sample with its control, e.g. "setting"
pos_gate     <- NULL                 # e.g. list(channel = "FL3-A", name = "CD4+", quantile = 0.995)
example_sample <- NULL               # sample for the gating-strategy figure (default: first non-control)
max_events_plot <- 10000             # per-sample downsampling for dot plots
# ---- end settings ---------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
if (length(args)) fcs_dir <- args[1]
fcs_dir <- path.expand(fcs_dir)
if (!dir.exists(fcs_dir) && basename(getwd()) == "plots") fcs_dir <- dirname(getwd())   # portable run copies
stopifnot("fcs_dir not found: pass it as an argument or edit the settings block" = dir.exists(fcs_dir))
out_dir <- file.path(fcs_dir, "plots"); dir.create(out_dir, showWarnings = FALSE)
set.seed(1)

# ---- read -----------------------------------------------------------------
files <- list.files(fcs_dir, file_pattern, full.names = TRUE, ignore.case = TRUE)
stopifnot(length(files) > 0)
fs <- read.flowSet(files, transformation = FALSE, truncate_max_range = FALSE)
sampleNames(fs) <- sub("\\.fcs$", "", sampleNames(fs), ignore.case = TRUE)
smp <- sampleNames(fs)
pd <- pData(parameters(fs[[1]]))[, c("name", "desc", "range")]
print(pd)

# ---- channels (side scatter is "BSC" on some SH800 exports, "SSC" on others) ----
ch    <- colnames(fs)
fsc_a <- grep("^FSC.*-A$", ch, value = TRUE)[1]
fsc_h <- grep("^FSC.*-H$", ch, value = TRUE)[1]
fsc_w <- grep("^FSC.*-W$", ch, value = TRUE)[1]
ssc_a <- grep("^(BSC|SSC).*-A$", ch, value = TRUE)[1]
time_ch <- grep("^time$", ch, value = TRUE, ignore.case = TRUE)[1]
fl_ch <- setdiff(grep("-A$", ch, value = TRUE), c(fsc_a, ssc_a))
stopifnot(!is.na(fsc_a), !is.na(ssc_a), length(fl_ch) > 0)
message("Scatter: ", fsc_a, " / ", ssc_a, " | height: ", fsc_h, " | width: ", fsc_w, " | time: ", time_ch,
        "\nFluorescence: ", paste(fl_ch, collapse = ", "))

# ---- marker labels: SH800 $PnS often holds a filter name ("FITC-A"); stains look like "CD4: PE-A" ----
desc <- setNames(as.character(pd$desc), pd$name)
if (!length(panel)) {
  st <- fl_ch[grepl(":", desc[fl_ch])]
  panel <- setNames(sub("-[AHW]$", "", sub(":\\s*", " ", desc[st])), st)
  if (length(panel)) message("Panel read from $PnS: ", paste(names(panel), panel, sep = " = ", collapse = "; "))
}
stained_ch <- intersect(names(panel), fl_ch)
lab <- function(x) vapply(x, function(chn) {
  if (chn %in% names(panel)) return(paste0(panel[[chn]], " (", chn, ")"))
  d <- desc[[chn]]
  if (!is.na(d) && nzchar(d) && d != chn) paste0(chn, " [", sub("-[AHW]$", "", d), " filter]") else chn
}, "")

# ---- sample metadata ------------------------------------------------------
alt_levels <- function(p) if (grepl("^[A-Za-z0-9_ +.-]+(\\|[A-Za-z0-9_ +.-]+)*$", p)) strsplit(p, "|", fixed = TRUE)[[1]] else NULL
meta <- data.frame(sample = smp, stringsAsFactors = FALSE)
for (nm in names(meta_regex)) {
  m <- regexpr(meta_regex[[nm]], smp)
  v <- ifelse(m > 0, substring(smp, m, m + attr(m, "match.length") - 1), NA)
  lv <- alt_levels(meta_regex[[nm]]); if (is.null(lv)) lv <- unique(v)
  if (!is.null(meta_labels[[nm]])) {
    rl <- meta_labels[[nm]]
    v  <- ifelse(v %in% names(rl), rl[v], v); lv <- ifelse(lv %in% names(rl), rl[lv], lv)
  }
  meta[[nm]] <- factor(v, levels = unique(lv))
}
meta$control <- if (!is.null(control_pattern)) grepl(control_pattern, smp) else FALSE
meta$label <- if (length(meta_regex)) apply(meta[names(meta_regex)], 1, function(v) paste(na.omit(v), collapse = ", ")) else smp
if (anyDuplicated(meta$label)) meta$label <- smp
ord_cols <- c(intersect(c(facet_rows, facet_cols), names(meta)), "sample")
meta <- meta[do.call(order, unname(as.list(meta[ord_cols]))), ]
meta$sample_f <- factor(meta$sample, levels = meta$sample)
meta$label_f  <- factor(meta$label, levels = meta$label)
add_meta <- function(df) dplyr::left_join(df, meta, by = "sample")
if (is.null(example_sample)) example_sample <- meta$sample[!meta$control][1]
if (is.na(example_sample)) example_sample <- meta$sample[1]

# ---- margin (saturated) events --------------------------------------------
margin_chans <- na.omit(c(fsc_a, fsc_h, fsc_w, ssc_a, fl_ch))
qc <- data.frame(sample = smp, events_in = as.numeric(fsApply(fs, nrow)), margin_removed = 0,
                 margin_channels = "", peacoqc_removed = NA_real_, events_kept = NA_real_, stringsAsFactors = FALSE)
kept <- list()
for (s in smp) {
  m <- exprs(fs[[s]]); bad <- rep(FALSE, nrow(m)); hitch <- character(0)
  for (chn in margin_chans) {
    x <- m[, chn]; mx <- max(x); hit <- x >= mx - abs(mx) * 1e-4
    if (sum(hit) >= max(5, 1e-5 * length(x))) { bad <- bad | hit; hitch <- c(hitch, paste0(chn, ":", sum(hit))) }
  }
  kept[[s]] <- fs[[s]][!bad, ]
  qc[qc$sample == s, c("margin_removed", "margin_channels")] <- list(sum(bad), paste(hitch, collapse = " "))
}
fs <- as(kept, "flowSet")

# ---- compensation (never double-compensate) -------------------------------
sp <- spillover(fs[[1]]); sp <- sp[!vapply(sp, is.null, logical(1))]
comp_status <- if (already_compensated) {
  "already compensated in the SH800 software: compensate() skipped"
} else if (!is.null(spill_csv)) {
  smat <- as.matrix(read.csv(spill_csv, row.names = 1, check.names = FALSE)); colnames(smat) <- rownames(smat)
  fs <- compensate(fs, smat); paste("applied", basename(spill_csv))
} else if (length(sp) && isTRUE(all.equal(unname(as.matrix(sp[[1]])), diag(ncol(sp[[1]]))))) {
  "embedded spillover is an identity matrix: data are UNCOMPENSATED, none applied"
} else if (length(sp)) {
  fs <- compensate(fs, sp[[1]]); paste("applied embedded", names(sp)[1])
} else "no spillover keyword: confirm compensation status with the user"
message("Compensation: ", comp_status)
comp_short <- if (grepl("UNCOMPENSATED", comp_status)) "uncompensated" else if (grepl("applied|already", comp_status)) "compensated" else "compensation unknown"
fs_lin <- fs   # linear copy for median intensities

# ---- transform fluorescence (logicle from a pooled subsample; scatter stays linear) ----
pool <- do.call(rbind, lapply(smp, function(s) { m <- exprs(fs[[s]]); m[sample(nrow(m), min(nrow(m), 5000)), , drop = FALSE] }))
tf <- tryCatch(estimateLogicle(flowFrame(pool), channels = fl_ch), error = function(e) NULL)
tf_type <- "logicle (estimateLogicle on a pooled subsample of all files)"
if (is.null(tf)) {
  tf_type <- paste0("arcsinh, cofactor ", cofactor)
  message("Logicle estimation failed; using arcsinh with cofactor ", cofactor)
  tf <- transformList(fl_ch, function(x) asinh(x / cofactor))
}
tf_fun <- function(chn, x) { tl <- tf@transforms; i <- which(vapply(tl, function(t) t@input, "") == chn); tl[[i]]@f(x) }
fs <- transform(fs, tf)

# ---- PeacoQC (needs a time channel) ---------------------------------------
if (!is.na(time_ch)) {
  lin_kept <- list()
  for (s in smp) {
    ff <- fs[[s]]
    res <- tryCatch(PeacoQC(ff, channels = match(c(fsc_a, ssc_a, fl_ch), colnames(ff)), determine_good_cells = "all",
                            time_channel_parameter = time_ch, save_fcs = FALSE, plot = FALSE, report = FALSE,
                            output_directory = tempdir()),
                    error = function(e) { message("PeacoQC failed on ", s, ": ", conditionMessage(e)); NULL })
    good <- if (is.null(res)) rep(TRUE, nrow(ff)) else as.logical(res$GoodCells)
    kept[[s]] <- ff[good, ]; lin_kept[[s]] <- fs_lin[[s]][good, ]
    qc[qc$sample == s, "peacoqc_removed"] <- sum(!good)
  }
  fs <- as(kept[smp], "flowSet")
  fs_lin <- as(lin_kept[smp], "flowSet")
} else qc$peacoqc_removed <- 0
qc$events_kept <- as.numeric(fsApply(fs, nrow)[qc$sample, 1])
qc$pct_removed <- round(100 * (1 - qc$events_kept / qc$events_in), 2)
write.csv(add_meta(qc) |> select(-sample_f, -label_f), file.path(out_dir, "qc_events.csv"), row.names = FALSE)
print(qc)

# ---- gating: debris -> singlets -> optional positive gate -----------------
gs <- GatingSet(fs)
gs_add_gating_method(gs, alias = "cells", pop = "+", parent = "root", dims = fsc_a, gating_method = "mindensity")
recompute(gs)
leaf <- "cells"

singlet_gate <- function(A, H, k) {
  ok <- is.finite(A) & is.finite(H) & H > 0; A <- A[ok]; H <- H[ok]; r <- A / H
  dn <- density(r[r < quantile(r, 0.99)], adjust = 0.5); m0 <- dn$x[which.max(dn$y)]
  sig0 <- median(m0 - r[r < m0]) / 0.6745             # left side of the singlet peak: doublets only raise A/H
  core <- r < m0 + 6 * sig0
  fit <- MASS::rlm(r[core] ~ A[core], maxit = 50)       # singlet A/H rises slowly with cell size
  c0 <- coef(fit)[[1]]; d0 <- coef(fit)[[2]]
  res <- r - (c0 + d0 * A); sig <- median(-res[res < 0]) / 0.6745
  xs <- seq(min(A), max(A), length.out = 80)
  hi_r <- c0 + d0 * xs + k * sig; lo_r <- pmax(c0 + d0 * xs - k * sig, 0.05)
  poly <- rbind(cbind(xs, xs / hi_r), cbind(rev(xs), rev(xs / lo_r)))
  colnames(poly) <- c(fsc_a, fsc_h)
  list(gate = polygonGate(filterId = "singlets", .gate = poly),
       params = data.frame(ratio_mode = m0, ratio_intercept = c0, ratio_slope_per_1e6 = d0 * 1e6, ratio_sd = sig, k = k))
}
singlet_params <- NULL
if (!is.na(fsc_h)) {
  sg <- lapply(smp, function(s) { m <- exprs(gh_pop_get_data(gs[[s]], "cells")); singlet_gate(m[, fsc_a], m[, fsc_h], singlet_k) })
  names(sg) <- smp
  gs_pop_add(gs, lapply(sg, `[[`, "gate"), parent = "cells", name = "singlets"); recompute(gs)
  singlet_params <- cbind(sample = smp, do.call(rbind, lapply(sg, `[[`, "params")))
  ## doublet-leak check: singlets should contain almost nothing with A/H > 1.5 (lymphocyte doublets sit near 2)
  leak <- t(sapply(smp, function(s) { m <- exprs(gh_pop_get_data(gs[[s]], "singlets")); r <- m[, fsc_a] / m[, fsc_h]
    c(max_ratio_kept = round(max(r), 3), pct_kept_ratio_gt_1.5 = round(100 * mean(r > 1.5), 2)) }))
  singlet_params <- cbind(singlet_params, leak)
  if (any(leak[, "pct_kept_ratio_gt_1.5"] > 1)) warning("Singlet gate keeps >1% events with FSC-A/FSC-H > 1.5: inspect 03_qc_singlets.png")
  leaf <- "singlets"
}

pos_name <- NULL; thr <- NULL
if (!is.null(pos_gate)) {
  pos_name <- pos_gate$name; pch <- pos_gate$channel
  grp <- if (!is.null(match_by)) as.character(meta[[match_by]][match(smp, meta$sample)]) else rep("all", length(smp))
  ctrl <- meta$control[match(smp, meta$sample)]
  if (any(ctrl)) {
    thr <- sapply(unique(grp), function(g) {
      v <- unlist(lapply(smp[ctrl & grp == g], function(s) exprs(gh_pop_get_data(gs[[s]], leaf))[, pch]))
      if (!length(v)) v <- unlist(lapply(smp[ctrl], function(s) exprs(gh_pop_get_data(gs[[s]], leaf))[, pch]))
      unname(quantile(v, pos_gate$quantile))
    })
    message(pos_name, " thresholds (", 100 * pos_gate$quantile, "th percentile of matched controls): ",
            paste(names(thr), round(thr, 3), sep = " = ", collapse = ", "))
    gates <- setNames(lapply(grp, function(g) { rg <- list(c(thr[[g]], Inf)); names(rg) <- pch; rectangleGate(filterId = pos_name, .gate = rg) }), smp)
    gs_pop_add(gs, gates, parent = leaf, name = pos_name)
  } else {
    message("No control samples matched control_pattern: falling back to mindensity on ", pch)
    gs_add_gating_method(gs, alias = pos_name, pop = "+", parent = leaf, dims = pch, gating_method = "mindensity")
  }
  recompute(gs)
}

# ---- tables ---------------------------------------------------------------
pops <- setdiff(gs_get_pop_paths(gs, path = "auto"), "root")
## as.data.frame(): gs_pop_get_stats returns a data.table, where st[st$pop == pop, ] silently matches the COLUMN, not the argument
st <- as.data.frame(merge(gs_pop_get_stats(gs, type = "percent"), gs_pop_get_stats(gs, type = "count"), by = c("sample", "pop")))
st$pop <- basename(st$pop); st$percent <- round(100 * st$percent, 2)
parent_of <- c(cells = "all events", singlets = "cells"); if (!is.null(pos_name)) parent_of[pos_name] <- leaf
st$percent_of <- ifelse(st$pop %in% names(parent_of), parent_of[st$pop], "")
st <- add_meta(st[st$pop != "root", ]) |> arrange(sample_f, factor(pop, levels = c("cells", "singlets", pos_name))) |> select(-sample_f, -label_f)
write.csv(st, file.path(out_dir, "gate_percent.csv"), row.names = FALSE)
if (!is.null(singlet_params)) write.csv(singlet_params, file.path(out_dir, "singlet_gate_parameters.csv"), row.names = FALSE)

mfi_pops <- c(leaf, pos_name)
mfi <- do.call(rbind, lapply(smp, function(s) {
  lin <- exprs(fs_lin[[s]]); stopifnot(nrow(lin) == nrow(exprs(fs[[s]])))
  rows <- lapply(mfi_pops, function(p) {
    idx <- gh_pop_get_indices(gs[[s]], p)
    out <- list(data.frame(sample = s, population = p, n = sum(idx), channel = fl_ch,
                           median = apply(lin[idx, fl_ch, drop = FALSE], 2, median), rSD = apply(lin[idx, fl_ch, drop = FALSE], 2, mad)))
    if (!is.null(pos_name) && p == pos_name) {
      neg <- gh_pop_get_indices(gs[[s]], leaf) & !idx
      out[[2]] <- data.frame(sample = s, population = paste0(sub("\\+$", "", p), "-"), n = sum(neg), channel = fl_ch,
                             median = apply(lin[neg, fl_ch, drop = FALSE], 2, median), rSD = apply(lin[neg, fl_ch, drop = FALSE], 2, mad))
    }
    do.call(rbind, out)
  })
  do.call(rbind, rows)
}))
mfi$marker <- lab(mfi$channel); mfi$median <- round(mfi$median, 1); mfi$rSD <- round(mfi$rSD, 1)
write.csv(add_meta(mfi) |> select(-sample_f, -label_f), file.path(out_dir, "median_intensity.csv"), row.names = FALSE)

si <- NULL
if (!is.null(pos_name)) {
  pm <- mfi[mfi$channel == pos_gate$channel, ]
  si <- do.call(rbind, lapply(setdiff(smp, meta$sample[meta$control]), function(s) {
    p <- pm[pm$sample == s & pm$population == pos_name, ]; n <- pm[pm$sample == s & pm$population == paste0(sub("\\+$", "", pos_name), "-"), ]
    data.frame(sample = s, pct_pos = st$percent[st$sample == s & st$pop == pos_name],
               median_pos = p$median, median_neg = n$median, rSD_neg = n$rSD,
               stain_index = round((p$median - n$median) / (2 * n$rSD), 2))
  }))
  write.csv(add_meta(si) |> select(-sample_f, -label_f), file.path(out_dir, "stain_index.csv"), row.names = FALSE)
}

# ---- figure style (dataviz reference palette; single-hue blue density) ----
ink <- "#0b0b0b"; ink2 <- "#52514e"; muted <- "#898781"; axis_c <- "#c3c2b7"
col_main <- "#2a78d6"; col_gate <- "#eb6834"; col_ctrl <- "#898781"
blue_ramp <- c("#9ec5f4", "#6da7ec", "#3987e5", "#2a78d6", "#1c5cab", "#104281", "#0d366b")
ord_ramp <- function(n) if (n <= 3) c("#86b6ef", "#2a78d6", "#104281")[seq_len(n)] else grDevices::colorRampPalette(c("#86b6ef", "#0d366b"))(n)
## base 9 pt at <= ~170 mm wide keeps text >= 7 pt when a report scales the figure to 5.6 in
theme_flow <- function(base = 9) theme_classic(base_size = base) + theme(
  axis.line = element_line(colour = axis_c, linewidth = 0.3), axis.ticks = element_line(colour = axis_c, linewidth = 0.3),
  axis.minor.ticks.length = rel(0.5), axis.text = element_text(colour = ink2), axis.title = element_text(colour = ink),
  strip.background = element_blank(), strip.text = element_text(colour = ink, face = "bold", hjust = 0),
  panel.spacing = unit(3, "mm"), plot.title = element_text(colour = ink, face = "bold", size = base + 1),
  plot.subtitle = element_text(colour = ink2, size = base), plot.title.position = "plot",
  legend.title = element_text(colour = ink2), legend.text = element_text(colour = ink2), legend.key.size = unit(3, "mm"))
lin_lab <- scales::label_number(scale_cut = scales::cut_short_scale())
fl_scale <- function(chn, aes_ = "x", lims = NULL) {
  dec <- c(0, 10^(2:6)); pos <- tf_fun(chn, dec); labs_ <- parse(text = c("0", paste0("10^", 2:6)))
  mnr <- tf_fun(chn, as.vector(outer(2:9, 10^(2:5))))
  if (!is.null(lims)) {                               # no tick label within 4% of a panel edge
    pad <- 0.04 * diff(lims); keep <- pos >= lims[1] + pad & pos <= lims[2] - pad
    pos <- pos[keep]; labs_ <- labs_[keep]; mnr <- mnr[mnr >= lims[1] & mnr <= lims[2]]
  }
  f <- if (aes_ == "x") scale_x_continuous else scale_y_continuous
  f(breaks = pos, labels = labs_, minor_breaks = mnr)
}
facet_layer <- function(free = FALSE) {
  sc <- if (free) "free" else "fixed"
  if (!is.null(facet_rows) || !is.null(facet_cols))
    facet_grid(rows = if (!is.null(facet_rows)) vars(.data[[facet_rows]]), cols = if (!is.null(facet_cols)) vars(.data[[facet_cols]]), scales = sc)
  else facet_wrap(~sample_f, ncol = min(3, length(smp)), scales = sc)
}
grid_dims <- function() {
  if (!is.null(facet_rows) || !is.null(facet_cols))
    c(if (!is.null(facet_rows)) nlevels(meta[[facet_rows]]) else 1, if (!is.null(facet_cols)) nlevels(meta[[facet_cols]]) else 1)
  else c(ceiling(length(smp) / min(3, length(smp))), min(3, length(smp)))
}
save_fig <- function(p, name, w_mm, h_mm) {
  ggsave(file.path(out_dir, paste0(name, ".png")), p, width = w_mm, height = h_mm, units = "mm", dpi = 300, device = ragg::agg_png, bg = "white")
}
events <- function(pop, chans, n = max_events_plot, samples = smp) {
  do.call(rbind, lapply(samples, function(s) {
    m <- exprs(gh_pop_get_data(gs[[s]], pop))[, chans, drop = FALSE]
    if (nrow(m) > n) m <- m[sample(nrow(m), n), , drop = FALSE]
    data.frame(sample = s, m, check.names = FALSE)
  }))
}
add_density <- function(df, x, y, logx = FALSE, logy = FALSE) {
  do.call(rbind, lapply(split(df, df$sample), function(d) {
    xx <- if (logx) log10(pmax(d[[x]], 1)) else d[[x]]; yy <- if (logy) log10(pmax(d[[y]], 1)) else d[[y]]
    bw <- function(v) { b <- MASS::bandwidth.nrd(v); if (!is.finite(b) || b <= 0) b <- sd(v) + 1e-9; b / 2 }
    k <- MASS::kde2d(xx, yy, n = 200, h = c(bw(xx), bw(yy)), lims = c(quantile(xx, c(.005, .995)), quantile(yy, c(.005, .995))))
    d$dens <- k$z[cbind(findInterval(xx, k$x, all.inside = TRUE), findInterval(yy, k$y, all.inside = TRUE))]
    d$dens <- d$dens / max(d$dens); d[order(d$dens), ]
  })) |> add_meta()
}
dens_points <- function(size = 0.15) list(geom_point(aes(colour = dens), size = size, stroke = 0, shape = 16),
                                          scale_colour_gradientn(colours = blue_ramp, guide = "none"))
pct_label <- function(pop, name = pop) {
  x <- st[st$pop == pop, c("sample", "percent")]; x$txt <- sprintf("%s %.1f%%", name, x$percent); add_meta(x)
}
gate_text <- function(df, x = Inf, y = Inf, hjust = 1.05, vjust = 1.3)
  geom_label(data = df, aes(label = txt), x = x, y = y, hjust = hjust, vjust = vjust, size = 2.9, colour = ink,
             fill = "white", alpha = 0.9, linewidth = 0, label.padding = unit(0.6, "mm"), inherit.aes = FALSE)
cut_df <- function(pop) add_meta(data.frame(sample = smp, x = vapply(smp, function(s) unname(gh_pop_get_gate(gs[[s]], pop)@min[1]), 0)))
poly_df <- function(pop) add_meta(do.call(rbind, lapply(smp, function(s) {
  b <- gh_pop_get_gate(gs[[s]], pop)@boundaries; b <- rbind(b, b[1, ]); data.frame(sample = s, x = b[, 1], y = b[, 2]) })))
gd <- grid_dims(); w_grid <- min(175, 50 * gd[2] + 20); h_grid <- 45 * gd[1] + 24

# ---- 1. gating strategy for one representative sample ---------------------
ex <- example_sample
pa_d <- add_density(events("root", c(fsc_a, ssc_a), n = 30000, samples = ex), fsc_a, ssc_a, TRUE, TRUE)
pa <- ggplot(pa_d, aes(.data[[fsc_a]], .data[[ssc_a]])) + dens_points(0.2) +
  geom_vline(data = cut_df("cells")[cut_df("cells")$sample == ex, ], aes(xintercept = x), colour = col_gate, linewidth = 0.5) +
  gate_text(pct_label("cells", "Cells")[pct_label("cells")$sample == ex, ]) +
  scale_x_log10(labels = lin_lab) + scale_y_log10(labels = lin_lab) + annotation_logticks(sides = "bl", colour = axis_c, linewidth = 0.2, short = unit(0.6, "mm"), mid = unit(1, "mm"), long = unit(1.4, "mm")) +
  labs(x = fsc_a, y = ssc_a, title = "Debris", subtitle = "All events after QC") + theme_flow()
panels <- list(pa)
if (leaf == "singlets") {
  sd_ <- events("cells", c(fsc_a, fsc_h), samples = ex)
  pb_d <- add_density(sd_, fsc_a, fsc_h)
  lim <- quantile(sd_[[fsc_a]], c(0, 0.98)); limh <- quantile(sd_[[fsc_h]], c(0, 0.995))
  pb <- ggplot(pb_d, aes(.data[[fsc_a]], .data[[fsc_h]])) + dens_points(0.25) +
    geom_path(data = poly_df("singlets")[poly_df("singlets")$sample == ex, ], aes(x, y), colour = col_gate, linewidth = 0.5) +
    gate_text(pct_label("singlets", "Singlets")[pct_label("singlets")$sample == ex, ], y = -Inf, vjust = -0.4) +
    coord_cartesian(xlim = lim, ylim = limh) + scale_x_continuous(labels = lin_lab) + scale_y_continuous(labels = lin_lab) +
    labs(x = fsc_a, y = fsc_h, title = "Doublets", subtitle = "Gated on cells") + theme_flow()
  panels <- c(panels, list(pb))
}
if (!is.null(pos_name)) {
  pch <- pos_gate$channel
  pc_d <- add_density(events(leaf, c(pch, ssc_a), samples = ex), pch, ssc_a)
  pc <- ggplot(pc_d, aes(.data[[pch]], .data[[ssc_a]])) + dens_points(0.25) +
    geom_vline(data = cut_df(pos_name)[cut_df(pos_name)$sample == ex, ], aes(xintercept = x), colour = col_gate, linewidth = 0.5) +
    gate_text(pct_label(pos_name)[pct_label(pos_name)$sample == ex, ]) + fl_scale(pch, lims = range(pc_d[[pch]])) +
    scale_y_continuous(labels = lin_lab) + coord_cartesian(ylim = quantile(pc_d[[ssc_a]], c(0, 0.995))) +
    guides(x = guide_axis(minor.ticks = TRUE)) + labs(x = lab(pch), y = ssc_a, title = pos_name, subtitle = paste("Gated on", leaf)) + theme_flow()
  panels <- c(panels, list(pc))
} else if (length(stained_ch) >= 2) {
  pc_d <- add_density(events(leaf, stained_ch[1:2], samples = ex), stained_ch[1], stained_ch[2])
  pc <- ggplot(pc_d, aes(.data[[stained_ch[1]]], .data[[stained_ch[2]]])) + dens_points(0.25) + fl_scale(stained_ch[1]) + fl_scale(stained_ch[2], "y") +
    labs(x = lab(stained_ch[1]), y = lab(stained_ch[2]), title = "Markers", subtitle = paste("Gated on", leaf)) + theme_flow()
  panels <- c(panels, list(pc))
}
p1 <- wrap_plots(panels, nrow = 1) + plot_annotation(title = paste("Gating strategy:", ex), tag_levels = "a",
                                                     theme = theme(plot.title = element_text(face = "bold", size = 10, colour = ink)))
save_fig(p1, "01_gating_strategy", 55 * length(panels) + 10, 70)

# ---- 2. debris gate, all samples (log-log scatter) -------------------------
d2 <- add_density(events("root", c(fsc_a, ssc_a)), fsc_a, ssc_a, TRUE, TRUE)
p2 <- ggplot(d2, aes(.data[[fsc_a]], .data[[ssc_a]])) + dens_points(0.22) +
  geom_vline(data = cut_df("cells"), aes(xintercept = x), colour = col_gate, linewidth = 0.4) +
  gate_text(pct_label("cells", "Cells")) + scale_x_log10(labels = lin_lab) + scale_y_log10(labels = lin_lab) +
  facet_layer() + labs(x = fsc_a, y = ssc_a, title = "Debris gate (mindensity on FSC-A)", subtitle = "All events after margin and PeacoQC removal; log axes") + theme_flow()
save_fig(p2, "02_qc_debris", w_grid, h_grid)

# ---- 3. singlet gate, all samples -----------------------------------------
if (leaf == "singlets") {
  e3 <- events("cells", c(fsc_a, fsc_h))
  d3 <- add_density(e3, fsc_a, fsc_h)
  p3 <- ggplot(d3, aes(.data[[fsc_a]], .data[[fsc_h]])) + dens_points(0.25) +
    geom_path(data = poly_df("singlets"), aes(x, y), colour = col_gate, linewidth = 0.4) +
    gate_text(pct_label("singlets", "Singlets"), y = -Inf, vjust = -0.4) +
    coord_cartesian(xlim = quantile(e3[[fsc_a]], c(0, 0.98)), ylim = quantile(e3[[fsc_h]], c(0, 0.995))) +
    scale_x_continuous(labels = lin_lab) + scale_y_continuous(labels = lin_lab) + facet_layer() +
    labs(x = fsc_a, y = fsc_h, title = "Singlet gate (size-aware FSC-A/FSC-H ratio band)",
         subtitle = sprintf("Band = singlet ratio trend +/- %g robust SD of its doublet-free side; gated on cells", singlet_k)) + theme_flow()
  save_fig(p3, "03_qc_singlets", w_grid, h_grid)
}

# ---- 4. marker histograms -------------------------------------------------
hist_ch <- if (!is.null(pos_name)) pos_gate$channel else stained_ch
if (length(hist_ch)) {
  e4 <- events(leaf, hist_ch, n = 50000) |> add_meta()
  if (!is.null(pos_name) && any(meta$control)) {
    pch <- pos_gate$channel
    e4$role <- factor(ifelse(e4$control, "Negative control", "Stained"), levels = c("Stained", "Negative control"))
    grp_col <- if (!is.null(match_by)) match_by else NULL
    lab4 <- pct_label(pos_name) |> filter(!control)
    thr_df <- if (!is.null(grp_col)) data.frame(g = names(thr), x = unname(thr)) |> setNames(c(grp_col, "x")) else data.frame(x = thr[[1]])
    if (!is.null(grp_col)) { thr_df[[grp_col]] <- factor(thr_df[[grp_col]], levels = levels(meta[[grp_col]])) }
    xl <- quantile(e4[[pch]], c(0.0005, 0.9995)); xl <- xl + c(-0.05, 0.05) * diff(xl)
    p4 <- ggplot(e4, aes(.data[[pch]], fill = role, colour = role)) +
      geom_density(aes(group = sample), linewidth = 0.35, bw = 0.06, alpha = 0.45) +
      scale_fill_manual(values = c(Stained = col_main, `Negative control` = "#c3c2b7"), name = NULL) +
      scale_colour_manual(values = c(Stained = col_main, `Negative control` = col_ctrl), name = NULL) +
      geom_vline(data = thr_df, aes(xintercept = x), colour = col_gate, linewidth = 0.4) +
      gate_text(lab4) +
      fl_scale(pch, lims = xl) + coord_cartesian(xlim = xl) + guides(x = guide_axis(minor.ticks = TRUE)) +
      (if (!is.null(grp_col)) facet_wrap(vars(.data[[grp_col]]), nrow = 1) else NULL) +
      labs(x = lab(pch), y = "Density", title = paste(lab(pch), "stained vs matched negative control"),
           subtitle = sprintf("Gated on %s. Orange line: %s threshold, the %gth percentile of the matched control", leaf, pos_name, 100 * pos_gate$quantile)) +
      theme_flow() + theme(legend.position = "top", legend.justification = "left")
    nf <- if (!is.null(grp_col)) nlevels(meta[[grp_col]]) else 1
    save_fig(p4, "04_marker_histograms", min(170, 50 * nf + 15), 68)
  } else {
    l4 <- pivot_longer(e4, all_of(hist_ch), names_to = "channel", values_to = "value") |> mutate(marker = lab(channel))
    p4 <- ggplot(l4, aes(value, label_f, fill = control)) +
      geom_density_ridges(scale = 0.9, colour = "white", linewidth = 0.2, show.legend = FALSE) +
      scale_fill_manual(values = c(`FALSE` = col_main, `TRUE` = "#c3c2b7")) + facet_wrap(~marker, scales = "free_x") +
      labs(x = "Logicle-transformed intensity", y = NULL, title = paste("Stained markers, gated on", leaf)) + theme_flow()
    save_fig(p4, "04_marker_histograms", 183, 20 + 6 * length(smp))
  }
}

# ---- 5. every detector across samples (spillover / autofluorescence check) ----
e5 <- events(leaf, fl_ch, n = 5000) |> add_meta()
l5 <- pivot_longer(e5, all_of(fl_ch), names_to = "channel", values_to = "value") |>
  mutate(detector = factor(lab(channel), levels = lab(fl_ch)), role = ifelse(control, "control", "stained"))
p5 <- ggplot(l5, aes(value, label_f, fill = role)) +
  geom_density_ridges(scale = 0.9, colour = "white", linewidth = 0.2, rel_min_height = 0.005) +
  scale_fill_manual(values = c(stained = col_main, control = "#c3c2b7"), labels = c(stained = "Stained", control = "Negative control"), name = NULL) +
  facet_wrap(~detector, scales = "free_x", ncol = 3) + scale_y_discrete(limits = rev) +
  labs(x = "Logicle units", y = NULL, title = paste("All detectors, gated on", leaf),
       subtitle = paste0("Data ", comp_short, ". Stain signal in an unstained detector is spillover")) +
  theme_flow() + theme(legend.position = "top", legend.justification = "left")
save_fig(p5, "05_all_detectors", 183, 30 + 4.5 * length(smp) * ceiling(length(fl_ch) / 3))

# ---- 6. population frequencies (dot plot, values labelled) -----------------
f6 <- st |> mutate(pop_lab = factor(paste0(pop, " (% of ", percent_of, ")"), levels = unique(paste0(pop, " (% of ", percent_of, ")"))),
                   label_f = factor(label, levels = rev(meta$label)), role = ifelse(control, "control", "stained"))
p6 <- ggplot(f6, aes(percent, label_f)) +
  geom_segment(aes(x = 0, xend = percent, yend = label_f), colour = "#e1e0d9", linewidth = 0.4) +
  geom_point(aes(colour = role), size = 2.2) + geom_text(aes(x = percent + 4, label = sprintf("%.1f", percent)), hjust = 0, size = 2.7, colour = ink2) +
  scale_colour_manual(values = c(stained = col_main, control = col_ctrl), labels = c(stained = "Stained", control = "Negative control"), name = NULL) +
  scale_x_continuous(limits = c(0, 112), breaks = seq(0, 100, 25), expand = expansion(add = c(3, 0))) +
  facet_wrap(~pop_lab, nrow = 1) + labs(x = "Percent", y = NULL, title = "Population frequencies") +
  theme_flow() + theme(legend.position = "top", legend.justification = "left")
save_fig(p6, "06_population_frequencies", min(183, 55 * nlevels(f6$pop_lab) + 45), 25 + 6 * length(smp))

# ---- 7. stain index (if a positive gate and controls exist) ----------------
if (!is.null(si) && nrow(si)) {
  s7 <- add_meta(si) |> mutate(label_f = factor(label, levels = rev(meta$label)))
  p7 <- ggplot(s7, aes(stain_index, label_f)) +
    geom_segment(aes(x = 0, xend = stain_index, yend = label_f), colour = "#e1e0d9", linewidth = 0.4) +
    geom_point(colour = col_main, size = 2.2) + geom_text(aes(x = stain_index + max(stain_index) * 0.04, label = sprintf("%.1f", stain_index)), hjust = 0, size = 2.7, colour = ink2) +
    scale_x_continuous(limits = c(0, max(s7$stain_index) * 1.2), expand = expansion(add = c(max(s7$stain_index) * 0.02, 0))) +
    labs(x = "Stain index = (median pos - median neg) / (2 x rSD neg), linear scale", y = NULL,
         title = paste(pos_name, "resolution by sample")) + theme_flow()
  save_fig(p7, "07_stain_index", 120, 25 + 7 * nrow(s7))
}

# ---- run record for the report skill --------------------------------------
kw1 <- function(s, k) { v <- keyword(fs_lin[[s]])[[k]]; if (is.null(v)) NA_character_ else as.character(v) }
pv <- function(p) as.character(utils::packageVersion(p))
info <- list(
  analysis_date = format(Sys.Date()), script = "sh800_flow.R (sh800-flow-analysis skill)",
  fcs_dir = fcs_dir, file_pattern = file_pattern, files = I(basename(files)), n_files = length(files),
  instrument = I(unique(vapply(smp, kw1, "", k = "$CYT"))), instrument_serial = I(unique(vapply(smp, kw1, "", k = "$CYTSN"))),
  acquisition_dates = as.list(setNames(vapply(smp, kw1, "", k = "$DATE"), smp)),
  fcs_version = I(unique(vapply(smp, kw1, "", k = "FCSversion"))),
  channels = list(fsc_area = fsc_a, fsc_height = fsc_h, fsc_width = fsc_w, side_scatter = ssc_a, time = time_ch, fluorescence = fl_ch),
  channel_labels = as.list(setNames(lab(fl_ch), fl_ch)), panel = as.list(panel), stained_channels = I(stained_ch),
  compensation = comp_status, compensation_short = comp_short, transform = tf_type,
  margin_rule = "events piled up at a detector's maximum (>= 5 within 0.01%) are removed as saturated",
  peacoqc = !is.na(time_ch), debris_gate = "openCyto mindensity on FSC-A",
  singlet_gate = if (!is.null(singlet_params)) sprintf("size-aware FSC-A/FSC-H ratio band, +/- %g robust SD of the doublet-free side", singlet_k) else "none (no FSC-H channel)",
  leaf_population = leaf,
  positive_gate = if (!is.null(pos_gate)) list(channel = pos_gate$channel, marker = lab(pos_gate$channel), name = pos_name,
                                               quantile = pos_gate$quantile, control_pattern = control_pattern, match_by = match_by,
                                               thresholds_logicle = if (!is.null(thr)) as.list(round(thr, 4)) else "mindensity fallback") else NULL,
  controls = I(meta$sample[meta$control]), example_sample = example_sample,
  samples = lapply(seq_len(nrow(meta)), function(i) { r <- meta[i, setdiff(names(meta), c("sample_f", "label_f"))]; lapply(r, function(v) if (is.factor(v)) as.character(v) else v) }),
  figures = I(sort(list.files(out_dir, "\\.png$"))), tables = I(sort(list.files(out_dir, "\\.csv$"))),
  software = list(R = R.version.string, flowCore = pv("flowCore"), flowWorkspace = pv("flowWorkspace"), openCyto = pv("openCyto"),
                  PeacoQC = pv("PeacoQC"), ggplot2 = pv("ggplot2")))
jsonlite::write_json(info, file.path(out_dir, "run_info.json"), auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null")
message("Done. Figures and tables in ", out_dir)
print(st |> select(sample, pop, percent, count, percent_of))
if (!is.null(si)) print(si)
