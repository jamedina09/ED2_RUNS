# Running ED2 for single-point sites

A framework for building, running, tracking, and exploring single-point ED2
experiments at any site. Each site lives in its own folder under `sites/`
with its own raw data and site-specific R scripts (met/soil/vegetation
prep, ED2IN namelist building); everything else — the container image, the
experiment orchestrator, the cross-site registry, output cataloging and
comparison tools — is shared and site-agnostic.

**BCI (Barro Colorado Island) is the worked example currently set up**
(`sites/BCI/`), driven by real site data (ForestGEO 50-ha plot census +
QA/QC'd ESS-DIVE tower met). The container image is built from a separate
repo (`/Users/medinaja/ed2-personal-container`, your ED2 fork); everything
else needed to actually run and evaluate experiments — data, scripts,
experiment tracking, output/plots — lives here, organized so a second site
can be added alongside BCI without touching BCI's own files (§11).

## TL;DR

```sh
# One-time setup (§1-§2): podman machine running, ed2:personal image built,
# R-utils/ED2IN extracted, raw data in place.

cd /Users/medinaja/ED2_RUNS

# One-time per site: build the shared met driver + vegetation init (§6.1)
Rscript sites/BCI/R/data_preparation/build_bci_datasets.R

# Run a full experiment at a site: build namelist -> run ED2 -> extract ->
# plot -> catalog variables -> log to the registry. One command, ~6 min
# for BCI's default 3-month baseline window (§4).
./run_experiment.sh --site=BCI --name=baseline

# Run a second experiment to compare against (e.g. dynamic plant hydraulics)
./run_experiment.sh --site=BCI --name=plant_hydro --plant_hydro_scheme=1

# Get hourly and daily output too (monthly is always on) - §13
./run_experiment.sh --site=BCI --name=hires --output_freq=monthly,daily,hourly

# Continue an earlier experiment from where it left off, instead of
# starting bare-ground/from the census again - §12
./run_experiment.sh --site=BCI --name=continued --restart_from=<earlier_exp_id> --end_date=2004-12-31

# Find what you've run (across all sites), and compare two experiments at
# the same site on one set of plots (§5)
Rscript R-tools/list_experiments.R
Rscript R-tools/compare_experiments.R --site=BCI --exp=<baseline_id>,<plant_hydro_id>
```

Every `run_experiment.sh --site=<site> --name=X` call auto-generates a
fresh, never-colliding `exp_id` (`X_<timestamp>`) and writes its results to
`sites/<site>/run/experiments/<exp_id>/` — see §3 for the full layout, §4
for all available flags (longer windows, PFT parameter overrides, ...), §5
for how to find and compare results afterward, §11 for adding a new site,
§12 for restarting from an earlier experiment, and §13 for hourly/daily
output.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [One-time setup](#2-one-time-setup)
3. [Workspace layout](#3-workspace-layout)
4. [Quick start: run a full experiment](#4-quick-start-run-a-full-experiment)
5. [Finding and comparing results](#5-finding-and-comparing-results)
6. [Step-by-step workflow (manual control)](#6-step-by-step-workflow-manual-control)
7. [What each script does](#7-what-each-script-does)
8. [How the climate years work (recycling, running outside 2003-2016)](#8-how-the-climate-years-work-recycling-running-outside-2003-2016)
9. [Changing PFT parameters (wood density, SLA, Vm0, and other traits)](#9-changing-pft-parameters-wood-density-sla-vm0-and-other-traits)
10. [Caveats when interpreting results](#10-caveats-when-interpreting-results)
11. [Adding a new site](#11-adding-a-new-site)
12. [Restarting from an earlier experiment](#12-restarting-from-an-earlier-experiment)
13. [Output resolution: monthly, daily, hourly](#13-output-resolution-monthly-daily-hourly)

## 1. Prerequisites

- [podman](https://podman.io/), with `podman machine` running (macOS/Windows only):

  ```sh
  podman machine start
  ```

- R, with these packages installed on the host (only the `ed2` model run
  itself happens inside the container — every data-prep/output/plotting
  script runs on the host):

  ```r
  install.packages(c("ncdf4", "hdf5r", "data.table", "chron", "ggplot2"))
  # PEcAn.ED2 (from your local PEcAn checkout, e.g. /Users/medinaja/pecan/models/ed)
  ```

## 2. One-time setup

The `ed2:personal` image (built from `/Users/medinaja/ed2-personal-container`)
must already exist — check with `podman images ed2:personal`. If it doesn't,
build it there:

```sh
cd /Users/medinaja/ed2-personal-container
podman build -t ed2:personal -f docker/Dockerfile.personal .
```

This also bakes in `common/ed_inputs/` (chill-day/degree-day climatology,
generic ED2 startup data, not site-specific) at `/opt/ed2_common/ed_inputs/`
inside the image — no per-run copy needed; see §7's `THSUMS_DATABASE` row.
This image and everything in this section is shared by every site.

### 2.1 Extract `R-utils/` and the `ED2IN` template

Every site's R scripts need two things out of the ED2 source tree that
aren't distributed separately: the lab's `R-utils/` physics/allometry
functions, and the `ED/run/ED2IN` namelist template (the full stock
namelist that each site's ED2IN-builder script reads and overrides — it
does not generate `ED2IN` from scratch). Pull them from the image's build
stage (same Dockerfile, `build` target, before the final minimal-runtime
stage strips everything but the compiled binary):

```sh
cd /Users/medinaja/ed2-personal-container
podman build -t ed2:build --target build -f docker/Dockerfile.personal .
podman create --name ed2-extract ed2:build
podman cp ed2-extract:/ED2/R-utils "$HOME/ED2_RUNS/R-utils"
mkdir -p "$HOME/ED2_RUNS/ED/run"
podman cp ed2-extract:/ED2/ED/run/ED2IN "$HOME/ED2_RUNS/ED/run/ED2IN"
podman rm ed2-extract
```

Only needs to be redone if you rebuild `ed2:build` from a different
`ED2_GIT_REF`. `R-utils/` and `ED/run/ED2IN` live at the repo root, shared
by every site.

### 2.2 BCI raw data (the example site)

`sites/BCI/raw_data/` should already contain:

- `bci_climate/` — official QA/QC'd BCI tower met, hourly 2003-2016
  (Faybishenko, Knox, Chambers et al., LBNL/STRI, ESS-DIVE).
- `bci_stem_data/` — ForestGEO 50-ha plot census #8 (`bci.stem8.rdata`) +
  species table with wood density (`bci.spptable.rdata`).
- `bci_forcing_data/` — CLM5/ELM `surfdata_bci_*.nc`, used only for
  `PCT_SAND`/`PCT_CLAY` soil texture.

`ED2_Support_Files-master/` (the ED2 lab's site-processing scripts —
`tower_processing/`, `pss+css_processing/`, `soil_data_processing/`, at the
repo root, shared by every site) should also be present alongside
`R-utils/` — `build_bci_datasets.R` sources functions from both.

## 3. Workspace layout

```text
ED2_RUNS/
├── run_ed2.sh                    # wrapper: podman run against a RUNDIR + ED2IN name (any site)
├── run_experiment.sh              # orchestrator: build -> run -> extract -> plot -> catalog -> registry, for any site (§4)
├── experiments_registry.csv       # every experiment ever built, at any site: id, site, config, status (§5)
├── .ed2_repo_root                 # empty marker file; every script walks up
│                                   # from its own path looking for this (not .git)
│                                   # to find the workspace root, portably
├── R-utils/                       # ED2 lab physics/allometry, shared by every site (§2.1)
├── ED/run/ED2IN                   # ED2IN template, shared by every site (§2.1)
├── ED2_Support_Files-master/      # site-processing driver scripts, shared by every site (§2.2)
├── R-tools/                         # cross-site, site-agnostic tools (§5, §7) - not to be confused with each site's own R/ below, or R-utils/ above

│   ├── registry_utils.R              # sourced helper: read/add/update experiments_registry.csv
│   ├── update_registry_status.R      # CLI wrapper used by run_experiment.sh
│   ├── describe_variables.R          # variable/dimension/units catalog, works at any site
│   ├── list_experiments.R            # query the registry across all sites
│   └── compare_experiments.R         # overlay multiple experiments (same site) on shared axes
└── sites/
    └── BCI/                        # one folder per site - BCI is the example site (§11 to add another)
        ├── raw_data/                  # real source data (§2.2)
        ├── pft_configs/                # your own XML PFT-parameter override files (§9)
        │   └── high_rho_pft3.xml         # example: PFT 3 wood density raised to 0.80 g/cm3
        ├── run/
        │   ├── met/                   # shared met driver (all this site's experiments use the same met)
        │   ├── init/                  # shared vegetation init (all this site's experiments use the same census)
        │   ├── diagnostics/{met,init}/ # input QC plots (input_visualization/, independent of any experiment)
        │   ├── comparisons/<name>/     # compare_experiments.R output (§5)
        │   ├── ED2IN-<exp_id>          # one namelist per experiment
        │   ├── pft_config-<exp_id>.xml # copied in only if --pft_config was used (§9)
        │   └── experiments/
        │       └── <exp_id>/             # e.g. baseline_20260716_110606
        │           ├── analysis-{E,D,I}-*.h5, history-S-*.h5, history.xml, run.log
        │           │                                      # E=monthly, D=daily, I=hourly (§13); history-S-* is what --restart_from (§12) reads
        │           ├── timeseries_output_<resolution>.{csv,rds}  # ecosystem-scale, one file per --resolution extracted (§13)
        │           ├── sizeclass_output_<resolution>.{csv,rds}   # PFT x DBH-size-class, one file per --resolution extracted
        │           ├── variable_catalog.csv            # describe_variables.R (§5)
        │           └── figures/<resolution>/*.png       # this site's plot script, one subfolder per --resolution
        └── R/                           # BCI's own site-specific scripts (§11: a new site mirrors this)
            ├── data_preparation/
            │   ├── evaluate_bci_data.R    # optional: sanity-check raw data
            │   ├── build_bci_datasets.R   # met + soil + vegetation init -> sites/BCI/run/{met,init}
            │   └── lib_load_utils.R       # sourced helper, not run directly
            ├── model_runs/
            │   └── build_bci_ed2in.R      # ED2IN namelist -> sites/BCI/run/ED2IN-<exp_id>; registers in the registry; --restart_from/--output_freq (§12/§13)
            ├── output_preparation/
            │   ├── extract_bci_output.R   # ecosystem-scale + size-class output at any --resolution -> timeseries_output_<resolution>.{csv,rds}, sizeclass_output_<resolution>.{csv,rds}
            │   └── plot_bci_output.R      # all plots (flux_/stock_/water_/energy_/forcing_/sizeclass_) at any --resolution -> figures/<resolution>/
            └── input_visualization/
                ├── plot_met_input.R    # QC/visualize the met driver itself (independent of any run)
                └── plot_init_input.R   # QC/visualize the vegetation census itself (independent of any run)
```

The naming convention that lets `run_experiment.sh --site=<site>` find a
site's scripts automatically: `sites/<site>/R/model_runs/build_<site
lowercased>_ed2in.R`, and `.../output_preparation/{extract,plot}_<site
lowercased>_output.R` — see §11.

## 4. Quick start: run a full experiment

Once §1-§2 are done and `sites/<site>/run/{met,init}` exist (§6.1,
one-time per site), one command runs the entire pipeline — build namelist,
run ED2, extract both ecosystem-scale and size-class-resolved output at
every requested `--output_freq` resolution (§13), plot everything, catalog
every output variable, and record the outcome in the registry:

```sh
./run_experiment.sh --site=BCI --name=baseline
```

Every experiment is auto-named `<name>_<YYYYMMDD_HHMMSS>` (e.g.
`baseline_20260716_110606`), so running the same `--name` again — or the
exact same config — never collides with a previous run; each attempt gets
its own timestamped id and its own output directory.

Flags (all optional except `--site`, passed straight through to that
site's ED2IN-builder script):

| Flag | Default | Meaning |
| --- | --- | --- |
| `--site` | `BCI` | Which `sites/<site>/` to run. |
| `--name` | `experiment` | Human label; the timestamp is appended automatically to form the actual `exp_id`. |
| `--exp` | *(none)* | Pins an **exact** id with no timestamp appended — only for reproducing/rebuilding a specific already-known id, not for new runs. |
| `--plant_hydro_scheme` | `0` | `NL%PLANT_HYDRO_SCHEME` — 0 = static (leaf/wood always saturated), 1 = Christoffersen et al. (2016), 2 = Xu et al. (2016). |
| `--start_date` | `2003-01-01` | Simulation start (`NL%IYEARA`/`IMONTHA`/`IDATEA`). BCI-specific default; other sites set their own. |
| `--end_date` | `2003-03-31` | Simulation end (`NL%IYEARZ`/`IMONTHZ`/`IDATEZ`). Independent of the met data's own 2003-2016 range at BCI — see §8. |
| `--pft_config` | *(none)* | Path to an XML file overriding ED2's compiled-in PFT parameters (wood density, SLA, ...) — see §9. |
| `--restart_from` | *(none)* | An earlier experiment's `exp_id` to continue from (`RUNTYPE=HISTORY`) instead of starting `INITIAL` from the census — see §12. |
| `--restart_date` | *(latest)* | Which of `--restart_from`'s `history-S-*.h5` snapshots to restart from, if not the most recent — see §12. |
| `--output_freq` | `monthly` | Comma-separated list of `monthly`/`daily`/`hourly` — which output resolutions ED2 writes and `run_experiment.sh` extracts/plots — see §13. |

Examples:

```sh
./run_experiment.sh --site=BCI --name=baseline
./run_experiment.sh --site=BCI --name=plant_hydro --plant_hydro_scheme=1
./run_experiment.sh --site=BCI --name=high_rho_pft3 --pft_config=sites/BCI/pft_configs/high_rho_pft3.xml
./run_experiment.sh --site=BCI --name=plant_hydro_long --plant_hydro_scheme=1 --start_date=1950-01-01 --end_date=2022-12-31
./run_experiment.sh --site=BCI --name=continued --restart_from=baseline_20260716_110606 --end_date=2004-12-31
./run_experiment.sh --site=BCI --name=hires --output_freq=monthly,daily,hourly
```

**Verified timing** (2026-07-16, this environment, BCI's default 3-month
window): cohort loading/fusion (248,715 cohorts → ~80 fused cohorts) takes
~67-70s wall time regardless of `PLANT_HYDRO_SCHEME`. Time integration for
the 3-month window took ~165s with `PLANT_HYDRO_SCHEME=0` and ~520s with
`PLANT_HYDRO_SCHEME=1` (the extra internal water-potential sub-stepping
roughly triples wall time); a full `run_experiment.sh` call (including
extraction, plotting, and cataloging) completed in ~6 minutes end-to-end for
the baseline config. Extrapolating the baseline integration rate, a full
2003-2016 run (168 months) would take roughly 4-4.5 hours with hydraulics
off, correspondingly longer with it on. `run_experiment.sh` runs to
completion in the foreground; background it for anything long-running:

```sh
./run_experiment.sh --site=BCI --name=plant_hydro_long --plant_hydro_scheme=1 \
    --start_date=1950-01-01 --end_date=2022-12-31 > /tmp/my_run.log 2>&1 &
tail -f /tmp/my_run.log
```

If the ED2 run itself fails (non-zero exit, missing "Time integration
ends", or a `FATAL` in the log), `run_experiment.sh` stops immediately,
marks the experiment `failed` in the registry (see §5), and does not
attempt extraction/plotting on incomplete output.

## 5. Finding and comparing results

### 5.1 List every experiment ever built, at any site

```sh
Rscript R-tools/list_experiments.R
Rscript R-tools/list_experiments.R --site=BCI
Rscript R-tools/list_experiments.R --name=plant_hydro   # substring filter
Rscript R-tools/list_experiments.R --status=completed
```

Reads `experiments_registry.csv` (repo root) — one row per experiment (id,
site, name, timestamp, config flags used, and status: `built` → `running`
→ `completed`/`failed`, plus wall-clock run time). This file lives at the
repo root, not inside any site's `run/`, so it survives a
`rm -rf sites/<site>/run` and stays the permanent cross-site record of
every experiment ever attempted, including ones whose output has since
been deleted.

### 5.2 Identify output variables (names, dimensions, units)

```sh
Rscript R-tools/describe_variables.R --site=BCI --exp=<exp_id>
```

Writes `sites/BCI/run/experiments/<exp_id>/variable_catalog.csv` — every
one of ED2's ~600 output variables in that experiment's HDF5 files, with
its exact HDF5 dimensions and a "kind" classification (polygon-level
scalar, PFT x size-class array, soil-layer array, per-cohort array, or
other — this classification works identically at any site, since it's
based purely on HDF5 shape), plus a curated description/units/source-script
for the ~35 variables the BCI pipeline actually extracts (GPP, `WfluxGW`,
`AGB_PY`, ...). Read this instead of re-deriving variable meanings from
ED2's Fortran source each time. `run_experiment.sh` runs this automatically
for every experiment.

### 5.3 Compare experiments side by side

```sh
Rscript R-tools/compare_experiments.R --site=BCI --exp=<id1>,<id2>[,<id3>,...]
Rscript R-tools/compare_experiments.R --site=BCI --exp=<id1>,<id2> --resolution=daily
```

Overlays the requested experiments' (same site) ecosystem-scale output
(coloured by experiment) into one set of faceted plots — carbon fluxes,
carbon stocks, plant hydraulics, energy/microclimate — written to
`sites/BCI/run/comparisons/comparison_<resolution>_<timestamp>/` (or
`--out=<name>` for a fixed folder name). `--resolution` (default `monthly`)
must match a resolution every experiment being compared was actually
extracted at (§13) — requires that site's extraction script to have
already run at that resolution for every experiment (`run_experiment.sh`
already does this for whatever `--output_freq` it was given). This tool is
site-agnostic because every site's extraction script writes to the same
`timeseries_output_<resolution>.rds` filename regardless of the script's
own name (§7). This is the fastest way to see, e.g., that
`WfluxGW`/`WfluxWL` are flat zero in a static-hydraulics run and clearly
non-zero once `PLANT_HYDRO_SCHEME=1` — one plot instead of opening two
separate `figures/` folders.

## 6. Step-by-step workflow (manual control)

`run_experiment.sh` (§4) is the whole pipeline in one call. Use the
individual steps below instead when you want to inspect intermediate
output, rerun just one stage, or debug a failure. Examples use BCI; swap
paths for another site.

`met/` and `init/` (built once by a site's data-prep script) are
**experiment-independent** — the same site meteorology and the same real
vegetation census underlie every experiment at that site. What varies
between experiments is only the `ED2IN` namelist (that site's ED2IN-builder
script) and where its output lands
(`sites/<site>/run/experiments/<exp_id>/`).

### 6.1 Build the shared inputs (once per site)

```sh
cd /Users/medinaja/ED2_RUNS
Rscript sites/BCI/R/data_preparation/evaluate_bci_data.R   # optional: QC raw data
Rscript sites/BCI/R/data_preparation/build_bci_datasets.R  # → sites/BCI/run/{met,init}
```

Only re-run this if the raw data changes — not per experiment. If you
`rm -rf sites/BCI/run` to start fully clean, this is the first thing to
rebuild (it does not touch `experiments_registry.csv`, which lives at the
repo root).

### 6.2 Build an experiment's `ED2IN`

```sh
Rscript sites/BCI/R/model_runs/build_bci_ed2in.R --name=<label> [flags]
```

Same flags as §4's table (this script doesn't take `--site` itself — it's
already BCI-specific by virtue of living inside `sites/BCI/`). Writes
`sites/BCI/run/ED2IN-<exp_id>`, creates `sites/BCI/run/experiments/<exp_id>/`,
and adds a `built` row to `experiments_registry.csv`. Prints the resolved
`exp_id` as its first line of output (`EXP_ID:<value>`) — this is what
`run_experiment.sh` parses to chain the remaining steps.

### 6.3 Run it

```sh
./run_ed2.sh sites/BCI/run ED2IN-<exp_id>
```

`run_ed2.sh` bind-mounts `sites/BCI/run` at `/data` and runs:

```sh
podman run --rm --ulimit stack=-1:-1 -v "$(pwd)/sites/BCI/run:/data:Z" ed2:personal -f ED2IN-<exp_id>
```

Paths inside `ED2IN` are relative to `/data`, not the host path. It runs in
the foreground; for anything longer than a few minutes, background it and
tail the log:

```sh
./run_ed2.sh sites/BCI/run ED2IN-<exp_id> > /tmp/bci_run_<exp_id>.log 2>&1 &
tail -f /tmp/bci_run_<exp_id>.log          # or: podman stats --no-stream
```

To keep the registry accurate when running manually, update its status
yourself:

```sh
Rscript R-tools/update_registry_status.R --exp=<exp_id> --status=completed --run_seconds=<n>
```

### 6.4 Extract and plot the output

One pair of scripts, keyed by `--exp` and `--resolution` (`monthly` by
default; see §13 for `daily`/`hourly`). Each covers both ecosystem-scale
and PFT x size-class-resolved output in one pass:

```sh
Rscript sites/BCI/R/output_preparation/extract_bci_output.R --exp=<exp_id> --resolution=monthly
Rscript sites/BCI/R/output_preparation/plot_bci_output.R --exp=<exp_id> --resolution=monthly

# Catalog every output variable's name/dimensions/units (see §5.2) - a
# cross-site tool, hence --site here (unlike the site-specific scripts above)
Rscript R-tools/describe_variables.R --site=BCI --exp=<exp_id>
```

Writes into `sites/BCI/run/experiments/<exp_id>/` —
`timeseries_output_<resolution>.{csv,rds}`, `sizeclass_output_<resolution>.{csv,rds}`,
and `figures/<resolution>/*.png`. Run the pair once per resolution you
extracted (`run_experiment.sh` does this automatically for every value in
`--output_freq`); each resolution's output and figures live in their own
files/subfolder, so running them for `monthly` and `daily` back to back is
safe and non-destructive to each other's output.

### 6.5 Example: baseline vs. plant hydraulics (at BCI)

| Experiment | `PLANT_HYDRO_SCHEME` | Window | Result |
| --- | --- | --- | --- |
| baseline | 0 (static) | 2003-01 to 2003-03 | `WfluxGW`/`WfluxWL` (internal soil→wood/wood→leaf water flux) are **exactly 0** every month — no internal water transport is tracked, as expected. |
| plant_hydro | 1 (Christoffersen et al. 2016) | 2003-01 to 2003-03 | `WfluxGW`/`WfluxWL` become non-zero (~3.3e-5 kg/m²/s), and `WoodWater` jumps from ~4 kg/m² to ~38-41 kg/m² (a real, dynamically-tracked sapwood water pool instead of the static nominal value). GPP/NPP shift only slightly (~1-8%) over this short, wet-season window with no water stress — a longer run spanning BCI's dry season would be the real test of whether the scheme matters for carbon fluxes here. |

`Rscript R-tools/compare_experiments.R --site=BCI --exp=<baseline_id>,<plant_hydro_id>`
(§5.3) is the fastest way to see this: the plant-hydraulics panel shows a
flat-zero line vs. a clearly non-zero one for `WfluxGW`/`WfluxWL`.

## 7. What each script does

**Cross-site tools** (repo root `R-tools/` — site-agnostic, take `--site` where
they need to locate a site's output):

| Script | Reads | Writes | Notes |
| --- | --- | --- | --- |
| `run_experiment.sh` | — | (chains everything below) | Full pipeline orchestrator for any site (§4). |
| `R-tools/registry_utils.R` | `experiments_registry.csv` | (sourced helper) | `registry_add()`/`registry_update_status()`/`registry_read()`. Not run directly — sourced by each site's ED2IN-builder script, `update_registry_status.R`, `list_experiments.R`. |
| `R-tools/update_registry_status.R` | — | `experiments_registry.csv` | Tiny CLI wrapper around `registry_update_status()` so `run_experiment.sh` can update status without embedding R in the shell script. Doesn't need `--site` (exp_id is globally unique). |
| `R-tools/describe_variables.R` | `sites/<site>/run/experiments/<exp_id>/analysis-E-*.h5` | `variable_catalog.csv` | Variable/dimension/units catalog — see §5.2. Shape-based classification is site-agnostic; the curated descriptions document BCI's own extraction as a worked example. |
| `R-tools/list_experiments.R` | `experiments_registry.csv` | console output only | List/filter every experiment ever built, across all sites — see §5.1. |
| `R-tools/compare_experiments.R` | multiple experiments' `timeseries_output_<resolution>.rds` (same site, same resolution) | `sites/<site>/run/comparisons/<name>/*.png` | Overlay multiple experiments on shared axes — see §5.3. |

**BCI's site-specific scripts** (`sites/BCI/R/` — a new site mirrors this
structure and naming convention; see §11):

| Script | Reads | Writes | Notes |
| --- | --- | --- | --- |
| `data_preparation/evaluate_bci_data.R` | `sites/BCI/raw_data/` | console output only | Optional QC pass over the raw met/census/soil files before building anything. |
| `data_preparation/build_bci_datasets.R` | `sites/BCI/raw_data/`, `R-utils/`, `ED2_Support_Files-master/` | `sites/BCI/run/met/*.h5` + `ED_MET_DRIVER_HEADER`, `sites/BCI/run/init/*.pss`/`*.css` | Builds the met driver (shortwave partition via `rshort.bdown()`, solar geometry via `ed.zen()`, longwave via Longo's `"aml"` scheme), soil texture (`SLXSAND`/`SLXCLAY`, printed to console for `build_bci_ed2in.R` to use), and the vegetation initial condition (real ForestGEO census → one cohort per stem, PFT assigned by wood-density breakpoints — **this is the census-to-PFT classification step, not ED2's internal PFT parameter table**, see §9). Experiment-independent — run once, shared by every experiment at this site. |
| `data_preparation/lib_load_utils.R` | — | — | Sourced helper (not run directly): loads the specific `R-utils/`/`ED2_Support_Files-master/` functions `build_bci_datasets.R` needs, without pulling in the lab's full plotting/mapping environment. |
| `model_runs/build_bci_ed2in.R` | `ED/run/ED2IN` (template); `--restart_from`'s `history-S-*.h5` if given | `sites/BCI/run/ED2IN-<exp_id>`; a row in `experiments_registry.csv` | Builds one experiment's namelist — see §4's flag table, §12 (restart), §13 (output resolution). Auto-names the experiment `<name>_<timestamp>` unless `--exp` pins an exact id. Fixes two confirmed `PEcAn.ED2` bugs: `read_ed2in()` truncating multi-line array parameters (`SLZ`/`SLMSTR`/`STGOFF`), and `modify_ed2in()`'s path-mangling convenience arguments (`met_driver`/`output_dir`) baking in absolute host paths that break once bind-mounted into the container. |
| `output_preparation/extract_bci_output.R` | `sites/BCI/run/experiments/<exp_id>/analysis-{E,D,I}-*.h5` (per `--resolution`) | `timeseries_output_<resolution>.{csv,rds}`, `sizeclass_output_<resolution>.{csv,rds}` | Both ecosystem-scale (polygon-level) scalars (carbon fluxes, PFT-summed stocks, plant hydraulics, energy balance, radiation forcing) and full PFT x DBH-size-class resolution (`AGB_PY`, `LAI_PY`/`MMEAN_LAI_PY`, `NPLANT_PY`, `Bstorage`/`MMEAN_BSTORAGE_PY`, `BASAL_AREA_PY`, plus cohort-level GPP/NPP aggregated into ED2's own 11 size-class bins — confirmed against `update_derived_utils.f90`: `idbh = max(1, min(11, ceiling(dbh * 0.1)))`), at whichever of `monthly`/`daily`/`hourly` is requested (§13 — cohort-level GPP/NPP are monthly-only, a real ED2 output limitation, not a script limitation). Reads HDF5 directly (`PEcAn.ED2::model2netcdf.ED2()` is broken by a `dplyr` version incompatibility in its per-cohort reshaping — not used). Output filenames (`timeseries_output_<resolution>.rds`, not `bci_timeseries_output_...`) are the site-agnostic convention `R-tools/compare_experiments.R` relies on. |
| `output_preparation/plot_bci_output.R` | `timeseries_output_<resolution>.rds`, `sizeclass_output_<resolution>.rds` | `figures/<resolution>/{flux,stock,water,energy,forcing,sizeclass}_*.png` | Time-series plots at whichever `--resolution` was extracted; any PFT or size-class breakdown is a date x PFT (or size-class x PFT) heatmap matrix, never a stacked bar/area (stacking hides each PFT's own magnitude behind the others). Size-class GPP/NPP plots only appear at `--resolution=monthly` (§13). |
| `input_visualization/plot_met_input.R` | `sites/BCI/run/met/*.h5` | `sites/BCI/run/diagnostics/met/*.png` + joined CSV/RDS | QC/visualize the met **input** itself (temperature, radiation, precipitation, wind, humidity, pressure), independent of any experiment or model run — met is shared, so there's exactly one met input to look at. |
| `input_visualization/plot_init_input.R` | `sites/BCI/run/init/*.pss`/`*.css` | `sites/BCI/run/diagnostics/init/*.png` + CSV | QC/visualize the vegetation **input** itself (DBH distribution, height-DBH allometry, biomass/density by PFT and size class), independent of any experiment. |

## 8. How the climate years work (recycling, running outside 2003-2016)

BCI's met driver covers 2003-2016 (`METCYC1`/`METCYCF` in its `ED2IN`,
site-specific — another site's own data range would differ). Your
simulation window (`--start_date`/`--end_date` in §4) is **completely
independent** of that range — ED2 handles anything outside it automatically
via a documented recycling mechanism that's part of ED2 itself, not
specific to any site (confirmed directly in
`ED/src/driver/ed_met_driver.f90:531-544`, not assumed):

```fortran
ncyc = metcycf - metcyc1 + 1        ! = 14 for BCI (any site: its own metcycf - metcyc1 + 1)
do while (year_cyc > metcycf)
   year_cyc = year_cyc - ncyc       ! simulated year past the data range -> wraps back into range
end do
do while (year_cyc < metcyc1)
   year_cyc = year_cyc + ncyc       ! simulated year before the data range -> wraps forward into range
end do
```

- **Running past the met data's last year**: works with no config changes.
  At BCI, simulated year 2017 transparently uses 2003's real met data, 2018
  uses 2004's, etc. — a deterministic, sequential replay of the same
  14-year block, repeating indefinitely.
- **Running before the met data's first year**: same mechanism in reverse —
  e.g. simulated year 1990 at BCI uses 2004's real data (1990 + 14 = 2004).
- **`NL%ISHUFFLE`** (currently `0` in every BCI `ED2IN`) controls the
  order years are picked once outside the range: `0` = sequential repeat
  (current setting, fully deterministic), `1` = randomly shuffled but same
  order every run, `2` = randomly shuffled, different order every run (not
  reproducible without seeding).

**What this means in practice**: it's a literal replay of the same real
years, not synthesized new climate — no long-term trend, no years beyond
what's actually in the source record. This is exactly what you want for a
multi-century **spin-up** to equilibrium (a standard ED2 use case — e.g. run
200+ years before your real comparison period to let biomass/soil carbon
reach steady state), but the borrowed met year and the simulated calendar
year diverge once you're outside the real data range, so don't treat a
simulated "2020" as reflecting actual 2020 conditions unless it happens to
fall on a real data year. To extend a run, just pass a later `--end_date` to
`run_experiment.sh`/that site's ED2IN-builder script (§4) — no other change
needed; `METCYC1`/`METCYCF` stay fixed regardless of the simulation window.

## 9. Changing PFT parameters (wood density, SLA, Vm0, and other traits)

There are **two entirely different "PFT" things** in this pipeline — don't
confuse them:

1. **Census-to-PFT classification** (`build_bci_datasets.R`, or the
   equivalent script at another site): assigns each real census stem to
   PFT 2, 3, or 4 by comparing its species' wood density (`wsg`, joined
   from `bci.spptable` at BCI) against two breakpoints (0.62, 0.805 g/cm³
   — the midpoints between adjacent PFTs' reference densities). This only
   decides *which existing PFT a stem becomes*; it does not change what
   PFT 2/3/4 physiologically *are*.
2. **ED2's internal per-PFT parameter table** (wood density, SLA, `Vm0`,
   max height, mortality rates, hydraulic traits, ...): hardcoded defaults
   in the compiled `ed2` binary (`ED/src/init/ed_params.f90`), the same for
   every site and every user unless overridden. **This is what you'd
   change to test, e.g., "what if PFT 3's wood density were higher" —
   and it applies identically regardless of which site you're running.**

### 9.1 Overriding PFT parameters via the XML config file

ED2 has a documented, no-recompile override mechanism for exactly this,
usable at any site: a per-run XML config file, read by
`ED/src/io/ed_xml_config.f90` (confirmed directly in that source, not
PEcAn's separate `write.config.xml.ED2()`). Every `ED2IN` already has the
hook, unset by default:

```text
NL%IEDCNFGF = '/mypath/config.xml'
```

(This is why every run log prints a harmless `WARNING! ... config.xml
wasn't found. Using default parameters in ED2.` when no override is
requested — no file exists there, so ED2 just uses its compiled-in
defaults.)

`sites/BCI/pft_configs/` holds BCI's own reusable override files (another
site would have its own `sites/<site>/pft_configs/`). One example is
already there — `high_rho_pft3.xml`, raising PFT 3's (mid-successional
tropical) wood density from ED2's default 0.71 g/cm³ to 0.80 g/cm³:

```xml
<config>
  <pft>
    <num>3</num>
    <rho>0.80</rho>
  </pft>
</config>
```

Use it (or any file of your own in the same format) directly with §4's
`--pft_config` flag:

```sh
./run_experiment.sh --site=BCI --name=high_rho_pft3 --pft_config=sites/BCI/pft_configs/high_rho_pft3.xml
```

The ED2IN-builder script copies the file into
`sites/BCI/run/pft_config-<exp_id>.xml` (inside the mounted run directory,
since ED2 only sees that site's `run/`'s contents) and points `IEDCNFGF` at
it. ED2 recomputes every parameter derived from an override
(height/biomass allometry, `wood_Kmax`/`wood_psi50` under
`PLANT_HYDRO_SCHEME`, ...) immediately after applying the XML — the
`"Init_derived_params_after_xml"` line visible in every run log — so one
override like `rho` propagates correctly through that PFT's whole
allometry, not just a raw density number. None of this is BCI-specific:
the same XML file format and mechanism work at any site.

Write your own XML with only the tags you want to change (one `<pft>`
block per PFT number; anything omitted keeps ED2's default).
Confirmed-available tag names (non-exhaustive; grep
`ED/src/io/ed_xml_config.f90` for `getConfigREAL(...,'pft',...)` in the
image's build stage for the complete list — same command style as §2.1's
extraction, swap `podman cp` for `podman run --rm --entrypoint grep
<image> -n "getConfigREAL.*'pft'" /ED2/ED/src/io/ed_xml_config.f90`):

| Tag | Meaning |
| --- | --- |
| `rho` | Wood density (g/cm³) — drives `wood_Kmax`/`wood_psi50`/allometry, same quantity as the census `wsg` in §9's item 1, but here it's ED2's *parameter*, not a per-stem measurement. |
| `SLA`, `sla_s0`, `sla_s1` | Specific leaf area and its size-dependence. |
| `Vm0`, `vm0_v0`, `vm0_v1` | Photosynthetic capacity and its variants. |
| `hgt_min`, `hgt_max`, `hgt_ref` | Height allometry bounds. |
| `leaf_turnover_rate`, `growth_resp_factor`, `storage_turnover_rate` | Carbon allocation/turnover. |
| `mort0`-`mort3`, `frost_mort`, `hydro_mort0`, `hydro_mort1`, `seedling_mortality` | Mortality parameters (`hydro_mort*` only matter when `PLANT_HYDRO_SCHEME > 0`). |
| `wood_water_cap`, `wood_rwc_min`, `wood_psi_min`, `wood_psi_tlp`, `wood_elastic_mod`, `wood_Kmax`, `wood_Kexp`, `wood_psi50` | Plant-hydraulics-specific traits (only exercised when `PLANT_HYDRO_SCHEME > 0`). |
| `sapwood_ratio`, `init_density`, `f_bstorage_init` | Initial-condition-related traits. |

`PEcAn.ED2::write.config.xml.ED2()` also exists and can generate this same
XML format, but it expects a full PEcAn `settings`/`trait.values` object
from PEcAn's trait-database/meta-analysis workflow — not set up in this
standalone repo, so hand-writing the XML directly (as above) is the simpler
path here.

## 10. Caveats when interpreting results

- Downward longwave radiation was never measured at the BCI tower; it's
  estimated (Longo's `"aml"` scheme, uncalibrated coefficients) — expect
  more uncertainty in radiation-driven fluxes than a fully-measured-forcing
  run. (Site-specific to BCI's data — a site with measured longwave
  wouldn't need this.)
- Soil carbon pool initial values (`fsc`/`stsc`/`stsl`/`ssc`/`msn`/`fsn`)
  are illustrative defaults at BCI, not site-specific measurements.
- `build_bci_datasets.R`/`build_bci_ed2in.R` already work around two known
  ED2 quirks that apply at any site (a `filelist_c_` alphabetical-ordering
  bug that needs decoy placeholder files in `init/`, and a required
  decimal point in the longitude filename tag) — no action needed, just
  don't "clean up" the placeholder files in `sites/BCI/run/init/` if you
  see them.
- Met-year recycling (§8) means any run extending outside a site's real
  data range is replaying real years out of their original calendar order
  — check which real year actually backed a given simulated year before
  attributing results to "conditions in year X."

## 11. Adding a new site

A new site needs its own `sites/<Site>/` folder mirroring BCI's structure
and script-naming convention (§3, §7), so the cross-site tools
(`run_experiment.sh`, `R-tools/describe_variables.R`, `R-tools/compare_experiments.R`)
can find it automatically:

1. `sites/<Site>/raw_data/` — that site's raw met/soil/vegetation data.
2. `sites/<Site>/R/data_preparation/build_<sitelower>_datasets.R` — builds
   `sites/<Site>/run/{met,init}` from the raw data, following
   `build_bci_datasets.R`'s pattern (met driver: shortwave partition,
   solar geometry, longwave estimate if not measured; vegetation init:
   census → cohorts with a PFT assignment rule appropriate for that site's
   species).
3. `sites/<Site>/R/model_runs/build_<sitelower>_ed2in.R` — builds that
   site's `ED2IN`, following `build_bci_ed2in.R`'s pattern: same
   `--name`/`--exp`/`--plant_hydro_scheme`/`--start_date`/`--end_date`/
   `--pft_config` flags (§4), same `EXP_ID:<value>` first-line-of-output
   convention, same `registry_add(repo_root, exp_id, site = "<Site>", ...)`
   call at the end (sourcing `R-tools/registry_utils.R` from the repo root, not
   a site-local copy) — but with that site's own coordinates, soil
   texture, PFT set, and met/init paths.
4. `sites/<Site>/R/output_preparation/{extract,plot}_<sitelower>_output.R` —
   following the BCI pair's pattern (both take `--exp` and `--resolution`),
   **writing to `timeseries_output_<resolution>.{csv,rds}` and
   `sizeclass_output_<resolution>.{csv,rds}` exactly** (not
   `<sitelower>_timeseries_output...`) so `R-tools/compare_experiments.R` and
   `run_experiment.sh` can find them without needing to know anything
   site-specific about column names or PFT numbering.
5. (Optional) `sites/<Site>/R/input_visualization/` for input QC plots, and
   `sites/<Site>/pft_configs/` for that site's own PFT-override XML files.

Once in place: `./run_experiment.sh --site=<Site> --name=baseline` works
exactly as it does for BCI, and every cross-site tool in §5/§7 works
against it with no further changes.

## 12. Restarting from an earlier experiment

Once a run has reached equilibrium (or you just want to keep going in time
without redoing years already simulated), continue it as a new experiment
instead of re-running `INITIAL` from the census each time:

```sh
./run_experiment.sh --site=BCI --name=continued --restart_from=baseline_20260716_110606 --end_date=2004-12-31
```

This is ED2's own `RUNTYPE=HISTORY` mechanism (`ED/src/init/ed_init_history.f90`)
— it reloads the **full internal model state** (every cohort/patch/soil
layer's carbon, water, and structural pools, not just biomass) from an
earlier experiment's `history-S-*.h5` restart file, so the new run
genuinely continues rather than approximating a restart from a summary.

- `--restart_from=<exp_id>` points at the earlier experiment; `build_bci_ed2in.R`
  looks in `sites/BCI/run/experiments/<exp_id>/` for its `history-S-*.h5`
  snapshots and picks the most recent one by default.
- `--restart_date=YYYY-MM-DD` picks a specific earlier snapshot instead of
  the latest, if that experiment wrote more than one (e.g. `IOUTPUT`/`ISOUTPUT`
  frequency was more than once).
- The new experiment's simulation **starts at the restart snapshot's own
  timestamp**, not at `--start_date` (any `--start_date` you pass is
  ignored for a restart) — only `--end_date` controls how much further it
  runs.
- `SFILIN` in the new `ED2IN` is pointed at the source experiment's own
  `history` prefix, so the new experiment reads the old one's output
  directory directly; the old experiment's files are not copied or
  modified.

**Important limitation, confirmed by testing**: `PLANT_HYDRO_SCHEME` cannot
be changed across a restart. A static-hydraulics (`0`) run's history file
has `wood_psi = 0` baked into its saved state; restarting it with
`--plant_hydro_scheme=1` (or vice versa) crashes with a `FATAL` "Plant
Hydrodynamics is off-track" error in `plant_hydro.f90`, because the
dynamic scheme's internal sanity checks reject the static scheme's
placeholder value. Restart into the **same** `PLANT_HYDRO_SCHEME` the
source experiment used — if you need to compare hydraulics schemes, start
each from the same `INITIAL` spin-up point rather than restarting one
into the other. Similarly, only restart into a scenario you actually
intend as a continuation (e.g. a `--pft_config` change *is* fine to apply
at a restart — the XML override is reapplied at `INITIAL`/`HISTORY`
startup either way).

## 13. Output resolution: monthly, daily, hourly

`--output_freq` (§4) controls which of ED2's built-in output resolutions
get written and extracted; pass a comma-separated list to get more than
one from the same run:

```sh
./run_experiment.sh --site=BCI --name=hires --output_freq=monthly,daily,hourly
```

This maps directly onto `ED2IN`'s own `NL%IMOUTPUT`/`NL%IDOUTPUT`/`NL%IFOUTPUT`
(lines 649-688 of the stock `ED2IN` template) — `build_bci_ed2in.R` turns
each requested resolution on (`= 3`) and leaves the others off (`= 0`), and
sets `NL%OUTFAST`/`NL%UNITFAST`/`NL%FRQFAST` for hourly (`FRQFAST=3600`,
packed via `OUTFAST=-1` per ED2's own convention for sub-daily output).
Each resolution writes its own HDF5 file series into the experiment's
folder: `analysis-E-*.h5` (monthly), `analysis-D-*.h5` (daily),
`analysis-I-*.h5` (hourly/instantaneous) — confirmed via
`ED/src/io/h5_output.F90`'s `vnam` naming convention, not assumed.

**A resolution only has output once a full period of that length has
completed** — e.g. `monthly` output needs the run to actually cross a
month boundary; a `--start_date`/`--end_date` window shorter than one
month will produce daily/hourly files but zero monthly ones. `run_experiment.sh`
extracts/plots each requested resolution independently and only warns
(does not abort the whole pipeline) if one resolution has no data yet —
confirmed by testing a run shorter than a month.

Each output resolution uses a different variable-name prefix inside the
HDF5 files — `MMEAN_`/`DMEAN_`/`FMEAN_` for monthly/daily/hourly time-means
respectively (e.g. `MMEAN_GPP_PY`, `DMEAN_GPP_PY`, `FMEAN_GPP_PY`) — and
**not every variable exists at every resolution**: confirmed by direct
HDF5 inspection, ED2 does not write an `FMEAN_BSTORAGE_PY` or
`FMEAN_GPP_CO`/`DMEAN_GPP_CO` (per-cohort GPP/NPP are monthly-only).
`extract_bci_output.R` (§6.4, §7) picks the right prefix automatically
from `--resolution` and falls back gracefully (empty/zero columns) where a
variable genuinely isn't written at that resolution — this is a real ED2
output limitation, not a script gap. Timestamps in the extracted
`timeseries_output_<resolution>.rds`/`sizeclass_output_<resolution>.rds`
(column `datetime`) match each HDF5 file's actual reporting instant —
confirmed for hourly output by matching the diurnal shortwave-radiation
and GPP cycle against local time.

Run the same experiment's extraction/plotting again at a different
`--resolution` any time after the fact (§6.4) — it's independent of the
`ED2IN`'s `--output_freq` used to build the run, as long as that
resolution's HDF5 files actually exist for it.
