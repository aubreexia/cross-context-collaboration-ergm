#!/usr/bin/env python3
"""Summarize GHTorrent commit-count distributions for April 2020.

The script scans commits.csv only once and produces two deliberately different
distributions:

1. Per user: every valid author with at least one commit between 2020-04-01
   (inclusive) and 2020-05-01 (exclusive), counting all of that author's April
   commits across repositories.
2. Per user--project pair: every valid (author, repository) pair with at least
   one April commit, counting that author's commits in that specific repository.

The second distribution is the one that corresponds to the current GHTorrent
pipeline's "user-repository has at least 10 April commits" eligibility rule.
It is not a filter requiring a repository as a whole to have ten commits.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Dict, Iterable, Tuple

import numpy as np
import pandas as pd


START = pd.Timestamp("2020-04-01", tz="UTC")
END = pd.Timestamp("2020-05-01", tz="UTC")
DEFAULT_CHUNKSIZE = 1_000_000
QUANTILES = [
    0.00, 0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95,
    0.99, 0.995, 0.999, 1.00,
]
THRESHOLDS = [1, 2, 5, 10, 11, 20, 25, 50, 100, 250, 500, 1_000]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Calculate April 2020 GHTorrent commit-count distributions among "
            "authors who made at least one commit that month."
        )
    )
    parser.add_argument(
        "--commits-csv",
        required=True,
        type=Path,
        help="Absolute path to the raw GHTorrent commits.csv file.",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="Directory in which CSV summaries and a text report are written.",
    )
    parser.add_argument(
        "--chunksize",
        type=int,
        default=DEFAULT_CHUNKSIZE,
        help=f"Rows read at a time (default: {DEFAULT_CHUNKSIZE:,}).",
    )
    parser.add_argument(
        "--skip-user-project-distribution",
        action="store_true",
        help=(
            "Only calculate the per-user monthly distribution. Use this only "
            "if memory is constrained; the user-project distribution is the "
            "one matching the pipeline's 10-commit rule."
        ),
    )
    return parser.parse_args()


def normalize_id(series: pd.Series) -> pd.Series:
    """Return clean string IDs compatible with GHTorrent's numeric-looking IDs."""
    return series.astype(str).str.strip().str.replace(r"\.0$", "", regex=True)


def valid_id_mask(frame: pd.DataFrame, columns: Iterable[str]) -> pd.Series:
    mask = pd.Series(True, index=frame.index)
    for column in columns:
        text = frame[column].astype(str).str.strip()
        mask &= frame[column].notna()
        mask &= text.ne("")
        mask &= text.ne("\\N")
        mask &= text.str.lower().ne("nan")
    return mask


def check_columns(commits_csv: Path, include_pairs: bool) -> None:
    header = pd.read_csv(commits_csv, nrows=0)
    header.columns = header.columns.str.strip()
    required = {"author_id", "created_at"}
    if include_pairs:
        required.add("project_id")
    missing = required.difference(header.columns)
    if missing:
        raise KeyError(
            "commits.csv is missing required column(s): " + ", ".join(sorted(missing))
        )


