#!/usr/bin/env Rscript
# Plot the tidy BCI output produced by extract_bci_output.R, at whichever
# --resolution (monthly/daily/hourly) was extracted. One script for both
# the ecosystem-scale time series and the PFT x size-class heatmaps (these
# used to be two separate plotting scripts).
#
# No stacked bars/areas anywhere: any variable broken down by PFT (or PFT x
# size-class) is shown as a matrix (geom_tile heatmap) instead, since
# stacking hides each PFT's/class's own trajectory behind the others.
# Filenames are grouped by a category prefix (flux_/stock_/water_/energy_/
# forcing_/sizeclass_) so they sort into coherent groups regardless of
# resolution; figures for different resolutions of the same experiment go
# into separate figures/<resolution>/ subfolders so extracting e.g. both
# monthly and hourly never overwrites the other's plots.
#
# Usage: Rscript sites/BCI/R/output_preparation/plot_bci_output.R --exp=<id> [--resolution=monthly|daily|hourly]
# (run extract_bci_output.R --exp=<same> --resolution=<same> first if the
# .rds files don't exist yet)

library(data.table)
library(ggplot2)

.cli_args <- commandArgs(trailingOnly = TRUE)
.get_flag <- function(name, default) {
  hit <- grep(paste0("^--", name, "="), .cli_args, value = TRUE)
  if (length(hit) == 0) return(default)
  sub(paste0("^--", name, "="), "", hit[1])
}
exp_id <- .get_flag("exp", "001_baseline")
resolution <- .get_flag("resolution", "monthly")

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
fig_dir <- file.path(outdir, "figures", resolution)

cat("Experiment:", exp_id, " Resolution:", resolution, "(", outdir, ")\n")

eco_rds <- file.path(outdir, sprintf("timeseries_output_%s.rds", resolution))
sc_rds <- file.path(outdir, sprintf("sizeclass_output_%s.rds", resolution))
if (!file.exists(eco_rds)) stop("Run extract_bci_output.R --resolution=", resolution, " first - missing ", eco_rds)
if (!file.exists(sc_rds)) stop("Run extract_bci_output.R --resolution=", resolution, " first - missing ", sc_rds)
dt <- readRDS(eco_rds)
sc <- readRDS(sc_rds)

dir.create(fig_dir, showWarnings = FALSE, recursive = TRUE)
unlink(list.files(fig_dir, full.names = TRUE))

pft_labels <- c(pft2 = "Early successional", pft3 = "Mid successional", pft4 = "Late successional")
pft_levels <- c("pft2", "pft3", "pft4")
pft_labels_named <- c(`2` = "Early successional", `3` = "Mid successional", `4` = "Late successional")
sc[, pft_label := factor(pft_labels_named[as.character(pft)], levels = pft_labels_named)]
size_levels <- c(sprintf("%d-%d", seq(0, 90, 10), seq(10, 100, 10)), ">100")
sc[, size_class := factor(size_class, levels = size_levels)]

theme_bci <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
        legend.position = "top")

save_plot <- function(p, name, width = 8, height = 5) {
  path <- file.path(fig_dir, name)
  p <- p + labs(subtitle = sprintf("Experiment: %s (%s)", exp_id, resolution))
  ggsave(path, p, width = width, height = height, dpi = 150)
  cat("Wrote", path, "\n")
}

# A datetime x PFT matrix (heatmap), for any ecosystem-scale variable broken
# down by PFT - used instead of a stacked bar/area so each PFT's own
# magnitude stays readable rather than being hidden inside a cumulative stack.
matrix_by_pft <- function(measure_cols, title, fill_label) {
  long <- melt(dt, id.vars = "datetime", measure.vars = measure_cols,
               variable.name = "pft", value.name = "value")
  long[, pft := factor(sub("^[A-Za-z]+_", "", pft), levels = pft_levels, labels = pft_labels[pft_levels])]
  ggplot(long, aes(datetime, pft, fill = value)) +
    geom_tile() +
    scale_fill_viridis_c(name = fill_label) +
    labs(title = title, x = NULL, y = NULL) +
    theme_bci +
    theme(legend.position = "right")
}

