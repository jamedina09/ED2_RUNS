#!/usr/bin/env Rscript
# Extract BCI ED2 output at a chosen time resolution into two tidy tables -
# ecosystem-scale (polygon-level) and PFT x DBH-size-class-resolved - saved
# as both CSV (external tools) and RDS (plot_bci_output.R). One script for
# both tables (they used to be two separate extraction scripts); one flag
# controls temporal resolution.
#
# Usage: Rscript sites/BCI/R/output_preparation/extract_bci_output.R --exp=<id> [--resolution=monthly|daily|hourly]
# (--resolution defaults to monthly - requires that experiment's ED2IN to
# have been built with a matching --output_freq, e.g. --output_freq=daily
# or --output_freq=monthly,daily,hourly; see build_bci_ed2in.R)
#
# --- Choosing which variables to extract (--variables, --sizeclass_variables) --
# By default this script extracts a fixed, curated set of ~23 ecosystem-scale
# variables and all 7 size-class variables (the same set it has always
# extracted). To extract a different subset (or add one not in the default
# set), pass a comma-separated list:
#
#   --variables=GPP,NPP,LeafTemp                circumscribed ecosystem-scale set
#   --sizeclass_variables=AGB,NPLANT             circumscribed size-class set
#
# --variables accepts either this script's own friendly column names (GPP,
# LeafTemp, SensibleAC, ... - see ECOSYSTEM_VAR_MAP below for the full list)
# or, for any _PY polygon-scale variable NOT in that curated list, the raw
# ED2 variable name exactly as it appears in variable_catalog.csv (see
# R-tools/describe_variables.R) with the resolution prefix optionally
# included or omitted (e.g. `ATM_TMP_PY` or `MMEAN_ATM_TMP_PY` both work at
# --resolution=monthly) - this script strips a leading MMEAN_/DMEAN_/FMEAN_
# and re-adds the correct one for whichever --resolution you asked for. Any
# requested variable that doesn't exist at all in the file becomes an
# all-NA column rather than an error (same fallback get_prefixed() has
# always used) - check variable_catalog.csv if a column comes back empty.
#
# --sizeclass_variables must be a subset of: LAI, AGB, NPLANT, Bstorage,
# BasalArea (native 17x11 arrays, any resolution) and GPP, NPP
# (cohort-aggregated, monthly-only - see the cohort-flux note below).
# Unlike --variables, this list is closed (not extensible to arbitrary raw
# names) since these 7 are the only PFT x size-class-shaped variables ED2
# writes.
#
# Run R-tools/describe_variables.R --site=BCI --exp=<id> first if you're not
# sure what raw variable names are available to add.
#
# --- How ED2's output resolution actually works (confirmed by inspecting
#     real output files, not assumed) --------------------------------------
# Each resolution writes its own file series with its own one-letter tag in
# the filename (ED/src/io/h5_output.F90's vnam): monthly = analysis-E-*.h5,
# daily = analysis-D-*.h5, hourly = analysis-I-*.h5 (packed: each daily file
# holds 24 hourly steps in one extra trailing array dimension, since
# build_bci_ed2in.R sets OUTFAST=-1 for hourly output).
#
# Ecosystem-scale flux/state variables use a resolution-specific prefix on
# the SAME base name: MMEAN_GPP_PY (monthly), DMEAN_GPP_PY (daily),
# FMEAN_GPP_PY (hourly). Not every variable has all three - e.g.
# FMEAN_BSTORAGE_PY does not exist (storage carbon has no hourly mean),
# confirmed by direct inspection - such gaps are simply reported as NA,
# not treated as an error.
#
# PFT x DBH-size-class arrays are DIFFERENT: AGB_PY/NPLANT_PY/BASAL_AREA_PY
# have NO prefix at any resolution (they're instantaneous snapshots, not
# time-means) and keep their (17 x 11) shape everywhere, just with an extra
# packed-hour dimension at hourly resolution. LAI/Bstorage are the odd ones
# out: at monthly resolution they're only exposed prefixed as MMEAN_LAI_PY/
# MMEAN_BSTORAGE_PY (true monthly time-means, (17 x 11) shaped); at daily/
# hourly resolution the SAME (17 x 11)-shaped quantity is instead exposed
# unprefixed as LAI_PY/BSTORAGE_PY (an instantaneous snapshot, not a time-
# mean) - confirmed directly: DMEAN_LAI_PY does not exist, but LAI_PY does.
# This script tries the unprefixed name first, falling back to the MMEAN_
# name, so the same code path works at every resolution - but be aware the
# monthly number is a true period mean while daily/hourly are point-in-time
# snapshots.
#
# Cohort-level GPP/NPP (needed for the size-class flux breakdown) is ONLY
# available at monthly resolution (MMEAN_GPP_CO/MMEAN_NPP_CO) - confirmed
# FMEAN_GPP_CO/DMEAN_GPP_CO do not exist. At daily/hourly resolution the
# size-class table's GPP/NPP columns are 0 (structural columns - AGB, LAI,
# NPLANT, Bstorage, BasalArea - are still fully populated).
#
# Why not PEcAn.ED2::model2netcdf.ED2()? That's the standard tool, but it
# fails here with a confirmed dplyr version incompatibility in its
# per-cohort/per-PFT reshaping step. This script reads the same HDF5 files
# directly instead.

