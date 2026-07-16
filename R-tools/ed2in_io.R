#!/usr/bin/env Rscript
# ed2in_io.R - ED2IN namelist read/modify/write, vendored from PEcAn.ED2 so
# this repo does not require installing the PEcAn.ED2 package (which in
# turn pulls in PEcAn.logger/PEcAn.utils/PEcAn.data.land/lubridate/dplyr/...
# - a heavy dependency chain for the ~3 functions this repo actually uses).
#
# ----------------------------------------------------------------------------
# ATTRIBUTION
# ----------------------------------------------------------------------------
# The functions below (read_ed2in(), modify_ed2in(), write_ed2in() and its
# S3 methods, tags2char()) are adapted, with minimal changes, from the
# PEcAn.ED2 R package:
#
#   PEcAn.ED2: PEcAn Package for Integration of ED2 Model
#   Authors:   David LeBauer, Mike Dietze, Xiaohui Feng, Dan Wang,
#              Carl Davidson, Rob Kooper, Shawn Serbin, Alexey Shiklomanov,
#              Eric R. Scott (contributor)
#   Part of:   PEcAn (Predictive Ecosystem Carbon Analyzer),
#              https://github.com/PecanProject/pecan (models/ed subdirectory)
#   Copyright: University of Illinois, NCSA
#   License:   University of Illinois/NCSA Open Source License (see below)
#
# PEcAn.ED2 is licensed under the University of Illinois/NCSA Open Source
# License, a permissive license that requires only that this notice and the
# disclaimer below be retained in redistributed source. Full text:
#
#   Copyright (c) 2012, University of Illinois, NCSA. All rights reserved.
#
#   Permission is hereby granted, free of charge, to any person obtaining a
#   copy of this software and associated documentation files (the
#   "Software"), to deal with the Software without restriction, including
#   without limitation the rights to use, copy, modify, merge, publish,
#   distribute, sublicense, and/or sell copies of the Software, and to
#   permit persons to whom the Software is furnished to do so, subject to
#   the following conditions:
#
#   - Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimers.
#   - Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimers in the
#     documentation and/or other materials provided with the distribution.
#   - Neither the names of University of Illinois, NCSA, nor the names of
#     its contributors may be used to endorse or promote products derived
#     from this Software without specific prior written permission.
#
#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
#   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
#   IN NO EVENT SHALL THE CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR
#   ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
#   CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH
#   THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH THE SOFTWARE.
#
# ----------------------------------------------------------------------------
# WHAT CHANGED FROM UPSTREAM
# ----------------------------------------------------------------------------
# Ported from PEcAn.ED2 1.8.2.9000 (GitHub sha 770075d, models/ed
# subdirectory), extracted directly from the installed package via
# `print(PEcAn.ED2::read_ed2in)` etc. (source form, not reverse-engineered).
# Changes are limited to removing PEcAn-internal dependencies from code
# paths this repo's ED2IN-builder scripts never exercise:
#
#   - `PEcAn.logger::logger.{warn,severe,debug}()` calls replaced with base
#     `warning()`/`stop()`/(dropped, debug-only) - purely a logging-backend
#     swap, same conditions trigger the same outcomes.
#   - `lubridate::year()/month()/day()` replaced with base
#     `as.integer(format(x, "%Y"))` etc. - avoids adding lubridate as a
#     dependency for 3 one-line date-component extractions.
#   - `modify_ed2in()`'s `veg_prefix` argument (which calls
#     `PEcAn.utils::match_file()` and `read_ed_veg()`, both from other
#     PEcAn packages) is not ported - this repo's ED2IN-builder scripts
#     always set `SFILIN`/`IED_INIT_MODE` directly as raw namelist
#     arguments instead (see build_bci_ed2in.R), so this argument is
#     replaced with a clear error if anyone passes it, rather than being
#     silently unsupported.
#
# Everything else - the ED2IN parsing regex, the namelist-modification
# logic, the multi-line-array write behavior, and the two known bugs noted
# below - is preserved exactly, so behavior here matches what this repo has
# already tested against PEcAn.ED2 itself.
#
# ----------------------------------------------------------------------------
# TWO KNOWN BUGS, INHERITED FROM UPSTREAM AND STILL PRESENT HERE
# ----------------------------------------------------------------------------
# Confirmed by direct testing against this repo's ED2IN template before
# this file existed (see build_bci_ed2in.R, which still works around both):
#
#   1. read_ed2in() only captures the first physical line of a multi-line
#      array parameter (e.g. NL%SLZ spans 2 physical lines for NZG=16
#      layers; read_ed2in() silently returns only the first 10 values).
#      Callers must re-assign such arrays explicitly after reading.
#   2. Nothing changed here affects this one, since it was never in
#      modify_ed2in()'s core (dots-passthrough) logic - it was specific to
#      the now-unported `met_driver`/`output_dir` convenience arguments,
#      which called normalizePath() and baked in absolute host paths. This
#      repo's scripts set ED_MET_DRIVER_DB/FFILOUT/SFILOUT/etc. directly as
#      raw uppercase namelist arguments instead, which are passed straight
#      through unmodified (see modify_ed2in()'s dots-passthrough below).

