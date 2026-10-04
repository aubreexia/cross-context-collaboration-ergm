# ============================================================================
# GitHub/GHTorrent: block-diagonal ERGM across all language folders in FullProject
#
# Put this script directly in FullProject and run:
#   Rscript run_all_language_block_ergm_gwesp.R
#
# Optional: pass FullProject explicitly:
#   Rscript run_all_language_block_ergm_gwesp.R /path/to/FullProject
#
# The script searches each immediate language folder recursively for exactly
# one directory containing this processed ERGM file triplet:
#   *_nodes.csv
#   *_edges.csv            (but not *_prior_edges.csv)
#   *_prior_mat.csv
# The triplet may be inside processed_for_ergm_prior_before_* or may have been
# copied directly into the language folder when downloaded from CRC.
#
# It combines the language networks into one network and excludes all
# cross-language dyads with constraints = ~ blockdiag("block_id").
#
# Models:
#   M0: edges
#   M1: edges + prior collaboration
#   M2: M1 + expertise
#   M3: M2 + absolute expertise difference
#   M4: M3 + leadership + absolute leadership difference
#   M5: M4 + GWESP (fixed decay = 0.25)
#
# Output folder:
#   FullProject/block_diagonal_language_ergm_results/
# ============================================================================

SCRIPT_VERSION <- "GitHub/GHTorrent language block-diagonal ERGM 2026-08-15 v3 (GWESP)"
message("Running: ", SCRIPT_VERSION)


# ----------------------------------------------------------------------------
# 0. User settings
# ----------------------------------------------------------------------------

get_script_directory <- function() {
  file_argument <- grep(
    "^--file=",
    commandArgs(trailingOnly = FALSE),
    value = TRUE
  )

  if (length(file_argument) == 0L) {
    return(getwd())
  }

  script_path <- sub("^--file=", "", file_argument[[1L]])
  dirname(normalizePath(script_path, mustWork = TRUE))
}

user_arguments <- commandArgs(trailingOnly = TRUE)

if (length(user_arguments) > 1L) {
  stop(
    paste0(
      "Use at most one argument: the path to FullProject.\n",
      "Example: Rscript run_all_language_block_ergm.R /path/to/FullProject"
    ),
    call. = FALSE
  )
}

ROOT_DIR <- if (length(user_arguments) == 1L) {
  normalizePath(user_arguments[[1L]], mustWork = TRUE)
} else {
  get_script_directory()
}

# NULL means: use every immediate subfolder except the excluded folders below.
# To use only selected languages, enter their folder names, for example:
# LANGUAGE_FOLDERS <- c("Python", "JavaScript", "TypeScript")
LANGUAGE_FOLDERS <- NULL

EXCLUDED_TOP_LEVEL_FOLDERS <- c(
  "logs",
  "separate_results",
  "separate_results_gwesp",
  "separate_results_gwesp_mle",
  "separate_results_m6",
  "separate_session_ergm_results",
  "block_diagonal_language_ergm_results",
  "block_diagonal_session_ergm_results"
)

# TRUE prevents fitting a different model after silently omitting a language.
STOP_IF_ANY_LANGUAGE_FAILS <- TRUE

BINARIZE_PRIOR <- TRUE
SAVE_COMBINED_PRIOR_MATRIX <- FALSE
SAVE_MODEL_OBJECTS <- TRUE

# Model local transitivity with geometrically weighted edgewise shared partners.
# A fixed decay keeps M5 directly comparable across reruns and language sets.
GWESP_DECAY <- 0.25

# The combined edgecov matrix is dense. Raise this only if the compute node has
# enough RAM. At 12,000 nodes, the integer matrix alone is about 576 MB.
MAX_COMBINED_NODES <- 12000L

SEED <- 20260802L

OUTPUT_DIR <- file.path(
  ROOT_DIR,
  "block_diagonal_language_ergm_results"
)
OUTPUT_FILE <- file.path(
  OUTPUT_DIR,
  "block_diagonal_language_ergm_results.xlsx"
)
TXT_FILE <- file.path(
  OUTPUT_DIR,
  "block_diagonal_language_ergm_output.txt"
)


# ----------------------------------------------------------------------------
# 1. Required packages and ERGM control
# ----------------------------------------------------------------------------

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

suppressPackageStartupMessages({
  library(network)
  library(ergm)
  library(openxlsx)
})

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

ERGM_CONTROL <- control.ergm(
  seed = SEED,
  MCMLE.maxit = 20,
  MCMC.burnin = 100000,
  MCMC.interval = 4096
)


# ----------------------------------------------------------------------------
# 2. Helper functions
# ----------------------------------------------------------------------------

clean_id <- function(x) {
  y <- trimws(as.character(x))
  invalid <- is.na(y) | y %in% c(
    "", "NA", "NaN", "nan", "<NA>", "NULL", "null", "None"
  )
  y[invalid] <- NA_character_
  y
}