# =============================================================================
# Carbon fluxes (ecosystem scale)
# =============================================================================

flux_long <- melt(dt, id.vars = "datetime",
                   measure.vars = c("GPP", "NPP", "PlantResp", "HeteroResp"),
                   variable.name = "flux", value.name = "value")
p_flux <- ggplot(flux_long, aes(datetime, value, colour = flux)) +
  geom_line(linewidth = 0.5) +
  scale_colour_brewer(palette = "Set2", name = NULL) +
  labs(title = "BCI: carbon fluxes",
       x = NULL, y = "Flux (ED2 native units, see README.md)") +
  theme_bci
save_plot(p_flux, "flux_01_gpp_npp_resp.png")

p_nep <- ggplot(dt, aes(datetime, NEP)) +
  geom_hline(yintercept = 0, colour = "grey60", linetype = "dashed") +
  geom_line(colour = "#1b9e77", linewidth = 0.5) +
  labs(title = "BCI: net ecosystem productivity (NEP)",
       x = NULL, y = "NEP (ED2 native units)") +
  theme_bci
save_plot(p_nep, "flux_02_nep.png")

# =============================================================================
# Carbon stocks - ecosystem totals, and by-PFT matrices (see the sizeclass_*
# plots below for the further PFT x size-class breakdown)
# =============================================================================

p_lai <- ggplot(dt, aes(datetime, LAI_total)) +
  geom_line(colour = "#1b9e77", linewidth = 0.5) +
  labs(title = "BCI: total leaf area index", x = NULL, y = expression(LAI~(m^2/m^2))) +
  theme_bci
save_plot(p_lai, "stock_01_lai_total.png")

p_agb <- ggplot(dt, aes(datetime, AGB_total)) +
  geom_line(colour = "#7570b3", linewidth = 0.5) +
  labs(title = "BCI: total aboveground biomass", x = NULL,
       y = "AGB (ED2 native units)") +
  theme_bci
save_plot(p_agb, "stock_02_agb_total.png")

save_plot(matrix_by_pft(c("AGB_pft2", "AGB_pft3", "AGB_pft4"),
                         "BCI: aboveground biomass by PFT", "AGB"),
          "stock_03_agb_by_pft_matrix.png")

save_plot(matrix_by_pft(c("LAI_pft2", "LAI_pft3", "LAI_pft4"),
                         "BCI: leaf area index by PFT", "LAI"),
          "stock_04_lai_by_pft_matrix.png")

save_plot(matrix_by_pft(c("NPLANT_pft2", "NPLANT_pft3", "NPLANT_pft4"),
                         "BCI: plant density by PFT", "Plants/m2"),
          "stock_05_nplant_by_pft_matrix.png")

save_plot(matrix_by_pft(c("Bstorage_pft2", "Bstorage_pft3", "Bstorage_pft4"),
                         "BCI: non-structural (storage) carbon by PFT", "Bstorage"),
          "stock_06_bstorage_by_pft_matrix.png")

# =============================================================================
# Water and plant hydraulics
# =============================================================================

# The key PLANT_HYDRO_SCHEME diagnostic: both are identically 0 whenever
# PLANT_HYDRO_SCHEME=0 (no internal water transport tracked - see
# extract_bci_output.R), non-zero once dynamic hydraulics are on.
wflux_long <- melt(dt, id.vars = "datetime",
                    measure.vars = c("WfluxGW", "WfluxWL"),
                    variable.name = "flux", value.name = "value")
wflux_long[, flux := c(WfluxGW = "Soil -> wood (GW)", WfluxWL = "Wood -> leaf (WL)")[as.character(flux)]]
p_wflux <- ggplot(wflux_long, aes(datetime, value, colour = flux)) +
  geom_hline(yintercept = 0, colour = "grey60", linetype = "dashed") +
  geom_line(linewidth = 0.5) +
  scale_colour_brewer(palette = "Set1", name = NULL) +
  labs(title = "BCI: internal plant water fluxes (PLANT_HYDRO_SCHEME diagnostic)",
       x = NULL, y = expression(Water~flux~(kg~m^-2~s^-1))) +
  theme_bci
