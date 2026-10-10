# ================================================================
# MyDreamTeam: block-diagonal MLE ERGM across the selected sessions (M0--M5)
#
# Expected folder structure:
# ROOT_DIR/
#   337/
#     mdt_current_network_nodes.csv
#     mdt_current_network_edges.csv
#     mdt_team_users_project_skill_average.csv
#     mdt_team_users_leadership_score.csv
#     mdt_prior_mat.csv
#   341/
#     ...
#
# All valid immediate session folders are combined into ONE network.
# Each person receives a session-specific vertex ID. Cross-session
# dyads are excluded from the risk set by:
#   constraints = ~ blockdiag("block_id")
#
# Attribute transformation, performed separately within each session:
#   expertise_model_z  = z-score(log1p(avg_project_skill))
#   leadership_model_z = z-score(log1p(leadership_score))
#
# No network figures are generated.
#
# Output:
# ROOT_DIR/results/02_block_ergm_m0_m5_gwesp_mle/
#   02_block_ergm_m0_m5_gwesp_mle.xlsx
#   block_diagonal_ergm_output.txt
#   combined_nodes_used.csv
#   combined_edges_used.csv
#   block_summary.csv
# ================================================================

SCRIPT_VERSION <- "MDT selected-session block-diagonal ERGM M0--M5 with fixed GWESP, 2026-08-23 v2"
message("Running: ", SCRIPT_VERSION)


# ----------------------------------------------------------------
# 0. User settings
# ----------------------------------------------------------------

# Use the parent folder containing all selected session subfolders. It can be
# supplied explicitly, e.g. Rscript scripts/r/05_fit_mydreamteam_block_m0_m5.R data/processed/mydreamteam
user_args <- commandArgs(trailingOnly = TRUE)
if (length(user_args) > 1L) {
  stop("Use at most one argument: the MyDreamTeam input directory.", call. = FALSE)
}
ROOT_DIR <- if (length(user_args) == 1L) {
  normalizePath(user_args[[1L]], mustWork = TRUE)
} else {
  normalizePath(getwd(), mustWork = TRUE)
}

# The ten final sessions. Keep this vector identical across all three scripts.
SESSION_IDS <- c("6", "10", "11", "14", "91", "92", "101", "130", "133", "221")

# TRUE ensures that the block model is not fitted after silently
# dropping a session that failed validation.
STOP_IF_ANY_SESSION_FAILS <- TRUE

BINARIZE_PRIOR <- TRUE
SAVE_COMBINED_PRIOR_MATRIX <- FALSE
# Same fixed GWESP decay used in the SciSciNet and GHTorrent M5 models.
GWESP_DECAY <- 2.5
ESTIMATION_METHOD <- "MLE"
SEED <- 20260728L

OUTPUT_DIR <- file.path(
  ROOT_DIR,
  "results",
  "02_block_ergm_m0_m5_gwesp_mle"
)
OUTPUT_FILE <- file.path(
  OUTPUT_DIR,
  "02_block_ergm_m0_m5_gwesp_mle.xlsx"
)
TXT_FILE <- file.path(
  OUTPUT_DIR,
  "02_block_ergm_m0_m5_gwesp_mle_output.txt"
)


# ----------------------------------------------------------------
# 1. Required packages
# ----------------------------------------------------------------

required_packages <- c("network", "ergm", "openxlsx")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0L) {
  stop(
    paste0(
      "Missing required R package(s): ",
      paste(missing_packages, collapse = ", "),
      ".\nInstall them with:\ninstall.packages(c(",
      paste(sprintf('"%s"', missing_packages), collapse = ", "),
      "))"
    ),
    call. = FALSE
  )
}

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

# Load packages in the same way as the separate-session script that
# is already running successfully.
suppressPackageStartupMessages({
  library(network)
  library(ergm)
  library(openxlsx)
})

ERGM_CONTROL <- control.ergm(
  seed = SEED,
  MCMLE.maxit = 20,
  MCMC.burnin = 100000,
  MCMC.interval = 4096
)


# ----------------------------------------------------------------
# 2. Required files and helper functions
# ----------------------------------------------------------------

required_file_names <- c(
  "mdt_current_network_nodes.csv",
  "mdt_current_network_edges.csv",
  "mdt_team_users_project_skill_average.csv",
  "mdt_team_users_leadership_score.csv",
  "mdt_prior_mat.csv"
)

has_required_files <- function(folder) {
  all(file.exists(file.path(folder, required_file_names)))
}

clean_id <- function(x) {
  y <- trimws(as.character(x))
  y[
    is.na(y) |
      y %in% c("", "NA", "NaN", "nan", "<NA>", "NULL", "null", "None")
  ] <- NA_character_
  y
}

assert_columns <- function(data, required, object_name) {
  missing <- setdiff(required, names(data))
  if (length(missing) > 0L) {
    stop(
      sprintf(
        "%s is missing required column(s): %s",
        object_name,
        paste(missing, collapse = ", ")
      ),
      call. = FALSE
    )
  }
}

safe_z <- function(x) {
  x <- as.numeric(x)
  sx <- stats::sd(x)
  
  if (!is.finite(sx) || sx == 0) {
    return(rep(0, length(x)))
  }
  
  as.numeric(scale(x))
}

