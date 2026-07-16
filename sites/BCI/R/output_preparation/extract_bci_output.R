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

  # --- Ecosystem-scale ------------------------------------------------------
  soil_water <- get_prefixed_soil_mean(f, nms, "SOIL_WATER_PY")
  ecosystem_rows[[length(ecosystem_rows) + 1]] <- data.table(
    datetime = datetimes, year = year, month = month, day = day,

    GPP        = get_prefixed(f, nms, "GPP_PY"),
    NPP        = get_prefixed(f, nms, "NPP_PY"),
    PlantResp  = get_prefixed(f, nms, "PLRESP_PY"),
    HeteroResp = get_prefixed(f, nms, "RH_PY"),
    NEP        = get_prefixed(f, nms, "NEP_PY"),

    Transp        = get_prefixed(f, nms, "TRANSP_PY"),
    ET            = get_prefixed(f, nms, "VAPOR_AC_PY"),
    FSW           = get_prefixed(f, nms, "FSW_PY"),
    FS_open       = get_prefixed(f, nms, "FS_OPEN_PY"),
    LeafWater     = get_prefixed(f, nms, "LEAF_WATER_IM2_PY"),
    WoodWater     = get_prefixed(f, nms, "WOOD_WATER_IM2_PY"),
    WfluxGW       = get_prefixed(f, nms, "WFLUX_GW_PY"),
    WfluxWL       = get_prefixed(f, nms, "WFLUX_WL_PY"),
    WaterSupply   = get_prefixed(f, nms, "WATER_SUPPLY_PY"),
    AvailableWater = get_prefixed(f, nms, "AVAILABLE_WATER_PY"),
    LeafVPD       = get_prefixed(f, nms, "LEAF_VPDEF_PY"),
    CanVPD        = get_prefixed(f, nms, "CAN_VPDEF_PY"),
    SoilMoist     = soil_water,

    LeafTemp   = get_prefixed(f, nms, "LEAF_TEMP_PY"),
    CanTemp    = get_prefixed(f, nms, "CAN_TEMP_PY"),
    SensibleAC = get_prefixed(f, nms, "SENSIBLE_AC_PY"),
    Rnet       = get_prefixed(f, nms, "RNET_PY"),
    RshortAtm  = get_prefixed(f, nms, "ATM_RSHORT_PY"),
    RlongAtm   = get_prefixed(f, nms, "ATM_RLONG_PY")
  )

  # --- PFT x size-class stocks + (monthly-only) cohort fluxes --------------
  lai_steps <- get_pft_sizeclass_array(f, nms, "LAI_PY")
  agb_steps <- get_pft_sizeclass_array(f, nms, "AGB_PY")
  nplant_steps <- get_pft_sizeclass_array(f, nms, "NPLANT_PY")
  bstorage_steps <- get_pft_sizeclass_array(f, nms, "BSTORAGE_PY")
  basal_steps <- get_pft_sizeclass_array(f, nms, "BASAL_AREA_PY")
  cohort_flux_steps <- if (resolution == "monthly") get_cohort_flux_sizeclass(f, nms) else NULL

  for (step in seq_len(n_steps)) {
    setnames(lai_steps[[step]], "value", "LAI")
    setnames(agb_steps[[step]], "value", "AGB")
    setnames(nplant_steps[[step]], "value", "NPLANT")
    setnames(bstorage_steps[[step]], "value", "Bstorage")
    setnames(basal_steps[[step]], "value", "BasalArea")
    merged <- Reduce(function(a, b) merge(a, b, by = c("pft", "size_class_id"), all = TRUE),
                      list(lai_steps[[step]], agb_steps[[step]], nplant_steps[[step]],
                           bstorage_steps[[step]], basal_steps[[step]]))
    if (!is.null(cohort_flux_steps)) {
      merged <- merge(merged, cohort_flux_steps[[step]], by = c("pft", "size_class_id"), all = TRUE)
    } else {
      merged[, `:=`(GPP = NA_real_, NPP = NA_real_)]
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
num_cols <- c("LAI", "AGB", "NPLANT", "Bstorage", "BasalArea", "GPP", "NPP")
for (col in num_cols) sizeclass_dt[is.na(get(col)), (col) := 0]

# --- Ecosystem totals and by-PFT sums (summed over size class), derived
# from sizeclass_dt and merged into ecosystem_dt - plot_bci_output.R reads
# these for the stock-total lines and by-PFT matrices, while sizeclass_dt
# itself keeps the full PFT x size-class resolution for its own heatmaps.
stock_totals <- sizeclass_dt[, .(LAI_total = sum(LAI), AGB_total = sum(AGB),
                                  NPLANT_total = sum(NPLANT), Bstorage_total = sum(Bstorage)),
                              by = datetime]
by_pft <- sizeclass_dt[, .(LAI = sum(LAI), AGB = sum(AGB), NPLANT = sum(NPLANT), Bstorage = sum(Bstorage)),
                        by = .(datetime, pft)]
by_pft_wide <- dcast(by_pft, datetime ~ pft, value.var = c("LAI", "AGB", "NPLANT", "Bstorage"))
setnames(by_pft_wide, setdiff(names(by_pft_wide), "datetime"),
         gsub("_(\\d)$", "_pft\\1", setdiff(names(by_pft_wide), "datetime")))
ecosystem_dt <- merge(ecosystem_dt, stock_totals, by = "datetime", all.x = TRUE)
ecosystem_dt <- merge(ecosystem_dt, by_pft_wide, by = "datetime", all.x = TRUE)
setorder(ecosystem_dt, datetime)

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
