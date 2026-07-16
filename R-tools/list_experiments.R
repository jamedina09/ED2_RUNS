#!/usr/bin/env Rscript
# List/filter every experiment ever built, at any site (experiments_registry.csv
# at the repo root, written by each site's build_*_ed2in.R and updated by
# run_experiment.sh) - the "find my results" half of run+find+evaluate.
# Survives `rm -rf sites/<site>/run`, since the registry lives at the repo
# root, not inside any site's run/ directory.
#
# Usage:
#   Rscript R-tools/list_experiments.R
#   Rscript R-tools/list_experiments.R --site=BCI
#   Rscript R-tools/list_experiments.R --name=plant_hydro
#   Rscript R-tools/list_experiments.R --status=completed

library(data.table)

.cli_args <- commandArgs(trailingOnly = TRUE)
.get_flag <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), .cli_args, value = TRUE)
  if (length(hit) == 0) return(default)
  sub(paste0("^--", name, "="), "", hit[1])
}
site_filter <- .get_flag("site", "")
name_filter <- .get_flag("name", "")
status_filter <- .get_flag("status", "")

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

reg <- registry_read(repo_root)
if (nrow(reg) == 0) {
  cat("No experiments registered yet - run a site's build_*_ed2in.R or run_experiment.sh first.\n")
  quit(status = 0)
}

if (nzchar(site_filter)) reg <- reg[site == site_filter]
if (nzchar(name_filter)) reg <- reg[grepl(name_filter, name, fixed = TRUE)]
if (nzchar(status_filter)) reg <- reg[status == status_filter]
setorder(reg, -created_at)

cat("experiments_registry.csv -", nrow(reg), "experiment(s)",
    if (nzchar(site_filter) || nzchar(name_filter) || nzchar(status_filter)) "(filtered)" else "", "\n\n")
print(reg[, .(exp_id, site, name, created_at, status, run_seconds,
              plant_hydro_scheme, start_date, end_date, pft_config)])

cat("\nTo explore an experiment's output (substitute its site):\n")
cat("  sites/<site>/run/experiments/<exp_id>/figures/*.png\n")
cat("  sites/<site>/run/experiments/<exp_id>/variable_catalog.csv\n")
cat("  sites/<site>/run/experiments/<exp_id>/timeseries_output_<resolution>.csv\n")
cat("To compare several (must be the same site):\n")
cat("  Rscript R-tools/compare_experiments.R --site=<site> --exp=<id1>,<id2>,...\n")
