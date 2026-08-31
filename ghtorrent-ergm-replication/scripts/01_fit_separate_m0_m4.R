# ================================================================
# Batch SciSciNet separate ERGM analysis: M0--M4, exact MLE
#
# Default layout: place this script directly inside the directory that
# contains one subdirectory per journal. For the repository layout, keep
# the script in scripts/ and set SCISCINET_INPUT_DIR and
# SCISCINET_OUTPUT_DIR before running it (see ../README.md).
#
# FullJournal/
#   run_all_journal_separate_ergm.R
#   Mind/
#     Mind_nodes.csv
#     Mind_edges.csv
#     Mind_prior_mat.csv
#     Mind_prior_edges.csv        # optional cross-check file
#   Nature/
#     Nature_nodes.csv
#     Nature_edges.csv
#     Nature_prior_mat.csv
#     Nature_prior_edges.csv
#   ...
#
# The script scans every non-hidden immediate subfolder of FullJournal,
# fits M0--M4 separately for each journal, and writes all outputs to:
#
# FullJournal/separate_results_m0_m4_mle/
#   all_journal_ergm_results.xlsx
#   all_journal_M4_coefficients.csv
#   all_journal_all_model_coefficients.csv
#   all_journal_model_fit.csv
#   all_journal_network_summary.csv
#   all_journal_failed_models.csv
#   journal_outputs/
#     Mind_ERGM_models.rds
#     Mind_ERGM_output.txt
#     ...
#
# The Excel sheet "coefficients_M4" contains every journal's M4
# coefficients in one table. A failure in one journal is recorded and
# does not stop the remaining journals.
#
# The nodes files are expected to contain already log-transformed and
# standardized expertise/leadership variables. This script uses their
# z-score columns directly and does not transform them again.
# ================================================================

SCRIPT_VERSION <- "SciSciNet separate ERGM M0--M4 MLE 2026-08-31 v1.1"
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
  # FullJournal before sourcing the script if neither method above applies.
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
  file.path(ROOT_DIR, "separate_results_m0_m4_mle")
}
JOURNAL_OUTPUT_DIR <- file.path(OUTPUT_DIR, "journal_outputs")

OUTPUT_XLSX <- file.path(
  OUTPUT_DIR,
  "all_journal_ergm_results.xlsx"
)

BINARIZE_PRIOR <- TRUE

# M0--M4 contain only dyad-independent terms. For these models, ergm
# obtains the exact MLE without the MCMLE iterations required by GWESP.
ESTIMATION_METHOD <- "MLE"

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

dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(JOURNAL_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

# ----------------------------------------------------------------
# 2. General helper functions
# ----------------------------------------------------------------

empty_coefficients <- function() {
  data.frame(
    journal = character(),
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
    journal = character(),
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
    journal = character(),
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
    nodes_file = character(),
    edges_file = character(),
    prior_matrix_file = character(),
    prior_edges_file = character(),
    script_version = character(),
    stringsAsFactors = FALSE
  )
}

clean_id <- function(x) {
  trimws(as.character(x))
}

safe_file_name <- function(x) {
  result <- gsub("[^A-Za-z0-9._-]+", "_", x)
  result <- gsub("^_+|_+$", "", result)
  ifelse(result == "", "journal", result)
}

relative_to_root <- function(path, root = ROOT_DIR) {
  path_normalized <- normalizePath(path, mustWork = FALSE)
  root_normalized <- normalizePath(root, mustWork = FALSE)
  root_prefix <- paste0(root_normalized, .Platform$file.sep)

  if (identical(path_normalized, root_normalized)) {
    return(".")
  }

  if (startsWith(path_normalized, root_prefix)) {
    return(substr(
      path_normalized,
      nchar(root_prefix) + 1L,
      nchar(path_normalized)
    ))
  }

  path_normalized
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

find_one_input_file <- function(
  folder,
  include_pattern,
  label,
  exclude_pattern = NULL,
  required = TRUE
) {
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
      !grepl(
        exclude_pattern,
        basename(candidates),
        ignore.case = TRUE
      )
    ]
  }

  # Do not reuse files from an old results folder if one exists inside
  # a journal directory.
  if (length(candidates) > 0L) {
    normalized_output <- normalizePath(
      OUTPUT_DIR,
      mustWork = FALSE
    )
    normalized_candidates <- normalizePath(
      candidates,
      mustWork = FALSE
    )
    candidates <- candidates[
      !startsWith(normalized_candidates, normalized_output)
    ]
  }

  if (length(candidates) == 0L) {
    if (required) {
      stop(
        sprintf(
          "Missing %s in folder: %s",
          label,
          basename(folder)
        ),
        call. = FALSE
      )
    }
    return(NA_character_)
  }

  if (length(candidates) > 1L) {
    stop(
      paste0(
        "Found multiple possible ", label, " files in folder ",
        basename(folder), ":\n- ",
        paste(candidates, collapse = "\n- "),
        "\nKeep exactly one analysis dataset in each journal folder."
      ),
      call. = FALSE
    )
  }

  candidates[[1L]]
}

