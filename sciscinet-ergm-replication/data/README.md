# Data access and processed-input interface

## Source data

The analysis uses SciSciNet v1. Cite both the data paper and the dataset:

> Lin, Z., Yin, Y., Liu, L., & Wang, D. (2023). SciSciNet: A large-scale open data lake for the science of science research. *Scientific Data*. https://doi.org/10.1038/s41597-023-02198-9

> Lin, Z., Yin, Y., Liu, L., & Wang, D. (2022). *SciSciNet: A large-scale open data lake for the science of science research* [Data set]. Figshare. https://doi.org/10.6084/m9.figshare.c.6076908.v1

The source data are not redistributed here. Download them from the official SciSciNet record and retain the original license and attribution. This repository begins at the processed network-input stage.

## Why `data/processed/` is empty

The public Git repository deliberately contains no author-level input data. The exact processed folders should be deposited as a versioned companion archive (for example, Zenodo/OSF) or regenerated from the original SciSciNet data before a final release. Once available locally, place or symlink them under `data/processed/journals/`.

## Required layout

Each immediate subdirectory is one journal. Files may live directly in that directory or in one nested processing directory.

```text
data/processed/journals/
  Cell/
    Cell_nodes.csv
    Cell_edges.csv
    Cell_prior_mat.csv
    Cell_prior_edges.csv          # optional validation file
  Mind/
    Mind_2019_01_01_to_2020_12_31_k1/
      Mind_nodes.csv
      Mind_edges.csv
      Mind_prior_mat.csv
  ...
```

The analysis scripts find one `*_nodes.csv`, one current-period `*_edges.csv`, and one `*_prior_mat.csv` per top-level journal directory. They fail rather than choose arbitrarily if multiple candidate files exist.

## Required files and columns

| File | Required content |
| --- | --- |
| `*_nodes.csv` | `global_id`; one standardized expertise column (`expertise_z`, `expertise_model_z`, or `expertise_z_shared`); one standardized leadership column (`leadership_z`, `leadership_model_z`, or `leadership_z_shared`). `AuthorID` is optional. |
| `*_edges.csv` | Undirected current-period ties, one row per dyad, with `u` and `v` identifiers matching `global_id`. Self-ties and duplicate dyads are removed by the code. |
| `*_prior_mat.csv` | A square, symmetric, nonnegative dyadic matrix. The first column holds row IDs; remaining column names hold the same IDs. Positive values are converted to a binary prior-collaboration indicator. |
| `*_prior_edges.csv` | Optional prior-edge list used only as a count cross-check by the separate-model script. |

All final analysis networks must have no isolates. The scripts stop with a clear error if an isolate remains, preventing an unrecorded change to the sample.

## Processed-data deposit checklist

Before releasing the manuscript materials, deposit the ten processed journal folders separately and add the permanent DOI/URL here. The deposit should include a short provenance note with the source SciSciNet version, time window, journal-selection rule, author-selection rule, and transformations used to create the standardized covariates.
