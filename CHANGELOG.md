# Changelog

## v1.1.0 — 2026-10-10

- Added the final high-precision pooled M5-D GWdegree analyses for
  MyDreamTeam, GHTorrent, and SciSciNet.
- Added constrained model-statistic GOF tables and figures based on 500
  simulations of each final fitted M5-D model.
- Reframed M5-D as the shared pooled structural model in the README, run
  order, methods, and reproducibility documentation.
- Renamed the older GHTorrent-only GWESP analysis M5-E in public
  documentation, preserving it as a supplementary sensitivity analysis.
- Added public-release safeguards that ignore restricted raw and processed
  data and fitted model objects.

## v1.0.2 — 2026-10-04

- Standardized all released MyDreamTeam error text to English; localized
  R indexing errors are now recorded as "subscript out of bounds".
- Removed two spurious SciSciNet folder_failed records that came from
  auxiliary output folders rather than journal networks, and updated the
  separate-network script to ignore folders without a complete ERGM input
  triplet.
- Clarified that MyDreamTeam GWESP (M5) fits did not yield usable converged
  estimates and are not interpreted as a robustness result.

## v1.0.1 — 2026-10-04

- Corrected the SciSciNet sampling description to its official 95th-percentile
  (top-5%) rule.
- Renamed the retained configuration to `sciscinet_2020_top5pct.csv` and
  removed the obsolete alternative selection configuration from this public
  release.
- Aligned the README, configuration notes, run order, reproducibility notes,
  and released-results documentation with the top-5% rule.
