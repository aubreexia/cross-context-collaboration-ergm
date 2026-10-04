#!/usr/bin/env python3
"""
SciSciNet v1 journal-network pipeline for Notre Dame CRC.

Main changes from the original notebook-style script:
1. Uses a portable project directory (``--project-dir`` or ``SCI_DIR``) and a
   raw/processed project structure.
2. Uses command-line arguments instead of input(), so it works with qsub.
3. Reads SciSciNet_Papers.tsv in chunks instead of loading the full file.
4. Reads SciSciNet_PaperAuthorAffiliations.tsv in chunks.
5. Reads SciSciNet_Authors.tsv in chunks and extracts H-index only for target authors.
6. Does not generate yearly-count figures or network-layout figures.
7. Saves validation summaries and fails early when source files/columns are missing.
8. Accepts an exact inclusive date range through --start-date and --end-date.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime
from itertools import combinations
from pathlib import Path
from typing import Iterable, Optional

import networkx as nx
import numpy as np
import pandas as pd


DEFAULT_PROJECT_DIR = Path(os.environ.get("SCI_DIR", ".")).expanduser().resolve()

DEFAULT_CHUNKSIZE = 1_000_000
K_FILTER_MODE = "at_least"

NULL_ID_VALUES = {"", "\\N", "nan", "None", "<NA>"}


def clean_id_series(series: pd.Series) -> pd.Series:
    """Preserve identifiers as strings and normalize surrounding whitespace."""
    return series.astype("string").str.strip()


def normalize_mag_id_series(series: pd.Series) -> pd.Series:
    """
    Normalize integer-like MAG identifiers without converting them through float.

    Examples:
        "12345"   -> "12345"
        "12345.0" -> "12345"
    """
    cleaned = clean_id_series(series)
    return cleaned.str.replace(r"^([0-9]+)\.0+$", r"\1", regex=True)


def valid_id_mask(series: pd.Series) -> pd.Series:
    """Return True for nonmissing, nonblank identifiers."""
    cleaned = clean_id_series(series)
    return cleaned.notna() & ~cleaned.isin(NULL_ID_VALUES)


def safe_name(name: str) -> str:
    name = name.strip().replace("&", "and")
    name = re.sub(r"[^\w\s-]", "_", name)
    name = re.sub(r"\s+", "_", name)
    name = re.sub(r"_+", "_", name)
    return name.strip("_")


def make_short_name(journal_name: str) -> str:
    special = {
        "The New England Journal of Medicine": "NEJM",
        "The Lancet": "Lancet",
        "JAMA": "JAMA",
        "BMJ": "BMJ",
        "Nature Medicine": "Nature_Medicine",
        "PLOS Medicine": "PLOS_Medicine",
        "PLOS ONE": "PLOS_ONE",
        "Nature": "Nature",
        "Science": "Science",
        "Cell": "Cell",
    }
    return special.get(journal_name, safe_name(journal_name))


def parse_date_range(
    start_date_text: str,
    end_date_text: str,
) -> tuple[pd.Timestamp, pd.Timestamp, str]:
    """
    Parse an inclusive focal date range.

    The returned end timestamp is exclusive so downstream filters can continue
    to use:

        focal_start <= Date < focal_end

    Example:
        --start-date 2020-01-01 --end-date 2020-07-23
        -> [2020-01-01, 2020-07-24)
        -> label 2020_01_01_to_2020_07_23
    """
    start_date_text = start_date_text.strip()
    end_date_text = end_date_text.strip()

    date_pattern = r"\d{4}-\d{2}-\d{2}"
    if not re.fullmatch(date_pattern, start_date_text):
        raise ValueError(
            "--start-date must use YYYY-MM-DD format, for example 2020-01-01."
        )
    if not re.fullmatch(date_pattern, end_date_text):
        raise ValueError(
            "--end-date must use YYYY-MM-DD format, for example 2020-07-23."
        )

    try:
        focal_start = pd.Timestamp(
            datetime.strptime(start_date_text, "%Y-%m-%d")
        )
    except ValueError as error:
        raise ValueError(f"Invalid --start-date: {start_date_text}.") from error

    try:
        focal_end_inclusive = pd.Timestamp(
            datetime.strptime(end_date_text, "%Y-%m-%d")
        )
    except ValueError as error:
        raise ValueError(f"Invalid --end-date: {end_date_text}.") from error

    if focal_end_inclusive < focal_start:
        raise ValueError("--end-date must be on or after --start-date.")

    # Convert the user-facing inclusive end date to an exclusive upper bound.
    focal_end = focal_end_inclusive + pd.Timedelta(days=1)
    period_label = (
        f"{focal_start.strftime('%Y_%m_%d')}"
        f"_to_{focal_end_inclusive.strftime('%Y_%m_%d')}"
    )
    return focal_start, focal_end, period_label


def require_columns(file_path: Path, required: Iterable[str], sep: str = "\t") -> list[str]:
    """Read only the header and verify required columns."""
    header = pd.read_csv(file_path, sep=sep, dtype="string", nrows=0)
    columns = header.columns.astype(str).str.strip().tolist()
    missing = [column for column in required if column not in columns]
    if missing:
        raise KeyError(
            f"{file_path.name} is missing required columns {missing}. "
            f"Available columns: {columns}"
        )
    return columns


def validate_source_files(
    papers_file: Path,
    journals_file: Path,
    authorpaper_file: Path,
    authors_file: Path,
) -> None:
    files = [papers_file, journals_file, authorpaper_file, authors_file]
    missing = [str(path) for path in files if not path.exists()]
    if missing:
        raise FileNotFoundError(
            "The following source files were not found:\n- " + "\n- ".join(missing)
        )

    require_columns(papers_file, ["PaperID", "JournalID", "Year", "Date"])
    require_columns(journals_file, ["JournalID", "Journal_Name"])
    require_columns(authorpaper_file, ["PaperID", "AuthorID"])
    require_columns(authors_file, ["AuthorID"])


def load_journals(journals_file: Path) -> pd.DataFrame:
    journals = pd.read_csv(
        journals_file,
        sep="\t",
        dtype="string",
        usecols=["JournalID", "Journal_Name"],
    )
    journals.columns = journals.columns.astype(str).str.strip()
    journals["JournalID"] = normalize_mag_id_series(journals["JournalID"])
    journals["Journal_Name"] = journals["Journal_Name"].astype("string").str.strip()
    journals = journals[
        valid_id_mask(journals["JournalID"]) & journals["Journal_Name"].notna()
    ].drop_duplicates()
    return journals


def choose_journal(
    journals: pd.DataFrame,
    journal_query: str,
    journal_id: Optional[str],
) -> tuple[str, set[str]]:
    query = journal_query.strip()

    if journal_id:
        chosen = journals[
            normalize_mag_id_series(journals["JournalID"]) == normalize_mag_id_series(pd.Series([journal_id])).iloc[0]
        ].copy()
        if chosen.empty:
            raise ValueError(f"JournalID {journal_id!r} was not found.")
        return str(chosen["Journal_Name"].iloc[0]), set(chosen["JournalID"].astype(str))

    exact = journals[
        journals["Journal_Name"].astype("string").str.casefold() == query.casefold()
    ].copy()

    matches = exact
    if matches.empty:
        matches = journals[
            journals["Journal_Name"]
            .astype("string")
            .str.contains(query, case=False, na=False, regex=False)
        ].copy()

    if matches.empty:
        raise ValueError(f"No journal matched {query!r}.")

    unique_matches = matches[["JournalID", "Journal_Name"]].drop_duplicates()

    if len(unique_matches) > 1:
        options = unique_matches.to_string(index=False)
        raise ValueError(
            "Multiple journals matched the query. Re-run with --journal-id.\n"
            f"{options}"
        )

    journal_name = str(unique_matches["Journal_Name"].iloc[0])
    journal_ids = set(normalize_mag_id_series(unique_matches["JournalID"]).dropna().astype(str))
    return journal_name, journal_ids


def scan_journal_papers(
    papers_file: Path,
    journal_ids: set[str],
    journal_name: str,
    focal_start: pd.Timestamp,
    focal_end: pd.Timestamp,
    chunksize: int,
) -> pd.DataFrame:
    """
    Scan SciSciNet_Papers.tsv and retain the selected journal through
    the inclusive end date of the focal period.

    Exact dates are required for focal-period membership. Older papers whose
    Date is missing are retained only when Year is strictly earlier than the
    focal period, so they can still contribute to prior history.
    """
    matched_chunks: list[pd.DataFrame] = []

    require_columns(
        papers_file,
        ["PaperID", "JournalID", "Year", "Date"],
    )
    usecols = ["PaperID", "JournalID", "Year", "Date"]

    normalized_target_ids = set(
        normalize_mag_id_series(pd.Series(list(journal_ids), dtype="string"))
        .dropna()
        .astype(str)
    )

    print("\n===== Scanning SciSciNet_Papers.tsv =====", flush=True)
    print(f"Target journal: {journal_name!r}", flush=True)
    print(f"Target JournalIDs: {sorted(normalized_target_ids)}", flush=True)
    print(
        f"Focal interval: [{focal_start.date()}, {focal_end.date()})",
        flush=True,
    )

    total_id_matches = 0
    total_kept = 0

    reader = pd.read_csv(
        papers_file,
        sep="\t",
        dtype="string",
        usecols=usecols,
        chunksize=chunksize,
    )

    for index, chunk in enumerate(reader, start=1):
        chunk.columns = chunk.columns.astype(str).str.strip()
        chunk["PaperID"] = clean_id_series(chunk["PaperID"])
        chunk["JournalID"] = normalize_mag_id_series(chunk["JournalID"])
        chunk["Year"] = pd.to_numeric(chunk["Year"], errors="coerce")
        chunk["Date"] = pd.to_datetime(
            chunk["Date"],
            errors="coerce",
            format="%Y-%m-%d",
        )

        id_match = chunk["JournalID"].isin(normalized_target_ids)
        total_id_matches += int(id_match.sum())

        # Keep exact-dated papers through the inclusive focal end date.
        # Also retain older-year papers with missing Date for prior history.
        temporal_keep = (
            (chunk["Date"].notna() & (chunk["Date"] < focal_end))
            | (
                chunk["Date"].isna()
                & chunk["Year"].notna()
                & (chunk["Year"] < focal_start.year)
            )
        )

        keep_mask = (
            valid_id_mask(chunk["PaperID"])
            & id_match
            & temporal_keep
        )
        chunk = chunk[keep_mask].copy()

        if not chunk.empty:
            matched_chunks.append(chunk)
            total_kept += len(chunk)

        if index == 1 or index % 10 == 0:
            print(
                f"Processed paper chunks: {index}; "
                f"journal-ID matches: {total_id_matches}; "
                f"kept through focal period: {total_kept}",
                flush=True,
            )

    if not matched_chunks:
        raise ValueError(
            "No paper rows matched the normalized JournalID. "
            "Check the JournalID and SciSciNet_Papers.tsv."
        )

    papers = pd.concat(matched_chunks, ignore_index=True)
    papers = (
        papers.drop_duplicates(subset=["PaperID"])
        .sort_values(["Date", "Year", "PaperID"], na_position="last")
        .reset_index(drop=True)
    )

    focal_count = int(
        (
            papers["Date"].notna()
            & (papers["Date"] >= focal_start)
            & (papers["Date"] < focal_end)
        ).sum()
    )
    print(f"Matched historical + focal papers: {len(papers):,}", flush=True)
    print(f"Papers in focal period: {focal_count:,}", flush=True)
    return papers



def read_authorpaper_subset(
    authorpaper_file: Path,
    target_paper_ids: Iterable[str],
    target_author_ids: Optional[Iterable[str]] = None,
    chunksize: int = DEFAULT_CHUNKSIZE,
) -> pd.DataFrame:
    target_paper_set = {str(x).strip() for x in target_paper_ids if pd.notna(x)}
    target_author_set = (
        {str(x).strip() for x in target_author_ids if pd.notna(x)}
        if target_author_ids is not None
        else None
    )

    if not target_paper_set:
        return pd.DataFrame(columns=["PaperID", "AuthorID"])

    print("\n===== Scanning SciSciNet_PaperAuthorAffiliations.tsv =====", flush=True)
    print(f"Target PaperIDs: {len(target_paper_set):,}", flush=True)
    if target_author_set is not None:
        print(f"Target AuthorIDs: {len(target_author_set):,}", flush=True)

    matched_chunks: list[pd.DataFrame] = []

    reader = pd.read_csv(
        authorpaper_file,
        sep="\t",
        dtype="string",
        usecols=["PaperID", "AuthorID"],
        chunksize=chunksize,
    )

    for index, chunk in enumerate(reader, start=1):
        chunk.columns = chunk.columns.astype(str).str.strip()
        chunk["PaperID"] = clean_id_series(chunk["PaperID"])
        chunk["AuthorID"] = clean_id_series(chunk["AuthorID"])

        chunk = chunk[
            valid_id_mask(chunk["PaperID"])
            & valid_id_mask(chunk["AuthorID"])
            & chunk["PaperID"].isin(target_paper_set)
        ]

        if target_author_set is not None:
            chunk = chunk[chunk["AuthorID"].isin(target_author_set)]

        if not chunk.empty:
            matched_chunks.append(chunk[["PaperID", "AuthorID"]].copy())

        if index == 1 or index % 10 == 0:
            kept = sum(len(x) for x in matched_chunks)
            print(
                f"Processed author-paper chunks: {index}; matched rows so far: {kept}",
                flush=True,
            )

    if not matched_chunks:
        return pd.DataFrame(columns=["PaperID", "AuthorID"])

    output = pd.concat(matched_chunks, ignore_index=True)
    output = output.drop_duplicates(subset=["PaperID", "AuthorID"]).reset_index(drop=True)

    print(f"Matched author-paper rows: {len(output):,}", flush=True)
    print(f"Matched unique papers: {output['PaperID'].nunique():,}", flush=True)
    print(f"Matched unique authors: {output['AuthorID'].nunique():,}", flush=True)
    return output


def build_focal_network(
    journal_papers: pd.DataFrame,
    authorpaper_file: Path,
    focal_start: pd.Timestamp,
    focal_end: pd.Timestamp,
    k: int,
    chunksize: int,
) -> dict:
    focal_papers = journal_papers[
        journal_papers["Date"].notna()
        & (journal_papers["Date"] >= focal_start)
        & (journal_papers["Date"] < focal_end)
    ].copy()
    focal_paper_ids = set(focal_papers["PaperID"].dropna().astype(str))

    if not focal_paper_ids:
        raise ValueError(
            "No papers were found in focal interval "
            f"[{focal_start.date()}, {focal_end.date()})."
        )

    focal_authorpaper = read_authorpaper_subset(
        authorpaper_file,
        target_paper_ids=focal_paper_ids,
        chunksize=chunksize,
    )

    if focal_authorpaper.empty:
        raise ValueError("No author-paper rows matched the focal-period papers.")

    author_counts = (
        focal_authorpaper.groupby("AuthorID")["PaperID"]
        .nunique()
        .reset_index(name="focal_paper_count")
    )

    if K_FILTER_MODE == "greater_than":
        active_authors = author_counts[author_counts["focal_paper_count"] > k].copy()
        k_text = f"> {k}"
    else:
        active_authors = author_counts[author_counts["focal_paper_count"] >= k].copy()
        k_text = f">= {k}"

    if active_authors.empty:
        raise ValueError(
            f"No authors satisfy focal paper count {k_text}. "
            "Use a smaller k or a wider focal period."
        )

    active_author_set = set(active_authors["AuthorID"].astype(str))
    filtered_authorpaper = focal_authorpaper[
        focal_authorpaper["AuthorID"].isin(active_author_set)
    ].copy()

    edge_weights: dict[tuple[str, str], int] = {}

    for _, group in filtered_authorpaper.groupby("PaperID", sort=False):
        authors = sorted(set(group["AuthorID"].astype(str)))
        for author_a, author_b in combinations(authors, 2):
            edge = (author_a, author_b)
            edge_weights[edge] = edge_weights.get(edge, 0) + 1

    graph = nx.Graph()

    for row in active_authors.itertuples(index=False):
        graph.add_node(
            str(row.AuthorID),
            focal_paper_count=int(row.focal_paper_count),
        )

    for (author_a, author_b), weight in edge_weights.items():
        graph.add_edge(author_a, author_b, weight=weight)

    isolates = list(nx.isolates(graph))
    graph.remove_nodes_from(isolates)

    clean_node_set = set(graph.nodes())
    clean_authorpaper = filtered_authorpaper[
        filtered_authorpaper["AuthorID"].isin(clean_node_set)
    ].copy()
    clean_paper_ids = set(clean_authorpaper["PaperID"].astype(str))
    clean_papers = focal_papers[focal_papers["PaperID"].isin(clean_paper_ids)].copy()

    nodes_df = pd.DataFrame(
        [
            {
                "AuthorID": node,
                "focal_paper_count": int(
                    graph.nodes[node].get("focal_paper_count", 0)
                ),
            }
            for node in sorted(graph.nodes())
        ]
    )

    edges_df = pd.DataFrame(
        [
            {
                "AuthorID_1": min(author_a, author_b),
                "AuthorID_2": max(author_a, author_b),
                "weight": int(data.get("weight", 1)),
            }
            for author_a, author_b, data in graph.edges(data=True)
        ],
        columns=["AuthorID_1", "AuthorID_2", "weight"],
    )

    if not edges_df.empty:
        edges_df = (
            edges_df.drop_duplicates(subset=["AuthorID_1", "AuthorID_2"])
            .sort_values(["AuthorID_1", "AuthorID_2"])
            .reset_index(drop=True)
        )

    summary = {
        "focal_period_label": (
            f"{focal_start.strftime('%Y_%m_%d')}"
            f"_to_{(focal_end - pd.Timedelta(days=1)).strftime('%Y_%m_%d')}"
        ),
        "focal_start": focal_start.strftime("%Y-%m-%d"),
        "focal_end_inclusive": (
            focal_end - pd.Timedelta(days=1)
        ).strftime("%Y-%m-%d"),
        "focal_end_exclusive": focal_end.strftime("%Y-%m-%d"),
        "k": k,
        "k_text": k_text,
        "focal_papers_before_cleaning": int(len(focal_papers)),
        "authorpaper_rows_before_cleaning": int(len(focal_authorpaper)),
        "active_authors_before_isolate_removal": int(len(active_authors)),
        "isolated_nodes_removed": int(len(isolates)),
        "nodes_after_isolate_removal": int(graph.number_of_nodes()),
        "edges_after_isolate_removal": int(graph.number_of_edges()),
        "density_after_isolate_removal": float(
            nx.density(graph) if graph.number_of_nodes() > 1 else 0.0
        ),
        "average_clustering_after_isolate_removal": float(
            nx.average_clustering(graph) if graph.number_of_nodes() > 0 else 0.0
        ),
        "connected_components_after_isolate_removal": int(
            nx.number_connected_components(graph)
            if graph.number_of_nodes() > 0
            else 0
        ),
        "clean_papers": int(clean_papers["PaperID"].nunique()),
        "clean_authorpaper_rows": int(len(clean_authorpaper)),
    }

    return {
        "graph": graph,
        "summary": summary,
        "clean_nodes": nodes_df,
        "clean_edges": edges_df,
        "clean_papers": clean_papers,
        "clean_authorpaper": clean_authorpaper,
        "active_authors": active_authors,
    }


def find_hindex_column(authors_file: Path) -> str:
    columns = require_columns(authors_file, ["AuthorID"])
    candidates = [
        "H-index",
        "H_index",
        "h-index",
        "h_index",
        "hindex",
        "HIndex",
        "H Index",
    ]
    for candidate in candidates:
        if candidate in columns:
            return candidate
    raise KeyError(
        f"No H-index column was found in {authors_file.name}. "
        f"Available columns: {columns}"
    )


def load_leadership(
    authors_file: Path,
    author_ids: Iterable[str],
    chunksize: int,
) -> pd.DataFrame:
    target_author_set = {str(x).strip() for x in author_ids if pd.notna(x)}
    output = pd.DataFrame({"AuthorID": sorted(target_author_set)})

    hindex_column = find_hindex_column(authors_file)
    print(f"\nUsing leadership column: {hindex_column}", flush=True)

    matched_chunks: list[pd.DataFrame] = []

    reader = pd.read_csv(
        authors_file,
        sep="\t",
        dtype="string",
        usecols=["AuthorID", hindex_column],
        chunksize=chunksize,
    )

    for index, chunk in enumerate(reader, start=1):
        chunk.columns = chunk.columns.astype(str).str.strip()
        chunk["AuthorID"] = clean_id_series(chunk["AuthorID"])
        chunk = chunk[
            valid_id_mask(chunk["AuthorID"])
            & chunk["AuthorID"].isin(target_author_set)
        ].copy()

        if not chunk.empty:
            chunk["leadership_raw"] = pd.to_numeric(
                chunk[hindex_column], errors="coerce"
            )
            matched_chunks.append(chunk[["AuthorID", "leadership_raw"]])

        if index == 1 or index % 10 == 0:
            kept = sum(len(x) for x in matched_chunks)
            print(
                f"Processed author chunks: {index}; matched rows so far: {kept}",
                flush=True,
            )

    if matched_chunks:
        leadership = pd.concat(matched_chunks, ignore_index=True)
        leadership = leadership.drop_duplicates(subset=["AuthorID"], keep="first")
    else:
        leadership = pd.DataFrame(columns=["AuthorID", "leadership_raw"])

    output = output.merge(leadership, on="AuthorID", how="left")

    matched = int(output["leadership_raw"].notna().sum())
    missing = int(len(output) - matched)

    print("\n===== Leadership Match Summary =====", flush=True)
    print(f"Authors in network: {len(output):,}", flush=True)
    print(f"Authors matched with H-index: {matched:,}", flush=True)
    print(f"Authors missing H-index: {missing:,}", flush=True)

    if matched == 0:
        raise ValueError(
            "No network authors matched SciSciNet_Authors.tsv. "
            "Check AuthorID formatting and source-file version."
        )

    output["leadership_raw"] = (
        pd.to_numeric(output["leadership_raw"], errors="coerce")
        .fillna(0)
        .astype(float)
    )
    return output


def zscore_log1p(series: pd.Series) -> tuple[pd.Series, pd.Series]:
    raw = pd.to_numeric(series, errors="coerce").fillna(0)
    log_series = np.log1p(raw)
    standard_deviation = log_series.std(skipna=True)
    mean_value = log_series.mean(skipna=True)

    if pd.isna(standard_deviation) or standard_deviation == 0:
        z_score = pd.Series(0.0, index=series.index)
    else:
        z_score = (log_series - mean_value) / standard_deviation

    return log_series, z_score



def build_processed_ergm_files(
    journal_papers: pd.DataFrame,
    clean_nodes: pd.DataFrame,
    clean_edges: pd.DataFrame,
    journal_short_name: str,
    focal_dir: Path,
    focal_start: pd.Timestamp,
    authorpaper_file: Path,
    authors_file: Path,
    chunksize: int,
) -> dict:
    prior_label = focal_start.strftime("%Y_%m_%d")
    output_dir = focal_dir / f"processed_for_ergm_prior_before_{prior_label}"
    output_dir.mkdir(parents=True, exist_ok=True)

    nodes = (
        clean_nodes[["AuthorID"]]
        .assign(AuthorID=lambda frame: clean_id_series(frame["AuthorID"]))
        .drop_duplicates()
        .sort_values("AuthorID")
        .reset_index(drop=True)
    )

    edges = clean_edges.copy()
    if edges.empty:
        edges = pd.DataFrame(columns=["AuthorID_1", "AuthorID_2", "weight"])

    edges["AuthorID_1"] = clean_id_series(edges["AuthorID_1"])
    edges["AuthorID_2"] = clean_id_series(edges["AuthorID_2"])
    edges = edges[
        valid_id_mask(edges["AuthorID_1"])
        & valid_id_mask(edges["AuthorID_2"])
        & (edges["AuthorID_1"] != edges["AuthorID_2"])
    ].copy()

    prior_papers = journal_papers[
        (
            journal_papers["Date"].notna()
            & (journal_papers["Date"] < focal_start)
        )
        | (
            journal_papers["Date"].isna()
            & journal_papers["Year"].notna()
            & (journal_papers["Year"] < focal_start.year)
        )
    ].copy()
    prior_paper_ids = set(prior_papers["PaperID"].dropna().astype(str))
    node_order = nodes["AuthorID"].astype(str).tolist()
    node_set = set(node_order)

    prior_authorpaper = read_authorpaper_subset(
        authorpaper_file,
        target_paper_ids=prior_paper_ids,
        target_author_ids=node_set,
        chunksize=chunksize,
    )

    expertise_counts = (
        prior_authorpaper.groupby("AuthorID")["PaperID"]
        .nunique()
        .reset_index(name="expertise_raw")
    )

    processed_nodes = nodes.merge(expertise_counts, on="AuthorID", how="left")
    processed_nodes["expertise_raw"] = (
        pd.to_numeric(processed_nodes["expertise_raw"], errors="coerce")
        .fillna(0)
        .astype(float)
    )
    (
        processed_nodes["log_expertise"],
        processed_nodes["expertise_z"],
    ) = zscore_log1p(processed_nodes["expertise_raw"])

    leadership = load_leadership(
        authors_file,
        processed_nodes["AuthorID"],
        chunksize=chunksize,
    )
    processed_nodes = processed_nodes.merge(
        leadership[["AuthorID", "leadership_raw"]],
        on="AuthorID",
        how="left",
    )
    processed_nodes["leadership_raw"] = (
        pd.to_numeric(processed_nodes["leadership_raw"], errors="coerce")
        .fillna(0)
        .astype(float)
    )
    (
        processed_nodes["log_leadership"],
        processed_nodes["leadership_z"],
    ) = zscore_log1p(processed_nodes["leadership_raw"])

    node_prefix = f"{journal_short_name}_"
    processed_nodes["global_id"] = node_prefix + processed_nodes["AuthorID"].astype(str)
    processed_nodes["dataset"] = journal_short_name
    processed_nodes["expertise_raw_shared"] = processed_nodes["expertise_raw"]
    processed_nodes["leadership_raw_shared"] = processed_nodes["leadership_raw"]
    processed_nodes["expertise_z_shared"] = processed_nodes["expertise_z"]
    processed_nodes["leadership_z_shared"] = processed_nodes["leadership_z"]

    processed_nodes = processed_nodes[
        [
            "global_id",
            "dataset",
            "AuthorID",
            "expertise_raw",
            "log_expertise",
            "expertise_z",
            "leadership_raw",
            "log_leadership",
            "leadership_z",
            "expertise_raw_shared",
            "leadership_raw_shared",
            "expertise_z_shared",
            "leadership_z_shared",
        ]
    ].copy()

    processed_edges = edges.copy()
    processed_edges["u"] = node_prefix + processed_edges["AuthorID_1"].astype(str)
    processed_edges["v"] = node_prefix + processed_edges["AuthorID_2"].astype(str)
    processed_edges = (
        processed_edges[["u", "v"]]
        .drop_duplicates()
        .sort_values(["u", "v"])
        .reset_index(drop=True)
    )

    number_of_nodes = len(node_order)
    if number_of_nodes > 5_000:
        raise ValueError(
            f"The prior matrix would contain {number_of_nodes:,} nodes. "
            "Apply a stronger k filter before creating a dense matrix."
        )

    id_to_index = {author_id: index for index, author_id in enumerate(node_order)}
    prior_matrix = np.zeros((number_of_nodes, number_of_nodes), dtype=np.uint8)

    for _, group in prior_authorpaper.groupby("PaperID", sort=False):
        authors = sorted(set(group["AuthorID"].astype(str)))
        for author_a, author_b in combinations(authors, 2):
            index_a = id_to_index[author_a]
            index_b = id_to_index[author_b]
            prior_matrix[index_a, index_b] = 1
            prior_matrix[index_b, index_a] = 1

    np.fill_diagonal(prior_matrix, 0)

    prefixed_order = [node_prefix + author_id for author_id in node_order]
    processed_prior_matrix = pd.DataFrame(
        prior_matrix,
        index=prefixed_order,
        columns=prefixed_order,
    )

    upper_rows, upper_columns = np.where(np.triu(prior_matrix, k=1) == 1)
    prior_edges = pd.DataFrame(
        {
            "u": [prefixed_order[index] for index in upper_rows],
            "v": [prefixed_order[index] for index in upper_columns],
            "prior": 1,
        }
    )

    nodes_file = output_dir / f"{journal_short_name}_nodes.csv"
    edges_file = output_dir / f"{journal_short_name}_edges.csv"
    prior_file = output_dir / f"{journal_short_name}_prior_mat.csv"
    prior_edges_file = output_dir / f"{journal_short_name}_prior_edges.csv"

    processed_nodes.to_csv(nodes_file, index=False)
    processed_edges.to_csv(edges_file, index=False)
    processed_prior_matrix.to_csv(prior_file)
    prior_edges.to_csv(prior_edges_file, index=False)

    return {
        "processed_nodes": processed_nodes,
        "processed_edges": processed_edges,
        "processed_prior_matrix": processed_prior_matrix,
        "prior_edges": prior_edges,
        "output_dir": output_dir,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Build one exact-date-range SciSciNet journal "
            "coauthorship network for ERGM."
        )
    )
    parser.add_argument("--journal", required=True, help="Exact or partial journal name.")
    parser.add_argument(
        "--journal-id",
        default=None,
        help="Required only when the journal-name query matches multiple JournalIDs.",
    )
    parser.add_argument(
        "--start-date",
        required=True,
        help="Inclusive focal start date in YYYY-MM-DD format.",
    )
    parser.add_argument(
        "--end-date",
        required=True,
        help="Inclusive focal end date in YYYY-MM-DD format.",
    )
    parser.add_argument(
        "--k",
        required=True,
        type=int,
        help="Minimum number of focal-period papers per author.",
    )
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=DEFAULT_PROJECT_DIR,
        help="SciSciNet project directory containing raw/ and processed/.",
    )
    parser.add_argument(
        "--chunksize",
        type=int,
        default=DEFAULT_CHUNKSIZE,
        help="Rows per pandas input chunk.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()

    if args.k < 1:
        raise ValueError("--k must be at least 1.")
    if args.chunksize < 10_000:
        raise ValueError("--chunksize should be at least 10,000 rows.")

    project_dir = args.project_dir.expanduser().resolve()
    raw_dir = project_dir / "raw"
    processed_root = project_dir / "processed"

    papers_file = raw_dir / "SciSciNet_Papers.tsv"
    journals_file = raw_dir / "SciSciNet_Journals.tsv"
    authorpaper_file = raw_dir / "SciSciNet_PaperAuthorAffiliations.tsv"
    authors_file = raw_dir / "SciSciNet_Authors.tsv"

    processed_root.mkdir(parents=True, exist_ok=True)

    print("===== SciSciNet CRC Pipeline =====", flush=True)
    print(f"Project directory: {project_dir}", flush=True)
    print(f"Journal query: {args.journal}", flush=True)
    print(f"Focal start date: {args.start_date}", flush=True)
    print(f"Focal end date (inclusive): {args.end_date}", flush=True)
    print(f"k: {args.k}", flush=True)
    print(f"Chunk size: {args.chunksize:,}", flush=True)

    validate_source_files(
        papers_file,
        journals_file,
        authorpaper_file,
        authors_file,
    )

    journals = load_journals(journals_file)
    journal_name, journal_ids = choose_journal(
        journals,
        journal_query=args.journal,
        journal_id=args.journal_id,
    )

    print(f"\nSelected journal: {journal_name}", flush=True)
    print(f"JournalIDs: {sorted(journal_ids)}", flush=True)

    focal_start, focal_end, period_label = parse_date_range(
        args.start_date,
        args.end_date,
    )

    journal_papers = scan_journal_papers(
        papers_file,
        journal_ids=journal_ids,
        journal_name=journal_name,
        focal_start=focal_start,
        focal_end=focal_end,
        chunksize=args.chunksize,
    )

    journal_short_name = make_short_name(journal_name)
    journal_folder = processed_root / safe_name(journal_name)
    journal_folder.mkdir(parents=True, exist_ok=True)

    # Retain the selected journal's historical + focal papers as a compact
    # Parquet cache. No yearly-count CSV or yearly-count image is generated.
    papers_file_out = journal_folder / f"{journal_short_name}_all_papers.parquet"
    journal_papers.to_parquet(papers_file_out, index=False)

    focal_result = build_focal_network(
        journal_papers=journal_papers,
        authorpaper_file=authorpaper_file,
        focal_start=focal_start,
        focal_end=focal_end,
        k=args.k,
        chunksize=args.chunksize,
    )

    focal_dir = journal_folder / f"{journal_short_name}_{period_label}_k{args.k}"
    focal_dir.mkdir(parents=True, exist_ok=True)

    clean_papers_file = (
        focal_dir
        / f"{journal_short_name}_{period_label}_filtered_papers_k{args.k}.csv"
    )
    clean_authorpaper_file = (
        focal_dir
        / f"{journal_short_name}_{period_label}_filtered_authorpaper_k{args.k}.csv"
    )
    clean_nodes_file = (
        focal_dir
        / f"{journal_short_name}_{period_label}_clean_network_nodes_k{args.k}.csv"
    )
    clean_edges_file = (
        focal_dir
        / f"{journal_short_name}_{period_label}_clean_network_edges_k{args.k}.csv"
    )
    active_authors_file = (
        focal_dir
        / f"{journal_short_name}_{period_label}_active_authors_k{args.k}.csv"
    )
    summary_file = focal_dir / f"{journal_short_name}_{period_label}_summary_k{args.k}.json"

    focal_result["clean_papers"].to_csv(clean_papers_file, index=False)
    focal_result["clean_authorpaper"].to_csv(clean_authorpaper_file, index=False)
    focal_result["clean_nodes"].to_csv(clean_nodes_file, index=False)
    focal_result["clean_edges"].to_csv(clean_edges_file, index=False)
    focal_result["active_authors"].to_csv(active_authors_file, index=False)

    with summary_file.open("w", encoding="utf-8") as output:
        json.dump(focal_result["summary"], output, indent=2)


    ergm_result = build_processed_ergm_files(
        journal_papers=journal_papers,
        clean_nodes=focal_result["clean_nodes"],
        clean_edges=focal_result["clean_edges"],
        journal_short_name=journal_short_name,
        focal_dir=focal_dir,
        focal_start=focal_start,
        authorpaper_file=authorpaper_file,
        authors_file=authors_file,
        chunksize=args.chunksize,
    )

    print("\n===== Completed =====", flush=True)
    print(json.dumps(focal_result["summary"], indent=2), flush=True)
    print(f"Journal output: {journal_folder}", flush=True)
    print(f"Selected-paper cache: {papers_file_out}", flush=True)
    print(f"ERGM output: {ergm_result['output_dir']}", flush=True)
    print(
        f"Prior dyads: {int(ergm_result['prior_edges'].shape[0]):,}",
        flush=True,
    )
    print(
        "Leadership nonzero authors: "
        f"{int((ergm_result['processed_nodes']['leadership_raw'] > 0).sum()):,}",
        flush=True,
    )

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"\nERROR: {error}", file=sys.stderr, flush=True)
        raise
