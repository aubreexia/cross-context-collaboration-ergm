# ============================================================================
# GHTorrent ERGM goodness-of-fit (GOF) diagnostics for M4 and M5
#
# Put this script in FullProject and run:
#   Rscript run_ghtorrent_gof_m4_m5.R
#
# It LOADS the already-saved ERGM model objects (.rds); it does NOT refit
# M4 or M5.  It produces GOF diagnostics for:
#   - each separate language model (optional), and
#   - the block-diagonal model (optional).
#
# M4: edges + prior + expertise level/difference + leadership level/difference
# M5: M4 + fixed-decay GWESP
#
# Output: FullProject/gof_results_m4_m5/
# ============================================================================

SCRIPT_VERSION <- "GHTorrent M4/M5 GOF 2026-08-19 v2"

# ---------------------------------------------------------------------------
# 1. Settings
# ---------------------------------------------------------------------------

# Set either option to FALSE if you do not want that analysis.
RUN_SEPARATE_MODELS <- TRUE
RUN_BLOCK_MODEL <- TRUE

# NULL = all saved language model files. To select a subset, use the file
# label, e.g. c("Python", "JavaScript", "C_plus").
SEPARATE_LANGUAGE_LABELS <- NULL

# First run a pilot with 20 simulations. After checking that all output looks
# correct, change this to 100 for the final diagnostic figures.
GOF_NSIM <- 100L

# NULL inherits the MCMC settings stored in each fitted model. This is the
# safest choice because the M5 fits were estimated with their own settings.
GOF_MCMC_BURNIN <- NULL
GOF_MCMC_INTERVAL <- NULL

# These are the fixed values used when the GHTorrent M5 models were fitted.
# They must be recreated because an RDS model stores the formula reference
# (GWESP_DECAY), rather than the value itself.
GWESP_DECAY <- 0.25
GWESP_FIXED <- TRUE

# On CRC this automatically uses the number of slots requested by qsub
# (e.g., 8). On a Mac it defaults to one core. Set it explicitly if needed.
GOF_CORES <- suppressWarnings(as.integer(Sys.getenv("NSLOTS", unset = "1")))
if (is.na(GOF_CORES) || GOF_CORES < 1L) GOF_CORES <- 1L

# Fixed seeds make GOF simulations reproducible. Different models receive
# different seeds derived from this base value.
GOF_SEED <- 20260819L

# Leave these as NULL unless your result directories have nonstandard names.
SEPARATE_MODELS_DIR <- NULL
BLOCK_MODELS_RDS <- NULL

# ---------------------------------------------------------------------------
# 2. Paths and package checks
# ---------------------------------------------------------------------------

get_script_dir <- function() {
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0L) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[[1L]]))))
  }
  normalizePath(getwd(), mustWork = TRUE)
}

user_args <- commandArgs(trailingOnly = TRUE)
if (length(user_args) > 1L) {
  stop("Use at most one argument: the FullProject path.", call. = FALSE)
}
ROOT_DIR <- if (length(user_args) == 1L) {
  normalizePath(user_args[[1L]], mustWork = TRUE)
} else {
  get_script_dir()
}

OUTPUT_DIR <- file.path(ROOT_DIR, "gof_results_m4_m5")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

required <- c("network", "ergm")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0L) {
  stop(
    paste0("Missing R package(s): ", paste(missing, collapse = ", "),
           "\nInstall with: install.packages(c(\"network\", \"ergm\"))"),
    call. = FALSE
  )
}
suppressPackageStartupMessages({
  library(network)
  library(ergm)
})

# The saved M5 language formulas refer to these global names. Defining them
# here lets `gof()` reconstruct the original fixed-decay GWESP specification.
assign("GWESP_DECAY", GWESP_DECAY, envir = .GlobalEnv)
assign("GWESP_FIXED", GWESP_FIXED, envir = .GlobalEnv)

