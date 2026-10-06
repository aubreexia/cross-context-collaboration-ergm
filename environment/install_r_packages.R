# Install the R packages needed by scripts/r/. Run once in a clean R library.
required <- c("network", "ergm", "openxlsx", "metafor")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0L) {
  install.packages(missing, repos = "https://cloud.r-project.org")
}
message("R dependencies are installed.")
