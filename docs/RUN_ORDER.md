# Analysis run order

The raw data and generated ERGM inputs are intentionally not versioned.  Use
a writable local location for each domain, then pass that location as the
single argument to the R scripts.

## 1. SciSciNet

For each of the ten journals in `configs/sciscinet_2020_top5pct.csv`, run the
selection script first. It determines a journal-specific `k`, so do not reuse
Cell's cutoff for another journal. This release uses only the 95th-percentile
(top-5%) selection; retain the explicit `--top-percent 5` argument below.

```bash
python scripts/python/sciscinet/01_select_top5_productivity.py \
  --journal "JOURNAL" --start-date 2020-01-01 --end-date 2020-12-31 \
  --top-percent 5 --project-dir /path/to/sciscinet

python scripts/python/sciscinet/02_build_ergm_inputs.py \
  --journal "JOURNAL" --start-date 2020-01-01 --end-date 2020-12-31 \
  --k JOURNAL_SPECIFIC_K --project-dir /path/to/sciscinet
```

Copy or link every journal's `*_nodes.csv`, `*_edges.csv`, and
`*_prior_mat.csv` into an immediate journal folder under one local
`data/processed/sciscinet/` root.  Then run:

```bash
Rscript scripts/r/01_fit_sciscinet_separate_m0_m4.R data/processed/sciscinet
Rscript scripts/r/02_fit_sciscinet_block_m0_m4.R data/processed/sciscinet
Rscript scripts/r/07_run_sciscinet_m4_gof.R data/processed/sciscinet
```

`07_run_sciscinet_m4_gof.R` must be run after the separate and block model
scripts because it reads their saved model objects.

## 2. GHTorrent

Place CSV exports of the GHTorrent `commits`, `projects`, and `followers`
tables in a protected local directory.  Use `--commits-csv`, `--projects-csv`,
or `--followers-csv` if their filenames differ from the defaults.

```bash
python scripts/python/ghtorrent/00_profile_april_2020_commits.py \
  --commits-csv /path/to/ghtorrent_csv/commits.csv \
  --output-dir data/derived/ghtorrent_april2020_audit

python scripts/python/ghtorrent/01_build_language_network.py \
  --raw-dir /path/to/ghtorrent_csv \
  --output-root data/processed/ghtorrent \
  --language "Python" --allow-undated-followers
```

Repeat the builder for all ten languages listed in
`configs/ghtorrent_april2020_top1pct.csv`.  The first script is an optional
audit of the April commit distribution; the second script is the authoritative
network/input builder.

```bash
Rscript scripts/r/03_fit_ghtorrent_separate_m0_m5.R data/processed/ghtorrent
Rscript scripts/r/04_fit_ghtorrent_block_m0_m5.R data/processed/ghtorrent
Rscript scripts/r/08_run_ghtorrent_m4_m5_gof.R data/processed/ghtorrent
```

## 3. MyDreamTeam

Prepare one immediate folder per selected session listed in
`configs/mydreamteam_sessions.csv`, with the expected session input files.
Run the block-diagonal model with:

```bash
Rscript scripts/r/05_fit_mydreamteam_block_m0_m5.R data/processed/mydreamteam
```

The separate-session outputs used in the meta-analysis are retained as release
tables in `results/mydreamteam/`; their original preprocessing is not released
because the classroom data are restricted.

## 4. Within-domain random-effects meta-analysis

The meta-analysis uses M4 estimates and standard errors from the three
separate-network Excel workbooks.  It fits a REML random-effects model with
Knapp--Hartung inference separately for each domain and each theory-relevant
term, and reports a 95% prediction interval, `tau^2`, and `I^2`.

```bash
Rscript scripts/r/06_run_within_domain_meta_m4.R /path/to/meta_input_workbooks
```

The input folder must contain exactly one workbook matching each of the three
filename patterns documented at the top of `06_run_within_domain_meta_m4.R`.
The resulting CSVs are the input to the results narrative; do not replace the
prediction interval with a count of individually significant networks.

For a public-data-only check, rerun the same REML/Knapp--Hartung synthesis on
the released 30 estimate/SE rows:

```bash
Rscript scripts/r/09_verify_public_meta_results.R results/meta
```
