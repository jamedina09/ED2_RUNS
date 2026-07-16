#!/usr/bin/env Rscript
# Loads the specific ED2-lab utility functions needed for the BCI met/soil/
# inventory rebuild, from:
#   - R-utils/ (repo root) - this repo's own copy of the lab's shared R
#     function library
#   - ED2_Support_Files-master/ - site-processing driver scripts
#     that use those functions (tower_processing, soil_data_processing,
#     pss+css_processing, tower_gapfilling_preproc). Downloaded fresh into
#      (not an external, machine-specific path) so the whole
#      tree - and this file's dependency on it - stays portable
#     across machines/devices; see README.md's
#     architecture section.
#
# We source only the specific files needed (not R-utils/load.everything.r,
# which pulls in dozens of unrelated plotting/mapping packages) and predefine
# the one loose global (`all.colour`) that timeutils.r expects to already
# exist (normally set up by load.everything.r's colour-palette section,
# which we don't need here).
#
# Source this at the top of any script that needs ed.zen(), rshort.bdown(),
# lcl.il(), or rlong.in.mmi.predict(). The calling script must define
# `repo_root` before sourcing this file (all BCI/R/ scripts do,
# via the self-locating snippet at their top).

if (!exists("repo_root")) {
  stop("lib_load_utils.R requires `repo_root` to already be set by the ",
       "calling script before sourcing this file.")
}
R_UTILS_DIR <- file.path(repo_root, "R-utils")
SUPPORT_FILES_DIR <- file.path(repo_root, "ED2_Support_Files-master")

library(chron)  # zen.r/timeutils.r call days()/months()/years() unqualified

all.colour <- "grey22"  # nolint: expected by timeutils.r's season.cols line

for (f in c("rconstants.r", "operators.r", "numutils.r", "thermlib.r", "timeutils.r", "zen.r", "rshort.bdown.r")) {
  source(file.path(R_UTILS_DIR, f))
}

# Radiation threshold constants normally come from R-utils/globdims.r, but
# that file also defines land-cover colour palettes using a custom RGB()
# helper that isn't part of this minimal load (it lives in a plotting-utils
# file we don't need). Defining just the few constants rshort.bdown()/ed.zen()
# actually use, copied verbatim from R-utils/globdims.r's "Radiation
# thresholds" section.
cosz.min      <<- 0.0001
cosz.highsun  <<- cos(84 * pi / 180)
cosz.twilight <<- cos(96 * pi / 180)
fvis.beam.def <<- 0.43
fnir.beam.def <<- 1.0 - fvis.beam.def
fvis.diff.def <<- 0.52
fnir.diff.def <<- 1.0 - fvis.diff.def
source(file.path(SUPPORT_FILES_DIR, "tower_gapfilling_preproc/Rsc/marthews.rlong.r"))

# inv.logit() is used by marthews.rlong.r's "aml" scheme but isn't defined
# anywhere in R-utils (it's normally pulled in from the `boot`/`gtools`
# packages elsewhere in the lab's full environment) - define it directly.
if (!exists("inv.logit")) {
  inv.logit <- function(x) 1 / (1 + exp(-x))
}

cat("Loaded ED2 lab utilities: ed.zen, rshort.bdown, lcl.il, rlong.in.mmi.predict\n")
