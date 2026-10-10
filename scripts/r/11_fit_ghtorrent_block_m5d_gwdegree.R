# ============================================================================
# GHTorrent: pooled block-diagonal M5-D with fixed GWDEGREE
# High-precision re-fit with one shared density parameter across languages
#
# Run with the GHTorrent processed-input root as the first argument:
#   Rscript scripts/r/11_fit_ghtorrent_block_m5d_gwdegree.R data/processed/ghtorrent
#
# This does NOT overwrite the published M4 or prior GWESP output.  It rebuilds
# the already-validated pooled GHTorrent network from the M4 input files,
# retains the blockdiag("block_id") constraint, fits M4 as a reference, then
# fits M5-D = M4 + gwdegree(0.5, fixed = TRUE) using MCMLE.
#
# IMPORTANT: This script intentionally keeps a single global `edges` term.
# It adds no language-specific density terms and therefore does not change the
# density specification of the pooled GHTorrent block model.
# ============================================================================

SCRIPT_VERSION <- "GHTorrent pooled M5-D GWDEGREE MCMLE 2026-10-08 v3 (same global density; high-precision re-fit)"

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

# ---- User-adjustable estimation settings ----------------------------------
# These affect only the accuracy/mixing of MCMLE simulation, not the model
# formula or its shared density specification.
GWDEGREE_DECAY <- 0.50
SEED <- 20261008L
MCMLE_MAXIT <- 60L
MCMLE_BURNIN <- 1000000L
MCMLE_INTERVAL <- 65536L
MCMLE_EFFECTIVE_SIZE <- 128L
MCMLE_LAST_BOOST <- 8L
MCMC_RETURN_STATS <- 8192L

# If the prior v2 M5-D fit exists, begin the high-precision re-fit from its
# coefficient vector. This preserves exactly the same model and usually avoids
# repeating the early MCMLE search. If it is unavailable, the script falls
# back safely to M4 coefficients plus GWDEGREE = 0.
USE_PREVIOUS_M5_INIT <- TRUE

M4_DIR <- file.path(ROOT_DIR, "block_diagonal_language_ergm_results")
NODES_FILE <- file.path(M4_DIR, "combined_nodes_used.csv")
EDGES_FILE <- file.path(M4_DIR, "combined_edges_used.csv")
PREVIOUS_M5_RDS <- file.path(
  ROOT_DIR, "block_diagonal_language_m5_gwdegree_decay050",
  "block_diagonal_m5_gwdegree_model.rds"
)
OUTPUT_DIR <- file.path(ROOT_DIR, "block_diagonal_language_m5_gwdegree_decay050_highprecision")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

need <- c("network", "ergm")
missing <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  stop("Missing R package(s): ", paste(missing, collapse = ", "),
       ". Load an R module containing statnet/ergm or set R_LIBS_USER.", call. = FALSE)
}
suppressPackageStartupMessages({ library(network); library(ergm) })
set.seed(SEED)

if (!file.exists(NODES_FILE) || !file.exists(EDGES_FILE)) {
  stop(
    "Could not find the pooled M4 inputs. Expected:\n  ", NODES_FILE,
    "\n  ", EDGES_FILE,
    call. = FALSE
  )
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
  p <- as.matrix(raw[-1L])
  suppressWarnings(storage.mode(p) <- "double")
  rownames(p) <- clean_id(raw[[1L]])
  colnames(p) <- clean_id(colnames(p))
  if (nrow(p) != ncol(p) || anyNA(rownames(p)) || anyNA(colnames(p)) ||
      anyDuplicated(rownames(p)) || anyDuplicated(colnames(p)) ||
      !setequal(rownames(p), colnames(p))) {
    stop("Prior matrix has invalid IDs or dimensions: ", path, call. = FALSE)
  }
  p <- p[rownames(p), rownames(p), drop = FALSE]
  if (anyNA(p) || any(!is.finite(p)) || any(p < 0) ||
      !isTRUE(all.equal(p, t(p), tolerance = 1e-12))) {
    stop("Prior matrix is non-finite, negative, or asymmetric: ", path, call. = FALSE)
  }
  p <- 1L * (p > 0)
  diag(p) <- 0L
  p
}

