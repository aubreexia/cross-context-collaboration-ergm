#!/usr/bin/env Rscript

# Refit the within-domain M4 random-effects models from the released aggregate
# input table. This script needs no individual-level data or Excel workbooks.
#
# Example:
#   Rscript scripts/r/09_verify_public_meta_results.R results/meta

args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 1L) {
  stop("Use at most one argument: the directory containing M4_meta_input_estimates.csv.", call. = FALSE)
}

input_dir <- if (length(args) == 1L) {
  normalizePath(args[[1L]], mustWork = TRUE)
} else {
  normalizePath(file.path("results", "meta"), mustWork = TRUE)
}

if (!requireNamespace("metafor", quietly = TRUE)) {
  stop(
    "Missing package 'metafor'. Run source('environment/install_r_packages.R') first.",
    call. = FALSE
  )
}

input_file <- file.path(input_dir, "M4_meta_input_estimates.csv")
if (!file.exists(input_file)) {
  stop("Cannot find: ", input_file, call. = FALSE)
}

input <- read.csv(input_file, stringsAsFactors = FALSE, check.names = FALSE)
required <- c("domain", "term", "construct", "theta", "se")
missing <- setdiff(required, names(input))
if (length(missing) > 0L) {
  stop("Missing required column(s): ", paste(missing, collapse = ", "), call. = FALSE)
}

input$theta <- as.numeric(input$theta)
input$se <- as.numeric(input$se)
if (anyNA(input$theta) || anyNA(input$se) || any(input$se <= 0)) {
  stop("theta and se must be finite numeric values with se > 0.", call. = FALSE)
}

keys <- unique(input[c("domain", "term", "construct")])
results <- vector("list", nrow(keys))

for (index in seq_len(nrow(keys))) {
  key <- keys[index, , drop = FALSE]
  subset <- input[
    input$domain == key$domain & input$term == key$term,
    ,
    drop = FALSE
  ]
  fit <- metafor::rma.uni(
    yi = subset$theta,
    sei = subset$se,
    method = "REML",
    test = "knha"
  )
  prediction <- predict(fit, level = 95)
  results[[index]] <- data.frame(
    domain = key$domain,
    term = key$term,
    construct = key$construct,
    k = fit$k,
    pooled_log_odds = as.numeric(fit$b),
    pooled_se_KH = as.numeric(fit$se),
    pooled_ci_lower = fit$ci.lb,
    pooled_ci_upper = fit$ci.ub,
    pooled_p_value_KH = fit$pval,
    pooled_odds_ratio = exp(as.numeric(fit$b)),
    pooled_OR_ci_lower = exp(fit$ci.lb),
    pooled_OR_ci_upper = exp(fit$ci.ub),
    tau2_REML = fit$tau2,
    I2_percent = fit$I2,
    H2 = fit$H2,
    Cochran_Q = fit$QE,
    Q_df = fit$k - fit$p,
    Q_p_value = fit$QEp,
    prediction_log_odds_lower = prediction$pi.lb,
    prediction_log_odds_upper = prediction$pi.ub,
    prediction_OR_lower = exp(prediction$pi.lb),
    prediction_OR_upper = exp(prediction$pi.ub),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

output <- do.call(rbind, results)
output_file <- file.path(input_dir, "M4_random_effects_meta_recomputed.csv")
write.csv(output, output_file, row.names = FALSE)
message("Saved: ", output_file)
