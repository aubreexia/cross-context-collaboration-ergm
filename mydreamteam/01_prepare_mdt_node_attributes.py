"""Build analysis-ready MyDreamTeam inputs from the two source CSV files.

Required source files
---------------------
1. users_profiles.csv
   Required columns: user_id, team_id, leadership.score, and one or more
   columns whose names begin with project.skill.
2. relationships.csv
   Required columns: network_type, source, and target.

The script:
- derives team membership directly from users_profiles.csv;
- computes expertise as the row mean of project.skill* columns;
- extracts leadership.score;
- constructs undirected same-team collaboration edges;
- constructs a binary, undirected prior-work matrix from relationships.csv;
- removes isolates and users without complete covariates;
- writes audit tables and a count-reconciliation summary.

Source files are never modified.
"""

from __future__ import annotations

import argparse
import re
from itertools import combinations
from pathlib import Path

import numpy as np
import pandas as pd


INVALID_IDS = {"", "nan", "none", "null", "<na>"}
MDT_PREFIX = "MDT_"


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description=(
            "Prepare MyDreamTeam nodes, edges, and prior-collaboration matrix "
            "from users_profiles.csv and relationships.csv."
        )
    )
    parser.add_argument(
        "--users",
        type=Path,
        default=Path("data/raw/mydreamteam/users_profiles.csv"),
        help="Path to users_profiles.csv.",
    )
    parser.add_argument(
        "--relationships",
        type=Path,
        default=Path("data/raw/mydreamteam/relationships.csv"),
        help="Path to relationships.csv.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("data/processed/mydreamteam"),
        help="Directory for processed outputs and audit files.",
    )
    return parser.parse_args()


def require_columns(
    frame: pd.DataFrame,
    required: set[str],
    source: Path,
) -> None:
    """Raise a clear error when required columns are absent."""
    missing = required - set(frame.columns)
    if missing:
        raise KeyError(f"{source} is missing required columns: {sorted(missing)}")


def normalize_id(series: pd.Series) -> pd.Series:
    """Normalize IDs while preserving missing values."""
    normalized = series.astype("string").str.strip()

    normalized = normalized.mask(
        normalized.str.lower().isin(INVALID_IDS),
        pd.NA,
    )

    # Normalize 101.0 to 101.
    return normalized.str.replace(
        r"^([+-]?\d+)\.0+$",
        r"\1",
        regex=True,
    )


def project_skill_sort_key(column: str) -> tuple[int, int, str]:
    """Sort project.skill, project.skill.1, project.skill.2, ... naturally."""
    if column == "project.skill":
        return (0, 0, column)

    match = re.fullmatch(r"project\.skill\.(\d+)", column)

    if match:
        return (1, int(match.group(1)), column)

    return (2, 0, column)


def find_project_skill_columns(columns: pd.Index) -> list[str]:
    """Return naturally sorted columns beginning with project.skill."""
    selected = [
        column
        for column in columns
        if column.startswith("project.skill")
    ]

    return sorted(selected, key=project_skill_sort_key)


def z_score_preserve_missing(series: pd.Series) -> pd.Series:
    """Z-standardize observed values while preserving missing values."""
    mean_value = series.mean(skipna=True)
    sd_value = series.std(skipna=True)

    if pd.isna(sd_value) or sd_value == 0:
        result = pd.Series(np.nan, index=series.index, dtype=float)
        result.loc[series.notna()] = 0.0
        return result

    return (series - mean_value) / sd_value


def save_audit(frame: pd.DataFrame, path: Path) -> None:
    """Write an audit table, including an empty table."""
    frame.to_csv(path, index=False)
    print(f"[audit] {path}")


