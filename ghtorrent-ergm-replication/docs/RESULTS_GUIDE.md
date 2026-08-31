# Results guide

## Archived aggregate model tables

| File | Contents |
| --- | --- |
| `results/model_fits/separate_m0_m4/coefficients_m4.csv` | Coefficients, standard errors, Wald p values, odds ratios, and confidence intervals for the 10 separate M4 models. |
| `results/model_fits/separate_m0_m4/coefficients_all_models.csv` | Corresponding output for M0--M4. |
| `results/model_fits/separate_m0_m4/model_fit.csv` | AIC, BIC, log-likelihood, and run status for the separate models. |
| `results/model_fits/separate_m0_m4/network_summary.csv` | Aggregate network and covariate summaries, with local paths removed. |
| `results/model_fits/block_m0_m4/coefficients_m4.csv` | Coefficients for the pooled block-diagonal M4 model. |
| `results/model_fits/block_m0_m4/coefficients_all_models.csv` | Corresponding output for the pooled M0--M4 models. |
| `results/model_fits/block_m0_m4/model_fit.csv` | AIC, BIC, log-likelihood, and run status for the pooled models. |
| `results/model_fits/block_m0_m4/network_summary.csv` | Journal-level block summaries, with local paths removed. |

## Goodness-of-fit archive

`results/diagnostics/m4_gof/gof_statistics.csv` preserves the supplied GOF summaries for the ten separate M4 models. `run_log.csv` records their successful completion and the supplied pooled block-diagonal GOF attempt, which failed with a 16 GB vector-memory limit. This status is retained for transparency; it should not be represented as a completed pooled GOF result. The corresponding ten separate-model diagnostic PDFs are in `figures/diagnostics/m4_gof/separate/`.

## Figures

`figures/main_text/figure_sciscinet_m4_prior_forest.png` displays the separate-journal prior-collaboration estimates and the pooled block-diagonal estimate. `figure_sciscinet_m4_covariate_heatmap.png` displays the four non-prior M4 covariates for the separate models.

Both figures can be reproduced byte-for-byte from the included CSV tables with `scripts/04_make_main_figures.py` in the Python environment recorded in `environment/requirements-python.txt`.
