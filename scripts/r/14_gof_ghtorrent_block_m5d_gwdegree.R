# ============================================================================
# GHTorrent pooled M5-D GWDEGREE: final in-model GOF for the high-precision fit
#
# Put this file in FullProject and run it through qsub:
#   Rscript scripts/r/14_gof_ghtorrent_block_m5d_gwdegree.R data/processed/ghtorrent
#
# This does NOT refit the ERGM. It loads the completed high-precision M5-D fit
# and evaluates GOF = ~model under the same stored blockdiag constraint.
# The model continues to have one global edges (density) parameter.
# ============================================================================

SCRIPT_VERSION <- "GHTorrent M5-D GWDEGREE high-precision final model GOF 2026-10-08 v1"

get_script_dir <- function() {
  a <- commandArgs(trailingOnly = FALSE)
  x <- grep("^--file=", a, value = TRUE)
  if (length(x)) dirname(normalizePath(sub("^--file=", "", x[[1L]]), mustWork = TRUE))
  else normalizePath(getwd(), mustWork = TRUE)
}

args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 1L) {
  stop("Use at most one argument: the GHTorrent FullProject directory.", call. = FALSE)
}
ROOT_DIR <- if (length(args)) normalizePath(args[[1L]], mustWork = TRUE) else get_script_dir()

# ---- User-adjustable GOF settings -----------------------------------------
# 500 simulated networks gives stable tail probabilities while staying far
# shorter than a complete MCMLE refit. These are simulation controls only;
# they do not alter the fitted model or its global density specification.
GOF_NSIM <- 500L
GOF_MCMC_BURNIN <- 1000000L
GOF_MCMC_INTERVAL <- 65536L
GOF_SEED <- 20261008L
GOF_CORES <- suppressWarnings(as.integer(Sys.getenv("NSLOTS", unset = "1")))
if (is.na(GOF_CORES) || GOF_CORES < 1L) GOF_CORES <- 1L

MODEL_DIR <- file.path(ROOT_DIR, "block_diagonal_language_m5_gwdegree_decay050_highprecision")
M5_RDS <- file.path(MODEL_DIR, "block_diagonal_m5_gwdegree_model.rds")
NETWORK_RDS <- file.path(MODEL_DIR, "block_diagonal_network.rds")
NODES_FILE <- file.path(MODEL_DIR, "combined_nodes_used.csv")
SOURCES_FILE <- file.path(MODEL_DIR, "prior_big_rebuild_sources.csv")
OUTPUT_DIR <- file.path(ROOT_DIR, "gof_ghtorrent_m5_gwdegree_highprecision")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

need <- c("network", "ergm")
missing <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  stop("Missing R package(s): ", paste(missing, collapse = ", "), call. = FALSE)
}
suppressPackageStartupMessages({ library(network); library(ergm) })

for (f in c(M5_RDS, NETWORK_RDS, NODES_FILE, SOURCES_FILE)) {
  if (!file.exists(f)) stop("Required high-precision M5-D output is missing: ", f, call. = FALSE)
}

clean_id <- function(x) {
  x <- trimws(as.character(x))
  x[is.na(x) | tolower(x) %in% c("", "na", "nan", "<na>", "null", "none")] <- NA_character_
  x
}

read_char_csv <- function(path) {
  read.csv(path, stringsAsFactors = FALSE, check.names = FALSE,
           colClasses = "character", na.strings = c("", "NA", "NaN", "nan"))
}

read_binary_prior <- function(path) {
  raw <- read_char_csv(path)
  if (ncol(raw) < 2L) stop("Prior matrix is malformed: ", path, call. = FALSE)
  prior <- as.matrix(raw[-1L])
  suppressWarnings(storage.mode(prior) <- "double")
  rownames(prior) <- clean_id(raw[[1L]])
  colnames(prior) <- clean_id(colnames(prior))
  if (nrow(prior) != ncol(prior) || anyNA(rownames(prior)) || anyNA(colnames(prior)) ||
      anyDuplicated(rownames(prior)) || anyDuplicated(colnames(prior)) ||
      !setequal(rownames(prior), colnames(prior))) {
    stop("Prior matrix has invalid IDs or dimensions: ", path, call. = FALSE)
  }
  prior <- prior[rownames(prior), rownames(prior), drop = FALSE]
  if (anyNA(prior) || any(!is.finite(prior)) || any(prior < 0) ||
      !isTRUE(all.equal(prior, t(prior), tolerance = 1e-12))) {
    stop("Prior matrix is non-finite, negative, or asymmetric: ", path, call. = FALSE)
  }
  prior <- 1L * (prior > 0)
  diag(prior) <- 0L
  prior
}

