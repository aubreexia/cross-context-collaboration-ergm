# ============================================================================
# SciSciNet M4 four-panel goodness-of-fit (GOF)
# Separate journal M4 models + pooled block-diagonal M4 model
#
# Put this file directly inside FullJournal, then run:
#   Rscript run_sciscinet_m4_gof.R
# ============================================================================

get_script_dir <- function() {
  file_arg <- grep(
    "^--file=",
    commandArgs(trailingOnly = FALSE),
    value = TRUE
  )

  if (length(file_arg) > 0L) {
    script_path <- sub("^--file=", "", file_arg[[1L]])
    return(dirname(normalizePath(script_path, mustWork = TRUE)))
  }

  normalizePath(getwd(), mustWork = TRUE)
}

user_args <- commandArgs(trailingOnly = TRUE)
if (length(user_args) > 1L) {
  stop("Use at most one argument: the FullJournal input directory.", call. = FALSE)
}
ROOT_DIR <- if (length(user_args) == 1L) {
  normalizePath(user_args[[1L]], mustWork = TRUE)
} else {
  get_script_dir()
}

# These are the exact M0--M4 MLE result folders already in FullJournal.
SEPARATE_MODEL_DIR <- file.path(
  ROOT_DIR,
  "separate_results_m0_m4_mle",
  "journal_outputs"
)

BLOCK_MODEL_FILE <- file.path(
  ROOT_DIR,
  "block_diagonal_journal_ergm_results_m0_m4_mle",
  "block_diagonal_journal_ergm_models.rds"
)

OUTPUT_DIR <- file.path(ROOT_DIR, "m4_gof")

# For a quick test, temporarily set NSIM <- 20L.
# Use 100 simulations for the final supplementary GOF output.
NSIM <- 100L
MCMC_BURNIN <- 100000L
MCMC_INTERVAL <- 4096L
SEED <- 20260826L


# ----------------------------------------------------------------------------
# 1. Packages and path validation
# ----------------------------------------------------------------------------

required_packages <- c("network", "ergm")

missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0L) {
  stop(
    paste0(
      "Missing R package(s): ", paste(missing_packages, collapse = ", "),
      "\nInstall them with:\ninstall.packages(c(",
      paste(sprintf('"%s"', missing_packages), collapse = ", "),
      "))"
    ),
    call. = FALSE
  )
}

suppressPackageStartupMessages({
  library(network)
  library(ergm)
})

if (!dir.exists(SEPARATE_MODEL_DIR)) {
  stop(
    "Cannot find the separate-model folder:\n", SEPARATE_MODEL_DIR,
    "\n\nCheck the folder name at the top of this script.",
    call. = FALSE
  )
}

if (!file.exists(BLOCK_MODEL_FILE)) {
  stop(
    "Cannot find the pooled block-model file:\n", BLOCK_MODEL_FILE,
    "\n\nCheck the folder name at the top of this script.",
    call. = FALSE
  )
}

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)


# ----------------------------------------------------------------------------
# 2. Helper functions
# ----------------------------------------------------------------------------

