"""Compare a fresh M0--M4 ERGM run with the archived coefficient tables.

Run after scripts/01_fit_separate_m0_m4.R and 02_fit_block_m0_m4.R, for example:

python3 scripts/05_verify_archived_results.py \
  --separate results/recomputed/separate_m0_m4/all_journal_all_model_coefficients.csv \
  --block results/recomputed/block_m0_m4/block_diagonal_all_model_coefficients.csv

The check compares only successful coefficient rows and the Estimate and
Std_Error columns. It exits nonzero if a model term is missing, unexpected,
or outside the specified numerical tolerance.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
ARCHIVED_SEPARATE = (
    REPOSITORY_ROOT
    / "results"
    / "model_fits"
    / "separate_m0_m4"
    / "coefficients_all_models.csv"
)
ARCHIVED_BLOCK = (
    REPOSITORY_ROOT
    / "results"
    / "model_fits"
    / "block_m0_m4"
    / "coefficients_all_models.csv"
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare recomputed ERGM coefficients with archived tables."
    )
    parser.add_argument(
        "--separate",
        type=Path,
        required=True,
        help="Fresh all_journal_all_model_coefficients.csv from script 01.",
    )
    parser.add_argument(
        "--block",
        type=Path,
        required=True,
        help="Fresh block_diagonal_all_model_coefficients.csv from script 02.",
    )
    parser.add_argument(
        "--atol",
        type=float,
        default=1e-6,
        help="Absolute tolerance for coefficient comparison (default: 1e-6).",
    )
    parser.add_argument(
        "--rtol",
        type=float,
        default=1e-6,
        help="Relative tolerance for coefficient comparison (default: 1e-6).",
    )
    return parser.parse_args()


def load_successful_coefficients(path: Path, keys: list[str]) -> pd.DataFrame:
    if not path.is_file():
        raise FileNotFoundError(f"Coefficient file not found: {path}")

    table = pd.read_csv(path)
    required = {*keys, "Estimate", "Std_Error", "status"}
    missing = required.difference(table.columns)
    if missing:
        raise ValueError(
            f"{path.name} is missing required columns: {', '.join(sorted(missing))}"
        )

    table = table.loc[
        table["status"].astype(str).str.lower().eq("ok"),
        [*keys, "Estimate", "Std_Error"],
    ].copy()
    if table.duplicated(keys).any():
        raise ValueError(f"{path.name} contains duplicate successful coefficient rows.")
    for column in ("Estimate", "Std_Error"):
        table[column] = pd.to_numeric(table[column], errors="raise")
    return table


def compare_tables(
    label: str,
    archived_path: Path,
    fresh_path: Path,
    keys: list[str],
    atol: float,
    rtol: float,
) -> tuple[bool, str]:
    archived = load_successful_coefficients(archived_path, keys)
    fresh = load_successful_coefficients(fresh_path, keys)

    merged = archived.merge(
        fresh,
        on=keys,
        how="outer",
        suffixes=("_archived", "_fresh"),
        indicator=True,
    )
    missing_or_unexpected = merged.loc[merged["_merge"].ne("both")]
    if not missing_or_unexpected.empty:
        example = missing_or_unexpected[[*keys, "_merge"]].head(10).to_string(index=False)
        return False, f"{label}: mismatched model-term coverage:\n{example}"

    mismatches: list[pd.DataFrame] = []
    for column in ("Estimate", "Std_Error"):
        close = np.isclose(
            merged[f"{column}_archived"],
            merged[f"{column}_fresh"],
            atol=atol,
            rtol=rtol,
            equal_nan=True,
        )
        if not bool(close.all()):
            mismatches.append(
                merged.loc[
                    ~close,
                    [*keys, f"{column}_archived", f"{column}_fresh"],
                ]
            )

    if mismatches:
        example = pd.concat(mismatches, ignore_index=True).head(10).to_string(index=False)
        return False, f"{label}: numerical mismatch outside tolerance:\n{example}"

    return True, f"{label}: {len(merged)} successful coefficient rows match."


def main() -> int:
    arguments = parse_arguments()
    checks = [
        compare_tables(
            "Separate models",
            ARCHIVED_SEPARATE,
            arguments.separate.expanduser().resolve(),
            ["journal", "model", "term"],
            arguments.atol,
            arguments.rtol,
        ),
        compare_tables(
            "Block-diagonal model",
            ARCHIVED_BLOCK,
            arguments.block.expanduser().resolve(),
            ["analysis", "model", "term"],
            arguments.atol,
            arguments.rtol,
        ),
    ]
    for _, message in checks:
        print(message)
    return 0 if all(ok for ok, _ in checks) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, ValueError) as error:
        print(f"Verification failed: {error}", file=sys.stderr)
        raise SystemExit(2)
