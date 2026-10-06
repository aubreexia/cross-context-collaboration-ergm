#!/usr/bin/env python3
"""Build one April-2020 GHTorrent language network for ERGM estimation.

This script implements the sampling and measurement design used for the
GHTorrent analysis:

1. Keep user--repository pairs with at least 10 commits between 2020-04-01
   (inclusive) and 2020-05-01 (exclusive).
2. Within a programming language, count each user's qualifying repositories
   and retain users at or above the language-specific 99th-percentile
   nearest-rank cutoff, retaining ties.
3. Define a focal tie when two retained users qualify in the same repository.
4. Before the focal window, construct (a) the binary prior co-contribution
   matrix and (b) expertise as the number of distinct prior repositories in
   the same language.
5. Construct follower-count status, then apply log(1 + x) and within-network
   standardization to expertise and status.

The script writes only analysis-ready node, edge, and prior-matrix files. It
does not distribute the raw GHTorrent snapshot or generated actor-level data.
"""

from __future__ import annotations

import argparse
import json
import math
import re
from collections import Counter, defaultdict
from itertools import combinations
from pathlib import Path
from typing import Iterable

import numpy as np
import pandas as pd


NULL_VALUES = {"", "\\N", "N", "NA", "NAN", "<NA>", "NULL", "NONE"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build one language-specific April 2020 GHTorrent ERGM input set."
    )
    parser.add_argument("--raw-dir", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--language", required=True)
    parser.add_argument("--focal-start", default="2020-04-01")
    parser.add_argument("--focal-end", default="2020-05-01")
    parser.add_argument(
        "--minimum-commits-per-user-project",
        type=int,
        default=10,
        help="Inclusive April commit threshold for a user--repository pair (default: 10).",
    )
    parser.add_argument(
        "--user-quantile",
        type=float,
        default=0.99,
        help="Within-language upper-tail cutoff for qualifying-repository counts (default: .99).",
    )
    parser.add_argument("--chunksize", type=int, default=500_000)
    parser.add_argument("--commits-csv", type=Path)
    parser.add_argument("--projects-csv", type=Path)
    parser.add_argument("--followers-csv", type=Path)
    parser.add_argument(
        "--allow-undated-followers",
        action="store_true",
        help=(
            "Use follower rows even when the source has no relationship date. "
            "Without this flag, the script stops rather than silently using a post-focal snapshot."
        ),
    )
    return parser.parse_args()


def normalize_name(value: object) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip()).casefold()


def safe_name(value: str) -> str:
    result = re.sub(r"[^A-Za-z0-9._-]+", "_", value.strip())
    return result.strip("_") or "language"


def clean_id(series: pd.Series) -> pd.Series:
    cleaned = series.astype("string").str.strip()
    invalid = cleaned.isna() | cleaned.str.upper().isin(NULL_VALUES)
    return cleaned.mask(invalid)


def parse_timestamp(value: str, label: str) -> pd.Timestamp:
    timestamp = pd.to_datetime(value, errors="coerce")
    if pd.isna(timestamp):
        raise ValueError(f"{label} must be a valid date, not {value!r}.")
    return pd.Timestamp(timestamp).tz_localize(None)


def parse_datetime_series(values: pd.Series) -> pd.Series:
    """Parse mixed timestamp encodings and compare them as naive UTC times."""
    parsed = pd.to_datetime(values, errors="coerce", utc=True)
    return parsed.dt.tz_localize(None)


def read_header(path: Path) -> list[str]:
    if not path.is_file():
        raise FileNotFoundError(f"Required input file not found: {path}")
    frame = pd.read_csv(
        path,
        nrows=0,
        dtype="string",
        escapechar="\\",
        doublequote=False,
        on_bad_lines="warn",
        keep_default_na=False,
    )
    return [str(column).strip() for column in frame.columns]


def pick_column(columns: Iterable[str], candidates: Iterable[str], label: str) -> str:
    lookup = {normalize_name(column): column for column in columns}
    for candidate in candidates:
        found = lookup.get(normalize_name(candidate))
        if found is not None:
            return found
    raise KeyError(
        f"Could not find a {label} column. Expected one of {list(candidates)}; "
        f"available columns are {list(columns)}"
    )