def collapse_user_attribute(
    frame: pd.DataFrame,
    value_column: str,
    label: str,
    audit_dir: Path,
) -> pd.DataFrame:
    """Return one non-conflicting attribute value per user."""

    duplicate_rows = frame[
        frame.duplicated(subset=["user_id"], keep=False)
    ].sort_values(
        ["user_id", value_column],
        na_position="last",
    )

    save_audit(
        duplicate_rows,
        audit_dir / f"{label}_duplicate_profile_rows.csv",
    )

    value_counts = (
        frame.groupby("user_id")[value_column]
        .nunique(dropna=True)
    )

    conflicting_ids = value_counts[value_counts > 1].index

    conflicts = frame[
        frame["user_id"].isin(conflicting_ids)
    ].copy()

    save_audit(
        conflicts,
        audit_dir / f"{label}_conflicting_values.csv",
    )

    if len(conflicting_ids) > 0:
        raise ValueError(
            f"{len(conflicting_ids)} user(s) have conflicting "
            f"{label} values. Review "
            f"'{audit_dir / f'{label}_conflicting_values.csv'}'."
        )

    collapsed = (
        frame.assign(_missing=frame[value_column].isna())
        .sort_values(["user_id", "_missing"])
        .drop_duplicates(subset=["user_id"], keep="first")
        [["user_id", value_column]]
        .sort_values("user_id")
        .reset_index(drop=True)
    )

    if not collapsed["user_id"].is_unique:
        raise AssertionError(
            f"Duplicate user_id remained in {label}."
        )

    return collapsed


def canonicalize_pairs(
    frame: pd.DataFrame,
    first: str,
    second: str,
) -> pd.DataFrame:
    """Convert directed pairs to unique undirected pairs."""

    pair_frame = frame[[first, second]].copy()

    pair_frame = pair_frame[
        pair_frame[first].notna()
        & pair_frame[second].notna()
        & pair_frame[first].ne(pair_frame[second])
    ].copy()

    first_values = pair_frame[first].to_numpy(dtype=str)
    second_values = pair_frame[second].to_numpy(dtype=str)

    pair_frame["user_id_1"] = np.where(
        first_values <= second_values,
        first_values,
        second_values,
    )

    pair_frame["user_id_2"] = np.where(
        first_values <= second_values,
        second_values,
        first_values,
    )

    return (
        pair_frame[["user_id_1", "user_id_2"]]
        .drop_duplicates()
        .sort_values(["user_id_1", "user_id_2"])
        .reset_index(drop=True)
    )