library(hdf5r)
library(data.table)

.cli_args <- commandArgs(trailingOnly = TRUE)
.get_flag <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), .cli_args, value = TRUE)
  if (length(hit) == 0) return(default)
  sub(paste0("^--", name, "="), "", hit[1])
}
exp_id <- .get_flag("exp", "001_baseline")
resolution <- .get_flag("resolution", "monthly")
valid_res <- c("monthly", "daily", "hourly")
if (!(resolution %in% valid_res)) {
  stop("--resolution must be one of: ", paste(valid_res, collapse = ", "), " - got: ", resolution)
}

# Locate the repo root from this script's own path (portable - works on any
# machine/device, not tied to a specific home directory). See
# README.md's architecture section for why this matters.
.this_file <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1])
.this_dir <- dirname(normalizePath(.this_file))
.find_repo_root <- function(d) {
  for (i in 1:20) {
    if (file.exists(file.path(d, ".ed2_repo_root"))) return(d)
    parent <- dirname(d)
    if (parent == d) stop("Could not locate repo root (no .git found)")
    d <- parent
  }
  stop("Could not locate repo root (no .git found)")
}
repo_root <- .find_repo_root(.this_dir)
outdir <- file.path(repo_root, "sites/BCI/run/experiments", exp_id)
BCI_PFTS <- c(2L, 3L, 4L)
N_DBH <- 11L
DDBHI <- 0.1 # (n_dbh - 1) / maxdbh = 10 / 100 - see README.md for the idbh formula
size_class_labels <- c(sprintf("%d-%d", seq(0, 90, 10), seq(10, 100, 10)), ">100")

# =============================================================================
# Ecosystem-scale variable selection (--variables)
# =============================================================================
# Friendly output column name -> ED2 base variable name (without the
# resolution prefix - e.g. "GPP_PY", not "MMEAN_GPP_PY"). This is the
# curated default set (unchanged from before --variables existed); anything
# requested via --variables that isn't a key here is treated as a raw ED2
# base name instead (see get_prefixed(), which is generic over any _PY
# scalar regardless of whether it's in this table).
ECOSYSTEM_VAR_MAP <- c(
  GPP = "GPP_PY", NPP = "NPP_PY", PlantResp = "PLRESP_PY", HeteroResp = "RH_PY", NEP = "NEP_PY",
  Transp = "TRANSP_PY", ET = "VAPOR_AC_PY", FSW = "FSW_PY", FS_open = "FS_OPEN_PY",
  LeafWater = "LEAF_WATER_IM2_PY", WoodWater = "WOOD_WATER_IM2_PY",
  WfluxGW = "WFLUX_GW_PY", WfluxWL = "WFLUX_WL_PY", WaterSupply = "WATER_SUPPLY_PY",
  AvailableWater = "AVAILABLE_WATER_PY", LeafVPD = "LEAF_VPDEF_PY", CanVPD = "CAN_VPDEF_PY",
  SoilMoist = "SOIL_WATER_PY", # special: averaged across 16 soil layers (get_prefixed_soil_mean())
  LeafTemp = "LEAF_TEMP_PY", CanTemp = "CAN_TEMP_PY", SensibleAC = "SENSIBLE_AC_PY",
  Rnet = "RNET_PY", RshortAtm = "ATM_RSHORT_PY", RlongAtm = "ATM_RLONG_PY"
)
SOIL_MEAN_VARS <- c("SoilMoist") # column names needing get_prefixed_soil_mean(), not get_prefixed()

