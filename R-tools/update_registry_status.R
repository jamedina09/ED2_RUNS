#!/usr/bin/env Rscript
# Small CLI wrapper around registry_update_status() (registry_utils.R), so
# run_experiment.sh can update experiments_registry.csv after the podman
# run finishes without embedding R code inline in the shell script. Works
# for any site's experiments - exp_id alone is enough to find the row (it's
# unique across sites).
#
# Usage: Rscript R-tools/update_registry_status.R --exp=<id> \
#          --status=completed [--run_seconds=520] [--notes="..."]

.cli_args <- commandArgs(trailingOnly = TRUE)
.get_flag <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), .cli_args, value = TRUE)
  if (length(hit) == 0) return(default)
  sub(paste0("^--", name, "="), "", hit[1])
}
exp_id <- .get_flag("exp", "")
status <- .get_flag("status", "")
run_seconds <- as.numeric(.get_flag("run_seconds", NA_character_))
notes <- .get_flag("notes", NA_character_)
if (!nzchar(exp_id) || !nzchar(status)) {
  stop("Usage: update_registry_status.R --exp=<id> --status=<value> [--run_seconds=<n>] [--notes=<text>]")
}

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
source(file.path(repo_root, "R-tools/registry_utils.R"))

registry_update_status(repo_root, exp_id, new_status = status,
                       new_run_seconds = run_seconds, new_notes = notes)
cat("Updated", exp_id, "-> status:", status,
    if (!is.na(run_seconds)) paste0(" (", run_seconds, "s)") else "", "\n")