def main() -> None:
    """Run the complete MyDreamTeam preprocessing workflow."""

    args = parse_args()

    output_dir = args.output_dir
    audit_dir = output_dir / "audit"

    output_dir.mkdir(parents=True, exist_ok=True)
    audit_dir.mkdir(parents=True, exist_ok=True)

    # =====================================================
    # 1. Read the two source files
    # =====================================================

    users_raw = pd.read_csv(
        args.users,
        dtype="string",
        low_memory=False,
    )

    relationships_raw = pd.read_csv(
        args.relationships,
        dtype="string",
        low_memory=False,
    )

    users_raw.columns = users_raw.columns.str.strip()
    relationships_raw.columns = (
        relationships_raw.columns.str.strip()
    )

    require_columns(
        users_raw,
        {"user_id", "team_id", "leadership.score"},
        args.users,
    )

    require_columns(
        relationships_raw,
        {"network_type", "source", "target"},
        args.relationships,
    )

    project_skill_columns = find_project_skill_columns(
        users_raw.columns
    )

    if not project_skill_columns:
        raise KeyError(
            f"{args.users} contains no columns beginning "
            "with 'project.skill'."
        )

    users = users_raw.copy()
    relationships = relationships_raw.copy()

    users["user_id"] = normalize_id(users["user_id"])
    users["team_id"] = normalize_id(users["team_id"])

    relationships["network_type"] = (
        relationships["network_type"]
        .astype("string")
        .str.strip()
    )

    relationships["source"] = normalize_id(
        relationships["source"]
    )

    relationships["target"] = normalize_id(
        relationships["target"]
    )

    save_audit(
        users[users["user_id"].isna()].copy(),
        audit_dir / "profiles_invalid_user_ids.csv",
    )

    save_audit(
        users[
            users["user_id"].notna()
            & users["team_id"].isna()
        ].copy(),
        audit_dir / "profiles_users_without_team.csv",
    )

    # =====================================================
    # 2. Derive team memberships
    # =====================================================

    membership_rows = users[
        users["user_id"].notna()
        & users["team_id"].notna()
    ].copy()

    duplicate_memberships = membership_rows[
        membership_rows.duplicated(
            subset=["user_id", "team_id"],
            keep=False,
        )
    ].sort_values(["user_id", "team_id"])

    save_audit(
        duplicate_memberships,
        audit_dir / "duplicate_user_team_memberships.csv",
    )

    team_memberships = (
        membership_rows[["user_id", "team_id"]]
        .drop_duplicates()
        .sort_values(["team_id", "user_id"])
        .reset_index(drop=True)
    )

    user_team_counts = (
        team_memberships.groupby("user_id")["team_id"]
        .nunique()
    )

    multi_team_ids = user_team_counts[
        user_team_counts > 1
    ].index

    save_audit(
        team_memberships[
            team_memberships["user_id"].isin(multi_team_ids)
        ].sort_values(["user_id", "team_id"]),
        audit_dir / "users_in_multiple_teams.csv",
    )

    target_users = sorted(
        team_memberships["user_id"].unique().tolist()
    )

    target_set = set(target_users)

    # =====================================================
    # 3. Derive expertise and leadership
    # =====================================================

    attribute_rows = users[
        users["user_id"].isin(target_set)
    ].copy()

    for column in project_skill_columns:
        attribute_rows[column] = pd.to_numeric(
            attribute_rows[column],
            errors="coerce",
        )

    attribute_rows["leadership.score"] = pd.to_numeric(
        attribute_rows["leadership.score"],
        errors="coerce",
    )

    attribute_rows["avg_project_skill"] = (
        attribute_rows[project_skill_columns]
        .mean(axis=1, skipna=True)
    )

    expertise = collapse_user_attribute(
        attribute_rows[
            ["user_id", "avg_project_skill"]
        ].copy(),
        value_column="avg_project_skill",
        label="expertise",
        audit_dir=audit_dir,
    )

    leadership = collapse_user_attribute(
        attribute_rows[
            ["user_id", "leadership.score"]
        ]
        .rename(
            columns={
                "leadership.score": "leadership_score"
            }
        )
        .copy(),
        value_column="leadership_score",
        label="leadership",
        audit_dir=audit_dir,
    )

    # These are outputs, not required source inputs.
    expertise.to_csv(
        output_dir
        / "mdt_team_users_project_skill_average.csv",
        index=False,
    )

    leadership.to_csv(
        output_dir
        / "mdt_team_users_leadership_score.csv",
        index=False,
    )

    team_memberships.to_csv(
        output_dir / "mdt_team_memberships.csv",
        index=False,
    )

    # =====================================================
    # 4. Construct current same-team edges
    # =====================================================

    team_edges: list[tuple[str, str]] = []

    grouped_teams = (
        team_memberships.groupby("team_id")["user_id"]
        .apply(lambda values: sorted(set(values)))
    )

    for members in grouped_teams:
        if len(members) >= 2:
            team_edges.extend(combinations(members, 2))

    if team_edges:
        observed_edges = pd.DataFrame(
            team_edges,
            columns=["user_id_1", "user_id_2"],
        )

        observed_edges = (
            observed_edges
            .drop_duplicates()
            .sort_values(["user_id_1", "user_id_2"])
            .reset_index(drop=True)
        )

    else:
        observed_edges = pd.DataFrame(
            columns=["user_id_1", "user_id_2"]
        )

    # =====================================================
    # 5. Construct prior-work pairs
    # =====================================================

    work_rows = relationships[
        relationships["network_type"]
        .str.lower()
        .eq("work")
    ].copy()

    prior_pairs_all = canonicalize_pairs(
        work_rows,
        first="source",
        second="target",
    )

    prior_pairs = prior_pairs_all[
        prior_pairs_all["user_id_1"].isin(target_set)
        & prior_pairs_all["user_id_2"].isin(target_set)
    ].reset_index(drop=True)

    # =====================================================
    # 6. Construct node attributes
    # =====================================================

    nodes = pd.DataFrame({"user_id": target_users})

    nodes = nodes.merge(
        expertise,
        on="user_id",
        how="left",
        validate="one_to_one",
    )

    nodes = nodes.merge(
        leadership,
        on="user_id",
        how="left",
        validate="one_to_one",
    )

    nodes["expertise_raw"] = nodes["avg_project_skill"]
    nodes["leadership_raw"] = nodes["leadership_score"]

    negative_covariates = nodes[
        (nodes["expertise_raw"] < 0)
        | (nodes["leadership_raw"] < 0)
    ].copy()

    save_audit(
        negative_covariates,
        audit_dir / "negative_covariates.csv",
    )

    if not negative_covariates.empty:
        raise ValueError(
            "Negative expertise or leadership values were "
            "found; log1p cannot be applied safely. Review "
            f"'{audit_dir / 'negative_covariates.csv'}'."
        )

    nodes["log_expertise"] = np.log1p(
        nodes["expertise_raw"]
    )

    nodes["log_leadership"] = np.log1p(
        nodes["leadership_raw"]
    )

    nodes["expertise_z"] = z_score_preserve_missing(
        nodes["log_expertise"]
    )

    nodes["leadership_z"] = z_score_preserve_missing(
        nodes["log_leadership"]
    )

    missing_covariates = nodes[
        nodes["expertise_z"].isna()
        | nodes["leadership_z"].isna()
        | ~np.isfinite(nodes["expertise_z"])
        | ~np.isfinite(nodes["leadership_z"])
    ].copy()

    save_audit(
        missing_covariates,
        audit_dir / "missing_or_invalid_covariates.csv",
    )

    # =====================================================
    # 7. Retain complete nonisolated users
    # =====================================================

    observed_node_ids = set(
        observed_edges["user_id_1"]
    ).union(
        set(observed_edges["user_id_2"])
    )

    nodes_final = nodes[
        nodes["user_id"].isin(observed_node_ids)
        & nodes["expertise_z"].notna()
        & nodes["leadership_z"].notna()
        & np.isfinite(nodes["expertise_z"])
        & np.isfinite(nodes["leadership_z"])
    ].copy()

    valid_ids = set(nodes_final["user_id"])

    edges_final = observed_edges[
        observed_edges["user_id_1"].isin(valid_ids)
        & observed_edges["user_id_2"].isin(valid_ids)
    ].copy()

    # Complete-case deletion may create new isolates.
    final_edge_ids = set(
        edges_final["user_id_1"]
    ).union(
        set(edges_final["user_id_2"])
    )

    nodes_final = nodes_final[
        nodes_final["user_id"].isin(final_edge_ids)
    ].copy()

    node_order = sorted(
        nodes_final["user_id"].tolist()
    )

    nodes_final = (
        nodes_final
        .set_index("user_id")
        .loc[node_order]
        .reset_index()
    )

    edges_final = (
        edges_final[
            edges_final["user_id_1"].isin(node_order)
            & edges_final["user_id_2"].isin(node_order)
        ]
        .drop_duplicates()
        .sort_values(["user_id_1", "user_id_2"])
        .reset_index(drop=True)
    )

    # =====================================================
    # 8. Construct final prior matrix
    # =====================================================

    prior_matrix = pd.DataFrame(
        0.0,
        index=node_order,
        columns=node_order,
    )

    prior_pairs_final = prior_pairs[
        prior_pairs["user_id_1"].isin(node_order)
        & prior_pairs["user_id_2"].isin(node_order)
    ].copy()

    for pair in prior_pairs_final.itertuples(
        index=False
    ):
        prior_matrix.loc[
            pair.user_id_1,
            pair.user_id_2,
        ] = 1.0

        prior_matrix.loc[
            pair.user_id_2,
            pair.user_id_1,
        ] = 1.0

    np.fill_diagonal(prior_matrix.values, 0.0)

    # =====================================================
    # 9. Standardize output identifiers
    # =====================================================

    mdt_nodes = nodes_final.copy()

    mdt_nodes["global_id"] = (
        MDT_PREFIX + mdt_nodes["user_id"]
    )

    mdt_nodes["dataset"] = "MDT"

    mdt_nodes["expertise_raw_shared"] = (
        mdt_nodes["expertise_raw"]
    )

    mdt_nodes["leadership_raw_shared"] = (
        mdt_nodes["leadership_raw"]
    )

    mdt_nodes = mdt_nodes[
        [
            "global_id",
            "dataset",
            "user_id",
            "expertise_raw",
            "log_expertise",
            "expertise_z",
            "leadership_raw",
            "log_leadership",
            "leadership_z",
            "expertise_raw_shared",
            "leadership_raw_shared",
        ]
    ]

    mdt_edges = edges_final.copy()

    mdt_edges["u"] = (
        MDT_PREFIX + mdt_edges["user_id_1"]
    )

    mdt_edges["v"] = (
        MDT_PREFIX + mdt_edges["user_id_2"]
    )

    mdt_edges = (
        mdt_edges[["u", "v"]]
        .drop_duplicates()
    )

    prefixed_order = [
        MDT_PREFIX + user_id
        for user_id in node_order
    ]

    mdt_prior_matrix = prior_matrix.copy()
    mdt_prior_matrix.index = prefixed_order
    mdt_prior_matrix.columns = prefixed_order

    # =====================================================
    # 10. Mandatory validation
    # =====================================================

    assert mdt_nodes["user_id"].is_unique
    assert mdt_nodes["global_id"].is_unique

    assert not mdt_edges.duplicated(
        subset=["u", "v"]
    ).any()

    assert not (
        mdt_edges["u"] == mdt_edges["v"]
    ).any()

    final_global_ids = set(
        mdt_nodes["global_id"]
    )

    edge_global_ids = set(
        mdt_edges["u"]
    ).union(
        set(mdt_edges["v"])
    )

    assert edge_global_ids == final_global_ids

    assert mdt_prior_matrix.shape == (
        len(mdt_nodes),
        len(mdt_nodes),
    )

    assert list(
        mdt_prior_matrix.index
    ) == prefixed_order

    assert list(
        mdt_prior_matrix.columns
    ) == prefixed_order

    assert not mdt_prior_matrix.isna().values.any()

    assert np.allclose(
        mdt_prior_matrix.values,
        mdt_prior_matrix.values.T,
    )

    assert np.allclose(
        np.diag(mdt_prior_matrix.values),
        0.0,
    )

    assert set(
        np.unique(mdt_prior_matrix.values)
    ).issubset({0.0, 1.0})

    # =====================================================
    # 11. Save final outputs
    # =====================================================

    mdt_nodes.to_csv(
        output_dir / "mdt_nodes.csv",
        index=False,
    )

    mdt_edges.to_csv(
        output_dir / "mdt_edges.csv",
        index=False,
    )

    mdt_prior_matrix.to_csv(
        output_dir / "mdt_prior_mat.csv",
        index=True,
        index_label="global_id",
    )

    summary = pd.DataFrame(
        [
            ("raw_profile_rows", len(users_raw)),
            (
                "unique_valid_profile_users",
                users["user_id"].nunique(),
            ),
            (
                "valid_user_team_rows",
                len(membership_rows),
            ),
            (
                "unique_user_team_memberships",
                len(team_memberships),
            ),
            (
                "unique_team_users_before_cleaning",
                len(target_users),
            ),
            (
                "unique_teams",
                team_memberships["team_id"].nunique(),
            ),
            (
                "users_in_multiple_teams",
                len(multi_team_ids),
            ),
            (
                "project_skill_columns",
                len(project_skill_columns),
            ),
            (
                "raw_relationship_rows",
                len(relationships_raw),
            ),
            (
                "unique_work_pairs_all_users",
                len(prior_pairs_all),
            ),
            (
                "observed_edges_before_cleaning",
                len(observed_edges),
            ),
            (
                "users_missing_or_invalid_covariates",
                len(missing_covariates),
            ),
            (
                "final_unique_nonisolated_users",
                len(mdt_nodes),
            ),
            (
                "final_unique_observed_edges",
                len(mdt_edges),
            ),
            (
                "final_prior_work_pairs",
                int(
                    mdt_prior_matrix.values.sum() / 2
                ),
            ),
        ],
        columns=["metric", "value"],
    )

    summary.to_csv(
        output_dir / "mdt_processing_summary.csv",
        index=False,
    )

    print(
        "\nMyDreamTeam preprocessing "
        "completed successfully."
    )

    print(
        f"Project-skill columns: "
        f"{project_skill_columns}"
    )

    print(summary.to_string(index=False))

    print(
        f"\nOutputs saved in: {output_dir}"
    )


if __name__ == "__main__":
    main()
