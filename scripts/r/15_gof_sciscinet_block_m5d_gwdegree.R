# ============================================================================
# SciSciNet pooled M5-D GWDEGREE: final constrained GOF = ~model
#
# Run only after 12_fit_sciscinet_block_m5d_gwdegree.R has
# returned a successful M5-D fit. This script does not refit the ERGM. It loads
# the high-precision fit and assesses final in-model statistics under the same
# stored blockdiag("block_id") constraint.
#
# The model deliberately retains one global `edges` term across all journals.
# It contains no journal-specific density deviations.
# ============================================================================

SCRIPT_VERSION <- "SciSciNet unified-density M5-D GWDEGREE high-precision final model GOF, 2026-10-09 v1"

get_script_dir <- function() {
  arguments <- commandArgs(trailingOnly = FALSE)
  file_argument <- grep("^--file=", arguments, value = TRUE)
  if (length(file_argument) > 0L) {
    return(dirname(normalizePath(
      sub("^--file=", "", file_argument[[1L]]),
      mustWork = TRUE
    )))
  }
  normalizePath(getwd(), mustWork = TRUE)
}

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) > 1L) {
  stop("Use at most one argument: the FullJournal directory.", call. = FALSE)
}
ROOT_DIR <- if (length(arguments) == 1L) {
  normalizePath(arguments[[1L]], mustWork = TRUE)
} else {
  get_script_dir()
}

# Simulation settings for GOF only; these do not alter the fitted M5-D model.
GOF_NSIM <- 500L
GOF_MCMC_BURNIN <- 1000000L
GOF_MCMC_INTERVAL <- 65536L
GOF_SEED <- 20261009L
DECAY <- 0.50
EXPECTED_JOURNALS <- 10L

M4_DIR <- file.path(ROOT_DIR, "block_diagonal_journal_ergm_results_m0_m4_mle")
NODES_FILE <- file.path(M4_DIR, "combined_nodes_used.csv")
EDGES_FILE <- file.path(M4_DIR, "combined_edges_used.csv")
MODEL_DIR <- file.path(ROOT_DIR, "block_diagonal_journal_m5_gwdegree_decay050_highprecision")
M5_RDS <- file.path(MODEL_DIR, "block_diagonal_m5_gwdegree_model.rds")
PRIOR_SOURCES_FILE <- file.path(MODEL_DIR, "prior_matrix_sources.csv")
OUTPUT_DIR <- file.path(ROOT_DIR, "gof_sciscinet_m5_gwdegree_highprecision_model")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

required_packages <- c("network", "ergm")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0L) {
  stop(
    "Missing R package(s): ",
    paste(missing_packages, collapse = ", "),
    ". Use an R installation with compatible statnet and ergm packages.",
    call. = FALSE
  )
}
suppressPackageStartupMessages({
  library(network)
  library(ergm)
})

for (file_name in c(NODES_FILE, EDGES_FILE, M5_RDS, PRIOR_SOURCES_FILE)) {
  if (!file.exists(file_name)) {
    stop("Required input is missing: ", file_name, call. = FALSE)
  }
}

clean_id <- function(x) {
  x <- trimws(as.character(x))
  x[is.na(x) | tolower(x) %in% c("", "na", "nan", "<na>", "null", "none")] <- NA_character_
  x
}

read_char_csv <- function(path) {
  read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    colClasses = "character",
    na.strings = c("", "NA", "NaN", "nan")
  )
}

