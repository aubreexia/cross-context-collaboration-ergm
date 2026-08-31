# Model specification

## Networks and estimation

Each journal is modeled as an undirected current-period coauthorship network. The separate analysis fits five nested ERGMs independently for the ten journal networks. The pooled analysis combines the same networks into a block-diagonal network and constrains all cross-journal dyads to be structurally unavailable.

All M0--M4 terms are dyad-independent. They are therefore fit with `estimate = "MLE"`, rather than MCMC maximum likelihood estimation.

## Terms

| Label | ERGM term | Interpretation |
| --- | --- | --- |
| Edges | `edges` | Baseline log-odds of a current collaboration tie. |
| Prior collaboration | `edgecov(prior)` / `edgecov(prior_big)` | Indicator that the two scholars collaborated in the prior period. |
| Expertise level | `nodecov("expertise_model_z")` | Association of the endpoints' standardized expertise with tie formation. |
| Expertise absolute difference | `absdiff("expertise_model_z")` | Association of expertise dissimilarity with tie formation. |
| Leadership/status level | `nodecov("leadership_model_z")` | Association of the endpoints' standardized leadership/status with tie formation. |
| Leadership/status absolute difference | `absdiff("leadership_model_z")` | Association of leadership/status dissimilarity with tie formation. |

For undirected networks, `nodecov()` uses the sum of the two endpoints' attribute values for each dyad. Negative `absdiff()` coefficients indicate a similarity association, conditional on the other terms.

## Nested models

| Model | Formula |
| --- | --- |
| M0 | `edges` |
| M1 | `edges + prior collaboration` |
| M2 | `M1 + expertise level` |
| M3 | `M2 + expertise absolute difference` |
| M4 | `M3 + leadership/status level + leadership/status absolute difference` |

## Pooled block-diagonal model

The pooled model assigns each author to a journal-specific `block_id`. It uses the constraint:

```r
constraints = ~blockdiag("block_id")
```

Thus the likelihood is evaluated only over within-journal dyads. The pooled covariates retain each journal's standardized values; they are not re-standardized after pooling.

## Goodness of fit

The M4 GOF script compares observed and simulated model statistics, geodesic-distance distributions, degree distributions, edgewise shared partners, and dyadwise shared partners. It uses 100 simulations by default. The supplied diagnostic tables are preserved in `results/diagnostics/m4_gof/`.
