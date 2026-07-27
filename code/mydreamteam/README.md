# MyDreamTeam analysis

This directory contains the scripts used to construct the MyDreamTeam collaboration network and estimate the separate-network exponential random graph models (ERGMs).

The workflow contains two steps:

1. Python preprocessing and network construction;
2. R-based ERGM estimation.

## Directory contents

```text
code/mydreamteam/
├── README.md
├── 01_prepare_mdt_ergm_inputs.py
└── 02_run_mdt_ergm.R
```

| File | Description |
| --- | --- |
| `01_prepare_mdt_ergm_inputs.py` | Constructs the node table, current collaboration edges, and prior-collaboration matrix |
| `02_run_mdt_ergm.R` | Draws the observed network and estimates the M0–M4 ERGM sequence |

## Source data

The workflow begins with two source files:

```text
data/raw/mydreamteam/
├── users_profiles.csv
└── relationships.csv
```

The files used in this study were obtained from the public OSF project:

https://osf.io/mjhpd/overview?view_only=af9133fb34db457daabde1966c6c90b8

The source files are not modified by either script.

### Required columns

| Source file | Required columns | Purpose |
| --- | --- | --- |
| `users_profiles.csv` | `user_id`, `team_id`, `leadership.score`, and one or more `project.skill*` columns | Team membership, current collaboration, expertise, and leadership |
| `relationships.csv` | `network_type`, `source`, and `target` | Prior collaboration |

Files such as `mdt_team_user_ids.csv`, `mdt_team_users_project_skill_average.csv`, and `mdt_team_users_leadership_score.csv` are generated intermediate files. They are not required source inputs.

## Variable construction

### Current collaboration

A node represents a MyDreamTeam participant.

Two participants are connected in the current collaboration network when they share the same nonmissing `team_id` in `users_profiles.csv`.

The resulting network is undirected and binary.

### Prior collaboration

Prior collaboration is derived from `relationships.csv`.

Rows satisfying the following condition are retained:

```text
network_type == "work"
```

The `source` and `target` users in these rows are treated as having a prior collaboration relationship. Directed and duplicated records are converted into unique, binary, undirected user pairs.

### Expertise

Expertise is calculated as the row mean of all available columns beginning with:

```text
project.skill
```

This includes columns such as:

```text
project.skill
project.skill.1
project.skill.2
```

The raw expertise measure is transformed using `log1p` and then z-standardized.

### Leadership

Leadership-related status is measured using:

```text
leadership.score
```

The raw leadership measure is transformed using `log1p` and then z-standardized.

## Step 1: Python preprocessing

From the repository root, run:

```bash
python code/mydreamteam/01_prepare_mdt_ergm_inputs.py
```

The script:

1. reads `users_profiles.csv` and `relationships.csv`;
2. normalizes user identifiers;
3. derives unique user–team memberships;
4. calculates expertise;
5. extracts leadership scores;
6. constructs current same-team collaboration edges;
7. constructs the binary prior-collaboration matrix;
8. transforms and standardizes the actor attributes;
9. removes incomplete cases and resulting isolates;
10. verifies that the node, edge, and prior-matrix files use the same node set.

### Optional paths

Different file locations can be supplied through command-line options:

```bash
python code/mydreamteam/01_prepare_mdt_ergm_inputs.py \
  --users path/to/users_profiles.csv \
  --relationships path/to/relationships.csv \
  --output-dir path/to/output
```

### Python outputs

By default, the script writes:

```text
data/processed/mydreamteam/
├── mdt_team_memberships.csv
├── mdt_team_users_project_skill_average.csv
├── mdt_team_users_leadership_score.csv
├── mdt_nodes.csv
├── mdt_edges.csv
├── mdt_prior_mat.csv
├── mdt_processing_summary.csv
└── audit/
```

The primary ERGM input files are:

| File | Description |
| --- | --- |
| `mdt_nodes.csv` | Final nonisolated nodes with complete expertise and leadership covariates |
| `mdt_edges.csv` | Unique undirected current collaboration edges |
| `mdt_prior_mat.csv` | Binary symmetric prior-collaboration matrix aligned with the node order |

The other files document intermediate processing decisions and data-quality checks.

`mdt_processing_summary.csv` records the numbers of source rows, unique users, teams, current edges, prior-collaboration pairs, removed observations, and final analytical nodes.

The `audit/` directory records duplicate memberships, conflicting profile values, invalid identifiers, missing covariates, and users assigned to multiple teams.

## Step 2: ERGM estimation in R

After completing the Python preprocessing, run:

```bash
Rscript code/mydreamteam/02_run_mdt_ergm.R
```

The R script reads:

```text
data/processed/mydreamteam/
├── mdt_nodes.csv
├── mdt_edges.csv
└── mdt_prior_mat.csv
```

Before model estimation, it verifies:

- unique node identifiers;
- unique undirected edge pairs;
- absence of self-loops;
- agreement between the node and edge sets;
- agreement between the node order and prior matrix;
- symmetry and binary values of the prior matrix;
- absence of missing model covariates.

The R script uses the `expertise_z` and `leadership_z` variables generated by the Python script. It does not transform or standardize these variables a second time.

## ERGM sequence

The models are estimated sequentially:

| Model | Terms |
| --- | --- |
| M0 | Edges |
| M1 | M0 + prior collaboration |
| M2 | M1 + expertise level |
| M3 | M2 + absolute difference in expertise |
| M4 | M3 + leadership level + absolute difference in leadership |

The complete M4 specification is:

```r
mdt_network ~
  edges +
  edgecov(prior_mat) +
  nodecov("expertise_z") +
  absdiff("expertise_z") +
  nodecov("leadership_z") +
  absdiff("leadership_z")
```

The `nodecov` terms represent actor attribute levels. The `absdiff` terms represent the absolute difference between the attributes of two actors. A negative `absdiff` coefficient is consistent with a greater probability of collaboration between actors with more similar attribute values, conditional on the other model terms.

## R outputs

The R script writes:

```text
results/
├── separate_networks/
│   └── mydreamteam/
│       └── mdt_ergm_results.xlsx
└── figures/
    └── mdt_collaboration_network.png
```

The result workbook contains:

| Worksheet | Description |
| --- | --- |
| `coefficients` | Coefficient estimates from the complete M4 model |
| `model_fit` | AIC, BIC, and estimation status for M0–M4 |
| `network_summary` | Final nodes, edges, density, isolates, and prior-collaboration pairs |
| `failed_models` | Models that could not be estimated and their error messages |
| `run_settings` | Model definitions, random seed, package versions, and R version |

After a successful run, the console should report:

```text
Successful models: 5/5
```

## Software requirements

### Python

The preprocessing script requires:

```text
pandas
numpy
```

Install these packages with:

```bash
pip install pandas numpy
```

### R

The ERGM script requires:

```r
install.packages(c(
  "network",
  "ergm",
  "openxlsx",
  "igraph"
))
```

## Complete execution order

Run both scripts from the repository root:

```bash
python code/mydreamteam/01_prepare_mdt_ergm_inputs.py
Rscript code/mydreamteam/02_run_mdt_ergm.R
```

Do not run the R script before the Python script, because the R analysis requires the three processed network files generated during preprocessing.

The source files should be downloaded from that project and placed in
`data/raw/mydreamteam/`. This repository can provide the processing code and
derived analysis files without duplicating the original source files.

