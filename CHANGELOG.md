# Changelog

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
