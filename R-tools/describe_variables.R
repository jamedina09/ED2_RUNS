#!/usr/bin/env Rscript
# Catalog every variable ED2 actually wrote to one of an experiment's
# output files (preferring monthly, falling back to daily/hourly/yearly -
# see below): name, HDF5 dimensions, what "kind" of variable it is
# (ecosystem scalar / PFT x size-class array / soil-layer array /
# per-cohort array / other), units and a plain-language description where
# known, and which extraction script (if any) already pulls it into a
# tidy table. This is the answer to "what output variables are there and
# what do they mean" - read this instead of re-deriving it from ED2's
# source or Doc/ each time. Note: the curated dictionary below documents
# monthly flux/state variables specifically (extract_bci_output.R's
# default set); if the file it actually opens is a yearly demographic
# census (see extract_bci_output.R's header for why that's a different
# variable set entirely), the shape-based classification in part 2 still
# works, but few of its variables will match the curated dictionary.
#
# Two layers:
#   1. A curated dictionary (below) of the ~40 variables the pipeline
#      actually uses (see extract_bci_output.R),
#      with real units/descriptions gathered from ED2's source and confirmed
#      against this pipeline's own output.
#   2. Everything else in the file gets auto-classified by shape alone
#      (scalar/_PY/_SI/_PA, 17x11 PFT-x-size-class, 16-layer soil array,
#      per-cohort array, or "other") - not individually described, but at
#      least you know what *kind* of thing it is and its exact dimensions
#      without re-reading Fortran source.
#
# This script is fully cross-site: it just introspects whatever HDF5 file
# ED2 wrote (dimensions/shape work identically at any site), so --site only
# needs to point it at the right sites/<site>/run/experiments/<exp>/ folder.
# The curated dictionary below documents this pipeline's BCI implementation
# as a worked example; the shape-based classification (§2) needs no
# per-site knowledge at all.
#
# Usage: Rscript R-tools/describe_variables.R --site=BCI --exp=<id>

library(hdf5r)
library(data.table)

.cli_args <- commandArgs(trailingOnly = TRUE)
.get_flag <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), .cli_args, value = TRUE)
  if (length(hit) == 0) return(default)
  sub(paste0("^--", name, "="), "", hit[1])
}
site <- .get_flag("site", "BCI")
exp_id <- .get_flag("exp", "001_baseline")

# Locate the repo root from this script's own path (portable - works on any
# machine/device, not tied to a specific home directory). See
# README.md's Repository Structure section (§3) for why this matters.
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
outdir <- file.path(repo_root, "sites", site, "run/experiments", exp_id)

# Prefer a monthly file (most aggregated, so richest set of MMEAN_ variables
# to catalog), falling back to daily/hourly/yearly in that order - a short
# run (e.g. a --restart_from continuation shorter than one month, see
# README §4.6) may not have crossed a month boundary yet and so has no
# analysis-E-*.h5; an experiment built with --output_freq=yearly only has
# analysis-Y-*.h5 at all (see README §6.3 for why yearly is a completely
# different variable set, not just a coarser monthly).
find_files <- function(tag) sort(list.files(outdir, pattern = sprintf("^analysis-%s-\\d{4}-\\d{2}-.*\\.h5$", tag), full.names = TRUE))
files_by_tag <- list(E = find_files("E"), D = find_files("D"), I = find_files("I"), Y = find_files("Y"))
chosen_tag <- names(files_by_tag)[vapply(files_by_tag, length, integer(1)) > 0][1]
if (is.na(chosen_tag)) {
  stop("No analysis-{E,D,I,Y}-*.h5 files found in ", outdir, " - has the model run yet?")
}
chosen_files <- files_by_tag[[chosen_tag]]
latest_file <- chosen_files[length(chosen_files)]
cat("Site:", site, " Experiment:", exp_id, "\n")
cat("Cataloging variables from:", basename(latest_file),
    "(most recent of", length(chosen_files),
    c(E = "monthly", D = "daily", I = "hourly", Y = "yearly")[[chosen_tag]], "files)\n\n")

