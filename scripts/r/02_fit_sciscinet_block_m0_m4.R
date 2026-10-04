# ============================================================================
# SciSciNet block-diagonal journal ERGM: M0--M4, exact MLE
#
# Place this script directly inside FullJournal and run:
#   Rscript run_all_journal_block_ergm_m0_m4_mle.R
#
# Or explicitly provide the FullJournal path:
#   Rscript run_all_journal_block_ergm_m0_m4_mle.R /path/to/FullJournal
#
# Expected input for each journal (directly in its folder or in one nested
# processed_for_ergm_prior_before_* folder):
#   *_nodes.csv
#   *_edges.csv              (not *_prior_edges.csv)
#   *_prior_mat.csv
#
# The script builds one pooled, block-diagonal network. Cross-journal dyads are
# structural zeros and are excluded from the risk set via:
#   constraints = ~ blockdiag("block_id")
#
# Models:
#   M0: edges
#   M1: M0 + prior collaboration
#   M2: M1 + expertise level
#   M3: M2 + absolute expertise difference
#   M4: M3 + leadership level + absolute leadership difference
#
# All M0--M4 terms are dyad-independent. Therefore, the script explicitly uses
# estimate = "MLE"; it does NOT run MCMLE/MCMC iterations or include GWESP.
#
# Output:
#   FullJournal/block_diagonal_journal_ergm_results_m0_m4_mle/
# ============================================================================

SCRIPT_VERSION <- "SciSciNet journal block-diagonal ERGM M0--M4 exact MLE 2026-08-23 v1"
message("Running: ", SCRIPT_VERSION)


# ----------------------------------------------------------------------------
# 0. Paths and user settings
# ----------------------------------------------------------------------------

get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)

  if (length(file_arg) > 0L) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[[1L]]),
                                 mustWork = TRUE)))
  }

  normalizePath(getwd(), mustWork = TRUE)
}

user_args <- commandArgs(trailingOnly = TRUE)
if (length(user_args) > 1L) {
  stop(
    paste0(
      "Use at most one argument: the path to FullJournal.\n",
      "Example: Rscript run_all_journal_block_ergm_m0_m4_mle.R /path/to/FullJournal"
    ),
    call. = FALSE
  )
}

ROOT_DIR <- if (length(user_args) == 1L) {
  normalizePath(user_args[[1L]], mustWork = TRUE)
} else {
  get_script_dir()
}

# NULL = automatically include every immediate subfolder that contains exactly
# one valid input triplet. This safely ignores folders such as
# journal_network_visualizations and old result folders.
#
# To force a known journal set, replace NULL with exact Finder folder names:
# JOURNAL_FOLDERS <- c("Cell", "Ecological Applications", "Geology", "Organization Science")
JOURNAL_FOLDERS <- NULL

EXCLUDED_TOP_LEVEL_FOLDERS <- c(
  "journal_network_visualizations",
  "separate_results",
  "separate_results_m0_m4_mle",
  "block_diagonal_journal_ergm_results",
  "block_diagonal_journal_ergm_results_m0_m4_mle"
)

# A block is never silently dropped after its input triplet has been found.
# Set FALSE only if you deliberately want to fit the remaining valid blocks.
STOP_IF_ANY_JOURNAL_FAILS <- TRUE

BINARIZE_PRIOR <- TRUE
SAVE_COMBINED_PRIOR_MATRIX <- FALSE
SAVE_MODEL_OBJECTS <- TRUE
MAX_COMBINED_NODES <- 12000L
SEED <- 20260823L

OUTPUT_DIR <- file.path(
  ROOT_DIR,
  "block_diagonal_journal_ergm_results_m0_m4_mle"
)
OUTPUT_XLSX <- file.path(
  OUTPUT_DIR,
  "block_diagonal_journal_ergm_results.xlsx"
)
OUTPUT_TXT <- file.path(
  OUTPUT_DIR,
  "block_diagonal_journal_ergm_output.txt"
)


# ----------------------------------------------------------------------------
# 1. Required packages
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
      ".\n\nInstall them in R with:\ninstall.packages(c(",
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

set.seed(SEED)
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)


# ----------------------------------------------------------------------------
# 2. General helper functions
# ----------------------------------------------------------------------------

clean_id <- function(x) {
  y <- trimws(as.character(x))
  bad_literal <- !is.na(y) & tolower(y) %in% c(
    "", "na", "nan", "<na>", "null", "none"
  )
  y[is.na(y) | bad_literal] <- NA_character_
  y
}

safe_name <- function(x) {
  y <- gsub("[^A-Za-z0-9._-]+", "_", as.character(x))
  y <- gsub("_+", "_", y)
  y <- gsub("^_+|_+$", "", y)
  if (is.na(y) || y == "") "journal" else y
}

