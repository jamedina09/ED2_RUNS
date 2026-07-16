#!/usr/bin/env Rscript
# Build the BCI ED2IN namelist in R using PEcAn.ED2's read_ed2in/modify_ed2in/
# write_ed2in, based on the repo's main template (ED/run/ED2IN).
#
# Two known PEcAn.ED2 issues worked around here (both confirmed by testing
# directly against this template before writing this script):
#   1. read_ed2in() only captures the first line of multi-line array
#      parameters (e.g. NL%SLZ spans 2 physical lines for NZG=16 layers;
#      read_ed2in() silently returns only the first 10 values). Confirmed:
#      length(ed2in[["SLZ"]]) == 10, not 16, straight after read_ed2in().
#      Fixed by re-assigning SLZ/SLMSTR/STGOFF explicitly after reading.
#   2. modify_ed2in()'s `met_driver`/`output_dir` convenience arguments call
#      normalizePath(), baking in absolute host paths - which breaks once
#      the run directory is bind-mounted into a podman container at /data
#      (relative paths are what the container sees). Worked around by
#      setting ED_MET_DRIVER_DB/FFILOUT/SFILOUT/etc. directly as uppercase
#      NL% arguments (passed through modify_ed2in()'s `...`, which does NOT
#      path-mangle them) instead of using those named arguments.
#
# Multi-experiment layout: met/ and init/ (built by build_bci_datasets.R) are
# experiment-independent, so they stay shared at sites/BCI/run/{met,init}.
# Each experiment gets its own namelist (sites/BCI/run/ED2IN-<exp>) and its
# own output directory (sites/BCI/run/experiments/<exp>/), so several
# configs can be built and run side by side (with run_ed2.sh sites/BCI/run
# ED2IN-<exp>) without recomputing met/soil/vegetation-init or clobbering
# each other's output. See README.md. This is BCI's own site-specific
# implementation of the pattern every site under sites/<site>/ follows -
# see README.md for how to adapt it to a new site.
#
# Usage (typical - auto-names the experiment <name>_<timestamp>, so rerunning
# the same config never collides with a previous run). Normally called via
# ./run_experiment.sh --site=BCI ... from the repo root rather than
# directly, but both work:
#   Rscript sites/BCI/R/model_runs/build_bci_ed2in.R --name=baseline
#   Rscript sites/BCI/R/model_runs/build_bci_ed2in.R --name=plant_hydro --plant_hydro_scheme=1
#   Rscript sites/BCI/R/model_runs/build_bci_ed2in.R --name=high_rho_pft3 --pft_config=sites/BCI/pft_configs/high_rho_pft3.xml
#   Rscript sites/BCI/R/model_runs/build_bci_ed2in.R --name=plant_hydro_long --plant_hydro_scheme=1 --start_date=1950-01-01 --end_date=2022-12-31
# --exp=<exact id> overrides --name entirely (no timestamp appended) - use
#   this only to reproduce/rebuild a specific already-known experiment id
#   (e.g. one already run and referenced by exp_id elsewhere), not for new runs.
# Optional flags (defaults shown): --name=experiment --start_date=2003-01-01
# --end_date=2003-03-31 --plant_hydro_scheme=0 (0/1/2, see physiology_coms.f90)
# --pft_config=<path> (relative to the repo root, or absolute; sets
#   NL%IEDCNFGF so ED2 overrides its compiled-in PFT parameters - e.g. wood
#   density - at startup. See README.md section 7. Omit to leave the
#   template's placeholder (no override, harmless startup warning).
#
# --restart_from=<exp_id> (branch a new experiment from another experiment's
#   restart state, instead of cold-starting from the census - e.g. spin up
#   once, then branch several treatment experiments from the same
#   equilibrium state. Sets RUNTYPE='HISTORY' and points SFILIN at that
#   experiment's history-S-*.h5 files; --start_date is ignored and replaced
#   by the restart file's own date. Requires that experiment to have been
#   run with ISOUTPUT=3, i.e. restart files enabled - true by default.)
# --restart_date=<YYYY-MM-DD> (which of --restart_from's history-S-*.h5
#   dates to use; defaults to the latest one available)
#
# --output_freq=monthly[,daily][,hourly] (default: monthly, same as before
#   this flag existed). Comma-separated list of which ED2 output
#   resolutions to write, on top of the always-on yearly restart/history
#   files. Controls IMOUTPUT/IDOUTPUT/IFOUTPUT (see README.md): "monthly"
#   -> analysis-E-*.h5 (one file/month, already what extract_bci_output.R
#   reads), "daily" -> analysis-D-*.h5 (one file/day), "hourly" ->
#   analysis-I-*.h5 (packed one file/day, 24 hourly steps each). Daily/
#   hourly output is NOT read by the current extract_bci_output.R/
#   extract_bci_sizeclass_output.R (those are monthly-only) - read the
#   extra files directly with hdf5r if you need finer resolution.

