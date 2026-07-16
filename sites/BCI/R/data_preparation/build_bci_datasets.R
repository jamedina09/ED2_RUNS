#!/usr/bin/env Rscript
# Build ALL of the BCI ED2 run inputs (met driver, soil texture, vegetation
# initial condition) in one script, in R, reusing the ED2 lab's own physics
# and allometry functions (R-utils/, ED2_Support_Files/) wherever possible.
#
# Inputs (all real, raw data - see README.md for the full
# assessment of each):
#   - BCI/raw_data/bci_climate/.../BCI_met_drivers_2003_2016.csv
#     Official QA/QC'd BCI tower met (Faybishenko/Knox/Chambers et al., LBNL/
#     STRI, ESS-DIVE). Hourly, 2003-2016, real wind direction, real flags.
#   - BCI/raw_data/bci_forcing_data/.../surfdata_bci_clm5.0.dev009_c180523.nc
#     CLM5 surface data - used only for PCT_SAND/PCT_CLAY (soil texture).
#   - BCI/raw_data/bci_stem_data/bci.stem/bci.stem8.rdata
#     ForestGEO BCI 50-ha plot census #8 (most recent), stem-level.
#   - BCI/raw_data/bci_stem_data/bci.spptable.rdata
#     Species table with wood specific gravity (wsg) - used directly (not
#     BIOMASS::getWoodDensity()) per instruction.
#
# Outputs, all under sites/BCI/run/:
#   met/*.h5, met/ED_MET_DRIVER_HEADER   - met driver
#   init/BCI.lat9.153lon-79.8461.pss     - vegetation patch file
#   init/BCI.lat9.153lon-79.8461.css     - vegetation cohort file
#   (soil texture is printed for direct entry into ED2IN as SLXSAND/SLXCLAY -
#   ISOILFLG=2 needs no file)
#
# Usage: Rscript sites/BCI/R/data_preparation/build_bci_datasets.R

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

source(file.path(repo_root, "sites/BCI/R/data_preparation/lib_load_utils.R"))
source(file.path(repo_root, "ED2_Support_Files-master/pss+css_processing/allometry.r"))

library(ncdf4)
library(hdf5r)

