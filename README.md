# Cross-Context ERGM Replication Materials

This repository accompanies a study of collaboration tie formation across three settings: classroom teams (MyDreamTeam), open-source development (GHTorrent/GitHub), and scientific coauthorship (SciSciNet). It provides the analysis code available for public release, sanitized aggregate estimates, goodness-of-fit (GOF) materials, and figures. It does **not** redistribute person-level network data, source databases, model-object files, or run logs.

## Study design

The analysis asks whether future collaboration is associated with prior collaboration, expertise, and leadership/status across distinct collaboration settings. For each context, we estimate separate ERGMs for each network and a pooled block-diagonal ERGM. Cross-network dyads are excluded from pooled models with `blockdiag("block_id")`.

| Context | Networks | Primary model | Public materials |
| --- | --- | --- | --- |
| MyDreamTeam | Classroom/team sessions | M4 | Analysis scripts and aggregate outputs will be added after data-sharing review. Raw participant data are restricted. |
| GHTorrent/GitHub | 10 programming-language networks | M4; M5 (GWESP) robustness check | `contexts/ghtorrent/` |
| SciSciNet | 10 journal coauthorship networks | M4 | Repository root folders listed below |

### Common M4 specification

All primary M4 models are undirected ERGMs with: edges; an indicator of prior collaboration; standardized expertise level; absolute expertise difference; standardized leadership/status level; and absolute leadership/status difference. M5 adds `gwesp(decay = 0.25, fixed = TRUE)` as a structural robustness check. Exact variable construction differs by context and is documented with the relevant data interface.

## Repository layout

| Location | Contents |
| --- | --- |
| `scripts/`, `data/`, `results/`, `figures/`, `docs/` | SciSciNet analysis, archived aggregate results, M4 diagnostics, and publication figures. |
| `contexts/ghtorrent/` | GHTorrent/GitHub code, archived aggregate results, M4/M5 GOF materials, and a data interface. |
| `environment/` | R and Python dependency lists. |

The GHTorrent workflow begins at [contexts/ghtorrent/README.md](contexts/ghtorrent/README.md). The top-level folders comprise the SciSciNet workflow; see [data/README.md](data/README.md) for its input interface.

## Quick start

Install the R dependencies:

```r
install.packages(c("network", "ergm", "openxlsx"))
```

To recreate the included SciSciNet figures from archived results:

```bash
python3 -m pip install -r environment/requirements-python.txt
python3 scripts/04_make_main_figures.py \
  --separate results/model_fits/separate_m0_m4/coefficients_m4.csv \
  --block results/model_fits/block_m0_m4/coefficients_m4.csv \
  --output-dir figures/main_text
```

To rerun an analysis, obtain each context's processed inputs under the source data's terms and place them outside version control, as specified in its data README. Recomputed outputs are intentionally ignored by Git.

## What can be shared

The repository contains only code, aggregate model tables, GOF plots and summaries, and rendered figures. Do not add raw GHTorrent tables, contributor identifiers, SciSciNet author-level files, MyDreamTeam participant data, `.rds` model objects, or console logs to a public release.

Before creating a DOI release, update `CITATION.cff` and `.zenodo.json` with the manuscript title, authors, repository URL, and DOI; add the exact data-access links in the context-specific data READMEs; and run the release checklist in [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md).

## License and citation

Repository code is available under the [MIT License](LICENSE). Source data remain subject to their original licenses, access terms, and citation requirements. Please cite the accompanying manuscript and the relevant source data.
