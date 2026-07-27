# Cross-Context Collaboration ERGM

This repository contains the code, model outputs, and supplementary documentation for a comparative study of collaboration ties in three independent settings:

1. project-team formation on **MyDreamTeam**;
2. open-source software development represented by **GHTorrent**; and
3. scientific coauthorship represented by **SciSciNet**.

The analysis uses the cleaned and unified versions of these datasets made publicly available through the [source OSF project](https://osf.io/mjhpd/overview?view_only=af9133fb34db457daabde1966c6c90b8). The three datasets do not share actors or identifiers and are analyzed as separate networks. The source OSF project distributes the datasets as standardized heterogeneous graphs suitable for PyTorch Geometric workflows. This repository does **not** introduce those heterogeneous-graph datasets; instead, it uses the source data to construct collaboration networks and estimate exponential random graph models (ERGMs).

The study asks whether prior collaboration, expertise, and leadership-related status are associated with current collaboration ties, and whether the observed associations are consistent across team-formation, open-source, and scientific settings.

## Research questions

The analyses address two main questions:

1. How are prior collaboration, expertise, expertise similarity, leadership-related status, and leadership similarity associated with collaboration ties within individual networks?
2. Which associations remain consistent when multiple networks from the same domain are estimated together using a block-diagonal ERGM?

The three domains are not pooled into a single cross-domain network. Separate-network ERGMs are estimated for each network. Block-diagonal ERGMs are estimated only within the GitHub and SciSciNet domains.

## Source data and availability

The data used in this study were downloaded from a [publicly accessible OSF project](https://osf.io/mjhpd/overview?view_only=af9133fb34db457daabde1966c6c90b8) that provides cleaned and unified heterogeneous-graph versions of MyDreamTeam, GHTorrent, and SciSciNet. Each source dataset is independent; there are no overlapping entities or shared identifiers across the three datasets.

### MyDreamTeam

MyDreamTeam is a web-based platform for assembling project teams. Participants create profiles, search for potential collaborators, and invite others to join their “Dream Team.” The source dataset documentation describes 297 participants who formed 75 teams while working on the same creative task. The participants were students enrolled in academic or executive-education programs.

### GHTorrent

GHTorrent is a research data-collection project that mirrors public GitHub activity by collecting event streams and REST API resources for offline analysis. For this study, GHTorrent data are used to construct programming-language-specific collaboration networks from project, commit, user, and follower information.

### SciSciNet

SciSciNet is a large-scale data lake for science-of-science research. It integrates bibliographic records with linkages to sources such as funding, patents, news and social media, and institutional affiliations. For this study, publication, authorship, journal, and author-level information are used to construct journal-specific coauthorship networks.

The OSF project is the source of the cleaned data used here. This repository focuses on the ERGM analysis and may contain analysis-ready network files, code, results, and documentation. Users should cite the OSF project and the relevant original data source, and should follow the licensing and terms specified by the data providers.

## Network construction

All outcome networks are undirected and binary. A node represents an actor and an edge represents collaboration in the focal observation period. Network construction and actor attributes are domain specific.

| Domain | Node | Current collaboration edge | Prior collaboration | Expertise | Leadership-related status |
| --- | --- | --- | --- | --- | --- |
| MyDreamTeam | Participant | Two participants belong to the same focal Dream Team | Two participants had a prior collaboration relationship | Participant expertise score | Participant leadership score |
| GitHub | Developer | Two developers contributed to the same focal project | Two developers contributed to the same project before the focal period | Number of qualifying projects to which the developer contributed before the focal period | Number of followers |
| SciSciNet | Author | Two authors coauthored a paper in the focal journal and period | Two authors coauthored in the target journal before the focal period | Number of papers previously published in the target journal | Author h-index |

The exact focal periods and threshold values used to construct each network are documented in the source-specific processing files and supplementary materials.

## Network samples

### MyDreamTeam

The organizational analysis contains one network:

| Network | Nodes | Edges | Density | Nonzero prior-collaboration dyads |
| --- | ---: | ---: | ---: | ---: |
| MyDreamTeam | 366 | 529 | 0.0079 | 80 |

The 366 nodes reported here come from the network used by the current ERGM run, whereas the OSF source description summarizes 297 participants and 75 teams. This discrepancy should be reconciled against the MyDreamTeam preprocessing and node-inclusion rules before a final reproducibility release.

### GitHub language networks

Nine programming-language-specific networks are analyzed:

| Language | Nodes | Edges | Density | Nonzero prior-collaboration dyads |
| --- | ---: | ---: | ---: | ---: |
| C | 420 | 936 | 0.0106 | 396 |
| C# | 424 | 359 | 0.0040 | 4 |
| C++ | 459 | 537 | 0.0051 | 57 |
| CSS | 372 | 351 | 0.0051 | 1 |
| Java | 330 | 528 | 0.0097 | 73 |
| JavaScript | 365 | 346 | 0.0052 | 2 |
| PHP | 611 | 773 | 0.0041 | 72 |
| Python | 604 | 675 | 0.0037 | 11 |
| Ruby | 304 | 269 | 0.0058 | 8 |
| **Block-diagonal total** | **3,889** | **4,774** | **0.0054 within blocks** | **624** |

### SciSciNet journal networks

Eleven journal-specific coauthorship networks are analyzed:

| Journal | Nodes | Edges | Density | Nonzero prior-collaboration dyads |
| --- | ---: | ---: | ---: | ---: |
| Cell | 729 | 8,151 | 0.0307 | 16 |
| Chemical Reviews | 175 | 442 | 0.0290 | 1 |
| Communications of the ACM | 334 | 1,587 | 0.0285 | 1 |
| Environmental Science & Technology | 1,101 | 4,926 | 0.0081 | 233 |
| IEEE Transactions on Automatic Control | 287 | 362 | 0.0088 | 26 |
| Management Science | 215 | 246 | 0.0107 | 2 |
| Nature | 254 | 1,189 | 0.0370 | 60 |
| Nature Materials | 230 | 1,904 | 0.0723 | 24 |
| Nature Physics | 437 | 8,531 | 0.0895 | 25 |
| Psychological Science | 168 | 940 | 0.0670 | 1 |
| Science | 239 | 2,442 | 0.0859 | 81 |
| **Block-diagonal total** | **4,169** | **30,720** | **0.0256 within blocks** | **470** |

Counts report the analysis-ready networks represented in the current result workbooks. Density for each block-diagonal model is calculated over possible dyads within blocks; between-block dyads are structural zeros and are excluded from this denominator.

## ERGM specification

The study uses exponential random graph models (ERGMs). Models are added sequentially:

| Model | Terms |
| --- | --- |
| M0 | Edges |
| M1 | M0 + prior collaboration |
| M2 | M1 + expertise level |
| M3 | M2 + absolute difference in expertise |
| M4 | M3 + leadership level + absolute difference in leadership |

The complete M4 specification can be written conceptually as:

```text
Current collaboration
  ~ edges
  + prior collaboration
  + expertise level
  + expertise difference
  + leadership level
  + leadership difference
```

Actor attributes are standardized before estimation. Absolute-difference terms capture dissimilarity between two actors; a negative coefficient on an absolute-difference term is consistent with greater tie probability among actors with more similar attribute values, conditional on the other model terms.

### Separate-network models

A separate M0–M4 sequence is estimated for:

- one MyDreamTeam network;
- nine GitHub language networks; and
- eleven SciSciNet journal networks.

### Block-diagonal models

Two additional within-domain analyses are estimated:

- a GitHub block-diagonal ERGM containing the nine language networks; and
- a SciSciNet block-diagonal ERGM containing the eleven journal networks.

Each component network forms one block. Collaboration ties are possible only within blocks, and between-block cells are treated as structural zeros. Actor identifiers are made block specific to prevent unintended cross-network identity matching.

In the current GitHub block-diagonal analysis, prior collaboration is binarized and attributes are standardized within language. In the current SciSciNet block-diagonal analysis, the stored prior-collaboration covariate is used without additional binarization.

## Repository structure

```text
cross-context-collaboration-ergm/
├── README.md
├── code/
│   ├── mydreamteam/
│   ├── github/
│   ├── sciscinet/
│   ├── block_diagonal/
│   └── figures/
├── data/
│   ├── README.md
│   ├── mydreamteam/
│   ├── github/
│   └── sciscinet/
├── results/
    ├── separate_networks/
    ├── block_diagonal/
    └── figures/
```

Folder-level README files should document the inputs, outputs, temporal windows, threshold choices, and execution order for each analysis.

## Result files

The current model outputs and reports are:

| File | Description |
| --- | --- |
| `mdt_ergm_results.xlsx` | MyDreamTeam M4 coefficients, M0–M4 fit statistics, network summary, and run settings |
| `all_language_ergm_results.xlsx` | Separate-network results for the nine GitHub language networks |
| `all_journal_ergm_results.xlsx` | Separate-network results for the eleven SciSciNet journal networks |
| `block_diagonal_language_ergm_results.xlsx` | GitHub language block-diagonal ERGM results and block summaries |
| `block_diagonal_journal_ergm_results.xlsx` | SciSciNet journal block-diagonal ERGM results and block summaries |

Most result workbooks contain the following sheets:

- `coefficients`: estimates from the complete M4 model;
- `model_fit`: AIC and BIC for the M0–M4 sequence;
- `network_summary`, `block_summary`, or an equivalent summary sheet: network sizes and densities; and
- `failed_models`: any model or input-folder failures recorded during batch estimation.

The separate SciSciNet workbook currently contains a `.Rproj.user` folder warning in `failed_models`. This is a non-data directory detected during batch processing and is not one of the eleven journal networks.

## Reproducing the analysis

1. Download the source data from the OSF project linked above.
2. Place the required files in the appropriate subfolders under `data/`, following each folder-level README.
3. Run the source-specific preprocessing scripts to construct:
   - a node table;
   - an edge table; and
   - a prior-collaboration matrix for each network.
4. Check the generated node and edge counts against the tables in this README.
5. Run the separate-network ERGM scripts.
6. Run the GitHub and SciSciNet block-diagonal ERGM scripts.
7. Compare the generated workbooks with the files under `results/`.
8. Run the figure and supplementary-material scripts, if applicable.

Exact command-line instructions will be maintained in the folder-level README files alongside the corresponding scripts.

## Software

Data processing and network construction are performed in Python. ERGM estimation is performed in R using the `network` and `ergm` packages from the Statnet ecosystem.

The recorded MyDreamTeam run used:

- R 4.5.3;
- `network` 1.20.0;
- `ergm` 4.12.0;
- `openxlsx` 4.2.8.1; and
- `igraph` 2.2.0.

The recorded random seed for that run was `20260722`. Source-specific scripts and result metadata should be treated as the authoritative record for each analysis.

## Interpretation and scope

ERGM coefficients represent conditional associations with tie formation under the specified network model. They should not be interpreted as causal effects. Comparisons across settings should also account for differences in institutional context, observation windows, network construction, and variable operationalization.

The main comparative result is that prior collaboration is the most consistent positive correlate of current collaboration across the three settings, whereas associations involving expertise and leadership-related status vary more across domains and individual networks.

## Citation

If you use the data, code, or results in this repository, please cite:

1. the associated manuscript, once its full citation is available;
2. the OSF project linked in the data-availability section; and
3. the relevant original data source or documentation for MyDreamTeam, GHTorrent, and/or SciSciNet.

A complete manuscript citation and DOI will be added after publication.

## License

The original data remain subject to the licensing and terms specified by the OSF project and the underlying data providers. No repository-wide license is implied for third-party data.

## Contact

For questions about this repository, please open a GitHub issue.