assert_columns <- function(data, required, object_name) {
  missing <- setdiff(required, names(data))
  if (length(missing) > 0L) {
    stop(
      sprintf(
        "%s is missing required column(s): %s\nAvailable columns: %s",
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
        "Could not find a usable ", variable_name, " column.\n",
        "Expected one of: ", paste(candidates, collapse = ", "), "\n",
        "Available columns: ", paste(names(data), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  hit[[1L]]
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

read_prior_matrix <- function(path, binarize = TRUE) {
  prior_raw <- read_character_csv(path)

  if (ncol(prior_raw) < 2L) {
    stop(basename(path), " does not contain a matrix.", call. = FALSE)
  }

  row_ids <- clean_id(prior_raw[[1L]])
  prior <- as.matrix(prior_raw[-1L])
  suppressWarnings(storage.mode(prior) <- "double")

  rownames(prior) <- row_ids
  colnames(prior) <- clean_id(colnames(prior))

  if (anyNA(rownames(prior)) || anyNA(colnames(prior))) {
    stop("The prior matrix has a missing row or column ID.", call. = FALSE)
  }
  if (anyDuplicated(rownames(prior)) > 0L ||
      anyDuplicated(colnames(prior)) > 0L) {
    stop("The prior matrix contains duplicated IDs.", call. = FALSE)
  }
  if (nrow(prior) != ncol(prior)) {
    stop("The prior matrix is not square.", call. = FALSE)
  }
  if (!setequal(rownames(prior), colnames(prior))) {
    stop("Prior-matrix row and column ID sets differ.", call. = FALSE)
  }

  prior <- prior[rownames(prior), rownames(prior), drop = FALSE]

  if (anyNA(prior) || any(!is.finite(prior))) {
    stop("The prior matrix contains missing or non-finite values.", call. = FALSE)
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
  diag(prior) <- 0L
  prior
}

degree_from_edge_indices <- function(tail_index, head_index, n_nodes) {
  tabulate(
    c(as.integer(tail_index), as.integer(head_index)),
    nbins = n_nodes
  )
}

safe_numeric <- function(x) {
  x <- suppressWarnings(as.numeric(x))
  x[!is.finite(x)] <- NA_real_
  x
}

condition_text <- function(x) {
  if (inherits(x, "condition")) conditionMessage(x) else as.character(x)
}


# ----------------------------------------------------------------------------
# 3. Input discovery
# ----------------------------------------------------------------------------

NODE_FILE_PATTERN <- "_nodes( \\([0-9]+\\))?\\.csv$"
EDGE_FILE_PATTERN <- "_edges( \\([0-9]+\\))?\\.csv$"
PRIOR_FILE_PATTERN <- "_prior_mat( \\([0-9]+\\))?\\.csv$"
PRIOR_EDGE_FILE_PATTERN <- "_prior_edges( \\([0-9]+\\))?\\.csv$"

processed_file_triplet <- function(folder) {
  files <- list.files(folder, full.names = TRUE, recursive = FALSE)
  if (length(files) == 0L) {
    return(list(valid = FALSE, nodes = character(), edges = character(),
                prior = character()))
  }

  info <- file.info(files)
  files <- files[!is.na(info$isdir) & !info$isdir]
  file_names <- basename(files)

  node_files <- files[grepl(NODE_FILE_PATTERN, file_names, ignore.case = TRUE)]
  edge_files <- files[grepl(EDGE_FILE_PATTERN, file_names, ignore.case = TRUE)]
  edge_files <- edge_files[
    !grepl(PRIOR_EDGE_FILE_PATTERN, basename(edge_files), ignore.case = TRUE)
  ]
  prior_files <- files[grepl(PRIOR_FILE_PATTERN, file_names, ignore.case = TRUE)]

  list(
    valid = length(node_files) == 1L &&
      length(edge_files) == 1L &&
      length(prior_files) == 1L,
    nodes = node_files,
    edges = edge_files,
    prior = prior_files
  )
}

discover_one_journal <- function(journal_root, explicitly_requested = FALSE) {
  possible_dirs <- unique(c(
    journal_root,
    list.dirs(journal_root, recursive = TRUE, full.names = TRUE)
  ))

  triplet_status <- lapply(possible_dirs, processed_file_triplet)
  is_valid <- vapply(triplet_status, `[[`, logical(1), "valid")
  valid_all <- possible_dirs[is_valid]
  canonical <- valid_all[
    grepl("processed_for_ergm_prior_before_", valid_all, fixed = TRUE)
  ]
  candidates <- if (length(canonical) > 0L) canonical else valid_all

  csv_files <- list.files(
    journal_root,
    pattern = "\\.csv$",
    full.names = TRUE,
    recursive = TRUE,
    ignore.case = TRUE
  )
  has_ergm_like_file <- any(grepl(
    "_(nodes|edges|prior_mat)( \\([0-9]+\\))?\\.csv$",
    basename(csv_files),
    ignore.case = TRUE
  ))

  common <- list(
    journal_folder = basename(journal_root),
    journal_root = normalizePath(journal_root, mustWork = TRUE),
    candidate_directories = paste(valid_all, collapse = " | "),
    number_of_valid_triplets = length(valid_all),
    number_of_csv_files_found = length(csv_files)
  )

  if (length(candidates) == 1L) {
    return(as.data.frame(c(
      common,
      list(
        processed_dir = normalizePath(candidates[[1L]], mustWork = TRUE),
        status = "included",
        error = NA_character_
      )
    ), stringsAsFactors = FALSE))
  }

  if (length(candidates) > 1L) {
    return(as.data.frame(c(
      common,
      list(
        processed_dir = NA_character_,
        status = "error",
        error = paste0(
          "Multiple valid input triplets were found. Keep exactly one intended ",
          "processed dataset in this journal folder. Candidates: ",
          paste(candidates, collapse = " | ")
        )
      )
    ), stringsAsFactors = FALSE))
  }

  # In automatic mode, folders without ERGM-like files are harmless auxiliary
  # folders (for example, journal_network_visualizations), so they are logged
  # and ignored. A partial ERGM dataset is treated as an error.
  if (!explicitly_requested && !has_ergm_like_file) {
    return(as.data.frame(c(
      common,
      list(
        processed_dir = NA_character_,
        status = "ignored_nonjournal_folder",
        error = "No complete ERGM input triplet found; auxiliary folder ignored."
      )
    ), stringsAsFactors = FALSE))
  }

  return(as.data.frame(c(
    common,
    list(
      processed_dir = NA_character_,
      status = "error",
      error = paste0(
        "No directory containing exactly one *_nodes.csv, one current ",
        "*_edges.csv, and one *_prior_mat.csv was found."
      )
    )
  ), stringsAsFactors = FALSE))
}

if (is.null(JOURNAL_FOLDERS)) {
  journal_roots <- list.dirs(ROOT_DIR, full.names = TRUE, recursive = FALSE)
  journal_roots <- journal_roots[
    normalizePath(journal_roots, mustWork = TRUE) !=
      normalizePath(ROOT_DIR, mustWork = TRUE) &
      !grepl("^\\.", basename(journal_roots)) &
      !basename(journal_roots) %in% EXCLUDED_TOP_LEVEL_FOLDERS
  ]
  explicitly_requested <- FALSE
} else {
  journal_roots <- file.path(ROOT_DIR, unique(as.character(JOURNAL_FOLDERS)))
  missing_roots <- journal_roots[!dir.exists(journal_roots)]
  if (length(missing_roots) > 0L) {
    stop(
      paste0("Requested journal folder(s) do not exist:\n- ",
             paste(missing_roots, collapse = "\n- ")),
      call. = FALSE
    )
  }
  explicitly_requested <- TRUE
}

journal_roots <- sort(journal_roots)
if (length(journal_roots) == 0L) {
  stop("No journal subfolders were found under ROOT_DIR.", call. = FALSE)
}

discovery_table <- do.call(
  rbind,
  lapply(journal_roots, discover_one_journal,
         explicitly_requested = explicitly_requested)
)
rownames(discovery_table) <- NULL

write.csv(
  discovery_table,
  file.path(OUTPUT_DIR, "journal_discovery.csv"),
  row.names = FALSE
)

discovery_errors <- discovery_table[
  discovery_table$status == "error",
  ,
  drop = FALSE
]
if (nrow(discovery_errors) > 0L) {
  stop(
    paste0(
      "Journal discovery failed for: ",
      paste(discovery_errors$journal_folder, collapse = ", "),
      ". See ", file.path(OUTPUT_DIR, "journal_discovery.csv")
    ),
    call. = FALSE
  )
}

valid_discovery <- discovery_table[
  discovery_table$status == "included",
  ,
  drop = FALSE
]
if (nrow(valid_discovery) == 0L) {
  stop(
    paste0(
      "No valid journal input triplets were found. See ",
      file.path(OUTPUT_DIR, "journal_discovery.csv")
    ),
    call. = FALSE
  )
}

message("ROOT_DIR: ", ROOT_DIR)
message("Journals included (", nrow(valid_discovery), "): ",
        paste(valid_discovery$journal_folder, collapse = ", "))


# ----------------------------------------------------------------------------
# 4. Read and validate one journal block
# ----------------------------------------------------------------------------

read_journal_block <- function(journal_folder, processed_dir, block_index) {
  message("\nPreparing journal block: ", journal_folder)
  message("  Source: ", processed_dir)

  triplet <- processed_file_triplet(processed_dir)
  if (!isTRUE(triplet$valid)) {
    stop("The selected processed directory no longer has one valid input triplet.",
         call. = FALSE)
  }

  node_file <- triplet$nodes[[1L]]
  edge_file <- triplet$edges[[1L]]
  prior_file <- triplet$prior[[1L]]

  nodes_raw <- read_character_csv(node_file)
  edges_raw <- read_character_csv(edge_file)
  assert_columns(nodes_raw, "global_id", paste0(journal_folder, " nodes file"))
  assert_columns(edges_raw, c("u", "v"), paste0(journal_folder, " edges file"))

  expertise_column <- pick_first_column(
    nodes_raw,
    c("expertise_z", "expertise_model_z", "expertise_z_shared"),
    "standardized expertise"
  )
  leadership_column <- pick_first_column(
    nodes_raw,
    c("leadership_z", "leadership_model_z", "leadership_z_shared"),
    "standardized leadership"
  )

  dataset_value <- journal_folder
  if ("dataset" %in% names(nodes_raw)) {
    dataset_values <- unique(clean_id(nodes_raw$dataset))
    dataset_values <- dataset_values[!is.na(dataset_values)]
    if (length(dataset_values) > 1L) {
      stop("The node file contains more than one dataset value.", call. = FALSE)
    }
    if (length(dataset_values) == 1L) dataset_value <- dataset_values[[1L]]
  }

  nodes <- data.frame(
    original_global_id = clean_id(nodes_raw$global_id),
    expertise_model_z = suppressWarnings(as.numeric(nodes_raw[[expertise_column]])),
    leadership_model_z = suppressWarnings(as.numeric(nodes_raw[[leadership_column]])),
    stringsAsFactors = FALSE
  )
  nodes$AuthorID <- if ("AuthorID" %in% names(nodes_raw)) {
    clean_id(nodes_raw$AuthorID)
  } else {
    NA_character_
  }

  if (nrow(nodes) < 2L) {
    stop("Fewer than two nodes are available.", call. = FALSE)
  }
  if (anyNA(nodes$original_global_id)) {
    stop("The nodes file contains a missing global_id.", call. = FALSE)
  }
  if (anyDuplicated(nodes$original_global_id) > 0L) {
    stop("The nodes file contains duplicated global_id values.", call. = FALSE)
  }
  if (anyNA(nodes$expertise_model_z) || any(!is.finite(nodes$expertise_model_z))) {
    stop("Expertise contains missing or non-finite values.", call. = FALSE)
  }
  if (anyNA(nodes$leadership_model_z) || any(!is.finite(nodes$leadership_model_z))) {
    stop("Leadership contains missing or non-finite values.", call. = FALSE)
  }

  edges <- data.frame(
    u_original = clean_id(edges_raw$u),
    v_original = clean_id(edges_raw$v),
    stringsAsFactors = FALSE
  )
  if (anyNA(edges$u_original) || anyNA(edges$v_original)) {
    stop("The edges file contains a missing endpoint.", call. = FALSE)
  }
  if (any(edges$u_original == edges$v_original)) {
    stop("The edges file contains self-loops.", call. = FALSE)
  }

  absent_edge_ids <- setdiff(
    unique(c(edges$u_original, edges$v_original)),
    nodes$original_global_id
  )
  if (length(absent_edge_ids) > 0L) {
    stop(
      paste0(
        "Edges refer to IDs absent from the nodes file: ",
        paste(head(absent_edge_ids, 20L), collapse = ", ")
      ),
      call. = FALSE
    )
  }

  if (nrow(edges) > 0L) {
    edge_low <- pmin(edges$u_original, edges$v_original)
    edge_high <- pmax(edges$u_original, edges$v_original)
    keep_edge <- !duplicated(paste(edge_low, edge_high, sep = "\r"))
    edges <- edges[keep_edge, , drop = FALSE]
    edges$u_original <- edge_low[keep_edge]
    edges$v_original <- edge_high[keep_edge]
  }

  prior <- read_prior_matrix(prior_file, binarize = BINARIZE_PRIOR)
  node_ids <- nodes$original_global_id
  if (!setequal(node_ids, rownames(prior))) {
    missing_in_prior <- setdiff(node_ids, rownames(prior))
    extra_in_prior <- setdiff(rownames(prior), node_ids)
    stop(
      paste0(
        "Node and prior-matrix IDs do not match. Missing from prior: ",
        paste(head(missing_in_prior, 20L), collapse = ", "),
        "; extra in prior: ",
        paste(head(extra_in_prior, 20L), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  prior <- prior[node_ids, node_ids, drop = FALSE]

  tail_local <- match(edges$u_original, node_ids)
  head_local <- match(edges$v_original, node_ids)
  degree_values <- degree_from_edge_indices(
    tail_local,
    head_local,
    nrow(nodes)
  )
  if (any(degree_values == 0L)) {
    stop(
      sprintf("The processed network contains %d isolate(s).",
              sum(degree_values == 0L)),
      call. = FALSE
    )
  }

  upper <- upper.tri(prior)
  prior_dyads <- sum(prior[upper] > 0)
  prior_current_edges <- if (nrow(edges) == 0L) {
    0L
  } else {
    sum(prior[cbind(tail_local, head_local)] > 0)
  }

  block_id <- sprintf("block_%03d_%s", block_index, safe_name(journal_folder))
  nodes$journal_folder <- journal_folder
  nodes$journal_dataset <- dataset_value
  nodes$block_id <- block_id
  nodes$vertex_id <- paste(block_id, nodes$original_global_id, sep = "__")

  id_lookup <- stats::setNames(nodes$vertex_id, nodes$original_global_id)
  edges$journal_folder <- journal_folder
  edges$journal_dataset <- dataset_value
  edges$block_id <- block_id
  edges$u <- unname(id_lookup[edges$u_original])
  edges$v <- unname(id_lookup[edges$v_original])
  if (anyNA(edges$u) || anyNA(edges$v)) {
    stop("Could not map a local edge endpoint to a block vertex.", call. = FALSE)
  }

  rownames(prior) <- nodes$vertex_id
  colnames(prior) <- nodes$vertex_id

  possible_dyads <- nrow(nodes) * (nrow(nodes) - 1) / 2
  block_summary <- data.frame(
    block_id = block_id,
    journal_folder = journal_folder,
    journal_dataset = dataset_value,
    processed_dir = normalizePath(processed_dir, mustWork = TRUE),
    node_file = normalizePath(node_file, mustWork = TRUE),
    edge_file = normalizePath(edge_file, mustWork = TRUE),
    prior_file = normalizePath(prior_file, mustWork = TRUE),
    expertise_column_used = expertise_column,
    leadership_column_used = leadership_column,
    number_of_nodes = nrow(nodes),
    number_of_edges = nrow(edges),
    possible_within_journal_dyads = possible_dyads,
    density = nrow(edges) / possible_dyads,
    number_of_prior_dyads = prior_dyads,
    prior_current_edges = prior_current_edges,
    prior_current_nonedges = prior_dyads - prior_current_edges,
    mean_expertise_z = mean(nodes$expertise_model_z),
    sd_expertise_z = stats::sd(nodes$expertise_model_z),
    mean_leadership_z = mean(nodes$leadership_model_z),
    sd_leadership_z = stats::sd(nodes$leadership_model_z),
    stringsAsFactors = FALSE
  )

  message("  [OK] ", journal_folder, ": ", nrow(nodes), " nodes, ",
          nrow(edges), " edges, ", prior_dyads, " prior dyads")

  list(nodes = nodes, edges = edges, prior = prior, summary = block_summary)
}


# ----------------------------------------------------------------------------
# 5. Read all journal blocks
# ----------------------------------------------------------------------------

blocks_raw <- lapply(seq_len(nrow(valid_discovery)), function(i) {
  journal_folder <- valid_discovery$journal_folder[[i]]
  processed_dir <- valid_discovery$processed_dir[[i]]

  tryCatch(
    read_journal_block(journal_folder, processed_dir, i),
    error = function(e) structure(
      list(
        journal_folder = journal_folder,
        processed_dir = processed_dir,
        error = conditionMessage(e)
      ),
      class = "failed_journal_block"
    )
  )
})

is_failed_block <- vapply(
  blocks_raw,
  inherits,
  logical(1),
  "failed_journal_block"
)
valid_blocks <- blocks_raw[!is_failed_block]
failed_blocks <- blocks_raw[is_failed_block]

failed_journals <- if (length(failed_blocks) == 0L) {
  data.frame(
    journal_folder = character(),
    processed_dir = character(),
    error = character(),
    stringsAsFactors = FALSE
  )
} else {
  do.call(rbind, lapply(failed_blocks, function(x) {
    data.frame(
      journal_folder = x$journal_folder,
      processed_dir = x$processed_dir,
      error = x$error,
      stringsAsFactors = FALSE
    )
  }))
}

write.csv(
  failed_journals,
  file.path(OUTPUT_DIR, "journal_validation_failures.csv"),
  row.names = FALSE
)

if (nrow(failed_journals) > 0L && STOP_IF_ANY_JOURNAL_FAILS) {
  stop(
    paste0(
      nrow(failed_journals),
      " journal(s) failed validation; the block model was not fitted. See ",
      file.path(OUTPUT_DIR, "journal_validation_failures.csv")
    ),
    call. = FALSE
  )
}
if (length(valid_blocks) == 0L) {
  stop("All journal blocks failed validation.", call. = FALSE)
}


# ----------------------------------------------------------------------------
# 6. Combine the blocks and create the constrained network
# ----------------------------------------------------------------------------

nodes_all <- do.call(rbind, lapply(valid_blocks, `[[`, "nodes"))
edges_all <- do.call(rbind, lapply(valid_blocks, `[[`, "edges"))
block_summary <- do.call(rbind, lapply(valid_blocks, `[[`, "summary"))
rownames(nodes_all) <- NULL
rownames(edges_all) <- NULL
rownames(block_summary) <- NULL

if (anyDuplicated(nodes_all$vertex_id) > 0L) {
  stop("Combined vertex IDs are not unique.", call. = FALSE)
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
if (!is.finite(stats::sd(nodes_all$expertise_model_z)) ||
    stats::sd(nodes_all$expertise_model_z) == 0) {
  stop("The pooled expertise covariate has zero variance.", call. = FALSE)
}
if (!is.finite(stats::sd(nodes_all$leadership_model_z)) ||
    stats::sd(nodes_all$leadership_model_z) == 0) {
  stop("The pooled leadership covariate has zero variance.", call. = FALSE)
}

prior_big <- matrix(0L, nrow = total_nodes, ncol = total_nodes)
for (block in valid_blocks) {
  index <- match(block$nodes$vertex_id, nodes_all$vertex_id)
  prior_big[index, index] <- unname(block$prior)
}
diag(prior_big) <- 0L
if (!isTRUE(all.equal(prior_big, t(prior_big), tolerance = 1e-12))) {
  stop("The combined prior matrix is not symmetric.", call. = FALSE)
}

net_big <- network.initialize(
  n = total_nodes,
  directed = FALSE,
  loops = FALSE,
  multiple = FALSE
)
network.vertex.names(net_big) <- nodes_all$vertex_id
set.vertex.attribute(net_big, "block_id", nodes_all$block_id)
set.vertex.attribute(net_big, "journal", nodes_all$journal_folder)
set.vertex.attribute(net_big, "expertise_model_z", nodes_all$expertise_model_z)
set.vertex.attribute(net_big, "leadership_model_z", nodes_all$leadership_model_z)

tail_index <- match(edges_all$u, nodes_all$vertex_id)
head_index <- match(edges_all$v, nodes_all$vertex_id)
if (anyNA(tail_index) || anyNA(head_index)) {
  stop("At least one combined edge endpoint is absent from the vertex set.",
       call. = FALSE)
}
if (length(tail_index) > 0L) {
  add.edges(net_big, tail = tail_index, head = head_index)
}
if (network.edgecount(net_big) != nrow(edges_all)) {
  stop("Combined network edge count does not match the cleaned edge files.",
       call. = FALSE)
}

combined_degrees <- degree_from_edge_indices(tail_index, head_index, total_nodes)
if (any(combined_degrees == 0L)) {
  stop(
    sprintf("The combined network contains %d isolate(s).",
            sum(combined_degrees == 0L)),
    call. = FALSE
  )
}

# This constraint is what makes the model block-diagonal: only dyads whose
# endpoints have the same block_id are eligible to form ties.
block_constraint <- ~ blockdiag("block_id")


# ----------------------------------------------------------------------------
# 7. Diagnostics before model fitting
# ----------------------------------------------------------------------------

possible_within_journal_dyads <- sum(block_summary$possible_within_journal_dyads)
observed_edges <- nrow(edges_all)
prior_dyads_total <- sum(block_summary$number_of_prior_dyads)
prior_current_edges_total <- sum(block_summary$prior_current_edges)
prior_current_nonedges_total <- sum(block_summary$prior_current_nonedges)

if (prior_dyads_total == 0L) {
  stop("No prior-collaboration dyads exist; M1--M4 cannot estimate the prior effect.",
       call. = FALSE)
}
if (prior_current_edges_total == 0L || prior_current_nonedges_total == 0L) {
  stop(
    paste0(
      "Prior collaboration perfectly predicts the current tie across the ",
      "pooled blocks (prior current edges = ", prior_current_edges_total,
      ", prior current nonedges = ", prior_current_nonedges_total, ")."
    ),
    call. = FALSE
  )
}

current_by_prior <- rbind(
  data.frame(
    current_tie = 0L,
    prior_tie = 0L,
    n_dyads = possible_within_journal_dyads - observed_edges -
      prior_dyads_total + prior_current_edges_total
  ),
  data.frame(
    current_tie = 0L,
    prior_tie = 1L,
    n_dyads = prior_current_nonedges_total
  ),
  data.frame(
    current_tie = 1L,
    prior_tie = 0L,
    n_dyads = observed_edges - prior_current_edges_total
  ),
  data.frame(
    current_tie = 1L,
    prior_tie = 1L,
    n_dyads = prior_current_edges_total
  )
)

combined_summary <- data.frame(
  analysis = "block_diagonal_journals",
  script_version = SCRIPT_VERSION,
  estimation_method = "exact MLE (dyad-independent terms)",
  constraint = "blockdiag(block_id): cross-journal dyads excluded",
  number_of_journals = nrow(block_summary),
  journals_included = paste(block_summary$journal_folder, collapse = ", "),
  number_of_nodes = total_nodes,
  number_of_edges = observed_edges,
  possible_within_journal_dyads = possible_within_journal_dyads,
  within_journal_density = observed_edges / possible_within_journal_dyads,
  number_of_prior_dyads = prior_dyads_total,
  prior_current_edges = prior_current_edges_total,
  prior_current_nonedges = prior_current_nonedges_total,
  stringsAsFactors = FALSE
)

message("\nCombined block-diagonal network: ", total_nodes, " nodes, ",
        observed_edges, " edges, ", nrow(block_summary), " journal blocks")


# ----------------------------------------------------------------------------
# 8. Fit M0--M4 with exact maximum likelihood estimation
# ----------------------------------------------------------------------------

fit_ergm_safe <- function(formula, constraints) {
  tryCatch(
    ergm(
      formula,
      constraints = constraints,
      estimate = "MLE"
    ),
    error = function(e) e
  )
}

significance_code <- function(p) {
  ifelse(
    is.na(p), "",
    ifelse(p < 0.001, "***",
           ifelse(p < 0.01, "**", ifelse(p < 0.05, "*", "")))
  )
}

extract_coefficients <- function(fit, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      analysis = "block_diagonal_journals",
      model = model_name,
      term = NA_character_,
      Estimate = NA_real_,
      Std_Error = NA_real_,
      z_value = NA_real_,
      p_value = NA_real_,
      Odds_Ratio = NA_real_,
      CI_95_Lower = NA_real_,
      CI_95_Upper = NA_real_,
      significance = "",
      status = "failed",
      error = condition_text(fit),
      stringsAsFactors = FALSE,
      check.names = FALSE
    ))
  }

  estimate <- stats::coef(fit)
  variance <- tryCatch(stats::vcov(fit), error = function(e) NULL)
  if (is.null(variance) || nrow(variance) != length(estimate)) {
    std_error <- rep(NA_real_, length(estimate))
  } else {
    variance_diagonal <- diag(variance)
    variance_diagonal[!is.finite(variance_diagonal) | variance_diagonal < 0] <- NA_real_
    std_error <- sqrt(variance_diagonal)
  }

  z_value <- estimate / std_error
  p_value <- 2 * stats::pnorm(abs(z_value), lower.tail = FALSE)
  estimable <- is.finite(estimate) & is.finite(std_error) & std_error > 0 &
    is.finite(z_value) & is.finite(p_value)

  odds_ratio <- exp(estimate)
  ci_lower <- exp(estimate - 1.96 * std_error)
  ci_upper <- exp(estimate + 1.96 * std_error)

  data.frame(
    analysis = "block_diagonal_journals",
    model = model_name,
    term = names(estimate),
    Estimate = safe_numeric(estimate),
    Std_Error = safe_numeric(std_error),
    z_value = safe_numeric(z_value),
    p_value = safe_numeric(p_value),
    Odds_Ratio = safe_numeric(odds_ratio),
    CI_95_Lower = safe_numeric(ci_lower),
    CI_95_Upper = safe_numeric(ci_upper),
    significance = significance_code(safe_numeric(p_value)),
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
      analysis = "block_diagonal_journals",
      model = model_name,
      AIC = NA_real_,
      BIC = NA_real_,
      logLik = NA_real_,
      estimation_method = "MLE",
      status = "failed",
      error = condition_text(fit),
      stringsAsFactors = FALSE
    ))
  }

  data.frame(
    analysis = "block_diagonal_journals",
    model = model_name,
    AIC = safe_numeric(tryCatch(AIC(fit), error = function(e) NA_real_)),
    BIC = safe_numeric(tryCatch(BIC(fit), error = function(e) NA_real_)),
    logLik = safe_numeric(tryCatch(as.numeric(stats::logLik(fit)),
                                   error = function(e) NA_real_)),
    estimation_method = "MLE",
    status = "ok",
    error = NA_character_,
    stringsAsFactors = FALSE
  )
}

model_formulas <- list(
  m0_edges =
    net_big ~ edges,
  m1_prior =
    net_big ~ edges + edgecov(prior_big),
  m2_prior_expertise =
    net_big ~ edges + edgecov(prior_big) + nodecov("expertise_model_z"),
  m3_prior_expertise_similarity =
    net_big ~ edges + edgecov(prior_big) + nodecov("expertise_model_z") +
    absdiff("expertise_model_z"),
  m4_full =
    net_big ~ edges + edgecov(prior_big) + nodecov("expertise_model_z") +
    absdiff("expertise_model_z") + nodecov("leadership_model_z") +
    absdiff("leadership_model_z")
)

message("\nFitting block-diagonal M0--M4 exact-MLE models...")
models <- list()
for (model_name in names(model_formulas)) {
  message("  Fitting ", model_name, " ...")
  models[[model_name]] <- fit_ergm_safe(
    model_formulas[[model_name]],
    block_constraint
  )

  if (inherits(models[[model_name]], "ergm")) {
    message("  [OK] ", model_name)
  } else {
    message("  [MODEL FAILED] ", model_name, ": ",
            condition_text(models[[model_name]]))
  }
}

coefficients_all <- do.call(rbind, lapply(names(models), function(model_name) {
  extract_coefficients(models[[model_name]], model_name)
}))
rownames(coefficients_all) <- NULL

model_fit <- do.call(rbind, lapply(names(models), function(model_name) {
  extract_model_fit(models[[model_name]], model_name)
}))
rownames(model_fit) <- NULL

coefficients_m4 <- coefficients_all[
  coefficients_all$model == "m4_full",
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
    "edges + prior collaboration",
    "edges + prior collaboration + expertise level",
    "edges + prior collaboration + expertise level + absolute expertise difference",
    paste0(
      "edges + prior collaboration + expertise level + absolute expertise ",
      "difference + leadership level + absolute leadership difference"
    )
  ),
  stringsAsFactors = FALSE
)


# ----------------------------------------------------------------------------
# 9. Save reproducibility files, text output, and Excel results
# ----------------------------------------------------------------------------

nodes_to_save <- nodes_all[, c(
  "vertex_id", "journal_folder", "journal_dataset", "block_id",
  "original_global_id", "AuthorID", "expertise_model_z", "leadership_model_z"
), drop = FALSE]
edges_to_save <- edges_all[, c(
  "journal_folder", "journal_dataset", "block_id", "u", "v",
  "u_original", "v_original"
), drop = FALSE]

write.csv(nodes_to_save,
          file.path(OUTPUT_DIR, "combined_nodes_used.csv"),
          row.names = FALSE)
write.csv(edges_to_save,
          file.path(OUTPUT_DIR, "combined_edges_used.csv"),
          row.names = FALSE)
write.csv(block_summary,
          file.path(OUTPUT_DIR, "journal_block_summary.csv"),
          row.names = FALSE)
write.csv(coefficients_m4,
          file.path(OUTPUT_DIR, "block_diagonal_M4_coefficients.csv"),
          row.names = FALSE)
write.csv(coefficients_all,
          file.path(OUTPUT_DIR, "block_diagonal_all_model_coefficients.csv"),
          row.names = FALSE)
write.csv(model_fit,
          file.path(OUTPUT_DIR, "block_diagonal_model_fit.csv"),
          row.names = FALSE)

if (SAVE_COMBINED_PRIOR_MATRIX) {
  dimnames(prior_big) <- list(nodes_all$vertex_id, nodes_all$vertex_id)
  write.csv(prior_big,
            file.path(OUTPUT_DIR, "combined_prior_matrix.csv"),
            row.names = TRUE)
}
if (SAVE_MODEL_OBJECTS) {
  saveRDS(models,
          file.path(OUTPUT_DIR, "block_diagonal_journal_ergm_models.rds"))
}

output_lines <- capture.output({
  cat("SciSciNet journal block-diagonal ERGM: M0--M4 exact MLE\n")
  cat("Script version:", SCRIPT_VERSION, "\n")
  cat("Root directory:", ROOT_DIR, "\n")
  cat("Constraint: blockdiag(block_id); cross-journal dyads excluded\n")
  cat("Estimation: exact MLE (all terms are dyad-independent)\n\n")
  print(combined_summary)
  cat("\nCurrent tie by prior collaboration:\n")
  print(current_by_prior)
  cat("\nJournal block summary:\n")
  print(block_summary)
  if (nrow(failed_journals) > 0L) {
    cat("\nJournal validation failures:\n")
    print(failed_journals)
  }
  for (model_name in names(models)) {
    cat("\n---------------- ", model_name, " ----------------\n", sep = "")
    if (inherits(models[[model_name]], "ergm")) {
      print(extract_coefficients(models[[model_name]], model_name))
      cat("AIC:", tryCatch(AIC(models[[model_name]]),
                             error = function(e) NA_real_), "\n")
      cat("BIC:", tryCatch(BIC(models[[model_name]]),
                             error = function(e) NA_real_), "\n")
    } else {
      cat("FAILED:", condition_text(models[[model_name]]), "\n")
    }
  }
})
writeLines(output_lines, OUTPUT_TXT, useBytes = TRUE)

workbook <- createWorkbook()
write_sheet <- function(name, data) {
  addWorksheet(workbook, name, gridLines = FALSE)
  writeData(workbook, name, data, withFilter = nrow(data) > 0L)
  freezePane(workbook, name, firstRow = TRUE)
  if (ncol(data) > 0L) {
    setColWidths(workbook, name, cols = seq_len(ncol(data)), widths = "auto")
  }
}

write_sheet("coefficients_M4", coefficients_m4)
write_sheet("coefficients_all_models", coefficients_all)
write_sheet("model_fit", model_fit)
write_sheet("model_specifications", model_specifications)
write_sheet("combined_summary", combined_summary)
write_sheet("current_by_prior", current_by_prior)
write_sheet("journal_block_summary", block_summary)
write_sheet("journal_discovery", discovery_table)
write_sheet("combined_nodes", nodes_to_save)
write_sheet("failed_models", failed_models)
write_sheet("not_estimable_terms", not_estimable_terms)
write_sheet("failed_journals", failed_journals)

saveWorkbook(workbook, OUTPUT_XLSX, overwrite = TRUE)

message("\nBlock-diagonal journal ERGM analysis completed.")
message("Journals included: ", paste(block_summary$journal_folder, collapse = ", "))
message("Successful models: ", sum(model_fit$status == "ok"))
message("Failed models: ", sum(model_fit$status != "ok"))
message("[SAVED] ", normalizePath(OUTPUT_DIR, mustWork = FALSE))
message("Workbook: ", normalizePath(OUTPUT_XLSX, mustWork = FALSE))
