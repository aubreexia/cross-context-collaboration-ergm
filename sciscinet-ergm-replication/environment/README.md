# Computational environment

The archived figures were recreated with Python 3.12.13 and the exact packages in `requirements-python.txt`.

The supplied GOF PDFs identify R 4.5.3 as their graphics producer. The supplied R execution records did not retain a complete package lockfile. Install the packages listed in `requirements-r.txt`, run `scripts/00_capture_session_info.R` in the final environment, and commit the resulting `session_info.txt` before minting a DOI release. This avoids claiming package versions that were not recorded during the original run.