def pick_optional_column(columns: Iterable[str], candidates: Iterable[str]) -> str | None:
    lookup = {normalize_name(column): column for column in columns}
    for candidate in candidates:
        found = lookup.get(normalize_name(candidate))
        if found is not None:
            return found
    return None


def read_chunks(path: Path, usecols: list[str], chunksize: int):
    return pd.read_csv(
        path,
        usecols=usecols,
        chunksize=chunksize,
        dtype="string",
        escapechar="\\",
        doublequote=False,
        on_bad_lines="warn",
        keep_default_na=False,
    )


def nearest_rank_cutoff(values: Iterable[int], quantile: float) -> int:
    ordered = sorted(int(value) for value in values)
    if not ordered:
        raise ValueError("Cannot calculate a quantile from an empty distribution.")
    rank = max(1, min(len(ordered), math.ceil(quantile * len(ordered))))
    return ordered[rank - 1]


def log1p_zscore(values: pd.Series) -> tuple[pd.Series, pd.Series]:
    raw = pd.to_numeric(values, errors="coerce").fillna(0.0).astype(float)
    logged = np.log1p(raw)
    standard_deviation = logged.std(ddof=1)
    if not np.isfinite(standard_deviation) or standard_deviation == 0:
        z_score = pd.Series(0.0, index=raw.index)
    else:
        z_score = (logged - logged.mean()) / standard_deviation
    return logged, z_score


def language_projects(
    projects_csv: Path,
    language: str,
    chunksize: int,
) -> set[str]:
    columns = read_header(projects_csv)
    project_column = pick_column(columns, ("id", "project_id", "ProjectID"), "project ID")
    language_column = pick_column(
        columns,
        ("language", "primary_language", "Language"),
        "project language",
    )
    target = normalize_name(language)
    selected: set[str] = set()
    for chunk in read_chunks(projects_csv, [project_column, language_column], chunksize):
        project_ids = clean_id(chunk[project_column])
        language_values = chunk[language_column].astype("string").map(normalize_name)
        selected.update(project_ids[language_values.eq(target)].dropna().astype(str))
    if not selected:
        raise ValueError(f"No projects with language {language!r} were found in {projects_csv}.")
    return selected


def discover_commit_columns(commits_csv: Path) -> tuple[str, str, str]:
    columns = read_header(commits_csv)
    return (
        pick_column(columns, ("project_id", "ProjectID"), "commit project ID"),
        pick_column(columns, ("author_id", "AuthorID"), "commit author ID"),
        pick_column(columns, ("created_at", "CreatedAt", "date", "Date"), "commit date"),
    )


def qualifying_focal_pairs(
    commits_csv: Path,
    commit_columns: tuple[str, str, str],
    project_ids: set[str],
    focal_start: pd.Timestamp,
    focal_end: pd.Timestamp,
    chunksize: int,
    minimum_commits: int,
) -> tuple[dict[tuple[str, str], int], dict[str, int]]:
    project_column, author_column, date_column = commit_columns
    pair_counts: Counter[tuple[str, str]] = Counter()
    diagnostics: Counter[str] = Counter()
    for chunk in read_chunks(commits_csv, [project_column, author_column, date_column], chunksize):
        diagnostics["commit_rows_scanned"] += len(chunk)
        chunk[project_column] = clean_id(chunk[project_column])
        chunk[author_column] = clean_id(chunk[author_column])
        chunk[date_column] = parse_datetime_series(chunk[date_column])
        eligible = chunk[
            chunk[project_column].isin(project_ids)
            & chunk[author_column].notna()
            & chunk[date_column].notna()
            & (chunk[date_column] >= focal_start)
            & (chunk[date_column] < focal_end)
        ].copy()
        diagnostics["focal_commit_rows"] += len(eligible)
        if not eligible.empty:
            counts = eligible.groupby([project_column, author_column], sort=False).size()
            pair_counts.update({(str(project), str(author)): int(count) for (project, author), count in counts.items()})

    qualified = {
        pair: int(count)
        for pair, count in pair_counts.items()
        if count >= minimum_commits
    }
    diagnostics["active_user_project_pairs"] = len(pair_counts)
    diagnostics["qualifying_user_project_pairs"] = len(qualified)
    return qualified, dict(diagnostics)