library(PEcAn.ED2)

# --- Experiment selection ----------------------------------------------------
.cli_args <- commandArgs(trailingOnly = TRUE)
.get_flag <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), .cli_args, value = TRUE)
  if (length(hit) == 0) {
    return(default)
  }
  sub(paste0("^--", name, "="), "", hit[1])
}
exp_name <- .get_flag("name", "experiment")
exp_id_override <- .get_flag("exp", "")
# --exp pins an exact id (no timestamp); otherwise auto-name from --name so
# repeated runs of "the same" experiment never collide with an earlier one.
exp_id <- if (nzchar(exp_id_override)) {
  exp_id_override
} else {
  paste0(exp_name, "_", format(Sys.time(), "%Y%m%d_%H%M%S"))
}
cat(sprintf("EXP_ID:%s\n", exp_id)) # machine-parseable tag (no stray whitespace - cat()'s
# default separator previously left a trailing space before the newline,
# corrupting run_experiment.sh's captured exp_id) - it greps this exact line
plant_hydro_scheme <- as.integer(.get_flag("plant_hydro_scheme", "0"))
run_start_date <- .get_flag("start_date", "2003-01-01")
run_end_date <- .get_flag("end_date", "2003-03-31")
pft_config_flag <- .get_flag("pft_config", "")
restart_from <- .get_flag("restart_from", "")
restart_date_flag <- .get_flag("restart_date", "")
output_freq_flag <- .get_flag("output_freq", "monthly")

# Locate the repo root from this script's own path (portable - works on any
# machine/device, not tied to a specific home directory). See
# README.md's architecture section for why this matters.
.this_file <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1])
.this_dir <- dirname(normalizePath(.this_file))
.find_repo_root <- function(d) {
  for (i in 1:20) {
    if (file.exists(file.path(d, ".ed2_repo_root"))) {
      return(d)
    }
    parent <- dirname(d)
    if (parent == d) stop("Could not locate repo root (no .git found)")
    d <- parent
  }
  stop("Could not locate repo root (no .git found)")
}
repo_root <- .find_repo_root(.this_dir)
source(file.path(repo_root, "R-tools/registry_utils.R")) # cross-site tool - lives at the repo root, not under sites/BCI/
site_id <- "BCI" # hardcoded: this script only ever builds BCI experiments (it lives inside sites/BCI/)
run_dir <- file.path(repo_root, "sites/BCI/run")
exp_rel_dir <- file.path("experiments", exp_id) # relative to run_dir -> /data inside the container

