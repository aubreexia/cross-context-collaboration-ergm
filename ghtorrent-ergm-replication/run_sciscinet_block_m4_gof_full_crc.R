# ============================================================================
# SciSciNet pooled block-diagonal M4: four-panel GOF for CRC
#
# Put this script directly in your FullJournal directory, alongside:
#   block_diagonal_journal_ergm_results_m0_m4_mle/
#     block_diagonal_journal_ergm_models.rds
#
# Submit through CRC with the accompanying .sbatch file.  The script saves one
# four-panel figure (model, degree, ESP, and geodesic distance) plus the GOF
# object and underlying numerical output.
# ============================================================================


# ----------------------------------------------------------------------------
# 0. Settings
# ----------------------------------------------------------------------------

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

read_positive_integer <- function(env_name, default) {
  value <- Sys.getenv(env_name, unset = "")

  if (!nzchar(value)) {
    return(as.integer(default))
  }

  parsed <- suppressWarnings(as.integer(value))
  if (is.na(parsed) || parsed <= 0L) {
    stop(
      sprintf("%s must be a positive integer; received: %s", env_name, value),
      call. = FALSE
    )
  }

  parsed
}

ROOT_DIR <- get_script_dir()

BLOCK_MODEL_FILE <- file.path(
  ROOT_DIR,
  "block_diagonal_journal_ergm_results_m0_m4_mle",
  "block_diagonal_journal_ergm_models.rds"
)

OUTPUT_DIR <- file.path(ROOT_DIR, "m4_gof", "block_diagonal_full")

# Defaults for the final supplementary analysis.  You may override these only
# for a short test, e.g. GOF_NSIM=20 Rscript run_sciscinet_block_m4_gof_full_crc.R
NSIM <- read_positive_integer("GOF_NSIM", 100L)
MCMC_BURNIN <- read_positive_integer("GOF_MCMC_BURNIN", 100000L)
MCMC_INTERVAL <- read_positive_integer("GOF_MCMC_INTERVAL", 4096L)
SEED <- 20260831L


# ----------------------------------------------------------------------------
# 1. Packages and input checks
# ----------------------------------------------------------------------------

required_packages <- c("network", "ergm")

missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0L) {
  stop(
    paste0(
      "Missing R package(s): ", paste(missing_packages, collapse = ", "),
      "\nInstall them in your CRC R library before running this script."
    ),
    call. = FALSE
  )
}

suppressPackageStartupMessages({
  library(network)
  library(ergm)
})

if (!file.exists(BLOCK_MODEL_FILE)) {
  stop(
    "Cannot find the pooled block-model file:\n", BLOCK_MODEL_FILE,
    "\n\nPlace this script in FullJournal, or edit BLOCK_MODEL_FILE at the top.",
    call. = FALSE
  )
}

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)


# ----------------------------------------------------------------------------
# 2. Helper functions
# ----------------------------------------------------------------------------

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

save_four_panel_gof <- function(gof_result, output_file, type = c("pdf", "png")) {
  type <- match.arg(type)

  if (identical(type, "pdf")) {
    grDevices::pdf(output_file, width = 16, height = 10, onefile = TRUE)
  } else {
    grDevices::png(output_file, width = 2400, height = 1800, res = 220)
  }

  old_par <- graphics::par(no.readonly = TRUE)

  tryCatch(
    {
      # The GOF formula below has exactly four terms.  A 2 x 2 layout therefore
      # creates one complete four-panel diagnostic figure, not four files.
      graphics::par(
        mfrow = c(2, 2),
        mar = c(4.2, 4.2, 2.8, 1.2),
        oma = c(0, 0, 2.0, 0)
      )

      plot(gof_result, cex.axis = 0.65)

      graphics::mtext(
        "SciSciNet pooled block-diagonal M4 goodness-of-fit diagnostics",
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


# ----------------------------------------------------------------------------
# 3. Load the saved M4 fit and run the full four-panel GOF
# ----------------------------------------------------------------------------

models <- readRDS(BLOCK_MODEL_FILE)

if (!is.list(models) || is.null(models[["m4_full"]])) {
  stop(
    "The model RDS does not contain an object named m4_full.",
    call. = FALSE
  )
}

m4_fit <- models[["m4_full"]]

if (!inherits(m4_fit, "ergm")) {
  stop("m4_full is not a successful ergm object.", call. = FALSE)
}

message("SciSciNet pooled block-diagonal M4 GOF")
message("Model file: ", BLOCK_MODEL_FILE)
message("Output folder: ", OUTPUT_DIR)
message("Simulations: ", NSIM)
message("MCMC burn-in: ", MCMC_BURNIN)
message("MCMC interval: ", MCMC_INTERVAL)
message("GOF panels: model, degree, espartners, distance")
message("Starting simulation-based GOF.  Distance is computationally intensive; run on CRC.")

set.seed(SEED)
gc()

# The fitted model retains its blockdiag("block_id") constraint during GOF
# simulations.  Cross-journal dyads therefore remain structural zeros.
#
# dspartners is intentionally excluded: it is not needed for the requested
# four-panel supplementary figure and adds a fifth panel plus substantial cost.
gof_block_m4 <- gof(
  m4_fit,
  GOF = ~ model + degree + espartners + distance,
  control = control.gof.ergm(
    nsim = NSIM,
    MCMC.burnin = MCMC_BURNIN,
    MCMC.interval = MCMC_INTERVAL
  ),
  verbose = TRUE
)


# ----------------------------------------------------------------------------
# 4. Save the complete reproducible output
# ----------------------------------------------------------------------------

file_stub <- "All_journals_block_diagonal_M4_full_gof"

saveRDS(
  gof_block_m4,
  file.path(OUTPUT_DIR, paste0(file_stub, ".rds"))
)

capture.output(
  print(gof_block_m4),
  file = file.path(OUTPUT_DIR, paste0(file_stub, ".txt"))
)

gof_statistics <- extract_gof_statistics(gof_block_m4)

if (nrow(gof_statistics) > 0L) {
  write.csv(
    gof_statistics,
    file.path(OUTPUT_DIR, paste0(file_stub, ".csv")),
    row.names = FALSE,
    na = ""
  )
}

save_four_panel_gof(
  gof_block_m4,
  file.path(OUTPUT_DIR, paste0(file_stub, ".pdf")),
  type = "pdf"
)

save_four_panel_gof(
  gof_block_m4,
  file.path(OUTPUT_DIR, paste0(file_stub, ".png")),
  type = "png"
)

metadata <- c(
  "SciSciNet pooled block-diagonal M4 GOF",
  paste("Completed:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
  paste("Model RDS:", normalizePath(BLOCK_MODEL_FILE, mustWork = TRUE)),
  "GOF terms: model + degree + espartners + distance",
  "dspartners intentionally excluded to retain exactly four panels.",
  paste("nsim:", NSIM),
  paste("MCMC.burnin:", MCMC_BURNIN),
  paste("MCMC.interval:", MCMC_INTERVAL),
  paste("seed:", SEED)
)

writeLines(
  metadata,
  file.path(OUTPUT_DIR, "GOF_run_metadata.txt")
)

capture.output(
  sessionInfo(),
  file = file.path(OUTPUT_DIR, "session_info.txt")
)

message("\nCompleted successfully.")
message("Four-panel PNG: ", file.path(OUTPUT_DIR, paste0(file_stub, ".png")))
message("Four-panel PDF: ", file.path(OUTPUT_DIR, paste0(file_stub, ".pdf")))
