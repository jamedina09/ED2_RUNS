#!/usr/bin/env bash
# Full end-to-end experiment pipeline, for any site under sites/<site>/:
# build ED2IN -> run ED2 (podman) -> extract + plot output (once per
# resolution enabled via --output_freq) -> catalog output variables ->
# record status in the repo-root experiments_registry.csv.
#
# One command instead of the ~7 separate steps in README.md's step-by-step
# section - use those directly instead if you want to inspect/rerun
# individual steps.
#
# Usage (--site defaults to BCI, the example site shipped with this repo):
#   ./run_experiment.sh --site=BCI --name=baseline
#   ./run_experiment.sh --site=BCI --name=plant_hydro --plant_hydro_scheme=1
#   ./run_experiment.sh --site=BCI --name=high_rho_pft3 --pft_config=sites/BCI/pft_configs/high_rho_pft3.xml
#   ./run_experiment.sh --site=BCI --name=plant_hydro_long --plant_hydro_scheme=1 --start_date=1950-01-01 --end_date=2022-12-31
#
# All other flags are passed straight through to that site's ED2IN-builder
# script (see README.md's "Adapting to a new site" section for the full
# flag list and the naming convention a new site's scripts must follow for
# this orchestrator to find them). sites/<site>/run/{met,init} must already
# exist (that site's data-prep script) - this script does not build shared
# inputs, only per-experiment ones.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# --- Parse --site and --output_freq out of the argument list (everything,
#     including these two, still passes through unchanged to the site's own
#     ED2IN-builder script) ---------------------------------------------------
SITE="BCI"
OUTPUT_FREQ="monthly"
for arg in "$@"; do
    case "$arg" in
        --site=*) SITE="${arg#--site=}" ;;
        --output_freq=*) OUTPUT_FREQ="${arg#--output_freq=}" ;;
    esac
done
SITE_DIR="sites/${SITE}"
SITE_LOWER="$(echo "$SITE" | tr '[:upper:]' '[:lower:]')"

if [[ ! -d "$SITE_DIR" ]]; then
    echo "No such site: $SITE_DIR does not exist. Available sites:" >&2
    ls -1 sites/ >&2 2>/dev/null || echo "  (none - sites/ is empty)" >&2
    exit 1
fi
if [[ ! -d "$SITE_DIR/run/met" || ! -d "$SITE_DIR/run/init" ]]; then
    echo "$SITE_DIR/run/met or $SITE_DIR/run/init missing - run this site's data-prep script first (README.md)." >&2
    exit 1
fi

BUILD_SCRIPT="$SITE_DIR/R/model_runs/build_${SITE_LOWER}_ed2in.R"
EXTRACT_SCRIPT="$SITE_DIR/R/output_preparation/extract_${SITE_LOWER}_output.R"
PLOT_SCRIPT="$SITE_DIR/R/output_preparation/plot_${SITE_LOWER}_output.R"
for f in "$BUILD_SCRIPT" "$EXTRACT_SCRIPT" "$PLOT_SCRIPT"; do
    if [[ ! -f "$f" ]]; then
        echo "Expected script not found: $f" >&2
        echo "(sites/<site>/ scripts must follow the build_<sitelower>_ed2in.R / extract_<sitelower>_output.R / plot_<sitelower>_output.R naming convention - see README.md)" >&2
        exit 1
    fi
done

# --- 1. Build this experiment's ED2IN, capture the (possibly auto-timestamped) exp_id ---
BUILD_OUT="$(Rscript "$BUILD_SCRIPT" "$@")"
echo "$BUILD_OUT"
EXP_ID="$(echo "$BUILD_OUT" | grep '^EXP_ID:' | sed 's/^EXP_ID://' | xargs)" # xargs trims whitespace
if [[ -z "$EXP_ID" ]]; then
    echo "Could not determine exp_id from $BUILD_SCRIPT's output - aborting." >&2
    exit 1
fi
echo "=== Site: $SITE  Experiment: $EXP_ID ==="

RUN_LOG="$SITE_DIR/run/experiments/${EXP_ID}/run.log"

# --- 2. Run the model ---------------------------------------------------------
Rscript R-tools/update_registry_status.R --exp="$EXP_ID" --status=running
echo "Running ED2 (log: $RUN_LOG)..."
START_TS=$(date +%s)
set +e
./run_ed2.sh "$SITE_DIR/run" "ED2IN-${EXP_ID}" > "$RUN_LOG" 2>&1
RUN_EXIT=$?
set -e
END_TS=$(date +%s)
RUN_SECONDS=$((END_TS - START_TS))

if [[ $RUN_EXIT -ne 0 ]] || ! grep -q "Time integration ends" "$RUN_LOG" || grep -q "FATAL" "$RUN_LOG"; then
    echo "ED2 run FAILED (exit=$RUN_EXIT) after ${RUN_SECONDS}s - see $RUN_LOG" >&2
    Rscript R-tools/update_registry_status.R --exp="$EXP_ID" --status=failed \
        --run_seconds="$RUN_SECONDS" --notes="see run.log"
    exit 1
fi
echo "ED2 run completed in ${RUN_SECONDS}s."
Rscript R-tools/update_registry_status.R --exp="$EXP_ID" --status=completed \
    --run_seconds="$RUN_SECONDS"

# --- 3. Extract + plot, once per resolution enabled via --output_freq -------
# A resolution can legitimately have no output yet (e.g. --output_freq=monthly
# on a run shorter than one month - ED2 only writes analysis-E-*.h5 at month
# boundaries), so a failure here is reported but does not abort the other
# resolutions or steps 4/5 below.
IFS=',' read -ra RESOLUTIONS <<< "$OUTPUT_FREQ"
for RES in "${RESOLUTIONS[@]}"; do
    echo "--- Extracting/plotting at --resolution=$RES ---"
    if ! Rscript "$EXTRACT_SCRIPT" --exp="$EXP_ID" --resolution="$RES"; then
        echo "WARNING: extraction at --resolution=$RES failed (see above) - skipping its plots. This is expected if the run is shorter than one $RES period." >&2
        continue
    fi
    Rscript "$PLOT_SCRIPT" --exp="$EXP_ID" --resolution="$RES"
done

# --- 4. Catalog every output variable (name, dimensions, units, description) -
Rscript R-tools/describe_variables.R --site="$SITE" --exp="$EXP_ID"

echo ""
echo "=== Done: $EXP_ID ==="
echo "Output:    $SITE_DIR/run/experiments/${EXP_ID}/"
echo "Figures:   $SITE_DIR/run/experiments/${EXP_ID}/figures/"
echo "Variables: $SITE_DIR/run/experiments/${EXP_ID}/variable_catalog.csv"
echo "List all experiments:   Rscript R-tools/list_experiments.R"
echo "Compare with another:   Rscript R-tools/compare_experiments.R --site=${SITE} --exp=${EXP_ID},<other_exp_id>"