save_plot(p_wflux, "water_01_plant_water_fluxes.png")

water_content_long <- melt(dt, id.vars = "datetime",
                            measure.vars = c("LeafWater", "WoodWater"),
                            variable.name = "pool", value.name = "value")
water_content_long[, pool := c(LeafWater = "Leaf", WoodWater = "Wood")[as.character(pool)]]
p_water_content <- ggplot(water_content_long, aes(datetime, value, colour = pool)) +
  geom_line(linewidth = 0.5) +
  scale_colour_manual(values = c(Leaf = "#1b9e77", Wood = "#a6761d"), name = NULL) +
  labs(title = "BCI: leaf and wood water content",
       x = NULL, y = expression(Water~content~(kg~m^-2))) +
  theme_bci
save_plot(p_water_content, "water_02_leaf_wood_water_content.png")

et_long <- melt(dt, id.vars = "datetime",
                 measure.vars = c("Transp", "ET"),
                 variable.name = "flux", value.name = "value")
et_long[, flux := c(Transp = "Plant transpiration", ET = "Net canopy<->atm vapor flux (ET)")[as.character(flux)]]
p_et <- ggplot(et_long, aes(datetime, value, colour = flux)) +
  geom_line(linewidth = 0.5) +
  scale_colour_brewer(palette = "Dark2", name = NULL) +
  labs(title = "BCI: transpiration and evapotranspiration",
       x = NULL, y = expression(Water~flux~(kg~m^-2~s^-1))) +
  theme_bci
save_plot(p_et, "water_03_transpiration_et.png")

fsw_long <- melt(dt, id.vars = "datetime",
                  measure.vars = c("FSW", "FS_open"),
                  variable.name = "factor", value.name = "value")
fsw_long[, factor := c(FSW = "Water availability (fsw)", FS_open = "Realized stomatal opening (fs_open)")[as.character(factor)]]
p_fsw <- ggplot(fsw_long, aes(datetime, value, colour = factor)) +
  geom_line(linewidth = 0.5) +
  ylim(0, 1) +
  scale_colour_brewer(palette = "Set2", name = NULL) +
  labs(title = "BCI: water-limitation and stomatal-opening factors",
       x = NULL, y = "Factor (0 = fully limited, 1 = unlimited)") +
  theme_bci
save_plot(p_fsw, "water_04_limitation_factors.png")

vpd_long <- melt(dt, id.vars = "datetime",
                  measure.vars = c("LeafVPD", "CanVPD"),
                  variable.name = "level", value.name = "value")
vpd_long[, level := c(LeafVPD = "Leaf", CanVPD = "Canopy air")[as.character(level)]]
p_vpd <- ggplot(vpd_long, aes(datetime, value / 1000, colour = level)) +   # Pa -> kPa
  geom_line(linewidth = 0.5) +
  scale_colour_manual(values = c(Leaf = "#e6550d", `Canopy air` = "#3182bd"), name = NULL) +
  labs(title = "BCI: vapor pressure deficit", x = NULL, y = "VPD (kPa)") +
  theme_bci
save_plot(p_vpd, "water_05_vpd.png")

# =============================================================================
# Energy balance and microclimate
# =============================================================================

temp_long <- melt(dt, id.vars = "datetime",
                   measure.vars = c("LeafTemp", "CanTemp"),
                   variable.name = "level", value.name = "value")
temp_long[, level := c(LeafTemp = "Leaf", CanTemp = "Canopy air")[as.character(level)]]
p_temp <- ggplot(temp_long, aes(datetime, value - 273.15, colour = level)) +   # K -> degC
  geom_line(linewidth = 0.5) +
  scale_colour_manual(values = c(Leaf = "#e6550d", `Canopy air` = "#3182bd"), name = NULL) +
  labs(title = "BCI: leaf and canopy air temperature", x = NULL, y = "Temperature (°C)") +
  theme_bci
