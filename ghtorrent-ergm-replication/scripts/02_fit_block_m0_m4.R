# ================================================================
# SciSciNet block-diagonal ERGM analysis: M0--M4, exact MLE
#
# This script pools the journal-specific networks into one disconnected
# block-diagonal network. Cross-journal dyads are structurally excluded
# with the blockdiag("block_id") constraint.
#
# Run from the repository root, for example:
#
#   SCISCINET_INPUT_DIR=data/processed/journals \
#   SCISCINET_OUTPUT_DIR=results/recomputed/block_m0_m4 \
#   Rscript scripts/02_fit_block_m0_m4.R
#
# Each immediate journal directory may contain its CSV triplet directly
# or in one nested processing directory:
#   *_nodes.csv      (global_id plus standardized covariates)
#   *_edges.csv      (u, v; undirected current-period ties)
#   *_prior_mat.csv  (square, symmetric prior-tie matrix)
# ================================================================

SCRIPT_VERSION <- "SciSciNet block-diagonal ERGM M0--M4 MLE 2026-08-31 v1.0"
message("Running: ", SCRIPT_VERSION)

get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0L) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[[1L]]))))
  }
  normalizePath(getwd(), mustWork = TRUE)
}

input_dir_from_env <- Sys.getenv("SCISCINET_INPUT_DIR", unset = "")
output_dir_from_env <- Sys.getenv("SCISCINET_OUTPUT_DIR", unset = "")

ROOT_DIR <- if (nzchar(input_dir_from_env)) {
  normalizePath(input_dir_from_env, mustWork = TRUE)
} else {
  get_script_dir()
}

OUTPUT_DIR <- if (nzchar(output_dir_from_env)) {
  normalizePath(output_dir_from_env, mustWork = FALSE)
} else {
  file.path(ROOT_DIR, "block_diagonal_journal_m0_m4")
}

OUTPUT_XLSX <- file.path(OUTPUT_DIR, "block_diagonal_journal_ergm_results.xlsx")
MODELS_RDS <- file.path(OUTPUT_DIR, "block_diagonal_journal_ergm_models.rds")
OUTPUT_TXT <- file.path(OUTPUT_DIR, "block_diagonal_journal_ergm_output.txt")
ESTIMATION_METHOD <- "MLE"

required_packages <- c("network", "ergm", "openxlsx")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0L) {
  stop(
    paste0(
      "Missing required R package(s): ",
      paste(missing_packages, collapse = ", "),
      ". Install with install.packages(c(",
      paste(sprintf('"%s"', missing_packages), collapse = ", "),
      "))."
    ),
    call. = FALSE
  )
}

suppressPackageStartupMessages({
  library(network)
  library(ergm)
  library(openxlsx)
})

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

clean_id <- function(x) {
  trimws(as.character(x))
}

safe_file_name <- function(x) {
  value <- gsub("[^A-Za-z0-9._-]+", "_", x)
  value <- gsub("^_+|_+$", "", value)
  ifelse(value == "", "journal", value)
}

relative_to_root <- function(path, root = ROOT_DIR) {
  path_normalized <- normalizePath(path, mustWork = FALSE)
  root_normalized <- normalizePath(root, mustWork = FALSE)
  root_prefix <- paste0(root_normalized, .Platform$file.sep)
  if (identical(path_normalized, root_normalized)) {
    return(".")
  }
  if (startsWith(path_normalized, root_prefix)) {
    return(substr(path_normalized, nchar(root_prefix) + 1L, nchar(path_normalized)))
  }
  path_normalized
}

assert_columns <- function(data, required, object_name) {
  missing <- setdiff(required, names(data))
  if (length(missing) > 0L) {
    stop(
      sprintf(
        "%s is missing required column(s): %s. Available columns: %s",
        object_name,
        paste(missing, collapse = ", "),
        paste(names(data), collapse = ", ")
      ),
      call. = FALSE
    )
  }
}