def scan_april_commits(
    commits_csv: Path,
    chunksize: int,
    include_pairs: bool,
) -> Tuple[Counter, Counter | None, Dict[str, int]]:
    """Return April counts plus transparent row-accounting diagnostics."""
    usecols = ["author_id", "created_at"]
    if include_pairs:
        usecols.insert(1, "project_id")

    user_counts: Counter = Counter()
    user_project_counts: Counter | None = Counter() if include_pairs else None
    diagnostics: Dict[str, int] = {
        "rows_scanned": 0,
        "rows_with_unparseable_date": 0,
        "rows_in_april_before_id_cleaning": 0,
        "valid_april_commit_rows": 0,
    }

    reader = pd.read_csv(
        commits_csv,
        usecols=usecols,
        chunksize=chunksize,
        low_memory=False,
    )

    for chunk_number, chunk in enumerate(reader, start=1):
        chunk.columns = chunk.columns.str.strip()
        diagnostics["rows_scanned"] += len(chunk)

        dates = pd.to_datetime(chunk["created_at"], errors="coerce", utc=True)
        diagnostics["rows_with_unparseable_date"] += int(dates.isna().sum())
        in_april = (dates >= START) & (dates < END)
        month = chunk.loc[in_april].copy()
        diagnostics["rows_in_april_before_id_cleaning"] += len(month)

        if not month.empty:
            month["author_id"] = normalize_id(month["author_id"])
            id_columns = ["author_id"]
            if include_pairs:
                month["project_id"] = normalize_id(month["project_id"])
                id_columns.append("project_id")
            month = month.loc[valid_id_mask(month, id_columns)].copy()
            diagnostics["valid_april_commit_rows"] += len(month)

            if not month.empty:
                user_counts.update(month.groupby("author_id", sort=False).size().to_dict())
                if include_pairs and user_project_counts is not None:
                    pairs = month.groupby(["author_id", "project_id"], sort=False).size()
                    user_project_counts.update(pairs.to_dict())

        print(
            f"[chunk {chunk_number:,}] scanned={diagnostics['rows_scanned']:,}; "
            f"valid April commits={diagnostics['valid_april_commit_rows']:,}; "
            f"unique April users so far={len(user_counts):,}",
            flush=True,
        )

    return user_counts, user_project_counts, diagnostics


def distribution_table(counts: Counter, unit_name: str) -> pd.DataFrame:
    values = pd.Series(list(counts.values()), dtype="int64")
    frequencies = values.value_counts(sort=False).sort_index()
    result = frequencies.rename_axis("april_commit_count").reset_index(name=f"n_{unit_name}")
    total = int(len(values))
    result["percent_of_all_units"] = result[f"n_{unit_name}"] / total * 100
    result["cumulative_n_units"] = result[f"n_{unit_name}"].cumsum()
    result["cumulative_percent_of_all_units"] = result["cumulative_n_units"] / total * 100
    return result


def quantile_table(counts: Counter, unit_name: str) -> pd.DataFrame:
    values = pd.Series(list(counts.values()), dtype="int64")
    rows = []
    for q in QUANTILES:
        rows.append(
            {
                "quantile": q,
                "quantile_label": f"p{q * 100:g}",
                "april_commit_count": float(values.quantile(q, interpolation="linear")),
            }
        )
    result = pd.DataFrame(rows)
    result.insert(0, "unit", unit_name)
    return result


def threshold_table(counts: Counter, unit_name: str) -> pd.DataFrame:
    values = np.asarray(list(counts.values()), dtype=np.int64)
    total = len(values)
    rows = []
    for threshold in THRESHOLDS:
        n_ge = int(np.sum(values >= threshold))
        n_gt = int(np.sum(values > threshold))
        rows.append(
            {
                "unit": unit_name,
                "commit_threshold": threshold,
                "n_units_total": total,
                "n_units_equal_to_threshold": int(np.sum(values == threshold)),
                "n_units_at_least_threshold": n_ge,
                "percent_at_least_threshold": n_ge / total * 100,
                "n_units_strictly_greater_than_threshold": n_gt,
                "percent_strictly_greater_than_threshold": n_gt / total * 100,
            }
        )
    return pd.DataFrame(rows)


