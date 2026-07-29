# MyDreamTeam Network Preparation and ERGM Workflow

This directory contains the reproducible MyDreamTeam workflow:

```text
code/mydreamteam/
├── README.md
├── 01_prepare_mdt_session_networks.py
├── 02_mdt_separate_ergm.R
└── 03_mdt_block_diagonal_ergm.R
```

The Python script converts the two raw MyDreamTeam files into analysis-ready, session-level networks and aligned covariates. The two R scripts then estimate separate-session and block-diagonal ERGMs.

MyDreamTeam is a web-based platform through which participants create profiles, search for collaborators, send invitations, and assemble project teams. The participants in these data were students enrolled in academic or executive-education programs and worked on a shared creative task.

## Raw inputs

Download the source files from the project’s [OSF page](https://osf.io/mjhpd/overview?view_only=af9133fb34db457daabde1966c6c90b8) and place them at:

```text
data/raw/mydreamteam/users_profiles.csv
data/raw/mydreamteam/relationships.csv
```

### `users_profiles.csv`

Required columns:

| Column | Role |
| --- | --- |
| `user_id` | Exact participant identifier |
| `team_id` | Current MyDreamTeam team identifier |
| `leadership.score` | Leadership covariate |
| `project.skill*` | One or more project-skill items used to construct expertise |

### `relationships.csv`

Required columns:

| Column | Role |
| --- | --- |
| `network_type` | Relationship type; `work` identifies prior collaboration |
| `source` | First participant in the relationship |
| `target` | Second participant in the relationship |

> **Critical ID rule:** all raw columns are initially read as strings. An identifier such as `337.10` must never be parsed as a floating-point number, because doing so would convert it to `337.1` and could incorrectly merge two distinct participants.

## Session definition and inclusion

A participant’s session is the substring of `user_id` before the first period:

```text
337.10       -> session 337
341.a12bc34  -> session 341
```

The default threshold is `--min-members 20`. A session is eligible when it has **strictly more than 20** unique participants with nonmissing `user_id` and `team_id` before covariate and isolate filtering.

With the current source files, six sessions satisfy this rule:

```text
337, 341, 342, 344, 346, 349
```

## Variable construction

### Current collaboration network

Within each eligible session, participants with the same `team_id` are treated as current collaborators. Every unordered pair of participants within a current team becomes an undirected edge. Each team therefore forms a clique in the current network.

### Prior collaboration

Rows in `relationships.csv` for which `network_type` equals `work` are treated as prior work relationships. Self-ties are removed, duplicate directions are collapsed, and the remaining pairs are treated as undirected.

For every session, the script creates a symmetric binary prior-collaboration matrix:

- `1`: the pair had a recorded prior work relationship;
- `0`: no recorded prior work relationship;
- diagonal: always `0`.

The row and column order exactly matches the final node order.

### Expertise

Expertise is the row mean across every column whose name begins with `project.skill`. Available skill items are averaged while partial missingness is ignored. Expertise is missing only when all project-skill items are missing or the resulting value is non-finite.

### Leadership

Leadership is the numeric value of `leadership.score`. Missing or non-finite values are not retained in the analysis network.

## Filtering and validation

For each eligible session, the preprocessing script:

1. checks that a participant does not belong to multiple current teams in the same session;
2. aggregates duplicate profile rows to one row per participant;
3. retains only participants with finite expertise and leadership values;
4. creates all within-team current collaboration edges;
5. removes participants who become isolates after covariate filtering;
6. aligns the node, edge, expertise, leadership, and prior-collaboration files;
7. verifies unique node IDs, valid edge endpoints, no self-ties, complete covariates, a symmetric binary prior matrix, and identical node ordering across files;
8. writes output files only after all validation checks pass.

The audit file preserves the IDs of participants removed because of missing or invalid covariates.

## Run the Python preprocessing

From the repository root:

```bash
python code/mydreamteam/01_prepare_mdt_session_networks.py \
  --users data/raw/mydreamteam/users_profiles.csv \
  --relationships data/raw/mydreamteam/relationships.csv \
  --output data/processed/mydreamteam/mdt_by_session \
  --min-members 20 \
  --plot
```

Use `--plot` to save a 600-dpi PNG and a PDF visualization of each current team network. Omit it when only the analysis files are needed.

Required Python packages:

```bash
pip install pandas numpy networkx matplotlib
```

## Generated files

The script creates one subdirectory per eligible session:

```text
data/processed/mydreamteam/mdt_by_session/
├── session_covariate_prior_summary.csv
├── 337/
├── 341/
├── 342/
├── 344/
├── 346/
└── 349/
```

Each session directory contains:

| File | Description |
| --- | --- |
| `mdt_current_network_nodes.csv` | Final node list with `node_id` and `team_id` |
| `mdt_current_network_edges.csv` | Undirected current-team edges with `source`, `target`, and `team_id` |
| `mdt_team_users_project_skill_average.csv` | Expertise value for every final node |
| `mdt_team_users_leadership_score.csv` | Leadership value for every final node |
| `mdt_prior_mat.csv` | Symmetric binary prior-collaboration matrix |
| `mdt_users_removed_missing_covariates.csv` | Audit of participants excluded for invalid covariates |
| `session_<ID>_current_team_network.png` | Optional 600-dpi network plot |
| `session_<ID>_current_team_network.pdf` | Optional vector network plot |

The root summary file reports filtering counts, final network size, number of teams, covariate means, number of prior pairs, and prior-matrix dimensions.

## Current preprocessing summary

The validated notebook run produced the following final session networks:

| Session | Nodes | Current edges | Teams | Prior pairs | Isolates removed |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 337 | 20 | 30 | 5 | 7 | 3 |
| 341 | 28 | 42 | 7 | 11 | 0 |
| 342 | 24 | 36 | 6 | 1 | 2 |
| 344 | 26 | 37 | 7 | 1 | 0 |
| 346 | 24 | 36 | 6 | 0 | 2 |
| 349 | 23 | 33 | 6 | 0 | 2 |

These values should be treated as reproducibility checks for the current version of the source data and preprocessing rules. A changed source file or threshold may produce different values.

## ERGM scripts

After preprocessing:

```bash
Rscript code/mydreamteam/02_mdt_separate_ergm.R
Rscript code/mydreamteam/03_mdt_block_diagonal_ergm.R
```

- `02_mdt_separate_ergm.R` estimates one ERGM per eligible session.
- `03_mdt_block_diagonal_ergm.R` combines the eligible session networks into a single block-diagonal network while prohibiting cross-session ties.

Model specifications, convergence checks, and result-file definitions will be documented with the finalized R scripts.