pick_first_column <- function(data, candidates, variable_name) {
  hit <- candidates[candidates %in% names(data)]
  if (length(hit) == 0L) {
    stop(
      paste0(
        "Could not find a usable ", variable_name, " column. Expected one of: ",
        paste(candidates, collapse = ", "), ". Available columns: ",
        paste(names(data), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  hit[[1L]]
}

find_one_input_file <- function(folder, include_pattern, label, exclude_pattern = NULL) {
  candidates <- list.files(
    folder,
    pattern = include_pattern,
    full.names = TRUE,
    recursive = TRUE,
    ignore.case = TRUE
  )
  candidates <- candidates[file.info(candidates)$isdir %in% FALSE]

  if (!is.null(exclude_pattern) && length(candidates) > 0L) {
    candidates <- candidates[
      !grepl(exclude_pattern, basename(candidates), ignore.case = TRUE)
    ]
  }

  normalized_output <- normalizePath(OUTPUT_DIR, mustWork = FALSE)
  if (length(candidates) > 0L) {
    candidates <- candidates[
      !startsWith(normalizePath(candidates, mustWork = FALSE), normalized_output)
    ]
  }

  if (length(candidates) == 0L) {
    stop(sprintf("Missing %s in journal folder %s.", label, basename(folder)), call. = FALSE)
  }
  if (length(candidates) > 1L) {
    stop(
      paste0(
        "Found multiple possible ", label, " files in journal folder ", basename(folder), ":\n- ",
        paste(candidates, collapse = "\n- ")
      ),
      call. = FALSE
    )
  }
  candidates[[1L]]
}

discover_input_files <- function(folder) {
  list(
    nodes = find_one_input_file(folder, "_nodes\\.csv$", "*_nodes.csv"),
    edges = find_one_input_file(
      folder,
      "_edges\\.csv$",
      "*_edges.csv",
      exclude_pattern = "_prior_edges\\.csv$"
    ),
    prior_matrix = find_one_input_file(folder, "_prior_mat\\.csv$", "*_prior_mat.csv")
  )
}

read_character_csv <- function(path) {
  read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    colClasses = "character",
    na.strings = c("", "NA", "NaN", "nan")
  )
}

read_prior_matrix <- function(path) {
  raw <- read_character_csv(path)
  if (ncol(raw) < 2L) {
    stop(paste0(basename(path), " does not contain a matrix."), call. = FALSE)
  }

  row_ids <- clean_id(raw[[1L]])
  prior <- as.matrix(raw[-1L])
  suppressWarnings(storage.mode(prior) <- "double")
  rownames(prior) <- row_ids
  colnames(prior) <- clean_id(colnames(prior))

  if (nrow(prior) != ncol(prior)) {
    stop("The prior matrix is not square.", call. = FALSE)
  }
  if (anyNA(prior) || any(!is.finite(prior)) || any(prior < 0)) {
    stop("The prior matrix contains invalid values.", call. = FALSE)
  }
  if (anyDuplicated(rownames(prior)) > 0L || anyDuplicated(colnames(prior)) > 0L) {
    stop("The prior matrix contains duplicated IDs.", call. = FALSE)
  }
  if (!setequal(rownames(prior), colnames(prior))) {
    stop("Prior-matrix row and column ID sets differ.", call. = FALSE)
  }

  prior <- prior[rownames(prior), rownames(prior), drop = FALSE]
  if (!isTRUE(all.equal(prior, t(prior), tolerance = 1e-12))) {
    stop("The prior matrix is not symmetric.", call. = FALSE)
  }

  prior <- 1L * (prior > 0)
  diag(prior) <- 0L
  prior
}

degree_from_edge_indices <- function(tail_index, head_index, number_of_nodes) {
  tabulate(c(as.integer(tail_index), as.integer(head_index)), nbins = number_of_nodes)
}

preprocess_journal <- function(folder, position) {
  journal <- basename(folder)
  input_files <- discover_input_files(folder)
  nodes <- read_character_csv(input_files$nodes)
  edges <- read_character_csv(input_files$edges)
  prior <- read_prior_matrix(input_files$prior_matrix)

  assert_columns(nodes, "global_id", paste0(journal, " nodes file"))
  assert_columns(edges, c("u", "v"), paste0(journal, " edges file"))

  expertise_column <- pick_first_column(
    nodes,
    c("expertise_z", "expertise_model_z", "expertise_z_shared"),
    "standardized expertise"
  )
  leadership_column <- pick_first_column(
    nodes,
    c("leadership_z", "leadership_model_z", "leadership_z_shared"),
    "standardized leadership"
  )

  nodes$global_id <- clean_id(nodes$global_id)
  edges$u <- clean_id(edges$u)
  edges$v <- clean_id(edges$v)
  nodes <- nodes[!is.na(nodes$global_id) & nodes$global_id != "", , drop = FALSE]
  edges <- edges[
    !is.na(edges$u) & edges$u != "" & !is.na(edges$v) & edges$v != "" & edges$u != edges$v,
    ,
    drop = FALSE
  ]

  if (nrow(nodes) < 2L || anyDuplicated(nodes$global_id) > 0L) {
    stop(paste0(journal, " has fewer than two valid nodes or duplicated global_id values."), call. = FALSE)
  }

  node_ids <- nodes$global_id
  unknown_ids <- setdiff(unique(c(edges$u, edges$v)), node_ids)
  if (length(unknown_ids) > 0L) {
    stop(
      paste0(journal, " edges include IDs absent from nodes: ", paste(head(unknown_ids, 20L), collapse = ", ")),
      call. = FALSE
    )
  }

  edge_low <- ifelse(edges$u < edges$v, edges$u, edges$v)
  edge_high <- ifelse(edges$u < edges$v, edges$v, edges$u)
  edges <- edges[!duplicated(paste(edge_low, edge_high, sep = "\r")), , drop = FALSE]

  if (!setequal(node_ids, rownames(prior))) {
    stop(paste0(journal, " node IDs and prior-matrix IDs do not match."), call. = FALSE)
  }
  prior <- prior[node_ids, node_ids, drop = FALSE]

  expertise_values <- suppressWarnings(as.numeric(nodes[[expertise_column]]))
  leadership_values <- suppressWarnings(as.numeric(nodes[[leadership_column]]))
  if (anyNA(expertise_values) || any(!is.finite(expertise_values)) || stats::sd(expertise_values) == 0) {
    stop(paste0(journal, " expertise covariate is invalid or has zero variance."), call. = FALSE)
  }
  if (anyNA(leadership_values) || any(!is.finite(leadership_values)) || stats::sd(leadership_values) == 0) {
    stop(paste0(journal, " leadership covariate is invalid or has zero variance."), call. = FALSE)
  }

  tail_index <- match(edges$u, node_ids)
  head_index <- match(edges$v, node_ids)
  degree_values <- degree_from_edge_indices(tail_index, head_index, length(node_ids))
  if (any(degree_values == 0L)) {
    stop(
      sprintf("%s contains %d isolate(s); input must be preprocessed before fitting.", journal, sum(degree_values == 0L)),
      call. = FALSE
    )
  }

  block_id <- sprintf("block_%03d_%s", position, safe_file_name(journal))
  combined_ids <- paste(block_id, node_ids, sep = "__")
  author_id <- if ("AuthorID" %in% names(nodes)) as.character(nodes$AuthorID) else NA_character_
  possible_dyads <- length(node_ids) * (length(node_ids) - 1) / 2
  upper <- upper.tri(prior)

  list(
    journal = journal,
    block_id = block_id,
    nodes = data.frame(
      vertex_id = combined_ids,
      journal_folder = journal,
      block_id = block_id,
      original_global_id = node_ids,
      AuthorID = author_id,
      expertise_model_z = expertise_values,
      leadership_model_z = leadership_values,
      stringsAsFactors = FALSE
    ),
    edges = data.frame(
      journal_folder = journal,
      block_id = block_id,
      u = combined_ids[tail_index],
      v = combined_ids[head_index],
      u_original = edges$u,
      v_original = edges$v,
      stringsAsFactors = FALSE
    ),
    prior = prior,
    summary = data.frame(
      block_id = block_id,
      journal_folder = journal,
      nodes_file = relative_to_root(input_files$nodes),
      edges_file = relative_to_root(input_files$edges),
      prior_file = relative_to_root(input_files$prior_matrix),
      expertise_column_used = expertise_column,
      leadership_column_used = leadership_column,
      number_of_nodes = length(node_ids),
      number_of_edges = nrow(edges),
      possible_within_journal_dyads = possible_dyads,
      density = nrow(edges) / possible_dyads,
      number_of_prior_dyads = sum(prior[upper] > 0),
      prior_current_edges = sum(prior[cbind(tail_index, head_index)] > 0),
      prior_current_nonedges = sum(prior[upper] > 0) - sum(prior[cbind(tail_index, head_index)] > 0),
      mean_expertise_z = mean(expertise_values),
      sd_expertise_z = stats::sd(expertise_values),
      mean_leadership_z = mean(leadership_values),
      sd_leadership_z = stats::sd(leadership_values),
      stringsAsFactors = FALSE
    )
  )
}

empty_coefficients <- function() {
  data.frame(
    analysis = character(), model = character(), term = character(), Estimate = numeric(),
    Std_Error = numeric(), z_value = numeric(), p_value = numeric(), Odds_Ratio = numeric(),
    CI_95_Lower = numeric(), CI_95_Upper = numeric(), significance = character(),
    status = character(), error = character(), stringsAsFactors = FALSE, check.names = FALSE
  )
}

significance_code <- function(p) {
  ifelse(is.na(p), "", ifelse(p < 0.001, "***", ifelse(p < 0.01, "**", ifelse(p < 0.05, "*", ""))))
}

extract_coefficients <- function(fit, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      analysis = "block_diagonal_journals", model = model_name, term = NA_character_,
      Estimate = NA_real_, Std_Error = NA_real_, z_value = NA_real_, p_value = NA_real_,
      Odds_Ratio = NA_real_, CI_95_Lower = NA_real_, CI_95_Upper = NA_real_,
      significance = "", status = "failed", error = conditionMessage(fit),
      stringsAsFactors = FALSE, check.names = FALSE
    ))
  }

  estimate <- stats::coef(fit)
  variance <- tryCatch(stats::vcov(fit), error = function(e) NULL)
  std_error <- if (is.null(variance)) rep(NA_real_, length(estimate)) else sqrt(diag(variance))
  z_value <- estimate / std_error
  p_value <- 2 * stats::pnorm(abs(z_value), lower.tail = FALSE)
  data.frame(
    analysis = "block_diagonal_journals", model = model_name, term = names(estimate),
    Estimate = as.numeric(estimate), Std_Error = as.numeric(std_error), z_value = as.numeric(z_value),
    p_value = as.numeric(p_value), Odds_Ratio = exp(as.numeric(estimate)),
    CI_95_Lower = exp(as.numeric(estimate) - 1.96 * as.numeric(std_error)),
    CI_95_Upper = exp(as.numeric(estimate) + 1.96 * as.numeric(std_error)),
    significance = significance_code(p_value), status = "ok", error = NA_character_,
    stringsAsFactors = FALSE, check.names = FALSE
  )
}