# --- Optional restart from another experiment's history file (--restart_from) -
# RUNTYPE='HISTORY' resumes full model state (biomass, soil water/carbon,
# canopy thermodynamics - not just biomass, unlike IED_INIT_MODE-based
# initial conditions) from a previous experiment's history-S-*.h5 file, so
# a new experiment (e.g. a different PLANT_HYDRO_SCHEME or PFT config) can
# branch from an already-spun-up state instead of the raw census.
run_type <- "INITIAL"
restart_sfilin <- NULL
restart_h <- NULL
if (nzchar(restart_from)) {
  restart_dir <- file.path(run_dir, "experiments", restart_from)
  hist_files <- list.files(restart_dir, pattern = "^history-S-\\d{4}-\\d{2}-\\d{2}-\\d{6}-g01\\.h5$")
  if (length(hist_files) == 0) {
    stop(
      "No history-S-*.h5 restart files found in ", restart_dir, " - was ",
      "--restart_from='", restart_from, "' run with ISOUTPUT enabled ",
      "(true by default; see --output_freq's header comment) and did it ",
      "actually reach a restart-writing point (FRQSTATE/UNITSTATE)?"
    )
  }
  hist_dates <- regmatches(hist_files, regexpr("\\d{4}-\\d{2}-\\d{2}-\\d{6}", hist_files))
  if (nzchar(restart_date_flag)) {
    want <- format(as.Date(restart_date_flag), "%Y-%m-%d")
    match_idx <- which(startsWith(hist_dates, want))
    if (length(match_idx) == 0) {
      stop(
        "No restart file matching --restart_date=", restart_date_flag, " in ",
        restart_dir, ". Available dates: ", paste(sort(unique(substr(hist_dates, 1, 10))), collapse = ", ")
      )
    }
    chosen <- hist_dates[match_idx[1]]
  } else {
    chosen <- sort(hist_dates)[length(hist_dates)] # latest available
  }
  restart_h <- list(
    year = as.integer(substr(chosen, 1, 4)),
    month = as.integer(substr(chosen, 6, 7)),
    date = as.integer(substr(chosen, 9, 10)),
    time = as.integer(substr(chosen, 12, 15))
  )
  run_type <- "HISTORY"
  # Same prefix that --restart_from's own build_bci_ed2in.R run wrote its
  # SFILOUT as (see FFILOUT/SFILOUT below) - guaranteed to match since it's
  # the exact same "experiments/<exp>/history" convention every experiment uses.
  restart_sfilin <- file.path("experiments", restart_from, "history")
  # A HISTORY run's start date IS the restart point (see ED2IN's own
  # RUNTYPE documentation: "you should NOT change IMONTHA and related" once
  # set to match IYEARH/etc.) - --start_date is meaningless here and ignored.
  run_start_date <- sprintf("%04d-%02d-%02d", restart_h$year, restart_h$month, restart_h$date)
  cat(sprintf(
    "Restarting from experiment '%s' at %04d-%02d-%02d %02d:%02d UTC\n",
    restart_from, restart_h$year, restart_h$month, restart_h$date, restart_h$time %/% 100, restart_h$time %% 100
  ))
}

# --- Output frequency (--output_freq) ---------------------------------------
output_freqs <- trimws(strsplit(output_freq_flag, ",")[[1]])
valid_freqs <- c("monthly", "daily", "hourly")
if (!all(output_freqs %in% valid_freqs)) {
  stop("--output_freq must be a comma-separated list from: ", paste(valid_freqs, collapse = ", "),
       " - got: ", output_freq_flag)
}
imoutput <- if ("monthly" %in% output_freqs) 3L else 0L
idoutput <- if ("daily" %in% output_freqs) 3L else 0L
ifoutput <- if ("hourly" %in% output_freqs) 3L else 0L

# --- Optional PFT parameter override (--pft_config) -------------------------
# The XML must end up inside run_dir (the directory bind-mounted at /data),
# not just anywhere under repo_root, since ED2 only sees run_dir's contents.
# Copied in under a fixed name per experiment so it survives independently
# of wherever the source XML lives.
pft_config_rel <- NULL
if (nzchar(pft_config_flag)) {
  pft_config_src <- if (file.exists(pft_config_flag)) {
    normalizePath(pft_config_flag)
  } else {
    normalizePath(file.path(repo_root, pft_config_flag))
  }
  if (!file.exists(pft_config_src)) {
    stop("--pft_config file not found: ", pft_config_flag)
  }
  pft_config_rel <- paste0("pft_config-", exp_id, ".xml")
  file.copy(pft_config_src, file.path(run_dir, pft_config_rel), overwrite = TRUE)
  cat("Copied", pft_config_src, "->", file.path(run_dir, pft_config_rel), "\n")
}

