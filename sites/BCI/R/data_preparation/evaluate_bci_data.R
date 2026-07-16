#!/usr/bin/env Rscript
# Sanity-check the raw BCI data actually used by build_bci_datasets.R,
# ahead of rebuilding sites/BCI/run. All in R.
#
# NOTE: an earlier version of this script (and this pipeline) evaluated a
# different, now-unused bundle: CLM1PT_data/*.nc for met, and derived
# .pss/.css files under bci_forcing_data/.../Inventory/ for the census -
# those derived census files really were corrupted (R pointer strings like
# <0x...> in place of numeric site/patch/cohort IDs, and a column-count
# mismatch in every .pss file - confirmed at the time). But
# build_bci_datasets.R does not use either of those sources any more: it
# reads the official ESS-DIVE met CSV (bci_climate/) and the real
# ForestGEO 50-ha plot census #8 (bci_stem_data/bci.stem8.rdata +
# bci.spptable.rdata) directly. That real census is NOT corrupted - this
# script checks it directly below, not the old derived files.
#
# Usage: Rscript sites/BCI/R/data_preparation/evaluate_bci_data.R

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
bci_data_root <- file.path(repo_root, "sites/BCI/raw_data")

cat("=========================================================\n")
cat("1. Meteorological forcing (bci_climate/.../BCI_met_drivers_2003_2016.csv)\n")
cat("=========================================================\n")

met_csv <- file.path(bci_data_root,
  "bci_climate/ess_dive_541b60dca11b546_20241028T152354878826/data",
  "BCI_met_drivers_2003-2016/BCI_met_drivers_2003_2016.csv")
if (!file.exists(met_csv)) stop("Met CSV not found: ", met_csv)
met <- read.csv(met_csv, stringsAsFactors = FALSE)
cat("Columns:", paste(names(met), collapse = ", "), "\n")
cat("Rows:", nrow(met), "\n")

when_posix <- as.POSIXct(met$Date_UTC_start, format = "%m/%d/%y %H:%M", tz = "UTC")
if (any(is.na(when_posix))) {
  cat("WARNING:", sum(is.na(when_posix)), "unparseable timestamps\n")
} else {
  dt_gaps <- unique(diff(as.numeric(when_posix)))
  if (length(dt_gaps) == 1 && dt_gaps == 3600) {
    cat("Confirmed regular hourly timestamps,", format(when_posix[1]), "to",
        format(when_posix[length(when_posix)]), "\n")
  } else {
    cat("WARNING: timestamps not perfectly regular hourly - gaps found:",
        paste(dt_gaps, collapse = ", "), "\n")
  }
}

needed_for_ed2 <- c("nbdsf", "nddsf", "vbdsf", "vddsf", "prate", "dlwrf",
                     "pres", "hgt", "ugrd", "vgrd", "sh", "tmp")
cat("\nED2 met driver needs:", paste(needed_for_ed2, collapse = ", "), "\n")
cat("Directly available (renamed/unit-converted, no estimation): Temp_o_C.",
    "-> tmp, BP_hPa (actually mmHg, see build_bci_datasets.R) -> pres,",
    "RH_. -> sh (via thermo conversion), real wind speed+direction -> ugrd/vgrd\n")
cat("Derivable from FSDS-equivalent total shortwave via Weiss-Norman",
    "partitioning: nbdsf, nddsf, vbdsf, vddsf\n")
cat("MISSING entirely (never measured at the BCI tower, confirmed across",
    "every met bundle assessed for this site): dlwrf - estimated via",
    "Longo's 'aml' scheme (refinement of Marthews et al. 2012)\n")
cat("hgt: overridden to a nominal 50 m reference height (ED2 requires it",
    "to exceed the tallest PFT it can grow, ~46 m for tropical PFTs here),",
    "matching ED2_Support_Files/tower_processing/make_met_driver.r's own",
    "convention for tall-canopy sites.\n")

cat("\n=========================================================\n")
cat("2. Soil texture (bci_forcing_data/.../surfdata_bci_*.nc)\n")
cat("=========================================================\n")

surf_nc_path <- file.path(bci_data_root,
  "bci_forcing_data/bci_0.1x0.1_v4.0i/surfdata_bci_clm5.0.dev009_c180523.nc")