# =============================================================================
# read_ed2in() - parse an ED2IN namelist file into a named list
# =============================================================================
read_ed2in <- function(filename) {
  raw_file <- readLines(filename)
  ed2in_tag_rxp <- paste0(
    "^[[:blank:]]*", "NL%([[:graph:]]+)",
    "[[:blank:]]+=[[:blank:]]*", "(",
    "[[:digit:].-]+(,[[:blank:]]*[[:digit:].-]+)*", "|",
    "@.*?@", "|", "'[[:graph:][:blank:]]*'", ")", "[[:blank:]]*!?.*$"
  )
  tag_lines <- grep(ed2in_tag_rxp, raw_file, perl = TRUE)
  sub_file <- raw_file[tag_lines]
  tags <- gsub(ed2in_tag_rxp, "\\1", sub_file, perl = TRUE)
  values <- gsub(ed2in_tag_rxp, "\\2", sub_file, perl = TRUE)
  all_lines <- seq_along(raw_file)
  comment_linenos <- all_lines[!all_lines %in% tag_lines]
  comment_values <- raw_file[comment_linenos]
  values_list <- as.list(values)
  numeric_values <- !is.na(suppressWarnings(as.numeric(values))) |
    grepl("^@.*?@$", values)
  if (any(grepl("^@.*?@$", values))) {
    warning("Old substitution tags present in ED2IN file")
  }
  values_list[numeric_values] <- suppressWarnings(lapply(
    values_list[numeric_values], as.numeric
  ))
  numlist_values <- grep(
    "[[:digit:].-]+(,[[:blank:]]*[[:digit:].-]+)+", values
  )
  values_list[numlist_values] <- lapply(
    values_list[numlist_values],
    function(x) as.numeric(strsplit(x, split = ",")[[1]])
  )
  charlist_values <- grep("'.*?'(,'.*?')+", values)
  values_list[charlist_values] <- lapply(
    values_list[charlist_values],
    function(x) strsplit(x, split = ",")[[1]]
  )
  quoted_values <- grep("'.*?'", values)
  values_list[quoted_values] <- lapply(
    values_list[quoted_values], gsub,
    pattern = "'", replacement = ""
  )
  structure(values_list,
    names = tags, class = c("ed2in", "list"),
    comment_linenos = comment_linenos, comment_values = comment_values,
    value_linenos = tag_lines
  )
}