extract_fit <- function(fit, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      analysis = "block_diagonal_journals", model = model_name, AIC = NA_real_, BIC = NA_real_,
      logLik = NA_real_, estimation_method = ESTIMATION_METHOD, status = "failed",
      error = conditionMessage(fit), stringsAsFactors = FALSE
    ))
  }
  data.frame(
    analysis = "block_diagonal_journals", model = model_name,
    AIC = tryCatch(AIC(fit), error = function(e) NA_real_),
    BIC = tryCatch(BIC(fit), error = function(e) NA_real_),
    logLik = tryCatch(as.numeric(stats::logLik(fit)), error = function(e) NA_real_),
    estimation_method = ESTIMATION_METHOD, status = "ok", error = NA_character_,
    stringsAsFactors = FALSE
  )
}

write_sheet <- function(workbook, name, data) {
  openxlsx::addWorksheet(workbook, name, gridLines = FALSE)
  openxlsx::writeData(workbook, name, data, withFilter = nrow(data) > 0L)
  openxlsx::freezePane(workbook, name, firstRow = TRUE)
  if (ncol(data) > 0L) {
    openxlsx::setColWidths(workbook, name, cols = seq_len(ncol(data)), widths = "auto")
  }
}

journal_folders <- list.dirs(ROOT_DIR, full.names = TRUE, recursive = FALSE)
journal_folders <- sort(journal_folders[
  !grepl("^\\.", basename(journal_folders)) &
    normalizePath(journal_folders, mustWork = FALSE) != normalizePath(OUTPUT_DIR, mustWork = FALSE)
])
if (length(journal_folders) == 0L) {
  stop(paste0("No journal directories found under: ", ROOT_DIR), call. = FALSE)
}

