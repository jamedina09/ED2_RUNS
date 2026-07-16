# Running ED2 for Single-Point Sites

A framework for building, running, tracking, and exploring single-point
[ED2](https://github.com/EDmodel/ED2) (Ecosystem Demography Model, version
2.2) experiments at any site. It wraps a containerized ED2 build with the
data-preparation, execution, extraction, plotting, and bookkeeping scripts
needed to go from raw site data to comparable, reproducible experiment
output — without requiring you to compile ED2 yourself or hand-edit its
namelist from scratch.

**BCI (Barro Colorado Island, Panama) is the worked example shipped with
this repo** (`sites/BCI/`), driven by real site data: a ForestGEO 50-ha
permanent plot census and QA/QC'd ESS-DIVE tower meteorology. Every
example command below uses BCI, but nothing in the framework is
BCI-specific — see [§9](#9-adding-a-new-site) for adding another site
alongside it.

## Key Terms

A few terms recur throughout this document; if you're new to ED2 or this
repository, read this table first.

| Term | Meaning |
| --- | --- |
| **Site** | A physical location this repo is configured to simulate (e.g. BCI). Each site has its own folder under `sites/`, its own raw data, and its own met driver and vegetation initial condition — but shares the same container image, orchestration scripts, and tooling as every other site. |
| **Experiment** | One configured run of ED2 at a site — a specific combination of start/end dates, physiological switches, and optional parameter overrides. Every experiment gets a unique `exp_id` and its own output folder, so you can run the same site many different ways without overwriting previous results. |
| **`exp_id`** | The unique identifier for one experiment, e.g. `baseline_20260716_110606` (your `--name` plus an automatic timestamp). Used everywhere — as a folder name, a `--exp=` flag value, and a row key in the experiment registry. |
| **Namelist / `ED2IN`** | ED2's plain-text configuration file format. Every experiment gets its own `ED2IN-<exp_id>` file, built by overriding a stock template — you never need to write one from scratch. |
| **PFT (Plant Functional Type)** | One of ED2's built-in vegetation categories (e.g. "tropical broadleaf, early successional"). ED2 ships with a fixed set of 17 PFTs; simulations choose a subset of these and can override their trait parameters — see [§7](#7-pft-configuration). |
| **Cohort / Patch / Polygon** | ED2's internal spatial hierarchy, largest to smallest: a **polygon** is the whole simulated area (one per site here); a polygon contains one or more **patches** (areas of similar disturbance history); a patch contains **cohorts** (groups of trees of the same PFT and similar size, ED2's basic unit of vegetation dynamics). Output variable names ending in `_PY`, `_SI`, `_PA`, or `_CO` refer to polygon-, site-, patch-, or cohort-level quantities respectively. |
| **`RUNTYPE` (`INITIAL` vs. `HISTORY`)** | Whether a run starts fresh from a vegetation census (`INITIAL`) or continues from an earlier experiment's saved internal state (`HISTORY`, a **restart** — see [§4.6](#46-restarting-or-continuing-a-run)). |
| **Resolution (`monthly`/`daily`/`hourly`)** | How often ED2 writes output to disk during a run. All three can be enabled simultaneously; see [§6.3](#63-output-resolution-monthly-daily-hourly). |

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Requirements and Installation](#2-requirements-and-installation)
3. [Repository Structure](#3-repository-structure)
4. [Manual Workflow (Step by Step)](#4-manual-workflow-step-by-step)
5. [Automated Workflow: `run_experiment.sh`](#5-automated-workflow-run_experimentsh)
6. [Configuration Reference](#6-configuration-reference)
7. [PFT Configuration](#7-pft-configuration)
8. [Output Files and Results](#8-output-files-and-results)
9. [Adding a New Site](#9-adding-a-new-site)
10. [Troubleshooting and Caveats](#10-troubleshooting-and-caveats)
11. [TL;DR / Quick Reference](#11-tldr--quick-reference)

---

## 1. Project Overview

This repository answers a specific problem: running ED2 for a single
point on the map is easy to get *wrong* in ways that are hard to notice —
a namelist typo, a mismatched restart timestamp, a plot built from a
stale extraction — and hard to *compare*, since ED2 gives you raw HDF5
files with cryptic variable names and no built-in experiment tracking.
This framework addresses both problems:

- **Correctness**: every step (building the namelist, running the model,
  extracting output, restarting from a previous run) is scripted and
  validated, so the same mistakes don't have to be rediscovered each time.
- **Comparability**: every experiment gets a unique, timestamped id, a
  row in a persistent registry, and output in a predictable location and
  format, so two experiments (e.g. "static vs. dynamic plant hydraulics")
  can be overlaid on one plot with a single command.

**Division of responsibility**:

- The **container image** (built from a separate repo,
  `/Users/medinaja/ed2-personal-container`, your ED2 fork) provides the
  compiled `ed2` binary. You do not need a Fortran toolchain or an ED2
  source checkout on your host machine to run experiments — only to
  rebuild the image itself, and only occasionally.
- **This repository** provides everything else: site data, the scripts
  that turn that data into ED2's expected input formats, the scripts that
  build each experiment's namelist, the orchestration that runs the model
  and manages output, and the tools that extract, plot, catalog, and
  compare results.

**What this repo does *not* do**: it does not modify ED2's source code or
compiled behavior. Every customization available to you (PFT parameter
overrides, output resolution, simulation window, restart chaining) uses
ED2's own existing, documented mechanisms — namelist variables and its
XML configuration override system. If you need to change something ED2
itself does not expose as a runtime option (e.g. add a genuinely new
18th PFT, see [§7.5](#75-what-you-cannot-do-without-recompiling-ed2)),
that requires modifying and recompiling ED2 itself, which is out of scope
here.

---

## 2. Requirements and Installation

### 2.1 Software Prerequisites

- **[podman](https://podman.io/)**, a container engine (Docker-compatible
  CLI). On macOS/Windows, start its VM once per session:

  ```sh
  podman machine start
  ```

- **R**, with the following packages installed on the host. Note that only
  the compiled `ed2` model itself runs inside the container — every
  data-preparation, output-extraction, and plotting script in this
  repository runs directly on your host machine, so these packages must
  be available there:

  ```r
  install.packages(c("ncdf4", "hdf5r", "data.table", "chron", "ggplot2"))
  ```

  > **You do *not* need to install the `PEcAn.ED2` package.** ED2IN
  > namelist reading/writing (`read_ed2in()`/`modify_ed2in()`/
  > `write_ed2in()`) is provided by `R-tools/ed2in_io.R`, a small,
  > dependency-free file vendored into this repo directly from
  > `PEcAn.ED2` — installing the full [PEcAn](https://github.com/PecanProject/pecan)
  > project just for these three functions would pull in a much larger
  > dependency chain (`PEcAn.logger`, `PEcAn.utils`, `lubridate`, `dplyr`,
  > ...) than this repo actually needs. See `R-tools/ed2in_io.R`'s header
  > comment for full attribution, the exact upstream version ported, and
  > its license (PEcAn.ED2 is UIUC/NCSA-licensed, which permits this as
  > long as the license notice is retained — it is, in that file). Two
  > known bugs inherited from upstream (both already worked around by
  > this repo's ED2IN-builder scripts) are documented in
  > [§10](#10-troubleshooting-and-caveats) and in that file's header.

### 2.2 Building the ED2 Container Image

The `ed2:personal` image must exist before you can run any experiment.
Check whether it already does:

```sh
podman images ed2:personal
```

If not, build it from the container repo (a separate repository from this
one):

```sh
cd /Users/medinaja/ed2-personal-container
podman build -t ed2:personal -f docker/Dockerfile.personal .
```

This step compiles ED2 from source inside the container — it does not
require a Fortran compiler on your host. It also bakes in
`common/ed_inputs/` (chill-day/degree-day climatology and other generic
ED2 startup data that is not site-specific) at
`/opt/ed2_common/ed_inputs/` inside the image, so no per-site copy of
that data is needed (see the `THSUMS_DATABASE` row in
[§8.2](#82-script-reference-tables)).

This image, and everything else in this section, is **shared across every
site** — you build it once regardless of how many sites you add later.

> **Note:** Rebuilding the image is only necessary the first time, or if
> you intentionally update `ED2_GIT_REF` in the container repo to build a
> different version of ED2. Routine experiment work never touches this
> step.

### 2.3 Extracting Shared ED2 Assets

Two things live inside the ED2 source tree that are not distributed
separately from the compiled binary, and that this repo's R scripts need
directly:

- **`R-utils/`** — the ED2 development lab's own physics and allometry
  helper functions (shortwave radiation partitioning, solar geometry,
  height/biomass allometric equations, ...), used by each site's
  data-preparation script.
- **`ED/run/ED2IN`** — the stock ED2IN namelist template. Every
  experiment's namelist is built by taking this template and overriding
  only the fields that vary (coordinates, dates, output settings, ...),
  never by writing one from scratch.

Pull both out of the image's intermediate **build stage** (the same
Dockerfile, `build` target, before the final minimal-runtime stage strips
away everything except the compiled binary):

```sh
cd /Users/medinaja/ed2-personal-container
podman build -t ed2:build --target build -f docker/Dockerfile.personal .
podman create --name ed2-extract ed2:build
podman cp ed2-extract:/ED2/R-utils "$HOME/ED2_RUNS/R-utils"
mkdir -p "$HOME/ED2_RUNS/ED/run"
podman cp ed2-extract:/ED2/ED/run/ED2IN "$HOME/ED2_RUNS/ED/run/ED2IN"
podman rm ed2-extract
```

`R-utils/` and `ED/run/ED2IN` land at this repo's root, shared by every
site — you only redo this if you rebuild `ed2:build` from a different
`ED2_GIT_REF`.

> **Tip:** This same "build the intermediate stage, then `podman cp` a
> path out of it" pattern is also how you can inspect ED2's Fortran
> source directly for any question this README doesn't answer — e.g. to
> see the full list of XML-configurable PFT parameters yourself
> ([§7.3](#73-full-list-of-overridable-pft-parameters)), without ever
> checking out the ED2 source tree on your host.

### 2.4 Site Raw Data

`sites/BCI/raw_data/` should contain (already provided with this example
site):

| Folder | Contents | Used for |
| --- | --- | --- |
| `bci_climate/` | Official QA/QC'd BCI tower meteorology, hourly, 2003-2016 (Faybishenko, Knox, Chambers et al., LBNL/STRI, ESS-DIVE) | Building the met driver |
| `bci_stem_data/` | ForestGEO 50-ha plot census #8 (`bci.stem8.rdata`) and a species table with wood density (`bci.spptable.rdata`) | Building the vegetation initial condition |
| `bci_forcing_data/` | CLM5/ELM `surfdata_bci_*.nc` | Soil sand/clay texture fractions only |

`ED2_Support_Files-master/` (the ED2 development lab's own
site-processing driver scripts — `tower_processing/`,
`pss+css_processing/`, `soil_data_processing/`) should also be present at
this repo's root, alongside `R-utils/`: BCI's data-preparation script
sources functions from both.

---

## 3. Repository Structure

```text
ED2_RUNS/
├── run_ed2.sh                     # thin wrapper: podman run against a run dir + ED2IN name (any site)
├── run_experiment.sh              # orchestrator: build -> run -> extract -> plot -> catalog -> registry (§5)
├── experiments_registry.csv       # every experiment ever built, at any site: id, site, config, status (§8.3)
├── .ed2_repo_root                 # empty marker file; every script walks up from its own
│                                   # path looking for this (not .git) to find the repo root portably
├── R-utils/                       # ED2 lab physics/allometry functions, shared by every site (§2.3)
├── ED/run/ED2IN                   # stock ED2IN namelist template, shared by every site (§2.3)
├── ED2_Support_Files-master/      # site-processing driver scripts, shared by every site (§2.4)
├── R-tools/                       # cross-site, site-agnostic tools (§8) - distinct from each
│   │                               #   site's own R/ below, and from R-utils/ above
│   ├── registry_utils.R              # sourced helper: read/add/update experiments_registry.csv
│   ├── ed2in_io.R                     # sourced helper: read/modify/write ED2IN (vendored from PEcAn.ED2, §2.1)
│   ├── update_registry_status.R      # CLI wrapper used by run_experiment.sh
│   ├── describe_variables.R          # variable/dimension/units catalog, works at any site
│   ├── list_experiments.R            # query the registry across all sites
│   └── compare_experiments.R         # overlay multiple experiments (same site) on shared axes
└── sites/
    └── BCI/                        # one folder per site - BCI is the example site (§9 to add another)
        ├── raw_data/                  # real source data (§2.4)
        ├── pft_configs/                # your own XML PFT-parameter override files (§7)
        │   └── high_rho_pft3.xml         # example: PFT 3 wood density raised to 0.80 g/cm3
        ├── run/                        # generated - safe to delete and rebuild (§4.1)
        │   ├── met/                       # shared met driver (every experiment at this site uses the same met)
        │   ├── init/                      # shared vegetation init (every experiment uses the same census)
        │   ├── diagnostics/{met,init}/    # input QC plots (input_visualization/, independent of any experiment)
        │   ├── comparisons/<name>/        # compare_experiments.R output (§8.3)
        │   ├── ED2IN-<exp_id>             # one namelist per experiment
        │   ├── pft_config-<exp_id>.xml    # copied in only if --pft_config was used (§7)
        │   └── experiments/
        │       └── <exp_id>/                 # e.g. baseline_20260716_110606
        │           ├── analysis-{E,D,I}-*.h5, history-S-*.h5, history.xml, run.log
        │           │                          # E=monthly, D=daily, I=hourly (§6.3); history-S-* is
        │           │                          #   what --restart_from (§4.6) reads
        │           ├── timeseries_output_<resolution>.{csv,rds}  # ecosystem-scale (§8.1)
        │           ├── sizeclass_output_<resolution>.{csv,rds}   # PFT x DBH-size-class (§8.1)
        │           ├── variable_catalog.csv   # describe_variables.R (§8.2)
        │           └── figures/<resolution>/*.png  # one subfolder per --resolution
        └── R/                           # BCI's own site-specific scripts (§9: a new site mirrors this)
            ├── data_preparation/
            │   ├── evaluate_bci_data.R    # optional: sanity-check raw data
            │   ├── build_bci_datasets.R   # met + soil + vegetation init -> sites/BCI/run/{met,init}
            │   └── lib_load_utils.R       # sourced helper, not run directly
            ├── model_runs/
            │   └── build_bci_ed2in.R      # ED2IN namelist -> sites/BCI/run/ED2IN-<exp_id>; registers in the registry
            ├── output_preparation/
            │   ├── extract_bci_output.R   # ecosystem-scale + size-class output at any --resolution
            │   └── plot_bci_output.R      # all plots, at any --resolution
            └── input_visualization/
                ├── plot_met_input.R    # QC/visualize the met driver itself (independent of any run)
                └── plot_init_input.R   # QC/visualize the vegetation census itself (independent of any run)
```

**Naming convention** (this is what lets `run_experiment.sh --site=<site>`
find a site's scripts automatically, without a lookup table): a site
called `<Site>` must provide
`sites/<Site>/R/model_runs/build_<sitelower>_ed2in.R` and
`sites/<Site>/R/output_preparation/{extract,plot}_<sitelower>_output.R`,
where `<sitelower>` is `<Site>` lowercased. See [§9](#9-adding-a-new-site)
for the complete convention.

> **Two similarly-named directories, one distinction to keep straight:**
> `R-tools/` (repo root) holds *cross-site* tools that take a `--site=`
> flag and work against any site's output. `sites/BCI/R/` (nested inside
> the site folder) holds *BCI-specific* scripts that already know they're
> for BCI and don't take `--site`. If a script's usage line takes
> `--site=`, it's a cross-site tool from `R-tools/`; if not, it's a
> site-specific script from that site's own `R/`.

---

## 4. Manual Workflow (Step by Step)

Every ED2 experiment, regardless of whether you drive it manually or via
[`run_experiment.sh`](#5-automated-workflow-run_experimentsh), goes
through the same five stages:

```text
 (once per site)                      (once per experiment)
┌───────────────────┐   ┌──────────┐   ┌─────────┐   ┌───────────┐   ┌──────────┐
│ 1. Build shared    │→│ 2. Build   │→│ 3. Run  │→│ 4. Extract  │→│ 5. Plot +  │
│    met + init      │  │   ED2IN    │  │   ED2   │  │   output    │  │  catalog   │
└───────────────────┘   └──────────┘   └─────────┘   └───────────┘   └──────────┘
```

This section walks through each stage manually — running the underlying
R script or `podman`/`ED2` command directly, rather than through the
orchestrator. **Read this section even if you plan to always use
`run_experiment.sh`**: understanding what each stage actually does is what
lets you debug a failure, interpret an unexpected result, or extend the
pipeline later, and `run_experiment.sh` is genuinely just these same
steps chained together (see [§5](#5-automated-workflow-run_experimentsh)
for a line-by-line correspondence).

All examples below use BCI; substitute another site's name and scripts
once you've added one ([§9](#9-adding-a-new-site)).

### 4.1 Step 1 — Build the Shared Site Inputs (Met Driver + Vegetation Init)

**What it does**: converts a site's raw data (tower meteorology, forest
census, soil texture) into the two file formats ED2 actually reads at
startup — an hourly HDF5 meteorological driver, and a `.pss`/`.css`
(patch/cohort) pair describing the initial vegetation state.

**Why it's needed**: ED2 does not read CSVs, `.rdata` files, or raw
NetCDF forcing directly. Every one of those needs a specific unit
convention, timestamp encoding, or structural format, and getting this
translation right (partitioning total shortwave radiation into direct
and diffuse components, computing solar geometry, converting a stem
census into ED2's cohort format, assigning each stem a PFT) is itself
nontrivial — this is exactly the kind of step that's easy to get subtly
wrong and hard to notice, which is why it is scripted rather than done by
hand.

**Why it's shared, not per-experiment**: the real meteorology and the
real forest census at a site do not change from one experiment to the
next — only the namelist settings (which years to simulate, which
physiological switches to flip) do. Building `met/` and `init/` once and
reusing them for every experiment avoids redundant, deterministic work
and guarantees every experiment at a site is driven by identical inputs
(a prerequisite for fair before/after comparisons).

```sh
cd /Users/medinaja/ED2_RUNS

# Optional: sanity-check the raw data before building anything from it
# (confirms the census is real, non-corrupted forest structure data, not
# a placeholder; confirms the met CSV has a full, gap-free hourly record)
Rscript sites/BCI/R/data_preparation/evaluate_bci_data.R

# Build the shared inputs
Rscript sites/BCI/R/data_preparation/build_bci_datasets.R
```

**Inputs**: `sites/BCI/raw_data/` (§2.4).

**Outputs**:

- `sites/BCI/run/met/*.h5` (one file per real month covered by the
  source data, e.g. `2003JAN.h5`) plus `ED_MET_DRIVER_HEADER`, an index
  ED2 reads to find them.
- `sites/BCI/run/init/BCI.lat9lon-79.846.{pss,css}` — one patch, and one
  cohort per living stem in the census (respectively).
- Console output reporting the resolved soil texture (`SLXSAND`/
  `SLXCLAY`) that the next step needs.

**Run this only when the raw data changes** — not once per experiment.
If you ever delete `sites/BCI/run/` to start clean (it contains only
generated files, safe to remove), this is the first thing to rebuild; it
does not touch `experiments_registry.csv`, which lives at the repo root
and is unaffected by anything under `sites/<site>/run/`.

### 4.2 Step 2 — Build the Experiment's `ED2IN` Namelist

**What it does**: takes the stock `ED2IN` template (§2.3) and overrides
the fields specific to this one experiment — simulation dates, which
physiological options are enabled, where output should be written, and
(optionally) a restart source or PFT parameter override — producing
`sites/BCI/run/ED2IN-<exp_id>`.

**Why it's needed**: `ED2IN` is a Fortran namelist file with roughly 300
parameters. Editing it by hand for every experiment is slow and
error-prone (a stray path or malformed array is a common source of
opaque ED2 startup failures); this script encapsulates the set of edits
that actually vary between experiments as flags, and leaves everything
else at the template's validated defaults.

```sh
Rscript sites/BCI/R/model_runs/build_bci_ed2in.R --name=baseline
```

See [§6.1](#61-namelist-ed2in-flag-reference) for the complete flag
table (dates, `PLANT_HYDRO_SCHEME`, `--pft_config`, `--restart_from`,
`--output_freq`, ...) — every flag works identically whether you call
this script directly or through `run_experiment.sh`.

`--output_freq` (default `monthly`) is set at this step, not at run time —
it controls `NL%IMOUTPUT`/`NL%IDOUTPUT`/`NL%IFOUTPUT` in the namelist this
script writes, which in turn determines which `analysis-{E,D,I}-*.h5`
files ED2 actually produces when you run it in §4.3. If you decide later
that you need a resolution you didn't request here, there's no way to add
it after the fact — you must rebuild the namelist (this step) with the
right `--output_freq` and re-run the model; see [§6.3](#63-output-resolution-monthly-daily-hourly)
for the full mechanics.

**Inputs**: `ED/run/ED2IN` (the template); if `--restart_from` is given,
that experiment's `history-S-*.h5` files (§4.6).

**Outputs**:

- `sites/BCI/run/ED2IN-<exp_id>` — the finished namelist.
- A new row in `experiments_registry.csv` with `status = built`.
- `sites/BCI/run/experiments/<exp_id>/` — an empty folder, created ready
  to receive this experiment's output.
- **`EXP_ID:<value>` printed as the first line of output** — this is the
  resolved experiment id (your `--name` plus an automatic timestamp,
  unless you pinned an exact id with `--exp`). Capture it if you're
  scripting around this step yourself; `run_experiment.sh` parses this
  exact line to chain the remaining steps automatically.

> **Note:** This script does not take a `--site` flag — it lives inside
> `sites/BCI/`, so it is already BCI-specific. The cross-site tools in
> `R-tools/` (§3) are the ones that take `--site=`.

### 4.3 Step 3 — Run ED2

**What it does**: actually executes the compiled `ed2` binary inside the
container against the namelist built in Step 2.

```sh
./run_ed2.sh sites/BCI/run ED2IN-<exp_id>
```

Under the hood, `run_ed2.sh` bind-mounts `sites/BCI/run` into the
container at `/data` and runs:

```sh
podman run --rm --ulimit stack=-1:-1 -v "$(pwd)/sites/BCI/run:/data:Z" ed2:personal -f ED2IN-<exp_id>
```

> **Important:** every path *inside* `ED2IN` (e.g. `SFILIN`,
> `ED_MET_DRIVER_DB`, `FFILOUT`) is relative to `/data` — the mount
> point inside the container — never to a path on your host filesystem.
> This is why the ED2IN-builder script (Step 2) writes relative paths
> like `met/ED_MET_DRIVER_HEADER`, not absolute host paths.

This runs in the foreground and can take anywhere from under a minute
(a short test window) to several hours (a multi-decade run — see the
timing table in [§5](#5-automated-workflow-run_experimentsh)). For
anything longer than a few minutes, background it and tail the log:

```sh
./run_ed2.sh sites/BCI/run ED2IN-<exp_id> > /tmp/bci_run_<exp_id>.log 2>&1 &
tail -f /tmp/bci_run_<exp_id>.log          # or: podman stats --no-stream
```

**Inputs**: the `ED2IN-<exp_id>` namelist (which in turn references
`met/`, `init/`, and optionally another experiment's `history-S-*.h5` or
a `pft_config-<exp_id>.xml` override).

**Outputs**: written into
`sites/BCI/run/experiments/<exp_id>/` — `analysis-{E,D,I}-*.h5` (output
at whichever resolutions were requested, §6.3), `history-S-*.h5` (full
internal-state snapshots, used for restarts, §4.6), `history.xml` (the
resolved parameter set actually used, useful for confirming a
`--pft_config` override took effect), and `run.log` if you redirected it
as shown above.

**When running manually, update the registry yourself** so `list_experiments.R`
(§8.3) stays accurate — `run_experiment.sh` does this automatically, but
a manual run does not:

```sh
Rscript R-tools/update_registry_status.R --exp=<exp_id> --status=running
# ... after the run finishes ...
Rscript R-tools/update_registry_status.R --exp=<exp_id> --status=completed --run_seconds=<n>
# or, on failure:
Rscript R-tools/update_registry_status.R --exp=<exp_id> --status=failed --notes="see run.log"
```

This is not needed for a model run. It is a provided option so the user can keep track of any experiment.

**Checking whether a run actually succeeded**: ED2 does not always exit
with a nonzero status on failure. Check the log directly for the
completion banner and the absence of a fatal error:

```sh
grep -q "Time integration ends" /tmp/bci_run_<exp_id>.log && echo "completed"
grep "FATAL" /tmp/bci_run_<exp_id>.log   # should print nothing
```

### 4.4 Step 4 — Extract the Output

**What it does**: reads ED2's raw HDF5 output files and consolidates them
into tidy, analysis-ready tables — one row per timestep, one column per
variable — instead of leaving you to open dozens of HDF5 files by hand.

**Why it's needed**: ED2 writes one HDF5 file *per output timestep* (one
per month for monthly output, one per day for daily, etc.), each
containing ~600 variables in ED2's own internal shapes (polygon-level
scalars, 17×11 PFT-by-size-class arrays, per-cohort arrays whose length
changes every timestep as cohorts fuse and split, ...). Extraction
collapses this into two flat, plottable tables per experiment:

- `timeseries_output_<resolution>.{csv,rds}` — one row per timestep,
  ecosystem-scale scalars: carbon fluxes (GPP, NPP, respiration), carbon
  stocks (total and by PFT), plant hydraulics, energy balance, and
  meteorological forcing as ED2 actually saw it.
- `sizeclass_output_<resolution>.{csv,rds}` — one row per (timestep, PFT,
  DBH size class) combination: biomass, leaf area, stem density, storage
  carbon, and basal area broken down by both plant functional type *and*
  tree size simultaneously (ED2's native 11-class DBH binning:
  10 cm-wide classes from 0–100 cm, plus an 11th class for trees over
  100 cm).

```sh
Rscript sites/BCI/R/output_preparation/extract_bci_output.R --exp=<exp_id> --resolution=monthly
```

**Choosing a resolution — this is the answer to "how do I get hourly or
daily output instead of just monthly"**: `--resolution` must be one of
`monthly`, `daily`, or `hourly`, and must match a resolution that was
actually enabled when the experiment's `ED2IN` was built (via
`--output_freq`, §6.3) — extraction reads whichever HDF5 files exist
(`analysis-E-*.h5` for monthly, `analysis-D-*.h5` for daily,
`analysis-I-*.h5` for hourly) and fails clearly if the requested
resolution's files aren't present:

```sh
Rscript sites/BCI/R/output_preparation/extract_bci_output.R --exp=<exp_id> --resolution=daily
Rscript sites/BCI/R/output_preparation/extract_bci_output.R --exp=<exp_id> --resolution=hourly
```

> **Warning — a resolution only has output once a full period of that
> length has completed.** Monthly output needs the simulation to cross
> an actual month boundary; a run shorter than one month will produce
> daily/hourly files but zero monthly ones, and extracting at
> `--resolution=monthly` for such a run will fail with "No
> analysis-E-*.h5 files found." This is expected, not a bug — request
> `daily` or `hourly` instead for short test runs.
>
> **Note — not every variable exists at every resolution.** ED2 uses a
> different variable-name prefix per resolution (`MMEAN_`/`DMEAN_`/
> `FMEAN_` for monthly/daily/hourly time-means, e.g. `MMEAN_GPP_PY` vs.
> `DMEAN_GPP_PY` vs. `FMEAN_GPP_PY`), and does not write every variable
> at every resolution — most notably, **per-cohort GPP/NPP
> (`MMEAN_GPP_CO`/`MMEAN_NPP_CO`) are monthly-only**; there is no
> `DMEAN_`/`FMEAN_` equivalent. This means the `sizeclass_output_daily`/
> `sizeclass_output_hourly` tables have real (non-zero) biomass/LAI/
> density/storage-carbon columns but zeroed-out GPP/NPP columns — this
> is a real ED2 output limitation, not a gap in the extraction script,
> and the script prints a note to this effect when it happens.

**Inputs**: `sites/BCI/run/experiments/<exp_id>/analysis-{E,D,I}-*.h5`
(whichever resolution was requested).

**Outputs**: `timeseries_output_<resolution>.{csv,rds}` and
`sizeclass_output_<resolution>.{csv,rds}` inside that experiment's
folder. The `.rds` files are what the plotting step (4.5) and
`compare_experiments.R` (§8.3) read; the `.csv` files are for opening in
a spreadsheet or another language.

**Timestamps**: the `datetime` column matches each HDF5 file's actual
reporting instant — confirmed for hourly output by matching the diurnal
shortwave-radiation and GPP cycle against local time. Monthly files
internally use day `"00"` as a month marker (not a real calendar day);
the extraction script anchors these to day 1 of that month so the
`datetime` column is always a valid date.

Extraction for one resolution is independent of any other — running it
for `monthly` and then `daily` for the same experiment is safe and
non-destructive, since each resolution writes to its own filenames.

**Choosing which variables to extract (`--variables`, `--sizeclass_variables`)
— this is the answer to "how do I get a specific list of variables instead
of the fixed default set"**: by default, extraction pulls a fixed, curated
set of ~23 ecosystem-scale variables and all 7 size-class variables (the
same set this script has always extracted). Pass a comma-separated list to
extract something different instead:

```sh
Rscript sites/BCI/R/output_preparation/extract_bci_output.R --exp=<exp_id> \
    --variables=GPP,NPP,LeafTemp --sizeclass_variables=AGB,NPLANT
```

- **`--variables`** (ecosystem-scale table) accepts either this script's
  own friendly column names (`GPP`, `LeafTemp`, `SensibleAC`, ... — the
  same names that appear as columns in `timeseries_output_<resolution>.csv`
  today) **or any raw ED2 variable name straight from `variable_catalog.csv`**
  (§4.5) for a polygon-scale (`_PY`) variable not in the curated set — e.g.
  `--variables=ATM_TMP_PY` works even though air temperature isn't one of
  the ~23 defaults. A resolution prefix (`MMEAN_`/`DMEAN_`/`FMEAN_`) is
  optional on a raw name; the script strips whichever one you included and
  substitutes the correct one for the `--resolution` you're extracting at.
  A requested variable that doesn't exist in the file at all becomes an
  all-`NA` column rather than an error — check `variable_catalog.csv` if a
  column comes back empty.
- **`--sizeclass_variables`** (PFT × size-class table) is a **closed** list
  — it must be a subset of `LAI`, `AGB`, `NPLANT`, `Bstorage`, `BasalArea`,
  `GPP`, `NPP`, since those are the only variables ED2 writes in the
  17×11 PFT-by-size-class shape; unlike `--variables` it cannot be extended
  to arbitrary raw names.
- Not sure what's available to add? Run `describe_variables.R` (§4.5)
  first — its `variable_catalog.csv` is the reference for every raw
  variable name, its dimensions, and its "kind" (polygon scalar,
  PFT × size-class array, ...).
- **Plotting a restricted extraction is safe**: `plot_bci_output.R` (§4.5)
  checks each plot's required column(s) before building it and skips that
  one plot — with a console note, not an error — if a variable wasn't
  extracted. E.g. extracting only `--variables=GPP,NPP` still produces
  the carbon-flux plot's *available* half correctly and simply skips
  every plot needing a column you didn't request.
- Re-running extraction for the same `--exp`/`--resolution` with a
  different `--variables`/`--sizeclass_variables` list overwrites that
  resolution's `timeseries_output_*`/`sizeclass_output_*` files — it does
  not merge with a previous extraction, so include everything you want in
  one call.

### 4.5 Step 5 — Plot the Output and Catalog Variables

**Plotting** turns the extracted tables into a standard set of PNG
figures, organized by topic (carbon fluxes, carbon stocks, plant
hydraulics, energy balance, meteorological forcing, and PFT/size-class
breakdowns):

```sh
Rscript sites/BCI/R/output_preparation/plot_bci_output.R --exp=<exp_id> --resolution=monthly
```

Run once per resolution you extracted (matching §4.4); each resolution's
figures land in their own subfolder,
`sites/BCI/run/experiments/<exp_id>/figures/<resolution>/`, so plotting
`monthly` and `daily` back to back does not overwrite either. Any PFT or
size-class breakdown is drawn as a heatmap matrix (date/size-class ×
PFT), never a stacked bar or area chart — stacking hides each PFT's own
magnitude behind the others and, combined with a log scale (needed for
variables spanning orders of magnitude), can make segment heights
outright misleading.

**Cataloging variables** answers "what output variables exist, what are
their dimensions, and what do they mean" without you having to open an
HDF5 file by hand or read ED2's Fortran source:

```sh
Rscript R-tools/describe_variables.R --site=BCI --exp=<exp_id>
```

This is a cross-site tool (hence `--site=`, unlike the two site-specific
scripts above) — it introspects whichever HDF5 output file it can find
for that experiment (preferring monthly, falling back to daily or hourly
if no monthly file exists yet) and classifies every one of ED2's ~600
variables by shape (polygon-level scalar, 17×11 PFT-by-size-class array,
soil-layer array, per-cohort array, or other), plus a curated
description/units/source-script for the ~35 variables this pipeline
actually extracts. Writes
`sites/BCI/run/experiments/<exp_id>/variable_catalog.csv`.

### 4.6 Restarting or Continuing a Run

**What this is for**: once a run has reached ecological equilibrium (or
you simply want to extend a run further in time without redoing years
already simulated), you can start a *new* experiment that continues from
an *earlier* experiment's exact internal state — every cohort's carbon
and water pools, every patch's disturbance history, every soil layer's
moisture — rather than starting over `INITIAL` from the census each
time. This is ED2's own `RUNTYPE=HISTORY` restart mechanism.

To do this manually, pass `--restart_from` at Step 2 (building the
namelist) instead of the usual `--start_date`:

```sh
Rscript sites/BCI/R/model_runs/build_bci_ed2in.R \
    --name=continued --restart_from=baseline_20260716_110606 --end_date=2004-12-31
```

Then run Steps 3-5 exactly as normal against the resulting `exp_id`.

**What actually happens**, in detail:

- `build_bci_ed2in.R` looks inside
  `sites/BCI/run/experiments/baseline_20260716_110606/` for
  `history-S-*.h5` snapshot files, and (by default) picks the most
  recent one. Use `--restart_date=YYYY-MM-DD` to pick an earlier
  snapshot instead, if the source experiment wrote more than one.
- The new experiment's simulation **starts at that snapshot's own
  timestamp** — any `--start_date` you pass is ignored for a restart.
  Only `--end_date` matters, controlling how much further the new
  experiment runs.
- `SFILIN` in the new `ED2IN` points at the source experiment's own
  `history` file prefix — the source experiment's files are read, never
  copied or modified. Deleting the new (child) experiment never affects
  the old (parent) one, but deleting the *parent* before the child is
  ever run will break the restart.

> **Warning — `PLANT_HYDRO_SCHEME` cannot change across a restart,
> confirmed by testing.** A static-hydraulics (`0`) run's saved state has
> a placeholder wood-water-potential value baked in; restarting it with
> `--plant_hydro_scheme=1` (or vice versa) crashes with a `FATAL` "Plant
> Hydrodynamics is off-track" error, because the dynamic scheme's
> internal sanity checks reject the static scheme's placeholder. Always
> restart into the **same** `PLANT_HYDRO_SCHEME` the source experiment
> used. If you need to compare hydraulics schemes over a long spin-up,
> start each scheme from the same `INITIAL` point independently, rather
> than restarting one into the other.
>
> A `--pft_config` override, by contrast, **is** safe to apply at a
> restart — XML parameter overrides are reapplied fresh at every startup
> (`INITIAL` or `HISTORY` alike), so restarting with a *different*
> `--pft_config` than the parent used is a valid way to ask "what if this
> parameter had been different, starting from this same equilibrium
> state?"

### 4.7 When to Use the Manual Workflow Instead of `run_experiment.sh`

The automated script (§5) is right for most day-to-day experiment runs.
Reach for the manual steps in this section instead when:

- **Debugging a failure.** If `run_experiment.sh` reports a failed run,
  re-running the individual steps lets you inspect intermediate state
  (does the namelist look right? does the raw HDF5 output exist? does
  extraction succeed in isolation?) instead of re-running the entire
  pipeline to reproduce the failure.
- **Re-extracting or re-plotting at a different resolution** after the
  fact, without re-running the model — e.g. you ran with
  `--output_freq=monthly,daily` but only plotted `monthly` at the time;
  rerunning just Step 4/5 at `--resolution=daily` is faster than
  rebuilding the whole experiment.
- **Iterating on the extraction or plotting scripts themselves** — e.g.
  you're adding a new variable to the extraction output and want to
  rerun just that step against existing HDF5 output to check it.
- **Building a namelist without running it yet** — e.g. to inspect
  `ED2IN-<exp_id>` or `history.xml` before committing to a (possibly
  long) run.
- **Restarting from a specific historical snapshot** other than the most
  recent one (`--restart_date`), a scenario the automated script supports
  but that benefits from double-checking the chosen snapshot manually
  first.

For a first-time run of a new experiment configuration, or for routine
day-to-day work once you're comfortable with the pipeline, the automated
workflow is faster and less error-prone — it runs every step in the
correct order automatically and keeps the registry in sync without extra
commands.

---

## 5. Automated Workflow: `run_experiment.sh`

`run_experiment.sh` runs every step in [§4](#4-manual-workflow-step-by-step)
— build namelist, run ED2, extract output (once per `--output_freq`
resolution), plot output, catalog variables, and record the outcome in
the registry — as a single command:

```sh
./run_experiment.sh --site=BCI --name=baseline
```

Concretely, this one command is equivalent to running, in order:
`build_bci_ed2in.R` (§4.2) → `run_ed2.sh` (§4.3) →
`update_registry_status.R` (§4.3) → `extract_bci_output.R` and
`plot_bci_output.R` for each requested resolution (§4.4, §4.5) →
`describe_variables.R` (§4.5) — with status updates and error handling
added at each stage.

Every experiment is auto-named `<name>_<YYYYMMDD_HHMMSS>` (e.g.
`baseline_20260716_110606`), so running the same `--name` again — or the
exact same configuration — never collides with a previous run; each
attempt gets its own timestamped id and its own output folder.

All flags accepted by `build_bci_ed2in.R` (§4.2) are accepted here and
passed straight through — see [§6.1](#61-namelist-ed2in-flag-reference)
for the complete reference.

```sh
./run_experiment.sh --site=BCI --name=plant_hydro --plant_hydro_scheme=1
./run_experiment.sh --site=BCI --name=high_rho_pft3 --pft_config=sites/BCI/pft_configs/high_rho_pft3.xml
./run_experiment.sh --site=BCI --name=plant_hydro_long --plant_hydro_scheme=1 --start_date=1950-01-01 --end_date=2022-12-31
./run_experiment.sh --site=BCI --name=continued --restart_from=baseline_20260716_110606 --end_date=2004-12-31
./run_experiment.sh --site=BCI --name=hires --output_freq=monthly,daily,hourly
```

**Verified timing** (BCI's default 3-month window, this environment):
cohort loading/fusion (248,715 census stems → ~80 fused cohorts) takes
~67-70s wall time regardless of `PLANT_HYDRO_SCHEME`. Time integration
for the 3-month window took ~165s with `PLANT_HYDRO_SCHEME=0` and ~520s
with `PLANT_HYDRO_SCHEME=1` (the extra internal water-potential
sub-stepping roughly triples wall time); the full `run_experiment.sh`
call (including extraction, plotting, and cataloging) completed in ~6
minutes end-to-end for the baseline configuration. Extrapolating the
baseline integration rate, a full 2003-2016 run (168 months) would take
roughly 4-4.5 hours with hydraulics off, correspondingly longer with it
on.

`run_experiment.sh` runs to completion in the foreground; background it
for anything long-running:

```sh
./run_experiment.sh --site=BCI --name=plant_hydro_long --plant_hydro_scheme=1 \
    --start_date=1950-01-01 --end_date=2022-12-31 > /tmp/my_run.log 2>&1 &
tail -f /tmp/my_run.log
```

**Error handling**:

- If the ED2 run itself fails (non-zero exit, missing "Time integration
  ends" in the log, or a `FATAL` message), `run_experiment.sh` stops
  immediately, marks the experiment `failed` in the registry, and does
  not attempt extraction or plotting on incomplete output.
- If one requested `--output_freq` resolution has no output yet (e.g.
  you asked for `monthly` on a run shorter than a month), extraction for
  *that resolution* fails and is skipped with a warning — the script
  continues on to any other requested resolutions and to variable
  cataloging, rather than aborting the whole run. This is expected
  behavior for short test runs, not something to work around.

---

## 6. Configuration Reference

This section is the flag-by-flag reference for configuring an
experiment — consult it regardless of whether you're calling
`build_bci_ed2in.R` directly (§4.2) or through `run_experiment.sh` (§5);
every flag works identically in both.

### 6.1 Namelist (`ED2IN`) Flag Reference

| Flag | Default | Meaning |
| --- | --- | --- |
| `--site` *(run_experiment.sh only)* | `BCI` | Which `sites/<site>/` to run. |
| `--name` | `experiment` | Human-readable label; a timestamp is appended automatically to form the actual `exp_id`. |
| `--exp` | *(none)* | Pins an **exact** id with no timestamp appended. Only for reproducing or rebuilding a specific already-known id — not for new runs, since it can collide with an existing folder. |
| `--plant_hydro_scheme` | `0` | `NL%PLANT_HYDRO_SCHEME` — ED2's plant hydraulics scheme. `0` = static (leaf and wood water potential always at saturation, no internal water transport tracked); `1` = Christoffersen et al. (2016) dynamic scheme; `2` = Xu et al. (2016) dynamic scheme. |
| `--start_date` | `2003-01-01` | Simulation start date (`NL%IYEARA`/`IMONTHA`/`IDATEA`). BCI-specific default — another site sets its own. **Ignored if `--restart_from` is given** (§4.6). |
| `--end_date` | `2003-03-31` | Simulation end date (`NL%IYEARZ`/`IMONTHZ`/`IDATEZ`). Independent of the met driver's own real-data date range — see [§6.2](#62-climate-year-recycling). |
| `--pft_config` | *(none)* | Path to an XML file overriding ED2's compiled-in PFT parameters — see [§7](#7-pft-configuration). |
| `--restart_from` | *(none)* | An earlier experiment's `exp_id` to continue from (`RUNTYPE=HISTORY`) instead of starting `INITIAL` from the census — see [§4.6](#46-restarting-or-continuing-a-run). |
| `--restart_date` | *(latest)* | Which of `--restart_from`'s `history-S-*.h5` snapshots to restart from, if not the most recent. Format `YYYY-MM-DD`. |
| `--output_freq` | `monthly` | Comma-separated subset of `monthly`,`daily`,`hourly` — which output resolutions ED2 writes (and, via `run_experiment.sh`, which get extracted/plotted). See [§6.3](#63-output-resolution-monthly-daily-hourly). |

### 6.2 Climate Year Recycling

BCI's met driver covers real data from 2003-2016 (`NL%METCYC1`/
`NL%METCYCF` in its `ED2IN`; site-specific — another site's own range
would differ). Your simulation window (`--start_date`/`--end_date`) is
**completely independent** of that range: ED2 automatically recycles
years outside it via a mechanism built into ED2 itself, confirmed
directly in `ED/src/driver/ed_met_driver.f90`:

```fortran
ncyc = metcycf - metcyc1 + 1        ! = 14 for BCI (any site: its own metcycf - metcyc1 + 1)
do while (year_cyc > metcycf)
   year_cyc = year_cyc - ncyc       ! simulated year past the data range -> wraps back into range
end do
do while (year_cyc < metcyc1)
   year_cyc = year_cyc + ncyc       ! simulated year before the data range -> wraps forward into range
end do
```

- **Running past the met driver's last year** works with no
  configuration changes. At BCI, simulated year 2017 transparently uses
  2003's real met data, 2018 uses 2004's, and so on — a deterministic,
  sequential replay of the same 14-year block, repeating indefinitely.
- **Running before the met driver's first year** uses the same mechanism
  in reverse — e.g. simulated year 1990 at BCI uses 2004's real data
  (1990 + 14 = 2004).
- **`NL%ISHUFFLE`** (`0` in every BCI `ED2IN` by default) controls the
  order years are picked once outside the range: `0` = sequential repeat
  (current setting, fully deterministic), `1` = randomly shuffled but the
  same order every run, `2` = randomly shuffled, a different order every
  run (not reproducible without seeding).

> **Note:** this is a literal replay of real recorded years, not
> synthesized new climate — there is no long-term trend and no years
> beyond what's actually in the source record. This is exactly what you
> want for a multi-century **spin-up** to ecological equilibrium (a
> standard ED2 use case: run 200+ years before your real comparison
> period so biomass and soil carbon reach steady state), but it also
> means the borrowed met year and the simulated calendar year diverge
> once you're outside the real data range — don't interpret a simulated
> "2020" as reflecting actual 2020 conditions unless it happens to fall
> on a real data year. To extend a run, just pass a later `--end_date` —
> `METCYC1`/`METCYCF` stay fixed regardless of the simulation window.

### 6.3 Output Resolution: Monthly, Daily, Hourly

`--output_freq` controls which of ED2's built-in output resolutions get
written; pass a comma-separated list to get more than one from the same
run:

```sh
./run_experiment.sh --site=BCI --name=hires --output_freq=monthly,daily,hourly
```

This maps directly onto `ED2IN`'s own `NL%IMOUTPUT`/`NL%IDOUTPUT`/
`NL%IFOUTPUT` namelist variables — `build_bci_ed2in.R` turns each
requested resolution on (`= 3`) and leaves the others off (`= 0`), and
sets `NL%OUTFAST`/`NL%UNITFAST`/`NL%FRQFAST` for hourly output
(`FRQFAST=3600`, packed via `OUTFAST=-1` per ED2's own convention for
sub-daily output). Each resolution writes its own HDF5 file series,
confirmed via `ED/src/io/h5_output.F90`'s naming logic:

| Resolution | `--output_freq` value | File pattern | Variable prefix |
| --- | --- | --- | --- |
| Monthly | `monthly` | `analysis-E-*.h5` | `MMEAN_` |
| Daily | `daily` | `analysis-D-*.h5` | `DMEAN_` |
| Hourly | `hourly` | `analysis-I-*.h5` | `FMEAN_` |

See [§4.4](#44-step-4--extract-the-output) for the two most important
practical consequences of this — that a resolution only has output once
a full period of that length has completed, and that not every variable
is written at every resolution (per-cohort GPP/NPP are monthly-only).

---

## 7. PFT Configuration

**Plant Functional Types (PFTs)** are ED2's built-in vegetation
categories — groups of species treated as physiologically identical for
simulation purposes (e.g. "tropical broadleaf, early successional").
Configuring PFTs correctly requires understanding that **ED2 has two
entirely separate PFT-related mechanisms** that are easy to conflate.
Confusing them is the single most common PFT-configuration mistake this
section exists to prevent.

### 7.1 The Two PFT Mechanisms — Do Not Confuse Them

| | Census-to-PFT classification | ED2's internal PFT parameter table |
| --- | --- | --- |
| **What it is** | The rule that decides *which PFT number* each real census stem becomes | The compiled-in physiological/structural parameters that define what each PFT number *physiologically is* |
| **Where it lives** | In this repo's data-preparation script (`build_bci_datasets.R`), applied once per site | Compiled into the `ed2` binary (`ED/src/init/ed_params.f90`); identical for every site and every user unless explicitly overridden |
| **Example** | "A stem with wood density 0.75 g/cm³ becomes PFT 3" | "PFT 3's wood density is 0.71 g/cm³, its specific leaf area is X, its mortality rate is Y, ..." |
| **How to change it** | Edit the breakpoints/logic in that site's data-preparation script | Write an XML override file and pass `--pft_config` — see [§7.2](#72-overriding-pft-parameters-via-xml) |
| **Scope of the change** | Affects only how *this site's* real stems are labeled | Affects how *every* stem of that PFT number behaves, at any site, in that experiment |

At BCI specifically: `build_bci_datasets.R` assigns every census stem to
PFT 2, 3, or 4 by comparing its species' wood density (`wsg`, joined from
`bci.spptable`) against two breakpoints (0.62 and 0.805 g/cm³ — the
midpoints between adjacent PFTs' *reference* wood densities). This
decides only *which existing PFT a given stem becomes* — it has no effect
on what PFT 2, 3, or 4 physiologically *are*. Changing what a PFT
physiologically *is* — e.g. testing "what if PFT 3 had higher wood
density" — is the subject of the rest of this section.

### 7.2 Overriding PFT Parameters via XML

ED2 has a documented, no-recompile mechanism for overriding any PFT's
compiled-in parameters at runtime: a per-run XML configuration file, read
by `ED/src/io/ed_xml_config.f90` (confirmed directly in that source).
Every `ED2IN` already has the hook for this, unset by default:

```text
NL%IEDCNFGF = '/mypath/config.xml'
```

(This is why every run log prints a harmless `WARNING! ... config.xml
wasn't found. Using default parameters in ED2.` when no override is
requested — no file exists at that placeholder path, so ED2 simply uses
its compiled-in defaults.)

**Where you write these files**: `sites/BCI/pft_configs/` holds BCI's own
reusable override files (another site has its own
`sites/<site>/pft_configs/`). One example ships with this repo —
`high_rho_pft3.xml`, raising PFT 3's (mid-successional tropical) wood
density from ED2's compiled-in default of 0.71 g/cm³ to 0.80 g/cm³:

```xml
<config>
  <pft>
    <num>3</num>
    <rho>0.80</rho>
  </pft>
</config>
```

**How to use one**, with either workflow:

```sh
./run_experiment.sh --site=BCI --name=high_rho_pft3 --pft_config=sites/BCI/pft_configs/high_rho_pft3.xml
# or, manually (§4.2):
Rscript sites/BCI/R/model_runs/build_bci_ed2in.R --name=high_rho_pft3 \
    --pft_config=sites/BCI/pft_configs/high_rho_pft3.xml
```

**What happens internally**: the ED2IN-builder script copies your file
into `sites/BCI/run/pft_config-<exp_id>.xml` (inside the mounted run
directory, since the container only sees that site's `run/` contents)
and points `IEDCNFGF` at it. ED2 recomputes every parameter *derived*
from an override (height/biomass allometry, `wood_Kmax`/`wood_psi50`
under `PLANT_HYDRO_SCHEME`, ...) immediately after applying the XML —
visible as the `"Init_derived_params_after_xml"` line in every run log —
so a single override like `rho` propagates correctly through that PFT's
whole allometry, not just a raw density number in isolation.

**How to write your own**: include only the tags you want to change, one
`<pft>` block per PFT number; anything you omit keeps ED2's compiled-in
default for that PFT.

```xml
<config>
  <pft>
    <num>2</num>
    <SLA>15</SLA>
    <Vm0>18</Vm0>
  </pft>
  <pft>
    <num>4</num>
    <rho>0.95</rho>
  </pft>
</config>
```

### 7.3 Full List of Overridable PFT Parameters

The table below is a curated subset of the most commonly changed
parameters. ED2 supports well over 100 XML-overridable PFT parameters in
total; to get the exhaustive list yourself straight from source (useful
if you need a trait not listed here), run:

```sh
podman run --rm --entrypoint grep ed2:build -n "getConfigREAL.*'pft'" /ED2/ED/src/io/ed_xml_config.f90
```

(This requires the `ed2:build` intermediate image from
[§2.3](#23-extracting-shared-ed2-assets) — the same one-liner pattern
used there to pull files out of the build stage, here used to search it
instead.)

| Tag | Meaning |
| --- | --- |
| `rho` | Wood density (g/cm³) — drives `wood_Kmax`/`wood_psi50`/allometry. The same physical quantity as the census `wsg` used for classification (§7.1), but here it is ED2's *parameter for the whole PFT*, not a per-stem measurement. |
| `SLA`, `sla_s0`, `sla_s1` | Specific leaf area and its size-dependence. |
| `Vm0`, `vm0_v0`, `vm0_v1` | Photosynthetic capacity (maximum carboxylation rate) and its variants. |
| `hgt_min`, `hgt_max`, `hgt_ref` | Height-allometry bounds. |
| `leaf_turnover_rate`, `growth_resp_factor`, `storage_turnover_rate` | Carbon allocation and turnover rates. |
| `mort0`–`mort3`, `frost_mort`, `hydro_mort0`, `hydro_mort1`, `seedling_mortality` | Mortality parameters (`hydro_mort*` only matter when `PLANT_HYDRO_SCHEME > 0`). |
| `wood_water_cap`, `wood_rwc_min`, `wood_psi_min`, `wood_psi_tlp`, `wood_elastic_mod`, `wood_Kmax`, `wood_Kexp`, `wood_psi50` | Plant-hydraulics-specific traits (only exercised when `PLANT_HYDRO_SCHEME > 0`). |
| `sapwood_ratio`, `init_density`, `f_bstorage_init` | Initial-condition-related traits. |

For reference, ED2's compiled-in default wood density for BCI's three
active PFTs (confirmed directly in `ED/src/init/ed_params.f90`):

| PFT number | Description | Default `rho` (g/cm³) |
| --- | --- | --- |
| 2 | Tropical broadleaf, early successional | 0.53 |
| 3 | Tropical broadleaf, mid-successional | 0.71 |
| 4 | Tropical broadleaf, late successional | 0.90 |

> **Tip:** `PEcAn.ED2::write.config.xml.ED2()` can also generate this
> same XML format, but it expects a full PEcAn `settings`/`trait.values`
> object from PEcAn's trait-database/meta-analysis workflow, which is not
> set up in this standalone repo — hand-writing the XML directly (as
> shown above) is the simpler path here.

### 7.4 Selecting Which PFTs Are Active in a Run

A separate namelist setting, `NL%INCLUDE_THESE_PFT`, controls *which
subset* of ED2's compiled-in PFTs actually participate in a given
simulation (confirmed directly in `ED/run/ED2IN` and
`ED/src/io/ed_opspec.F90`). BCI's `build_bci_ed2in.R` sets this to
`c(2, 3, 4)` — the only three PFTs the census-to-PFT classification
(§7.1) ever assigns — but the underlying namelist variable accepts any
subset of ED2's 17 compiled-in PFTs (stock `ED2IN`'s own default is
`1,2,3,4,16`):

| # | PFT | # | PFT |
| --- | --- | --- | --- |
| 1 | C4 grass | 10 | Temperate broadleaf, mid-successional |
| 2 | Tropical broadleaf, early successional | 11 | Temperate broadleaf, late-successional |
| 3 | Tropical broadleaf, mid-successional | 12 | (Beta) Tropical broadleaf, early successional, thick bark |
| 4 | Tropical broadleaf, late successional | 13 | (Beta) Tropical broadleaf, mid-successional, thick bark |
| 5 | Temperate C3 grass | 14 | (Beta) Tropical broadleaf, late successional, thick bark |
| 6 | Northern North American pines | 15 | Araucaria |
| 7 | Southern North American pines | 16 | Tropical/subtropical C3 grass |
| 8 | Late-successional North American conifers | 17 | (Beta) Lianas |
| 9 | Temperate broadleaf, early successional | | |

A related setting, `NL%PFT_1ST_CHECK`, controls what happens if your
vegetation initial condition (`init/*.css`) contains a PFT number that
isn't in `INCLUDE_THESE_PFT` — this repo leaves it at ED2's default (`0`
= stop the run with an error), which is the safest choice: it forces you
to notice a mismatch rather than silently dropping cohorts.

> **Warning — the most common mistake here**: if you change the
> census-to-PFT classification (§7.1) to assign a PFT number that isn't
> also added to `INCLUDE_THESE_PFT`, the run will fail at startup with a
> `PFT_1ST_CHECK`-related error. **Whenever you change which PFT numbers
> your vegetation init can produce, update `INCLUDE_THESE_PFT` to match.**
> This repo's `build_bci_ed2in.R` currently hardcodes `include_these_pft
> = c(2, 3, 4)` to match BCI's classification exactly — if you edit
> BCI's wood-density breakpoints to introduce a fourth successional
> class, you must add that PFT number here too.

### 7.5 What You Cannot Do Without Recompiling ED2

ED2 ships with a **fixed, compile-time constant of 17 total PFT slots**
(`n_pft = 17`, confirmed directly in `ED/src/memory/ed_max_dims.F90`).
This has two important implications for what is and is not possible
without touching ED2's source code:

- **You cannot define an 18th, genuinely new PFT** through configuration
  alone. Every mechanism in this section — the XML override (§7.2,
  §7.3) and `INCLUDE_THESE_PFT` (§7.4) — lets you *reparameterize* or
  *select among* the 17 existing PFT slots; it does not let you add a
  new one. Defining a genuinely new PFT (e.g. a novel physiological
  syndrome not resembling any of the 17 built-in types) requires editing
  ED2's Fortran source (`ed_params.f90`, `ed_max_dims.F90`, and every
  file that iterates over PFTs by that fixed count) and recompiling —
  well outside the scope of this repository, which only automates
  *running* ED2, not modifying it.
- **You can, however, effectively repurpose an unused PFT slot** as a
  stand-in for a new type — e.g. if your site never uses PFT 17
  (lianas), you could override its parameters via XML to represent
  something else entirely, as long as you're comfortable that its name
  in ED2's own tables and documentation will still say "lianas."

### 7.6 Common PFT Configuration Mistakes

| Mistake | Consequence | Fix |
| --- | --- | --- |
| Confusing census classification (§7.1) with the parameter table (§7.2) — e.g. expecting a `--pft_config` override to relabel which real stems get which PFT number | The override changes the *physiology* of a PFT number, not which stems are assigned to it — your census-labeling stays the same | Edit the classification logic in `build_bci_datasets.R` for labeling changes; use `--pft_config` only for physiological parameter changes |
| Adding a new PFT number to your vegetation init without adding it to `INCLUDE_THESE_PFT` (§7.4) | Run fails at startup (`PFT_1ST_CHECK` error, default behavior) | Update `include_these_pft` in `build_bci_ed2in.R` to include every PFT number your init data can produce |
| Expecting to define a genuinely new (18th) PFT via XML | Not possible — `n_pft = 17` is a compile-time constant (§7.5) | Repurpose an existing, unused PFT slot, or modify and recompile ED2 source (out of scope here) |
| Overriding a parameter but not checking `history.xml` after the run | Silent typos in a tag name are simply ignored by ED2 (unknown tags are not applied and do not error) | After running, check `sites/BCI/run/experiments/<exp_id>/history.xml` to confirm your override actually took effect |
| Changing `rho` (or other allometry-linked parameters) expecting only that one value to change | ED2 recomputes every *derived* parameter (height/biomass allometry, hydraulic traits) after applying the XML — other reported values will also change, correctly | This is expected behavior, not a bug — see `"Init_derived_params_after_xml"` in the run log |
| Restarting (`--restart_from`) into a different `PLANT_HYDRO_SCHEME` while also changing PFT parameters | The restart itself fails regardless of PFT changes — see the warning in [§4.6](#46-restarting-or-continuing-a-run) | Keep `PLANT_HYDRO_SCHEME` identical across a restart; PFT parameter changes are fine to combine with a restart |

---

## 8. Output Files and Results

### 8.1 Output File Naming Convention

Inside `sites/<site>/run/experiments/<exp_id>/`:

| File pattern | Contents |
| --- | --- |
| `analysis-E-*.h5` | Raw ED2 monthly output (one file per month) |
| `analysis-D-*.h5` | Raw ED2 daily output (one file per day) |
| `analysis-I-*.h5` | Raw ED2 hourly/instantaneous output (one file per day, packed) |
| `history-S-*.h5` | Full internal-state snapshots — what `--restart_from` (§4.6) reads |
| `history.xml` | The resolved parameter set ED2 actually used, after any `--pft_config` override was applied |
| `run.log` | ED2's console output, if you redirected it |
| `timeseries_output_<resolution>.{csv,rds}` | Extracted ecosystem-scale scalars (§4.4) |
| `sizeclass_output_<resolution>.{csv,rds}` | Extracted PFT × DBH-size-class breakdown (§4.4) |
| `variable_catalog.csv` | Every raw output variable's name, dimensions, and (where known) meaning (§4.5) |
| `figures/<resolution>/*.png` | Plots, one subfolder per resolution (§4.5) |

### 8.2 Script Reference Tables

**Cross-site tools** (`R-tools/` at the repo root — site-agnostic, take
`--site=` where they need to locate a site's output):

| Script | Reads | Writes | Notes |
| --- | --- | --- | --- |
| `run_experiment.sh` | — | (chains everything below) | Full pipeline orchestrator for any site (§5). |
| `R-tools/registry_utils.R` | `experiments_registry.csv` | (sourced helper) | `registry_add()`/`registry_update_status()`/`registry_read()`. Not run directly — sourced by each site's ED2IN-builder script, `update_registry_status.R`, and `list_experiments.R`. |
| `R-tools/ed2in_io.R` | — | (sourced helper) | `read_ed2in()`/`modify_ed2in()`/`write_ed2in()`, vendored from `PEcAn.ED2` (full attribution and license in the file's header) so this repo does not require installing the `PEcAn.ED2` package. Not run directly — sourced by each site's ED2IN-builder script (§2.1, §4.2). |
| `R-tools/update_registry_status.R` | — | `experiments_registry.csv` | CLI wrapper around `registry_update_status()` so `run_experiment.sh` can update status without embedding R in the shell script. Doesn't need `--site` (`exp_id` is globally unique). |
| `R-tools/describe_variables.R` | `sites/<site>/run/experiments/<exp_id>/analysis-{E,D,I}-*.h5` | `variable_catalog.csv` | Variable/dimension/units catalog — see §4.5. Falls back to daily/hourly files if no monthly file exists yet. Shape-based classification is site-agnostic. |
| `R-tools/list_experiments.R` | `experiments_registry.csv` | console output only | List/filter every experiment ever built, across all sites — see §8.3. |
| `R-tools/compare_experiments.R` | multiple experiments' `timeseries_output_<resolution>.rds` (same site, same resolution) | `sites/<site>/run/comparisons/<name>/*.png` | Overlay multiple experiments on shared axes — see §8.3. |

**BCI's site-specific scripts** (`sites/BCI/R/` — a new site mirrors this
structure and naming convention; see [§9](#9-adding-a-new-site)):

| Script | Reads | Writes | Notes |
| --- | --- | --- | --- |
| `data_preparation/evaluate_bci_data.R` | `sites/BCI/raw_data/` | console output only | Optional QC pass over the raw met/census/soil files before building anything (§4.1). |
| `data_preparation/build_bci_datasets.R` | `sites/BCI/raw_data/`, `R-utils/`, `ED2_Support_Files-master/` | `sites/BCI/run/met/*.h5` + `ED_MET_DRIVER_HEADER`, `sites/BCI/run/init/*.pss`/`*.css` | Builds the met driver and vegetation initial condition (§4.1). Experiment-independent — run once, shared by every experiment at this site. |
| `data_preparation/lib_load_utils.R` | — | — | Sourced helper (not run directly): loads the specific `R-utils/`/`ED2_Support_Files-master/` functions `build_bci_datasets.R` needs. |
| `model_runs/build_bci_ed2in.R` | `ED/run/ED2IN` (template); `R-tools/ed2in_io.R`; `--restart_from`'s `history-S-*.h5` if given | `sites/BCI/run/ED2IN-<exp_id>`; a row in `experiments_registry.csv` | Builds one experiment's namelist using `R-tools/ed2in_io.R`'s `read_ed2in()`/`modify_ed2in()`/`write_ed2in()` (vendored from `PEcAn.ED2` — no PEcAn install required, see §2.1) — see §6.1's flag table (§4.2). Works around two confirmed bugs inherited from upstream `PEcAn.ED2` (still present in the vendored copy): `read_ed2in()` truncating multi-line array parameters (`SLZ`/`SLMSTR`/`STGOFF`), and (in unported upstream code this repo never calls) path-mangling convenience arguments that would bake in absolute host paths — this repo's script sets path-sensitive fields directly instead. |
| `output_preparation/extract_bci_output.R` | `sites/BCI/run/experiments/<exp_id>/analysis-{E,D,I}-*.h5` (per `--resolution`) | `timeseries_output_<resolution>.{csv,rds}`, `sizeclass_output_<resolution>.{csv,rds}` | See §4.4. `--variables`/`--sizeclass_variables` select which columns get extracted (default: the full curated set, unchanged from before those flags existed). Reads HDF5 directly (`PEcAn.ED2::model2netcdf.ED2()` is broken by a `dplyr` version incompatibility in its per-cohort reshaping — not used). |
| `output_preparation/plot_bci_output.R` | `timeseries_output_<resolution>.rds`, `sizeclass_output_<resolution>.rds` | `figures/<resolution>/{flux,stock,water,energy,forcing,sizeclass}_*.png` | See §4.5. Size-class GPP/NPP plots only appear at `--resolution=monthly` (cohort-level fluxes are monthly-only, §4.4). Any plot whose required column(s) weren't extracted (via a restricted `--variables`/`--sizeclass_variables`) is skipped with a console note rather than erroring. |
| `input_visualization/plot_met_input.R` | `sites/BCI/run/met/*.h5` | `sites/BCI/run/diagnostics/met/*.png` + joined CSV/RDS | QC/visualize the met **input** itself, independent of any experiment or model run. |
| `input_visualization/plot_init_input.R` | `sites/BCI/run/init/*.pss`/`*.css` | `sites/BCI/run/diagnostics/init/*.png` + CSV | QC/visualize the vegetation **input** itself, independent of any experiment. |

### 8.3 Finding and Comparing Experiments

**List every experiment ever built, at any site:**

```sh
Rscript R-tools/list_experiments.R
Rscript R-tools/list_experiments.R --site=BCI
Rscript R-tools/list_experiments.R --name=plant_hydro   # substring filter
Rscript R-tools/list_experiments.R --status=completed
```

This reads `experiments_registry.csv` at the repo root — one row per
experiment (id, site, name, timestamp, configuration flags used, and
status: `built` → `running` → `completed`/`failed`, plus wall-clock run
time). Because this file lives at the repo root, not inside any site's
`run/`, it survives deleting `sites/<site>/run/` entirely and stays the
permanent cross-site record of every experiment ever attempted, even
after its output has been deleted.

**Compare experiments side by side:**

```sh
Rscript R-tools/compare_experiments.R --site=BCI --exp=<id1>,<id2>[,<id3>,...]
Rscript R-tools/compare_experiments.R --site=BCI --exp=<id1>,<id2> --resolution=daily
```

Overlays the requested experiments' (must be the same site) output,
colour-coded by experiment, into one set of faceted plots — carbon
fluxes, carbon stocks, plant hydraulics, energy/microclimate — written to
`sites/BCI/run/comparisons/comparison_<resolution>_<timestamp>/` (or
`--out=<name>` for a fixed folder name). `--resolution` (default
`monthly`) must match a resolution every experiment being compared was
actually extracted at (§6.3) — every experiment must have already been
extracted at that resolution (`run_experiment.sh` does this automatically
for whatever `--output_freq` it was given).

**Worked example** — baseline vs. dynamic plant hydraulics at BCI:

| Experiment | `PLANT_HYDRO_SCHEME` | Window | Result |
| --- | --- | --- | --- |
| baseline | 0 (static) | 2003-01 to 2003-03 | `WfluxGW`/`WfluxWL` (internal soil→wood/wood→leaf water flux) are **exactly 0** every month — no internal water transport is tracked, as expected. |
| plant_hydro | 1 (Christoffersen et al. 2016) | 2003-01 to 2003-03 | `WfluxGW`/`WfluxWL` become non-zero (~3.3e-5 kg/m²/s), and `WoodWater` jumps from ~4 kg/m² to ~38-41 kg/m² (a real, dynamically-tracked sapwood water pool instead of the static nominal value). GPP/NPP shift only slightly (~1-8%) over this short, wet-season window with no water stress — a longer run spanning BCI's dry season would be the real test of whether the scheme matters for carbon fluxes here. |

`Rscript R-tools/compare_experiments.R --site=BCI --exp=<baseline_id>,<plant_hydro_id>`
is the fastest way to see this: the plant-hydraulics panel shows a
flat-zero line vs. a clearly non-zero one for `WfluxGW`/`WfluxWL`.

---

## 9. Adding a New Site

A new site needs its own `sites/<Site>/` folder mirroring BCI's structure
and script-naming convention (§3, §8.2), so the cross-site tools
(`run_experiment.sh`, `R-tools/describe_variables.R`,
`R-tools/compare_experiments.R`) can find it automatically:

1. **`sites/<Site>/raw_data/`** — that site's raw meteorological, soil,
   and vegetation data.
2. **`sites/<Site>/R/data_preparation/build_<sitelower>_datasets.R`** —
   builds `sites/<Site>/run/{met,init}` from the raw data, following
   `build_bci_datasets.R`'s pattern (met driver: shortwave partition,
   solar geometry, longwave estimate if not directly measured;
   vegetation init: census → cohorts with a PFT assignment rule
   appropriate for that site's species — see [§7.1](#71-the-two-pft-mechanisms--do-not-confuse-them)).
3. **`sites/<Site>/R/model_runs/build_<sitelower>_ed2in.R`** — builds
   that site's `ED2IN`, following `build_bci_ed2in.R`'s pattern: the same
   `--name`/`--exp`/`--plant_hydro_scheme`/`--start_date`/`--end_date`/
   `--pft_config`/`--restart_from`/`--restart_date`/`--output_freq` flags
   (§6.1), the same `EXP_ID:<value>` first-line-of-output convention, and
   the same `registry_add(repo_root, exp_id, site = "<Site>", ...)` call
   at the end (sourcing both `R-tools/registry_utils.R` and
   `R-tools/ed2in_io.R` from the repo root, not site-local copies) — but
   with that site's own coordinates, soil texture, PFT set (and matching
   `include_these_pft`, §7.4), and met/init paths.
4. **`sites/<Site>/R/output_preparation/{extract,plot}_<sitelower>_output.R`**
   — following the BCI pair's pattern (both take `--exp` and
   `--resolution`), **writing to `timeseries_output_<resolution>.{csv,rds}`
   and `sizeclass_output_<resolution>.{csv,rds}` exactly** (not
   `<sitelower>_timeseries_output...`) so `R-tools/compare_experiments.R`
   and `run_experiment.sh` can find them without needing to know anything
   site-specific about column names or PFT numbering.
5. *(Optional)* `sites/<Site>/R/input_visualization/` for input QC plots,
   and `sites/<Site>/pft_configs/` for that site's own PFT-override XML
   files.

Once in place, both workflows work exactly as they do for BCI, with no
further changes:

```sh
./run_experiment.sh --site=<Site> --name=baseline
```

---

## 10. Troubleshooting and Caveats

| Symptom | Explanation | What to do |
| --- | --- | --- |
| `WARNING! ... config.xml wasn't found` in the run log | Harmless. Every `ED2IN` has the `IEDCNFGF` hook set, but points at a placeholder path unless `--pft_config` was used | Ignore, unless you *did* pass `--pft_config` and expected an override — in that case, check the path you gave actually exists |
| `No analysis-E-*.h5 files found ... for --resolution=monthly` | The run window was shorter than one month, so ED2 never wrote a monthly output file — this is expected, not a bug (§4.4) | Extract at `--resolution=daily` or `--resolution=hourly` instead, or extend the run past a month boundary |
| `FATAL` "Plant Hydrodynamics is off-track" on a restart | `--plant_hydro_scheme` was changed across a `--restart_from` restart — not supported (§4.6) | Restart into the same `PLANT_HYDRO_SCHEME` the parent experiment used |
| Run fails at startup citing an invalid or missing PFT | A PFT number appears in your vegetation init that isn't in `NL%INCLUDE_THESE_PFT` (§7.4) | Add that PFT number to `include_these_pft` in the site's ED2IN-builder script |
| `sizeclass_output_daily`/`_hourly` has zeroed-out GPP/NPP columns | Per-cohort GPP/NPP are only written by ED2 at monthly resolution — a real ED2 limitation, not an extraction bug (§4.4) | Use `--resolution=monthly` if you need size-class-resolved GPP/NPP |
| An `ED2IN` array parameter (e.g. `SLZ`) looks truncated after `build_*_ed2in.R` runs | A bug inherited from upstream `PEcAn.ED2` (still present in `R-tools/ed2in_io.R`'s vendored `read_ed2in()`): it truncates multi-line array parameters to their first 10 values | Already worked around in this repo's ED2IN-builder scripts — if you see it anyway, check the script re-assigns the affected array (`SLZ`/`SLMSTR`/`STGOFF`) explicitly after calling `read_ed2in()` |
| Absolute host paths appear inside `ED2IN` and the container can't find its inputs | Upstream `PEcAn.ED2::modify_ed2in()`'s `met_driver`/`output_dir` convenience arguments call `normalizePath()`, baking in absolute host paths that don't exist inside the container — this is why those two arguments were not ported into `R-tools/ed2in_io.R` at all | This repo's ED2IN-builder scripts set path-sensitive fields (`ED_MET_DRIVER_DB`, `FFILOUT`, `SFILOUT`, ...) directly as raw namelist arguments instead of using those convenience arguments |
| Downward longwave radiation seems more uncertain than other forcing variables (BCI only) | Never directly measured at the BCI tower; estimated via Longo's `"aml"` scheme with uncalibrated coefficients | Expect more uncertainty in radiation-driven fluxes than a fully-measured-forcing site would have; not applicable to a site with measured longwave |
| Soil carbon pool values (`fsc`/`stsc`/`stsl`/`ssc`/`msn`/`fsn`) seem generic (BCI only) | These are illustrative defaults at BCI, not site-specific measurements | Treat soil-carbon-pool-dependent results with appropriate caution until site-specific values are available |
| Unexplained placeholder files inside `sites/BCI/run/init/` | `build_bci_datasets.R`/`build_bci_ed2in.R` write two small decoy files to work around a real ED2 `filelist_c_` alphabetical-ordering bug | Leave them — do not "clean up" `sites/BCI/run/init/` by hand |
| A simulated year's results don't match what you'd expect from that real calendar year | Met-year recycling (§6.2) means any run extending outside a site's real data range is replaying real years out of their original calendar order | Check which real year actually backed a given simulated year (via `METCYC1`/`METCYCF` and the recycling formula) before attributing results to "conditions in year X" |

---

## 11. TL;DR / Quick Reference

```sh
# One-time setup (§2): podman machine running, ed2:personal image built,
# R-utils/ED2IN extracted, raw data in place.

cd /Users/medinaja/ED2_RUNS

# One-time per site: build the shared met driver + vegetation init (§4.1)
Rscript sites/BCI/R/data_preparation/build_bci_datasets.R

# Run a full experiment at a site: build namelist -> run ED2 -> extract ->
# plot -> catalog variables -> log to the registry. One command, ~6 min
# for BCI's default 3-month baseline window (§5).
./run_experiment.sh --site=BCI --name=baseline

# Run a second experiment to compare against (e.g. dynamic plant hydraulics)
./run_experiment.sh --site=BCI --name=plant_hydro --plant_hydro_scheme=1

# Get hourly and daily output too (monthly is always on) - §6.3
./run_experiment.sh --site=BCI --name=hires --output_freq=monthly,daily,hourly

# Continue an earlier experiment from where it left off, instead of
# starting bare-ground/from the census again - §4.6
./run_experiment.sh --site=BCI --name=continued --restart_from=<earlier_exp_id> --end_date=2004-12-31

# Override a PFT's compiled-in parameters (e.g. wood density) - §7
./run_experiment.sh --site=BCI --name=high_rho_pft3 --pft_config=sites/BCI/pft_configs/high_rho_pft3.xml

# Re-extract/plot just a specific set of variables instead of the full
# default set (any raw variable_catalog.csv name works too) - §4.4
Rscript sites/BCI/R/output_preparation/extract_bci_output.R --exp=<exp_id> \
    --variables=GPP,NPP,LeafTemp --sizeclass_variables=AGB,NPLANT
Rscript sites/BCI/R/output_preparation/plot_bci_output.R --exp=<exp_id>

# Find what you've run (across all sites), and compare two experiments at
# the same site on one set of plots (§8.3)
Rscript R-tools/list_experiments.R
Rscript R-tools/compare_experiments.R --site=BCI --exp=<baseline_id>,<plant_hydro_id>
```

Every `run_experiment.sh --site=<site> --name=X` call auto-generates a
fresh, never-colliding `exp_id` (`X_<timestamp>`) and writes its results
to `sites/<site>/run/experiments/<exp_id>/`. For everything this
quick-reference glosses over — what each step actually does and why,
every flag's exact meaning, restart mechanics, output resolution
mechanics, and PFT configuration in depth — see the full sections above,
starting with [§4](#4-manual-workflow-step-by-step) if you're new to
this repository.
