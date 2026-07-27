# MyDreamTeam preprocessing

This directory contains the scripts used to construct the MyDreamTeam network
inputs for the ERGM analysis.

## Script order

1. `01_prepare_mdt_node_attributes.py`
   - restricts `users_profiles.csv` to the users in
     `mdt_team_user_ids.csv`;
   - calculates mean project skill as the expertise measure;
   - extracts `leadership.score` as the leadership measure;
   - checks invalid IDs, duplicate records, conflicting values, and unmatched
     users;
   - produces one row per user in each output file.
2. `02_build_mdt_network.py`
   - uses the prepared node attributes to construct the node table, observed
     collaboration edges, and prior-collaboration matrix.

The second script is maintained separately because attribute preparation and
network construction are distinct reproducibility steps.

## Required input files

Place the following source files in `data/raw/mydreamteam/`:

```text
data/raw/mydreamteam/
├── mdt_team_user_ids.csv
└── users_profiles.csv
```

Required columns:

| File | Required columns |
| --- | --- |
| `mdt_team_user_ids.csv` | `user_id` |
| `users_profiles.csv` | `user_id`, `leadership.score`, and one or more columns beginning with `project.skill` |

## Run

From the repository root:

```bash
python code/mydreamteam/01_prepare_mdt_node_attributes.py
```

Custom locations can be supplied when needed:

```bash
python code/mydreamteam/01_prepare_mdt_node_attributes.py \
  --team-users path/to/mdt_team_user_ids.csv \
  --profiles path/to/users_profiles.csv \
  --output-dir path/to/output
```

## Outputs

The default output directory is `data/processed/mydreamteam/`:

```text
data/processed/mydreamteam/
├── mdt_team_users_project_skill_average.csv
├── mdt_team_users_leadership_score.csv
├── mdt_attribute_processing_summary.csv
└── audit/
```

`mdt_team_users_project_skill_average.csv` contains:

| Column | Description |
| --- | --- |
| `user_id` | Normalized MyDreamTeam user identifier |
| `avg_project_skill` | Row mean across all available `project.skill*` fields |

`mdt_team_users_leadership_score.csv` contains:

| Column | Description |
| --- | --- |
| `user_id` | Normalized MyDreamTeam user identifier |
| `leadership_score` | Numeric value extracted from `leadership.score` |

The audit directory records invalid IDs, repeated profile rows, conflicting
attribute values, and team users not found in the profile file. Empty audit
files mean that no corresponding issue was detected.

## Duplicate-user handling

- Repeated IDs in `mdt_team_user_ids.csv` are reduced to one target user.
- Repeated profile rows are permitted only when their derived values agree.
- When the same user has conflicting nonmissing expertise or leadership values,
  the script writes the conflicting rows to `audit/` and stops.
- Each final attribute file is verified to contain a unique `user_id`.

## Data provenance

The source data used in this study were obtained from the public OSF project:

https://osf.io/mjhpd/overview?view_only=af9133fb34db457daabde1966c6c90b8

Users should consult the source project for its documentation, citation
instructions, and terms of use.