# Find precisely one raw input triplet per language.  This accepts both the
# original processed_for_ergm directory and the flattened CRC layout.
find_prior_file <- function(language) {
  language_root <- file.path(ROOT_DIR, language)
  if (!dir.exists(language_root)) stop("Missing language folder: ", language_root, call. = FALSE)
  candidates <- unique(c(language_root, list.dirs(language_root, recursive = TRUE, full.names = TRUE)))
  has_triplet <- vapply(candidates, function(d) {
    f <- list.files(d, full.names = TRUE, recursive = FALSE)
    f <- f[!file.info(f)$isdir]
    n <- basename(f)
    node_n <- sum(grepl("_nodes( \\([0-9]+\\))?\\.csv$", n, ignore.case = TRUE))
    edge_n <- sum(grepl("_edges( \\([0-9]+\\))?\\.csv$", n, ignore.case = TRUE) &
                    !grepl("_prior_edges( \\([0-9]+\\))?\\.csv$", n, ignore.case = TRUE))
    prior_n <- sum(grepl("_prior_mat( \\([0-9]+\\))?\\.csv$", n, ignore.case = TRUE))
    node_n == 1L && edge_n == 1L && prior_n == 1L
  }, logical(1))
  candidates <- candidates[has_triplet]
  canonical <- candidates[grepl("processed_for_ergm_prior_before_", candidates, fixed = TRUE)]
  candidates <- if (length(canonical)) canonical else candidates
  if (length(candidates) != 1L) {
    stop("Expected exactly one raw input triplet for ", language, "; found: ",
         if (length(candidates)) paste(candidates, collapse = " | ") else "none", call. = FALSE)
  }
  f <- list.files(candidates[[1L]], full.names = TRUE, recursive = FALSE)
  prior <- f[grepl("_prior_mat( \\([0-9]+\\))?\\.csv$", basename(f), ignore.case = TRUE)]
  if (length(prior) != 1L) stop("Could not resolve prior matrix for ", language, call. = FALSE)
  prior[[1L]]
}

message("Running: ", SCRIPT_VERSION)
message("ROOT_DIR: ", ROOT_DIR)
message("M4 inputs: ", M4_DIR)
message("Output: ", OUTPUT_DIR)
message("GWDEGREE: gwdegree(", GWDEGREE_DECAY, ", fixed = TRUE)")
message("M5-D control: MCMLE.maxit = ", MCMLE_MAXIT,
        "; MCMLE.burnin = ", MCMLE_BURNIN,
        "; MCMLE.interval = ", MCMLE_INTERVAL,
        "; MCMLE.effectiveSize = ", MCMLE_EFFECTIVE_SIZE,
        "; MCMLE.last.boost = ", MCMLE_LAST_BOOST)
write.csv(
  data.frame(
    setting = c("density_specification", "gwdegree_decay", "MCMLE.maxit",
                "MCMLE.burnin", "MCMLE.interval", "MCMLE.effectiveSize",
                "MCMLE.last.boost", "MCMC.return.stats", "use_previous_m5_init"),
    value = c("one global edges term; blockdiag only", GWDEGREE_DECAY,
              MCMLE_MAXIT, MCMLE_BURNIN, MCMLE_INTERVAL,
              MCMLE_EFFECTIVE_SIZE, MCMLE_LAST_BOOST, MCMC_RETURN_STATS,
              USE_PREVIOUS_M5_INIT),
    stringsAsFactors = FALSE
  ),
  file.path(OUTPUT_DIR, "m5_gwdegree_highprecision_settings.csv"),
  row.names = FALSE
)

# ---- Rebuild the exact pooled network used for the established M4 ----------
nodes <- read.csv(NODES_FILE, stringsAsFactors = FALSE, check.names = FALSE)
edges <- read_char_csv(EDGES_FILE)
needed_nodes <- c("vertex_id", "language_folder", "block_id", "original_global_id",
                  "expertise_model_z", "leadership_model_z")
needed_edges <- c("u", "v")
if (length(setdiff(needed_nodes, names(nodes)))) {
  stop("combined_nodes_used.csv is missing: ",
       paste(setdiff(needed_nodes, names(nodes)), collapse = ", "), call. = FALSE)
}
if (length(setdiff(needed_edges, names(edges)))) {
  stop("combined_edges_used.csv is missing: ",
       paste(setdiff(needed_edges, names(edges)), collapse = ", "), call. = FALSE)
}

