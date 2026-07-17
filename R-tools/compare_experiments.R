#!/usr/bin/env Rscript
# Overlay multiple experiments' ecosystem-scale monthly output on the same
# axes - one PNG per variable group (carbon fluxes, carbon stocks, plant
# hydraulics, energy/microclimate), coloured by experiment - instead of
# comparing separate figures/ folders PNG by PNG.
#
# Requires the site's output extraction script to have already been run, at
# the same --resolution, for every experiment being compared (reads their
# timeseries_output_<resolution>.rds - this filename convention is what
# makes this tool site-agnostic: any site's extraction script just needs to
# write to <exp>/timeseries_output_<resolution>.rds for compare_experiments.R
# to work against it, regardless of the site script's own name). All
# experiments compared in one call must be from the same site and the same
# --resolution.
#
# Usage:
#   Rscript R-tools/compare_experiments.R --site=BCI --exp=<id1>,<id2>
#   Rscript R-tools/compare_experiments.R --site=BCI --exp=<id1>,<id2>,<id3> --resolution=daily --out=my_comparison

library(data.table)
library(ggplot2)

.cli_args <- commandArgs(trailingOnly = TRUE)
.get_flag <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), .cli_args, value = TRUE)
  if (length(hit) == 0) return(default)
  sub(paste0("^--", name, "="), "", hit[1])
}
site <- .get_flag("site", "BCI")
resolution <- .get_flag("resolution", "monthly")
exp_ids <- strsplit(.get_flag("exp", ""), ",")[[1]]
out_name <- .get_flag("out", sprintf("comparison_%s_%s", resolution, format(Sys.time(), "%Y%m%d_%H%M%S")))
if (length(exp_ids) < 2) {
  stop("Need at least 2 experiments: --exp=<id1>,<id2>[,<id3>,...]")
}

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
run_dir <- file.path(repo_root, "sites", site, "run")
out_dir <- file.path(run_dir, "comparisons", out_name)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

cat("Site:", site, " Resolution:", resolution, " Comparing", length(exp_ids),
    "experiments:", paste(exp_ids, collapse = ", "), "\n")

load_one <- function(id) {
  rds_path <- file.path(run_dir, "experiments", id, sprintf("timeseries_output_%s.rds", resolution))
  if (!file.exists(rds_path)) {
    stop("Missing ", rds_path, " - run this site's extract-output script --exp=", id,
         " --resolution=", resolution, " first.")
  }
  dt <- readRDS(rds_path)
  dt[, experiment := id]
  dt
}
combined <- rbindlist(lapply(exp_ids, load_one), fill = TRUE)
combined[, experiment := factor(experiment, levels = exp_ids)] # preserve --exp order in legends

theme_cmp <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
        legend.position = "top")

save_plot <- function(p, name, width = 9, height = 5) {
  path <- file.path(out_dir, name)
  ggsave(path, p, width = width, height = height, dpi = 150)
  cat("Wrote", path, "\n")
}

# One faceted panel-of-lines-by-experiment plot per named group of measure
# columns - keeps each variable on its own natural scale (a single "GPP vs
# WfluxGW" plot would be useless since they differ by orders of magnitude).
compare_group <- function(measure_cols, title, ncol_facets = 2) {
  cols_present <- intersect(measure_cols, names(combined))
  if (length(cols_present) == 0) return(invisible(NULL))
  long <- melt(combined, id.vars = c("datetime", "experiment"), measure.vars = cols_present,
               variable.name = "variable", value.name = "value")
  p <- ggplot(long, aes(datetime, value, colour = experiment)) +
    geom_line(linewidth = 0.7) +
    facet_wrap(~variable, scales = "free_y", ncol = ncol_facets) +
    scale_colour_brewer(palette = "Dark2", name = NULL) +
    labs(title = title, x = NULL, y = NULL) +
    theme_cmp
  save_plot(p, paste0(gsub("[^a-z0-9]+", "_", tolower(title)), ".png"),
            height = 2.5 * ceiling(length(cols_present) / ncol_facets) + 1.5)
}

compare_group(c("GPP", "NPP", "PlantResp", "HeteroResp", "NEP"), "Carbon fluxes")
compare_group(c("LAI_total", "AGB_total", "NPLANT_total", "Bstorage_total"), "Carbon stocks (ecosystem total)")
compare_group(c("WfluxGW", "WfluxWL", "LeafWater", "WoodWater", "Transp", "ET", "FSW", "FS_open"),
              "Plant hydraulics and water fluxes", ncol_facets = 2)
compare_group(c("LeafTemp", "CanTemp", "SensibleAC", "Rnet", "SoilMoist", "LeafVPD", "CanVPD"),
              "Energy balance and microclimate")

cat("\nAll comparison plots written to", out_dir, "\n")
