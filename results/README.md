# Public aggregate result tables

Each CSV in this directory was exported from a final analysis workbook after
dropping machine-specific path columns. No raw rows, actor identifiers,
dyad-level data, fitted model objects, or input matrices are included.

* sciscinet/ contains separate and block-diagonal journal-model aggregate
  tables for the final ten-journal set, including block_m5d_gwdegree/.
* ghtorrent/ contains separate and block-diagonal language-model aggregate
  tables for the final ten-language set, including block_m5d_gwdegree/.
* mydreamteam/ contains the separate-session M4 tables and the final
  block_m5d_gwdegree/ outputs. Underlying classroom records remain restricted.
* block_m5d_gwdegree_summary.csv is a three-domain overview of final M5-D
  coefficients and constrained model-statistic GOF checks.
* meta/ contains the M4 random-effects input rows and pooled estimates.

M5-D denotes M4 plus fixed-decay GWdegree. It is distinct from the older
GHTorrent GWESP sensitivity analysis, called M5-E in the current
documentation. The public M5-D folders contain only aggregate result tables,
text exports, and figures; they do not contain node files, edge files, input
matrices, or fitted RDS objects.

The SciSciNet tables use the 95th-percentile top-5% selection specified in
configs/sciscinet_2020_top5pct.csv. The table provenance otherwise follows
the final result workbooks.