for (x in c("vertex_id", "language_folder", "block_id", "original_global_id")) nodes[[x]] <- clean_id(nodes[[x]])
edges$u <- clean_id(edges$u)
edges$v <- clean_id(edges$v)
nodes$expertise_model_z <- suppressWarnings(as.numeric(nodes$expertise_model_z))
nodes$leadership_model_z <- suppressWarnings(as.numeric(nodes$leadership_model_z))
if (anyNA(nodes$vertex_id) || anyDuplicated(nodes$vertex_id) ||
    anyNA(nodes$language_folder) || anyNA(nodes$block_id) || anyNA(nodes$original_global_id) ||
    anyNA(nodes$expertise_model_z) || anyNA(nodes$leadership_model_z) ||
    any(!is.finite(nodes$expertise_model_z)) || any(!is.finite(nodes$leadership_model_z))) {
  stop("Invalid values in combined_nodes_used.csv.", call. = FALSE)
}
if (anyNA(edges$u) || anyNA(edges$v) || any(edges$u == edges$v) ||
    any(!edges$u %in% nodes$vertex_id) || any(!edges$v %in% nodes$vertex_id)) {
  stop("Invalid endpoints in combined_edges_used.csv.", call. = FALSE)
}

# Canonicalize undirected edges and reject accidental duplicates.
edge_pair <- ifelse(edges$u < edges$v, paste(edges$u, edges$v, sep = "\r"),
                    paste(edges$v, edges$u, sep = "\r"))
if (anyDuplicated(edge_pair)) stop("combined_edges_used.csv contains duplicate undirected edges.", call. = FALSE)

prior_big <- matrix(0L, nrow(nodes), nrow(nodes),
                    dimnames = list(nodes$vertex_id, nodes$vertex_id))
languages <- sort(unique(nodes$language_folder))
sources <- vector("list", length(languages))
for (i in seq_along(languages)) {
  language <- languages[[i]]
  idx <- which(nodes$language_folder == language)
  ids <- nodes$original_global_id[idx]
  prior_file <- find_prior_file(language)
  prior <- read_binary_prior(prior_file)
  if (anyDuplicated(ids)) {
    stop("combined_nodes_used.csv has duplicated original_global_id values for ", language, call. = FALSE)
  }
  missing_ids <- setdiff(ids, rownames(prior))
  if (length(missing_ids)) {
    stop(
      "Prior matrix for ", language, " is missing focal node ID(s): ",
      paste(head(missing_ids, 10L), collapse = ", "),
      call. = FALSE
    )
  }
  # A prior matrix may legitimately include additional users that were removed
  # from the focal-period analytic network.  Retain only the exact node set
  # used by the established M4 pooled network.
  extra_ids <- setdiff(rownames(prior), ids)
  if (length(extra_ids)) {
    message("[INFO] ", language, ": using ", length(ids), " focal nodes from a prior matrix with ",
            length(extra_ids), " additional non-focal node(s).")
  }
  prior_big[idx, idx] <- prior[ids, ids, drop = FALSE]
  sources[[i]] <- data.frame(
    language_folder = language,
    prior_file = normalizePath(prior_file, mustWork = TRUE),
    nodes = length(idx),
    prior_matrix_nodes = nrow(prior),
    extra_nonfocal_prior_nodes = length(extra_ids),
    prior_dyads = sum(prior[upper.tri(prior)] > 0),
    stringsAsFactors = FALSE
  )
}
diag(prior_big) <- 0L
if (!isTRUE(all.equal(prior_big, t(prior_big), tolerance = 1e-12))) {
  stop("Rebuilt prior_big is not symmetric.", call. = FALSE)
}
write.csv(do.call(rbind, sources), file.path(OUTPUT_DIR, "prior_big_rebuild_sources.csv"), row.names = FALSE)