def write_outputs(
    output_dir: Path,
    user_counts: Counter,
    user_project_counts: Counter | None,
    diagnostics: Dict[str, int],
    commits_csv: Path,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    metadata = {
        "commits_csv": str(commits_csv.resolve()),
        "analysis_window": "2020-04-01 00:00:00 UTC <= created_at < 2020-05-01 00:00:00 UTC",
        "per_user_definition": (
            "One row per author with at least one valid April 2020 commit; commit count is "
            "that author's total across all repositories."
        ),
        "per_user_project_definition": (
            "One row per (author, project) pair with at least one valid April 2020 commit; "
            "commit count is the author's total in that repository. This is the unit for the "
            "pipeline's at-least-10-commits eligibility rule."
        ),
        "pipeline_cutoff_interpretation": "at least 10 (>= 10), so exactly 10 qualifies.",
        "diagnostics": diagnostics,
        "n_active_april_users": len(user_counts),
        "n_active_april_user_project_pairs": (
            len(user_project_counts) if user_project_counts is not None else None
        ),
    }
    (output_dir / "analysis_metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )

    user_distribution = distribution_table(user_counts, "users")
    user_quantiles = quantile_table(user_counts, "users")
    user_thresholds = threshold_table(user_counts, "users")
    user_distribution.to_csv(output_dir / "april_2020_user_commit_distribution.csv", index=False)
    user_quantiles.to_csv(output_dir / "april_2020_user_commit_quantiles.csv", index=False)
    user_thresholds.to_csv(output_dir / "april_2020_user_commit_thresholds.csv", index=False)

    report = [
        "GHTorrent April 2020 commit-count distribution",
        "=" * 48,
        f"Source: {commits_csv.resolve()}",
        "Window: 2020-04-01 inclusive to 2020-05-01 exclusive (UTC)",
        "",
        "Interpretation of the pipeline cutoff:",
        "  The relevant unit is a user--project pair, not a project overall.",
        "  A user--project pair is eligible at >= 10 April commits; exactly 10 qualifies.",
        "",
        "Row accounting:",
    ]
    report.extend(f"  {key}: {value:,}" for key, value in diagnostics.items())
    report.extend(
        [
            "",
            f"Active April users (at least one valid commit): {len(user_counts):,}",
            "",
            "Per-user monthly total: selected threshold statistics",
        ]
    )
    report.extend(
        user_thresholds.loc[
            user_thresholds["commit_threshold"].isin([10, 11]),
            [
                "commit_threshold",
                "n_units_equal_to_threshold",
                "n_units_at_least_threshold",
                "percent_at_least_threshold",
                "n_units_strictly_greater_than_threshold",
                "percent_strictly_greater_than_threshold",
            ],
        ].to_string(index=False)
        .splitlines()
    )

    if user_project_counts is not None:
        pair_distribution = distribution_table(user_project_counts, "user_project_pairs")
        pair_quantiles = quantile_table(user_project_counts, "user_project_pairs")
        pair_thresholds = threshold_table(user_project_counts, "user_project_pairs")
        pair_distribution.to_csv(
            output_dir / "april_2020_user_project_commit_distribution.csv", index=False
        )
        pair_quantiles.to_csv(
            output_dir / "april_2020_user_project_commit_quantiles.csv", index=False
        )
        pair_thresholds.to_csv(
            output_dir / "april_2020_user_project_commit_thresholds.csv", index=False
        )
        report.extend(
            [
                "",
                f"Active April user--project pairs: {len(user_project_counts):,}",
                "",
                "Per-user--project April total: selected threshold statistics",
            ]
        )
        report.extend(
            pair_thresholds.loc[
                pair_thresholds["commit_threshold"].isin([10, 11]),
                [
                    "commit_threshold",
                    "n_units_equal_to_threshold",
                    "n_units_at_least_threshold",
                    "percent_at_least_threshold",
                    "n_units_strictly_greater_than_threshold",
                    "percent_strictly_greater_than_threshold",
                ],
            ].to_string(index=False)
            .splitlines()
        )

    (output_dir / "summary.txt").write_text("\n".join(report) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    if args.chunksize <= 0:
        raise ValueError("--chunksize must be positive.")
    if not args.commits_csv.is_file():
        raise FileNotFoundError(f"Cannot find commits.csv: {args.commits_csv}")

    include_pairs = not args.skip_user_project_distribution
    check_columns(args.commits_csv, include_pairs)
    print("Starting April 2020 commit distribution scan.", flush=True)
    print(f"commits.csv: {args.commits_csv.resolve()}", flush=True)
    print(f"user-project distribution: {'yes' if include_pairs else 'no'}", flush=True)

    user_counts, user_project_counts, diagnostics = scan_april_commits(
        args.commits_csv, args.chunksize, include_pairs
    )
    if not user_counts:
        raise RuntimeError("No valid April 2020 commits were found; check the date column and source file.")

    write_outputs(
        args.output_dir,
        user_counts,
        user_project_counts,
        diagnostics,
        args.commits_csv,
    )
    print(f"\n[SAVED] {args.output_dir.resolve()}", flush=True)
    print(f"[RESULT] Active April users: {len(user_counts):,}", flush=True)
    if user_project_counts is not None:
        print(f"[RESULT] Active April user-project pairs: {len(user_project_counts):,}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"\n[FAILED] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise
