# Save the exact R and package versions used for a replication run.

output_file <- Sys.getenv("SCISCINET_SESSION_INFO_OUTPUT", unset = "session_info.txt")
output_file <- normalizePath(output_file, mustWork = FALSE)
dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)

lines <- c(
  paste("Captured:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
  "",
  capture.output(sessionInfo())
)
writeLines(lines, output_file)
message("[SAVED] ", output_file)