processed <- list()
discovery_rows <- list()
failed_rows <- list()
for (position in seq_along(journal_folders)) {
  folder <- journal_folders[[position]]
  journal <- basename(folder)
  message("Preprocessing ", journal, " ...")
  result <- tryCatch(preprocess_journal(folder, position), error = function(e) e)
  if (inherits(result, "error")) {
    error_text <- conditionMessage(result)
    message("[FAILED] ", journal, ": ", error_text)
    discovery_rows[[length(discovery_rows) + 1L]] <- data.frame(
      journal_folder = journal, journal_root = relative_to_root(folder), status = "failed",
      error = error_text, stringsAsFactors = FALSE
    )
    failed_rows[[length(failed_rows) + 1L]] <- data.frame(
      journal_folder = journal, error = error_text, stringsAsFactors = FALSE
    )
  } else {
    processed[[length(processed) + 1L]] <- result
    discovery_rows[[length(discovery_rows) + 1L]] <- data.frame(
      journal_folder = journal, journal_root = relative_to_root(folder), status = "included",
      error = NA_character_, stringsAsFactors = FALSE
    )
  }
}

if (length(processed) == 0L) {
  stop("No valid journal networks remain after validation.", call. = FALSE)
}

combined_nodes <- do.call(rbind, lapply(processed, `[[`, "nodes"))
combined_edges <- do.call(rbind, lapply(processed, `[[`, "edges"))
journal_block_summary <- do.call(rbind, lapply(processed, `[[`, "summary"))
journal_discovery <- do.call(rbind, discovery_rows)
failed_journals <- if (length(failed_rows) == 0L) {
  data.frame(journal_folder = character(), error = character(), stringsAsFactors = FALSE)
} else {
  do.call(rbind, failed_rows)
}