log_then_z <- function(x, variable_name, session_name) {
  x <- suppressWarnings(as.numeric(x))
  
  if (anyNA(x) || any(!is.finite(x))) {
    stop(
      sprintf(
        paste0(
          "Session %s: %s contains missing or non-finite values. ",
          "Regenerate the session files after removing users missing ",
          "either expertise or leadership."
        ),
        session_name,
        variable_name
      ),
      call. = FALSE
    )
  }
  
  if (any(x < 0)) {
    stop(
      sprintf(
        paste0(
          "Session %s: %s contains negative values. ",
          "log1p() requires nonnegative raw values."
        ),
        session_name,
        variable_name
      ),
      call. = FALSE
    )
  }
  
  logged <- log1p(x)
  
  list(
    raw = x,
    log = logged,
    z = safe_z(logged)
  )
}

degree_from_edge_indices <- function(
    tail_index,
    head_index,
    number_of_nodes
) {
  tabulate(
    c(as.integer(tail_index), as.integer(head_index)),
    nbins = number_of_nodes
  )
}

read_prior_matrix <- function(path, binarize = TRUE) {
  prior_raw <- read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    na.strings = c("", "NA", "NaN", "nan")
  )
  
  if (ncol(prior_raw) < 2L) {
    stop("The prior file does not contain a matrix.", call. = FALSE)
  }
  
  row_ids <- clean_id(prior_raw[[1L]])
  prior <- as.matrix(prior_raw[-1L])
  suppressWarnings(storage.mode(prior) <- "double")
  
  rownames(prior) <- row_ids
  colnames(prior) <- clean_id(colnames(prior))
  
  if (anyDuplicated(rownames(prior)) > 0L ||
      anyDuplicated(colnames(prior)) > 0L) {
    stop("The prior matrix contains duplicated IDs.", call. = FALSE)
  }
  if (nrow(prior) != ncol(prior)) {
    stop("The prior matrix is not square.", call. = FALSE)
  }
  if (anyNA(prior) || any(!is.finite(prior))) {
    stop(
      "The prior matrix contains missing or non-finite values.",
      call. = FALSE
    )
  }
  if (!setequal(rownames(prior), colnames(prior))) {
    stop(
      "The prior matrix row and column ID sets differ.",
      call. = FALSE
    )
  }
  
  prior <- prior[
    rownames(prior),
    rownames(prior),
    drop = FALSE
  ]
  
  if (!isTRUE(all.equal(prior, t(prior), tolerance = 1e-12))) {
    stop("The prior matrix is not symmetric.", call. = FALSE)
  }
  if (any(prior < 0)) {
    stop("The prior matrix contains negative values.", call. = FALSE)
  }
  
  if (binarize) {
    prior <- 1L * (prior > 0)
  }
  
  diag(prior) <- 0
  prior
}

fit_ergm_safe <- function(formula, control, constraints_formula) {
  tryCatch(
    ergm(
      formula,
      constraints = constraints_formula,
      estimate = ESTIMATION_METHOD,
      control = control
    ),
    error = function(e) e
  )
}

extract_coefficients <- function(fit, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      analysis = "block_diagonal_sessions",
      model = model_name,
      term = NA_character_,
      Estimate = NA_real_,
      Std_Error = NA_real_,
      MCMC_percent = NA_real_,
      z_value = NA_real_,
      p_value = NA_real_,
      status = "failed",
      error = conditionMessage(fit),
      stringsAsFactors = FALSE
    ))
  }
  
  # Do not call summary.ergm(). This mirrors the corrected separate
  # script and avoids the obsolete network::get.degree() path seen
  # with some ergm/network version combinations.
  estimate <- stats::coef(fit)
  variance <- tryCatch(
    stats::vcov(fit),
    error = function(e) NULL
  )
  
  if (is.null(names(estimate))) {
    term_names <- paste0("term_", seq_along(estimate))
  } else {
    term_names <- names(estimate)
  }
  
  if (is.null(variance) ||
      nrow(variance) != length(estimate) ||
      ncol(variance) != length(estimate)) {
    std_error <- rep(NA_real_, length(estimate))
  } else {
    variance_diagonal <- diag(variance)
    variance_diagonal[
      !is.finite(variance_diagonal) |
        variance_diagonal < 0
    ] <- NA_real_
    std_error <- sqrt(variance_diagonal)
  }
  
  z_value <- estimate / std_error
  p_value <- 2 * stats::pnorm(
    abs(z_value),
    lower.tail = FALSE
  )
  
  estimable <- (
    is.finite(estimate) &
      is.finite(std_error) &
      std_error > 0 &
      is.finite(z_value) &
      is.finite(p_value)
  )
  
  row_status <- ifelse(
    estimable,
    "ok",
    "not_estimable"
  )
  row_error <- ifelse(
    estimable,
    NA_character_,
    paste0(
      "Coefficient or standard error is non-finite; ",
      "the term is not estimable."
    )
  )
  
  # Replace non-finite values with NA before writing Excel so that
  # openxlsx does not produce #NUM!.
  estimate[!is.finite(estimate)] <- NA_real_
  std_error[!is.finite(std_error)] <- NA_real_
  z_value[!is.finite(z_value)] <- NA_real_
  p_value[!is.finite(p_value)] <- NA_real_
  
  data.frame(
    analysis = "block_diagonal_sessions",
    model = model_name,
    term = term_names,
    Estimate = as.numeric(estimate),
    Std_Error = as.numeric(std_error),
    MCMC_percent = NA_real_,
    z_value = as.numeric(z_value),
    p_value = as.numeric(p_value),
    status = row_status,
    error = row_error,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

extract_fit <- function(fit, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      analysis = "block_diagonal_sessions",
      model = model_name,
      AIC = NA_real_,
      BIC = NA_real_,
      status = "failed",
      error = conditionMessage(fit),
      stringsAsFactors = FALSE
    ))
  }
  
  aic_value <- tryCatch(
    AIC(fit),
    error = function(e) NA_real_
  )
  bic_value <- tryCatch(
    BIC(fit),
    error = function(e) NA_real_
  )
  
  if (!is.finite(aic_value)) {
    aic_value <- NA_real_
  }
  if (!is.finite(bic_value)) {
    bic_value <- NA_real_
  }
  
  data.frame(
    analysis = "block_diagonal_sessions",
    model = model_name,
    AIC = aic_value,
    BIC = bic_value,
    status = "ok",
    error = NA_character_,
    stringsAsFactors = FALSE
  )
}