bci_data_root <- file.path(repo_root, "sites/BCI/raw_data")
run_dir <- file.path(repo_root, "sites/BCI/run")
met_dir <- file.path(run_dir, "met")
init_dir <- file.path(run_dir, "init")
dir.create(met_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(init_dir, recursive = TRUE, showWarnings = FALSE)

LON <- -79.8461
LAT <- 9.153

cat("=========================================================\n")
cat("1. Meteorological driver\n")
cat("=========================================================\n")

met_csv <- file.path(bci_data_root,
  "bci_climate/ess_dive_541b60dca11b546_20241028T152354878826/data",
  "BCI_met_drivers_2003-2016/BCI_met_drivers_2003_2016.csv")
met <- read.csv(met_csv, stringsAsFactors = FALSE)

when_posix <- as.POSIXct(met$Date_UTC_start, format = "%m/%d/%y %H:%M", tz = "UTC")
stopifnot(!any(is.na(when_posix)))
dt_gaps <- unique(diff(as.numeric(when_posix)))
if (length(dt_gaps) != 1 || dt_gaps != 3600) {
  stop("Met CSV timestamps are not perfectly regular hourly - found gaps: ",
       paste(dt_gaps, collapse = ", "))
}
cat("Confirmed regular hourly timestamps,", nrow(met), "rows,",
    format(when_posix[1]), "to", format(when_posix[length(when_posix)]), "\n")

month_v <- as.integer(format(when_posix, "%m"))
day_v <- as.integer(format(when_posix, "%d"))
year_v <- as.integer(format(when_posix, "%Y"))
hour_v <- as.integer(format(when_posix, "%H"))
when_chron <- chron::chron(paste(month_v, day_v, year_v, sep = "/"),
                            paste(hour_v, 0, 0, sep = ":"))

zen <- ed.zen(lon = LON, lat = LAT, when = when_chron, ed21 = TRUE,
              zeronight = TRUE, meanval = FALSE)
cosz <- zen$cosz

atm.tmp <- met$Temp_o_C. + 273.15
# NOTE: despite its name, BP_hPa is actually in mmHg, not hPa - confirmed by
# cross-checking against the independent CLM1PT-derived PSRF values used in
# an earlier version of this pipeline (BCI/raw_data/bci_forcing_data):
# BP_hPa * 133.322 matches those Pa values almost exactly (e.g. 754.76 mmHg
# -> 100626 Pa, vs. CLM1PT's 100626.59 Pa for the same hour), whereas
# BP_hPa * 100 (treating it as real hPa) gives ~75476 Pa - about 25% too low
# and physically implausible for BCI's ~150 m elevation (expected ~995-1010
# hPa; 753 hPa would imply ~2400 m elevation).
atm.prss <- met$BP_hPa * 133.322  # mmHg -> Pa
atm.rhv <- met$RH_. / 100
# Specific humidity from RH, T, P (no direct sh column in this dataset).
esat <- 611.2 * exp(17.67 * (atm.tmp - 273.15) / (atm.tmp - 29.65))  # saturation vapor pressure [Pa]
atm.pvap <- atm.rhv * esat
atm.shv <- 0.622 * atm.pvap / (atm.prss - 0.378 * atm.pvap)
rshort.in <- met$SR_W_m2.
rain <- met$RA_mm_d / 3600  # mm/hr -> mm/s == kg/m2/s

# Wind decomposition using REAL wind direction (WD_deg) - R-utils convention
# (matches ED2_Support_Files/tower_processing/make_met_driver.r exactly).
trigo <- (270. - met$WD_deg) * pio180
atm.uspd <- met$WS_m_s * cos(trigo)
atm.vspd <- met$WS_m_s * sin(trigo)

# Weiss & Norman (1985) shortwave partitioning (R-utils/rshort.bdown.r)
rad <- rshort.bdown(rad.in = rshort.in, atm.prss = atm.prss, cosz = cosz)

# Downward longwave: Longo "aml" scheme (marthews.rlong.r), defaults (no
# local longwave observations to calibrate against - BCI's tower has never
# measured it, confirmed across both the CLM1PT and this official QA/QC'd
# dataset).
atm.ph2o <- 4.65 * atm.pvap / atm.tmp
highsun <- cosz > cosz.min
kappa <- rshort.in / pmax(rshort.in, solar * cosz)
kappa[!highsun] <- NA
kappa <- zoo::na.approx(kappa, na.rm = FALSE)
kappa <- zoo::na.locf(kappa, na.rm = FALSE)
kappa <- zoo::na.locf(kappa, fromLast = TRUE, na.rm = FALSE)
kappa <- pmin(1, pmax(0, kappa))

atm.theta <- atm.tmp * (p00 / atm.prss)^rocp
lcl <- lcl.il(thil = atm.theta, pres = atm.prss, temp = atm.tmp,
              hum = atm.pvap, type.hum = "pvap")
atm.tlcl <- lcl$temp

AML_COEFS <- c(0.7161, 0.02572, -46.63, 9.205, -0.500, 0.324)
rlong_datum <- list(atm.ph2o = atm.ph2o, kappa = kappa, atm.tlcl = atm.tlcl,
                     atm.rhv = atm.rhv, atm.tmp = atm.tmp)
dlwrf <- rlong.in.mmi.predict(x = AML_COEFS, scheme = "aml", datum = rlong_datum)$rlong.in

out_vars <- list(
  nbdsf = rad$nir.beam, nddsf = rad$nir.diff,
  vbdsf = rad$par.beam, vddsf = rad$par.diff,
  prate = rain, dlwrf = dlwrf,
  pres = atm.prss, ugrd = atm.uspd, vgrd = atm.vspd,
  sh = atm.shv, tmp = atm.tmp
)
bad <- vapply(out_vars, function(v) any(!is.finite(v)), logical(1))
if (any(bad)) stop("Non-finite values in: ", paste(names(bad)[bad], collapse = ", "))

ym <- format(when_posix, "%Y-%m")
month_abb_upper <- toupper(month.abb)
for (ym_i in unique(ym)) {
  sel <- ym == ym_i
  yr <- as.integer(substr(ym_i, 1, 4))
  mo <- as.integer(substr(ym_i, 6, 7))
  fname <- sprintf("%04d%s.h5", yr, month_abb_upper[mo])
  fpath <- file.path(met_dir, fname)
  if (file.exists(fpath)) file.remove(fpath)
  f <- H5File$new(fpath, mode = "w")
  for (name in names(out_vars)) {
    # Dimension order is (time, nlon, nlat) - NOT (nlat, nlon, time). Verified
    # against two independent known-working references read with hdf5r:
    # EDTS_run/umbs/met/1995JAN.h5 (built with Python/h5py) and
    # data/ED2_example_Harvard-main/input_harvard/met_driver/
    # HF_MET_1999JAN.h5 both report dims as (ntime, 1, 1) via hdf5r. R and
    # Fortran are both column-major (unlike Python/h5py, row-major), so
    # hdf5r needs the time axis first for ED2's Fortran reader to see the
    # dimensions in the order it expects (idims(1)=ntime, idims(2)=nlon,
    # idims(3)=nlat) - writing (1, 1, ntime) here (nlat/nlon first, as a
    # direct translation of the Python version's array shape) silently
    # produces a transposed dataset and ED2 fails with "Mismatch between
    # dataset and specified input".
    f[[name]] <- array(out_vars[[name]][sel], dim = c(sum(sel), 1, 1))
  }
  f$close_all()
}
cat("Wrote", length(unique(ym)), "monthly met driver files to", met_dir, "\n")

# Header: 7-line-per-format block matching ED/src/driver/ed_met_driver.f90.
# met_avgtype = 2 ("average starting at the reference time") - the QAQC
# report confirms each row is the mean over [Date_UTC_start, Date_UTC_end).
# hgt and co2 are flag-4 constants (not stored as datasets), following
# ED2_Support_Files/tower_processing/make_met_driver.r's convention. hgt is
# overridden to 50 m (well above the ~46 m max height ED2 allows tropical
# PFTs to reach) since there's no reason to believe any particular sensor
# height would be safely above canopy for a >30-year climatology.
HGT_REF <- 50
header_lines <- c(
  "'BCI: Barro Colorado Island, Panama - official QA/QC met (Faybishenko/Knox/Chambers et al.), built in R with ED2-lab physics'",
  "1",
  "met/",
  paste(1, 1, 1, 1, LON, LAT),
  "2",
  "13",
  "nbdsf nddsf vbdsf vddsf prate dlwrf pres hgt ugrd vgrd sh tmp co2",
  paste(3600, 3600, 3600, 3600, 3600, 3600, 3600, HGT_REF, 3600, 3600, 3600, 3600, 380),
  "1 1 1 1 0 1 1 4 1 1 1 1 4"
)
writeLines(header_lines, file.path(met_dir, "ED_MET_DRIVER_HEADER"))
cat("Wrote ED_MET_DRIVER_HEADER\n")

cat("\n=========================================================\n")
cat("2. Soil texture\n")
cat("=========================================================\n")

surf_nc_path <- file.path(bci_data_root,
  "bci_forcing_data/bci_0.1x0.1_v4.0i/surfdata_bci_clm5.0.dev009_c180523.nc")
surf_nc <- nc_open(surf_nc_path)
slxsand <- mean(ncvar_get(surf_nc, "PCT_SAND")) / 100
slxclay <- mean(ncvar_get(surf_nc, "PCT_CLAY")) / 100
nc_close(surf_nc)
cat(sprintf("SLXSAND = %.4f, SLXCLAY = %.4f (ISOILFLG=2, no database file needed)\n",
            slxsand, slxclay))

cat("\n=========================================================\n")
cat("3. Vegetation initial condition (census -> pss/css)\n")
cat("=========================================================\n")

load(file.path(bci_data_root, "bci_stem_data/bci.stem/bci.stem8.rdata"))
load(file.path(bci_data_root, "bci_stem_data/bci.spptable.rdata"))

stems <- bci.stem8[!is.na(bci.stem8$dbh) & bci.stem8$status == "A", ]
cat("Living stems with valid DBH:", nrow(stems), "across",
    length(unique(stems$treeID)), "trees (single- and multi-stem)\n")

stems$rho <- bci.spptable$wsg[match(stems$sp, bci.spptable$sp)]
if (any(is.na(stems$rho))) {
  stop(sum(is.na(stems$rho)), " stems have no wood density match - aborting")
}

# PFT assignment by wood-density breakpoints, exactly as
# ED2_Support_Files/pss+css_processing/make_bioinit.r does.
iallom <<- 2
pft_table <- read.csv(file.path(repo_root, "ED2_Support_Files-master/pss+css_processing/pft_allom_table.csv"),
                       stringsAsFactors = FALSE)
pft_table <- pft_table[pft_table$iallom == iallom, ]
pft_table <- pft_table[order(pft_table$ipft), ]
pft <<- pft_table
C2B <<- 2.0

pft.idx <- c(2, 3, 4)
pft.mid.rho <- pft$rho[match(pft.idx, pft$ipft)]
npft <- length(pft.mid.rho)
pft.brks <- c(-Inf, 0.5 * (pft.mid.rho[-1] + pft.mid.rho[-npft]), Inf)
stems$pft <- pft.idx[as.numeric(cut(stems$rho, pft.brks))]
cat("PFT assignment (wood density breakpoints", paste(round(pft.brks[2:3], 3), collapse = ", "), "):\n")
print(table(stems$pft))

PLOT_AREA_M2 <- 1000 * 500  # BCI 50-ha ForestGEO plot
stems$dbh_cm <- stems$dbh / 10  # mm -> cm
stems$n <- 1 / PLOT_AREA_M2
stems$height <- dbh2h(dbh = stems$dbh_cm, ipft = stems$pft)
stems$balive <- size2ba(dbh = stems$dbh_cm, hgt = stems$height, ipft = stems$pft)
stems$bdead <- size2bd(dbh = stems$dbh_cm, hgt = stems$height, ipft = stems$pft)
stems$lai <- size2lai(dbh = stems$dbh_cm, hgt = stems$height, nplant = stems$n, ipft = stems$pft)

# Single patch representing the whole plot (old-growth, undisturbed: trk=2).
# Soil carbon pool values are illustrative defaults (no BCI-specific
# measurements available), following the same approach
# ED2_Support_Files/pss+css_processing/make_bioinit.r takes for its example
# site ("from a previous simulation").
fast.soil.c <- 0.1495; struct.soil.c <- 6.126; struct.soil.l <- 6.126
slow.soil.c <- 4.546; min.soil.n <- 0.639; fast.soil.n <- 0.00348
YEAR_OUT <- 2015  # census 8 measurement year

# NOTE: the lat portion of the filename is deliberately an INTEGER (no
# decimal point), while lon keeps its decimal. Confirmed by direct testing
# against the compiled ED2 binary: ED2's C-level file-glob matching
# (ed_filelist.F90 -> utils_c.c's filelist_c_) fails to find the file (silent
# "0 files found", no crash) when BOTH lat and lon have a decimal point in
# the filename, but works when only one of them does. ed1_fileinfo's
# lat/lon-parsing step (ed_filelist.F90) separately requires a decimal point
# in the LON value specifically (its "extra dot" detection logic uses the
# lon value's own decimal as a reference point) - so lon must keep its
# decimal, and lat is the one that must drop it. The precise POI_LAT (9.153)
# is still used for the ED2IN NL%POI_LAT that drives the simulation -
# rounding this filename tag to an integer only affects the (here: trivial,
# single-file) nearest-neighbour file-matching step, not simulation
# coordinates.
outprefix <- sprintf("BCI.lat%.0flon%.3f", LAT, LON)
pss_file <- file.path(init_dir, paste0(outprefix, ".pss"))
css_file <- file.path(init_dir, paste0(outprefix, ".css"))

ncohorts <- nrow(stems)
outcohorts <- data.frame(
  time = sprintf("%4.4i", rep(YEAR_OUT, ncohorts)),
  patch = sprintf("0x%3.3X", 1),
  cohort = sprintf("0x%6.6X", seq_len(ncohorts)),
  dbh = sprintf("%9.3f", stems$dbh_cm),
  hite = sprintf("%9.3f", stems$height),
  pft = sprintf("%5i", stems$pft),
  n = sprintf("%15.8f", stems$n),
  bdead = sprintf("%9.3f", stems$bdead),
  balive = sprintf("%9.3f", stems$balive),
  # This column is read into Fortran's "avgRg" and never actually used
  # (ED/src/io/ed_read_ed10_20_history.f90 case(2,6)) - named to match the
  # convention in data/ED2_example_Harvard-main/input_harvard/
  # biometry/*.css (verified against a real, working reference file), even
  # though we still store per-cohort LAI here since the value itself is
  # otherwise discarded either way.
  avgRg = sprintf("%10.4f", stems$lai)
)
write.table(outcohorts, css_file, append = FALSE, quote = FALSE, sep = " ",
            row.names = FALSE, col.names = TRUE)

outpatches <- list(
  time = sprintf("%4.4i", YEAR_OUT), patch = sprintf("0x%3.3X", 1),
  trk = sprintf("%5i", 2), age = sprintf("%6.1f", 100),
  area = sprintf("%9.7f", 1), water = sprintf("%5i", 0),
  fsc = sprintf("%10.5f", fast.soil.c), stsc = sprintf("%10.5f", struct.soil.c),
  stsl = sprintf("%10.5f", struct.soil.l), ssc = sprintf("%10.5f", slow.soil.c),
  # Read into Fortran's "dummy"/psc slot and never used (same source as
  # above) - named "psc" to match the Harvard reference file's convention.
  psc = sprintf("%10.5f", sum(stems$lai)),
  msn = sprintf("%10.5f", min.soil.n), fsn = sprintf("%10.5f", fast.soil.n)
)
write.table(outpatches, pss_file, append = FALSE, quote = FALSE, sep = " ",
            row.names = FALSE, col.names = TRUE)

cat("Wrote", css_file, "(", ncohorts, "cohorts)\n")
cat("Wrote", pss_file, "(1 patch, plot-level LAI =", round(sum(stems$lai), 2), ")\n")

# WORKAROUND for a confirmed ED2 bug in ed_filelist.F90/utils_c.c's
# filelist_c_ (the C routine that globs a directory for files matching
# SFILIN's prefix). Root cause, pinned down precisely by direct testing
# against the compiled binary (see README.md for the full
# derivation): scandir() returns entries alphabetically, and filelist_c_
# always mishandles the first TWO real (non "."/"..") entries in that
# sorted list, REGARDLESS of whether they match the search prefix - e.g.
# with only our 2 real files present, both get silently dropped ("0 files
# found"); with 1 unrelated file added first alphabetically, exactly 1 of
# our 2 real files is dropped; with 2 unrelated files added first
# alphabetically, both real files are found correctly. This was verified
# independently on both this BCI dataset and the unrelated Harvard Forest
# reference example, and confirmed NOT to depend on filename content,
# decimal points, or total directory entry count in general - specifically
# on there being >=2 *other* directory entries that sort alphabetically
# before our target files (our files start with uppercase "B", so any name
# starting with a digit or another early letter works).
#
# Two tiny placeholder files (not a duplicated 23 MB dataset, as an earlier
# version of this workaround used) are the minimal fix: their names just
# need to sort before "BCI.lat9lon-79.846.*". They are never read by ED2 -
# ed1_fileinfo still requires an exact prefix match to actually use a file,
# it just needs *something* else present first for its internal indexing
# not to misfire.
placeholder_dir <- init_dir
writeLines(
  "This file intentionally left non-empty. See README.md
   section on the ED2 filelist_c_ bug: ED2 requires at least two other
   directory entries that sort alphabetically before the real
   BCI.lat9lon-79.846.pss/.css files, or it silently fails to find them.
   This file (and its sibling) are never read by ED2 - they only exist to
   satisfy that ordering requirement. Do not remove without also removing
   its sibling, or without re-verifying the workaround is still needed
   against the currently compiled ED2 binary.",
  file.path(placeholder_dir, "0_scandir_workaround_a.placeholder")
)
writeLines(
  "See 0_scandir_workaround_a.placeholder in this same directory.",
  file.path(placeholder_dir, "0_scandir_workaround_b.placeholder")
)
cat("Wrote 2 tiny placeholder files (workaround for ED2 filelist_c_ bug, not real data)\n")

cat("\n=========================================================\n")
cat("Summary - feed these into ED2IN\n")
cat("=========================================================\n")
cat(sprintf("SLXSAND = %.4f, SLXCLAY = %.4f\n", slxsand, slxclay))
cat("SFILIN prefix:", file.path("init", outprefix), " (IED_INIT_MODE = 6)\n")
cat("Met driver:  met/ED_MET_DRIVER_HEADER\n")