number_of_nodes <- nrow(combined_nodes)
prior_big <- matrix(0L, nrow = number_of_nodes, ncol = number_of_nodes)
offset <- 0L
for (result in processed) {
  indices <- seq.int(offset + 1L, offset + nrow(result$nodes))
  prior_big[indices, indices] <- result$prior
  offset <- offset + nrow(result$nodes)
}

net <- network.initialize(number_of_nodes, directed = FALSE, loops = FALSE, multiple = FALSE)
network.vertex.names(net) <- combined_nodes$vertex_id
set.vertex.attribute(net, "block_id", combined_nodes$block_id)
set.vertex.attribute(net, "expertise_model_z", combined_nodes$expertise_model_z)
set.vertex.attribute(net, "leadership_model_z", combined_nodes$leadership_model_z)

tail_index <- match(combined_edges$u, combined_nodes$vertex_id)
head_index <- match(combined_edges$v, combined_nodes$vertex_id)
if (nrow(combined_edges) > 0L) {
  add.edges(net, tail = tail_index, head = head_index)
}
if (network.edgecount(net) != nrow(combined_edges)) {
  stop("Combined network edge count does not match the cleaned edge input.", call. = FALSE)
}

current_matrix <- as.matrix.network.adjacency(net)
eligible_dyads <- upper.tri(current_matrix) &
  outer(combined_nodes$block_id, combined_nodes$block_id, FUN = "==")