def choose_users_and_current_edges(
    qualified_pairs: dict[tuple[str, str], int],
    quantile: float,
) -> tuple[set[str], list[tuple[str, str]], int, Counter[str]]:
    qualifying_repository_count: Counter[str] = Counter()
    contributors_by_project: dict[str, set[str]] = defaultdict(set)
    for (project, user) in qualified_pairs:
        qualifying_repository_count[user] += 1
        contributors_by_project[project].add(user)

    cutoff = nearest_rank_cutoff(qualifying_repository_count.values(), quantile)
    selected_users = {
        user
        for user, count in qualifying_repository_count.items()
        if count >= cutoff
    }

    current_edges: set[tuple[str, str]] = set()
    for contributors in contributors_by_project.values():
        retained = sorted(contributors.intersection(selected_users))
        current_edges.update(combinations(retained, 2))

    modeled_users = set().union(*[set(edge) for edge in current_edges]) if current_edges else set()
    return modeled_users, sorted(current_edges), cutoff, qualifying_repository_count


def build_history(
    commits_csv: Path,
    commit_columns: tuple[str, str, str],
    project_ids: set[str],
    modeled_users: set[str],
    focal_start: pd.Timestamp,
    chunksize: int,
) -> tuple[dict[str, set[str]], dict[str, set[str]], dict[str, int]]:
    project_column, author_column, date_column = commit_columns
    expertise_projects: dict[str, set[str]] = {user: set() for user in modeled_users}
    contributors_by_prior_project: dict[str, set[str]] = defaultdict(set)
    diagnostics: Counter[str] = Counter()
    for chunk in read_chunks(commits_csv, [project_column, author_column, date_column], chunksize):
        diagnostics["history_commit_rows_scanned"] += len(chunk)
        chunk[project_column] = clean_id(chunk[project_column])
        chunk[author_column] = clean_id(chunk[author_column])
        chunk[date_column] = parse_datetime_series(chunk[date_column])
        eligible = chunk[
            chunk[project_column].isin(project_ids)
            & chunk[author_column].isin(modeled_users)
            & chunk[date_column].notna()
            & (chunk[date_column] < focal_start)
        ].copy()
        diagnostics["history_commit_rows"] += len(eligible)
        if eligible.empty:
            continue
        for project, author in eligible[[project_column, author_column]].drop_duplicates().itertuples(index=False):
            project_id = str(project)
            author_id = str(author)
            expertise_projects[author_id].add(project_id)
            contributors_by_prior_project[project_id].add(author_id)
    return expertise_projects, contributors_by_prior_project, dict(diagnostics)


def build_prior_matrix(
    node_ids: list[str],
    contributors_by_prior_project: dict[str, set[str]],
) -> tuple[np.ndarray, int]:
    index = {node_id: position for position, node_id in enumerate(node_ids)}
    matrix = np.zeros((len(node_ids), len(node_ids)), dtype=np.int8)
    prior_pairs: set[tuple[str, str]] = set()
    for contributors in contributors_by_prior_project.values():
        retained = sorted(contributors.intersection(index))
        prior_pairs.update(combinations(retained, 2))
    for user_a, user_b in prior_pairs:
        i, j = index[user_a], index[user_b]
        matrix[i, j] = 1
        matrix[j, i] = 1
    return matrix, len(prior_pairs)


