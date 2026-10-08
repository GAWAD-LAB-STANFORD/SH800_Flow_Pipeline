# SH800 Cytotrol CD4-PE run: summary (2026-10-08, v2)

Data: six Cytotrol PBMC tubes (CD4-SK3 PE and unstained, each at Low / Medium / High settings) from
figshare 10.6084/m9.figshare.30584678 (Tang, uOttawa; CC BY 4.0). Bead files in the same folder were not analyzed.

v2 replaces the openCyto singletGate, which kept 95-96% of cells and let through doublets: 11-16% of the
events it kept had FSC-A/FSC-H above 1.5. The new size-aware ratio band keeps 77-80% of cells, and none of
the kept events exceed A/H 1.5 (max 1.41-1.47). Saturated events (FSC-H clipped near 1.06e6, 21-44 per tube)
are now removed before gating, and PeacoQC removed at most 1.8% of events. About 82-85% of events are debris
of the lyophilized material; the debris cut sits in the valley on log-log FSC/SSC. CD4+ was 57.2-59.7% of
singlets across settings (unstained controls 0.5% by construction); CD4-dim monocytes straddle the cut, so
this is not a CD4 T-cell frequency. Stain index rose from 72 (Low) to 96 (Medium) and 100 (High). The embedded
spillover is an identity matrix, so the data are uncompensated; PE signal is visible in FL2, FL4, FL5 and FL6,
which does not affect this single-color readout.
