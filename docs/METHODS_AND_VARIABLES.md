# Sampling and variable construction

This document is the implementation-level specification for the Python input
builders.  All focal ties and prior indicators are undirected and binary in
the ERGM input files.

## SciSciNet journal networks

### Requested top-5% (95th-percentile) selection

For each journal in `configs/sciscinet_2020_top5pct.csv`, the
selection script first identifies all papers dated from 1 January through 31
December 2020, inclusive.  The selection universe is every unique author of
those journal-specific focal papers, before isolate removal.  For author `i`,
let `c_i` be the number of distinct focal-period papers in that journal.

With `n` authors, order `c_i` from largest to smallest and define

```text
r = ceiling(0.05 * n)
k = c_(r)
```

All authors with `c_i >= k` are retained.  Thus “95th percentile” here means
the upper 5% by a nearest-rank rule, with all ties at the cutoff retained.  It
does **not** use an interpolated software quantile.  The script writes the
realized cutoff and actual retained percentage to `k_selection_summary.json`.
Pass `selected_k_cutoff` to `02_build_ergm_inputs.py --k`; that second script
uses the inclusive rule `focal_paper_count >= k`.

### Ties and covariates

* **Focal tie:** two retained authors coauthored at least one target-journal
  paper in 2020.  Multiple papers are one tie.  Retained focal isolates are
  removed after the focal network is constructed.
* **Prior collaboration:** two modeled authors coauthored at least one
  target-journal paper before 1 January 2020.  The indicator is binary.
* **Expertise:** the author's count of distinct target-journal papers before
  1 January 2020.
* **Leadership/status:** SciSciNet author h-index.
* **Model scale:** expertise and h-index are each transformed with `log(1+x)`
  and standardized within journal.  The R scripts use the supplied
  `expertise_z` and `leadership_z` values.

The code retains older papers with an unavailable exact date only when their
recorded year precedes 2020; it never treats an undated 2020 record as prior.

## GHTorrent programming-language networks

The GHTorrent inputs use the 2021-03-06 snapshot specified in
`configs/ghtorrent_april2020_top1pct.csv`. Repositories are selected by their
recorded focal programming language; there is no additional project-creation
date filter. The focal window is
`[2020-04-01, 2020-05-01)`: 1 April is included and 1 May is excluded.

### 99th-percentile (top-1%) selection

For a language, first retain every user--repository pair with **at least 10**
commits in the April focal window.  A pair with exactly 10 commits is retained.
For each user, count the number of those qualifying repositories.  If the
counts are `q_i` for `n` users, sort ascending and set

```text
r = ceiling(0.99 * n)
k = q_(r)
```

Retain users with `q_i >= k`, including ties.  A focal tie is present when two
retained users each have a qualifying April contribution to the same
language-matched repository.  The builder then removes focal isolates, which
means the final modeled node count may be smaller than the number passing the
upper-tail cutoff.

### Ties and covariates

* **Focal tie:** at least one shared language-matched repository for which
  both users meet the April `>= 10`-commit criterion.  Repeated shared
  repositories are collapsed to a binary tie.
* **Prior collaboration:** before 1 April 2020, both users made at least one
  commit to the same repository in the focal programming language.  This
  historical indicator intentionally has no 10-commit requirement and is
  binary.
* **Expertise:** number of distinct focal-language repositories to which the
  user made at least one pre-focal commit.
* **Leadership/status:** follower count.  The supplied builder accepts either
  one follower relationship per row or an already aggregated follower-count
  column.  It transforms the count with `log(1+x)` and standardizes it within
  language.

The research release used a March 2021 GHTorrent follower snapshot, which is
after the April 2020 focal window.  To mirror that measurement with an undated
snapshot, invoke the builder with `--allow-undated-followers`; this is an
explicitly non-temporal status measure and should remain disclosed as a study
limitation.  If a dated pre-focal follower table is available, omit that flag
and the builder will restrict relationships to dates before 1 April 2020.

## ERGM terms and standardization

For network `b`, the primary M4 specification is:

```text
edges + prior + expertise level + |expertise_i - expertise_j|
      + status level + |status_i - status_j|
```

The `nodecov` level term uses the sum of the two endpoint values in `ergm`;
the `absdiff` term is absolute difference.  All covariates are prepared at
the network level before the separate or block-diagonal model is fitted.
M0--M4 are dyad-independent exact-MLE models. The primary pooled structural
extension is M5-D, defined as M4 plus gwdegree(0.50, fixed = TRUE). M5-D is
estimated with MCMLE and uses one global edges term plus blockdiag(block_id)
in all three domains; it does not add session-, language-, or journal-specific
density parameters.

The older fixed-decay GWESP extension is denoted M5-E in the current
documentation. It remains a GHTorrent-only supplementary sensitivity analysis
and is not the cross-domain pooled primary model.