bind_rows_base <- function(items) {
  items <- items[
    vapply(items, function(x) nrow(x) > 0L, logical(1))
  ]
  
  if (length(items) == 0L) {
    return(data.frame())
  }
  
  do.call(rbind, items)
}


# ----------------------------------------------------------------
# 3. Read and validate one session block
# ----------------------------------------------------------------

read_session_block <- function(folder, block_index) {
  session_name <- basename(folder)
  
  message(
    "\n================================================"
  )
  message("Preparing session block: ", session_name)
  message(
    "================================================"
  )
  
  nodes <- read.csv(
    file.path(folder, "mdt_current_network_nodes.csv"),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  edges <- read.csv(
    file.path(folder, "mdt_current_network_edges.csv"),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  expertise <- read.csv(
    file.path(
      folder,
      "mdt_team_users_project_skill_average.csv"
    ),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  leadership <- read.csv(
    file.path(
      folder,
      "mdt_team_users_leadership_score.csv"
    ),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  
  raw_node_rows <- nrow(nodes)
  raw_edge_rows <- nrow(edges)
  raw_expertise_rows <- nrow(expertise)
  raw_leadership_rows <- nrow(leadership)
  
  assert_columns(nodes, "node_id", "nodes")
  assert_columns(edges, c("source", "target"), "edges")
  assert_columns(
    expertise,
    c("user_id", "avg_project_skill"),
    "expertise"
  )
  assert_columns(
    leadership,
    c("user_id", "leadership_score"),
    "leadership"
  )
  
  nodes$node_id <- clean_id(nodes$node_id)
  edges$source <- clean_id(edges$source)
  edges$target <- clean_id(edges$target)
  expertise$user_id <- clean_id(expertise$user_id)
  leadership$user_id <- clean_id(leadership$user_id)
  
  nodes <- nodes[
    !is.na(nodes$node_id),
    ,
    drop = FALSE
  ]
  edges <- edges[
    !is.na(edges$source) &
      !is.na(edges$target) &
      edges$source != edges$target,
    ,
    drop = FALSE
  ]
  expertise <- expertise[
    !is.na(expertise$user_id),
    ,
    drop = FALSE
  ]
  leadership <- leadership[
    !is.na(leadership$user_id),
    ,
    drop = FALSE
  ]
  
  if (anyDuplicated(nodes$node_id) > 0L) {
    stop(
      "The node file contains duplicated node_id values.",
      call. = FALSE
    )
  }
  if (anyDuplicated(expertise$user_id) > 0L) {
    stop(
      "The expertise file contains duplicated user_id values.",
      call. = FALSE
    )
  }
  if (anyDuplicated(leadership$user_id) > 0L) {
    stop(
      "The leadership file contains duplicated user_id values.",
      call. = FALSE
    )
  }
  
  # Convert the raw covariates before defining the complete-case
  # node set. A user is eligible only when both variables are finite
  # and nonnegative (the latter is required by log1p()).
  expertise$avg_project_skill <- suppressWarnings(
    as.numeric(expertise$avg_project_skill)
  )
  leadership$leadership_score <- suppressWarnings(
    as.numeric(leadership$leadership_score)
  )
  
  valid_expertise_ids <- expertise$user_id[
    !is.na(expertise$avg_project_skill) &
      is.finite(expertise$avg_project_skill) &
      expertise$avg_project_skill >= 0
  ]
  valid_leadership_ids <- leadership$user_id[
    !is.na(leadership$leadership_score) &
      is.finite(leadership$leadership_score) &
      leadership$leadership_score >= 0
  ]
  
  # Use both the node file and current edge endpoints as candidate
  # IDs. This lets the block script recover from a stale/empty node
  # file when the edge and covariate files still contain the valid
  # analysis population. The final population remains a strict
  # complete-case, non-isolate population.
  candidate_ids <- unique(c(
    nodes$node_id,
    edges$source,
    edges$target
  ))
  candidate_ids <- candidate_ids[!is.na(candidate_ids)]
  
  complete_case_ids <- candidate_ids[
    candidate_ids %in% valid_expertise_ids &
      candidate_ids %in% valid_leadership_ids
  ]
  
  edges <- edges[
    edges$source %in% complete_case_ids &
      edges$target %in% complete_case_ids,
    ,
    drop = FALSE
  ]
  
  # Standardize each undirected edge and remove duplicates.
  if (nrow(edges) > 0L) {
    source_original <- ifelse(
      edges$source < edges$target,
      edges$source,
      edges$target
    )
    target_original <- ifelse(
      edges$source < edges$target,
      edges$target,
      edges$source
    )
    edges$source <- source_original
    edges$target <- target_original
    edges <- edges[
      !duplicated(paste(edges$source, edges$target, sep = "\r")),
      ,
      drop = FALSE
    ]
  }
  
  edge_node_ids <- unique(c(edges$source, edges$target))
  edge_node_ids <- edge_node_ids[!is.na(edge_node_ids)]
  node_ids <- candidate_ids[candidate_ids %in% edge_node_ids]
  
  message(
    "[CHECK] Session ", session_name,
    ": raw rows (nodes/edges/expertise/leadership) = ",
    raw_node_rows, "/", raw_edge_rows, "/",
    raw_expertise_rows, "/", raw_leadership_rows,
    "; candidate IDs = ", length(candidate_ids),
    "; complete-case IDs = ", length(complete_case_ids),
    "; final non-isolate IDs = ", length(node_ids)
  )
  
  if (length(node_ids) < 2L) {
    stop(
      sprintf(
        paste0(
          "Fewer than two valid nodes remain after complete-case ",
          "and non-isolate filtering (raw node rows=%d, raw edge ",
          "rows=%d, candidate IDs=%d, complete-case IDs=%d, ",
          "retained edges=%d, final nodes=%d)."
        ),
        raw_node_rows,
        raw_edge_rows,
        length(candidate_ids),
        length(complete_case_ids),
        nrow(edges),
        length(node_ids)
      ),
      call. = FALSE
    )
  }
  
  # Rebuild the model node table in a deterministic order. Existing
  # node metadata (for example team_id) is retained when available.
  node_frame <- data.frame(
    node_id = node_ids,
    stringsAsFactors = FALSE
  )
  nodes <- merge(
    node_frame,
    nodes,
    by = "node_id",
    all.x = TRUE,
    sort = FALSE
  )
  nodes <- nodes[
    match(node_ids, nodes$node_id),
    ,
    drop = FALSE
  ]
  rownames(nodes) <- NULL
  
  expertise <- expertise[
    match(node_ids, expertise$user_id),
    ,
    drop = FALSE
  ]
  leadership <- leadership[
    match(node_ids, leadership$user_id),
    ,
    drop = FALSE
  ]
  
  expertise_values <- log_then_z(
    expertise$avg_project_skill,
    "avg_project_skill",
    session_name
  )
  leadership_values <- log_then_z(
    leadership$leadership_score,
    "leadership_score",
    session_name
  )
  
  nodes$expertise_raw <- expertise_values$raw
  nodes$log_expertise <- expertise_values$log
  nodes$expertise_model_z <- expertise_values$z
  nodes$leadership_raw <- leadership_values$raw
  nodes$log_leadership <- leadership_values$log
  nodes$leadership_model_z <- leadership_values$z
  
  tail_local <- match(edges$source, node_ids)
  head_local <- match(edges$target, node_ids)
  
  if (anyNA(tail_local) || anyNA(head_local)) {
    stop(
      "Some edge endpoints cannot be matched to nodes.",
      call. = FALSE
    )
  }
  
  local_degrees <- degree_from_edge_indices(
    tail_local,
    head_local,
    nrow(nodes)
  )
  if (any(local_degrees == 0L)) {
    stop(
      sprintf(
        "Session %s contains %d isolate(s); regenerate the session files.",
        session_name,
        sum(local_degrees == 0L)
      ),
      call. = FALSE
    )
  }
  
  prior <- read_prior_matrix(
    file.path(folder, "mdt_prior_mat.csv"),
    binarize = BINARIZE_PRIOR
  )
  
  missing_prior_ids <- setdiff(node_ids, rownames(prior))
  if (length(missing_prior_ids) > 0L) {
    stop(
      paste0(
        "The prior matrix is missing final node ID(s): ",
        paste(head(missing_prior_ids, 10L), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  prior <- prior[node_ids, node_ids, drop = FALSE]
  
  current_adjacency <- matrix(
    0L,
    nrow = nrow(nodes),
    ncol = nrow(nodes),
    dimnames = list(node_ids, node_ids)
  )
  if (length(tail_local) > 0L) {
    current_adjacency[
      cbind(tail_local, head_local)
    ] <- 1L
    current_adjacency[
      cbind(head_local, tail_local)
    ] <- 1L
  }
  
  upper <- upper.tri(prior)
  prior_indicator <- prior > 0
  current_indicator <- current_adjacency > 0
  
  number_of_prior_dyads <- sum(
    upper & prior_indicator
  )
  number_of_prior_current_edges <- sum(
    upper & prior_indicator & current_indicator
  )
  number_of_prior_current_nonedges <- sum(
    upper & prior_indicator & !current_indicator
  )
  
  block_id <- sprintf(
    "block_%03d_session_%s",
    block_index,
    gsub("[^A-Za-z0-9_-]+", "_", session_name)
  )
  
  nodes$session <- session_name
  nodes$block_id <- block_id
  nodes$original_node_id <- node_ids
  nodes$vertex_id <- paste(
    block_id,
    node_ids,
    sep = "__"
  )
  
  vertex_lookup <- stats::setNames(
    nodes$vertex_id,
    nodes$original_node_id
  )
  
  edges$session <- session_name
  edges$block_id <- block_id
  edges$source_original <- edges$source
  edges$target_original <- edges$target
  edges$source <- unname(vertex_lookup[edges$source])
  edges$target <- unname(vertex_lookup[edges$target])
  
  rownames(prior) <- nodes$vertex_id
  colnames(prior) <- nodes$vertex_id
  
  possible_dyads <- nrow(nodes) * (nrow(nodes) - 1) / 2
  
  block_summary <- data.frame(
    block_id = block_id,
    session = session_name,
    raw_node_rows = raw_node_rows,
    raw_edge_rows = raw_edge_rows,
    raw_expertise_rows = raw_expertise_rows,
    raw_leadership_rows = raw_leadership_rows,
    candidate_node_ids = length(candidate_ids),
    complete_case_node_ids = length(complete_case_ids),
    number_of_nodes = nrow(nodes),
    number_of_edges = nrow(edges),
    possible_within_session_dyads = possible_dyads,
    density = nrow(edges) / possible_dyads,
    number_of_prior_dyads = number_of_prior_dyads,
    prior_current_edges = number_of_prior_current_edges,
    prior_current_nonedges = number_of_prior_current_nonedges,
    mean_expertise_raw = mean(nodes$expertise_raw),
    mean_log_expertise = mean(nodes$log_expertise),
    sd_log_expertise = stats::sd(nodes$log_expertise),
    mean_leadership_raw = mean(nodes$leadership_raw),
    mean_log_leadership = mean(nodes$log_leadership),
    sd_log_leadership = stats::sd(nodes$log_leadership),
    stringsAsFactors = FALSE
  )
  
  message(
    "[OK] Session ", session_name,
    ": ", nrow(nodes), " nodes, ",
    nrow(edges), " edges, ",
    number_of_prior_dyads, " prior dyads"
  )
  
  list(
    session = session_name,
    nodes = nodes,
    edges = edges,
    prior = prior,
    block_summary = block_summary
  )
}


# ----------------------------------------------------------------
# 4. Find all requested session folders
# ----------------------------------------------------------------

if (is.null(SESSION_IDS)) {
  all_subfolders <- list.dirs(
    ROOT_DIR,
    full.names = TRUE,
    recursive = FALSE
  )
  
  all_subfolders <- all_subfolders[
    !grepl("^\\.", basename(all_subfolders)) &
      basename(all_subfolders) != basename(OUTPUT_DIR) &
      basename(all_subfolders) !=
      "separate_session_ergm_results"
  ]
  
  session_folders <- all_subfolders[
    vapply(all_subfolders, has_required_files, logical(1))
  ]
} else {
  SESSION_IDS <- unique(as.character(SESSION_IDS))
  session_folders <- file.path(ROOT_DIR, SESSION_IDS)
  
  missing_folders <- SESSION_IDS[
    !dir.exists(session_folders)
  ]
  if (length(missing_folders) > 0L) {
    stop(
      paste0(
        "Requested session folder(s) do not exist: ",
        paste(missing_folders, collapse = ", ")
      ),
      call. = FALSE
    )
  }
  
  incomplete_folders <- SESSION_IDS[
    !vapply(session_folders, has_required_files, logical(1))
  ]
  if (length(incomplete_folders) > 0L) {
    stop(
      paste0(
        "Requested session folder(s) are missing one or more required files: ",
        paste(incomplete_folders, collapse = ", ")
      ),
      call. = FALSE
    )
  }
}

if (length(session_folders) == 0L) {
  stop(
    paste0(
      "No valid session folders were found under:\n",
      ROOT_DIR,
      "\nEach session folder must contain:\n- ",
      paste(required_file_names, collapse = "\n- ")
    ),
    call. = FALSE
  )
}

if (is.null(SESSION_IDS)) {
  session_folders <- session_folders[order(basename(session_folders))]
} else {
  # Keep block IDs in the user-specified session order.
  session_folders <- session_folders[
    match(SESSION_IDS, basename(session_folders))
  ]
}

message("\nSession folders found: ", length(session_folders))
message(paste(basename(session_folders), collapse = ", "))


# ----------------------------------------------------------------
# 5. Prepare every session block
# ----------------------------------------------------------------

raw_blocks <- Map(
  function(folder, block_index) {
    tryCatch(
      read_session_block(folder, block_index),
      error = function(e) {
        structure(
          list(
            session = basename(folder),
            folder = folder,
            error = conditionMessage(e)
          ),
          class = "failed_session_block"
        )
      }
    )
  },
  session_folders,
  seq_along(session_folders)
)

valid_blocks <- raw_blocks[
  !vapply(
    raw_blocks,
    inherits,
    logical(1),
    "failed_session_block"
  )
]
failed_blocks <- raw_blocks[
  vapply(
    raw_blocks,
    inherits,
    logical(1),
    "failed_session_block"
  )
]

failed_sessions <- if (length(failed_blocks) == 0L) {
  data.frame(
    session = character(),
    folder = character(),
    error = character(),
    stringsAsFactors = FALSE
  )
} else {
  do.call(
    rbind,
    lapply(failed_blocks, function(x) {
      data.frame(
        session = x$session,
        folder = x$folder,
        error = x$error,
        stringsAsFactors = FALSE
      )
    })
  )
}

if (nrow(failed_sessions) > 0L) {
  write.csv(
    failed_sessions,
    file.path(OUTPUT_DIR, "session_validation_failures.csv"),
    row.names = FALSE
  )
  
  message("\nSession validation failures:")
  for (i in seq_len(nrow(failed_sessions))) {
    message(
      "  [FAILED] Session ",
      failed_sessions$session[[i]],
      ": ",
      failed_sessions$error[[i]]
    )
  }
  
  if (STOP_IF_ANY_SESSION_FAILS) {
    stop(
      paste0(
        nrow(failed_sessions),
        " session(s) failed validation. ",
        "The block model was not fitted because ",
        "STOP_IF_ANY_SESSION_FAILS is TRUE."
      ),
      call. = FALSE
    )
  }
}

if (length(valid_blocks) == 0L) {
  stop(
    "All session blocks failed validation.",
    call. = FALSE
  )
}


# ----------------------------------------------------------------
# 6. Combine nodes, edges, and prior matrices
# ----------------------------------------------------------------

nodes_all <- do.call(
  rbind,
  lapply(valid_blocks, `[[`, "nodes")
)
edges_all <- do.call(
  rbind,
  lapply(valid_blocks, `[[`, "edges")
)
block_summary <- do.call(
  rbind,
  lapply(valid_blocks, `[[`, "block_summary")
)

rownames(nodes_all) <- NULL
rownames(edges_all) <- NULL
rownames(block_summary) <- NULL

if (anyDuplicated(nodes_all$vertex_id) > 0L) {
  stop(
    "Combined vertex_id values are not unique.",
    call. = FALSE
  )
}

total_nodes <- nrow(nodes_all)
prior_big <- matrix(
  0,
  nrow = total_nodes,
  ncol = total_nodes,
  dimnames = list(
    nodes_all$vertex_id,
    nodes_all$vertex_id
  )
)

for (block in valid_blocks) {
  ids <- block$nodes$vertex_id
  prior_big[ids, ids] <- block$prior[ids, ids]
}

mode(prior_big) <- "numeric"
prior_big[is.na(prior_big)] <- 0
diag(prior_big) <- 0

if (!isTRUE(all.equal(
  prior_big,
  t(prior_big),
  tolerance = 1e-12
))) {
  stop(
    "The combined prior matrix is not symmetric.",
    call. = FALSE
  )
}


# ----------------------------------------------------------------
# 7. Build the combined block-diagonal network
# ----------------------------------------------------------------

net_big <- network.initialize(
  n = total_nodes,
  directed = FALSE,
  loops = FALSE,
  multiple = FALSE
)

network.vertex.names(net_big) <- nodes_all$vertex_id

set.vertex.attribute(
  net_big,
  "session",
  nodes_all$session
)
set.vertex.attribute(
  net_big,
  "block_id",
  nodes_all$block_id
)
set.vertex.attribute(
  net_big,
  "expertise_model_z",
  nodes_all$expertise_model_z
)
set.vertex.attribute(
  net_big,
  "leadership_model_z",
  nodes_all$leadership_model_z
)

tail_index <- integer(0)
head_index <- integer(0)

if (nrow(edges_all) > 0L) {
  tail_index <- match(
    edges_all$source,
    nodes_all$vertex_id
  )
  head_index <- match(
    edges_all$target,
    nodes_all$vertex_id
  )
  
  if (anyNA(tail_index) || anyNA(head_index)) {
    stop(
      "Some combined edge endpoints do not match combined vertices.",
      call. = FALSE
    )
  }
  
  add.edges(
    net_big,
    tail = tail_index,
    head = head_index
  )
}

combined_degrees <- degree_from_edge_indices(
  tail_index,
  head_index,
  total_nodes
)

if (any(combined_degrees == 0L)) {
  stop(
    sprintf(
      "The combined network contains %d isolate(s).",
      sum(combined_degrees == 0L)
    ),
    call. = FALSE
  )
}

# This is the critical constraint. It removes all cross-session
# dyads from the ERGM risk set.
block_constraint <- ~ blockdiag("block_id")


# ----------------------------------------------------------------
# 8. Combined diagnostics
# ----------------------------------------------------------------

within_session_possible_dyads <- sum(
  block_summary$possible_within_session_dyads
)
observed_edges <- nrow(edges_all)
prior_dyads_total <- sum(block_summary$number_of_prior_dyads)
prior_current_edges_total <- sum(
  block_summary$prior_current_edges
)
prior_current_nonedges_total <- sum(
  block_summary$prior_current_nonedges
)

if (prior_dyads_total == 0L) {
  stop(
    paste0(
      "No prior=1 dyads exist in any included session; ",
      "the common prior effect cannot be estimated."
    ),
    call. = FALSE
  )
}

if (prior_current_edges_total == 0L ||
    prior_current_nonedges_total == 0L) {
  stop(
    paste0(
      "Across all included sessions, prior=1 perfectly predicts ",
      "the current tie outcome. The common prior effect is not ",
      "estimable. prior edges = ",
      prior_current_edges_total,
      "; prior nonedges = ",
      prior_current_nonedges_total,
      "."
    ),
    call. = FALSE
  )
}

combined_summary <- data.frame(
  analysis = "block_diagonal_sessions",
  script_version = SCRIPT_VERSION,
  number_of_sessions = nrow(block_summary),
  sessions_included = paste(
    block_summary$session,
    collapse = ", "
  ),
  number_of_nodes = total_nodes,
  number_of_edges = observed_edges,
  possible_within_session_dyads =
    within_session_possible_dyads,
  within_session_density =
    observed_edges / within_session_possible_dyads,
  number_of_prior_dyads = prior_dyads_total,
  prior_current_edges = prior_current_edges_total,
  prior_current_nonedges =
    prior_current_nonedges_total,
  attribute_transformation =
    "within-session z-score(log1p(raw value))",
  estimation_method = ESTIMATION_METHOD,
  gwesp_decay = GWESP_DECAY,
  cross_session_dyads =
    "excluded by blockdiag(block_id)",
  stringsAsFactors = FALSE
)

message(
  "\n================================================"
)
message("Combined block-diagonal network")
message(
  "================================================"
)
message("Sessions included: ", nrow(block_summary))
message(
  "Session IDs: ",
  paste(block_summary$session, collapse = ", ")
)
message("Total nodes: ", total_nodes)
message("Total edges: ", observed_edges)
message(
  "Possible within-session dyads: ",
  within_session_possible_dyads
)
message("Prior=1 dyads: ", prior_dyads_total)
message(
  "Prior=1 and current edge: ",
  prior_current_edges_total
)
message(
  "Prior=1 and current non-edge: ",
  prior_current_nonedges_total
)


# ----------------------------------------------------------------
# 9. Fit one block-diagonal M0--M5 sequence
# ----------------------------------------------------------------

message(
  "\nFitting one block-diagonal M0--M5 sequence by MLE..."
)

model_formulas <- list(
  m0_edges =
    net_big ~ edges,
  m1_prior =
    net_big ~
    edges +
    edgecov(prior_big),
  m2_prior_expertise =
    net_big ~
    edges +
    edgecov(prior_big) +
    nodecov("expertise_model_z"),
  m3_prior_expertise_similarity =
    net_big ~
    edges +
    edgecov(prior_big) +
    nodecov("expertise_model_z") +
    absdiff("expertise_model_z"),
  m4_full =
    net_big ~
    edges +
    edgecov(prior_big) +
    nodecov("expertise_model_z") +
    absdiff("expertise_model_z") +
    nodecov("leadership_model_z") +
    absdiff("leadership_model_z"),
  m5_full_gwesp =
    net_big ~
    edges +
    edgecov(prior_big) +
    nodecov("expertise_model_z") +
    absdiff("expertise_model_z") +
    nodecov("leadership_model_z") +
    absdiff("leadership_model_z") +
    gwesp(GWESP_DECAY, fixed = TRUE)
)

models <- list()

for (model_name in names(model_formulas)) {
  message("  Fitting ", model_name, " ...")
  
  models[[model_name]] <- fit_ergm_safe(
    model_formulas[[model_name]],
    ERGM_CONTROL,
    block_constraint
  )
  
  if (inherits(models[[model_name]], "ergm")) {
    message("  [OK] ", model_name)
  } else {
    message(
      "  [MODEL FAILED] ",
      model_name,
      ": ",
      conditionMessage(models[[model_name]])
    )
  }
}

coefficients_all <- bind_rows_base(
  lapply(names(models), function(model_name) {
    extract_coefficients(
      models[[model_name]],
      model_name
    )
  })
)

model_fit <- bind_rows_base(
  lapply(names(models), function(model_name) {
    extract_fit(
      models[[model_name]],
      model_name
    )
  })
)

failed_models <- model_fit[
  model_fit$status != "ok",
  ,
  drop = FALSE
]

not_estimable_terms <- coefficients_all[
  coefficients_all$status == "not_estimable",
  ,
  drop = FALSE
]

coefficients_m4 <- coefficients_all[
  coefficients_all$model == "m4_full",
  ,
  drop = FALSE
]

coefficients_m5 <- coefficients_all[
  coefficients_all$model == "m5_full_gwesp",
  ,
  drop = FALSE
]

model_specifications <- data.frame(
  model = names(model_formulas),
  terms = c(
    "edges",
    "edges + prior",
    "edges + prior + expertise",
    paste0(
      "edges + prior + expertise + ",
      "absolute expertise difference"
    ),
    paste0(
      "edges + prior + expertise + ",
      "absolute expertise difference + leadership + ",
      "absolute leadership difference"
    ),
    paste0(
      "edges + prior + expertise + ",
      "absolute expertise difference + leadership + ",
      "absolute leadership difference + fixed GWESP (decay = ",
      GWESP_DECAY,
      ")"
    )
  ),
  stringsAsFactors = FALSE
)


# ----------------------------------------------------------------
# 10. Save reproducibility files
# ----------------------------------------------------------------

nodes_to_save <- nodes_all[
  ,
  c(
    "vertex_id",
    "session",
    "block_id",
    "original_node_id",
    "expertise_raw",
    "log_expertise",
    "expertise_model_z",
    "leadership_raw",
    "log_leadership",
    "leadership_model_z"
  ),
  drop = FALSE
]

edges_to_save <- edges_all[
  ,
  c(
    "session",
    "block_id",
    "source",
    "target",
    "source_original",
    "target_original"
  ),
  drop = FALSE
]

write.csv(
  nodes_to_save,
  file.path(OUTPUT_DIR, "combined_nodes_used.csv"),
  row.names = FALSE
)
write.csv(
  edges_to_save,
  file.path(OUTPUT_DIR, "combined_edges_used.csv"),
  row.names = FALSE
)
write.csv(
  block_summary,
  file.path(OUTPUT_DIR, "block_summary.csv"),
  row.names = FALSE
)

if (SAVE_COMBINED_PRIOR_MATRIX) {
  write.csv(
    prior_big,
    file.path(OUTPUT_DIR, "combined_prior_matrix.csv"),
    row.names = TRUE
  )
}

output_lines <- capture.output({
  cat("MyDreamTeam block-diagonal ERGM\n")
  cat("Script version:", SCRIPT_VERSION, "\n")
  cat("Estimation method:", ESTIMATION_METHOD, "\n")
  cat("M5 GWESP decay (fixed):", GWESP_DECAY, "\n")
  cat(
    "Transformation: z-score(log1p(raw value)) ",
    "within session\n",
    sep = ""
  )
  cat("Constraint: blockdiag(block_id)\n")
  cat(
    "Sessions included:",
    paste(block_summary$session, collapse = ", "),
    "\n"
  )
  cat("Nodes:", total_nodes, "\n")
  cat("Edges:", observed_edges, "\n")
  cat(
    "Possible within-session dyads:",
    within_session_possible_dyads,
    "\n"
  )
  cat("Prior=1 dyads:", prior_dyads_total, "\n")
  cat(
    "Prior=1 and current edge:",
    prior_current_edges_total,
    "\n"
  )
  cat(
    "Prior=1 and current non-edge:",
    prior_current_nonedges_total,
    "\n\n"
  )
  
  cat("Included blocks:\n")
  print(block_summary)
  
  if (nrow(failed_sessions) > 0L) {
    cat("\nSessions excluded after validation failure:\n")
    print(failed_sessions)
  }
  
  for (model_name in names(models)) {
    cat(
      "\n---------------- ",
      model_name,
      " ----------------\n",
      sep = ""
    )
    
    if (inherits(models[[model_name]], "ergm")) {
      print(extract_coefficients(
        models[[model_name]],
        model_name
      ))
      
      cat(
        "AIC:",
        tryCatch(
          AIC(models[[model_name]]),
          error = function(e) NA_real_
        ),
        "\n"
      )
      cat(
        "BIC:",
        tryCatch(
          BIC(models[[model_name]]),
          error = function(e) NA_real_
        ),
        "\n"
      )
    } else {
      cat(
        "FAILED:",
        conditionMessage(models[[model_name]]),
        "\n"
      )
    }
  }
})

writeLines(
  output_lines,
  TXT_FILE,
  useBytes = TRUE
)


# ----------------------------------------------------------------
# 11. Save Excel workbook
# ----------------------------------------------------------------

workbook <- createWorkbook()

write_sheet <- function(name, data) {
  addWorksheet(
    workbook,
    name,
    gridLines = FALSE
  )
  writeData(
    workbook,
    name,
    data,
    withFilter = nrow(data) > 0L
  )
  freezePane(
    workbook,
    name,
    firstRow = TRUE
  )
  
  if (ncol(data) > 0L) {
    setColWidths(
      workbook,
      name,
      cols = seq_len(ncol(data)),
      widths = "auto"
    )
  }
}

write_sheet("coefficients_M5", coefficients_m5)
write_sheet("coefficients_M4", coefficients_m4)
write_sheet(
  "coefficients_all_models",
  coefficients_all
)
write_sheet("model_fit", model_fit)
write_sheet("model_specifications", model_specifications)
write_sheet("combined_summary", combined_summary)
write_sheet("block_summary", block_summary)
write_sheet("transformed_nodes", nodes_to_save)
write_sheet("failed_models", failed_models)
write_sheet("not_estimable_terms", not_estimable_terms)
write_sheet("failed_sessions", failed_sessions)

saveWorkbook(
  workbook,
  OUTPUT_FILE,
  overwrite = TRUE
)

message(
  "\nBlock-diagonal session ERGM analysis completed."
)
message(
  "Sessions included: ",
  paste(block_summary$session, collapse = ", ")
)
message(
  "Sessions excluded: ",
  nrow(failed_sessions)
)
message(
  "[SAVED] ",
  normalizePath(OUTPUT_FILE, mustWork = FALSE)
)