def follower_counts(
    followers_csv: Path,
    modeled_users: set[str],
    focal_start: pd.Timestamp,
    chunksize: int,
    allow_undated: bool,
) -> tuple[dict[str, float], str]:
    columns = read_header(followers_csv)
    target_column = pick_column(
        columns,
        ("user_id", "followee_id", "followed_id", "target_id", "UserID"),
        "followee/user ID in followers.csv",
    )
    count_column = pick_optional_column(columns, ("followers", "follower_count", "num_followers"))
    date_column = pick_optional_column(columns, ("created_at", "CreatedAt", "date", "Date"))
    if date_column is None and not allow_undated:
        raise ValueError(
            "followers.csv has no relationship date. Supply a follower snapshot known to precede "
            "the focal window, or explicitly use --allow-undated-followers."
        )

    usecols = [target_column]
    if count_column is not None:
        usecols.append(count_column)
    if date_column is not None:
        usecols.append(date_column)
    counts: Counter[str] = Counter()
    for chunk in read_chunks(followers_csv, list(dict.fromkeys(usecols)), chunksize):
        chunk[target_column] = clean_id(chunk[target_column])
        chunk = chunk[chunk[target_column].isin(modeled_users)].copy()
        if date_column is not None:
            chunk[date_column] = parse_datetime_series(chunk[date_column])
            chunk = chunk[chunk[date_column].notna() & (chunk[date_column] < focal_start)].copy()
        if chunk.empty:
            continue
        if count_column is None:
            counts.update(chunk[target_column].astype(str).tolist())
        else:
            numeric = pd.to_numeric(chunk[count_column], errors="coerce").fillna(0.0)
            counts.update(dict(zip(chunk[target_column].astype(str), numeric.astype(float))))

    source = f"{followers_csv.name}; target column={target_column}"
    if count_column is not None:
        source += f"; aggregate count column={count_column}"
    else:
        source += "; one row counted per follower relationship"
    if date_column is not None:
        source += f"; restricted to {date_column} before {focal_start.date()}"
    else:
        source += "; undated snapshot explicitly allowed"
    return {user: float(counts.get(user, 0.0)) for user in modeled_users}, source


