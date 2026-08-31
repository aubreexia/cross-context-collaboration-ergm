# ================================================================
# Batch GitHub/GHTorrent separate ERGM analysis with GWESP: M0--M5
#
# Place this script directly inside FullProject:
#
# FullProject/
#   run_all_language_separate_ergm_gwesp_mle.R
#   Python/
#     gh_nodes.csv
#     gh_edges.csv
#     gh_prior_mat.csv
#     gh_edges_with_weights.csv   # not used by ERGM
#   JavaScript/
#     gh_nodes.csv
#     gh_edges.csv
#     gh_prior_mat.csv
#   ...
#
# The script scans every non-hidden immediate subfolder of FullProject,
# fits M0--M5 separately for each language, and writes all outputs to:
#
# FullProject/separate_results_gwesp_mle/
#   all_language_ergm_results_gwesp_mle.xlsx
#   all_language_gwesp_coefficients.csv
#   all_language_all_model_coefficients.csv
#   all_language_model_fit.csv
#   all_language_gwesp_status.csv
#   all_language_network_summary.csv
#   all_language_removed_isolates.csv
#   all_language_failed_models.csv
#   language_outputs/
#     Python_ERGM_models.rds
#     Python_ERGM_output.txt
#     Python_removed_isolates.csv
#     ...
#
# M5 adds gwesp(decay = 0.25, fixed = TRUE) to the original full M4.
# All models are requested as MLE. For M5, ergm first finds an MPLE
# starting value and then performs MCMLE because GWESP is dyad-dependent.
# The Excel sheet "coefficients_gwesp" contains every language's M5
# coefficients in one table. A failed M5 (or language folder) is recorded
# and does not stop the remaining languages.
#
# The input node files already contain log-transformed, within-language
# standardized expertise and leadership variables. This script uses their
# z-score columns directly and does not transform them again.
#
# The threshold-user extraction may retain users with no observed current
# tie to another selected user. ERGM estimation therefore removes current-
# network isolates inside each language and subsets the prior matrix to the
# same modeled node set. Removed IDs are saved for auditing.
# ================================================================

SCRIPT_VERSION <- "GitHub FullProject separate ERGM with GWESP MLE 2026-08-15 v1"
message("Running: ", SCRIPT_VERSION)

# ----------------------------------------------------------------
# 0. Paths and settings
# ----------------------------------------------------------------

get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)

  if (length(file_arg) > 0L) {
    script_path <- sub("^--file=", "", file_arg[[1L]])
    return(dirname(normalizePath(script_path, mustWork = TRUE)))
  }

  frames <- sys.frames()
  if (length(frames) > 0L) {
    source_files <- vapply(
      frames,
      function(frame) {
        if (is.null(frame$ofile)) NA_character_ else as.character(frame$ofile)
      },
      character(1)
    )
    source_files <- source_files[!is.na(source_files) & source_files != ""]

    if (length(source_files) > 0L) {
      return(dirname(normalizePath(tail(source_files, 1L), mustWork = TRUE)))
    }
  }

  # In an interactive RStudio session, set the working directory to
  # FullProject before sourcing the script if neither method above applies.
  normalizePath(getwd(), mustWork = TRUE)
}

input_dir_from_env <- Sys.getenv("GHTORRENT_INPUT_DIR", unset = "")
output_dir_from_env <- Sys.getenv("GHTORRENT_OUTPUT_DIR", unset = "")

# Use the explicit input directory when provided. This makes the script
# portable: the public repository contains code and aggregate outputs, while
# processed language folders stay outside version control.
ROOT_DIR <- if (nzchar(input_dir_from_env)) {
  normalizePath(input_dir_from_env, mustWork = TRUE)
} else {
  get_script_dir()
}
OUTPUT_DIR <- if (nzchar(output_dir_from_env)) {
  normalizePath(output_dir_from_env, mustWork = FALSE)
} else {
  file.path(ROOT_DIR, "separate_results_gwesp_mle")
}
LANGUAGE_OUTPUT_DIR <- file.path(OUTPUT_DIR, "language_outputs")

OUTPUT_XLSX <- file.path(
  OUTPUT_DIR,
  "all_language_ergm_results_gwesp_mle.xlsx"
)