current_prior <- as.data.frame.matrix(table(
  current_tie = factor(current_matrix[eligible_dyads], levels = c(0, 1)),
  prior_tie = factor(prior_big[eligible_dyads], levels = c(0, 1))
))
current_prior$current_tie <- rownames(current_prior)
rownames(current_prior) <- NULL
current_prior <- current_prior[c("current_tie", setdiff(names(current_prior), "current_tie"))]
names(current_prior)[-1L] <- c("prior_0", "prior_1")

block_constraint <- ~blockdiag("block_id")
fit_ergm_safe <- function(formula) {
  tryCatch(
    ergm(formula, constraints = block_constraint, estimate = ESTIMATION_METHOD),
    error = function(e) e
  )
}

model_formulas <- list(
  m0_edges = net ~ edges,
  m1_prior = net ~ edges + edgecov(prior_big),
  m2_prior_expertise = net ~ edges + edgecov(prior_big) + nodecov("expertise_model_z"),
  m3_prior_expertise_similarity = net ~
    edges + edgecov(prior_big) + nodecov("expertise_model_z") + absdiff("expertise_model_z"),
  m4_full = net ~
    edges + edgecov(prior_big) + nodecov("expertise_model_z") + absdiff("expertise_model_z") +
    nodecov("leadership_model_z") + absdiff("leadership_model_z")
)

models <- list()
for (model_name in names(model_formulas)) {
  message("Fitting ", model_name, " ...")
  models[[model_name]] <- fit_ergm_safe(model_formulas[[model_name]])
  if (inherits(models[[model_name]], "ergm")) {
    message("[OK] ", model_name)
  } else {
    message("[FAILED] ", model_name, ": ", conditionMessage(models[[model_name]]))
  }
}

coefficients_all <- do.call(rbind, lapply(names(models), function(model_name) {
  extract_coefficients(models[[model_name]], model_name)
}))
coefficients_m4 <- coefficients_all[coefficients_all$model == "m4_full", , drop = FALSE]
model_fit <- do.call(rbind, lapply(names(models), function(model_name) {
  extract_fit(models[[model_name]], model_name)
}))
failed_models <- model_fit[model_fit$status != "ok", , drop = FALSE]

possible_dyads <- sum(journal_block_summary$possible_within_journal_dyads)
upper <- upper.tri(prior_big)
combined_summary <- data.frame(
  analysis = "block_diagonal_journals",
  script_version = SCRIPT_VERSION,
  estimation_method = "exact MLE (dyad-independent terms)",
  constraint = "blockdiag(block_id): cross-journal dyads excluded",
  number_of_journals = nrow(journal_block_summary),
  journals_included = paste(journal_block_summary$journal_folder, collapse = ", "),
  number_of_nodes = number_of_nodes,
  number_of_edges = network.edgecount(net),
  possible_within_journal_dyads = possible_dyads,
  within_journal_density = network.edgecount(net) / possible_dyads,
  number_of_prior_dyads = sum(prior_big[eligible_dyads] > 0),
  prior_current_edges = sum(prior_big[cbind(tail_index, head_index)] > 0),
  prior_current_nonedges = sum(prior_big[eligible_dyads] > 0) - sum(prior_big[cbind(tail_index, head_index)] > 0),
  stringsAsFactors = FALSE
)