def main() -> None:
    args = parse_args()
    if args.minimum_commits_per_user_project < 1:
        raise ValueError("--minimum-commits-per-user-project must be at least 1.")
    if not 0 < args.user_quantile <= 1:
        raise ValueError("--user-quantile must be greater than 0 and at most 1.")
    if args.chunksize < 10_000:
        raise ValueError("--chunksize must be at least 10,000.")

    focal_start = parse_timestamp(args.focal_start, "--focal-start")
    focal_end = parse_timestamp(args.focal_end, "--focal-end")
    if focal_end <= focal_start:
        raise ValueError("--focal-end must be later than --focal-start.")

    raw_dir = args.raw_dir.expanduser().resolve()
    commits_csv = (args.commits_csv or raw_dir / "commits.csv").expanduser().resolve()
    projects_csv = (args.projects_csv or raw_dir / "projects.csv").expanduser().resolve()
    followers_csv = (args.followers_csv or raw_dir / "followers.csv").expanduser().resolve()
    for path in (commits_csv, projects_csv, followers_csv):
        if not path.is_file():
            raise FileNotFoundError(f"Required input file not found: {path}")

    language_label = safe_name(args.language)
    output_dir = args.output_root.expanduser().resolve() / language_label
    if output_dir.exists():
        raise FileExistsError(
            f"Output directory already exists: {output_dir}. Use a new --output-root or move the old output."
        )
    output_dir.mkdir(parents=True, exist_ok=False)

    print(f"Language: {args.language}", flush=True)
    print(f"Focal window: [{focal_start.date()}, {focal_end.date()})", flush=True)
    print("Reading language projects …", flush=True)
    project_ids = language_projects(projects_csv, args.language, args.chunksize)
    print(f"Projects in language: {len(project_ids):,}", flush=True)

    commit_columns = discover_commit_columns(commits_csv)
    print("Selecting qualifying April user--repository pairs …", flush=True)
    qualified_pairs, focal_diagnostics = qualifying_focal_pairs(
        commits_csv,
        commit_columns,
        project_ids,
        focal_start,
        focal_end,
        args.chunksize,
        args.minimum_commits_per_user_project,
    )
    if not qualified_pairs:
        raise RuntimeError("No user--repository pair met the focal commit threshold.")

    modeled_users, current_edges, user_cutoff, user_repository_counts = choose_users_and_current_edges(
        qualified_pairs,
        args.user_quantile,
    )
    if len(modeled_users) < 2 or not current_edges:
        raise RuntimeError("No non-isolate focal network remains after the upper-tail selection.")

    print(
        f"{100 * args.user_quantile:g}th-percentile user cutoff: {user_cutoff}; "
        f"modeled users: {len(modeled_users):,}; "
        f"current ties: {len(current_edges):,}",
        flush=True,
    )
    print("Constructing prior co-contribution and expertise …", flush=True)
    expertise_projects, prior_contributors, history_diagnostics = build_history(
        commits_csv,
        commit_columns,
        project_ids,
        modeled_users,
        focal_start,
        args.chunksize,
    )
    print("Constructing follower-count status …", flush=True)
    leadership_raw, leadership_source = follower_counts(
        followers_csv,
        modeled_users,
        focal_start,
        args.chunksize,
        args.allow_undated_followers,
    )

    actor_ids = sorted(modeled_users)
    prior_matrix, number_of_prior_dyads = build_prior_matrix(actor_ids, prior_contributors)
    global_ids = [f"GH_{language_label}_{actor_id}" for actor_id in actor_ids]
    id_lookup = dict(zip(actor_ids, global_ids))
    expertise_raw = pd.Series(
        [len(expertise_projects[actor_id]) for actor_id in actor_ids],
        index=actor_ids,
        dtype=float,
    )
    status_raw = pd.Series(
        [leadership_raw[actor_id] for actor_id in actor_ids],
        index=actor_ids,
        dtype=float,
    )
    log_expertise, expertise_z = log1p_zscore(expertise_raw)
    log_status, status_z = log1p_zscore(status_raw)

    nodes = pd.DataFrame(
        {
            "global_id": global_ids,
            "user_id": actor_ids,
            "language": args.language,
            "expertise_raw": expertise_raw.to_numpy(),
            "log_expertise": log_expertise.to_numpy(),
            "expertise_z": expertise_z.to_numpy(),
            "leadership_raw": status_raw.to_numpy(),
            "log_leadership": log_status.to_numpy(),
            "leadership_z": status_z.to_numpy(),
        }
    )
    edges = pd.DataFrame(
        [(id_lookup[user_a], id_lookup[user_b]) for user_a, user_b in current_edges],
        columns=["u", "v"],
    )
    prior = pd.DataFrame(prior_matrix, index=global_ids, columns=global_ids)
    prior.insert(0, "global_id", global_ids)
    prior_edges = pd.DataFrame(
        [
            (global_ids[i], global_ids[j])
            for i in range(len(global_ids))
            for j in range(i + 1, len(global_ids))
            if prior_matrix[i, j] == 1
        ],
        columns=["u", "v"],
    )
    selected_pairs = pd.DataFrame(
        [
            (project, user, count, user_repository_counts[user])
            for (project, user), count in sorted(qualified_pairs.items())
            if user in modeled_users
        ],
        columns=[
            "project_id",
            "user_id",
            "april_commit_count",
            "qualifying_repositories_for_user",
        ],
    )

    nodes.to_csv(output_dir / "gh_nodes.csv", index=False)
    edges.to_csv(output_dir / "gh_edges.csv", index=False)
    prior.to_csv(output_dir / "gh_prior_mat.csv", index=False)
    prior_edges.to_csv(output_dir / "gh_prior_edges.csv", index=False)
    selected_pairs.to_csv(output_dir / "selected_user_repository_pairs.csv", index=False)

    summary = {
        "language": args.language,
        "focal_start_inclusive": focal_start.date().isoformat(),
        "focal_end_exclusive": focal_end.date().isoformat(),
        "minimum_commits_per_user_repository": args.minimum_commits_per_user_project,
        "user_repository_count_quantile": args.user_quantile,
        "quantile_method": "nearest_rank; retain all users at or above the integer cutoff",
        "qualifying_repositories_per_user_cutoff": user_cutoff,
        "language_projects": len(project_ids),
        "qualifying_user_repository_pairs": len(qualified_pairs),
        "users_with_at_least_one_qualifying_repository": len(user_repository_counts),
        "selected_nonisolate_users": len(actor_ids),
        "focal_binary_ties": len(edges),
        "prior_binary_dyads": number_of_prior_dyads,
        "expertise_definition": "number of distinct same-language repositories with at least one pre-focal commit",
        "status_definition": "follower count, log1p transformed and standardized within language",
        "leadership_source": leadership_source,
        "focal_scan": focal_diagnostics,
        "history_scan": history_diagnostics,
        "source_files": {
            "commits": str(commits_csv),
            "projects": str(projects_csv),
            "followers": str(followers_csv),
        },
    }
    (output_dir / "network_construction_summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Saved ERGM inputs to: {output_dir}", flush=True)


if __name__ == "__main__":
    main()
