#!/usr/bin/env Rscript
# Read the BCI vegetation initial-condition files (.css cohorts / .pss patch,
# built by build_bci_datasets.R from the real ForestGEO census) and plot
# them, purely to visualize/QC the model's *input* vegetation state -
# independent of any experiment or model run.
#
# init/ is shared across all experiments (build_bci_ed2in.R only points
# SFILIN at it, never modifies it), so there's exactly one vegetation input
# to visualize, not one per experiment.
#
# Usage: Rscript sites/BCI/R/input_visualization/plot_init_input.R

library(data.table)
library(ggplot2)

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
init_dir <- file.path(repo_root, "sites/BCI/run/init")
out_dir <- file.path(repo_root, "sites/BCI/run/diagnostics/init")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

css_files <- list.files(init_dir, pattern = "\\.css$", full.names = TRUE)
pss_files <- list.files(init_dir, pattern = "\\.pss$", full.names = TRUE)
if (length(css_files) != 1 || length(pss_files) != 1) {
  stop("Expected exactly one .css and one .pss in ", init_dir,
       " - has build_bci_datasets.R run yet? (placeholder files don't match these patterns)")
}
cat("Reading", css_files, "\n")
cat("Reading", pss_files, "\n")

css <- fread(css_files, header = TRUE)
pss <- fread(pss_files, header = TRUE)
cat("Cohorts (stems):", nrow(css), "  Patches:", nrow(pss), "\n\n")

pft_labels <- c(`2` = "Early successional", `3` = "Mid successional", `4` = "Late successional")
pft_colors <- c(`2` = "#1b9e77", `3` = "#d95f02", `4` = "#7570b3")
css[, pft_label := factor(pft_labels[as.character(pft)], levels = pft_labels)]

# --- Derived per-cohort quantities ------------------------------------------
css[, biomass_kg := bdead + balive]              # kgC/plant, ED2 native units
css[, n_per_ha := n * 10000]                      # n is stems/m2 -> stems/ha

out_csv <- file.path(out_dir, "bci_init_cohorts.csv")
fwrite(css, out_csv)
cat("Wrote", out_csv, "\n\n")

cat("--- Summary by PFT ---\n")
summary_pft <- css[, .(
  n_stems       = .N,
  stems_per_ha  = sum(n_per_ha),
  mean_dbh_cm   = mean(dbh),
  biomass_Mg_ha = sum(n * biomass_kg) * 10000 / 1000  # kg/m2 -> Mg/ha
), by = pft_label]
print(summary_pft)

theme_bci <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
        legend.position = "top")

save_plot <- function(p, name, width = 8, height = 5) {
  path <- file.path(out_dir, name)
  ggsave(path, p, width = width, height = height, dpi = 150)
  cat("Wrote", path, "\n")
}

# --- 1. DBH distribution by PFT (unweighted stem counts, log-y: reverse-J
#        shape is the classic signature of a natural, uneven-aged forest).
#        Faceted, not stacked: stacking bars is unreliable under
#        scale_y_log10() (segment heights effectively get added in
#        log-space rather than the counts being summed then logged),
#        which silently produces meaningless totals.
p_dbh_hist <- ggplot(css, aes(dbh, fill = pft_label)) +
  geom_histogram(binwidth = 5, boundary = 0, alpha = 0.85, show.legend = FALSE) +
  scale_y_log10() +
  scale_fill_manual(values = setNames(pft_colors, pft_labels), name = NULL) +
  facet_wrap(~pft_label, ncol = 1) +
  labs(title = "BCI init: DBH distribution by PFT (log scale)",
       x = "DBH (cm)", y = "Stem count (log scale)") +
  theme_bci
save_plot(p_dbh_hist, "01_dbh_histogram.png", height = 8)

# --- 2. Height-DBH allometry (sanity check the allometric functions used) --
p_height_dbh <- ggplot(css[sample.int(.N, min(.N, 20000))], aes(dbh, hite, colour = pft_label)) +
  geom_point(alpha = 0.15, size = 0.5) +
  scale_colour_manual(values = setNames(pft_colors, pft_labels), name = NULL) +
  labs(title = "BCI init: height-DBH allometry by PFT (20k-stem subsample)",
       x = "DBH (cm)", y = "Height (m)") +
  theme_bci
save_plot(p_height_dbh, "02_height_dbh_allometry.png")

# --- 3. Standing biomass by PFT -------------------------------------------
p_biomass <- ggplot(summary_pft, aes(pft_label, biomass_Mg_ha, fill = pft_label)) +
  geom_col(show.legend = FALSE) +
  scale_fill_manual(values = setNames(pft_colors, pft_labels)) +
  labs(title = "BCI init: standing aboveground+belowground biomass by PFT",
       x = NULL, y = "Biomass (Mg/ha)") +
  theme_bci
save_plot(p_biomass, "03_biomass_by_pft.png")

# --- 4. Stem density by PFT ------------------------------------------------
p_density <- ggplot(summary_pft, aes(pft_label, stems_per_ha, fill = pft_label)) +
  geom_col(show.legend = FALSE) +
  scale_fill_manual(values = setNames(pft_colors, pft_labels)) +
  labs(title = "BCI init: stem density by PFT", x = NULL, y = "Stems/ha") +
  theme_bci
save_plot(p_density, "04_density_by_pft.png")

# --- 5. Biomass distribution across the DBH spectrum (which size classes
#        actually carry the standing carbon stock) --------------------------
css[, dbh_bin := cut(dbh, breaks = c(0, 10, 20, 30, 50, 70, 100, Inf), right = FALSE)]
biomass_by_bin <- css[, .(biomass_Mg_ha = sum(n * biomass_kg) * 10000 / 1000),
                       by = .(dbh_bin, pft_label)]
p_biomass_bin <- ggplot(biomass_by_bin, aes(dbh_bin, biomass_Mg_ha, fill = pft_label)) +
  geom_col(position = "stack") +
  scale_fill_manual(values = setNames(pft_colors, pft_labels), name = NULL) +
  labs(title = "BCI init: biomass by DBH size class and PFT",
       x = "DBH class (cm)", y = "Biomass (Mg/ha)") +
  theme_bci
save_plot(p_biomass_bin, "05_biomass_by_size_class.png")

cat("\nAll vegetation-init diagnostic plots written to", out_dir, "\n")