BINARIZE_PRIOR <- TRUE
ESTIMATION_METHOD <- "MLE"
GWESP_DECAY <- 0.25
GWESP_FIXED <- TRUE

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
      ".\n\nInstall them in the R Console with:\n",
      "install.packages(c(",
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

# MCMLE controls apply when a model has dyad-dependent terms (M5 GWESP).
# The same settings used for the block model make runs reproducible and give
# the MCMC sampler enough burn-in for the final structural model.
ERGM_CONTROL <- control.ergm(
  seed = 20260815L,
  MCMLE.maxit = 20,
  MCMC.burnin = 100000,
  MCMC.interval = 4096
)

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(LANGUAGE_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

# ----------------------------------------------------------------
# 2. General helper functions
# ----------------------------------------------------------------

empty_coefficients <- function() {
  data.frame(
    language = character(),
    model = character(),
    term = character(),
    Estimate = numeric(),
    Std_Error = numeric(),
    z_value = numeric(),
    p_value = numeric(),
    Odds_Ratio = numeric(),
    CI_95_Lower = numeric(),
    CI_95_Upper = numeric(),
    significance = character(),
    status = character(),
    error = character(),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

empty_model_fit <- function() {
  data.frame(
    language = character(),
    model = character(),
    AIC = numeric(),
    BIC = numeric(),
    logLik = numeric(),
    status = character(),
    error = character(),
    stringsAsFactors = FALSE
  )
}

empty_network_summary <- function() {
  data.frame(
    language = character(),
    input_number_of_nodes = integer(),
    isolates_removed = integer(),
    number_of_nodes = integer(),
    number_of_edges = integer(),
    possible_dyads = numeric(),
    density = numeric(),
    number_of_prior_dyads = integer(),
    isolates = integer(),
    mean_degree = numeric(),
    median_degree = numeric(),
    max_degree = numeric(),
    expertise_column_used = character(),
    leadership_column_used = character(),
    expertise_mean = numeric(),
    expertise_sd = numeric(),
    leadership_mean = numeric(),
    leadership_sd = numeric(),
    estimation_method = character(),
    gwesp_decay = numeric(),
    gwesp_fixed = logical(),
    nodes_file = character(),
    edges_file = character(),
    prior_matrix_file = character(),
    prior_edges_file = character(),
    script_version = character(),
    stringsAsFactors = FALSE
  )
}

empty_removed_isolates <- function() {
  data.frame(
    language = character(),
    global_id = character(),
    reason = character(),
    stringsAsFactors = FALSE
  )
}

clean_id <- function(x) {
  trimws(as.character(x))
}

safe_file_name <- function(x) {
  result <- gsub("+", "_plus", x, fixed = TRUE)
  result <- gsub("#", "_sharp", result, fixed = TRUE)
  result <- gsub("[^A-Za-z0-9._-]+", "_", result)
  result <- gsub("^_+|_+$", "", result)
  ifelse(result == "", "language", result)
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

discover_input_files <- function(folder) {
  nodes <- file.path(folder, "gh_nodes.csv")
  edges <- file.path(folder, "gh_edges.csv")
  prior_matrix <- file.path(folder, "gh_prior_mat.csv")
  prior_edges <- file.path(folder, "gh_prior_edges.csv")

  required_files <- c(nodes, edges, prior_matrix)
  missing_files <- required_files[!file.exists(required_files)]

  if (length(missing_files) > 0L) {
    stop(
      paste0(
        "Missing required GitHub ERGM input file(s) in folder ",
        basename(folder),
        ":\n- ",
        paste(basename(missing_files), collapse = "\n- ")
      ),
      call. = FALSE
    )
  }

  list(
    nodes = nodes,
    edges = edges,
    prior_matrix = prior_matrix,
    prior_edges = if (file.exists(prior_edges)) {
      prior_edges
    } else {
      NA_character_
    }
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

read_prior_matrix <- function(path, binarize = TRUE) {
  prior_raw <- read_character_csv(path)

  if (ncol(prior_raw) < 2L) {
    stop(
      paste0(basename(path), " does not contain a matrix."),
      call. = FALSE
    )
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
      "Prior-matrix row and column ID sets are different.",
      call. = FALSE
    )
  }

  prior <- prior[rownames(prior), rownames(prior), drop = FALSE]

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

fit_ergm_safe <- function(formula) {
  tryCatch(
    ergm(
      formula,
      estimate = ESTIMATION_METHOD,
      control = ERGM_CONTROL
    ),
    error = function(e) e
  )
}

significance_code <- function(p) {
  ifelse(
    is.na(p), "",
    ifelse(
      p < 0.001, "***",
      ifelse(
        p < 0.01, "**",
        ifelse(p < 0.05, "*", "")
      )
    )
  )
}

extract_coefficients <- function(fit, language, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      language = language,
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
      error = conditionMessage(fit),
      stringsAsFactors = FALSE,
      check.names = FALSE
    ))
  }

  estimate <- stats::coef(fit)

  variance <- tryCatch(
    stats::vcov(fit),
    error = function(e) NULL
  )

  if (is.null(variance)) {
    std_error <- rep(NA_real_, length(estimate))
  } else {
    std_error <- suppressWarnings(sqrt(diag(variance)))
  }

  z_value <- estimate / std_error
  p_value <- 2 * stats::pnorm(abs(z_value), lower.tail = FALSE)

  data.frame(
    language = language,
    model = model_name,
    term = names(estimate),
    Estimate = as.numeric(estimate),
    Std_Error = as.numeric(std_error),
    z_value = as.numeric(z_value),
    p_value = as.numeric(p_value),
    Odds_Ratio = exp(as.numeric(estimate)),
    CI_95_Lower = exp(
      as.numeric(estimate) - 1.96 * as.numeric(std_error)
    ),
    CI_95_Upper = exp(
      as.numeric(estimate) + 1.96 * as.numeric(std_error)
    ),
    significance = significance_code(p_value),
    status = "ok",
    error = NA_character_,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

extract_fit <- function(fit, language, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      language = language,
      model = model_name,
      AIC = NA_real_,
      BIC = NA_real_,
      logLik = NA_real_,
      status = "failed",
      error = conditionMessage(fit),
      stringsAsFactors = FALSE
    ))
  }

  data.frame(
    language = language,
    model = model_name,
    AIC = tryCatch(AIC(fit), error = function(e) NA_real_),
    BIC = tryCatch(BIC(fit), error = function(e) NA_real_),
    logLik = tryCatch(
      as.numeric(stats::logLik(fit)),
      error = function(e) NA_real_
    ),
    status = "ok",
    error = NA_character_,
    stringsAsFactors = FALSE
  )
}

write_sheet <- function(workbook, name, data) {
  openxlsx::addWorksheet(workbook, name, gridLines = FALSE)
  openxlsx::writeData(
    workbook,
    name,
    data,
    withFilter = nrow(data) > 0L
  )
  openxlsx::freezePane(workbook, name, firstRow = TRUE)

  if (ncol(data) > 0L) {
    openxlsx::setColWidths(
      workbook,
      name,
      cols = seq_len(ncol(data)),
      widths = "auto"
    )
  }
}

# ----------------------------------------------------------------
# 3. Fit M0--M5 for one language folder
# ----------------------------------------------------------------

run_one_language <- function(folder) {
  language <- basename(folder)
  safe_language <- safe_file_name(language)

  message("\n================================================")
  message("Language: ", language)
  message("Folder: ", folder)
  message("================================================")

  input_files <- discover_input_files(folder)

  message("Nodes: ", input_files$nodes)
  message("Edges: ", input_files$edges)
  message("Prior matrix: ", input_files$prior_matrix)

  nodes <- read_character_csv(input_files$nodes)
  edges <- read_character_csv(input_files$edges)
  prior <- read_prior_matrix(
    input_files$prior_matrix,
    binarize = BINARIZE_PRIOR
  )

  assert_columns(
    nodes,
    c("global_id"),
    paste0(language, " nodes file")
  )
  assert_columns(
    edges,
    c("u", "v"),
    paste0(language, " edges file")
  )

  expertise_column <- pick_first_column(
    nodes,
    c(
      "expertise_z",
      "expertise_model_z",
      "expertise_z_shared"
    ),
    "standardized expertise"
  )

  leadership_column <- pick_first_column(
    nodes,
    c(
      "leadership_z",
      "leadership_model_z",
      "leadership_z_shared"
    ),
    "standardized leadership"
  )

  message("Expertise column: ", expertise_column)
  message("Leadership column: ", leadership_column)

  nodes$global_id <- clean_id(nodes$global_id)
  edges$u <- clean_id(edges$u)
  edges$v <- clean_id(edges$v)

  nodes <- nodes[
    !is.na(nodes$global_id) & nodes$global_id != "",
    ,
    drop = FALSE
  ]

  edges <- edges[
    !is.na(edges$u) & edges$u != "" &
      !is.na(edges$v) & edges$v != "" &
      edges$u != edges$v,
    ,
    drop = FALSE
  ]

  if (anyDuplicated(nodes$global_id) > 0L) {
    stop(
      paste0(language, " nodes file contains duplicated global_id values."),
      call. = FALSE
    )
  }

  if (nrow(nodes) < 2L) {
    stop("Fewer than two valid nodes remain.", call. = FALSE)
  }

  input_node_ids <- nodes$global_id
  input_number_of_nodes <- length(input_node_ids)

  unknown_edge_ids <- setdiff(
    unique(c(edges$u, edges$v)),
    input_node_ids
  )

  if (length(unknown_edge_ids) > 0L) {
    stop(
      paste0(
        language,
        " edges file contains IDs absent from its nodes file:\n",
        paste(head(unknown_edge_ids, 20L), collapse = ", ")
      ),
      call. = FALSE
    )
  }

  edge_low <- ifelse(edges$u < edges$v, edges$u, edges$v)
  edge_high <- ifelse(edges$u < edges$v, edges$v, edges$u)
  edge_key <- paste(edge_low, edge_high, sep = "\r")
  edges <- edges[!duplicated(edge_key), , drop = FALSE]

  if (!setequal(input_node_ids, rownames(prior))) {
    missing_in_prior <- setdiff(input_node_ids, rownames(prior))
    extra_in_prior <- setdiff(rownames(prior), input_node_ids)

    stop(
      paste0(
        language,
        " nodes and prior-matrix IDs do not match.\n",
        "Missing from prior: ",
        paste(head(missing_in_prior, 20L), collapse = ", "),
        "\nExtra in prior: ",
        paste(head(extra_in_prior, 20L), collapse = ", ")
      ),
      call. = FALSE
    )
  }

  prior <- prior[
    input_node_ids,
    input_node_ids,
    drop = FALSE
  ]

  if (nrow(edges) == 0L) {
    stop(
      "No valid observed edges remain after cleaning.",
      call. = FALSE
    )
  }

  observed_node_ids <- unique(c(edges$u, edges$v))
  removed_isolate_ids <- input_node_ids[
    !input_node_ids %in% observed_node_ids
  ]

  removed_isolates <- data.frame(
    language = rep(language, length(removed_isolate_ids)),
    global_id = removed_isolate_ids,
    reason = rep(
      "degree_zero_in_current_network",
      length(removed_isolate_ids)
    ),
    stringsAsFactors = FALSE
  )

  if (length(removed_isolate_ids) > 0L) {
    message(
      "Removing ",
      length(removed_isolate_ids),
      " current-network isolate(s) before ERGM estimation."
    )
  }

  nodes <- nodes[
    nodes$global_id %in% observed_node_ids,
    ,
    drop = FALSE
  ]

  if (nrow(nodes) < 2L) {
    stop(
      "Fewer than two non-isolate nodes remain.",
      call. = FALSE
    )
  }

  node_ids <- nodes$global_id
  prior <- prior[node_ids, node_ids, drop = FALSE]

  expertise_values <- suppressWarnings(
    as.numeric(nodes[[expertise_column]])
  )
  leadership_values <- suppressWarnings(
    as.numeric(nodes[[leadership_column]])
  )

  if (anyNA(expertise_values) ||
      any(!is.finite(expertise_values))) {
    stop(
      paste0(
        expertise_column,
        " contains missing or non-finite values."
      ),
      call. = FALSE
    )
  }

  if (anyNA(leadership_values) ||
      any(!is.finite(leadership_values))) {
    stop(
      paste0(
        leadership_column,
        " contains missing or non-finite values."
      ),
      call. = FALSE
    )
  }

  if (!is.finite(stats::sd(expertise_values)) ||
      stats::sd(expertise_values) == 0) {
    stop("The expertise covariate has zero variance.", call. = FALSE)
  }

  if (!is.finite(stats::sd(leadership_values)) ||
      stats::sd(leadership_values) == 0) {
    stop("The leadership covariate has zero variance.", call. = FALSE)
  }

  net <- network.initialize(
    n = nrow(nodes),
    directed = FALSE,
    loops = FALSE,
    multiple = FALSE
  )

  network.vertex.names(net) <- node_ids

  set.vertex.attribute(
    net,
    "expertise_model_z",
    expertise_values
  )

  set.vertex.attribute(
    net,
    "leadership_model_z",
    leadership_values
  )

  tail_index <- match(edges$u, node_ids)
  head_index <- match(edges$v, node_ids)

  if (length(tail_index) > 0L) {
    add.edges(
      net,
      tail = tail_index,
      head = head_index
    )
  }

  degree_values <- degree_from_edge_indices(
    tail_index,
    head_index,
    nrow(nodes)
  )

  if (any(degree_values == 0L)) {
    stop(
      sprintf(
        "The %s network contains %d isolate(s). Check its processed files.",
        language,
        sum(degree_values == 0L)
      ),
      call. = FALSE
    )
  }

  if (network.edgecount(net) != nrow(edges)) {
    stop(
      paste0(
        "Network edge count does not match the cleaned edge file.\n",
        "Network: ", network.edgecount(net),
        "; edge rows: ", nrow(edges)
      ),
      call. = FALSE
    )
  }

  current_matrix <- as.matrix.network.adjacency(net)
  upper <- upper.tri(current_matrix)

  current_prior_table <- as.data.frame.matrix(
    table(
      current_tie = factor(
        current_matrix[upper],
        levels = c(0, 1)
      ),
      prior_tie = factor(
        prior[upper],
        levels = c(0, 1)
      )
    )
  )
  current_prior_table$current_tie <- rownames(current_prior_table)
  rownames(current_prior_table) <- NULL
  current_prior_table$language <- language
  current_prior_table <- current_prior_table[
    c(
      "language",
      "current_tie",
      setdiff(
        names(current_prior_table),
        c("language", "current_tie")
      )
    )
  ]

  prior_edge_check <- data.frame(
    language = language,
    prior_matrix_dyads = sum(prior[upper] > 0),
    prior_edge_file_rows = NA_integer_,
    difference = NA_integer_,
    stringsAsFactors = FALSE
  )

  if (!is.na(input_files$prior_edges)) {
    prior_edges <- read_character_csv(input_files$prior_edges)
    prior_edge_check$prior_edge_file_rows <- nrow(prior_edges)
    prior_edge_check$difference <-
      prior_edge_check$prior_matrix_dyads -
      prior_edge_check$prior_edge_file_rows
  }

  # M0--M4 reproduce the original script. M5 is the requested model:
  # the original full specification plus geometrically weighted edgewise
  # shared partners (GWESP), with a fixed decay of 0.25.
  model_formulas <- list(
    m0_edges =
      net ~ edges,

    m1_prior =
      net ~
      edges +
      edgecov(prior),

    m2_prior_expertise =
      net ~
      edges +
      edgecov(prior) +
      nodecov("expertise_model_z"),

    m3_prior_expertise_similarity =
      net ~
      edges +
      edgecov(prior) +
      nodecov("expertise_model_z") +
      absdiff("expertise_model_z"),

    m4_full =
      net ~
      edges +
      edgecov(prior) +
      nodecov("expertise_model_z") +
      absdiff("expertise_model_z") +
      nodecov("leadership_model_z") +
      absdiff("leadership_model_z"),

    m5_full_gwesp =
      net ~
      edges +
      edgecov(prior) +
      nodecov("expertise_model_z") +
      absdiff("expertise_model_z") +
      nodecov("leadership_model_z") +
      absdiff("leadership_model_z") +
      gwesp(decay = GWESP_DECAY, fixed = GWESP_FIXED)
  )

  models <- list()

  for (model_name in names(model_formulas)) {
    message("Fitting ", language, " / ", model_name, " ...")
    models[[model_name]] <- fit_ergm_safe(
      model_formulas[[model_name]]
    )

    if (inherits(models[[model_name]], "ergm")) {
      message("[OK] ", language, " / ", model_name)
    } else {
      message(
        "[MODEL FAILED] ",
        language,
        " / ",
        model_name,
        ": ",
        conditionMessage(models[[model_name]])
      )
    }
  }

  coefficients_all <- do.call(
    rbind,
    lapply(names(models), function(model_name) {
      extract_coefficients(
        models[[model_name]],
        language,
        model_name
      )
    })
  )
  rownames(coefficients_all) <- NULL

  coefficients_gwesp <- coefficients_all[
    coefficients_all$model == "m5_full_gwesp",
    ,
    drop = FALSE
  ]

  model_fit <- do.call(
    rbind,
    lapply(names(models), function(model_name) {
      extract_fit(
        models[[model_name]],
        language,
        model_name
      )
    })
  )
  rownames(model_fit) <- NULL

  possible_dyads <- nrow(nodes) * (nrow(nodes) - 1) / 2

  network_summary <- data.frame(
    language = language,
    input_number_of_nodes = input_number_of_nodes,
    isolates_removed = length(removed_isolate_ids),
    number_of_nodes = nrow(nodes),
    number_of_edges = network.edgecount(net),
    possible_dyads = possible_dyads,
    density = network.edgecount(net) / possible_dyads,
    number_of_prior_dyads = sum(prior[upper] > 0),
    isolates = sum(degree_values == 0L),
    mean_degree = mean(degree_values),
    median_degree = stats::median(degree_values),
    max_degree = max(degree_values),
    expertise_column_used = expertise_column,
    leadership_column_used = leadership_column,
    expertise_mean = mean(expertise_values),
    expertise_sd = stats::sd(expertise_values),
    leadership_mean = mean(leadership_values),
    leadership_sd = stats::sd(leadership_values),
    estimation_method = ESTIMATION_METHOD,
    gwesp_decay = GWESP_DECAY,
    gwesp_fixed = GWESP_FIXED,
    nodes_file = normalizePath(
      input_files$nodes,
      mustWork = FALSE
    ),
    edges_file = normalizePath(
      input_files$edges,
      mustWork = FALSE
    ),
    prior_matrix_file = normalizePath(
      input_files$prior_matrix,
      mustWork = FALSE
    ),
    prior_edges_file = if (is.na(input_files$prior_edges)) {
      NA_character_
    } else {
      normalizePath(input_files$prior_edges, mustWork = FALSE)
    },
    script_version = SCRIPT_VERSION,
    stringsAsFactors = FALSE
  )

  saveRDS(
    models,
    file.path(
      LANGUAGE_OUTPUT_DIR,
      paste0(safe_language, "_ERGM_models.rds")
    )
  )

  write.csv(
    removed_isolates,
    file.path(
      LANGUAGE_OUTPUT_DIR,
      paste0(safe_language, "_removed_isolates.csv")
    ),
    row.names = FALSE
  )

  output_lines <- capture.output({
    cat(language, " separate ERGM M0--M5 with GWESP\n")
    cat("==========================================\n\n")
    cat("Script version:", SCRIPT_VERSION, "\n")
    cat("Language folder:", folder, "\n")
    cat("Estimation method:", ESTIMATION_METHOD, "\n")
    cat("GWESP term: gwesp(decay =", GWESP_DECAY,
        ", fixed =", GWESP_FIXED, ")\n")
    cat("Expertise column:", expertise_column, "\n")
    cat("Leadership column:", leadership_column, "\n\n")

    cat("Removed current-network isolates\n")
    print(removed_isolates)

    cat("Network summary\n")
    print(network_summary)

    cat("\nCurrent tie x prior tie\n")
    print(current_prior_table)

    cat("\nPrior-edge cross-check\n")
    print(prior_edge_check)

    for (model_name in names(models)) {
      cat(
        "\n\n---------------- ",
        model_name,
        " ----------------\n",
        sep = ""
      )

      fit <- models[[model_name]]

      if (inherits(fit, "ergm")) {
        print(
          extract_coefficients(
            fit,
            language,
            model_name
          )
        )
        cat(
          "AIC:",
          tryCatch(AIC(fit), error = function(e) NA_real_),
          "\n"
        )
        cat(
          "BIC:",
          tryCatch(BIC(fit), error = function(e) NA_real_),
          "\n"
        )
      } else {
        cat("FAILED:", conditionMessage(fit), "\n")
      }
    }
  })

  writeLines(
    output_lines,
    file.path(
      LANGUAGE_OUTPUT_DIR,
      paste0(safe_language, "_ERGM_output.txt")
    ),
    useBytes = TRUE
  )

  list(
    coefficients_all = coefficients_all,
    coefficients_gwesp = coefficients_gwesp,
    model_fit = model_fit,
    network_summary = network_summary,
    removed_isolates = removed_isolates,
    current_prior_table = current_prior_table,
    prior_edge_check = prior_edge_check
  )
}

# ----------------------------------------------------------------
# 4. Discover language folders and run them separately
# ----------------------------------------------------------------

language_folders <- list.dirs(
  ROOT_DIR,
  full.names = TRUE,
  recursive = FALSE
)

language_folders <- language_folders[
  normalizePath(language_folders, mustWork = FALSE) !=
    normalizePath(ROOT_DIR, mustWork = FALSE) &
    !grepl("^separate_results($|_)", basename(language_folders)) &
    !grepl("^\\.", basename(language_folders))
]

language_folders <- sort(language_folders)

if (length(language_folders) == 0L) {
  stop(
    paste0(
      "No language subfolders were found under:\n",
      ROOT_DIR,
      "\n\nCreate folders such as FullProject/Python/ and place ",
      "gh_nodes.csv, gh_edges.csv, and gh_prior_mat.csv inside."
    ),
    call. = FALSE
  )
}

message("\nROOT_DIR: ", ROOT_DIR)
message("OUTPUT_DIR: ", OUTPUT_DIR)
message(
  "Language folders found (",
  length(language_folders),
  "): ",
  paste(basename(language_folders), collapse = ", ")
)

coefficients_all_languages <- empty_coefficients()
coefficients_gwesp_all_languages <- empty_coefficients()
model_fit_all_languages <- empty_model_fit()
network_summary_all_languages <- empty_network_summary()
removed_isolates_all_languages <- empty_removed_isolates()
current_prior_all_languages <- data.frame()
prior_edge_check_all_languages <- data.frame()

for (folder in language_folders) {
  language <- basename(folder)

  result <- tryCatch(
    run_one_language(folder),
    error = function(e) e
  )

  if (inherits(result, "error")) {
    error_text <- conditionMessage(result)

    message(
      "\n[FOLDER FAILED] ",
      language,
      ": ",
      error_text
    )

    model_fit_all_languages <- rbind(
      model_fit_all_languages,
      data.frame(
        language = language,
        model = NA_character_,
        AIC = NA_real_,
        BIC = NA_real_,
        logLik = NA_real_,
        status = "folder_failed",
        error = error_text,
        stringsAsFactors = FALSE
      )
    )

    failed_summary <- empty_network_summary()
    failed_summary[1L, ] <- NA
    failed_summary$language <- language
    failed_summary$script_version <- SCRIPT_VERSION

    network_summary_all_languages <- rbind(
      network_summary_all_languages,
      failed_summary
    )

    next
  }

  coefficients_all_languages <- rbind(
    coefficients_all_languages,
    result$coefficients_all
  )

  coefficients_gwesp_all_languages <- rbind(
    coefficients_gwesp_all_languages,
    result$coefficients_gwesp
  )

  model_fit_all_languages <- rbind(
    model_fit_all_languages,
    result$model_fit
  )

  network_summary_all_languages <- rbind(
    network_summary_all_languages,
    result$network_summary
  )

  removed_isolates_all_languages <- rbind(
    removed_isolates_all_languages,
    result$removed_isolates
  )

  current_prior_all_languages <- rbind(
    current_prior_all_languages,
    result$current_prior_table
  )

  prior_edge_check_all_languages <- rbind(
    prior_edge_check_all_languages,
    result$prior_edge_check
  )
}

rownames(coefficients_all_languages) <- NULL
rownames(coefficients_gwesp_all_languages) <- NULL
rownames(model_fit_all_languages) <- NULL
rownames(network_summary_all_languages) <- NULL
rownames(removed_isolates_all_languages) <- NULL

failed_models <- model_fit_all_languages[
  model_fit_all_languages$status != "ok",
  ,
  drop = FALSE
]

# One row per GWESP attempt, plus folder-level failures, shows which
# languages were retained and which were skipped.
gwesp_status <- model_fit_all_languages[
  model_fit_all_languages$model == "m5_full_gwesp" |
    model_fit_all_languages$status == "folder_failed",
  ,
  drop = FALSE
]

# ----------------------------------------------------------------
# 5. Save combined tables
# ----------------------------------------------------------------

write.csv(
  coefficients_gwesp_all_languages,
  file.path(
    OUTPUT_DIR,
    "all_language_gwesp_coefficients.csv"
  ),
  row.names = FALSE
)

write.csv(
  coefficients_all_languages,
  file.path(
    OUTPUT_DIR,
    "all_language_all_model_coefficients.csv"
  ),
  row.names = FALSE
)

write.csv(
  model_fit_all_languages,
  file.path(
    OUTPUT_DIR,
    "all_language_model_fit.csv"
  ),
  row.names = FALSE
)

write.csv(
  gwesp_status,
  file.path(
    OUTPUT_DIR,
    "all_language_gwesp_status.csv"
  ),
  row.names = FALSE
)

write.csv(
  network_summary_all_languages,
  file.path(
    OUTPUT_DIR,
    "all_language_network_summary.csv"
  ),
  row.names = FALSE
)

write.csv(
  removed_isolates_all_languages,
  file.path(
    OUTPUT_DIR,
    "all_language_removed_isolates.csv"
  ),
  row.names = FALSE
)

write.csv(
  failed_models,
  file.path(
    OUTPUT_DIR,
    "all_language_failed_models.csv"
  ),
  row.names = FALSE
)

workbook <- openxlsx::createWorkbook()

run_settings <- data.frame(
  setting = c(
    "script_version",
    "root_directory",
    "estimation_method",
    "binarize_prior",
    "isolate_handling",
    "expertise_term",
    "leadership_term",
    "gwesp_decay",
    "gwesp_fixed",
    "model_sequence"
  ),
  value = c(
    SCRIPT_VERSION,
    normalizePath(ROOT_DIR, mustWork = FALSE),
    ESTIMATION_METHOD,
    as.character(BINARIZE_PRIOR),
    "Remove degree-zero nodes separately within each language; subset prior matrix to the same IDs",
    "Use existing within-language expertise_z (log1p then standardized by Python pipeline)",
    "Use existing within-language leadership_z (log1p follower count then standardized by Python pipeline)",
    as.character(GWESP_DECAY),
    as.character(GWESP_FIXED),
    "M0 edges; M1 + prior; M2 + expertise level; M3 + expertise absdiff; M4 + leadership level and absdiff; M5 + GWESP"
  ),
  stringsAsFactors = FALSE
)

write_sheet(
  workbook,
  "run_settings",
  run_settings
)

write_sheet(
  workbook,
  "coefficients_gwesp",
  coefficients_gwesp_all_languages
)

write_sheet(
  workbook,
  "coefficients_all_models",
  coefficients_all_languages
)

write_sheet(
  workbook,
  "model_fit",
  model_fit_all_languages
)

write_sheet(
  workbook,
  "gwesp_status",
  gwesp_status
)

write_sheet(
  workbook,
  "network_summary",
  network_summary_all_languages
)

write_sheet(
  workbook,
  "removed_isolates",
  removed_isolates_all_languages
)

write_sheet(
  workbook,
  "current_by_prior",
  current_prior_all_languages
)

write_sheet(
  workbook,
  "prior_edge_check",
  prior_edge_check_all_languages
)

write_sheet(
  workbook,
  "failed_models",
  failed_models
)

openxlsx::saveWorkbook(
  workbook,
  OUTPUT_XLSX,
  overwrite = TRUE
)

successful_languages <- unique(
  network_summary_all_languages$language[
    !is.na(network_summary_all_languages$number_of_nodes)
  ]
)

failed_languages <- unique(
  model_fit_all_languages$language[
    model_fit_all_languages$status == "folder_failed"
  ]
)

message("\n================================================")
message("All-language separate ERGM analysis with GWESP completed.")
message("Language folders found: ", length(language_folders))
message("Languages processed: ", length(successful_languages))
message("Folders failed: ", length(failed_languages))
message(
  "Successful models: ",
  sum(model_fit_all_languages$status == "ok", na.rm = TRUE)
)
message(
  "Failed models/folders: ",
  sum(model_fit_all_languages$status != "ok", na.rm = TRUE)
)
message("[SAVED] ", normalizePath(OUTPUT_DIR, mustWork = FALSE))
message("Combined workbook: ", OUTPUT_XLSX)
