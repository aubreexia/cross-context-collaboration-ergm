# Script order

Run the scripts in numerical order:

1. `01_fit_separate_m0_m4.R` validates each journal and fits the separate models.
2. `02_fit_block_m0_m4.R` validates the same inputs and fits the pooled block-diagonal models.
3. `03_run_m4_gof.R` reads the saved `m4_full` model objects and runs GOF diagnostics. It skips the high-memory pooled GOF unless explicitly enabled.
4. `04_make_main_figures.py` generates the two publication figures from the aggregate M4 coefficient tables.
5. `05_verify_archived_results.py` compares a fresh run with the archived coefficient tables.

The R scripts use only base R plus `network`, `ergm`, and `openxlsx`. The Python figure and verification scripts use the packages in `../environment/requirements-python.txt`.

For reproducibility, set the documented `SCISCINET_*` environment variables instead of editing paths inside the scripts.
