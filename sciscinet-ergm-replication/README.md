# SciSciNet ERGM replication materials

This repository contains the analysis code, sanitized aggregate outputs, goodness-of-fit (GOF) diagnostics, and publication figures for the SciSciNet portion of a cross-context study of collaboration tie formation.

The package estimates five nested undirected ERGMs (M0--M4) for 10 scientific-journal coauthorship networks, as well as a pooled block-diagonal ERGM that excludes cross-journal dyads. The primary model is M4.

## Contents

| Location | Purpose |
| --- | --- |
| `scripts/01_fit_separate_m0_m4.R` | Fits M0--M4 separately for every journal. |
| `scripts/02_fit_block_m0_m4.R` | Fits the pooled block-diagonal M0--M4 models. |
| `scripts/03_run_m4_gof.R` | Runs M4 GOF diagnostics from saved ERGM objects. |
| `scripts/04_make_main_figures.py` | Recreates the two main-text PNG figures. |
| `scripts/05_verify_archived_results.py` | Compares a fresh model run with the archived coefficient tables. |
| `data/` | Input-data interface and source-data instructions; no author-level data are tracked in Git. |
| `results/` | Sanitized, aggregate model outputs and supplied GOF summaries. |
| `figures/main_text/` | Publication-ready figures generated from the archived M4 tables. |
| `docs/` | Model specification, data codebook, output guide, and manuscript-ready availability language. |

## Analysis scope

The analysis uses ten journal networks: *Cell*, *Geology*, *Journal of the ACM*, *Management Science*, *Mind*, *Nature Climate Change*, *Nature Materials*, *Psychological Science*, *The Economic Journal*, and *The New England Journal of Medicine*.

The models include prior collaboration, standardized expertise, standardized leadership/status, and absolute differences in the latter two attributes. M0--M4 are dyad-independent and are estimated with exact maximum likelihood. The block model uses `blockdiag("block_id")` to restrict the risk set to within-journal dyads.

Detailed formulas are in [docs/MODEL_SPECIFICATION.md](docs/MODEL_SPECIFICATION.md).

## Quick start

Install R packages:

```r
install.packages(c("network", "ergm", "openxlsx"))
```

Install Python packages:

```bash
python3 -m pip install -r environment/requirements-python.txt
```

Obtain the processed SciSciNet input folders described in [data/README.md](data/README.md), then run from the repository root:

```bash
SCISCINET_INPUT_DIR=data/processed/journals \
SCISCINET_OUTPUT_DIR=results/recomputed/separate_m0_m4 \
Rscript scripts/01_fit_separate_m0_m4.R

SCISCINET_INPUT_DIR=data/processed/journals \
SCISCINET_OUTPUT_DIR=results/recomputed/block_m0_m4 \
Rscript scripts/02_fit_block_m0_m4.R
```

Run M4 GOF for the separate models (100 simulations by default):

```bash
SCISCINET_SEPARATE_MODELS_DIR=results/recomputed/separate_m0_m4/journal_outputs \
SCISCINET_GOF_OUTPUT_DIR=results/recomputed/m4_gof \
SCISCINET_GOF_NSIM=100 \
Rscript scripts/03_run_m4_gof.R
```

The pooled GOF is deliberately opt-in because the supplied archived attempt exceeded a 16 GB vector-memory limit. To attempt it on a high-memory machine, also set `SCISCINET_RUN_BLOCK_GOF=true` and `SCISCINET_BLOCK_MODELS_RDS`.

Recreate the included figures directly from the archived aggregate results:

```bash
python3 scripts/04_make_main_figures.py \
  --separate results/model_fits/separate_m0_m4/coefficients_m4.csv \
  --block results/model_fits/block_m0_m4/coefficients_m4.csv \
  --output-dir figures/main_text
```

## Reproducibility and data availability

This repository does not redistribute raw or author-level SciSciNet records. The source data are publicly available from SciSciNet; see [data/README.md](data/README.md) for the source citation and the exact processed-file interface expected by the scripts.

The `results/` directory contains only aggregate numerical output, diagnostics, and figures. It deliberately excludes workstation paths, per-author input tables, model-object RDS files, and verbose console logs. Fresh outputs belong in `results/recomputed/`, which is ignored by Git.

Before creating a DOI release, run `scripts/00_capture_session_info.R` after installing the final R environment and commit the resulting session information. Then use `scripts/05_verify_archived_results.py` to compare fresh estimates with the archived tables.

## Citation

If you use this package, cite the associated manuscript and the SciSciNet data source. Repository citation metadata are in [CITATION.cff](CITATION.cff). Update the title, contributor list, and DOI fields before creating the final public release.

## License

Code in this repository is available under the [MIT License](LICENSE). The SciSciNet data retain their original terms and citation requirements.
