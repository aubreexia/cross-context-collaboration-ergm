# ============================================================================
# MyDreamTeam pooled M5-D GWDEGREE: final constrained GOF = ~model
#
# Run this only after 10_fit_mydreamteam_block_m5d_gwdegree.R has finished
# successfully.  It does not refit the ERGM; it evaluates the final M5-D fit
# using the same stored block-diagonal constraint.
#
# The fitted model has exactly one shared `edges` density parameter across the
# ten sessions.  Cross-session dyads remain excluded by blockdiag(block_id).
# ============================================================================

SCRIPT_VERSION <- "MDT pooled M5-D GWDEGREE high-precision final model GOF, 2026-10-08 v1"

get_script_dir <- function() {
  command_arguments <- commandArgs(trailingOnly = FALSE)
  script_argument <- grep("^--file=", command_arguments, value = TRUE)
  if (length(script_argument) > 0L) {
    return(dirname(normalizePath(
      sub("^--file=", "", script_argument[[1L]]),
      mustWork = TRUE
    )))
  }
  normalizePath(getwd(), mustWork = TRUE)
}

command_arguments <- commandArgs(trailingOnly = TRUE)
if (length(command_arguments) > 1L) {
  stop("Use at most one argument: the MDT session-data root directory.", call. = FALSE)
}
ROOT_DIR <- if (length(command_arguments) == 1L) {
  normalizePath(command_arguments[[1L]], mustWork = TRUE)
} else {
  get_script_dir()
}

# These controls affect only the simulations used to evaluate GOF. They do
# not change model coefficients or the shared-density specification.
GOF_NSIM <- 500L
GOF_MCMC_BURNIN <- 1000000L
GOF_MCMC_INTERVAL <- 65536L
GOF_SEED <- 20261008L

MODEL_DIR <- file.path(
  ROOT_DIR,
  "results",
  "03_block_m5_gwdegree_decay050_highprecision"
)
BLOCK_MODEL_DIR <- file.path(MODEL_DIR, "block_diagonal")
M5_RDS <- file.path(BLOCK_MODEL_DIR, "M5_gwdegree_block_diagonal.rds")
NETWORK_RDS <- file.path(BLOCK_MODEL_DIR, "pooled_block_network.rds")
PRIOR_RDS <- file.path(BLOCK_MODEL_DIR, "prior_big.rds")
OUTPUT_DIR <- file.path(
  ROOT_DIR,
  "results",
  "gof_mdt_block_m5_gwdegree_highprecision_model"
)
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

required_packages <- c("network", "ergm")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0L) {
  stop(
    "Missing required R package(s): ",
    paste(missing_packages, collapse = ", "),
    call. = FALSE
  )
}
suppressPackageStartupMessages({
  library(network)
  library(ergm)
})

for (file_name in c(M5_RDS, NETWORK_RDS, PRIOR_RDS)) {
  if (!file.exists(file_name)) {
    stop(
      "A required high-precision M5-D output is missing: ",
      file_name,
      "\nRun the high-precision refit first and confirm m5_gwdegree_status.csv.",
      call. = FALSE
    )
  }
}

message("Running: ", SCRIPT_VERSION)
message("ROOT_DIR: ", ROOT_DIR)
message("M5 RDS: ", M5_RDS)
message("Output: ", OUTPUT_DIR)
message(
  "GOF: ~model; nsim = ", GOF_NSIM,
  "; MCMC.burnin = ", GOF_MCMC_BURNIN,
  "; MCMC.interval = ", GOF_MCMC_INTERVAL
)

# The fitted formula refers to these objects when simulating. Restoring them
# before readRDS()/gof() makes the GOF run independent of the original
# fitting session.
net_big <- readRDS(NETWORK_RDS)
prior_big <- readRDS(PRIOR_RDS)
block_constraint <- ~ blockdiag("block_id")
GWDEGREE_DECAY <- 0.50
m5_formula <-
  net_big ~
  edges +
  edgecov(prior_big) +
  nodecov("expertise_model_z") +
  absdiff("expertise_model_z") +
  nodecov("leadership_model_z") +
  absdiff("leadership_model_z") +
  gwdegree(GWDEGREE_DECAY, fixed = TRUE)
assign("net_big", net_big, envir = .GlobalEnv)
assign("prior_big", prior_big, envir = .GlobalEnv)
assign("block_constraint", block_constraint, envir = .GlobalEnv)
assign("GWDEGREE_DECAY", GWDEGREE_DECAY, envir = .GlobalEnv)
assign("m5_formula", m5_formula, envir = .GlobalEnv)

m5_fit <- readRDS(M5_RDS)
if (!inherits(m5_fit, "ergm")) {
  stop("M5_gwdegree_block_diagonal.rds is not a successful ergm fit.", call. = FALSE)
}

expected_terms <- c(
  "edges",
  "edgecov.prior_big",
  "nodecov.expertise_model_z",
  "absdiff.expertise_model_z",
  "nodecov.leadership_model_z",
  "absdiff.leadership_model_z",
  "gwdeg.fixed.0.5"
)
if (!setequal(names(stats::coef(m5_fit)), expected_terms)) {
  stop(
    "The saved fit does not match the expected shared-density M5-D formula. Terms found: ",
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
  con = file.path(OUTPUT_DIR, "m5_gwdegree_model_gof.txt")
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
message("Inspect m5_gwdegree_model_gof.txt before interpreting the M5-D coefficient table.")