# Resolve a user's --variables tokens into a named vector (names = output
# column name, values = ED2 base variable name), falling back to treating
# an unrecognized token as a raw base name directly.
resolve_ecosystem_vars <- function(requested) {
  out_base <- character(length(requested))
  for (i in seq_along(requested)) {
    req <- requested[i]
    out_base[i] <- if (req %in% names(ECOSYSTEM_VAR_MAP)) {
      ECOSYSTEM_VAR_MAP[[req]]
    } else {
      sub("^(MMEAN_|DMEAN_|FMEAN_)", "", req) # tolerate a prefix if the user copied one from variable_catalog.csv
    }
  }
  setNames(out_base, requested)
}

variables_flag <- .get_flag("variables", "")
ecosystem_vars <- if (nzchar(variables_flag)) {
  resolve_ecosystem_vars(trimws(strsplit(variables_flag, ",")[[1]]))
} else {
  ECOSYSTEM_VAR_MAP
}

# =============================================================================
# Size-class variable selection (--sizeclass_variables)
# =============================================================================
SIZECLASS_STOCK_VARS <- c("LAI", "AGB", "NPLANT", "Bstorage", "BasalArea") # native (17x11) arrays
SIZECLASS_FLUX_VARS <- c("GPP", "NPP") # cohort-aggregated, monthly-only
SIZECLASS_RAW_NAME <- c(LAI = "LAI_PY", AGB = "AGB_PY", NPLANT = "NPLANT_PY",
                         Bstorage = "BSTORAGE_PY", BasalArea = "BASAL_AREA_PY")
ALL_SIZECLASS_VARS <- c(SIZECLASS_STOCK_VARS, SIZECLASS_FLUX_VARS)

sizeclass_variables_flag <- .get_flag("sizeclass_variables", "")
sizeclass_vars <- if (nzchar(sizeclass_variables_flag)) {
  req <- trimws(strsplit(sizeclass_variables_flag, ",")[[1]])
  invalid <- setdiff(req, ALL_SIZECLASS_VARS)
  if (length(invalid) > 0) {
    stop("--sizeclass_variables must be a subset of: ", paste(ALL_SIZECLASS_VARS, collapse = ", "),
         " - got invalid: ", paste(invalid, collapse = ", "))
  }
  req
} else {
  ALL_SIZECLASS_VARS
}
stock_vars_requested <- intersect(SIZECLASS_STOCK_VARS, sizeclass_vars)
flux_vars_requested <- intersect(SIZECLASS_FLUX_VARS, sizeclass_vars)

file_tag <- c(monthly = "E", daily = "D", hourly = "I")[[resolution]]
prefix <- c(monthly = "MMEAN_", daily = "DMEAN_", hourly = "FMEAN_")[[resolution]]
n_steps <- if (resolution == "hourly") 24L else 1L

cat("Experiment:", exp_id, " Resolution:", resolution, "(", outdir, ")\n")

files <- sort(list.files(outdir, pattern = sprintf("^analysis-%s-\\d{4}-\\d{2}-\\d{2}-\\d{6}-.*\\.h5$", file_tag),
                          full.names = TRUE))
if (length(files) == 0) {
  stop(
    "No analysis-", file_tag, "-*.h5 files found in ", outdir, " for --resolution=", resolution,
    " - was this experiment's ED2IN built with a matching --output_freq (see build_bci_ed2in.R)?"
  )
}
cat("Found", length(files), sprintf("%s output files.\n", resolution))
cat("Ecosystem-scale variables:", paste(names(ecosystem_vars), collapse = ", "), "\n")
cat("Size-class variables:", paste(sizeclass_vars, collapse = ", "), "\n")

