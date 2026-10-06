#!/usr/bin/env Rscript

# Within-domain random-effects meta-analysis of separate-network M4 ERGMs.
#
# Run from the folder containing the three Excel workbooks:
#   Rscript run_within_domain_meta_m4.R
#
# Or provide that folder explicitly:
#   Rscript run_within_domain_meta_m4.R "/path/to/sensitive"
#
# Required inputs (one of each; suffixes such as "(1)" are fine):
#   1) 01_separate_ergm...xlsx              (MyDreamTeam)
#   2) all_language_ergm_results...xlsx     (GHTorrent)
#   3) all_journal_ergm_results...xlsx      (SciSciNet)

ensure_package <- function(package_name) {
  if (!requireNamespace(package_name, quietly = TRUE)) {
    install.packages(package_name, repos = "https://cloud.r-project.org")
  }
}

invisible(lapply(c("openxlsx", "metafor"), ensure_package))
suppressPackageStartupMessages(library(metafor))

# The script uses the current directory unless an input directory is supplied.
args <- commandArgs(trailingOnly = TRUE)
input_dir <- if (length(args) >= 1L) {
  normalizePath(args[[1L]], mustWork = TRUE)
} else {
  normalizePath(getwd(), mustWork = TRUE)
}

# The five theory-relevant M4 terms. "edges" is intentionally excluded.
term_labels <- c(
  "edgecov.prior" = "Prior collaboration",
  "nodecov.expertise_model_z" = "Expertise level",
  "absdiff.expertise_model_z" = "Expertise absolute difference",
  "nodecov.leadership_model_z" = "Status-related attribute level",
  "absdiff.leadership_model_z" = "Status-related attribute difference"
)

find_one_file <- function(pattern, label) {
  hits <- list.files(
    input_dir,
    pattern = pattern,
    full.names = TRUE,
    ignore.case = TRUE
  )

  # Ignore temporary Excel lock files if Excel is open.
  hits <- hits[!grepl("^~\\$", basename(hits))]

  if (length(hits) != 1L) {
    found <- if (length(hits) == 0L) "(none)" else paste(basename(hits), collapse = "\n  ")
    stop(
      sprintf(
        paste0(
          "Could not identify the %s workbook. Expected exactly one .xlsx file matching:\n",
          "  %s\nFound:\n  %s\n\n",
          "Keep only the three required input workbooks in this folder, or edit the pattern in this script."
        ),
        label, pattern, found
      ),
      call. = FALSE
    )
  }
  normalizePath(hits)
}

input_files <- list(
  MyDreamTeam = list(
    path = find_one_file("^01[_ -]?separate[_ -]?ergm.*\\.xlsx$", "MyDreamTeam"),
    sheet = "coefficients_M4",
    id_col = "session"
  ),
  GHTorrent = list(
    path = find_one_file("^all[_ -]?language[_ -]?ergm[_ -]?results.*\\.xlsx$", "GHTorrent"),
    sheet = "coefficients_all_models",
    id_col = "language"
  ),
  SciSciNet = list(
    path = find_one_file("^all[_ -]?journal[_ -]?ergm[_ -]?results.*\\.xlsx$", "SciSciNet"),
    sheet = "coefficients_M4",
    id_col = "journal"
  )
)

as_number <- function(x) {
  x <- trimws(as.character(x))
  x[x %in% c("", "NA", "N/A", "NULL")] <- NA_character_
  suppressWarnings(as.numeric(gsub(",", "", x, fixed = TRUE)))
}

read_domain_results <- function(domain, config) {
  dat <- openxlsx::read.xlsx(
    xlsxFile = config$path,
    sheet = config$sheet,
    check.names = FALSE
  )
  names(dat) <- trimws(names(dat))

  required_columns <- c(config$id_col, "model", "term", "Estimate", "Std_Error", "status")
  missing_columns <- setdiff(required_columns, names(dat))
  if (length(missing_columns) > 0L) {
    stop(
      sprintf(
        "%s: sheet '%s' is missing required column(s): %s",
        domain, config$sheet, paste(missing_columns, collapse = ", ")
      ),
      call. = FALSE
    )
  }

  model <- tolower(trimws(as.character(dat$model)))
  status <- tolower(trimws(as.character(dat$status)))
  term <- trimws(as.character(dat$term))
  keep <- !is.na(model) & !is.na(status) &
    model == "m4_full" & status == "ok" & term %in% names(term_labels)

  out <- data.frame(
    domain = domain,
    network = trimws(as.character(dat[[config$id_col]][keep])),
    term = term[keep],
    construct = unname(term_labels[term[keep]]),
    theta = as_number(dat$Estimate[keep]),
    se = as_number(dat$Std_Error[keep]),
    stringsAsFactors = FALSE
  )

  if (nrow(out) == 0L) {
    stop(
      sprintf("%s: no usable m4_full / status == 'ok' rows were found.", domain),
      call. = FALSE
    )
  }

  bad_rows <- !is.finite(out$theta) | !is.finite(out$se) | out$se <= 0 |
    is.na(out$network) | out$network == ""
  if (any(bad_rows)) {
    stop(
      sprintf(
        "%s: invalid estimate, SE, or network identifier in row(s): %s",
        domain, paste(which(bad_rows), collapse = ", ")
      ),
      call. = FALSE
    )
  }

  out
}

meta_input <- do.call(
  rbind,
  Map(read_domain_results, names(input_files), input_files)
)
rownames(meta_input) <- NULL

