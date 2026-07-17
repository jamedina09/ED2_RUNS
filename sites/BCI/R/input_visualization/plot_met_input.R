#!/usr/bin/env Rscript
# Join every monthly ED2 met driver HDF5 file (sites/BCI/run/met/*.h5, built by
# build_bci_datasets.R) into one hourly time series and plot it, purely to
# visualize/QC the model's *input* met forcing - independent of any
# experiment or model run.
#
# met/ is shared across all experiments (build_bci_ed2in.R doesn't touch
# it), so there's exactly one met input to visualize, not one per
# experiment.
#
# Usage: Rscript sites/BCI/R/input_visualization/plot_met_input.R

library(hdf5r)
library(data.table)
library(ggplot2)

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
met_dir <- file.path(repo_root, "sites/BCI/run/met")
out_dir <- file.path(repo_root, "sites/BCI/run/diagnostics/met")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

met_files <- sort(list.files(met_dir, pattern = "^\\d{4}[A-Z]{3}\\.h5$", full.names = TRUE))
if (length(met_files) == 0) {
  stop("No monthly met .h5 files found in ", met_dir,
       " - has build_bci_datasets.R run yet?")
}
cat("Found", length(met_files), "monthly met driver files.\n")

month_abb_upper <- toupper(month.abb)
vars <- c("dlwrf", "nbdsf", "nddsf", "prate", "pres", "sh", "tmp", "ugrd", "vbdsf", "vddsf", "vgrd")

read_one_month <- function(path) {
  fname <- basename(path)
  m <- regmatches(fname, regexec("^(\\d{4})([A-Z]{3})\\.h5$", fname))[[1]]
  year  <- as.integer(m[2])
  month <- match(m[3], month_abb_upper)

  f <- H5File$new(path, mode = "r")
  on.exit(f$close_all())

  n_hours <- f[[vars[1]]]$dims[1]
  datetime <- seq(as.POSIXct(sprintf("%04d-%02d-01 00:00:00", year, month), tz = "UTC"),
                   by = "hour", length.out = n_hours)

  dt <- data.table(datetime = datetime, year = year, month = month)
  for (v in vars) dt[[v]] <- as.numeric(f[[v]]$read())
  dt
}

met <- rbindlist(lapply(met_files, read_one_month))
setorder(met, datetime)

# --- Derived, more directly interpretable quantities ------------------------
met[, rshort_total := nbdsf + nddsf + vbdsf + vddsf]     # total shortwave (W/m2)
met[, wind_speed   := sqrt(ugrd^2 + vgrd^2)]             # m/s
met[, tmp_c        := tmp - 273.15]                      # degC, easier to read than K

out_csv <- file.path(out_dir, "bci_met_joined.csv")
out_rds <- file.path(out_dir, "bci_met_joined.rds")
fwrite(met, out_csv)
saveRDS(met, out_rds)
cat("Wrote", out_csv, "\n")
cat("Wrote", out_rds, "\n")
cat("Rows (hours):", nrow(met), "  Span:", format(min(met$datetime)), "to", format(max(met$datetime)), "\n\n")

theme_bci <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"))

save_plot <- function(p, name, width = 10, height = 4.5) {
  path <- file.path(out_dir, name)
  ggsave(path, p, width = width, height = height, dpi = 150)
  cat("Wrote", path, "\n")
}

# Full 14-year hourly series is too dense to read as a line plot; use daily
# means for the full-span figures (raw hourly data stays in the CSV/RDS).
daily <- met[, .(
  tmp_c        = mean(tmp_c, na.rm = TRUE),
  rshort_total = mean(rshort_total, na.rm = TRUE),
  dlwrf        = mean(dlwrf, na.rm = TRUE),
  pres         = mean(pres, na.rm = TRUE),
  sh           = mean(sh, na.rm = TRUE),
  wind_speed   = mean(wind_speed, na.rm = TRUE),
  prate        = mean(prate, na.rm = TRUE)
), by = .(date = as.Date(datetime))]

p_tmp <- ggplot(daily, aes(date, tmp_c)) +
  geom_line(colour = "#d95f02", linewidth = 0.4) +
  labs(title = "BCI met input: daily mean air temperature", x = NULL, y = "Temperature (°C)") +
  theme_bci
save_plot(p_tmp, "01_temperature.png")

p_rad <- ggplot(daily, aes(date, rshort_total)) +
  geom_line(colour = "#e6ab02", linewidth = 0.4) +
  labs(title = "BCI met input: daily mean total incoming shortwave",
       x = NULL, y = expression(R[short]~(W/m^2))) +
  theme_bci
save_plot(p_rad, "02_shortwave.png")

p_lw <- ggplot(daily, aes(date, dlwrf)) +
  geom_line(colour = "#a6761d", linewidth = 0.4) +
  labs(title = "BCI met input: daily mean downward longwave (estimated, see README.md)",
       x = NULL, y = expression(L[down]~(W/m^2))) +
  theme_bci
save_plot(p_lw, "03_longwave.png")

p_precip <- ggplot(daily, aes(date, prate * 86400)) +   # kg/m2/s -> mm/day
  geom_col(fill = "#1f78b4", width = 1) +
  labs(title = "BCI met input: daily total precipitation", x = NULL, y = "Precipitation (mm/day)") +
  theme_bci
save_plot(p_precip, "04_precipitation.png")

p_pres <- ggplot(daily, aes(date, pres / 100)) +   # Pa -> hPa
  geom_line(colour = "#666666", linewidth = 0.4) +
  labs(title = "BCI met input: daily mean surface pressure", x = NULL, y = "Pressure (hPa)") +
  theme_bci
save_plot(p_pres, "05_pressure.png")

p_wind <- ggplot(daily, aes(date, wind_speed)) +
  geom_line(colour = "#1b9e77", linewidth = 0.4) +
  labs(title = "BCI met input: daily mean wind speed", x = NULL, y = "Wind speed (m/s)") +
  theme_bci
save_plot(p_wind, "06_wind_speed.png")

p_sh <- ggplot(daily, aes(date, sh * 1000)) +   # kg/kg -> g/kg
  geom_line(colour = "#7570b3", linewidth = 0.4) +
  labs(title = "BCI met input: daily mean specific humidity", x = NULL, y = "Specific humidity (g/kg)") +
  theme_bci
save_plot(p_sh, "07_specific_humidity.png")

# One year at hourly resolution, to check the diurnal cycle actually looks
# physical (not just the smoothed daily means above).
one_year <- met[year == met$year[1]]
p_diurnal <- ggplot(one_year, aes(datetime, rshort_total)) +
  geom_line(colour = "#e6ab02", linewidth = 0.3) +
  labs(title = paste("BCI met input: hourly total shortwave,", met$year[1]),
       x = NULL, y = expression(R[short]~(W/m^2))) +
  theme_bci
save_plot(p_diurnal, "08_shortwave_hourly_one_year.png", width = 12, height = 4.5)

cat("\nAll met diagnostic plots written to", out_dir, "\n")