ed2in <- read_ed2in(file.path(repo_root, "ED/run/ED2IN"))

# --- Fix #1: multi-line arrays truncated by read_ed2in() -------------------
stopifnot(length(ed2in[["SLZ"]]) == 10) # confirms the bug is still present
ed2in[["SLZ"]] <- c(
  -8.000, -7.072, -6.198, -5.380, -4.617, -3.910, -3.259,
  -2.664, -2.127, -1.648, -1.228, -0.866, -0.566, -0.326,
  -0.150, -0.040
)
ed2in[["SLMSTR"]] <- rep(1.000, 16)
ed2in[["STGOFF"]] <- rep(0.000, 16)

# --- Site / run configuration via modify_ed2in()'s validated arguments -----
ed2in <- modify_ed2in(
  ed2in,
  run_name = paste0("BCI - Barro Colorado Island, Panama (experiment: ", exp_id, ")"),
  latitude = 9.153,
  longitude = -79.8461,
  start_date = as.Date(run_start_date),
  end_date = as.Date(run_end_date),
  pecan_defaults = FALSE, # would force IED_INIT_MODE=0; we have real census now
  # Only the 3 PFTs actually produced by the wood-density split in
  # build_bci_datasets.R (early/mid/late tropical successional) - no grass
  # (1) or liana (16), since the census assigns every stem to one of 2/3/4
  # and nothing is ever placed in those other two.
  include_these_pft = c(2, 3, 4),
  check_paths = FALSE, # met/init paths are relative to the run dir, not cwd
  add_if_missing = FALSE,

  # --- Fix #2: path-sensitive fields set directly (no normalizePath) -------
  FFILOUT = file.path(exp_rel_dir, "analysis"),
  SFILOUT = file.path(exp_rel_dir, "history"),
  ED_MET_DRIVER_DB = "met/ED_MET_DRIVER_HEADER",

  # --- Run type: cold-start from census (default) or HISTORY restart from
  # another experiment's end state (--restart_from) -------------------------
  RUNTYPE = run_type,
  IYEARH = if (!is.null(restart_h)) restart_h$year else ed2in[["IYEARH"]],
  IMONTHH = if (!is.null(restart_h)) restart_h$month else ed2in[["IMONTHH"]],
  IDATEH = if (!is.null(restart_h)) restart_h$date else ed2in[["IDATEH"]],
  ITIMEH = if (!is.null(restart_h)) restart_h$time else ed2in[["ITIMEH"]],

  # --- Output frequency (--output_freq; see this script's header) ---------
  IMOUTPUT = imoutput, # analysis-E-*.h5, monthly - what extract_bci_output.R reads
  IDOUTPUT = idoutput, # analysis-D-*.h5, daily
  IFOUTPUT = ifoutput, # analysis-I-*.h5, hourly (packed one file/day below)
  UNITFAST = 0, # FRQFAST's units: seconds
  FRQFAST = 3600, # 1 hour - only applies while IFOUTPUT is on
  OUTFAST = if (ifoutput == 3L) -1 else 0, # -1 = pack a day's hourly steps into one file
  # Baked into the ed2:personal image (see Dockerfile.personal) rather than
  # copied into every run dir - it's generic ED2 climatology, not BCI data.
  THSUMS_DATABASE = "/opt/ed2_common/ed_inputs/",
  VEG_DATABASE = "",
  SOIL_DATABASE = "",
  LU_DATABASE = "",
  PLANTATION_FILE = "",
  PHENPATH = "",
  EVENT_FILE = "",

  # --- Vegetation initial condition: real BCI census (build_bci_datasets.R),
  # UNLESS --restart_from is set, in which case SFILIN instead points at
  # that experiment's history-S-*.h5 prefix and IED_INIT_MODE is ignored by
  # ED2 for RUNTYPE='HISTORY' (left at 6 regardless - harmless). -----------
  IED_INIT_MODE = 6, # matches make_bioinit.r's pss/css column layout
  # exactly (verified against ED/src/io/
  # ed_read_ed10_20_history.f90's case(2,6) branch)
  # Filename uses an integer lat but decimal lon - see the matching comment
  # in build_bci_datasets.R for why (confirmed ED2 C-level file-glob bug
  # with two decimal points in the lat/lon filename tag).
  SFILIN = if (!is.null(restart_sfilin)) restart_sfilin else "init/BCI.lat9lon-79.846",

  # --- Soil: no database needed for a POI run (build_bci_datasets.R) -------
  ISOILFLG = 2,
  SLXSAND = 0.3930,
  SLXCLAY = 0.3590,

  # --- Met cycling: matches the real (non-cycled) 2003-2016 data span ------
  METCYC1 = 2003,
  METCYCF = 2016,
  ISHUFFLE = 0,

  # --- Plant hydraulics (see README.md for the constraints behind these) ---
  # IGRASS is kept at 0 for every experiment, not just hydro runs: BCI's
  # census only ever assigns PFTs 2/3/4 (no grass PFT), so IGRASS is inert
  # here either way - fixing it at 0 removes it as a confound between
  # experiments and satisfies ED2's opspec check
  # (plant_hydro_scheme > 0 requires igrass == 0).
  IGRASS = 0,
  PLANT_HYDRO_SCHEME = plant_hydro_scheme,

  # --- Optional PFT parameter override (see README.md section 7) -----------
  # Falls back to the template's own placeholder ('/mypath/config.xml',
  # which doesn't exist - ED2 just warns and uses compiled-in defaults) when
  # --pft_config wasn't passed, so this is always safe to set explicitly.
  IEDCNFGF = if (!is.null(pft_config_rel)) pft_config_rel else ed2in[["IEDCNFGF"]]
)

