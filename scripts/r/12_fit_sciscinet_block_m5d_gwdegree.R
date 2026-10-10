# ============================================================================
# SciSciNet pooled block-diagonal ERGM: M4 + GWDEGREE(0.5, fixed = TRUE)
# High-precision re-fit with one shared density parameter across journals
#
# Run with the directory containing all 10 journal folders as the first argument:
#   Rscript scripts/r/12_fit_sciscinet_block_m5d_gwdegree.R data/processed/sciscinet
#
# Input is the completed pooled-M4 output:
#   block_diagonal_journal_ergm_results_m0_m4_mle/
#       combined_nodes_used.csv
#       combined_edges_used.csv
#
# The script reconstructs the same pooled network and its prior matrix, and
# keeps cross-journal dyads out of the risk set with blockdiag("block_id").
# M4 is exact MLE. M5-D has a dyad-dependent GWDEGREE term, so it is MCMLE.
#
# IMPORTANT: This script deliberately retains ONE global `edges` term. It does
# not add journal-specific density terms and therefore preserves the original
# uniform-density SciSciNet specification.
# ============================================================================

SCRIPT_VERSION <- "SciSciNet pooled 10-journal M5-D GWDEGREE MCMLE 2026-10-08 v2 (same global density; high-precision re-fit)"

get_script_dir <- function() {
  a <- commandArgs(trailingOnly = FALSE)
  x <- grep("^--file=", a, value = TRUE)
  if (length(x)) dirname(normalizePath(sub("^--file=", "", x[[1L]]), mustWork = TRUE))
  else normalizePath(getwd(), mustWork = TRUE)
}
args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 1L) stop("Use at most one argument: the FullJournal directory.", call. = FALSE)
ROOT_DIR <- if (length(args)) normalizePath(args[[1L]], mustWork = TRUE) else get_script_dir()

EXPECTED_JOURNALS <- 10L
DECAY <- 0.50
SEED <- 20261008L
MCMLE_MAXIT <- 60L
MCMC_BURNIN <- 1000000L
MCMC_INTERVAL <- 65536L
MCMLE_EFFECTIVE_SIZE <- 128L
MCMLE_LAST_BOOST <- 8L
MCMC_RETURN_STATS <- 8192L

# The preliminary M5-D fit had extremely poor estimating-equation diagnostics.
# Do not use its coefficients as the default starting point.  The fit starts
# from the exact M4 coefficients plus GWDEGREE = 0 instead.  Set this to TRUE
# only to deliberately retry from the old M5-D coefficient vector.
USE_PREVIOUS_M5_INIT <- FALSE
M4_DIR <- file.path(ROOT_DIR, "block_diagonal_journal_ergm_results_m0_m4_mle")
NODES_FILE <- file.path(M4_DIR, "combined_nodes_used.csv")
EDGES_FILE <- file.path(M4_DIR, "combined_edges_used.csv")
M4_REFERENCE_FILE <- file.path(M4_DIR, "block_diagonal_M4_coefficients.csv")
PREVIOUS_M5_RDS <- file.path(
  ROOT_DIR, "block_diagonal_journal_m5_gwdegree_decay050",
  "block_diagonal_m5_gwdegree_model.rds"
)
OUTPUT_DIR <- file.path(ROOT_DIR, "block_diagonal_journal_m5_gwdegree_decay050_highprecision")
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

need <- c("network", "ergm", "openxlsx")
missing <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  stop("Missing R package(s): ", paste(missing, collapse = ", "),
       ". Use an R installation with compatible statnet and ergm packages.",
       call. = FALSE)
}
suppressPackageStartupMessages({library(network); library(ergm); library(openxlsx)})
set.seed(SEED)