safe_name <- function(x) {
  y <- gsub("[^A-Za-z0-9_-]+", "_", as.character(x))
  y <- gsub("_+", "_", y)
  y <- gsub("^_|_$", "", y)
  if (nchar(y) == 0L) "language" else y
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

pick_column <- function(data, candidates, object_name) {
  available <- candidates[candidates %in% names(data)]
  if (length(available) == 0L) {
    stop(
      sprintf(
        "%s must contain one of these columns: %s",
        object_name,
        paste(candidates, collapse = ", ")
      ),
      call. = FALSE
    )
  }
  available[[1L]]
}

single_file <- function(folder, pattern, object_name, exclude_pattern = NULL) {
  files <- list.files(folder, full.names = TRUE, recursive = FALSE)
  files <- files[
    grepl(pattern, basename(files), ignore.case = TRUE)
  ]

  if (!is.null(exclude_pattern)) {
    files <- files[
      !grepl(exclude_pattern, basename(files), ignore.case = TRUE)
    ]
  }

  if (length(files) != 1L) {
    stop(
      sprintf(
        "%s: expected exactly one %s file, found %d.",
        folder,
        object_name,
        length(files)
      ),
      call. = FALSE
    )
  }

  files[[1L]]
}

# Also accept a Finder-style suffix such as "_nodes (1).csv" when it is the
# only copy in the directory.
NODE_FILE_PATTERN <- "_nodes( \\([0-9]+\\))?\\.csv$"
EDGE_FILE_PATTERN <- "_edges( \\([0-9]+\\))?\\.csv$"
PRIOR_FILE_PATTERN <- "_prior_mat( \\([0-9]+\\))?\\.csv$"
PRIOR_EDGE_FILE_PATTERN <- "_prior_edges( \\([0-9]+\\))?\\.csv$"

processed_file_triplet <- function(folder) {
  files <- list.files(folder, full.names = TRUE, recursive = FALSE)
  file_names <- basename(files)

  node_files <- files[
    grepl(NODE_FILE_PATTERN, file_names, ignore.case = TRUE)
  ]
  edge_files <- files[
    grepl(EDGE_FILE_PATTERN, file_names, ignore.case = TRUE)
  ]
  edge_files <- edge_files[
    !grepl(
      PRIOR_EDGE_FILE_PATTERN,
      basename(edge_files),
      ignore.case = TRUE
    )
  ]
  prior_files <- files[
    grepl(PRIOR_FILE_PATTERN, file_names, ignore.case = TRUE)
  ]

  list(
    node_files = node_files,
    edge_files = edge_files,
    prior_files = prior_files,
    valid = length(node_files) == 1L &&
      length(edge_files) == 1L &&
      length(prior_files) == 1L
  )
}

has_processed_files <- function(folder) {
  isTRUE(processed_file_triplet(folder)$valid)
}

degree_from_edge_indices <- function(tail_index, head_index, n_nodes) {
  tabulate(
    c(as.integer(tail_index), as.integer(head_index)),
    nbins = n_nodes
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

  if (anyNA(rownames(prior)) || anyNA(colnames(prior))) {
    stop("The prior matrix contains a missing row or column ID.", call. = FALSE)
  }
  if (anyDuplicated(rownames(prior)) > 0L ||
      anyDuplicated(colnames(prior)) > 0L) {
    stop("The prior matrix contains duplicated IDs.", call. = FALSE)
  }
  if (nrow(prior) != ncol(prior)) {
    stop("The prior matrix is not square.", call. = FALSE)
  }
  if (!setequal(rownames(prior), colnames(prior))) {
    stop("The prior row and column ID sets differ.", call. = FALSE)
  }

  prior <- prior[rownames(prior), rownames(prior), drop = FALSE]

  if (anyNA(prior) || any(!is.finite(prior))) {
    stop("The prior matrix has missing or non-finite values.", call. = FALSE)
  }
  if (any(prior < 0)) {
    stop("The prior matrix contains negative values.", call. = FALSE)
  }
  if (!isTRUE(all.equal(prior, t(prior), tolerance = 1e-12))) {
    stop("The prior matrix is not symmetric.", call. = FALSE)
  }

  if (binarize) {
    prior <- 1L * (prior > 0)
  }
  diag(prior) <- 0
  prior
}

fit_ergm_safe <- function(formula, constraint, control) {
  tryCatch(
    ergm(
      formula,
      constraints = constraint,
      control = control
    ),
    error = function(e) e
  )
}

extract_coefficients <- function(fit, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      analysis = "block_diagonal_languages",
      model = model_name,
      term = NA_character_,
      Estimate = NA_real_,
      Std_Error = NA_real_,
      z_value = NA_real_,
      p_value = NA_real_,
      status = "failed",
      error = conditionMessage(fit),
      stringsAsFactors = FALSE
    ))
  }

  # Avoid summary.ergm(), which can call obsolete network functions in some
  # mismatched ergm/network installations.
  estimate <- stats::coef(fit)
  variance <- tryCatch(stats::vcov(fit), error = function(e) NULL)
  term_names <- names(estimate)
  if (is.null(term_names)) {
    term_names <- paste0("term_", seq_along(estimate))
  }

  if (is.null(variance) ||
      nrow(variance) != length(estimate) ||
      ncol(variance) != length(estimate)) {
    std_error <- rep(NA_real_, length(estimate))
  } else {
    variance_diagonal <- diag(variance)
    variance_diagonal[
      !is.finite(variance_diagonal) | variance_diagonal < 0
    ] <- NA_real_
    std_error <- sqrt(variance_diagonal)
  }

  z_value <- estimate / std_error
  p_value <- 2 * stats::pnorm(abs(z_value), lower.tail = FALSE)
  estimable <- is.finite(estimate) &
    is.finite(std_error) &
    std_error > 0 &
    is.finite(z_value) &
    is.finite(p_value)

  estimate[!is.finite(estimate)] <- NA_real_
  std_error[!is.finite(std_error)] <- NA_real_
  z_value[!is.finite(z_value)] <- NA_real_
  p_value[!is.finite(p_value)] <- NA_real_

  data.frame(
    analysis = "block_diagonal_languages",
    model = model_name,
    term = term_names,
    Estimate = as.numeric(estimate),
    Std_Error = as.numeric(std_error),
    z_value = as.numeric(z_value),
    p_value = as.numeric(p_value),
    status = ifelse(estimable, "ok", "not_estimable"),
    error = ifelse(
      estimable,
      NA_character_,
      "Coefficient or standard error is non-finite."
    ),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

extract_model_fit <- function(fit, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      analysis = "block_diagonal_languages",
      model = model_name,
      AIC = NA_real_,
      BIC = NA_real_,
      status = "failed",
      error = conditionMessage(fit),
      stringsAsFactors = FALSE
    ))
  }

  aic_value <- tryCatch(AIC(fit), error = function(e) NA_real_)
  bic_value <- tryCatch(BIC(fit), error = function(e) NA_real_)

  data.frame(
    analysis = "block_diagonal_languages",
    model = model_name,
    AIC = if (is.finite(aic_value)) aic_value else NA_real_,
    BIC = if (is.finite(bic_value)) bic_value else NA_real_,
    status = "ok",
    error = NA_character_,
    stringsAsFactors = FALSE
  )
}

