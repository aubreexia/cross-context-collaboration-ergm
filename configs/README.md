# Analysis configurations

`sciscinet_2020_top5pct.csv` defines the SciSciNet 95th-percentile (top-5%)
selection. It uses a nearest-rank rule: with `n` focal authors, order authors
by focal-paper count and set `k` to the count at rank `ceiling(.05 * n)`;
retain everyone whose count is at least `k`. Ties can make the retained share
larger than 5%.

`ghtorrent_april2020_top1pct.csv` defines the focal window, the inclusive
10-commit user--repository criterion, and the within-language 99th-percentile
selection.  Here the nearest-rank cutoff is calculated on each user's number
of qualifying repositories, not on total commit counts.
