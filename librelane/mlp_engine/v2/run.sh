#!/usr/bin/env bash
set -euo pipefail

design_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tag="RUN_$(date +%Y-%m-%d_%H-%M-%S)"
config="$design_dir/config/config.json"
run_dir="$design_dir/runs/$tag"

# --force-run-dir requires an existing directory and overrides the default
# runs directory next to the design configuration.
mkdir -p "$run_dir"
librelane --run-tag "$tag" --force-run-dir "$run_dir" --design-dir "$design_dir" "$config"