read_prior <- function(path) {
  raw <- read_char_csv(path)
  if (ncol(raw) < 2L) {
    stop("Prior file is not a matrix: ", path, call. = FALSE)
  }
  prior <- as.matrix(raw[-1L])
  suppressWarnings(storage.mode(prior) <- "double")
  rownames(prior) <- clean_id(raw[[1L]])
  colnames(prior) <- clean_id(colnames(prior))
  if (anyNA(rownames(prior)) || anyNA(colnames(prior)) ||
      anyDuplicated(rownames(prior)) || anyDuplicated(colnames(prior)) ||
      nrow(prior) != ncol(prior) || !setequal(rownames(prior), colnames(prior))) {
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

message("Running: ", SCRIPT_VERSION)
message("ROOT_DIR: ", ROOT_DIR)
message("M5 RDS: ", M5_RDS)
message("Output: ", OUTPUT_DIR)
message(
  "GOF = ~model; nsim = ", GOF_NSIM,
  "; MCMC.burnin = ", GOF_MCMC_BURNIN,
  "; MCMC.interval = ", GOF_MCMC_INTERVAL
)

# Rebuild the exact objects referenced by the saved M5-D formula before loading
# it. The recorded prior-file paths ensure that the same inputs are used.
nodes <- read.csv(NODES_FILE, stringsAsFactors = FALSE, check.names = FALSE)
edges <- read_char_csv(EDGES_FILE)
required_node_columns <- c(
  "vertex_id", "journal_folder", "block_id", "original_global_id",
  "expertise_model_z", "leadership_model_z"
)
required_edge_columns <- c("u", "v", "block_id")
if (length(setdiff(required_node_columns, names(nodes))) > 0L) {
  stop(
    "combined_nodes_used.csv is missing: ",
    paste(setdiff(required_node_columns, names(nodes)), collapse = ", "),
    call. = FALSE
  )
}
if (length(setdiff(required_edge_columns, names(edges))) > 0L) {
  stop(
    "combined_edges_used.csv is missing: ",
    paste(setdiff(required_edge_columns, names(edges)), collapse = ", "),
    call. = FALSE
  )
}
for (field in c("vertex_id", "journal_folder", "block_id", "original_global_id")) {
  nodes[[field]] <- clean_id(nodes[[field]])
}
edges$u <- clean_id(edges$u)
edges$v <- clean_id(edges$v)
nodes$expertise_model_z <- suppressWarnings(as.numeric(nodes$expertise_model_z))
nodes$leadership_model_z <- suppressWarnings(as.numeric(nodes$leadership_model_z))
if (anyNA(nodes$vertex_id) || anyNA(nodes$journal_folder) || anyNA(nodes$block_id) ||
    anyNA(nodes$original_global_id) || anyDuplicated(nodes$vertex_id) ||
    any(!is.finite(nodes$expertise_model_z)) || any(!is.finite(nodes$leadership_model_z))) {
  stop("Invalid values in combined_nodes_used.csv.", call. = FALSE)
}
if (anyNA(edges$u) || anyNA(edges$v) || any(edges$u == edges$v) ||
    any(!edges$u %in% nodes$vertex_id) || any(!edges$v %in% nodes$vertex_id)) {
  stop("Invalid endpoints in combined_edges_used.csv.", call. = FALSE)
}

journals <- sort(unique(nodes$journal_folder))
if (length(journals) != EXPECTED_JOURNALS ||
    length(unique(nodes$block_id)) != EXPECTED_JOURNALS) {
  stop("Expected exactly 10 journals and 10 block IDs.", call. = FALSE)
}

sources <- read.csv(PRIOR_SOURCES_FILE, stringsAsFactors = FALSE, check.names = FALSE)
if (!all(c("journal_folder", "prior_file") %in% names(sources))) {
  stop("prior_matrix_sources.csv is missing journal_folder or prior_file.", call. = FALSE)
}
sources$journal_folder <- clean_id(sources$journal_folder)
sources$prior_file <- clean_id(sources$prior_file)

prior_big <- matrix(0L, nrow(nodes), nrow(nodes))
for (journal in journals) {
  source_row <- sources[sources$journal_folder == journal, , drop = FALSE]
  if (nrow(source_row) != 1L || is.na(source_row$prior_file[[1L]]) ||
      !file.exists(source_row$prior_file[[1L]])) {
    stop("Could not locate the recorded prior matrix for ", journal, call. = FALSE)
  }
  index <- which(nodes$journal_folder == journal)
  node_ids <- nodes$original_global_id[index]
  prior <- read_prior(source_row$prior_file[[1L]])
  if (!setequal(node_ids, rownames(prior))) {
    stop(
      "Prior/node IDs do not match for ", journal,
      ". Missing from prior: ",
      paste(head(setdiff(node_ids, rownames(prior)), 10L), collapse = ", "),
      call. = FALSE
    )
  }
  prior_big[index, index] <- prior[node_ids, node_ids, drop = FALSE]
}
diag(prior_big) <- 0L
if (!isTRUE(all.equal(prior_big, t(prior_big), tolerance = 1e-12))) {
  stop("The rebuilt pooled prior matrix is not symmetric.", call. = FALSE)
}

net_big <- network.initialize(
  nrow(nodes),
  directed = FALSE,
  loops = FALSE,
  multiple = FALSE
)
network.vertex.names(net_big) <- nodes$vertex_id
set.vertex.attribute(net_big, "block_id", nodes$block_id)
set.vertex.attribute(net_big, "journal", nodes$journal_folder)
set.vertex.attribute(net_big, "expertise_model_z", nodes$expertise_model_z)
set.vertex.attribute(net_big, "leadership_model_z", nodes$leadership_model_z)
tail_index <- match(edges$u, nodes$vertex_id)
head_index <- match(edges$v, nodes$vertex_id)
if (anyNA(tail_index) || anyNA(head_index) || any(tail_index == head_index) ||
    any(nodes$block_id[tail_index] != nodes$block_id[head_index])) {
  stop("Invalid or cross-journal edges in combined_edges_used.csv.", call. = FALSE)
}
edge_key <- paste(pmin(tail_index, head_index), pmax(tail_index, head_index), sep = "_")
if (anyDuplicated(edge_key)) {
  stop("combined_edges_used.csv contains duplicate undirected edges.", call. = FALSE)
}
add.edges(net_big, tail = tail_index, head = head_index)

constraint <- ~ blockdiag("block_id")
m5_formula <- net_big ~ edges + edgecov(prior_big) +
  nodecov("expertise_model_z") + absdiff("expertise_model_z") +
  nodecov("leadership_model_z") + absdiff("leadership_model_z") +
  gwdegree(DECAY, fixed = TRUE)

assign("net_big", net_big, envir = .GlobalEnv)
assign("prior_big", prior_big, envir = .GlobalEnv)
assign("constraint", constraint, envir = .GlobalEnv)
assign("DECAY", DECAY, envir = .GlobalEnv)
assign("m5_formula", m5_formula, envir = .GlobalEnv)

m5_fit <- readRDS(M5_RDS)
if (!inherits(m5_fit, "ergm")) {
  stop("The saved M5-D object is not a successful ergm fit.", call. = FALSE)
}
expected_terms <- c(
  "edges", "edgecov.prior_big", "nodecov.expertise_model_z",
  "absdiff.expertise_model_z", "nodecov.leadership_model_z",
  "absdiff.leadership_model_z", "gwdeg.fixed.0.5"
)
if (!setequal(names(stats::coef(m5_fit)), expected_terms)) {
  stop(
    "The saved M5-D terms do not match the requested shared-density formula: ",
    paste(names(stats::coef(m5_fit)), collapse = ", "),
    call. = FALSE
  )
}

gof_control <- control.gof.ergm(
  nsim = GOF_NSIM,
  MCMC.burnin = GOF_MCMC_BURNIN,
  MCMC.interval = GOF_MCMC_INTERVAL,
  seed = GOF_SEED
)

message("\nRunning final constrained GOF = ~model ...")
gof_fit <- tryCatch(
  gof(m5_fit, GOF = ~ model, control = gof_control, verbose = TRUE),
  error = function(e) e
)

status_file <- file.path(OUTPUT_DIR, "m5_gwdegree_model_gof_status.csv")
if (inherits(gof_fit, "error")) {
  write.csv(
    data.frame(
      model = "m5_full_gwdegree_highprecision",
      status = "failed",
      error = conditionMessage(gof_fit),
      stringsAsFactors = FALSE
    ),
    status_file,
    row.names = FALSE
  )
  stop("[GOF FAILED] ", conditionMessage(gof_fit), call. = FALSE)
}

saveRDS(gof_fit, file.path(OUTPUT_DIR, "m5_gwdegree_model_gof.rds"))
writeLines(
  c(
    "Final constrained GOF = ~model",
    "",
    capture.output(gof_fit),
    "",
    capture.output(summary(gof_fit))
  ),
  file.path(OUTPUT_DIR, "m5_gwdegree_model_gof.txt")
)

plot_status <- tryCatch({
  grDevices::pdf(
    file.path(OUTPUT_DIR, "m5_gwdegree_model_gof.pdf"),
    width = 14,
    height = 10
  )
  plot(gof_fit)
  grDevices::dev.off()
  "written"
}, error = function(e) {
  if (grDevices::dev.cur() > 1L) {
    try(grDevices::dev.off(), silent = TRUE)
  }
  conditionMessage(e)
})

write.csv(
  data.frame(
    model = "m5_full_gwdegree_highprecision",
    status = if (identical(plot_status, "written")) "completed" else "completed_plot_warning",
    error = if (identical(plot_status, "written")) NA_character_ else plot_status,
    nsim = GOF_NSIM,
    mcmc_burnin = GOF_MCMC_BURNIN,
    mcmc_interval = GOF_MCMC_INTERVAL,
    stringsAsFactors = FALSE
  ),
  status_file,
  row.names = FALSE
)

message("\n[GOF COMPLETE] Outputs written to: ", OUTPUT_DIR)
message("Inspect m5_gwdegree_model_gof.txt before interpreting M5-D coefficients.")