net_big <- network.initialize(n = nrow(nodes), directed = FALSE, loops = FALSE, multiple = FALSE)
network.vertex.names(net_big) <- nodes$vertex_id
set.vertex.attribute(net_big, "block_id", nodes$block_id)
set.vertex.attribute(net_big, "language", nodes$language_folder)
set.vertex.attribute(net_big, "expertise_model_z", nodes$expertise_model_z)
set.vertex.attribute(net_big, "leadership_model_z", nodes$leadership_model_z)
tail_idx <- match(edges$u, nodes$vertex_id)
head_idx <- match(edges$v, nodes$vertex_id)
add.edges(net_big, tail = tail_idx, head = head_idx)

block_constraint <- ~ blockdiag("block_id")
possible_within <- sum(table(nodes$block_id) * (table(nodes$block_id) - 1) / 2)
message("Combined network: ", nrow(nodes), " nodes, ", nrow(edges),
        " edges, ", length(languages), " language blocks, ", possible_within, " at-risk dyads.")

# ---- Fit M4 then M5-D ------------------------------------------------------
m4_formula <- net_big ~ edges + edgecov(prior_big) +
  nodecov("expertise_model_z") + absdiff("expertise_model_z") +
  nodecov("leadership_model_z") + absdiff("leadership_model_z")
if (!isTRUE(all.equal(GWDEGREE_DECAY, 0.50))) {
  stop("This script is written for the requested fixed GWDEGREE decay of 0.50.", call. = FALSE)
}
m5_formula <- net_big ~ edges + edgecov(prior_big) +
  nodecov("expertise_model_z") + absdiff("expertise_model_z") +
  nodecov("leadership_model_z") + absdiff("leadership_model_z") +
  gwdegree(0.5, fixed = TRUE)

fit_or_error <- function(formula, control) {
  tryCatch(
    ergm(formula, constraints = block_constraint, control = control),
    error = function(e) e
  )
}

message("\nFitting M4 (reference model) ...")
m4_fit <- fit_or_error(m4_formula, control.ergm(seed = SEED))
if (!inherits(m4_fit, "ergm")) {
  stop("M4 failed: ", conditionMessage(m4_fit), call. = FALSE)
}
message("[OK] M4 fit returned.")

base_m5_init <- c(coef(m4_fit), "gwdeg.fixed.0.5" = 0)
expected_m5_names <- c("edges", "edgecov.prior_big", "nodecov.expertise_model_z",
                       "absdiff.expertise_model_z", "nodecov.leadership_model_z",
                       "absdiff.leadership_model_z", "gwdeg.fixed.0.5")
if (!setequal(names(base_m5_init), expected_m5_names)) {
  stop("M4 coefficient names do not match the expected M5-D formula: ",
       paste(names(base_m5_init), collapse = ", "), call. = FALSE)
}
m5_init <- base_m5_init[expected_m5_names]
init_source <- "M4 coefficients plus gwdegree = 0"
if (isTRUE(USE_PREVIOUS_M5_INIT) && file.exists(PREVIOUS_M5_RDS)) {
  previous_m5 <- tryCatch(readRDS(PREVIOUS_M5_RDS), error = function(e) e)
  if (inherits(previous_m5, "ergm")) {
    previous_coef <- coef(previous_m5)
    if (setequal(names(previous_coef), expected_m5_names) &&
        all(is.finite(previous_coef))) {
      m5_init <- previous_coef[expected_m5_names]
      init_source <- paste0("previous v2 M5-D coefficients from ", PREVIOUS_M5_RDS)
    } else {
      message("[INFO] Existing M5-D RDS has incompatible or non-finite coefficients; using M4-based initialization.")
    }
  } else {
    message("[INFO] Existing M5-D RDS could not be read as an ergm fit; using M4-based initialization.")
  }
}
message("M5-D initialization: ", init_source)
m5_control <- control.ergm(
  init = m5_init,
  seed = SEED + 1L,
  MCMLE.maxit = MCMLE_MAXIT,
  MCMLE.burnin = MCMLE_BURNIN,
  MCMLE.interval = MCMLE_INTERVAL,
  MCMLE.effectiveSize = MCMLE_EFFECTIVE_SIZE,
  MCMLE.last.boost = MCMLE_LAST_BOOST,
  MCMC.return.stats = MCMC_RETURN_STATS
)
message("Resolved controls: MCMLE.burnin = ", m5_control$MCMLE.burnin,
        "; MCMLE.interval = ", m5_control$MCMLE.interval,
        "; MCMLE.effectiveSize = ", m5_control$MCMLE.effectiveSize)