model_specifications <- data.frame(
  model = names(model_formulas),
  terms = c(
    "edges",
    "edges + edgecov(prior_big)",
    "edges + edgecov(prior_big) + nodecov(expertise_model_z)",
    "edges + edgecov(prior_big) + nodecov(expertise_model_z) + absdiff(expertise_model_z)",
    "edges + edgecov(prior_big) + nodecov(expertise_model_z) + absdiff(expertise_model_z) + nodecov(leadership_model_z) + absdiff(leadership_model_z)"
  ),
  stringsAsFactors = FALSE
)

write.csv(coefficients_m4, file.path(OUTPUT_DIR, "block_diagonal_M4_coefficients.csv"), row.names = FALSE)
write.csv(coefficients_all, file.path(OUTPUT_DIR, "block_diagonal_all_model_coefficients.csv"), row.names = FALSE)
write.csv(model_fit, file.path(OUTPUT_DIR, "block_diagonal_model_fit.csv"), row.names = FALSE)
write.csv(journal_block_summary, file.path(OUTPUT_DIR, "journal_block_summary.csv"), row.names = FALSE)
write.csv(journal_discovery, file.path(OUTPUT_DIR, "journal_discovery.csv"), row.names = FALSE)
write.csv(failed_journals, file.path(OUTPUT_DIR, "journal_validation_failures.csv"), row.names = FALSE)
write.csv(combined_nodes, file.path(OUTPUT_DIR, "combined_nodes_used.csv"), row.names = FALSE)
write.csv(combined_edges, file.path(OUTPUT_DIR, "combined_edges_used.csv"), row.names = FALSE)
write.csv(failed_models, file.path(OUTPUT_DIR, "failed_models.csv"), row.names = FALSE)

workbook <- openxlsx::createWorkbook()
write_sheet(workbook, "coefficients_M4", coefficients_m4)
write_sheet(workbook, "coefficients_all_models", coefficients_all)
write_sheet(workbook, "model_fit", model_fit)
write_sheet(workbook, "model_specifications", model_specifications)
write_sheet(workbook, "combined_summary", combined_summary)
write_sheet(workbook, "current_by_prior", current_prior)
write_sheet(workbook, "journal_block_summary", journal_block_summary)
write_sheet(workbook, "journal_discovery", journal_discovery)
write_sheet(workbook, "combined_nodes", combined_nodes)
write_sheet(workbook, "failed_models", failed_models)
write_sheet(workbook, "failed_journals", failed_journals)
openxlsx::saveWorkbook(workbook, OUTPUT_XLSX, overwrite = TRUE)

saveRDS(models, MODELS_RDS)
output_lines <- capture.output({
  cat("SciSciNet journal block-diagonal ERGM: M0--M4 exact MLE\n")
  cat("Script version:", SCRIPT_VERSION, "\n")
  cat("Input directory:", ROOT_DIR, "\n")
  cat("Constraint: blockdiag(block_id); cross-journal dyads excluded\n\n")
  print(combined_summary)
  cat("\nCurrent tie by prior collaboration:\n")
  print(current_prior)
  cat("\nJournal block summary:\n")
  print(journal_block_summary)
  for (model_name in names(models)) {
    cat("\n---------------- ", model_name, " ----------------\n", sep = "")
    if (inherits(models[[model_name]], "ergm")) {
      print(extract_coefficients(models[[model_name]], model_name))
      cat("AIC:", tryCatch(AIC(models[[model_name]]), error = function(e) NA_real_), "\n")
      cat("BIC:", tryCatch(BIC(models[[model_name]]), error = function(e) NA_real_), "\n")
    } else {
      cat("FAILED:", conditionMessage(models[[model_name]]), "\n")
    }
  }
})
writeLines(output_lines, OUTPUT_TXT, useBytes = TRUE)

message("\nBlock-diagonal ERGM analysis completed.")
message("Journals included: ", nrow(journal_block_summary))
message("Successful models: ", sum(model_fit$status == "ok"))
message("[SAVED] ", normalizePath(OUTPUT_DIR, mustWork = FALSE))