save_plot(p_temp, "energy_01_leaf_canopy_temperature.png")

energy_long <- melt(dt, id.vars = "datetime",
                     measure.vars = c("Rnet", "SensibleAC"),
                     variable.name = "term", value.name = "value")
energy_long[, term := c(Rnet = "Net radiation", SensibleAC = "Sensible heat (canopy->atm)")[as.character(term)]]
p_energy <- ggplot(energy_long, aes(datetime, value, colour = term)) +
  geom_hline(yintercept = 0, colour = "grey60", linetype = "dashed") +
  geom_line(linewidth = 0.5) +
  scale_colour_brewer(palette = "Set1", name = NULL) +
  labs(title = "BCI: energy balance", x = NULL, y = expression(Flux~(W/m^2))) +
  theme_bci
save_plot(p_energy, "energy_02_balance.png")

p_soil <- ggplot(dt, aes(datetime, SoilMoist)) +
  geom_line(colour = "#1f78b4", linewidth = 0.5) +
  labs(title = "BCI: mean soil moisture across layers",
       x = NULL, y = expression(Soil~moisture~(m^3/m^3))) +
  theme_bci
save_plot(p_soil, "energy_03_soil_moisture.png")

# =============================================================================
# Forcing sanity check (input radiation, as seen by the model)
# =============================================================================

forcing_long <- melt(dt, id.vars = "datetime",
                      measure.vars = c("RshortAtm", "RlongAtm"),
                      variable.name = "band", value.name = "value")
forcing_long[, band := c(RshortAtm = "Shortwave", RlongAtm = "Longwave")[as.character(band)]]
p_forcing <- ggplot(forcing_long, aes(datetime, value, colour = band)) +
  geom_line(linewidth = 0.5) +
  scale_colour_manual(values = c(Shortwave = "#e6ab02", Longwave = "#a6761d"), name = NULL) +
  labs(title = "BCI: incoming radiation forcing (as seen by the model)",
       x = NULL, y = expression(Flux~(W/m^2))) +
  theme_bci
save_plot(p_forcing, "forcing_01_radiation.png")

# =============================================================================
# PFT x DBH-size-class matrices (from sizeclass_output_<resolution>.rds).
# GPP/NPP are only meaningful at --resolution=monthly (0 elsewhere - see
# extract_bci_output.R's header on why cohort-level fluxes are monthly-only).
# =============================================================================

matrix_by_sizeclass_pft <- function(varname, title, fill_label) {
  p <- ggplot(sc, aes(size_class, datetime, fill = get(varname))) +
    geom_tile() +
    facet_wrap(~pft_label, nrow = 1) +
    scale_fill_viridis_c(name = fill_label) +
    labs(title = title, x = "DBH size class (cm)", y = NULL) +
    theme_bci +
    theme(axis.text.x = element_text(angle = 45, hjust = 1))
  save_plot(p, sprintf("sizeclass_%s.png", tolower(varname)), width = 9)
}

if (resolution == "monthly") {
  matrix_by_sizeclass_pft("GPP", "BCI: GPP by size class and PFT", "GPP")
  matrix_by_sizeclass_pft("NPP", "BCI: NPP by size class and PFT", "NPP")
} else {
  cat("Skipping sizeclass GPP/NPP plots - only meaningful at --resolution=monthly.\n")
}
matrix_by_sizeclass_pft("AGB", "BCI: aboveground biomass by size class and PFT", "AGB")
matrix_by_sizeclass_pft("LAI", "BCI: leaf area index by size class and PFT", "LAI")
matrix_by_sizeclass_pft("NPLANT", "BCI: stem density by size class and PFT", "Plants/m2")
matrix_by_sizeclass_pft("Bstorage", "BCI: storage carbon by size class and PFT", "Bstorage")
matrix_by_sizeclass_pft("BasalArea", "BCI: basal area by size class and PFT", expression(m^2/m^2))

cat("\nAll plots written to", fig_dir, "\n")
