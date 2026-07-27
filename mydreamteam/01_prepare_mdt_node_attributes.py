"""Prepare MyDreamTeam expertise and leadership node attributes.

This script restricts ``users_profiles.csv`` to users listed in
``mdt_team_user_ids.csv`` and creates two user-level covariate files:

1. Mean project-skill score (expertise)
2. Leadership score

The script also writes audit files and stops when duplicate profile records
assign conflicting values to the same user. Source files are never overwritten.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import pandas as pd


INVALID_IDS = {"", "nan", "none", "null", "<na>"}


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Prepare MyDreamTeam expertise and leadership covariates."
    )
    parser.add_argument(
        "--team-users",
        type=Path,
        default=Path("data/raw/mydreamteam/mdt_team_user_ids.csv"),
        help="CSV containing the user_id values included in the MDT network.",
    )
    parser.add_argument(
        "--profiles",
        type=Path,
        default=Path("data/raw/mydreamteam/users_profiles.csv"),
        help="CSV containing project.skill* and leadership.score columns.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("data/processed/mydreamteam"),
        help="Directory for processed covariates and audit files.",
    )
    return parser.parse_args()


def require_columns(
    frame: pd.DataFrame,
    required: set[str],
    source: Path,
) -> None:
    """Raise a clear error when a required column is missing."""
    missing = required - set(frame.columns)
    if missing:
        raise KeyError(f"{source} is missing required columns: {sorted(missing)}")


def normalize_user_id(series: pd.Series) -> pd.Series:
    """Normalize IDs while preserving missing values.

    This also fixes a common spreadsheet artifact, such as ``101.0`` being
    read as a different identifier from ``101``.
    """
    normalized = series.astype("string").str.strip()
    normalized = normalized.mask(normalized.str.lower().isin(INVALID_IDS), pd.NA)
    return normalized.str.replace(r"^([+-]?\d+)\.0+$", r"\1", regex=True)


def project_skill_sort_key(column: str) -> tuple[int, int, str]:
    """Sort project.skill, project.skill.1, project.skill.2, ... naturally."""
    if column == "project.skill":
        return (0, 0, column)

    match = re.fullmatch(r"project\.skill\.(\d+)", column)
    if match:
        return (1, int(match.group(1)), column)

    return (2, 0, column)


def find_project_skill_columns(columns: pd.Index) -> list[str]:
    """Return naturally sorted columns beginning with ``project.skill``."""
    selected = [column for column in columns if column.startswith("project.skill")]
    return sorted(selected, key=project_skill_sort_key)


def save_audit(frame: pd.DataFrame, path: Path) -> None:
    """Write one audit table, including an empty table when no issue is found."""
    frame.to_csv(path, index=False)
    print(f"[audit] {path}")


def collapse_user_values(
    frame: pd.DataFrame,
    value_column: str,
    label: str,
    audit_dir: Path,
) -> pd.DataFrame:
    """Return one non-conflicting value per user.

    Exact repeats and repeated missing values are harmless. If a user has more
    than one distinct nonmissing value, the relevant rows are saved and the
    script stops rather than silently selecting the first row.
    """
    duplicate_rows = frame[
        frame.duplicated(subset=["user_id"], keep=False)
    ].sort_values(["user_id", value_column], na_position="last")
    save_audit(duplicate_rows, audit_dir / f"{label}_duplicate_profile_rows.csv")

    distinct_value_counts = (
        frame.groupby("user_id", dropna=False)[value_column]
        .nunique(dropna=True)
    )
    conflicting_ids = distinct_value_counts[distinct_value_counts > 1].index
    conflicts = frame[frame["user_id"].isin(conflicting_ids)].copy()
    save_audit(conflicts, audit_dir / f"{label}_conflicting_values.csv")

    if len(conflicting_ids) > 0:
        raise ValueError(
            f"{len(conflicting_ids)} user(s) have conflicting {label} values. "
            f"Review {audit_dir / f'{label}_conflicting_values.csv'}."
        )

    # A valid value is sorted before NA so that it is retained when a user has
    # both a populated and an empty duplicate row.
    collapsed = (
        frame.assign(_missing=frame[value_column].isna())
        .sort_values(["user_id", "_missing"])
        .drop_duplicates(subset=["user_id"], keep="first")
        [["user_id", value_column]]
        .sort_values("user_id")
        .reset_index(drop=True)
    )
    return collapsed


def main() -> None:
    """Run the attribute-preparation workflow."""
    args = parse_args()
    output_dir = args.output_dir
    audit_dir = output_dir / "audit"
    output_dir.mkdir(parents=True, exist_ok=True)
    audit_dir.mkdir(parents=True, exist_ok=True)

    team_users_raw = pd.read_csv(args.team_users, dtype="string")
    profiles_raw = pd.read_csv(args.profiles, dtype="string", low_memory=False)
    team_users_raw.columns = team_users_raw.columns.str.strip()
    profiles_raw.columns = profiles_raw.columns.str.strip()

    require_columns(team_users_raw, {"user_id"}, args.team_users)
    require_columns(
        profiles_raw,
        {"user_id", "leadership.score"},
        args.profiles,
    )

    project_skill_columns = find_project_skill_columns(profiles_raw.columns)
    if not project_skill_columns:
        raise KeyError(
            f"{args.profiles} contains no columns beginning with 'project.skill'."
        )

    team_users = team_users_raw.copy()
    profiles = profiles_raw.copy()
    team_users["user_id"] = normalize_user_id(team_users["user_id"])
    profiles["user_id"] = normalize_user_id(profiles["user_id"])

    save_audit(
        team_users[team_users["user_id"].isna()].copy(),
        audit_dir / "team_users_invalid_user_ids.csv",
    )
    save_audit(
        profiles[profiles["user_id"].isna()].copy(),
        audit_dir / "profiles_invalid_user_ids.csv",
    )

    team_users = (
        team_users[team_users["user_id"].notna()][["user_id"]]
        .drop_duplicates()
        .sort_values("user_id")
        .reset_index(drop=True)
    )
    profiles = profiles[profiles["user_id"].notna()].copy()

    matched = profiles.merge(
        team_users,
        on="user_id",
        how="inner",
        validate="many_to_one",
    )

    unmatched_team_users = team_users[
        ~team_users["user_id"].isin(matched["user_id"])
    ].copy()
    save_audit(
        unmatched_team_users,
        audit_dir / "team_users_missing_from_profiles.csv",
    )

    for column in project_skill_columns:
        matched[column] = pd.to_numeric(matched[column], errors="coerce")
    matched["leadership.score"] = pd.to_numeric(
        matched["leadership.score"],
        errors="coerce",
    )

    matched["avg_project_skill"] = matched[project_skill_columns].mean(
        axis=1,
        skipna=True,
    )

    expertise = collapse_user_values(
        matched[["user_id", "avg_project_skill"]].copy(),
        value_column="avg_project_skill",
        label="expertise",
        audit_dir=audit_dir,
    )
    leadership = collapse_user_values(
        matched[["user_id", "leadership.score"]]
        .rename(columns={"leadership.score": "leadership_score"})
        .copy(),
        value_column="leadership_score",
        label="leadership",
        audit_dir=audit_dir,
    )

    expertise_path = output_dir / "mdt_team_users_project_skill_average.csv"
    leadership_path = output_dir / "mdt_team_users_leadership_score.csv"
    expertise.to_csv(expertise_path, index=False)
    leadership.to_csv(leadership_path, index=False)

    summary = pd.DataFrame(
        {
            "metric": [
                "team_user_rows_raw",
                "unique_valid_team_users",
                "profile_rows_raw",
                "unique_valid_profile_users",
                "matched_profile_rows",
                "unique_matched_users",
                "team_users_missing_from_profiles",
                "project_skill_columns",
                "users_missing_expertise",
                "users_missing_leadership",
            ],
            "value": [
                len(team_users_raw),
                team_users["user_id"].nunique(),
                len(profiles_raw),
                profiles["user_id"].nunique(),
                len(matched),
                matched["user_id"].nunique(),
                len(unmatched_team_users),
                len(project_skill_columns),
                int(expertise["avg_project_skill"].isna().sum()),
                int(leadership["leadership_score"].isna().sum()),
            ],
        }
    )
    summary_path = output_dir / "mdt_attribute_processing_summary.csv"
    summary.to_csv(summary_path, index=False)

    if not expertise["user_id"].is_unique:
        raise AssertionError("Duplicate user_id found in the expertise output.")
    if not leadership["user_id"].is_unique:
        raise AssertionError("Duplicate user_id found in the leadership output.")

    print("\nMyDreamTeam node attributes prepared successfully.")
    print(f"Project-skill columns found: {project_skill_columns}")
    print(f"Expertise output: {expertise_path}")
    print(f"Leadership output: {leadership_path}")
    print(f"Processing summary: {summary_path}")


if __name__ == "__main__":
    main()