bind_rows_base <- function(items) {
  items <- items[vapply(items, function(x) nrow(x) > 0L, logical(1))]
  if (length(items) == 0L) return(data.frame())
  do.call(rbind, items)
}


# ----------------------------------------------------------------------------
# 3. Discover one processed ERGM file triplet per language folder
# ----------------------------------------------------------------------------

if (is.null(LANGUAGE_FOLDERS)) {
  language_roots <- list.dirs(
    ROOT_DIR,
    full.names = TRUE,
    recursive = FALSE
  )
  language_roots <- language_roots[
    !grepl("^\\.", basename(language_roots)) &
      !basename(language_roots) %in% EXCLUDED_TOP_LEVEL_FOLDERS
  ]
} else {
  language_roots <- file.path(ROOT_DIR, unique(as.character(LANGUAGE_FOLDERS)))
  missing_roots <- language_roots[!dir.exists(language_roots)]
  if (length(missing_roots) > 0L) {
    stop(
      paste0(
        "Requested language folder(s) do not exist:\n- ",
        paste(missing_roots, collapse = "\n- ")
      ),
      call. = FALSE
    )
  }
}

language_roots <- language_roots[order(basename(language_roots))]

if (length(language_roots) == 0L) {
  stop("No language folders were found under ROOT_DIR.", call. = FALSE)
}

