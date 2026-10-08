# Real Sony SH800 sample data (downloaded 2026-10-08)

Source: Tang & Welsh, "Flow cytometry data from uOttawa Flow Cytometry & Virometry Core Facility
Aurora, CytoFLEX S, SH800, and LSR Fortessa", figshare dataset 30584678, CC BY 4.0.
https://figshare.com/articles/dataset/30584678

Only the 18 files whose `$CYT` keyword is `LE-SH800SZFCPL` were downloaded (Sony SH800SZ).
Acquired for a fluorescence-calibration study (Cytometry Part A submission, Nov 2025).

Samples, each at Low / Medium / High instrument settings:
- Cytotrol_*      lyophilized human PBMC, CD4 (clone SK3) PE-stained and unstained (~37k-44k events)
- BDComp_*        BD CompBeads, CD4-PE-stained and unstained (~2.3k-3.7k events)
- QBritePE_*      PE quantitation beads (~2.7k-3.6k events)
- SpheroRainbow_* Spherotech rainbow calibration beads (~8.3k events)

Channels: TIME, FSC-A, FSC-H, FSC-W, SSC-A, FL1-A ... FL6-A. All files carry a $SPILLOVER keyword.
Note: these exports name side scatter SSC-A, not BSC-A.