# =============================================================================
# Shared helpers
# =============================================================================

# Ecosystem-scale scalar with the resolution-specific prefix. Returns a
# length-n_steps vector (all NA if the variable doesn't exist at this
# resolution - e.g. FMEAN_BSTORAGE_PY).
get_prefixed <- function(f, nms, base_name) {
  v <- paste0(prefix, base_name)
  if (!(v %in% nms)) return(rep(NA_real_, n_steps))
  x <- as.numeric(f[[v]]$read())
  length(x) <- n_steps # pads with NA or truncates defensively
  x
}

# Soil-layer mean, same prefix convention as get_prefixed() but averages
# across the 16-layer dimension first (dims: 16 x n_steps for hourly, 16 for
# daily/monthly).
get_prefixed_soil_mean <- function(f, nms, base_name) {
  v <- paste0(prefix, base_name)
  if (!(v %in% nms)) return(rep(NA_real_, n_steps))
  x <- f[[v]]$read()
  if (resolution == "hourly") {
    apply(matrix(x, nrow = length(x) / n_steps), 2, mean, na.rm = TRUE)
  } else {
    mean(as.numeric(x), na.rm = TRUE)
  }
}

# PFT x size-class array (17 x 11[ x n_steps]) - tries the unprefixed name
# first (AGB_PY/NPLANT_PY/BASAL_AREA_PY always; LAI_PY/BSTORAGE_PY at
# daily/hourly), falling back to the MMEAN_ name (LAI/BSTORAGE at monthly).
# Returns a list of n_steps data.tables, each (pft, size_class_id, value).
get_pft_sizeclass_array <- function(f, nms, unprefixed_name) {
  v <- if (unprefixed_name %in% nms) unprefixed_name else paste0(prefix, unprefixed_name)
  if (!(v %in% nms)) {
    return(replicate(n_steps, data.table(pft = integer(0), size_class_id = integer(0), value = numeric(0)), simplify = FALSE))
  }
  arr <- f[[v]]$read() # dims: (17, 11[, n_steps])
  lapply(seq_len(n_steps), function(step) {
    slice <- if (n_steps > 1) arr[, , step] else arr
    dt <- as.data.table(slice)
    setnames(dt, as.character(seq_len(N_DBH)))
    dt[, pft := seq_len(.N)]
    dt <- dt[pft %in% BCI_PFTS]
    dt <- melt(dt, id.vars = "pft", variable.name = "size_class_id", value.name = "value")
    dt[, size_class_id := as.integer(size_class_id)]
    dt
  })
}

# Cohort-level GPP/NPP (monthly only - MMEAN_GPP_CO/MMEAN_NPP_CO), aggregated
# into the same (pft, size_class) bins ED2 itself uses (confirmed against
# ED/src/utils/update_derived_utils.f90: idbh = max(1, min(11, ceiling(dbh *
# 0.1)))). Returns a one-element list (monthly is never packed/multi-step),
# or NA-filled bins if this resolution has no cohort fluxes.
get_cohort_flux_sizeclass <- function(f, nms) {
  has_cohort_flux <- all(c("PFT", "DBH", "NPLANT", "MMEAN_GPP_CO", "MMEAN_NPP_CO") %in% nms)
  if (!has_cohort_flux) {
    return(list(data.table(pft = integer(0), size_class_id = integer(0), GPP = numeric(0), NPP = numeric(0))))
  }
  co <- data.table(
    pft = f[["PFT"]]$read(), dbh = f[["DBH"]]$read(), nplant = f[["NPLANT"]]$read(),
    gpp_co = f[["MMEAN_GPP_CO"]]$read(), npp_co = f[["MMEAN_NPP_CO"]]$read()
  )
  co[, size_class_id := pmax(1L, pmin(N_DBH, as.integer(ceiling(dbh * DDBHI))))]
  list(co[, .(GPP = sum(nplant * gpp_co), NPP = sum(nplant * npp_co)), by = .(pft, size_class_id)])
}

