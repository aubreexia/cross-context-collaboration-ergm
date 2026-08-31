# ================================================================
# SciSciNet M4 goodness-of-fit diagnostics
#
# This script runs GOF diagnostics for the saved M4 ERGM objects. By
# default it runs the ten separate-journal models only. The pooled
# block-diagonal GOF can be enabled explicitly, but it can require more
# than 16 GB of memory for these data.
#
# Example:
#   SCISCINET_SEPARATE_MODELS_DIR=results/recomputed/separate_m0_m4/journal_outputs \
#   SCISCINET_GOF_OUTPUT_DIR=results/recomputed/m4_gof \
#   SCISCINET_GOF_NSIM=100 \
#   Rscript scripts/03_run_m4_gof.R
# ================================================================

SCRIPT_VERSION <- "SciSciNet M4 GOF 2026-08-31 v1.0"
message("Running: ", SCRIPT_VERSION)

get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0L) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[[1L]]))))
  }
  normalizePath(getwd(), mustWork = TRUE)
}

as_flag <- function(x) {
  tolower(trimws(x)) %in% c("1", "true", "t", "yes", "y")
}

repo_root <- normalizePath(file.path(get_script_dir(), ".."), mustWork = TRUE)
separate_models_dir <- Sys.getenv(
  "SCISCINET_SEPARATE_MODELS_DIR",
  unset = file.path(repo_root, "results", "recomputed", "separate_m0_m4", "journal_outputs")
)
block_models_rds <- Sys.getenv(
  "SCISCINET_BLOCK_MODELS_RDS",
  unset = file.path(repo_root, "results", "recomputed", "block_m0_m4", "block_diagonal_journal_ergm_models.rds")
)
output_dir <- Sys.getenv(
  "SCISCINET_GOF_OUTPUT_DIR",
  unset = file.path(repo_root, "results", "recomputed", "m4_gof")
)
nsim <- suppressWarnings(as.integer(Sys.getenv("SCISCINET_GOF_NSIM", unset = "100")))
seed <- suppressWarnings(as.integer(Sys.getenv("SCISCINET_GOF_SEED", unset = "20260831")))
run_block <- as_flag(Sys.getenv("SCISCINET_RUN_BLOCK_GOF", unset = "false"))

if (is.na(nsim) || nsim < 1L) {
  stop("SCISCINET_GOF_NSIM must be a positive integer.", call. = FALSE)
}
if (is.na(seed)) {
  stop("SCISCINET_GOF_SEED must be an integer.", call. = FALSE)
}

required_packages <- c("ergm", "network")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0L) {
  stop(
    paste0("Missing required R package(s): ", paste(missing_packages, collapse = ", ")),
    call. = FALSE
  )
}
suppressPackageStartupMessages({
  library(ergm)
  library(network)
})

if (!dir.exists(separate_models_dir)) {
  stop(paste0("Separate-model directory not found: ", separate_models_dir), call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

run_one_gof <- function(fit, unit, analysis_type, output_subdir, run_seed) {
  dir.create(output_subdir, recursive = TRUE, showWarnings = FALSE)
  set.seed(run_seed)

  gof_result <- tryCatch(
    gof(
      fit,
      GOF = ~model + distance + degree + espartners + dspartners,
      control = control.gof.ergm(nsim = nsim)
    ),
    error = function(e) e
  )

  if (inherits(gof_result, "error")) {
    return(data.frame(
      analysis_type = analysis_type,
      unit = unit,
      status = "failed",
      error = conditionMessage(gof_result),
      stringsAsFactors = FALSE
    ))
  }

  saveRDS(gof_result, file.path(output_subdir, "m4_gof.rds"))
  writeLines(capture.output(print(gof_result)), file.path(output_subdir, "m4_gof.txt"))

  plot_error <- tryCatch({
    grDevices::pdf(file.path(output_subdir, "m4_gof.pdf"), width = 12, height = 9, onefile = TRUE)
    on.exit(grDevices::dev.off(), add = TRUE)
    plot(gof_result)
    NULL
  }, error = function(e) e)
  if (inherits(plot_error, "error")) {
    return(data.frame(
      analysis_type = analysis_type,
      unit = unit,
      status = "failed_plot",
      error = conditionMessage(plot_error),
      stringsAsFactors = FALSE
    ))
  }

  data.frame(
    analysis_type = analysis_type,
    unit = unit,
    status = "ok",
    error = NA_character_,
    stringsAsFactors = FALSE
  )
}

model_files <- sort(list.files(
  separate_models_dir,
  pattern = "_ERGM_models\\.rds$",
  full.names = TRUE
))
if (length(model_files) == 0L) {
  stop("No *_ERGM_models.rds files found in the separate-model directory.", call. = FALSE)
}

status_rows <- list()
for (index in seq_along(model_files)) {
  model_file <- model_files[[index]]
  unit <- sub("_ERGM_models\\.rds$", "", basename(model_file))
  models <- tryCatch(readRDS(model_file), error = function(e) e)
  if (inherits(models, "error") || is.null(models[["m4_full"]]) || !inherits(models[["m4_full"]], "ergm")) {
    error_text <- if (inherits(models, "error")) conditionMessage(models) else "m4_full ERGM object is unavailable."
    status_rows[[length(status_rows) + 1L]] <- data.frame(
      analysis_type = "separate", unit = unit, status = "failed", error = error_text,
      stringsAsFactors = FALSE
    )
    next
  }
  message("Running GOF for ", unit, " ...")
  status_rows[[length(status_rows) + 1L]] <- run_one_gof(
    models[["m4_full"]],
    unit,
    "separate",
    file.path(output_dir, "separate", unit),
    seed + index - 1L
  )
}

if (run_block) {
  if (!file.exists(block_models_rds)) {
    status_rows[[length(status_rows) + 1L]] <- data.frame(
      analysis_type = "block_diagonal", unit = "all_journals", status = "failed",
      error = paste0("Block-model file not found: ", block_models_rds), stringsAsFactors = FALSE
    )
  } else {
    models <- tryCatch(readRDS(block_models_rds), error = function(e) e)
    if (inherits(models, "error") || is.null(models[["m4_full"]]) || !inherits(models[["m4_full"]], "ergm")) {
      error_text <- if (inherits(models, "error")) conditionMessage(models) else "m4_full ERGM object is unavailable."
      status_rows[[length(status_rows) + 1L]] <- data.frame(
        analysis_type = "block_diagonal", unit = "all_journals", status = "failed",
        error = error_text, stringsAsFactors = FALSE
      )
    } else {
      message("Running GOF for pooled block-diagonal model ...")
      status_rows[[length(status_rows) + 1L]] <- run_one_gof(
        models[["m4_full"]],
        "all_journals",
        "block_diagonal",
        file.path(output_dir, "block_diagonal"),
        seed + length(model_files)
      )
    }
  }
}

run_log <- do.call(rbind, status_rows)
write.csv(run_log, file.path(output_dir, "GOF_run_log.csv"), row.names = FALSE)
writeLines(
  c(
    paste("Script version:", SCRIPT_VERSION),
    paste("Number of simulations:", nsim),
    paste("Seed:", seed),
    paste("Block GOF requested:", run_block),
    "",
    capture.output(print(run_log))
  ),
  file.path(output_dir, "README.txt")
)
message("[SAVED] ", normalizePath(output_dir, mustWork = FALSE))
