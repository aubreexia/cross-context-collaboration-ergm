# GHTorrent/GitHub ERGM materials

This folder contains the public replication materials for the open-source portion of the cross-context collaboration study. The networks represent ten programming-language communities in April 2020: C, C++, CSS, HTML, Java, JavaScript, Jupyter Notebook, Python, Ruby, and TypeScript.

## Contents

| Location | Purpose |
| --- | --- |
| `scripts/01_fit_separate_m0_m5_gwesp.R` | Fits separate M0--M5 ERGMs for every language. M5 adds fixed-decay GWESP. |
| `results/model_fits/` | Sanitized aggregate coefficients, model fit, GOF status, and network/block summaries. |
| `results/diagnostics/` | GOF completion-status table. |
| `figures/diagnostics/` | Supplied M4 and M5 GOF PDFs, PNGs, and text summaries for the block model and all separate language networks. |
| `data/README.md` | Required processed-file interface and public-release restrictions. |

## Input interface and analysis

For each language, place these files in one immediate language folder below `GHTORRENT_INPUT_DIR`:

```text
<language>/
  gh_nodes.csv
  gh_edges.csv
  gh_prior_mat.csv
```

`gh_nodes.csv` must include `global_id`, plus within-language standardized columns `expertise_z` and `leadership_z` (the script also accepts its documented fallback column names). `gh_edges.csv` must include undirected current-period endpoints `u` and `v`. `gh_prior_mat.csv` must be a square, symmetric prior-collaboration matrix keyed by `global_id`.

The script removes current-network isolates, subsets the prior matrix to the modeled nodes, fits M0--M5 with MLE, writes aggregate results, and records any model failure without stopping the remaining language analyses. M4 is the primary specification. M5 is a robustness check with `gwesp(decay = 0.25, fixed = TRUE)`.

Run from this directory:

```bash
GHTORRENT_INPUT_DIR=data/processed/languages \
GHTORRENT_OUTPUT_DIR=results/recomputed/separate_m0_m5 \
Rscript scripts/01_fit_separate_m0_m5_gwesp.R
```

The archived result tables in this repository are sanitized and are suitable for reproducing reported summaries; they do not contain contributor-level data.

## GOF and archived results

The supplied diagnostics cover M4 and M5 for each of the 10 separate language networks and for the pooled block-diagonal language network, each using 100 simulations. The archived block fit uses 2,582 modeled contributors and 16,447 within-language ties across the 10 language blocks. Diagnostic files are presentation materials, not model inputs.

The original block-diagonal fitting script was not among the provided files. Sanitized pooled M0--M5 aggregate coefficients and model-fit tables are in `results/model_fits/`; add the fitting script before the final public DOI release if you intend to claim end-to-end code reproducibility for that pooled model.
