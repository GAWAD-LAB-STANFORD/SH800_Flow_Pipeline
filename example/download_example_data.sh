#!/usr/bin/env bash
# Download the 18 Sony SH800 FCS files used as the example dataset.
# Source: Tang V. Flow cytometry data from uOttawa Flow Cytometry & Virometry Core Facility
#   (Aurora, CytoFLEX S, SH800, LSR Fortessa). figshare, 2025. doi:10.6084/m9.figshare.30584678. CC BY 4.0.
# Only the files whose $CYT keyword is LE-SH800SZFCPL are fetched. Run from this example/ folder.
set -euo pipefail
out="$(dirname "$0")/SH800_uOttawa_figshare_30584678"
mkdir -p "$out"
while read -r id size name; do
  dest="$out/$name"
  if [ -f "$dest" ] && [ "$(wc -c < "$dest" | tr -d " ")" = "$size" ]; then echo "have  $name"; continue; fi
  curl -sSL --fail -o "$dest" "https://ndownloader.figshare.com/files/$id"
  got="$(wc -c < "$dest" | tr -d " ")"
  if [ "$got" != "$size" ]; then echo "SIZE MISMATCH $name ($got vs $size)" >&2; exit 1; fi
  echo "got   $name"
done <<'EOF'
59449778 106812 BDComp_CD4-SK3-PE_High.fcs
59449781 107692 BDComp_CD4-SK3-PE_Low.fcs
59449784 164848 BDComp_CD4-SK3-PE_Medium.fcs
59449787 107516 BDComp_Unst_High.fcs
59449790 107868 BDComp_Unst_Low.fcs
59449793 162912 BDComp_Unst_Medium.fcs
59449796 1769792 Cytotrol_CD4-SK3_PE_High.fcs
59449802 1874468 Cytotrol_CD4-SK3_PE_Low.fcs
59449799 1962116 Cytotrol_CD4-SK3_PE_Medium.fcs
59449805 1682804 Cytotrol_Unst_High.fcs
59449808 1644304 Cytotrol_Unst_Low.fcs
59449811 1896512 Cytotrol_Unst_Medium.fcs
59449814 163880 QBritePE_Lot82820_High.fcs
59449817 140340 QBritePE_Lot82820_Low.fcs
59449820 123972 QBritePE_Lot82820_Medium.fcs
59449823 370680 SpheroRainbow_RCP-30-5A_EAM02_High.fcs
59449826 370416 SpheroRainbow_RCP-30-5A_EAM02_Low.fcs
59449829 368788 SpheroRainbow_RCP-30-5A_EAM02_Medium.fcs
EOF
echo "Done: $(ls "$out"/*.fcs | wc -l | tr -d " ") FCS files in $out"
