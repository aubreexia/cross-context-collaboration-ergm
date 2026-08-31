# Archived GHTorrent aggregate results

These CSV files contain aggregate model estimates and diagnostics only. Absolute workstation paths were replaced with the portable placeholder `data/processed/languages/`.

- `model_fits/all_language_all_model_coefficients.csv`: M0--M5 coefficient estimates for separate language networks.
- `model_fits/all_language_gwesp_coefficients.csv`: M5-only coefficient estimates.
- `model_fits/all_language_model_fit.csv`: AIC, BIC, and log likelihood by model and language.
- `model_fits/all_language_gwesp_status.csv`: M5 completion status.
- `model_fits/all_language_network_summary.csv`: aggregate network summaries.
- `model_fits/language_block_summary.csv`: aggregate inputs used in the archived pooled block model.
- `model_fits/block_m0_m5_coefficients*.csv` and `block_m0_m5_model_fit.csv`: aggregate estimates and fit statistics for the archived pooled M0--M5 models.
- `diagnostics/gof_status.csv`: M4/M5 GOF completion status.

The original pooled fitting script was not among the provided files. Add it before final release if complete rerun reproducibility is required.