# =============================================================================
# modify_ed2in() - apply structured overrides to a parsed ED2IN list
# =============================================================================
# Supported convenience arguments: latitude, longitude, start_date, end_date,
# run_name, include_these_pft, pecan_defaults, add_if_missing, check_paths
# (check_paths is accepted for call-compatibility with existing scripts but
# is a no-op here, since it only ever gated the now-unported veg_prefix/
# met_driver validation).
# Any other named argument passed via `...` in ALL CAPS (matching ED2's own
# NL%<NAME> convention) is applied as a raw namelist override - this is how
# this repo's ED2IN-builder scripts set RUNTYPE, IMOUTPUT, SFILIN, etc.
# directly. `veg_prefix`/`met_driver`/`EDI_path`/`output_dir`/`run_dir`/
# `runtype`/`output_types` from upstream PEcAn.ED2 are intentionally not
# ported (see header comment) - this repo's scripts never use them.
modify_ed2in <- function(ed2in, ...,
                          veg_prefix = NULL,
                          latitude = NULL, longitude = NULL,
                          start_date = NULL, end_date = NULL,
                          run_name = NULL,
                          include_these_pft = NULL,
                          pecan_defaults = FALSE,
                          add_if_missing = FALSE,
                          check_paths = TRUE,
                          .dots = list()) {
  if (!is.null(veg_prefix)) {
    stop(
      "modify_ed2in()'s `veg_prefix` argument is not supported by this ",
      "repo's vendored ed2in_io.R (see its header comment) - set SFILIN/",
      "IED_INIT_MODE directly as raw namelist arguments instead."
    )
  }
  if (!is.null(run_name)) {
    ed2in[["EXPNME"]] <- run_name
  }
  if (is.null(.dots)) {
    .dots <- list()
  }
  dots <- utils::modifyList(.dots, list(...))
  is_upper <- names(dots) == toupper(names(dots))
  lower_args <- names(dots)[!is_upper]
  if (length(lower_args) > 0) {
    warning(
      "The following lowercase arguments are not supported, and will be ",
      "dropped: ", paste(lower_args, collapse = ", ")
    )
  }
  if (pecan_defaults) {
    ed2in[["IMETAVG"]] <- -1
    ed2in[["IPHEN_SCHEME"]] <- 0
    ed2in[["IPHENYS1"]] <- NA
    ed2in[["IPHENYSF"]] <- NA
    ed2in[["PHENPATH"]] <- ""
    ed2in[["IED_INIT_MODE"]] <- 0
    ed2in[["SOIL_DATABASE"]] <- ""
    ed2in[["LU_DATABASE"]] <- ""
  }
  if (!is.null(latitude)) {
    ed2in[["POI_LAT"]] <- latitude
  }
  if (!is.null(longitude)) {
    ed2in[["POI_LON"]] <- longitude
  }
  if (!is.null(start_date)) {
    ed2in[["IYEARA"]] <- ed2in[["IYEARH"]] <- as.integer(format(start_date, "%Y"))
    ed2in[["IMONTHA"]] <- ed2in[["IMONTHH"]] <- as.integer(format(start_date, "%m"))
    ed2in[["IDATEA"]] <- ed2in[["IDATEH"]] <- as.integer(format(start_date, "%d"))
    ed2in[["ITIMEA"]] <- ed2in[["ITIMEH"]] <- as.numeric(strftime(start_date, "%H%M", tz = "UTC"))
    ed2in[["METCYC1"]] <- ed2in[["IYEARA"]]
  }
  if (!is.null(end_date)) {
    ed2in[["IYEARZ"]] <- as.integer(format(end_date, "%Y"))
    ed2in[["IMONTHZ"]] <- as.integer(format(end_date, "%m"))
    ed2in[["IDATEZ"]] <- as.integer(format(end_date, "%d"))
    ed2in[["ITIMEZ"]] <- as.numeric(strftime(end_date, "%H%M", tz = "UTC"))
    ed2in[["METCYCF"]] <- ed2in[["IYEARZ"]]
  }
  if (!is.null(include_these_pft)) {
    if (!is.numeric(include_these_pft)) {
      stop("include_these_pft must be numeric vector")
    }
    ed2in[["INCLUDE_THESE_PFT"]] <- include_these_pft
  }
  namelist_args <- dots[is_upper]
  in_ed2in <- names(namelist_args) %in% names(ed2in)
  if (sum(!in_ed2in) > 0) {
    new_args <- namelist_args[!in_ed2in]
    if (!add_if_missing) {
      warning(
        "The following namelist arguments were missing from ED2IN and ",
        "will be ignored because `add_if_missing = FALSE`: ",
        paste(names(new_args), collapse = ", ")
      )
      namelist_args <- namelist_args[in_ed2in]
    }
  }
  ed2in <- utils::modifyList(ed2in, namelist_args)
  ed2in
}