discover_input_files <- function(folder) {
  list(
    nodes = find_one_input_file(
      folder,
      "_nodes\\.csv$",
      "*_nodes.csv"
    ),
    edges = find_one_input_file(
      folder,
      "_edges\\.csv$",
      "*_edges.csv",
      exclude_pattern = "_prior_edges\\.csv$"
    ),
    prior_matrix = find_one_input_file(
      folder,
      "_prior_mat\\.csv$",
      "*_prior_mat.csv"
    ),
    prior_edges = find_one_input_file(
      folder,
      "_prior_edges\\.csv$",
      "*_prior_edges.csv",
      required = FALSE
    )
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
      estimate = ESTIMATION_METHOD
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

extract_coefficients <- function(fit, journal, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      journal = journal,
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
    journal = journal,
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

extract_fit <- function(fit, journal, model_name) {
  if (!inherits(fit, "ergm")) {
    return(data.frame(
      journal = journal,
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
    journal = journal,
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
# 3. Fit all five models for one journal folder
# ----------------------------------------------------------------

run_one_journal <- function(folder) {
  journal <- basename(folder)
  safe_journal <- safe_file_name(journal)

  message("\n================================================")
  message("Journal: ", journal)
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
    paste0(journal, " nodes file")
  )
  assert_columns(
    edges,
    c("u", "v"),
    paste0(journal, " edges file")
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
      paste0(journal, " nodes file contains duplicated global_id values."),
      call. = FALSE
    )
  }

  if (nrow(nodes) < 2L) {
    stop("Fewer than two valid nodes remain.", call. = FALSE)
  }

  node_ids <- nodes$global_id

  unknown_edge_ids <- setdiff(
    unique(c(edges$u, edges$v)),
    node_ids
  )

  if (length(unknown_edge_ids) > 0L) {
    stop(
      paste0(
        journal,
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

  if (!setequal(node_ids, rownames(prior))) {
    missing_in_prior <- setdiff(node_ids, rownames(prior))
    extra_in_prior <- setdiff(rownames(prior), node_ids)

    stop(
      paste0(
        journal,
        " nodes and prior-matrix IDs do not match.\n",
        "Missing from prior: ",
        paste(head(missing_in_prior, 20L), collapse = ", "),
        "\nExtra in prior: ",
        paste(head(extra_in_prior, 20L), collapse = ", ")
      ),
      call. = FALSE
    )
  }

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
        journal,
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
  current_prior_table$journal <- journal
  current_prior_table <- current_prior_table[
    c(
      "journal",
      "current_tie",
      setdiff(
        names(current_prior_table),
        c("journal", "current_tie")
      )
    )
  ]

  prior_edge_check <- data.frame(
    journal = journal,
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
      absdiff("leadership_model_z")
  )

  models <- list()

  for (model_name in names(model_formulas)) {
    message("Fitting ", journal, " / ", model_name, " ...")
    models[[model_name]] <- fit_ergm_safe(
      model_formulas[[model_name]]
    )

    if (inherits(models[[model_name]], "ergm")) {
      message("[OK] ", journal, " / ", model_name)
    } else {
      message(
        "[MODEL FAILED] ",
        journal,
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
        journal,
        model_name
      )
    })
  )
  rownames(coefficients_all) <- NULL

  coefficients_m4 <- coefficients_all[
    coefficients_all$model == "m4_full",
    ,
    drop = FALSE
  ]

  model_fit <- do.call(
    rbind,
    lapply(names(models), function(model_name) {
      extract_fit(
        models[[model_name]],
        journal,
        model_name
      )
    })
  )
  rownames(model_fit) <- NULL

  possible_dyads <- nrow(nodes) * (nrow(nodes) - 1) / 2

  network_summary <- data.frame(
    journal = journal,
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
    nodes_file = relative_to_root(input_files$nodes),
    edges_file = relative_to_root(input_files$edges),
    prior_matrix_file = relative_to_root(input_files$prior_matrix),
    prior_edges_file = if (is.na(input_files$prior_edges)) {
      NA_character_
    } else {
      relative_to_root(input_files$prior_edges)
    },
    script_version = SCRIPT_VERSION,
    stringsAsFactors = FALSE
  )

  saveRDS(
    models,
    file.path(
      JOURNAL_OUTPUT_DIR,
      paste0(safe_journal, "_ERGM_models.rds")
    )
  )

  output_lines <- capture.output({
    cat(journal, " separate ERGM M0--M4\n")
    cat("===============================\n\n")
    cat("Script version:", SCRIPT_VERSION, "\n")
    cat("Journal folder:", folder, "\n")
    cat("Estimation method:", ESTIMATION_METHOD, "\n")
    cat("Expertise column:", expertise_column, "\n")
    cat("Leadership column:", leadership_column, "\n\n")

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
            journal,
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
      JOURNAL_OUTPUT_DIR,
      paste0(safe_journal, "_ERGM_output.txt")
    ),
    useBytes = TRUE
  )

  list(
    coefficients_all = coefficients_all,
    coefficients_m4 = coefficients_m4,
    model_fit = model_fit,
    network_summary = network_summary,
    current_prior_table = current_prior_table,
    prior_edge_check = prior_edge_check
  )
}

# ----------------------------------------------------------------
# 4. Discover journal folders and run them separately
# ----------------------------------------------------------------

journal_folders <- list.dirs(
  ROOT_DIR,
  full.names = TRUE,
  recursive = FALSE
)

journal_folders <- journal_folders[
  normalizePath(journal_folders, mustWork = FALSE) !=
    normalizePath(ROOT_DIR, mustWork = FALSE) &
    basename(journal_folders) != basename(OUTPUT_DIR) &
    !grepl("^\\.", basename(journal_folders))
]

journal_folders <- sort(journal_folders)

if (length(journal_folders) == 0L) {
  stop(
    paste0(
      "No journal subfolders were found under:\n",
      ROOT_DIR,
      "\n\nCreate folders such as FullJournal/Mind/ and place the ",
      "four Mind CSV files inside."
    ),
    call. = FALSE
  )
}

message("\nROOT_DIR: ", ROOT_DIR)
message("OUTPUT_DIR: ", OUTPUT_DIR)
message(
  "Journal folders found (",
  length(journal_folders),
  "): ",
  paste(basename(journal_folders), collapse = ", ")
)

coefficients_all_journals <- empty_coefficients()
coefficients_m4_all_journals <- empty_coefficients()
model_fit_all_journals <- empty_model_fit()
network_summary_all_journals <- empty_network_summary()
current_prior_all_journals <- data.frame()
prior_edge_check_all_journals <- data.frame()

for (folder in journal_folders) {
  journal <- basename(folder)

  result <- tryCatch(
    run_one_journal(folder),
    error = function(e) e
  )

  if (inherits(result, "error")) {
    error_text <- conditionMessage(result)

    message(
      "\n[FOLDER FAILED] ",
      journal,
      ": ",
      error_text
    )

    model_fit_all_journals <- rbind(
      model_fit_all_journals,
      data.frame(
        journal = journal,
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
    failed_summary$journal <- journal
    failed_summary$script_version <- SCRIPT_VERSION

    network_summary_all_journals <- rbind(
      network_summary_all_journals,
      failed_summary
    )

    next
  }

  coefficients_all_journals <- rbind(
    coefficients_all_journals,
    result$coefficients_all
  )

  coefficients_m4_all_journals <- rbind(
    coefficients_m4_all_journals,
    result$coefficients_m4
  )

  model_fit_all_journals <- rbind(
    model_fit_all_journals,
    result$model_fit
  )

  network_summary_all_journals <- rbind(
    network_summary_all_journals,
    result$network_summary
  )

  current_prior_all_journals <- rbind(
    current_prior_all_journals,
    result$current_prior_table
  )

  prior_edge_check_all_journals <- rbind(
    prior_edge_check_all_journals,
    result$prior_edge_check
  )
}

rownames(coefficients_all_journals) <- NULL
rownames(coefficients_m4_all_journals) <- NULL
rownames(model_fit_all_journals) <- NULL
rownames(network_summary_all_journals) <- NULL

failed_models <- model_fit_all_journals[
  model_fit_all_journals$status != "ok",
  ,
  drop = FALSE
]

# ----------------------------------------------------------------
# 5. Save combined tables
# ----------------------------------------------------------------

write.csv(
  coefficients_m4_all_journals,
  file.path(
    OUTPUT_DIR,
    "all_journal_M4_coefficients.csv"
  ),
  row.names = FALSE
)

write.csv(
  coefficients_all_journals,
  file.path(
    OUTPUT_DIR,
    "all_journal_all_model_coefficients.csv"
  ),
  row.names = FALSE
)

write.csv(
  model_fit_all_journals,
  file.path(
    OUTPUT_DIR,
    "all_journal_model_fit.csv"
  ),
  row.names = FALSE
)

write.csv(
  network_summary_all_journals,
  file.path(
    OUTPUT_DIR,
    "all_journal_network_summary.csv"
  ),
  row.names = FALSE
)

write.csv(
  failed_models,
  file.path(
    OUTPUT_DIR,
    "all_journal_failed_models.csv"
  ),
  row.names = FALSE
)

workbook <- openxlsx::createWorkbook()

write_sheet(
  workbook,
  "coefficients_M4",
  coefficients_m4_all_journals
)

write_sheet(
  workbook,
  "coefficients_all_models",
  coefficients_all_journals
)

write_sheet(
  workbook,
  "model_fit",
  model_fit_all_journals
)

write_sheet(
  workbook,
  "network_summary",
  network_summary_all_journals
)

write_sheet(
  workbook,
  "current_by_prior",
  current_prior_all_journals
)

write_sheet(
  workbook,
  "prior_edge_check",
  prior_edge_check_all_journals
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

successful_journals <- unique(
  network_summary_all_journals$journal[
    !is.na(network_summary_all_journals$number_of_nodes)
  ]
)

failed_journals <- unique(
  model_fit_all_journals$journal[
    model_fit_all_journals$status == "folder_failed"
  ]
)

message("\n================================================")
message("All-journal separate ERGM analysis completed.")
message("Journal folders found: ", length(journal_folders))
message("Journals processed: ", length(successful_journals))
message("Folders failed: ", length(failed_journals))
message(
  "Successful models: ",
  sum(model_fit_all_journals$status == "ok", na.rm = TRUE)
)
message(
  "Failed models/folders: ",
  sum(model_fit_all_journals$status != "ok", na.rm = TRUE)
)
message("[SAVED] ", normalizePath(OUTPUT_DIR, mustWork = FALSE))
message("Combined workbook: ", OUTPUT_XLSX)