# These checks protect against a workbook that includes duplicate models or
# does not contain all ten networks for a domain/term combination.
duplicate_rows <- duplicated(meta_input[c("domain", "network", "term")])
if (any(duplicate_rows)) {
  stop(
    paste0(
      "Duplicate domain/network/term rows found:\n",
      paste(capture.output(print(meta_input[duplicate_rows, ])), collapse = "\n")
    ),
    call. = FALSE
  )
}

count_check <- aggregate(
  network ~ domain + construct,
  data = meta_input,
  FUN = function(x) length(unique(x))
)
names(count_check)[names(count_check) == "network"] <- "k"
count_check$domain <- factor(count_check$domain, levels = names(input_files))
count_check$construct <- factor(count_check$construct, levels = unname(term_labels))
count_check <- count_check[order(count_check$domain, count_check$construct), ]
count_check$domain <- as.character(count_check$domain)
count_check$construct <- as.character(count_check$construct)
rownames(count_check) <- NULL

if (nrow(count_check) != length(input_files) * length(term_labels) || any(count_check$k != 10L)) {
  stop(
    paste0(
      "Expected 10 separate-network estimates for each domain and focal term.\n",
      "Observed counts:\n",
      paste(capture.output(print(count_check, row.names = FALSE)), collapse = "\n")
    ),
    call. = FALSE
  )
}

# A separate output folder is made on every run, so existing results are not overwritten.
output_dir <- file.path(
  input_dir,
  paste0("within_domain_random_effects_meta_M4_", format(Sys.time(), "%Y%m%d_%H%M%S"))
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(output_dir)) {
  stop("Could not create the output directory: ", output_dir, call. = FALSE)
}

message("Input directory: ", input_dir)
message("Output directory: ", output_dir)
message("\nInput workbooks:")
for (domain in names(input_files)) {
  message("  ", domain, ": ", basename(input_files[[domain]]$path))
}

fits <- list()
summary_rows <- list()
row_index <- 0L

for (domain in names(input_files)) {
  for (term_name in names(term_labels)) {
    dat <- meta_input[meta_input$domain == domain & meta_input$term == term_name, ]
    dat <- dat[order(dat$network), ]

    # REML estimates tau^2; Knapp-Hartung is used for the pooled-effect
    # confidence interval and p-value. All effects remain on the ERGM log-odds scale.
    fit <- metafor::rma.uni(
      yi = theta,
      sei = se,
      data = dat,
      method = "REML",
      test = "knha"
    )
    prediction <- predict(fit, level = 95)

    row_index <- row_index + 1L
    summary_rows[[row_index]] <- data.frame(
      domain = domain,
      term = term_name,
      construct = unname(term_labels[term_name]),
      k = fit$k,
      pooled_log_odds = as.numeric(fit$b),
      pooled_se_KH = as.numeric(fit$se),
      pooled_ci_lower = as.numeric(fit$ci.lb),
      pooled_ci_upper = as.numeric(fit$ci.ub),
      pooled_p_value_KH = as.numeric(fit$pval),
      pooled_odds_ratio = exp(as.numeric(fit$b)),
      pooled_OR_ci_lower = exp(as.numeric(fit$ci.lb)),
      pooled_OR_ci_upper = exp(as.numeric(fit$ci.ub)),
      tau2_REML = as.numeric(fit$tau2),
      I2_percent = as.numeric(fit$I2),
      H2 = as.numeric(fit$H2),
      Cochran_Q = as.numeric(fit$QE),
      Q_df = as.integer(fit$k - fit$p),
      Q_p_value = as.numeric(fit$QEp),
      prediction_log_odds_lower = as.numeric(prediction$pi.lb),
      prediction_log_odds_upper = as.numeric(prediction$pi.ub),
      prediction_OR_lower = exp(as.numeric(prediction$pi.lb)),
      prediction_OR_upper = exp(as.numeric(prediction$pi.ub)),
      stringsAsFactors = FALSE
    )
    fits[[paste(domain, term_name, sep = "__")]] <- fit
  }
}

meta_summary <- do.call(rbind, summary_rows)
rownames(meta_summary) <- NULL

utils::write.csv(
  meta_input,
  file.path(output_dir, "M4_meta_input_estimates.csv"),
  row.names = FALSE,
  na = ""
)
utils::write.csv(
  count_check,
  file.path(output_dir, "M4_meta_count_check.csv"),
  row.names = FALSE,
  na = ""
)
utils::write.csv(
  meta_summary,
  file.path(output_dir, "M4_random_effects_meta_summary.csv"),
  row.names = FALSE,
  na = ""
)
saveRDS(fits, file.path(output_dir, "M4_random_effects_meta_models.rds"))
capture.output(sessionInfo(), file = file.path(output_dir, "R_session_info.txt"))

# One forest plot per domain-term combination. Values on the plot are odds ratios,
# while the model is fitted on the log-odds (ERGM coefficient) scale.
plot_file <- file.path(output_dir, "M4_random_effects_meta_forest_plots.pdf")
grDevices::pdf(plot_file, width = 11, height = 7)
for (domain in names(input_files)) {
  for (term_name in names(term_labels)) {
    key <- paste(domain, term_name, sep = "__")
    dat <- meta_input[meta_input$domain == domain & meta_input$term == term_name, ]
    dat <- dat[order(dat$network), ]
    metafor::forest(
      fits[[key]],
      slab = dat$network,
      atransf = exp,
      refline = 0,
      xlab = "Odds ratio (reference line = 1)",
      main = paste(domain, "—", unname(term_labels[term_name])),
      cex = 0.9
    )
  }
}
grDevices::dev.off()

message("\nCompleted. Main result table:")
print(meta_summary, row.names = FALSE)
message("\nUse M4_random_effects_meta_summary.csv for the manuscript table/text.")
