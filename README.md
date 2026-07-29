# Cross-Context Collaboration ERGM

This repository contains the reproducible data-processing and modeling workflow for a comparative study of collaboration networks across three settings:

- **MyDreamTeam**: student team formation on a web-based platform;
- **GitHub**: open-source project collaboration derived from GHTorrent;
- **SciSciNet**: scientific coauthorship networks derived from SciSciNet.

The study examines whether three mechanisms are consistently associated with collaboration ties across these settings:

1. **Prior collaboration**: whether two actors collaborated before the focal network was observed;
2. **Expertise**: an actor-level measure of task-relevant experience or skill;
3. **Leadership-related status**: an actor-level measure of leadership, visibility, or scholarly status.

Exponential random graph models (ERGMs) are estimated in two complementary ways:

- **separate-network ERGMs**, estimated for each session, programming language, or journal network; and
- **block-diagonal ERGMs**, which combine networks from the same data domain while structurally prohibiting ties between blocks.

The analyses do not pool actors or ties across MyDreamTeam, GitHub, and SciSciNet.

## Repository structure

```text
cross-context-collaboration-ergm/
├── README.md
├── code/
│   ├── mydreamteam/
│   │   ├── README.md
│   │   ├── 01_prepare_mdt_session_networks.py
│   │   ├── 02_mdt_separate_ergm.R
│   │   └── 03_mdt_block_diagonal_ergm.R
│   ├── github/
│   │   ├── README.md
│   │   ├── 01_prepare_github_networks.py
│   │   ├── 02_github_separate_ergm.R
│   │   └── 03_github_block_diagonal_ergm.R
│   └── sciscinet/
│       ├── README.md
│       ├── 01_prepare_sciscinet_networks.py
│       ├── 02_sciscinet_separate_ergm.R
│       └── 03_sciscinet_block_diagonal_ergm.R
├── data/
│   ├── README.md
│   ├── raw/
│   │   ├── mydreamteam/
│   │   ├── github/
│   │   └── sciscinet/
│   └── processed/
│       ├── mydreamteam/
│       ├── github/
│       └── sciscinet/
├── results/
│   ├── mydreamteam/
│   │   ├── separate/
│   │   └── block_diagonal/
│   ├── github/
│   │   ├── separate/
│   │   └── block_diagonal/
│   └── sciscinet/
│       ├── separate/
│       └── block_diagonal/
├── figures/
└── supplementary/
    ├── network_documentation/
    └── reports/
```

The domain-specific README files document the exact input files, variable definitions, filtering rules, and outputs for each workflow.

## Data access

The original data files are not redistributed through this repository. Source files and data documentation are available from the project’s OSF page:

**[Download the source data from OSF](https://osf.io/mjhpd/overview?view_only=af9133fb34db457daabde1966c6c90b8)**

After downloading the required files, place them in the corresponding subdirectories under `data/raw/`. The scripts write analysis-ready files to `data/processed/`.

For the MyDreamTeam workflow, the required raw files are:

Large, restricted, or source-provided raw files should remain outside version control. This repository provides the code needed to reconstruct the analysis inputs.

## Reproduction workflow

Run each data domain independently:

1. Download and place the raw source files under `data/raw/`.
2. Run the domain’s Python preprocessing script.
3. Run the separate-network ERGM script.
4. Run the within-domain block-diagonal ERGM script.
5. Review the model outputs under `results/` and the network documentation under `supplementary/`.

## Software

The preprocessing workflows use Python 3.11 and commonly require:

- `pandas`
- `numpy`
- `networkx`
- `matplotlib`

The statistical analyses use R and the `statnet` ecosystem, including `network` and `ergm`. Exact package requirements and model specifications are documented alongside the corresponding R scripts.

## Reproducibility notes

- Actor identifiers must always be read and stored as strings.
- Current collaboration, prior collaboration, expertise, and leadership-related status are constructed separately within each data domain.
- Block-diagonal models combine networks only within the same data domain.
- Cross-block ties are structural zeros rather than observed non-ties.
- Generated summaries and validation checks should be reviewed before ERGM estimation.

## Citation

A manuscript citation will be added after publication. Until then, please cite the original data sources and this repository when reusing the workflow.