safe_name <- function(x) {
  x <- gsub("+", "_plus", x, fixed = TRUE)
  x <- gsub("#", "_sharp", x, fixed = TRUE)
  x <- gsub("[^A-Za-z0-9._-]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  if (nchar(x) == 0L) "model" else x
}

first_existing <- function(paths, type = c("file", "dir")) {
  type <- match.arg(type)
  exists <- if (type == "file") file.exists(paths) else dir.exists(paths)
  if (!any(exists)) return(NA_character_)
  paths[which(exists)[[1L]]]
}

# Recreate the dense block-diagonal prior-collaboration matrix required by
# the saved block model. The original fit refers to it as `prior_big` in its
# formula environment, but that object itself is not stored in the RDS.
read_binary_prior_matrix <- function(path) {
  raw <- read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    na.strings = c("", "NA", "NaN", "nan")
  )
  if (ncol(raw) < 2L) {
    stop("Prior-matrix file has fewer than two columns: ", path, call. = FALSE)
  }
  ids <- trimws(as.character(raw[[1L]]))
  prior <- as.matrix(raw[-1L])
  suppressWarnings(storage.mode(prior) <- "double")
  rownames(prior) <- ids
  colnames(prior) <- trimws(colnames(prior))
  if (nrow(prior) != ncol(prior) ||
      anyNA(prior) ||
      any(!is.finite(prior)) ||
      !setequal(rownames(prior), colnames(prior))) {
    stop("Invalid prior matrix: ", path, call. = FALSE)
  }
  prior <- prior[rownames(prior), rownames(prior), drop = FALSE]
  prior <- 1L * (prior > 0)
  diag(prior) <- 0L
  prior
}

rebuild_block_prior <- function(root_dir, block_models_rds) {
  block_dir <- dirname(block_models_rds)
  saved_matrix <- file.path(block_dir, "combined_prior_matrix.csv")
  nodes_file <- file.path(block_dir, "combined_nodes_used.csv")

  if (file.exists(saved_matrix)) {
    return(read_binary_prior_matrix(saved_matrix))
  }
  if (!file.exists(nodes_file)) {
    stop(
      "Cannot reconstruct prior_big: missing combined_nodes_used.csv in ",
      block_dir,
      call. = FALSE
    )
  }

  nodes <- read.csv(nodes_file, stringsAsFactors = FALSE, check.names = FALSE)
  needed <- c("vertex_id", "language_folder", "original_global_id")
  if (!all(needed %in% names(nodes))) {
    stop(
      "combined_nodes_used.csv must contain: ",
      paste(needed, collapse = ", "),
      call. = FALSE
    )
  }
  if (anyDuplicated(nodes$vertex_id) > 0L) {
    stop("combined_nodes_used.csv has duplicated vertex_id values.", call. = FALSE)
  }

  prior_big <- matrix(
    0L,
    nrow = nrow(nodes),
    ncol = nrow(nodes),
    dimnames = list(nodes$vertex_id, nodes$vertex_id)
  )

  for (language in unique(nodes$language_folder)) {
    rows <- which(nodes$language_folder == language)
    language_dir <- file.path(root_dir, language)
    prior_path <- file.path(language_dir, "gh_prior_mat.csv")
    if (!file.exists(prior_path)) {
      stop(
        "Cannot reconstruct block prior matrix: missing ", prior_path,
        call. = FALSE
      )
    }
    prior <- read_binary_prior_matrix(prior_path)
    ids <- trimws(as.character(nodes$original_global_id[rows]))
    missing_ids <- setdiff(ids, rownames(prior))
    if (length(missing_ids) > 0L) {
      stop(
        "Prior matrix for ", language, " is missing node ID(s): ",
        paste(head(missing_ids, 5L), collapse = ", "),
        call. = FALSE
      )
    }
    prior_big[rows, rows] <- prior[ids, ids, drop = FALSE]
  }
  diag(prior_big) <- 0L
  prior_big
}