# =============================================================================
# write_ed2in() - serialize a parsed/modified ED2IN list back to a namelist
# file. S3-dispatched (as upstream) so write_ed2in(ed2in, ...) keeps working
# on the "ed2in" objects read_ed2in() produces.
# =============================================================================
write_ed2in <- function(ed2in, filename, custom_header = character(), barebones = FALSE) {
  UseMethod("write_ed2in", ed2in)
}

# Internal helper: format every NL%<tag> = <value> line for output.
tags2char <- function(ed2in) {
  char_values <- vapply(ed2in, is.character, logical(1))
  na_values <- vapply(ed2in, function(x) all(is.na(x)), logical(1))
  quoted_vals <- ed2in
  quoted_vals[char_values] <- lapply(quoted_vals[char_values], shQuote)
  quoted_vals[na_values] <- lapply(quoted_vals[na_values], function(x) "")
  values_vec <- vapply(quoted_vals, paste, character(1), collapse = ",")
  sprintf("   NL%%%s = %s", names(values_vec), values_vec)
}

write_ed2in.ed2in <- function(ed2in, filename, custom_header = character(), barebones = FALSE) {
  tags_values_vec <- tags2char(ed2in)
  if (isTRUE(barebones)) {
    write_ed2in.default(ed2in, filename, custom_header, barebones)
    return(invisible(NULL))
  }
  nvalues <- length(tags_values_vec)
  ncomments <- length(attr(ed2in, "comment_values"))
  file_body <- character(nvalues + ncomments)
  file_body[attr(ed2in, "comment_linenos")] <- attr(ed2in, "comment_values")
  file_body[attr(ed2in, "value_linenos")] <-
    tags_values_vec[seq_along(attr(ed2in, "value_linenos"))]
  if (length(tags_values_vec) > length(attr(ed2in, "value_linenos"))) {
    end_line <- grep("\\$END", file_body) - 1
    new_tags <- tags_values_vec[(length(attr(ed2in, "value_linenos")) + 1):length(tags_values_vec)]
    file_body <- c(file_body[1:end_line], new_tags, "$END")
  }
  header <- c(
    "!=======================================",
    "!=======================================",
    "!  ED2 namelist file",
    "!  Generated by R-tools/ed2in_io.R (vendored from PEcAn.ED2 - see file header)",
    "!  Additional user comments below: ",
    paste0("!   ", custom_header),
    "!---------------------------------------"
  )
  writeLines(c(header, file_body), filename)
}

write_ed2in.default <- function(ed2in, filename, custom_header = character(), barebones = FALSE) {
  tags_values_vec <- tags2char(ed2in)
  header <- c(
    "!=======================================",
    "!=======================================",
    "!  ED2 namelist file",
    "!  Generated by R-tools/ed2in_io.R (vendored from PEcAn.ED2 - see file header)",
    "!  Additional user comments below: ",
    paste0("!   ", custom_header),
    "!---------------------------------------"
  )
  writeLines(
    c(
      header, "$ED_NL", tags_values_vec, "$END",
      "!==========================================================================================!",
      "!==========================================================================================!"
    ),
    filename
  )
}