exp_out_dir <- file.path(run_dir, exp_rel_dir)
dir.create(exp_out_dir, recursive = TRUE, showWarnings = FALSE)
ed2in_path <- file.path(run_dir, paste0("ED2IN-", exp_id))
write_ed2in(ed2in, ed2in_path)
cat("Wrote", ed2in_path, "\n")

# --- Sanity re-check: re-read what we just wrote and confirm no truncation -
reread <- read_ed2in(ed2in_path)
stopifnot(length(reread[["SLZ"]]) == 16)
cat("Verified: SLZ has all 16 layers after round-trip.\n")
cat("Experiment:", exp_id, "\n")
cat("RUNTYPE:", reread[["RUNTYPE"]], "\n")
cat("PLANT_HYDRO_SCHEME:", reread[["PLANT_HYDRO_SCHEME"]], "\n")
cat("IGRASS:", reread[["IGRASS"]], "\n")
cat("IED_INIT_MODE:", reread[["IED_INIT_MODE"]], "\n")
cat("SFILIN:", reread[["SFILIN"]], "\n")
cat("ED_MET_DRIVER_DB:", reread[["ED_MET_DRIVER_DB"]], "\n")
cat("FFILOUT:", reread[["FFILOUT"]], "\n")
cat("IEDCNFGF:", reread[["IEDCNFGF"]], "\n")
cat("Output frequency:", output_freq_flag,
    sprintf("(IMOUTPUT=%d IDOUTPUT=%d IFOUTPUT=%d)\n", imoutput, idoutput, ifoutput))

registry_notes <- paste(c(
  if (nzchar(restart_from)) sprintf("restart_from=%s@%s", restart_from, run_start_date),
  if (output_freq_flag != "monthly") sprintf("output_freq=%s", output_freq_flag)
), collapse = "; ")
registry_add(
  repo_root, exp_id = exp_id, site = site_id, name = exp_name,
  plant_hydro_scheme = plant_hydro_scheme, start_date = run_start_date,
  end_date = run_end_date, pft_config = pft_config_flag, status = "built",
  notes = if (nzchar(registry_notes)) registry_notes else NA_character_
)
cat("Registered in", file.path(repo_root, "experiments_registry.csv"), "\n")
cat("Run with: ./run_ed2.sh sites/BCI/run", paste0("ED2IN-", exp_id), "\n")
cat("Or, for the full pipeline: ./run_experiment.sh --site=BCI --exp=", exp_id, "\n", sep = "")
