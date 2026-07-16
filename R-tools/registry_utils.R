#!/usr/bin/env Rscript
# Shared helpers for experiments_registry.csv - the single source of truth
# for "what experiments exist, at which site, and what state are they in",
# so you never have to re-read individual ED2IN files or guess from
# directory names. Sourced by <site>/R/model_runs/build_*_ed2in.R (writes
# the initial row) and run_experiment.sh (updates status as the run
# progresses), and read by R-tools/list_experiments.R / R-tools/compare_experiments.R.
#
# Lives at the repo root, next to sites/ (not inside any one site's
# folder), because it's the cross-site index: one registry covering every
# site's every experiment. Survives `rm -rf sites/<site>/run` and stays the
# permanent record of every experiment ever built, including ones whose
# output has since been deleted.
#
# Not sourced directly - each caller does source(file.path(repo_root,
# "R-tools/registry_utils.R")) after locating repo_root itself.

library(data.table)

.registry_path <- function(repo_root) {
  file.path(repo_root, "experiments_registry.csv")
}

.registry_cols <- c(
  "exp_id", "site", "name", "created_at", "plant_hydro_scheme", "start_date",
  "end_date", "pft_config", "status", "run_seconds", "notes"
)

# Appends one new row (called once, at build time by a site's ED2IN-builder
# script). exp_id must not already exist in the registry - experiment ids
# are unique by design (the timestamp suffix makes collisions practically
# impossible even when reusing the same --name repeatedly, even across
# different sites).
registry_add <- function(repo_root, exp_id, site, name, plant_hydro_scheme,
                          start_date, end_date, pft_config, status = "built",
                          notes = NA_character_) {
  path <- .registry_path(repo_root)
  row <- data.table(
    exp_id = exp_id, site = site, name = name,
    created_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    plant_hydro_scheme = plant_hydro_scheme, start_date = start_date,
    end_date = end_date, pft_config = if (nzchar(pft_config)) pft_config else NA_character_,
    status = status, run_seconds = NA_real_, notes = notes
  )
  if (file.exists(path)) {
    existing <- fread(path, colClasses = "character")
    if (exp_id %in% existing$exp_id) {
      stop("exp_id '", exp_id, "' already exists in the registry - ",
           "this should be practically impossible with the timestamp ",
           "suffix; pass a different --name or an explicit --exp.")
    }
    fwrite(row, path, append = TRUE)
  } else {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    fwrite(row, path)
  }
  invisible(row)
}

# Updates status (and optionally run_seconds/notes) for an existing exp_id -
# called by run_experiment.sh after the podman run finishes.
#
# NOTE: parameters are named new_status/new_run_seconds/new_notes, not
# status/run_seconds/notes - data.table's `:=` NSE resolves a bare name on
# the RHS against the data.table's OWN columns before the calling
# environment, so e.g. `reg[i, status := status]` with a same-named
# parameter silently assigns the column to itself (a no-op) rather than to
# the parameter value. Confirmed the hard way: an earlier version of this
# function used the shadowed names and every "update" silently did nothing.
registry_update_status <- function(repo_root, target_exp_id, new_status,
                                    new_run_seconds = NA_real_, new_notes = NA_character_) {
  path <- .registry_path(repo_root)
  if (!file.exists(path)) stop("No registry found at ", path)
  reg <- fread(path, colClasses = "character")
  if (!(target_exp_id %in% reg$exp_id)) stop("exp_id '", target_exp_id, "' not found in registry")
  match_row <- reg$exp_id == target_exp_id
  reg[match_row, status := new_status]
  if (!is.na(new_run_seconds)) reg[match_row, run_seconds := as.character(new_run_seconds)]
  if (!is.na(new_notes)) reg[match_row, notes := new_notes]
  fwrite(reg, path)
}

registry_read <- function(repo_root) {
  path <- .registry_path(repo_root)
  if (!file.exists(path)) {
    return(data.table(matrix(nrow = 0, ncol = length(.registry_cols),
                              dimnames = list(NULL, .registry_cols))))
  }
  fread(path)
}