# =============================================================================
# Read every file, building both the ecosystem-scale and size-class tables
# =============================================================================

ecosystem_rows <- list()
sizeclass_rows <- list()

for (path in files) {
  fname <- basename(path)
  m <- regmatches(fname, regexec("analysis-[A-Z]-(\\d{4})-(\\d{2})-(\\d{2})-(\\d{6})", fname))[[1]]
  year <- as.integer(m[2]); month <- as.integer(m[3])
  # Monthly files (analysis-E-*) use day "00" as a month marker, not a real
  # calendar day (confirmed: ED2 writes analysis-E-YYYY-MM-00-*.h5) - not a
  # valid as.POSIXct() date, so anchor monthly datetimes/the day column on
  # day 1 instead.
  file_day <- if (resolution == "monthly") 1L else as.integer(m[4])
  day <- file_day
  base_datetime <- as.POSIXct(sprintf("%s-%s-%02d 00:00:00", m[2], m[3], file_day), tz = "UTC")
  # Hourly files are packed: step i (1-indexed) is the mean over UTC hour
  # (i-1):00-i:00 of this file's date (confirmed against the diurnal
  # shortwave/GPP pattern - zero at night, peak near local midday, BCI is
  # UTC-5 so local midday ~17:00 UTC - not exhaustively traced through
  # Fortran source, but consistent across every variable checked).
  datetimes <- base_datetime + (seq_len(n_steps) - 1) * 3600

  f <- H5File$new(path, mode = "r")
  nms <- f$ls()$name

  # --- Ecosystem-scale (whichever variables --variables resolved to) -------
  row_dt <- data.table(datetime = datetimes, year = year, month = month, day = day)
  for (i in seq_along(ecosystem_vars)) {
    colname <- names(ecosystem_vars)[i]
    base_name <- ecosystem_vars[[i]]
    row_dt[[colname]] <- if (colname %in% SOIL_MEAN_VARS || base_name == "SOIL_WATER_PY") {
      get_prefixed_soil_mean(f, nms, base_name)
    } else {
      get_prefixed(f, nms, base_name)
    }
  }
  ecosystem_rows[[length(ecosystem_rows) + 1]] <- row_dt

  # --- PFT x size-class stocks + (monthly-only) cohort fluxes (whichever
  # variables --sizeclass_variables resolved to) ---------------------------
  base_grid <- CJ(pft = BCI_PFTS, size_class_id = seq_len(N_DBH))
  stock_steps <- lapply(stock_vars_requested, function(v) get_pft_sizeclass_array(f, nms, SIZECLASS_RAW_NAME[[v]]))
  names(stock_steps) <- stock_vars_requested
  cohort_flux_steps <- if (length(flux_vars_requested) > 0 && resolution == "monthly") get_cohort_flux_sizeclass(f, nms) else NULL

  for (step in seq_len(n_steps)) {
    merged <- copy(base_grid)
    for (v in stock_vars_requested) {
      tab <- copy(stock_steps[[v]][[step]])
      setnames(tab, "value", v)
      merged <- merge(merged, tab, by = c("pft", "size_class_id"), all.x = TRUE)
    }
    if (length(flux_vars_requested) > 0) {
      if (!is.null(cohort_flux_steps)) {
        flux_tab <- cohort_flux_steps[[step]][, c("pft", "size_class_id", flux_vars_requested), with = FALSE]
        merged <- merge(merged, flux_tab, by = c("pft", "size_class_id"), all.x = TRUE)
      } else {
        for (v in flux_vars_requested) merged[, (v) := NA_real_]
      }
    }
    merged[, `:=`(datetime = datetimes[step], year = year, month = month, day = day,
                  size_class = size_class_labels[size_class_id])]
    sizeclass_rows[[length(sizeclass_rows) + 1]] <- merged
  }

  f$close_all()
}

ecosystem_dt <- rbindlist(ecosystem_rows)
setorder(ecosystem_dt, datetime)

