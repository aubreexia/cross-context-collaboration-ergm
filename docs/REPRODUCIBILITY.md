# Reproducibility notes

## Release result provenance

The public CSVs under `results/` were exported from the final analysis
workbooks supplied with this project.  They are intended for inspection,
figure/table regeneration, and meta-analysis verification.  No raw input
files are included, so a fresh end-to-end rerun requires separately obtained
source data and the same preprocessing configuration.

The M4 random-effects output is included in `results/meta/` along with the 30
network-specific estimate/standard-error rows.  The model uses REML and
Knapp--Hartung inference; `tau^2` quantifies estimated between-network
variance and `I^2` the estimated share of observed dispersion attributable to
heterogeneity.  The prediction interval answers the transport question for a
new network in the same domain.

## Primary pooled M5-D results

The current manuscript uses the pooled block-diagonal M5-D model as its
primary structural analysis in all three domains. M5-D adds a fixed-decay
GWdegree term, with decay 0.50, to M4. Each domain retains one global edges
term and a blockdiag constraint, so the density specification is unchanged
from the corresponding pooled M4 model.

The final public aggregate outputs are stored in these three folders:

    results/mydreamteam/block_m5d_gwdegree/
    results/ghtorrent/block_m5d_gwdegree/
    results/sciscinet/block_m5d_gwdegree/

Each folder contains coefficients, model settings, model status, a
model-statistic GOF table, a text export, and a GOF figure. The reported GOF
uses 500 constrained simulations with MCMC burn-in 1,000,000 and interval
65,536. It evaluates the statistics included in M5-D only. It should not be
described as a test of every possible network feature.

The M5-D status field deliberately remains
fit_returned_inspect_mcmc_and_gof. This wording preserves the MCMC diagnostic
review requirement and avoids making a blanket convergence claim from the
public aggregate tables alone. The older GHTorrent GWESP workflow is M5-E in
the current documentation and is not the pooled primary model.

## Release consistency notes

1. The SciSciNet selection, processed inputs, released results, and manuscript
   methods use the 95th-percentile (top-5%) rule in
   `configs/sciscinet_2020_top5pct.csv`. If this rule changes, rerun the full
   SciSciNet preprocessing and downstream analyses before updating any tables
   or claims.
2. The GHTorrent follower metric comes from the March 2021 snapshot. It is
   post-focal for an April 2020 network and should not be described as a
   pre-focal covariate unless a dated earlier source is substituted.
3. Recheck each current journal name in the paper and config. This release
   uses Ecological Applications and Organization Science, not older journal
   choices that may occur in archived output folders.
4. Replace the generic copyright line in `LICENSE` and add an author/DOI
   citation file at submission or archival release.

## Determinism

The Python scripts use deterministic sorting, fixed nearest-rank selection,
and explicit date inequalities.  The ERGM scripts set seeds where stochastic
MCMLE or GOF simulation is involved.  Record the R session information from
the meta-analysis output and any compute-cluster settings alongside a
versioned release tag.