clean_id <- function(x) {
  x <- trimws(as.character(x))
  x[is.na(x) | tolower(x) %in% c("", "na", "nan", "<na>", "null", "none")] <- NA_character_
  x
}
read_char_csv <- function(path) {
  read.csv(path, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character",
           na.strings = c("", "NA", "NaN", "nan"))
}
read_prior <- function(path) {
  raw <- read_char_csv(path)
  if (ncol(raw) < 2L) stop("Prior file is not a matrix: ", path, call. = FALSE)
  p <- as.matrix(raw[-1L])
  suppressWarnings(storage.mode(p) <- "double")
  rownames(p) <- clean_id(raw[[1L]])
  colnames(p) <- clean_id(colnames(p))
  if (anyNA(rownames(p)) || anyNA(colnames(p)) ||
      anyDuplicated(rownames(p)) || anyDuplicated(colnames(p)) ||
      nrow(p) != ncol(p) || !setequal(rownames(p), colnames(p))) {
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
# Locate the prior in the same canonical input triplet used in the original M4.
find_prior <- function(journal) {
  root <- file.path(ROOT_DIR, journal)
  if (!dir.exists(root)) stop("Missing journal folder: ", root, call. = FALSE)
  candidates <- unique(c(root, list.dirs(root, recursive = TRUE, full.names = TRUE)))
  is_triplet <- vapply(candidates, function(d) {
    f <- list.files(d, full.names = TRUE, recursive = FALSE)
    f <- f[!file.info(f)$isdir]
    n <- basename(f)
    nodes <- sum(grepl("_nodes( \\([0-9]+\\))?\\.csv$", n, ignore.case = TRUE))
    edges <- sum(grepl("_edges( \\([0-9]+\\))?\\.csv$", n, ignore.case = TRUE) &
                 !grepl("_prior_edges( \\([0-9]+\\))?\\.csv$", n, ignore.case = TRUE))
    priors <- sum(grepl("_prior_mat( \\([0-9]+\\))?\\.csv$", n, ignore.case = TRUE))
    nodes == 1L && edges == 1L && priors == 1L
  }, logical(1))
  candidates <- candidates[is_triplet]
  canonical <- candidates[grepl("processed_for_ergm_prior_before_", candidates, fixed = TRUE)]
  candidates <- if (length(canonical)) canonical else candidates
  if (length(candidates) != 1L) {
    stop("Expected one valid input triplet for ", journal, "; found: ",
         if (length(candidates)) paste(candidates, collapse = " | ") else "none", call. = FALSE)
  }
  f <- list.files(candidates[[1L]], full.names = TRUE, recursive = FALSE)
  f[grepl("_prior_mat( \\([0-9]+\\))?\\.csv$", basename(f), ignore.case = TRUE)][[1L]]
}
coef_table <- function(fit, model, method, status) {
  z <- summary(fit)$coefficients
  if (is.null(dim(z))) z <- matrix(z, nrow = 1L)
  se_name <- intersect(c("Std. Error", "Std.Error"), colnames(z))
  z_name <- intersect(c("z value", "z-value"), colnames(z))
  p_name <- grep("^Pr\\(", colnames(z), value = TRUE)
  est <- as.numeric(z[, "Estimate"])
  se <- if (length(se_name)) as.numeric(z[, se_name[[1L]]]) else rep(NA_real_, length(est))
  zv <- if (length(z_name)) as.numeric(z[, z_name[[1L]]]) else est / se
  pv <- if (length(p_name)) as.numeric(z[, p_name[[1L]]]) else 2 * pnorm(abs(zv), lower.tail = FALSE)
  nonlinear <- grepl("^gwdeg", rownames(z))
  data.frame(
    model = model, estimation = method, term = rownames(z), Estimate = est,
    Std_Error = se, z_value = zv, p_value = pv,
    Odds_Ratio = ifelse(nonlinear, NA_real_, exp(est)),
    CI_95_Lower = ifelse(nonlinear, NA_real_, exp(est - 1.96 * se)),
    CI_95_Upper = ifelse(nonlinear, NA_real_, exp(est + 1.96 * se)),
    interpretation = ifelse(nonlinear,
      "Nonlinear structural term: do not interpret exp(coef) as a dyadic odds ratio.",
      "Dyadic change statistic: odds ratio shown."),
    status = status, stringsAsFactors = FALSE, check.names = FALSE
  )
}
fit_row <- function(fit, model, method, status, error = NA_character_) {
  data.frame(model = model, estimation = method,
    AIC = tryCatch(AIC(fit), error = function(e) NA_real_),
    BIC = tryCatch(BIC(fit), error = function(e) NA_real_),
    logLik = tryCatch(as.numeric(logLik(fit)), error = function(e) NA_real_),
    status = status, error = error, stringsAsFactors = FALSE)
}
save_mcmc_diagnostics <- function(fit) {
  txt <- file.path(OUTPUT_DIR, "m5_gwdegree_mcmc_diagnostics.txt")
  pdf <- file.path(OUTPUT_DIR, "m5_gwdegree_mcmc_diagnostics.pdf")
  text_ok <- tryCatch({
    writeLines(capture.output(mcmc.diagnostics(fit)), txt)
    TRUE
  }, error = function(e) {writeLines(paste("Failed:", conditionMessage(e)), txt); FALSE})
  pdf_ok <- tryCatch({
    grDevices::pdf(pdf, width = 11, height = 8.5)
    mcmc.diagnostics(fit)
    grDevices::dev.off()
    TRUE
  }, error = function(e) {
    if (grDevices::dev.cur() > 1L) grDevices::dev.off()
    message("Could not write MCMC PDF: ", conditionMessage(e))
    FALSE
  })
  data.frame(diagnostic = c("text", "pdf"), path = c(txt, pdf),
             status = c(ifelse(text_ok, "written", "failed"), ifelse(pdf_ok, "written", "failed")),
             stringsAsFactors = FALSE)
}

message("Running: ", SCRIPT_VERSION)
message("ROOT_DIR: ", ROOT_DIR)
message("M4 inputs: ", M4_DIR)
message("Output: ", OUTPUT_DIR)
message("Density specification: one global edges term; blockdiag only")
message("GWDEGREE: gwdegree(", DECAY, ", fixed = TRUE)")
message("M5-D control: MCMLE.maxit = ", MCMLE_MAXIT,
        "; MCMLE.burnin = ", MCMC_BURNIN,
        "; MCMLE.interval = ", MCMC_INTERVAL,
        "; MCMLE.effectiveSize = ", MCMLE_EFFECTIVE_SIZE,
        "; MCMLE.last.boost = ", MCMLE_LAST_BOOST)
if (!all(file.exists(c(NODES_FILE, EDGES_FILE)))) {
  stop("Missing pooled-M4 inputs. Expected:\n- ", NODES_FILE, "\n- ", EDGES_FILE,
       "\nRun the pooled M0--M4 script first, or use the correct ROOT_DIR.", call. = FALSE)
}
nodes <- read.csv(NODES_FILE, stringsAsFactors = FALSE, check.names = FALSE)
edges <- read.csv(EDGES_FILE, stringsAsFactors = FALSE, check.names = FALSE)
needed_nodes <- c("vertex_id", "journal_folder", "block_id", "original_global_id",
                  "expertise_model_z", "leadership_model_z")
needed_edges <- c("u", "v", "block_id")
if (length(setdiff(needed_nodes, names(nodes)))) stop("Missing node columns: ",
  paste(setdiff(needed_nodes, names(nodes)), collapse = ", "), call. = FALSE)
if (length(setdiff(needed_edges, names(edges)))) stop("Missing edge columns: ",
  paste(setdiff(needed_edges, names(edges)), collapse = ", "), call. = FALSE)
for (x in c("vertex_id", "journal_folder", "block_id", "original_global_id")) nodes[[x]] <- clean_id(nodes[[x]])
if (anyNA(nodes$vertex_id) || anyNA(nodes$journal_folder) || anyNA(nodes$block_id) ||
    anyNA(nodes$original_global_id) || anyDuplicated(nodes$vertex_id)) {
  stop("Invalid or duplicated IDs in combined_nodes_used.csv.", call. = FALSE)
}
if (any(!is.finite(nodes$expertise_model_z)) || any(!is.finite(nodes$leadership_model_z))) {
  stop("Node covariates have missing/non-finite values.", call. = FALSE)
}
journals <- sort(unique(nodes$journal_folder))
if (length(journals) != EXPECTED_JOURNALS) {
  stop("Expected exactly ", EXPECTED_JOURNALS, " journals but found ", length(journals),
       ": ", paste(journals, collapse = ", "), call. = FALSE)
}
if (length(unique(nodes$block_id)) != EXPECTED_JOURNALS) {
  stop("There is not exactly one block ID per journal.", call. = FALSE)
}
message("Rebuilding pooled network: ", nrow(nodes), " nodes across ", length(journals), " journals.")

prior_big <- matrix(0L, nrow(nodes), nrow(nodes))
prior_sources <- vector("list", length(journals))
for (k in seq_along(journals)) {
  j <- journals[[k]]
  idx <- which(nodes$journal_folder == j)
  ids <- nodes$original_global_id[idx]
  prior_file <- find_prior(j)
  p <- read_prior(prior_file)
  if (!setequal(ids, rownames(p))) {
    stop("Prior/node IDs do not match for ", j, ". Missing from prior: ",
         paste(head(setdiff(ids, rownames(p)), 10L), collapse = ", "),
         call. = FALSE)
  }
  p <- p[ids, ids, drop = FALSE]
  prior_big[idx, idx] <- p
  prior_sources[[k]] <- data.frame(
    journal_folder = j, block_id = unique(nodes$block_id[idx]),
    prior_file = normalizePath(prior_file, mustWork = TRUE), nodes = length(idx),
    prior_dyads = sum(p[upper.tri(p)] > 0), stringsAsFactors = FALSE)
}
prior_sources <- do.call(rbind, prior_sources)
diag(prior_big) <- 0L
if (!isTRUE(all.equal(prior_big, t(prior_big), tolerance = 1e-12))) {
  stop("The rebuilt pooled prior matrix is not symmetric.", call. = FALSE)
}

net_big <- network.initialize(nrow(nodes), directed = FALSE, loops = FALSE, multiple = FALSE)
network.vertex.names(net_big) <- nodes$vertex_id
set.vertex.attribute(net_big, "block_id", nodes$block_id)
set.vertex.attribute(net_big, "journal", nodes$journal_folder)
set.vertex.attribute(net_big, "expertise_model_z", as.numeric(nodes$expertise_model_z))
set.vertex.attribute(net_big, "leadership_model_z", as.numeric(nodes$leadership_model_z))
tail <- match(clean_id(edges$u), nodes$vertex_id)
head <- match(clean_id(edges$v), nodes$vertex_id)
if (anyNA(tail) || anyNA(head) || any(tail == head)) stop("Invalid endpoint in combined edge list.", call. = FALSE)
if (any(nodes$block_id[tail] != nodes$block_id[head])) stop("Found a cross-journal edge.", call. = FALSE)
key <- paste(pmin(tail, head), pmax(tail, head), sep = "_")
if (anyDuplicated(key)) stop("Combined edge list has duplicate undirected edges.", call. = FALSE)
add.edges(net_big, tail = tail, head = head)
if (network.edgecount(net_big) != nrow(edges)) stop("Network edge count differs from combined_edges_used.csv.", call. = FALSE)

block_sizes <- table(nodes$block_id)
within_dyads <- sum(block_sizes * (block_sizes - 1) / 2)
network_summary <- data.frame(
  journals = length(journals), nodes = network.size(net_big), edges = network.edgecount(net_big),
  possible_within_journal_dyads = as.numeric(within_dyads),
  prior_dyads = sum(prior_big[upper.tri(prior_big)] > 0),
  cross_journal_dyads_excluded = choose(network.size(net_big), 2) - as.numeric(within_dyads),
  stringsAsFactors = FALSE
)
write.csv(network_summary, file.path(OUTPUT_DIR, "network_reconstruction_summary.csv"), row.names = FALSE)
write.csv(prior_sources, file.path(OUTPUT_DIR, "prior_matrix_sources.csv"), row.names = FALSE)
message("Network ready: ", network_summary$nodes, " nodes; ", network_summary$edges,
        " edges; cross-journal dyads excluded = ", network_summary$cross_journal_dyads_excluded)

constraint <- ~ blockdiag("block_id")
m4_formula <- net_big ~ edges + edgecov(prior_big) +
  nodecov("expertise_model_z") + absdiff("expertise_model_z") +
  nodecov("leadership_model_z") + absdiff("leadership_model_z")
m5_formula <- net_big ~ edges + edgecov(prior_big) +
  nodecov("expertise_model_z") + absdiff("expertise_model_z") +
  nodecov("leadership_model_z") + absdiff("leadership_model_z") +
  gwdegree(DECAY, fixed = TRUE)

message("\nFitting M4 exactly (reference model) ...")
m4 <- tryCatch(ergm(m4_formula, constraints = constraint, estimate = "MLE"), error = function(e) e)
if (!inherits(m4, "ergm")) stop("M4 failed: ", conditionMessage(m4), call. = FALSE)
saveRDS(m4, file.path(OUTPUT_DIR, "block_diagonal_m4_reference_model.rds"))
message("[OK] M4 fit returned.")

# Reproducing M4 here is a check that this M5-D used exactly the established
# pooled network, not a new or accidentally incomplete set of journals.
m4_check <- data.frame()
if (file.exists(M4_REFERENCE_FILE)) {
  old <- tryCatch(read.csv(M4_REFERENCE_FILE, stringsAsFactors = FALSE, check.names = FALSE), error = function(e) NULL)
  if (!is.null(old) && all(c("term", "Estimate") %in% names(old))) {
    now <- coef_table(m4, "m4_rebuilt", "exact_MLE", "fit_returned")
    m4_check <- merge(old[, c("term", "Estimate")], now[, c("term", "Estimate")],
      by = "term", all = TRUE, suffixes = c("_saved", "_rebuilt"))
    m4_check$absolute_difference <- abs(m4_check$Estimate_saved - m4_check$Estimate_rebuilt)
  }
}
write.csv(m4_check, file.path(OUTPUT_DIR, "m4_reconstruction_coefficient_check.csv"), row.names = FALSE)

base_m5_init <- c(coef(m4), "gwdeg.fixed.0.5" = 0)
expected_m5_names <- c(
  "edges", "edgecov.prior_big", "nodecov.expertise_model_z",
  "absdiff.expertise_model_z", "nodecov.leadership_model_z",
  "absdiff.leadership_model_z", "gwdeg.fixed.0.5"
)
if (!setequal(names(base_m5_init), expected_m5_names)) {
  stop("M4 coefficient names do not match the expected M5-D formula: ",
       paste(names(base_m5_init), collapse = ", "), call. = FALSE)
}
m5_init <- base_m5_init[expected_m5_names]
init_source <- "exact M4 coefficients plus gwdegree = 0"
if (isTRUE(USE_PREVIOUS_M5_INIT) && file.exists(PREVIOUS_M5_RDS)) {
  previous_m5 <- tryCatch(readRDS(PREVIOUS_M5_RDS), error = function(e) e)
  if (inherits(previous_m5, "ergm")) {
    previous_coef <- coef(previous_m5)
    if (setequal(names(previous_coef), expected_m5_names) && all(is.finite(previous_coef))) {
      m5_init <- previous_coef[expected_m5_names]
      init_source <- paste0("previous M5-D coefficients from ", PREVIOUS_M5_RDS)
    } else {
      message("[INFO] Existing M5-D RDS has incompatible or non-finite coefficients; using M4-based initialization.")
    }
  } else {
    message("[INFO] Existing M5-D RDS could not be read as an ergm fit; using M4-based initialization.")
  }
}
write.csv(
  data.frame(term = names(m5_init), initial_value = unname(m5_init),
             init_source = init_source, stringsAsFactors = FALSE),
  file.path(OUTPUT_DIR, "m5_gwdegree_initialization.csv"), row.names = FALSE
)
message("M5-D initialization: ", init_source)
ctl <- control.ergm(
  init = m5_init,
  seed = SEED + 1L,
  MCMLE.maxit = MCMLE_MAXIT,
  MCMC.burnin = MCMC_BURNIN,
  MCMC.interval = MCMC_INTERVAL,
  MCMLE.effectiveSize = MCMLE_EFFECTIVE_SIZE,
  MCMLE.last.boost = MCMLE_LAST_BOOST,
  MCMC.return.stats = MCMC_RETURN_STATS
)
message("Resolved controls: MCMLE.burnin = ", ctl$MCMLE.burnin,
        "; MCMC.interval = ", ctl$MCMC.interval,
        "; MCMLE.effectiveSize = ", ctl$MCMLE.effectiveSize)
message("\nFitting M5-D = M4 + gwdegree(", DECAY, ", fixed = TRUE) by MCMLE ...")
message("Do not report M5-D coefficients until MCMC diagnostics and constrained GOF are checked.")
m5 <- tryCatch(ergm(m5_formula, constraints = constraint, estimate = "MLE", control = ctl), error = function(e) e)

m4_coef <- coef_table(m4, "m4_full", "exact_MLE", "fit_returned")
if (inherits(m5, "ergm")) {
  status <- "fit_returned_inspect_mcmc_and_gof"
  error_text <- NA_character_
  saveRDS(m5, file.path(OUTPUT_DIR, "block_diagonal_m5_gwdegree_model.rds"))
  m5_coef <- coef_table(m5, "m5_full_gwdegree", "MCMLE", status)
  diag_status <- save_mcmc_diagnostics(m5)
  write.csv(diag_status, file.path(OUTPUT_DIR, "m5_gwdegree_diagnostic_files.csv"), row.names = FALSE)
  fits <- rbind(fit_row(m4, "m4_full", "exact_MLE", "fit_returned"),
                fit_row(m5, "m5_full_gwdegree", "MCMLE", status))
  message("[M5-D FIT RETURNED] Inspect the diagnostic files before interpreting it.")
} else {
  status <- "failed"
  error_text <- conditionMessage(m5)
  m5_coef <- data.frame(
    model = "m5_full_gwdegree", estimation = "MCMLE", term = NA_character_,
    Estimate = NA_real_, Std_Error = NA_real_, z_value = NA_real_, p_value = NA_real_,
    Odds_Ratio = NA_real_, CI_95_Lower = NA_real_, CI_95_Upper = NA_real_,
    interpretation = "M5-D failed; no M5-D coefficient should be reported.", status = status,
    stringsAsFactors = FALSE, check.names = FALSE)
  fits <- rbind(fit_row(m4, "m4_full", "exact_MLE", "fit_returned"),
                data.frame(model = "m5_full_gwdegree", estimation = "MCMLE", AIC = NA_real_,
                  BIC = NA_real_, logLik = NA_real_, status = status, error = error_text,
                  stringsAsFactors = FALSE))
  message("[M5-D FAILED] ", error_text)
}
coefs <- rbind(m4_coef, m5_coef)
write.csv(coefs, file.path(OUTPUT_DIR, "m4_m5_gwdegree_coefficients.csv"), row.names = FALSE)
write.csv(fits, file.path(OUTPUT_DIR, "m4_m5_gwdegree_model_fit.csv"), row.names = FALSE)
write.csv(data.frame(model = "m5_full_gwdegree", status = status, error = error_text,
  stringsAsFactors = FALSE), file.path(OUTPUT_DIR, "m5_gwdegree_status.csv"), row.names = FALSE)
settings <- data.frame(
  setting = c("script_version", "root_dir", "expected_journals", "gwdegree_decay",
    "density_specification", "m4_estimation", "m5_estimation", "mcmle_maxit",
    "mcmc_burnin", "mcmc_interval", "mcmle_effective_size", "mcmle_last_boost",
    "mcmc_return_stats", "seed", "m5_initialization", "previous_m5_rds", "constraint"),
  value = c(SCRIPT_VERSION, ROOT_DIR, EXPECTED_JOURNALS, DECAY,
    "one global edges term; blockdiag only", "exact MLE", "MCMLE", MCMLE_MAXIT,
    MCMC_BURNIN, MCMC_INTERVAL, MCMLE_EFFECTIVE_SIZE, MCMLE_LAST_BOOST,
    MCMC_RETURN_STATS, SEED, init_source, PREVIOUS_M5_RDS, "~ blockdiag(\"block_id\")"),
  stringsAsFactors = FALSE)
write.csv(settings, file.path(OUTPUT_DIR, "run_settings.csv"), row.names = FALSE)
write.csv(settings, file.path(OUTPUT_DIR, "m5_gwdegree_highprecision_settings.csv"), row.names = FALSE)
openxlsx::write.xlsx(list(
  coefficients = coefs, model_fit = fits, reconstruction = network_summary,
  prior_sources = prior_sources, m4_reconstruction_check = m4_check, settings = settings
), file.path(OUTPUT_DIR, "block_diagonal_m5_gwdegree_results.xlsx"), overwrite = TRUE)

message("\nOutputs: ", OUTPUT_DIR)
message("M5 status: ", status)
if (inherits(m5, "ergm")) message("Next: review m5_gwdegree_mcmc_diagnostics.txt, then run constrained GOF.")

