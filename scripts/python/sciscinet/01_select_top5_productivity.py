#!/usr/bin/env python3
"""Choose an ERGM inclusion cutoff from focal-period journal productivity.

For one journal and one focal date window, this script:
  1. identifies every paper published in the target journal during the window;
  2. identifies every author of those papers (including eventual isolates);
  3. counts each author's *unique focal-period papers*; and
  4. chooses the productivity cutoff at the top-percent rank, retaining ties.

It is intentionally separate from the network-construction pipeline so the
selection universe is not affected by later removal of isolates.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from collections import Counter
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Iterable


csv.field_size_limit(sys.maxsize)

PAPER_ID_CANDIDATES = ("PaperID", "paper_id", "paperid")
JOURNAL_ID_CANDIDATES = ("JournalID", "journal_id", "journalid")
AUTHOR_ID_CANDIDATES = ("AuthorID", "author_id", "authorid")
DATE_CANDIDATES = ("Date", "date", "PublicationDate", "publication_date")
JOURNAL_TITLE_CANDIDATES = (
    "JournalName",
    "journal_name",
    "Journal",
    "journal",
    "Name",
    "name",
    "Title",
    "title",
    "DisplayName",
    "display_name",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Select a focal-period journal-productivity cutoff at the top "
            "percentile, including all ties at the cutoff."
        )
    )
    parser.add_argument("--journal", required=True, help="Exact journal title.")
    parser.add_argument("--start-date", required=True, help="Inclusive YYYY-MM-DD.")
    parser.add_argument("--end-date", required=True, help="Inclusive YYYY-MM-DD.")
    parser.add_argument(
        "--top-percent",
        type=float,
        default=5.0,
        help="Upper tail to retain; default: 5.0.",
    )
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=Path("."),
        help="SciSciNet project root containing raw/; default: current directory.",
    )
    parser.add_argument("--papers-file", type=Path)
    parser.add_argument("--journals-file", type=Path)
    parser.add_argument("--paper-author-file", type=Path)
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Directory for the selection report; default: project-dir/k_selection/…",
    )
    return parser.parse_args()


def normalized(value: object) -> str:
    return " ".join(str(value or "").strip().casefold().split())


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("_") or "journal"


def canonical_journal_id(value: object) -> str:
    """Reconcile SciSciNet's journal-table and paper-table ID encodings.

    `SciSciNet_Journals.tsv` stores identifiers such as ``190:2898213522``,
    while `SciSciNet_Papers.tsv` stores the same identifier as ``2898213522.0``.
    Compare their shared numeric component rather than their raw text.
    """
    text = str(value or "").strip()
    if ":" in text:
        text = text.rsplit(":", 1)[1].strip()
    if re.fullmatch(r"[+-]?\d+\.0+", text):
        text = text.split(".", 1)[0]
    return text


def parse_iso_date(value: str, field: str) -> date | None:
    value = (value or "").strip()
    if not value:
        return None
    for candidate in (value[:10], value):
        try:
            return date.fromisoformat(candidate)
        except ValueError:
            pass
    for fmt in ("%Y/%m/%d", "%Y/%m/%d %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            pass
    raise ValueError(f"Could not parse {field} value as a date: {value!r}")


def require_columns(path: Path, candidates: Iterable[str], label: str) -> str:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        fields = reader.fieldnames or []
    lookup = {normalized(field): field for field in fields}
    for candidate in candidates:
        hit = lookup.get(normalized(candidate))
        if hit is not None:
            return hit
    raise ValueError(
        f"{path} has no {label} column. Available columns: {', '.join(fields)}"
    )


def find_journal_id(journals_file: Path, journal: str) -> str:
    journal_id_column = require_columns(
        journals_file, JOURNAL_ID_CANDIDATES, "journal-ID"
    )
    with journals_file.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        fields = reader.fieldnames or []
        title_columns = [
            field
            for field in fields
            if normalized(field) in {normalized(x) for x in JOURNAL_TITLE_CANDIDATES}
        ]
        if not title_columns:
            raise ValueError(
                f"{journals_file} has no recognized journal-title column. "
                f"Available columns: {', '.join(fields)}"
            )

        wanted = normalized(journal)
        matches: set[str] = set()
        for row in reader:
            if any(normalized(row.get(column, "")) == wanted for column in title_columns):
                journal_id = canonical_journal_id(row.get(journal_id_column, ""))
                if journal_id:
                    matches.add(journal_id)

    if not matches:
        raise ValueError(f"Journal not found exactly in {journals_file}: {journal!r}")
    if len(matches) != 1:
        raise ValueError(
            f"Journal title {journal!r} maps to multiple journal IDs: {sorted(matches)}"
        )
    return next(iter(matches))


def select_focal_papers(
    papers_file: Path,
    journal_id: str,
    focal_start: date,
    focal_end: date,
) -> tuple[set[str], Counter]:
    paper_id_column = require_columns(papers_file, PAPER_ID_CANDIDATES, "paper-ID")
    paper_journal_column = require_columns(
        papers_file, JOURNAL_ID_CANDIDATES, "journal-ID"
    )
    paper_date_column = require_columns(papers_file, DATE_CANDIDATES, "date")

    selected: set[str] = set()
    accounting: Counter = Counter()
    with papers_file.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            accounting["papers_rows_scanned"] += 1
            if canonical_journal_id(row.get(paper_journal_column, "")) != journal_id:
                continue
            accounting["target_journal_paper_rows"] += 1
            parsed = parse_iso_date(row.get(paper_date_column, ""), paper_date_column)
            if parsed is None:
                accounting["target_journal_rows_missing_date"] += 1
                continue
            if focal_start <= parsed <= focal_end:
                paper_id = (row.get(paper_id_column) or "").strip()
                if paper_id:
                    selected.add(paper_id)
                    accounting["focal_journal_paper_rows"] += 1
                else:
                    accounting["focal_rows_missing_paper_id"] += 1
    return selected, accounting


def count_focal_author_productivity(
    paper_author_file: Path, focal_paper_ids: set[str]
) -> tuple[Counter, Counter]:
    paper_id_column = require_columns(paper_author_file, PAPER_ID_CANDIDATES, "paper-ID")
    author_id_column = require_columns(paper_author_file, AUTHOR_ID_CANDIDATES, "author-ID")

    counts: Counter = Counter()
    seen_pairs: set[tuple[str, str]] = set()
    accounting: Counter = Counter()
    with paper_author_file.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            accounting["paper_author_rows_scanned"] += 1
            paper_id = (row.get(paper_id_column) or "").strip()
            if paper_id not in focal_paper_ids:
                continue
            author_id = (row.get(author_id_column) or "").strip()
            if not author_id:
                accounting["focal_rows_missing_author_id"] += 1
                continue
            pair = (author_id, paper_id)
            if pair in seen_pairs:
                accounting["duplicate_author_paper_rows"] += 1
                continue
            seen_pairs.add(pair)
            counts[author_id] += 1
            accounting["unique_focal_author_paper_pairs"] += 1
    return counts, accounting


def main() -> None:
    args = parse_args()
    if not 0 < args.top_percent <= 100:
        raise ValueError("--top-percent must be greater than 0 and at most 100.")

    focal_start = parse_iso_date(args.start_date, "--start-date")
    focal_end = parse_iso_date(args.end_date, "--end-date")
    if focal_start is None or focal_end is None or focal_end < focal_start:
        raise ValueError("Use a valid inclusive date range with end-date >= start-date.")

    project_dir = args.project_dir.expanduser().resolve()
    raw_dir = project_dir / "raw"
    papers_file = (args.papers_file or raw_dir / "SciSciNet_Papers.tsv").expanduser()
    journals_file = (args.journals_file or raw_dir / "SciSciNet_Journals.tsv").expanduser()
    paper_author_file = (
        args.paper_author_file or raw_dir / "SciSciNet_PaperAuthorAffiliations.tsv"
    ).expanduser()
    for source_file in (papers_file, journals_file, paper_author_file):
        if not source_file.is_file():
            raise FileNotFoundError(f"Required source file not found: {source_file}")

    label = f"{safe_name(args.journal)}_{focal_start:%Y_%m_%d}_to_{focal_end:%Y_%m_%d}_top{args.top_percent:g}"
    output_dir = (args.output_dir or project_dir / "k_selection" / label).expanduser()
    output_dir.mkdir(parents=True, exist_ok=False)

    journal_id = find_journal_id(journals_file, args.journal)
    focal_paper_ids, paper_accounting = select_focal_papers(
        papers_file, journal_id, focal_start, focal_end
    )
    if not focal_paper_ids:
        raise ValueError("No focal-period papers found for the requested journal and dates.")

    author_counts, author_accounting = count_focal_author_productivity(
        paper_author_file, focal_paper_ids
    )
    if not author_counts:
        raise ValueError("No focal-period authors were found for the selected papers.")

    ordered = sorted(author_counts.items(), key=lambda item: (-item[1], item[0]))
    number_of_authors = len(ordered)
    target_rank = math.ceil(number_of_authors * args.top_percent / 100.0)
    cutoff = ordered[target_rank - 1][1]
    selected = {author_id for author_id, count in ordered if count >= cutoff}

    author_file = output_dir / "focal_author_productivity.csv"
    with author_file.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["AuthorID", "focal_paper_count", "top_percent_selected"])
        for author_id, count in ordered:
            writer.writerow([author_id, count, int(author_id in selected)])

    distribution_file = output_dir / "focal_productivity_distribution.csv"
    with distribution_file.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["focal_paper_count", "number_of_authors"])
        for count in sorted(Counter(author_counts.values())):
            writer.writerow([count, Counter(author_counts.values())[count]])

    summary = {
        "selection_method": "focal_period_all_authors_top_percent_rank_cutoff",
        "journal": args.journal,
        "journal_id": journal_id,
        "focal_start_date_inclusive": focal_start.isoformat(),
        "focal_end_date_inclusive": focal_end.isoformat(),
        "top_percent": args.top_percent,
        "selection_universe": (
            "All unique authors attached to target-journal papers dated within the "
            "inclusive focal window; author productivity is the number of unique "
            "target-journal focal-period papers."
        ),
        "number_of_focal_papers": len(focal_paper_ids),
        "number_of_focal_authors": number_of_authors,
        "top_percent_target_rank": target_rank,
        "selected_k_cutoff": cutoff,
        "authors_retained_at_or_above_cutoff": len(selected),
        "actual_retained_percent_after_ties": 100.0 * len(selected) / number_of_authors,
        "main_pipeline_argument_if_filter_is_greater_or_equal": cutoff,
        "main_pipeline_argument_if_filter_is_greater_than": cutoff - 1,
        "accounting": {**paper_accounting, **author_accounting},
        "source_files": {
            "papers": str(papers_file),
            "journals": str(journals_file),
            "paper_author_affiliations": str(paper_author_file),
        },
    }
    summary_file = output_dir / "k_selection_summary.json"
    summary_file.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    print("[SAVED]", output_dir)
    print("Journal:", args.journal)
    print("Focal papers:", len(focal_paper_ids))
    print("Focal authors:", number_of_authors)
    print("Top-percent rank:", target_rank)
    print("Selected k cutoff:", cutoff)
    print("Authors retained at or above cutoff:", len(selected))
    print("Actual retained percent after ties:", f"{100.0 * len(selected) / number_of_authors:.3f}")
    print("Use --k", cutoff, "if K_FILTER_MODE is 'at_least'.")
    print("Use --k", cutoff - 1, "if K_FILTER_MODE is 'greater_than'.")


if __name__ == "__main__":
    main()
