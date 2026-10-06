# Cross-Context Collaboration ERGMs

Replication code and public aggregate results for a study of collaboration
networks in three settings: classroom project teams, open-source software
development, and scientific coauthorship. The analysis compares 30 undirected,
binary networks: 10 MyDreamTeam classroom sessions, 10 GHTorrent programming
language communities, and 10 SciSciNet journals.

The study asks whether prior collaboration, expertise, and leadership or status
are associated with focal-period collaboration across these different settings.
Each network is estimated separately, then combined within its domain using a
block-diagonal ERGM and synthesized with random-effects meta-analysis.

## Study design

| Domain | Networks | Focal collaboration tie | Sampling / focal window | Expertise | Leadership or status |
| --- | ---: | --- | --- | --- | --- |
| MyDreamTeam | 10 classroom-team sessions | Collaboration between two students in a selected session | Ten selected classroom sessions | Skill measure | Leadership measure |
| GHTorrent | 10 programming languages | Two developers each made at least 10 April 2020 commits to the same language-matched repository | April 2020; users retained at the within-language 99th percentile of qualifying repositories, with ties retained | Pre-April count of focal-language repositories | Follower count from the documented snapshot |
| SciSciNet | 10 journals | Two retained authors coauthored a target-journal paper in 2020 | 2020; authors retained at the journal-specific 95th percentile of focal-paper productivity, with ties retained | Pre-2020 target-journal publication count | Author h-index |

All focal ties and prior-collaboration indicators are binary and undirected.
The same conceptual terms are operationalized within each setting rather than
assumed to be identical measures across settings.

## Sampling and covariates

### MyDreamTeam

The public release contains aggregate results for ten selected classroom-team
sessions. The underlying classroom records, actor-level inputs, and
preprocessing pipeline are restricted. The models use prior collaboration, a
skill measure, and a leadership measure prepared within session.

### GHTorrent

The focal window is `[2020-04-01, 2020-05-01)`. A user--repository pair must
have at least 10 commits during that window; a pair with exactly 10 commits is
retained. Within each programming language, users are selected at the 99th
percentile of their number of qualifying repositories, using a nearest-rank
cutoff and retaining ties. Prior collaboration is shared activity in a
language-matched repository before 1 April 2020. Expertise is the number of
focal-language repositories with a pre-focal contribution, and status is
follower count. Both covariates are transformed as `log(1 + x)` and
standardized within language.

### SciSciNet

For each journal, authors are ranked by their number of 2020 papers in that
journal. The selection cutoff is the nearest-rank value at
`ceiling(0.05 * n)`; authors at or above the cutoff, including ties, are
retained. The realized retained share may therefore exceed 5%. Prior
collaboration is a pre-2020 coauthorship in the same journal. Expertise is the
pre-2020 count of papers in that journal, and status is the author h-index.
Both covariates are transformed as `log(1 + x)` and standardized within
journal.

For full implementation details, see `docs/METHODS_AND_VARIABLES.md` and the
CSV files in `configs/`.

## Models and outputs

The primary M4 specification is:

```text
edges + prior collaboration + expertise level + expertise difference
      + status level + status difference
```

- **Separate-network ERGMs:** M0--M4 are estimated for each of the 30
  networks. Because these specifications contain only dyad-independent terms,
  they are estimated by maximum likelihood.
- **Block-diagonal ERGMs:** Networks are pooled within each domain while
  constraining ties to remain within sessions, languages, or journals.
- **GWESP robustness models:** M5 adds fixed-decay GWESP as a sensitivity
  specification. It was fit for GHTorrent using MCMLE. The corresponding
  MyDreamTeam fits did not yield usable converged estimates and are not
  interpreted.
- **Random-effects meta-analysis:** The five theory-relevant M4 terms are
  synthesized within each domain using REML with Knapp--Hartung inference and
  95% prediction intervals.

The `results/` directory contains aggregate coefficients, model-fit summaries,
and network summaries. It contains no raw records, actor identifiers,
dyad-level inputs, or fitted model objects.

## Repository structure

| Location | Contents |
| --- | --- |
| `configs/` | Session, language, journal, date-window, and selection settings. |
| `scripts/python/sciscinet/` | SciSciNet author selection and ERGM-input construction. |
| `scripts/python/ghtorrent/` | GHTorrent audit and language-network construction. |
| `scripts/r/` | ERGM estimation, GOF, and meta-analysis scripts. |
| `results/` | Public aggregate results for the three domains and meta-analysis. |
| `docs/` | Detailed variable definitions, run order, data-access limits, and reproducibility notes. |
| `environment/` | Python and R dependency installation files. |

## Quick start

Install the recorded dependencies:

```bash
python -m pip install -r environment/requirements-python.txt
Rscript environment/install_r_packages.R
```

Protected source data must be obtained separately and kept outside the
repository or in ignored `data/raw/` paths. The domain-specific workflows are:

```bash
# SciSciNet: repeat for every journal in configs/sciscinet_2020_top5pct.csv.
python scripts/python/sciscinet/01_select_top5_productivity.py \
  --journal "Cell" --start-date 2020-01-01 --end-date 2020-12-31 \
  --top-percent 5 --project-dir /path/to/sciscinet

python scripts/python/sciscinet/02_build_ergm_inputs.py \
  --journal "Cell" --start-date 2020-01-01 --end-date 2020-12-31 \
  --k JOURNAL_SPECIFIC_K --project-dir /path/to/sciscinet

# GHTorrent: repeat for every language in configs/ghtorrent_april2020_top1pct.csv.
python scripts/python/ghtorrent/01_build_language_network.py \
  --raw-dir /path/to/ghtorrent_csv \
  --output-root data/processed/ghtorrent \
  --language "Python" --allow-undated-followers
```

After creating the protected, local processed inputs, run the ERGMs:

```bash
# SciSciNet
Rscript scripts/r/01_fit_sciscinet_separate_m0_m4.R data/processed/sciscinet
Rscript scripts/r/02_fit_sciscinet_block_m0_m4.R data/processed/sciscinet
Rscript scripts/r/07_run_sciscinet_m4_gof.R data/processed/sciscinet

# GHTorrent
Rscript scripts/r/03_fit_ghtorrent_separate_m0_m5.R data/processed/ghtorrent
Rscript scripts/r/04_fit_ghtorrent_block_m0_m5.R data/processed/ghtorrent
Rscript scripts/r/08_run_ghtorrent_m4_m5_gof.R data/processed/ghtorrent

# MyDreamTeam (restricted inputs required)
Rscript scripts/r/05_fit_mydreamteam_block_m0_m5.R data/processed/mydreamteam
```

To reproduce the meta-analysis from the released aggregate estimate/SE rows,
without restricted source data, run:

```bash
Rscript scripts/r/09_verify_public_meta_results.R results/meta
```

For the complete execution order and the expected processed-input layout, see
`docs/RUN_ORDER.md`.

## Data access and release boundaries

This is a public code-and-results release, not a redistribution of source
records. MyDreamTeam data are restricted. GHTorrent and SciSciNet source data
remain subject to their respective access terms. Do not upload raw extracts,
processed actor or dyad files, absolute paths, or fitted `.rds` objects to the
public repository. See `docs/DATA_ACCESS.md` before making a release.

## License and citation

Code is released under the MIT License. When creating the archival release,
create a GitHub tag and archive that tagged release with Zenodo; add the
resulting DOI and recommended citation here before submission.