safe_name <- function(x) {
  x <- gsub("[^A-Za-z0-9_-]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  if (nchar(x) == 0L) "model" else x
}

read_m4_model <- function(rds_file) {
  models <- readRDS(rds_file)

  if (!is.list(models) || is.null(models[["m4_full"]])) {
    stop(
      "The RDS file does not contain m4_full:\n", rds_file,
      call. = FALSE
    )
  }

  fit <- models[["m4_full"]]

  if (!inherits(fit, "ergm")) {
    stop(
      "m4_full is not a successful ergm fit:\n", rds_file,
      call. = FALSE
    )
  }

  fit
}

extract_gof_statistics <- function(gof_object) {
  summary_names <- grep("^summary\\.", names(gof_object), value = TRUE)

  if (length(summary_names) == 0L) {
    return(data.frame())
  }

  pieces <- lapply(summary_names, function(summary_name) {
    tab <- as.data.frame(gof_object[[summary_name]], check.names = FALSE)

    category <- rownames(tab)
    if (is.null(category)) {
      category <- as.character(seq_len(nrow(tab)))
    }

    out <- data.frame(
      GOF_component = sub("^summary\\.", "", summary_name),
      category = category,
      tab,
      check.names = FALSE,
      stringsAsFactors = FALSE
    )

    rownames(out) <- NULL
    out
  })

  do.call(rbind, pieces)
}

save_four_panel_gof <- function(gof_result, label, output_file, type = c("pdf", "png")) {
  type <- match.arg(type)

  if (identical(type, "pdf")) {
    grDevices::pdf(output_file, width = 16, height = 10, onefile = TRUE)
  } else {
    grDevices::png(output_file, width = 2400, height = 1800, res = 220)
  }

  old_par <- graphics::par(no.readonly = TRUE)
  tryCatch(
    {
      # Exactly four GOF components are requested below, so a 2 x 2 layout
      # produces one complete diagnostic figure rather than multiple pages.
      graphics::par(
        mfrow = c(2, 2),
        mar = c(4.2, 4.2, 2.8, 1.2),
        oma = c(0, 0, 2.0, 0)
      )
      plot(gof_result, cex.axis = 0.65)
      graphics::mtext(
        paste0(label, ": M4 goodness-of-fit diagnostics"),
        side = 3,
        outer = TRUE,
        line = 0.4,
        cex = 1.25
      )
    },
    finally = {
      graphics::par(old_par)
      grDevices::dev.off()
    }
  )
}

run_one_gof <- function(m4_fit, label, output_folder, seed) {
  dir.create(output_folder, recursive = TRUE, showWarnings = FALSE)

  set.seed(seed)

  # For the pooled model, gof.ergm() automatically retains the saved
  # blockdiag("block_id") constraint in m4_fit$constraints.
  gof_result <- gof(
    m4_fit,
    GOF = ~ model + degree + espartners + distance,
    control = control.gof.ergm(
      nsim = NSIM,
      MCMC.burnin = MCMC_BURNIN,
      MCMC.interval = MCMC_INTERVAL
    ),
    verbose = TRUE
  )

  file_stub <- paste0(safe_name(label), "_M4_gof")

  saveRDS(
    gof_result,
    file.path(output_folder, paste0(file_stub, ".rds"))
  )

  capture.output(
    print(gof_result),
    file = file.path(output_folder, paste0(file_stub, ".txt"))
  )

  save_four_panel_gof(
    gof_result,
    label,
    file.path(output_folder, paste0(file_stub, ".pdf")),
    type = "pdf"
  )
  save_four_panel_gof(
    gof_result,
    label,
    file.path(output_folder, paste0(file_stub, ".png")),
    type = "png"
  )

  list(
    gof = gof_result,
    statistics = extract_gof_statistics(gof_result)
  )
}

log_row <- function(analysis_type, unit, status, error = NA_character_) {
  data.frame(
    analysis_type = analysis_type,
    unit = unit,
    status = status,
    error = error,
    stringsAsFactors = FALSE
  )
}


# ----------------------------------------------------------------------------
# 3. Separate M4 GOF: one model for every journal
# ----------------------------------------------------------------------------

separate_rds_files <- list.files(
  SEPARATE_MODEL_DIR,
  pattern = "_ERGM_models\\.rds$",
  full.names = TRUE
)

if (length(separate_rds_files) == 0L) {
  stop(
    "No *_ERGM_models.rds files found in:\n", SEPARATE_MODEL_DIR,
    call. = FALSE
  )
}

all_statistics <- list()
run_log <- list()

for (i in seq_along(separate_rds_files)) {
  rds_file <- separate_rds_files[[i]]
  journal <- sub("_ERGM_models\\.rds$", "", basename(rds_file))

  message("\n[Separate GOF] ", journal)

  result <- tryCatch(
    {
      m4_fit <- read_m4_model(rds_file)

      run_one_gof(
        m4_fit = m4_fit,
        label = journal,
        output_folder = file.path(OUTPUT_DIR, "separate"),
        seed = SEED + i
      )
    },
    error = function(e) e
  )

  if (inherits(result, "error")) {
    message("[FAILED] ", journal, ": ", conditionMessage(result))

    run_log[[length(run_log) + 1L]] <- log_row(
      "separate", journal, "failed", conditionMessage(result)
    )
  } else {
    message("[OK] ", journal)

    all_statistics[[length(all_statistics) + 1L]] <- cbind(
      analysis_type = "separate",
      unit = journal,
      result$statistics
    )

    run_log[[length(run_log) + 1L]] <- log_row(
      "separate", journal, "ok"
    )
  }
}


# ----------------------------------------------------------------------------
# 4. Pooled block-diagonal M4 GOF
# ----------------------------------------------------------------------------

message("\n[Block-diagonal GOF] all journals")

block_result <- tryCatch(
  {
    block_m4_fit <- read_m4_model(BLOCK_MODEL_FILE)

    run_one_gof(
      m4_fit = block_m4_fit,
      label = "All_journals_block_diagonal",
      output_folder = file.path(OUTPUT_DIR, "block_diagonal"),
      seed = SEED + 1000L
    )
  },
  error = function(e) e
)

if (inherits(block_result, "error")) {
  message("[FAILED] Block-diagonal model: ", conditionMessage(block_result))

  run_log[[length(run_log) + 1L]] <- log_row(
    "block_diagonal", "all_journals", "failed", conditionMessage(block_result)
  )
} else {
  message("[OK] Block-diagonal model")

  all_statistics[[length(all_statistics) + 1L]] <- cbind(
    analysis_type = "block_diagonal",
    unit = "all_journals",
    block_result$statistics
  )

  run_log[[length(run_log) + 1L]] <- log_row(
    "block_diagonal", "all_journals", "ok"
  )
}


# ----------------------------------------------------------------------------
# 5. Save combined summaries
# ----------------------------------------------------------------------------

write.csv(
  do.call(rbind, run_log),
  file.path(OUTPUT_DIR, "GOF_run_log.csv"),
  row.names = FALSE,
  na = ""
)

if (length(all_statistics) > 0L) {
  write.csv(
    do.call(rbind, all_statistics),
    file.path(OUTPUT_DIR, "all_M4_gof_statistics.csv"),
    row.names = FALSE,
    na = ""
  )
}

message("\nCompleted M4 GOF analysis.")
message("Output folder: ", OUTPUT_DIR)