discovery <- lapply(language_roots, function(language_root) {
  # Search the language root itself as well as every nested directory. This is
  # intentionally independent of directory names because scp/Finder downloads
  # commonly flatten the original CRC directory tree.
  possible <- unique(c(
    language_root,
    list.dirs(language_root, recursive = TRUE, full.names = TRUE)
  ))
  valid_all <- possible[vapply(possible, has_processed_files, logical(1))]

  # If exactly one candidate lies within a canonical processed_for_ergm path,
  # prefer it over unrelated CSV folders. Otherwise accept exactly one valid
  # triplet anywhere below the language root, including the language root itself.
  canonical <- valid_all[
    grepl(
      "processed_for_ergm_prior_before_",
      valid_all,
      fixed = TRUE
    )
  ]
  valid <- if (length(canonical) > 0L) canonical else valid_all

  csv_files <- list.files(
    language_root,
    pattern = "\\.csv$",
    full.names = TRUE,
    recursive = TRUE,
    ignore.case = TRUE
  )
  named_processed_dirs <- possible[
    grepl("^processed_for_ergm_prior_before_", basename(possible))
  ]

  if (length(valid) == 1L) {
    source_layout <- if (normalizePath(
      valid[[1L]],
      mustWork = TRUE
    ) == normalizePath(language_root, mustWork = TRUE)) {
      "files_directly_in_language_folder"
    } else if (grepl(
      "processed_for_ergm_prior_before_",
      valid[[1L]],
      fixed = TRUE
    )) {
      "canonical_processed_directory"
    } else {
      "nested_directory_with_file_triplet"
    }

    data.frame(
      language_folder = basename(language_root),
      language_root = language_root,
      processed_dir = valid[[1L]],
      source_layout = source_layout,
      number_of_candidates = length(valid),
      number_of_all_valid_triplets = length(valid_all),
      number_of_named_processed_dirs = length(named_processed_dirs),
      number_of_csv_files_found = length(csv_files),
      candidate_directories = paste(valid_all, collapse = " | "),
      status = "ok",
      error = NA_character_,
      stringsAsFactors = FALSE
    )
  } else {
    detail <- if (length(valid_all) == 0L) {
      sample_files <- if (length(csv_files) == 0L) {
        "No CSV files were found below the language folder."
      } else {
        paste0(
          "CSV files found (first 12): ",
          paste(head(csv_files, 12L), collapse = " | ")
        )
      }
      paste0(
        "No directory containing exactly one *_nodes.csv, one current ",
        "*_edges.csv, and one *_prior_mat.csv was found. ",
        sample_files
      )
    } else {
      paste0(
        "Multiple valid processed file triplets were found. Keep only the ",
        "intended year/k result inside this language folder. Candidates: ",
        paste(valid, collapse = " | ")
      )
    }

    data.frame(
      language_folder = basename(language_root),
      language_root = language_root,
      processed_dir = NA_character_,
      source_layout = NA_character_,
      number_of_candidates = length(valid),
      number_of_all_valid_triplets = length(valid_all),
      number_of_named_processed_dirs = length(named_processed_dirs),
      number_of_csv_files_found = length(csv_files),
      candidate_directories = paste(valid_all, collapse = " | "),
      status = "failed",
      error = detail,
      stringsAsFactors = FALSE
    )
  }
})

discovery_table <- do.call(rbind, discovery)
rownames(discovery_table) <- NULL

discovery_failures <- discovery_table[
  discovery_table$status != "ok",
  ,
  drop = FALSE
]

write.csv(
  discovery_table,
  file.path(OUTPUT_DIR, "language_discovery.csv"),
  row.names = FALSE
)

if (nrow(discovery_failures) > 0L) {
  message("\nLanguage discovery failures:")
  for (i in seq_len(nrow(discovery_failures))) {
    message(
      "  [FAILED] ",
      discovery_failures$language_folder[[i]],
      ": ",
      discovery_failures$error[[i]]
    )
  }

  if (STOP_IF_ANY_LANGUAGE_FAILS) {
    stop(
      paste0(
        nrow(discovery_failures),
        " language folder(s) failed discovery. See ",
        file.path(OUTPUT_DIR, "language_discovery.csv")
      ),
      call. = FALSE
    )
  }
}

valid_discovery <- discovery_table[
  discovery_table$status == "ok",
  ,
  drop = FALSE
]

if (nrow(valid_discovery) == 0L) {
  stop("No valid language result directories remain.", call. = FALSE)
}

message("\nLanguage folders found: ", nrow(valid_discovery))
message(paste(valid_discovery$language_folder, collapse = ", "))


# ----------------------------------------------------------------------------
# 4. Read and validate one language block
# ----------------------------------------------------------------------------

