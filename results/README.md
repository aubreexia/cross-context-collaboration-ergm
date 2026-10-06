# Public aggregate result tables

Each CSV in this directory was exported from a final analysis workbook after
dropping machine-specific path columns. No raw rows, actor identifiers,
dyad-level data, fitted model objects, or input matrices are included.

* `sciscinet/` contains separate and block-diagonal journal-model aggregate
  tables for the final ten-journal set.
* `ghtorrent/` contains separate and block-diagonal language-model aggregate
  tables for the final ten-language set.
* `mydreamteam/` contains the separate-session M4 aggregate tables used in
  the meta-analysis. Underlying classroom records remain restricted.
* `meta/` contains the M4 random-effects input rows and pooled estimates.

The SciSciNet tables use the 95th-percentile (top-5%) selection specified in
`configs/sciscinet_2020_top5pct.csv`. The table provenance otherwise follows
the final result workbooks.
