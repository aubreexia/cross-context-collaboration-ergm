# Primary pooled M5-D GWdegree model

## Definition

The pooled structural model used in the current manuscript is:

    M5-D = M4 + gwdegree(0.50, fixed = TRUE)

M4 contains edges, prior collaboration, expertise level, expertise difference,
leadership or status level, and leadership or status difference. M5-D adds a
fixed-decay GWdegree term to represent degree-related structural dependence.
Its coefficient is nonlinear and should not be converted into a conventional
dyadic odds ratio.

M5-D is distinct from M5-E. M5-E is the prior GHTorrent-only fixed-decay
GWESP sensitivity analysis. It remains reproducible in this repository but is
not the shared primary pooled model.

## Common specification

All three M5-D models use:

| Setting | Value |
| --- | --- |
| Pooled networks | 10 sessions, languages, or journals per domain |
| Density specification | One global edges term |
| Constraint | blockdiag(block_id) |
| GWdegree decay | 0.50, fixed |
| Estimation | MCMLE, initialized from M4 plus GWdegree = 0 when appropriate |
| MCMLE maximum iterations | 60 |
| MCMC burn-in | 1,000,000 |
| MCMC interval | 65,536 |
| MCMLE effective size | 128 |
| MCMLE last boost | 8 |
| Final GOF | constrained gof(~model), 500 simulations |
| GOF burn-in and interval | 1,000,000 and 65,536 |

Blockdiag removes cross-block dyads from the risk set. The one global edges
term is therefore the same density specification used in the corresponding
pooled M4 model. No block-specific nodemix or mix density terms were added.

## Final aggregate results

| Domain | Prior-collaboration estimate | Prior-collaboration odds ratio | GWdegree estimate (SE) | Lowest final model-statistic GOF MC p-value |
| --- | ---: | ---: | ---: | ---: |
| MyDreamTeam | 1.700 | 5.475 | 6.101 (0.654) | 0.936 |
| GHTorrent | 4.851 | 127.840 | 0.819 (0.080) | 0.840 |
| SciSciNet | 7.223 | 1369.941 | -1.263 (0.048) | 0.664 |

For all three models, the final GOF output shows the observed value of every
fitted statistic within the corresponding simulated range. The complete
aggregate tables and figures are located at:

    results/mydreamteam/block_m5d_gwdegree/
    results/ghtorrent/block_m5d_gwdegree/
    results/sciscinet/block_m5d_gwdegree/

## Diagnostics and reporting scope

The public status is intentionally recorded as
fit_returned_inspect_mcmc_and_gof. It means that the fit returned and the
final constrained GOF was completed; it does not by itself replace
inspection of the MCMC diagnostic output.

The published model-statistic GOF evaluates the seven statistics included in
M5-D: edges, prior collaboration, two expertise terms, two leadership or
status terms, and GWdegree. It does not assess every possible structural
feature, such as degree distribution bins or shared-partner distributions not
included in the formula. Do not describe these values as a blanket GOF result
for all network features.

For manuscript reporting, state that M5-D is the primary pooled block model,
retain the common density specification, report the constrained model-statistic
GOF, and identify M5-E as a GHTorrent-only supplementary GWESP sensitivity
analysis.

## Scripts

| Domain | Fit script | GOF script |
| --- | --- | --- |
| MyDreamTeam | scripts/r/10_fit_mydreamteam_block_m5d_gwdegree.R | scripts/r/13_gof_mydreamteam_block_m5d_gwdegree.R |
| GHTorrent | scripts/r/11_fit_ghtorrent_block_m5d_gwdegree.R | scripts/r/14_gof_ghtorrent_block_m5d_gwdegree.R |
| SciSciNet | scripts/r/12_fit_sciscinet_block_m5d_gwdegree.R | scripts/r/15_gof_sciscinet_block_m5d_gwdegree.R |
