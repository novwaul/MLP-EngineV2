#!/usr/bin/env bash
# KLayout DRC (sky130A_mr.drc) split into FEOL and BEOL passes.
# The single-pass run exceeds the container's ~11.7 GiB memory limit and is
# killed, so the flow's KLayout.DRC step is disabled (RUN_KLAYOUT_DRC: false)
# and the same runset is applied here in two passes instead.
# usage (inside the librelane container): klayout_drc_split.sh <run_dir> <top_cell>
set -euo pipefail
run_dir="$1"
top="$2"
runset=/pdk/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.tech/klayout/drc/sky130A_mr.drc
gds="$run_dir/final/gds/$top.gds"
out="$run_dir/klayout-drc-split"
mkdir -p "$out"
total=0
for pass in feol beol; do
  feol=false; beol=false
  [ "$pass" = feol ] && feol=true
  [ "$pass" = beol ] && beol=true
  klayout -b -zz -r "$runset" -rd input="$gds" -rd topcell="$top" \
    -rd report="$out/$pass.lyrdb" -rd feol=$feol -rd beol=$beol \
    -rd floating_metal=false -rd offgrid=true -rd seal=true -rd thr=1 \
    > "$out/$pass.log" 2>&1
  n=$(grep -c "<item>" "$out/$pass.lyrdb" || true)
  echo "$pass: $n violations"
  total=$((total + n))
done
echo "total: $total violations"
