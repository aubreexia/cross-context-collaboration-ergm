# GHTorrent/GitHub data interface

Do not commit raw GHTorrent extracts, GitHub contributor identifiers, project-level contribution records, or reconstructed dyadic matrices to this repository. Build the processed inputs locally from a permitted copy of the source data and retain only the aggregate outputs listed in `../results/`.

The analysis window is 2020-04-01 (inclusive) through 2020-05-01 (exclusive), UTC. The preprocessing pipeline retains user--project pairs with at least 10 April commits. Each language folder must then contain the three CSV inputs documented in `../README.md`.

Before release, add here: (1) the exact GHTorrent snapshot/version; (2) the data source URL and citation; (3) the preprocessing script or an accessible archived version; (4) a DOI/OSF/Zenodo link for any legally shareable processed, de-identified inputs; and (5) the applicable source-data license or terms.