rebuild_prior_big <- function(nodes_file, sources_file) {
  nodes <- read.csv(nodes_file, stringsAsFactors = FALSE, check.names = FALSE)
  needed <- c("vertex_id", "language_folder", "original_global_id")
  if (length(setdiff(needed, names(nodes)))) {
    stop("combined_nodes_used.csv is missing: ",
         paste(setdiff(needed, names(nodes)), collapse = ", "), call. = FALSE)
  }
  for (x in needed) nodes[[x]] <- clean_id(nodes[[x]])
  if (anyNA(nodes$vertex_id) || anyDuplicated(nodes$vertex_id) ||
      anyNA(nodes$language_folder) || anyNA(nodes$original_global_id)) {
    stop("Invalid node identifiers in combined_nodes_used.csv.", call. = FALSE)
  }

  sources <- read.csv(sources_file, stringsAsFactors = FALSE, check.names = FALSE)
  if (!all(c("language_folder", "prior_file") %in% names(sources))) {
    stop("prior_big_rebuild_sources.csv lacks language_folder or prior_file.", call. = FALSE)
  }
  sources$language_folder <- clean_id(sources$language_folder)
  sources$prior_file <- clean_id(sources$prior_file)

  prior_big <- matrix(0L, nrow(nodes), nrow(nodes),
                      dimnames = list(nodes$vertex_id, nodes$vertex_id))
  for (language in sort(unique(nodes$language_folder))) {
    idx <- which(nodes$language_folder == language)
    source_row <- sources[sources$language_folder == language, , drop = FALSE]
    if (nrow(source_row) != 1L || is.na(source_row$prior_file[[1L]]) ||
        !file.exists(source_row$prior_file[[1L]])) {
      stop("Could not locate the recorded prior matrix for ", language, call. = FALSE)
    }
    prior <- read_binary_prior(source_row$prior_file[[1L]])
    ids <- nodes$original_global_id[idx]
    missing_ids <- setdiff(ids, rownames(prior))
    if (length(missing_ids)) {
      stop("Prior matrix for ", language, " is missing focal node ID(s): ",
           paste(head(missing_ids, 10L), collapse = ", "), call. = FALSE)
    }
    prior_big[idx, idx] <- prior[ids, ids, drop = FALSE]
  }
  diag(prior_big) <- 0L
  if (!isTRUE(all.equal(prior_big, t(prior_big), tolerance = 1e-12))) {
    stop("Rebuilt prior_big is not symmetric.", call. = FALSE)
  }
  prior_big
}

message("Running: ", SCRIPT_VERSION)
message("ROOT_DIR: ", ROOT_DIR)
message("Model RDS: ", M5_RDS)
message("Output: ", OUTPUT_DIR)
message("GOF: ~model; nsim = ", GOF_NSIM,
        "; MCMC.burnin = ", GOF_MCMC_BURNIN,
        "; MCMC.interval = ", GOF_MCMC_INTERVAL,
        "; cores = ", GOF_CORES)

# The model RDS refers to these objects in its formula environment. Rebuild
# them exactly from the completed v3 output before calling gof().
prior_big <- rebuild_prior_big(NODES_FILE, SOURCES_FILE)
net_big <- readRDS(NETWORK_RDS)
block_constraint <- ~ blockdiag("block_id")
GWDEGREE_DECAY <- 0.50
assign("prior_big", prior_big, envir = .GlobalEnv)
assign("net_big", net_big, envir = .GlobalEnv)
assign("block_constraint", block_constraint, envir = .GlobalEnv)
assign("GWDEGREE_DECAY", GWDEGREE_DECAY, envir = .GlobalEnv)

m5_fit <- readRDS(M5_RDS)
if (!inherits(m5_fit, "ergm")) {
  stop("block_diagonal_m5_gwdegree_model.rds is not a successful ergm fit.", call. = FALSE)
}

gof_control <- control.gof.ergm(
  nsim = GOF_NSIM,
  MCMC.burnin = GOF_MCMC_BURNIN,
  MCMC.interval = GOF_MCMC_INTERVAL,
  seed = GOF_SEED,
  parallel = GOF_CORES,
  parallel.type = if (GOF_CORES > 1L) "PSOCK" else NULL
)

message("\nRunning final constrained GOF = ~model ...")
gof_fit <- tryCatch(
  gof(m5_fit, GOF = ~model, control = gof_control, verbose = TRUE),
  error = function(e) e
)

status_file <- file.path(OUTPUT_DIR, "m5_gwdegree_model_gof_status.csv")
if (inherits(gof_fit, "error")) {
  write.csv(data.frame(
    model = "m5_full_gwdegree_highprecision", status = "failed",
    error = conditionMessage(gof_fit), stringsAsFactors = FALSE
  ), status_file, row.names = FALSE)
  stop("[GOF FAILED] ", conditionMessage(gof_fit), call. = FALSE)
}

saveRDS(gof_fit, file.path(OUTPUT_DIR, "m5_gwdegree_model_gof.rds"))
writeLines(
  c("Final constrained GOF = ~model", "", capture.output(gof_fit), "", capture.output(summary(gof_fit))),
  con = file.path(OUTPUT_DIR, "m5_gwdegree_model_gof.txt")
)

grDevices::pdf(file.path(OUTPUT_DIR, "m5_gwdegree_model_gof.pdf"), width = 14, height = 10)
plot_error <- try(plot(gof_fit), silent = TRUE)
grDevices::dev.off()

grDevices::png(file.path(OUTPUT_DIR, "m5_gwdegree_model_gof.png"),
               width = 2800, height = 1900, res = 200)
plot_error_png <- try(plot(gof_fit), silent = TRUE)
grDevices::dev.off()

write.csv(data.frame(
  model = "m5_full_gwdegree_highprecision",
  status = if (inherits(plot_error, "try-error") || inherits(plot_error_png, "try-error")) {
    "completed_plot_warning"
  } else "completed",
  error = if (inherits(plot_error, "try-error")) as.character(plot_error) else NA_character_,
  nsim = GOF_NSIM,
  mcmc_burnin = GOF_MCMC_BURNIN,
  mcmc_interval = GOF_MCMC_INTERVAL,
  stringsAsFactors = FALSE
), status_file, row.names = FALSE)

message("\n[GOF COMPLETE] Outputs written to: ", OUTPUT_DIR)
message("Inspect m5_gwdegree_model_gof.txt and the PDF/PNG before interpreting the M5-D coefficient table.")