read_language_block <- function(language_folder, processed_dir, block_index) {
  message("\n============================================================")
  message("Preparing language block: ", language_folder)
  message("Source: ", processed_dir)
  message("============================================================")

  node_file <- single_file(
    processed_dir,
    NODE_FILE_PATTERN,
    "nodes"
  )
  edge_file <- single_file(
    processed_dir,
    EDGE_FILE_PATTERN,
    "current edges",
    exclude_pattern = PRIOR_EDGE_FILE_PATTERN
  )
  prior_file <- single_file(
    processed_dir,
    PRIOR_FILE_PATTERN,
    "prior matrix"
  )

  nodes_raw <- read.csv(
    node_file,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    colClasses = "character"
  )
  edges_raw <- read.csv(
    edge_file,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    colClasses = "character"
  )

  assert_columns(nodes_raw, c("global_id"), "nodes")
  assert_columns(edges_raw, c("u", "v"), "edges")

  expertise_column <- pick_column(
    nodes_raw,
    c("expertise_z_shared", "expertise_z"),
    "nodes"
  )
  leadership_column <- pick_column(
    nodes_raw,
    c("leadership_z_shared", "leadership_z"),
    "nodes"
  )

  nodes <- data.frame(
    global_id = clean_id(nodes_raw$global_id),
    dataset = rep(language_folder, nrow(nodes_raw)),
    expertise_model_z = suppressWarnings(
      as.numeric(nodes_raw[[expertise_column]])
    ),
    leadership_model_z = suppressWarnings(
      as.numeric(nodes_raw[[leadership_column]])
    ),
    stringsAsFactors = FALSE
  )

  if ("user_id" %in% names(nodes_raw)) {
    nodes$UserID <- clean_id(nodes_raw$user_id)
  } else {
    nodes$UserID <- NA_character_
  }

  if (nrow(nodes) < 2L) {
    stop("The language has fewer than two nodes.", call. = FALSE)
  }
  if (anyNA(nodes$global_id)) {
    stop("The node file contains a missing global_id.", call. = FALSE)
  }
  if (anyDuplicated(nodes$global_id) > 0L) {
    stop("The node file contains duplicated global_id values.", call. = FALSE)
  }
  if (anyNA(nodes$expertise_model_z) ||
      any(!is.finite(nodes$expertise_model_z))) {
    stop("Expertise contains missing or non-finite values.", call. = FALSE)
  }
  if (anyNA(nodes$leadership_model_z) ||
      any(!is.finite(nodes$leadership_model_z))) {
    stop("Leadership contains missing or non-finite values.", call. = FALSE)
  }

  edges <- data.frame(
    u = clean_id(edges_raw$u),
    v = clean_id(edges_raw$v),
    stringsAsFactors = FALSE
  )

  if (anyNA(edges$u) || anyNA(edges$v)) {
    stop("The edge file contains a missing endpoint.", call. = FALSE)
  }
  if (any(edges$u == edges$v)) {
    stop("The edge file contains self-loops.", call. = FALSE)
  }

  missing_edge_ids <- setdiff(
    unique(c(edges$u, edges$v)),
    nodes$global_id
  )
  if (length(missing_edge_ids) > 0L) {
    stop(
      paste0(
        "Edge endpoints are missing from the node file: ",
        paste(head(missing_edge_ids, 10L), collapse = ", ")
      ),
      call. = FALSE
    )
  }

  if (nrow(edges) > 0L) {
    endpoint_1 <- pmin(edges$u, edges$v)
    endpoint_2 <- pmax(edges$u, edges$v)
    edges$u <- endpoint_1
    edges$v <- endpoint_2
    edges <- edges[
      !duplicated(paste(edges$u, edges$v, sep = "\r")),
      ,
      drop = FALSE
    ]
  }

  if (nrow(edges) == 0L) {
    stop("No valid observed edges remain after cleaning.", call. = FALSE)
  }

  # Match the language-level separate analysis: remove current-network
  # isolates within each language, then subset its prior matrix accordingly.
  input_number_of_nodes <- nrow(nodes)
  observed_node_ids <- unique(c(edges$u, edges$v))
  removed_isolate_ids <- nodes$global_id[
    !nodes$global_id %in% observed_node_ids
  ]
  if (length(removed_isolate_ids) > 0L) {
    message(
      "Removing ", length(removed_isolate_ids),
      " current-network isolate(s) from ", language_folder, "."
    )
  }
  nodes <- nodes[nodes$global_id %in% observed_node_ids, , drop = FALSE]
  if (nrow(nodes) < 2L) {
    stop("Fewer than two non-isolate nodes remain.", call. = FALSE)
  }

  tail_local <- match(edges$u, nodes$global_id)
  head_local <- match(edges$v, nodes$global_id)
  degrees <- degree_from_edge_indices(tail_local, head_local, nrow(nodes))
  if (any(degrees == 0L)) {
    stop("Isolates remain after current-network filtering.", call. = FALSE)
  }

  prior <- read_prior_matrix(prior_file, binarize = BINARIZE_PRIOR)
  missing_prior_ids <- setdiff(nodes$global_id, rownames(prior))
  if (length(missing_prior_ids) > 0L) {
    stop(
      paste0(
        "The prior matrix is missing node IDs: ",
        paste(head(missing_prior_ids, 10L), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  prior <- prior[nodes$global_id, nodes$global_id, drop = FALSE]

  current_adjacency <- matrix(
    0L,
    nrow = nrow(nodes),
    ncol = nrow(nodes)
  )
  if (nrow(edges) > 0L) {
    current_adjacency[cbind(tail_local, head_local)] <- 1L
    current_adjacency[cbind(head_local, tail_local)] <- 1L
  }

  upper <- upper.tri(prior)
  prior_indicator <- prior > 0
  current_indicator <- current_adjacency > 0
  number_of_prior_dyads <- sum(upper & prior_indicator)
  prior_current_edges <- sum(upper & prior_indicator & current_indicator)
  prior_current_nonedges <- sum(upper & prior_indicator & !current_indicator)

  block_id <- sprintf(
    "block_%03d_%s",
    block_index,
    safe_name(language_folder)
  )

  nodes$language_folder <- language_folder
  nodes$language_dataset <- unique(nodes$dataset)
  nodes$block_id <- block_id
  nodes$original_global_id <- nodes$global_id
  nodes$vertex_id <- paste(block_id, nodes$global_id, sep = "__")

  lookup <- stats::setNames(nodes$vertex_id, nodes$original_global_id)
  edges$language_folder <- language_folder
  edges$language_dataset <- unique(nodes$dataset)
  edges$block_id <- block_id
  edges$u_original <- edges$u
  edges$v_original <- edges$v
  edges$u <- unname(lookup[edges$u])
  edges$v <- unname(lookup[edges$v])

  rownames(prior) <- nodes$vertex_id
  colnames(prior) <- nodes$vertex_id

  possible_dyads <- nrow(nodes) * (nrow(nodes) - 1) / 2
  block_summary <- data.frame(
    block_id = block_id,
    language_folder = language_folder,
    language_dataset = unique(nodes$dataset),
    processed_dir = processed_dir,
    node_file = basename(node_file),
    edge_file = basename(edge_file),
    prior_file = basename(prior_file),
    expertise_column_used = expertise_column,
    leadership_column_used = leadership_column,
    input_number_of_nodes = input_number_of_nodes,
    isolates_removed = length(removed_isolate_ids),
    number_of_nodes = nrow(nodes),
    number_of_edges = nrow(edges),
    possible_within_language_dyads = possible_dyads,
    density = nrow(edges) / possible_dyads,
    number_of_prior_dyads = number_of_prior_dyads,
    prior_current_edges = prior_current_edges,
    prior_current_nonedges = prior_current_nonedges,
    mean_expertise_z = mean(nodes$expertise_model_z),
    sd_expertise_z = stats::sd(nodes$expertise_model_z),
    mean_leadership_z = mean(nodes$leadership_model_z),
    sd_leadership_z = stats::sd(nodes$leadership_model_z),
    stringsAsFactors = FALSE
  )

  message(
    "[OK] ", language_folder,
    ": ", nrow(nodes), " nodes, ",
    nrow(edges), " edges, ",
    number_of_prior_dyads, " prior dyads"
  )

  list(
    language_folder = language_folder,
    nodes = nodes,
    edges = edges,
    prior = prior,
    block_summary = block_summary
  )
}


# ----------------------------------------------------------------------------
# 5. Prepare all language blocks
# ----------------------------------------------------------------------------

raw_blocks <- Map(
  function(language_folder, processed_dir, block_index) {
    tryCatch(
      read_language_block(language_folder, processed_dir, block_index),
      error = function(e) {
        structure(
          list(
            language_folder = language_folder,
            processed_dir = processed_dir,
            error = conditionMessage(e)
          ),
          class = "failed_language_block"
        )
      }
    )
  },
  valid_discovery$language_folder,
  valid_discovery$processed_dir,
  seq_len(nrow(valid_discovery))
)

is_failed_block <- vapply(
  raw_blocks,
  inherits,
  logical(1),
  "failed_language_block"
)
valid_blocks <- raw_blocks[!is_failed_block]
failed_blocks <- raw_blocks[is_failed_block]

failed_languages <- if (length(failed_blocks) == 0L) {
  data.frame(
    language_folder = character(),
    processed_dir = character(),
    error = character(),
    stringsAsFactors = FALSE
  )
} else {
  do.call(rbind, lapply(failed_blocks, function(x) {
    data.frame(
      language_folder = x$language_folder,
      processed_dir = x$processed_dir,
      error = x$error,
      stringsAsFactors = FALSE
    )
  }))
}

if (nrow(failed_languages) > 0L) {
  write.csv(
    failed_languages,
    file.path(OUTPUT_DIR, "language_validation_failures.csv"),
    row.names = FALSE
  )
  message("\nLanguage validation failures:")
  for (i in seq_len(nrow(failed_languages))) {
    message(
      "  [FAILED] ", failed_languages$language_folder[[i]],
      ": ", failed_languages$error[[i]]
    )
  }

  if (STOP_IF_ANY_LANGUAGE_FAILS) {
    stop(
      paste0(
        nrow(failed_languages),
        " language(s) failed validation. The block model was not fitted."
      ),
      call. = FALSE
    )
  }
}

if (length(valid_blocks) == 0L) {
  stop("All language blocks failed validation.", call. = FALSE)
}


# ----------------------------------------------------------------------------
# 6. Combine nodes, edges, and block-diagonal prior matrices
# ----------------------------------------------------------------------------

nodes_all <- do.call(rbind, lapply(valid_blocks, `[[`, "nodes"))
edges_all <- do.call(rbind, lapply(valid_blocks, `[[`, "edges"))
block_summary <- do.call(rbind, lapply(valid_blocks, `[[`, "block_summary"))
rownames(nodes_all) <- NULL
rownames(edges_all) <- NULL
rownames(block_summary) <- NULL

if (anyDuplicated(nodes_all$vertex_id) > 0L) {
  stop("Combined vertex_id values are not unique.", call. = FALSE)
}

total_nodes <- nrow(nodes_all)
if (total_nodes > MAX_COMBINED_NODES) {
  stop(
    paste0(
      "The combined network has ", total_nodes,
      " nodes, exceeding MAX_COMBINED_NODES = ", MAX_COMBINED_NODES,
      ". Increase the limit only after confirming sufficient RAM."
    ),
    call. = FALSE
  )
}

prior_big <- matrix(
  0L,
  nrow = total_nodes,
  ncol = total_nodes,
  dimnames = list(nodes_all$vertex_id, nodes_all$vertex_id)
)

for (block in valid_blocks) {
  ids <- block$nodes$vertex_id
  prior_big[ids, ids] <- block$prior[ids, ids]
}
diag(prior_big) <- 0L

if (!isTRUE(all.equal(prior_big, t(prior_big), tolerance = 1e-12))) {
  stop("The combined prior matrix is not symmetric.", call. = FALSE)
}


# ----------------------------------------------------------------------------
# 7. Build the combined network and block constraint
# ----------------------------------------------------------------------------

net_big <- network.initialize(
  n = total_nodes,
  directed = FALSE,
  loops = FALSE,
  multiple = FALSE
)
network.vertex.names(net_big) <- nodes_all$vertex_id

set.vertex.attribute(net_big, "language", nodes_all$language_folder)
set.vertex.attribute(net_big, "block_id", nodes_all$block_id)
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

tail_index <- match(edges_all$u, nodes_all$vertex_id)
head_index <- match(edges_all$v, nodes_all$vertex_id)

if (anyNA(tail_index) || anyNA(head_index)) {
  stop("Some combined edge endpoints do not match vertices.", call. = FALSE)
}
if (length(tail_index) > 0L) {
  add.edges(net_big, tail = tail_index, head = head_index)
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

# This is essential: cross-language dyads are not part of the risk set.
block_constraint <- ~ blockdiag("block_id")


# ----------------------------------------------------------------------------
# 8. Combined diagnostics
# ----------------------------------------------------------------------------

possible_within_language_dyads <- sum(
  block_summary$possible_within_language_dyads
)
observed_edges <- nrow(edges_all)
prior_dyads_total <- sum(block_summary$number_of_prior_dyads)
prior_current_edges_total <- sum(block_summary$prior_current_edges)
prior_current_nonedges_total <- sum(block_summary$prior_current_nonedges)

if (prior_dyads_total == 0L) {
  stop(
    "No prior=1 dyads exist; the common prior effect cannot be estimated.",
    call. = FALSE
  )
}
if (prior_current_edges_total == 0L || prior_current_nonedges_total == 0L) {
  stop(
    paste0(
      "Across all languages, prior=1 perfectly predicts the current outcome. ",
      "prior current edges = ", prior_current_edges_total,
      "; prior current nonedges = ", prior_current_nonedges_total, "."
    ),
    call. = FALSE
  )
}

combined_summary <- data.frame(
  analysis = "block_diagonal_languages",
  script_version = SCRIPT_VERSION,
  root_directory = ROOT_DIR,
  number_of_languages = nrow(block_summary),
  languages_included = paste(block_summary$language_folder, collapse = ", "),
  number_of_nodes = total_nodes,
  number_of_edges = observed_edges,
  possible_within_language_dyads = possible_within_language_dyads,
  within_language_density = observed_edges / possible_within_language_dyads,
  number_of_prior_dyads = prior_dyads_total,
  prior_current_edges = prior_current_edges_total,
  prior_current_nonedges = prior_current_nonedges_total,
  expertise_variable = "expertise_z (fallback: expertise_model_z or expertise_z_shared)",
  leadership_variable = "leadership_z (fallback: leadership_model_z or leadership_z_shared)",
  cross_language_dyads = "excluded by blockdiag(block_id)",
  stringsAsFactors = FALSE
)

message("\n============================================================")
message("Combined block-diagonal language network")
message("============================================================")
message("Languages: ", nrow(block_summary))
message("Nodes: ", total_nodes)
message("Edges: ", observed_edges)
message("Possible within-language dyads: ", possible_within_language_dyads)
message("Prior=1 dyads: ", prior_dyads_total)
message("Prior=1 current edges: ", prior_current_edges_total)
message("Prior=1 current nonedges: ", prior_current_nonedges_total)


# ----------------------------------------------------------------------------
# 9. Fit the block-diagonal M0--M5 sequence
# ----------------------------------------------------------------------------

message("\nFitting block-diagonal M0--M5 models (M5 GWESP decay = ",
        GWESP_DECAY, ")...")

model_formulas <- list(
  m0_edges =
    net_big ~ edges,
  m1_prior =
    net_big ~ edges + edgecov(prior_big),
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
    block_constraint,
    ERGM_CONTROL
  )

  if (inherits(models[[model_name]], "ergm")) {
    message("  [OK] ", model_name)
  } else {
    message(
      "  [MODEL FAILED] ", model_name, ": ",
      conditionMessage(models[[model_name]])
    )
  }
}

coefficients_all <- bind_rows_base(lapply(names(models), function(model_name) {
  extract_coefficients(models[[model_name]], model_name)
}))
model_fit <- bind_rows_base(lapply(names(models), function(model_name) {
  extract_model_fit(models[[model_name]], model_name)
}))

coefficients_final_model <- coefficients_all[
  coefficients_all$model == "m5_full_gwesp",
  ,
  drop = FALSE
]
failed_models <- model_fit[model_fit$status != "ok", , drop = FALSE]
not_estimable_terms <- coefficients_all[
  coefficients_all$status == "not_estimable",
  ,
  drop = FALSE
]

model_specifications <- data.frame(
  model = names(model_formulas),
  terms = c(
    "edges",
    "edges + prior",
    "edges + prior + expertise",
    "edges + prior + expertise + absolute expertise difference",
    paste0(
      "edges + prior + expertise + absolute expertise difference + ",
      "leadership + absolute leadership difference"
    ),
    paste0(
      "edges + prior + expertise + absolute expertise difference + ",
      "leadership + absolute leadership difference + ",
      "GWESP (fixed decay = ", GWESP_DECAY, ")"
    )
  ),
  stringsAsFactors = FALSE
)


# ----------------------------------------------------------------------------
# 10. Save reproducibility files and model output
# ----------------------------------------------------------------------------

nodes_to_save <- nodes_all[
  ,
  c(
    "vertex_id", "language_folder", "language_dataset", "block_id",
    "original_global_id", "UserID", "expertise_model_z",
    "leadership_model_z"
  ),
  drop = FALSE
]
edges_to_save <- edges_all[
  ,
  c(
    "language_folder", "language_dataset", "block_id", "u", "v",
    "u_original", "v_original"
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
  file.path(OUTPUT_DIR, "language_block_summary.csv"),
  row.names = FALSE
)

if (SAVE_COMBINED_PRIOR_MATRIX) {
  write.csv(
    prior_big,
    file.path(OUTPUT_DIR, "combined_prior_matrix.csv"),
    row.names = TRUE
  )
}

if (SAVE_MODEL_OBJECTS) {
  saveRDS(
    models,
    file.path(OUTPUT_DIR, "block_diagonal_language_ergm_models.rds")
  )
}

output_lines <- capture.output({
  cat("GitHub/GHTorrent language block-diagonal ERGM\n")
  cat("Script version:", SCRIPT_VERSION, "\n")
  cat("Root directory:", ROOT_DIR, "\n")
  cat("Constraint: blockdiag(block_id)\n")
  cat(
    "Languages included:",
    paste(block_summary$language_folder, collapse = ", "),
    "\n"
  )
  cat("Nodes:", total_nodes, "\n")
  cat("Edges:", observed_edges, "\n")
  cat("Possible within-language dyads:", possible_within_language_dyads, "\n")
  cat("Prior=1 dyads:", prior_dyads_total, "\n")
  cat("Prior=1 current edges:", prior_current_edges_total, "\n")
  cat("Prior=1 current nonedges:", prior_current_nonedges_total, "\n\n")

  cat("Language blocks:\n")
  print(block_summary)

  if (nrow(failed_languages) > 0L) {
    cat("\nFailed languages:\n")
    print(failed_languages)
  }

  for (model_name in names(models)) {
    cat("\n---------------- ", model_name, " ----------------\n", sep = "")
    if (inherits(models[[model_name]], "ergm")) {
      print(extract_coefficients(models[[model_name]], model_name))
      cat(
        "AIC:",
        tryCatch(AIC(models[[model_name]]), error = function(e) NA_real_),
        "\n"
      )
      cat(
        "BIC:",
        tryCatch(BIC(models[[model_name]]), error = function(e) NA_real_),
        "\n"
      )
    } else {
      cat("FAILED:", conditionMessage(models[[model_name]]), "\n")
    }
  }
})

writeLines(output_lines, TXT_FILE, useBytes = TRUE)


# ----------------------------------------------------------------------------
# 11. Save Excel workbook
# ----------------------------------------------------------------------------

workbook <- createWorkbook()

write_sheet <- function(name, data) {
  addWorksheet(workbook, name, gridLines = FALSE)
  writeData(workbook, name, data, withFilter = nrow(data) > 0L)
  freezePane(workbook, name, firstRow = TRUE)
  if (ncol(data) > 0L) {
    setColWidths(workbook, name, cols = seq_len(ncol(data)), widths = "auto")
  }
}

write_sheet("coefficients", coefficients_final_model)
write_sheet("coefficients_all_models", coefficients_all)
write_sheet("model_fit", model_fit)
write_sheet("model_specifications", model_specifications)
write_sheet("combined_summary", combined_summary)
write_sheet("language_block_summary", block_summary)
write_sheet("language_discovery", discovery_table)
write_sheet("transformed_nodes", nodes_to_save)
write_sheet("failed_models", failed_models)
write_sheet("not_estimable_terms", not_estimable_terms)
write_sheet("failed_languages", failed_languages)

saveWorkbook(workbook, OUTPUT_FILE, overwrite = TRUE)

message("\nBlock-diagonal language ERGM analysis completed.")
message("Languages included: ", paste(block_summary$language_folder, collapse = ", "))
message("Languages excluded: ", nrow(failed_languages))
message("[SAVED] ", normalizePath(OUTPUT_FILE, mustWork = FALSE))
