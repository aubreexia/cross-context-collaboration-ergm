# Cross-context collaboration ERGMs

Code, release-level result tables, and documentation for the analysis of 30
collaboration networks: 10 MyDreamTeam classroom-team networks, 10 GHTorrent
programming-language co-contribution networks, and 10 SciSciNet journal
coauthorship networks.

The repository deliberately excludes raw data, actor-level ERGM inputs,
fitted-model objects, and source-data extracts.  Those materials may contain
identifiers or are subject to the respective data providers' terms.  The
included result tables are aggregate coefficient, fit, and network-summary
tables only.

## What is included

| Location | Contents |
| --- | --- |
| `configs/` | Fixed language, journal, session, date-window, and selection settings. |
| `scripts/python/` | SciSciNet and GHTorrent preprocessing and ERGM-input construction. |
| `scripts/r/` | Separate-network ERGMs, block-diagonal ERGMs, GOF scripts, and random-effects meta-analysis. |
| `results/` | Public aggregate tables used to report the submitted analysis. |
| `docs/` | Variable definitions, data-access instructions, and reproducibility notes. |

## SciSciNet selection

This release uses the **95th-percentile / top-5%** SciSciNet selection rule
recorded in `configs/sciscinet_2020_top5pct.csv`. For each journal, authors
are ranked by their number of 2020 target-journal papers; the cutoff is the
nearest-rank value at `ceiling(0.05 * n)`, and all authors tied at that cutoff
are retained. Thus, the realized retained share can exceed 5%. The same
top-5% rule applies to the documented preprocessing, ERGM inputs, and released
SciSciNet result tables.

## Quick start

Create a Python environment and install the packages in
`environment/requirements-python.txt`. In R, install the packages listed in
`environment/install_r_packages.R`.

```bash
python -m pip install -r environment/requirements-python.txt
Rscript environment/install_r_packages.R
```

The commands below assume that protected raw data have been placed outside
the repository or under ignored `data/raw/` paths.  Replace paths and the
SciSciNet `k` values with the values emitted by the selection script.

```bash
# 1. SciSciNet: calculate the journal-specific top-5% cutoff (ties retained).
python scripts/python/sciscinet/01_select_top5_productivity.py \
  --journal "Cell" --start-date 2020-01-01 --end-date 2020-12-31 \
  --top-percent 5 --project-dir /path/to/sciscinet

# 2. SciSciNet: build the focal network, prior matrix, expertise, and h-index.
# Replace K_FROM_STEP_1 with selected_k_cutoff in k_selection_summary.json.
python scripts/python/sciscinet/02_build_ergm_inputs.py \
  --journal "Cell" --start-date 2020-01-01 --end-date 2020-12-31 \
  --k K_FROM_STEP_1 --project-dir /path/to/sciscinet

# 3. GHTorrent: build one language-specific April-2020 ERGM input set.
python scripts/python/ghtorrent/01_build_language_network.py \
  --raw-dir /path/to/ghtorrent_csv --output-root data/processed/ghtorrent \
  --language Python

# 4. Fit the primary models after creating all domain-specific processed inputs.
Rscript scripts/r/01_fit_sciscinet_separate_m0_m4.R data/processed/sciscinet
Rscript scripts/r/02_fit_sciscinet_block_m0_m4.R data/processed/sciscinet
Rscript scripts/r/03_fit_ghtorrent_separate_m0_m5.R data/processed/ghtorrent
Rscript scripts/r/04_fit_ghtorrent_block_m0_m5.R data/processed/ghtorrent
Rscript scripts/r/05_fit_mydreamteam_block_m0_m5.R data/processed/mydreamteam
```

For the within-domain random-effects synthesis, put exactly the three required
separate-network Excel workbooks in a temporary local directory and run:

```bash
Rscript scripts/r/06_run_within_domain_meta_m4.R /path/to/meta_input_workbooks
```

That script writes a timestamped folder containing the meta-analytic input
rows, pooled estimates, prediction intervals, and session information.  See
`docs/REPRODUCIBILITY.md` for the complete ordering, inputs, and caveats.

To refit the meta-analysis from the released 30 estimate/SE rows alone (no
restricted input data or workbooks required), run:

```bash
Rscript scripts/r/09_verify_public_meta_results.R results/meta
```

## Model scope

M0--M4 use dyad-independent terms and are estimated by exact MLE.  The
GHTorrent and MyDreamTeam M5 models add fixed-decay GWESP and therefore use
MCMLE; treat them as a transitivity robustness specification rather than the
input to the M4 random-effects synthesis.  The SciSciNet analysis reports
M0--M4 because the M5 fits did not provide stable common diagnostics.

The public release includes the MyDreamTeam block-model code and aggregate
results, but not its restricted-data preprocessing or separate-session fitting
pipeline. The released M4 estimate/SE rows still allow the cross-network
meta-analysis to be independently checked.

## License and data access

Code in this repository is released under the MIT License.  Source data remain
governed by their providers' licenses and access conditions; see
`docs/DATA_ACCESS.md`.  Do not upload raw extracts, author/user identifiers,
or fitted `.rds` objects to a public repository.