message("\nFitting M5-D with fixed GWDEGREE; inspect MCMC diagnostics after completion ...")
m5_fit <- fit_or_error(m5_formula, m5_control)

# Always save M4 and the reusable pooled network, even if M5-D does not return.
saveRDS(m4_fit, file.path(OUTPUT_DIR, "block_diagonal_m4_reference_model.rds"))
saveRDS(net_big, file.path(OUTPUT_DIR, "block_diagonal_network.rds"))
write.csv(nodes, file.path(OUTPUT_DIR, "combined_nodes_used.csv"), row.names = FALSE)
write.csv(edges, file.path(OUTPUT_DIR, "combined_edges_used.csv"), row.names = FALSE)

make_coef_table <- function(fit, model, estimation) {
  b <- coef(fit)
  se <- sqrt(diag(vcov(fit)))
  z <- b / se
  p <- 2 * pnorm(abs(z), lower.tail = FALSE)
  nonlinear <- grepl("^gwdeg", names(b))
  data.frame(
    model = model, estimation = estimation, term = names(b),
    Estimate = unname(b), Std_Error = unname(se), z_value = unname(z), p_value = unname(p),
    Odds_Ratio = ifelse(nonlinear, NA_real_, exp(b)),
    CI_95_Lower = ifelse(nonlinear, NA_real_, exp(b - 1.96 * se)),
    CI_95_Upper = ifelse(nonlinear, NA_real_, exp(b + 1.96 * se)),
    interpretation = ifelse(nonlinear,
      "Nonlinear structural term: do not interpret exp(coef) as a dyadic odds ratio.",
      "Dyadic change statistic: odds ratio shown."),
    status = "fit_returned_inspect_mcmc_and_gof", stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

if (!inherits(m5_fit, "ergm")) {
  err <- conditionMessage(m5_fit)
  write.csv(make_coef_table(m4_fit, "m4_full", "exact_MLE"),
            file.path(OUTPUT_DIR, "m4_m5_gwdegree_coefficients.csv"), row.names = FALSE)
  write.csv(data.frame(model = "m5_full_gwdegree", status = "failed", error = err),
            file.path(OUTPUT_DIR, "m5_gwdegree_status.csv"), row.names = FALSE)
  message("[M5-D FAILED] ", err)
  message("M4 and reconstructed pooled inputs are saved to: ", OUTPUT_DIR)
  quit(status = 1L)
}

saveRDS(m5_fit, file.path(OUTPUT_DIR, "block_diagonal_m5_gwdegree_model.rds"))
coef_out <- rbind(
  make_coef_table(m4_fit, "m4_full", "exact_MLE"),
  make_coef_table(m5_fit, "m5_full_gwdegree", "MCMLE")
)
write.csv(coef_out, file.path(OUTPUT_DIR, "m4_m5_gwdegree_coefficients.csv"), row.names = FALSE)
capture.output(summary(m4_fit), file = file.path(OUTPUT_DIR, "m4_reference_summary.txt"))
capture.output(summary(m5_fit), file = file.path(OUTPUT_DIR, "m5_gwdegree_summary.txt"))

diag_file <- file.path(OUTPUT_DIR, "m5_gwdegree_mcmc_diagnostics.txt")
diag_error <- tryCatch({
  capture.output(mcmc.diagnostics(m5_fit), file = diag_file)
  NULL
}, error = function(e) conditionMessage(e))
if (!is.null(diag_error)) writeLines(paste("Diagnostics failed:", diag_error), diag_file)
pdf(file.path(OUTPUT_DIR, "m5_gwdegree_mcmc_diagnostics.pdf"), width = 12, height = 9)
try(mcmc.diagnostics(m5_fit), silent = TRUE)
dev.off()

write.csv(data.frame(
  model = "m5_full_gwdegree", status = "fit_returned_inspect_mcmc_and_gof",
  error = NA_character_, stringsAsFactors = FALSE
), file.path(OUTPUT_DIR, "m5_gwdegree_status.csv"), row.names = FALSE)

message("\n[M5-D FIT RETURNED] Outputs written to: ", OUTPUT_DIR)
message("Inspect m5_gwdegree_mcmc_diagnostics.txt, then run constrained GOF before reporting coefficients.")