if (is.null(SEPARATE_MODELS_DIR)) {
  SEPARATE_MODELS_DIR <- first_existing(
    c(
      file.path(ROOT_DIR, "separate_results_gwesp_mle", "language_outputs"),
      file.path(ROOT_DIR, "separate_results_gwesp", "language_outputs")
    ),
    type = "dir"
  )
}

if (is.null(BLOCK_MODELS_RDS)) {
  BLOCK_MODELS_RDS <- first_existing(
    c(
      file.path(ROOT_DIR, "block_diagonal_language_ergm_results", "block_diagonal_language_ergm_models.rds"),
      file.path(ROOT_DIR, "block_diagonal_language_ergm_results_gwesp_mle", "block_diagonal_language_ergm_models.rds")
    ),
    type = "file"
  )
}

# ---------------------------------------------------------------------------
# 3. GOF helpers
# ---------------------------------------------------------------------------

make_control <- function(seed) {
  control.gof.ergm(
    nsim = GOF_NSIM,
    MCMC.burnin = GOF_MCMC_BURNIN,
    MCMC.interval = GOF_MCMC_INTERVAL,
    seed = seed,
    parallel = GOF_CORES,
    parallel.type = if (GOF_CORES > 1L) "PSOCK" else NULL
  )
}

run_one_gof <- function(fit, scope, label, model_name, output_subdir, seed) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      scope = scope, label = label, model = model_name, status = "skipped",
      reason = "The saved object is not a successful ergm fit.",
      stringsAsFactors = FALSE
    ))
  }

  dir.create(output_subdir, recursive = TRUE, showWarnings = FALSE)
  prefix <- file.path(output_subdir, paste0(safe_name(model_name), "_gof"))

  result <- tryCatch(
    gof(
      fit,
      GOF = ~ degree + esp + distance,
      control = make_control(seed),
      verbose = TRUE
    ),
    error = function(e) e
  )

  if (inherits(result, "error")) {
    return(data.frame(
      scope = scope, label = label, model = model_name, status = "failed",
      reason = conditionMessage(result), stringsAsFactors = FALSE
    ))
  }

  saveRDS(result, paste0(prefix, ".rds"))
  writeLines(capture.output(result), paste0(prefix, ".txt"))

  grDevices::pdf(paste0(prefix, ".pdf"), width = 13, height = 8)
  graphics::par(mfrow = c(2, 2), mar = c(3.5, 3.5, 2.2, 1))
  plot(result)
  grDevices::dev.off()

  grDevices::png(paste0(prefix, ".png"), width = 2600, height = 1600, res = 200)
  graphics::par(mfrow = c(2, 2), mar = c(3.5, 3.5, 2.2, 1))
  plot(result)
  grDevices::dev.off()

  data.frame(
    scope = scope, label = label, model = model_name, status = "ok",
    reason = "", stringsAsFactors = FALSE
  )
}

models_to_check <- c("m4_full", "m5_full_gwesp")
status_rows <- list()
row_number <- 0L
add_status <- function(x) {
  row_number <<- row_number + 1L
  status_rows[[row_number]] <<- x
}

message("Running: ", SCRIPT_VERSION)
message("ROOT_DIR: ", ROOT_DIR)
message("GOF simulations per fit: ", GOF_NSIM)
message("GOF cores: ", GOF_CORES)
message("\nImportant: interpret M5 GOF only if its original MCMLE log confirms convergence.")

# ---------------------------------------------------------------------------
# 4. Separate language-model GOF
# ---------------------------------------------------------------------------