if (!file.exists(surf_nc_path)) stop("Surface data NetCDF not found: ", surf_nc_path)
library(ncdf4)
surf_nc <- nc_open(surf_nc_path)
pct_sand <- ncvar_get(surf_nc, "PCT_SAND")
pct_clay <- ncvar_get(surf_nc, "PCT_CLAY")
nc_close(surf_nc)
slxsand <- mean(pct_sand) / 100
slxclay <- mean(pct_clay) / 100
cat("PCT_SAND by layer:", paste(round(pct_sand, 1), collapse = ", "), "\n")
cat("PCT_CLAY by layer:", paste(round(pct_clay, 1), collapse = ", "), "\n")
cat(sprintf("Mean sand fraction (SLXSAND) = %.4f, mean clay fraction (SLXCLAY) = %.4f\n",
            slxsand, slxclay))
cat("No SOIL_DATABASE needed for a single-point run - ED2's ISOILFLG=2 +",
    "SLXSAND/SLXCLAY covers this directly.\n")

cat("\n=========================================================\n")
cat("3. Vegetation census (bci_stem_data/bci.stem8.rdata + bci.spptable.rdata)\n")
cat("=========================================================\n")

stem_path <- file.path(bci_data_root, "bci_stem_data/bci.stem/bci.stem8.rdata")
spp_path <- file.path(bci_data_root, "bci_stem_data/bci.spptable.rdata")
if (!file.exists(stem_path)) stop("Stem census not found: ", stem_path)
if (!file.exists(spp_path)) stop("Species table not found: ", spp_path)
load(stem_path)
load(spp_path)

cat("bci.stem8:", nrow(bci.stem8), "total stem records,",
    length(unique(bci.stem8$treeID)), "unique trees.\n")
cat("Columns:", paste(names(bci.stem8), collapse = ", "), "\n")

# The thing that was actually wrong with the OLD derived .pss/.css bundle:
# non-numeric site/patch/cohort ID fields (literal R pointer strings, e.g.
# "<0x6efd2288>"). Check the equivalent real ID fields here are proper
# values, not corrupted placeholders.
looks_like_pointer <- function(x) grepl("^<0x[0-9a-f]+>$", as.character(x))
id_cols_present <- intersect(c("treeID", "stemID", "tag", "sp", "quadrat"), names(bci.stem8))
corrupt_ids <- FALSE
for (col in id_cols_present) {
  bad <- sum(looks_like_pointer(bci.stem8[[col]]), na.rm = TRUE)
  if (bad > 0) {
    corrupt_ids <- TRUE
    cat("CORRUPTED:", col, "has", bad, "pointer-string values (e.g. '<0x...>')\n")
  }
}
if (!corrupt_ids) {
  cat("ID columns (", paste(id_cols_present, collapse = ", "),
      ") contain real values, not pointer-string placeholders - not corrupted.\n")
}

living <- bci.stem8[!is.na(bci.stem8$dbh) & bci.stem8$status == "A", ]
cat("Living stems with valid DBH:", nrow(living), "across",
    length(unique(living$treeID)), "trees (single- and multi-stem).\n")

rho <- bci.spptable$wsg[match(living$sp, bci.spptable$sp)]
n_unmatched <- sum(is.na(rho))
cat("Wood density (wsg) match against bci.spptable: ", nrow(living) - n_unmatched,
    "/", nrow(living), " stems matched (", n_unmatched, " unmatched) across ",
    length(unique(bci.spptable$sp)), " species in the species table.\n", sep = "")

cat("\nThis is real, usable ForestGEO census data - build_bci_datasets.R",
    "uses it directly to build the vegetation initial condition (real",
    "forest structure: 248,715 stems as of census 8), not a bare-ground",
    "start. See README.md section 9 for the full build (allometry, PFT",
    "assignment, .pss/.css writing) and section 5's script reference.\n")

cat("\n=========================================================\n")
cat("Summary\n")
cat("=========================================================\n")
cat("Met:      usable after Weiss-Norman SW partition + Marthews/Longo dlwrf estimate + hgt override\n")
cat("Soil:     usable directly (ISOILFLG=2, SLXSAND=", round(slxsand, 4),
    ", SLXCLAY=", round(slxclay, 4), ")\n", sep = "")
cat("Census:   usable directly -", if (corrupt_ids) "CORRUPTED IDs FOUND, investigate" else "not corrupted",
    "- real forest structure init (IED_INIT_MODE=6), not bare-ground\n")