# =============================================================================
# 1. Curated dictionary - variables this pipeline specifically knows about
# =============================================================================
# Uses base R's read.csv(), not data.table::fread(): fread(text=...)'s
# footer-autodetection silently discarded the last row here (a real bug
# hit and confirmed while building this script - read.csv() has no such
# heuristic).
curated <- as.data.table(read.csv(text = '
variable,units,description,extracted_by
MMEAN_GPP_PY,kgC/m2/yr,Gross primary productivity (ecosystem total),extract_bci_output.R
MMEAN_NPP_PY,kgC/m2/yr,Net primary productivity (ecosystem total),extract_bci_output.R
MMEAN_PLRESP_PY,kgC/m2/yr,Total plant (autotrophic) respiration,extract_bci_output.R
MMEAN_RH_PY,kgC/m2/yr,Heterotrophic (soil/litter decomposition) respiration,extract_bci_output.R
MMEAN_NEP_PY,kgC/m2/yr,Net ecosystem productivity (GPP - PlantResp - HeteroResp),extract_bci_output.R
MMEAN_TRANSP_PY,kg/m2/s,Plant transpiration,extract_bci_output.R
MMEAN_VAPOR_AC_PY,kg/m2/s,Net canopy<->atmosphere vapor flux (ecosystem evapotranspiration),extract_bci_output.R
MMEAN_FSW_PY,0-1,Water-availability limitation factor on stomatal opening,extract_bci_output.R
MMEAN_FS_OPEN_PY,0-1,Realized stomatal opening factor (light + water combined),extract_bci_output.R
MMEAN_LEAF_WATER_IM2_PY,kg/m2,Leaf water content,extract_bci_output.R
MMEAN_WOOD_WATER_IM2_PY,kg/m2,Wood (sapwood) water content,extract_bci_output.R
MMEAN_WFLUX_GW_PY,kg/m2/s,"Internal plant hydraulics: soil->wood water flux. Identically 0 when PLANT_HYDRO_SCHEME=0 - the cleanest diagnostic that dynamic hydraulics is active.",extract_bci_output.R
MMEAN_WFLUX_WL_PY,kg/m2/s,"Internal plant hydraulics: wood->leaf water flux. Identically 0 when PLANT_HYDRO_SCHEME=0.",extract_bci_output.R
MMEAN_WATER_SUPPLY_PY,kg/m2/s,Root water uptake supply term,extract_bci_output.R
MMEAN_AVAILABLE_WATER_PY,mm (approx.),Plant-available soil water,extract_bci_output.R
MMEAN_LEAF_VPDEF_PY,Pa,Leaf-level vapor pressure deficit,extract_bci_output.R
MMEAN_CAN_VPDEF_PY,Pa,Canopy-air-space vapor pressure deficit,extract_bci_output.R
MMEAN_SOIL_WATER_PY,m3/m3 (per soil layer - 16 layers),Volumetric soil moisture; extract_bci_output.R reports a simple unweighted mean across layers,extract_bci_output.R
MMEAN_LEAF_TEMP_PY,K,Leaf temperature,extract_bci_output.R
MMEAN_CAN_TEMP_PY,K,Canopy air space temperature,extract_bci_output.R
MMEAN_SENSIBLE_AC_PY,W/m2,Sensible heat flux (canopy -> atmosphere),extract_bci_output.R
MMEAN_RNET_PY,W/m2,Net radiation,extract_bci_output.R
MMEAN_ATM_RSHORT_PY,W/m2,Incoming shortwave radiation (met forcing as seen by the model),extract_bci_output.R
MMEAN_ATM_RLONG_PY,W/m2,Incoming longwave radiation (met forcing as seen by the model),extract_bci_output.R
AGB_PY,kgC/m2 (per PFT x size-class bin),Aboveground biomass,extract_bci_output.R
MMEAN_LAI_PY,m2/m2 (per PFT x size-class bin),Leaf area index,extract_bci_output.R
NPLANT_PY,plants/m2 (per PFT x size-class bin),Plant (stem) density,extract_bci_output.R
MMEAN_BSTORAGE_PY,kgC/m2 (per PFT x size-class bin),Non-structural (storage) carbon pool,extract_bci_output.R
BASAL_AREA_PY,m2/m2 (per PFT x size-class bin),Basal area,extract_bci_output.R
MMEAN_GPP_CO,kgC/plant/yr,"Per-cohort GPP (extensive, per plant - multiply by NPLANT to get an area-basis contribution). Aggregated into (PFT x size-class) bins by extract_bci_output.R.",extract_bci_output.R
MMEAN_NPP_CO,kgC/plant/yr,"Per-cohort NPP (extensive, per plant); same aggregation as MMEAN_GPP_CO.",extract_bci_output.R
PFT,integer 1-17,Per-cohort PFT number (2/3/4 = early/mid/late tropical successional here),extract_bci_output.R
DBH,cm,Per-cohort diameter at breast height,extract_bci_output.R
NPLANT,plants/m2,Per-cohort plant density (this is the cohort-level array; NPLANT_PY above is the PFT x size-class aggregate),extract_bci_output.R
SLZ,"m (negative, below ground)","Soil layer depths (16 layers, matches MMEAN_SOIL_WATER_PY dimension)",(reference only)
', stringsAsFactors = FALSE))

# =============================================================================
# 2. Introspect the actual HDF5 file and classify every variable by shape
# =============================================================================
f <- H5File$new(latest_file, mode = "r")
all_names <- sort(f$ls()$name)

# Reference lengths to recognize soil-layer and per-cohort arrays by shape.
n_cohorts <- if ("PFT" %in% all_names) length(f[["PFT"]]$read()) else NA_integer_
n_soil <- if ("SLZ" %in% all_names) length(f[["SLZ"]]$read()) else NA_integer_

classify_one <- function(v) {
  d <- f[[v]]$read()
  dims <- dim(d)
  dims_str <- if (is.null(dims)) as.character(length(d)) else paste(dims, collapse = " x ")
  n <- length(d)

  kind <- if (!is.null(dims) && length(dims) >= 2 && dims[1] == 17 && dims[2] == 11) {
    "PFT (17) x DBH size-class (11) array - native ED2 binning"
  } else if (n == 1) {
    if (grepl("_PY$", v)) "polygon-level scalar (_PY)"
    else if (grepl("_SI$", v)) "site-level scalar (_SI)"
    else if (grepl("_PA$", v)) "patch-level scalar (_PA, 1 patch in this run)"
    else "scalar"
  } else if (!is.na(n_soil) && n == n_soil && !grepl("_CO$", v)) {
    "soil-layer array (matches SLZ length)"
  } else if (!is.na(n_cohorts) && n == n_cohorts && n_cohorts > 1) {
    "per-cohort array (1 value per fused cohort this month; count varies month to month)"
  } else {
    "other / grid-bookkeeping - see ED2 source (ED/src/io/*.F90) or Doc/"
  }
  data.table(variable = v, hdf5_dims = dims_str, kind = kind)
}

shape_info <- rbindlist(lapply(all_names, classify_one))
f$close_all()

catalog <- merge(shape_info, curated, by = "variable", all.x = TRUE)
setorder(catalog, variable)
catalog[is.na(units), units := ""]
catalog[is.na(description), description := ""]
catalog[is.na(extracted_by), extracted_by := ""]

out_csv <- file.path(outdir, "variable_catalog.csv")
fwrite(catalog, out_csv)
cat("Wrote", out_csv, "(", nrow(catalog), "variables )\n\n")

cat("--- Summary by kind ---\n")
print(catalog[, .N, by = kind][order(-N)])

cat("\n--- Curated (documented) variables in this file ---\n")
print(catalog[description != "", .(variable, hdf5_dims, units, extracted_by)])