sizeclass_dt <- rbindlist(sizeclass_rows, fill = TRUE)
setcolorder(sizeclass_dt, c("datetime", "year", "month", "day", "pft", "size_class_id", "size_class"))
setorder(sizeclass_dt, datetime, pft, size_class_id)
num_cols <- intersect(c("LAI", "AGB", "NPLANT", "Bstorage", "BasalArea", "GPP", "NPP"), names(sizeclass_dt))
for (col in num_cols) sizeclass_dt[is.na(get(col)), (col) := 0]

# --- Ecosystem totals and by-PFT sums (summed over size class), derived
# from sizeclass_dt and merged into ecosystem_dt - plot_bci_output.R reads
# these for the stock-total lines and by-PFT matrices, while sizeclass_dt
# itself keeps the full PFT x size-class resolution for its own heatmaps.
# Only computed for whichever stock variables --sizeclass_variables
# actually resolved to (default: all four) - if e.g. Bstorage was excluded,
# there is simply no Bstorage_total/Bstorage_pft* column, and
# plot_bci_output.R skips the plots that need it.
totalable_stock_vars <- intersect(c("LAI", "AGB", "NPLANT", "Bstorage"), stock_vars_requested)
if (length(totalable_stock_vars) > 0) {
  stock_totals <- sizeclass_dt[, lapply(.SD, sum), by = datetime, .SDcols = totalable_stock_vars]
  setnames(stock_totals, totalable_stock_vars, paste0(totalable_stock_vars, "_total"))
  by_pft <- sizeclass_dt[, lapply(.SD, sum), by = .(datetime, pft), .SDcols = totalable_stock_vars]
  by_pft_wide <- dcast(by_pft, datetime ~ pft, value.var = totalable_stock_vars)
  setnames(by_pft_wide, setdiff(names(by_pft_wide), "datetime"),
           gsub("_(\\d)$", "_pft\\1", setdiff(names(by_pft_wide), "datetime")))
  ecosystem_dt <- merge(ecosystem_dt, stock_totals, by = "datetime", all.x = TRUE)
  ecosystem_dt <- merge(ecosystem_dt, by_pft_wide, by = "datetime", all.x = TRUE)
  setorder(ecosystem_dt, datetime)
} else {
  cat("No size-class stock variables requested (--sizeclass_variables) - skipping ecosystem-scale stock-total/by-PFT columns.\n")
}

cat("\nUnits are ED2's native output units (see ED/Doc/ for exact definitions;\n")
cat("*_PY fluxes are commonly kgC/m2/yr, AGB/LAI are stocks per m2/m2).\n")
cat("Cross-check against ED2's documentation before using these in a paper.\n\n")

out_eco_csv <- file.path(outdir, sprintf("timeseries_output_%s.csv", resolution))
out_eco_rds <- file.path(outdir, sprintf("timeseries_output_%s.rds", resolution))
fwrite(ecosystem_dt, out_eco_csv)
saveRDS(ecosystem_dt, out_eco_rds)
cat("Wrote", out_eco_csv, "\n")
cat("Wrote", out_eco_rds, "(for plot_bci_output.R)\n\n")

out_sc_csv <- file.path(outdir, sprintf("sizeclass_output_%s.csv", resolution))
out_sc_rds <- file.path(outdir, sprintf("sizeclass_output_%s.rds", resolution))
fwrite(sizeclass_dt, out_sc_csv)
saveRDS(sizeclass_dt, out_sc_rds)
cat("Wrote", out_sc_csv, "\n")
cat("Wrote", out_sc_rds, "(for plot_bci_output.R)\n\n")

if (resolution != "monthly") {
  cat("NOTE: GPP/NPP in", basename(out_sc_csv), "are 0 (not real data) - cohort-level\n")
  cat("fluxes are only available at monthly resolution (MMEAN_GPP_CO/MMEAN_NPP_CO);\n")
  cat("see this script's header. LAI/Bstorage here are instantaneous snapshots,\n")
  cat("not the monthly time-mean --resolution=monthly gives you.\n\n")
}

cat("--- Preview (ecosystem-scale) ---\n")
print(head(ecosystem_dt, 12))