if (RUN_SEPARATE_MODELS) {
  if (is.na(SEPARATE_MODELS_DIR) || !dir.exists(SEPARATE_MODELS_DIR)) {
    add_status(data.frame(
      scope = "separate", label = "all", model = NA_character_, status = "failed",
      reason = "Could not find separate language_outputs directory. Set SEPARATE_MODELS_DIR at the top.",
      stringsAsFactors = FALSE
    ))
  } else {
    model_files <- list.files(
      SEPARATE_MODELS_DIR,
      pattern = "_ERGM_models\\.rds$",
      full.names = TRUE
    )
    if (!is.null(SEPARATE_LANGUAGE_LABELS)) {
      wanted <- safe_name(SEPARATE_LANGUAGE_LABELS)
      model_files <- model_files[sub("_ERGM_models\\.rds$", "", basename(model_files)) %in% wanted]
    }

    for (model_file in sort(model_files)) {
      label <- sub("_ERGM_models\\.rds$", "", basename(model_file))
      message("\n[SEPARATE] ", label)
      models <- tryCatch(readRDS(model_file), error = function(e) e)
      if (inherits(models, "error") || !is.list(models)) {
        add_status(data.frame(
          scope = "separate", label = label, model = NA_character_, status = "failed",
          reason = if (inherits(models, "error")) conditionMessage(models) else "RDS does not contain a model list.",
          stringsAsFactors = FALSE
        ))
        next
      }
      for (model_name in models_to_check) {
        message("  GOF: ", model_name)
        fit <- models[[model_name]]
        add_status(run_one_gof(
          fit = fit,
          scope = "separate",
          label = label,
          model_name = model_name,
          output_subdir = file.path(OUTPUT_DIR, "separate", safe_name(label)),
          seed = GOF_SEED + row_number + 1L
        ))
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 5. Block-diagonal model GOF
# ---------------------------------------------------------------------------

if (RUN_BLOCK_MODEL) {
  if (is.na(BLOCK_MODELS_RDS) || !file.exists(BLOCK_MODELS_RDS)) {
    add_status(data.frame(
      scope = "block", label = "all_languages", model = NA_character_, status = "failed",
      reason = "Could not find the block model RDS. Set BLOCK_MODELS_RDS at the top.",
      stringsAsFactors = FALSE
    ))
  } else {
    message("\n[BLOCK] Loading ", BLOCK_MODELS_RDS)
    models <- tryCatch(readRDS(BLOCK_MODELS_RDS), error = function(e) e)
    if (inherits(models, "error") || !is.list(models)) {
      add_status(data.frame(
        scope = "block", label = "all_languages", model = NA_character_, status = "failed",
        reason = if (inherits(models, "error")) conditionMessage(models) else "RDS does not contain a model list.",
        stringsAsFactors = FALSE
      ))
    } else {
      message("[BLOCK] Reconstructing prior_big for the saved model formula...")
      prior_big_result <- tryCatch(
        rebuild_block_prior(ROOT_DIR, BLOCK_MODELS_RDS),
        error = function(e) e
      )
      if (inherits(prior_big_result, "error")) {
        for (model_name in models_to_check) {
          add_status(data.frame(
            scope = "block", label = "all_languages", model = model_name,
            status = "failed", reason = conditionMessage(prior_big_result),
            stringsAsFactors = FALSE
          ))
        }
      } else {
        assign("prior_big", prior_big_result, envir = .GlobalEnv)
        for (model_name in models_to_check) {
          message("  GOF: ", model_name)
          add_status(run_one_gof(
            fit = models[[model_name]],
            scope = "block",
            label = "all_languages",
            model_name = model_name,
            output_subdir = file.path(OUTPUT_DIR, "block"),
            seed = GOF_SEED + row_number + 1L
          ))
        }
      }
    }
  }
}

status_table <- if (length(status_rows) == 0L) {
  data.frame(
    scope = character(), label = character(), model = character(), status = character(),
    reason = character(), stringsAsFactors = FALSE
  )
} else {
  do.call(rbind, status_rows)
}
status_table$nsim <- GOF_NSIM
status_table$gof_cores <- GOF_CORES
write.csv(status_table, file.path(OUTPUT_DIR, "gof_status.csv"), row.names = FALSE)

message("\n[SAVED] ", normalizePath(OUTPUT_DIR, mustWork = FALSE))
message("Pilot complete. Set GOF_NSIM <- 100L and rerun for final figures after reviewing gof_status.csv.")
