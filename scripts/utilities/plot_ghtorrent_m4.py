"""Generate the two main-text GHTorrent ERGM figures from M4 estimates.

This script deliberately uses M4 as the primary specification:

    M4 = edges + prior collaboration + expertise level + expertise difference
         + leadership level + leadership difference

It does not plot the M5 GWESP estimates.  Those can be reported separately in
an appendix or supplementary repository.

Example (run from any directory):

    python3 generate_ghtorrent_m4_figures.py \
      --separate "/path/to/all_language_ergm_results_gwesp_mle.xlsx" \
      --block "/path/to/block_diagonal_language_ergm_results.xlsx" \
      --output-dir "/path/to/your/LaTex-project/Figures"

The output directory receives exactly two PNG files:

    figure_ghtorrent_m4_prior_forest.png
    figure_ghtorrent_m4_covariate_heatmap.png

Requirements:
    pip install pandas openpyxl matplotlib numpy
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


# Keep this setting explicit so that a later appendix version can change it
# without changing any plotting logic.
PRIMARY_MODEL = "m4_full"
Z_95 = 1.96

LANGUAGE_ORDER = [
    "C",
    "C++",
    "CSS",
    "HTML",
    "Java",
    "JavaScript",
    "Jupyter Notebook",
    "Python",
    "Ruby",
    "TypeScript",
]

SEPARATE_TERMS = {
    "prior": "edgecov.prior",
    "expertise_level": "nodecov.expertise_model_z",
    "expertise_difference": "absdiff.expertise_model_z",
    "leadership_level": "nodecov.leadership_model_z",
    "leadership_difference": "absdiff.leadership_model_z",
}

BLOCK_TERMS = {
    "prior": "edgecov.prior_big",
    "expertise_level": "nodecov.expertise_model_z",
    "expertise_difference": "absdiff.expertise_model_z",
    "leadership_level": "nodecov.leadership_model_z",
    "leadership_difference": "absdiff.leadership_model_z",
}

HEATMAP_COLUMNS = [
    ("expertise_level", "Expertise\nlevel"),
    ("expertise_difference", "Expertise\nabsolute difference"),
    ("leadership_level", "Leadership\nlevel"),
    ("leadership_difference", "Leadership\nabsolute difference"),
]


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create main-text M4 GHTorrent ERGM figures."
    )
    parser.add_argument(
        "--separate",
        type=Path,
        required=True,
        help="Separate-language ERGM workbook (.xlsx).",
    )
    parser.add_argument(
        "--block",
        type=Path,
        required=True,
        help="Block-diagonal ERGM workbook (.xlsx).",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("Figures"),
        help="Directory for the two PNG figures (default: Figures).",
    )
    return parser.parse_args()


def require_columns(data: pd.DataFrame, columns: set[str], source: Path) -> None:
    missing = columns.difference(data.columns)
    if missing:
        raise ValueError(
            f"{source.name} is missing required column(s): {', '.join(sorted(missing))}"
        )


def load_m4_rows(workbook: Path, term_map: dict[str, str]) -> pd.DataFrame:
    """Read the M4 coefficient rows and validate one row per requested term."""
    if not workbook.is_file():
        raise FileNotFoundError(f"Workbook not found: {workbook}")

    data = pd.read_excel(workbook, sheet_name="coefficients_all_models")
    require_columns(
        data,
        {"model", "term", "Estimate", "Std_Error", "p_value", "status"},
        workbook,
    )

    data = data.loc[
        data["model"].astype(str).eq(PRIMARY_MODEL)
        & data["status"].astype(str).str.lower().eq("ok")
        & data["term"].astype(str).isin(term_map.values())
    ].copy()
    data["Estimate"] = pd.to_numeric(data["Estimate"], errors="coerce")
    data["Std_Error"] = pd.to_numeric(data["Std_Error"], errors="coerce")
    data["p_value"] = pd.to_numeric(data["p_value"], errors="coerce")

    if data[["Estimate", "Std_Error", "p_value"]].isna().any().any():
        raise ValueError(f"{workbook.name} has nonnumeric M4 coefficient values.")
    return data


def prepare_separate_data(workbook: Path) -> pd.DataFrame:
    data = load_m4_rows(workbook, SEPARATE_TERMS)
    require_columns(data, {"language"}, workbook)
    data["language"] = data["language"].astype(str)

    expected_pairs = {
        (language, term)
        for language in LANGUAGE_ORDER
        for term in SEPARATE_TERMS.values()
    }
    observed_pairs = set(zip(data["language"], data["term"]))
    missing = expected_pairs.difference(observed_pairs)
    extra_languages = set(data["language"]).difference(LANGUAGE_ORDER)

    if missing:
        examples = "; ".join(f"{language}: {term}" for language, term in sorted(missing))
        raise ValueError(f"Missing M4 coefficient rows: {examples}")
    if extra_languages:
        raise ValueError(
            "Unexpected language labels in the separate-model workbook: "
            + ", ".join(sorted(extra_languages))
        )
    if data.duplicated(subset=["language", "term"]).any():
        raise ValueError("Duplicate M4 language--term rows were found.")
    return data


def prepare_block_data(workbook: Path) -> pd.DataFrame:
    data = load_m4_rows(workbook, BLOCK_TERMS)
    expected_terms = set(BLOCK_TERMS.values())
    observed_terms = set(data["term"])
    missing = expected_terms.difference(observed_terms)

    if missing:
        raise ValueError("Missing pooled M4 coefficient rows: " + ", ".join(sorted(missing)))
    if data.duplicated(subset=["term"]).any():
        raise ValueError("Duplicate pooled M4 coefficient rows were found.")
    return data


def stars(p_value: float) -> str:
    if p_value < 0.001:
        return "***"
    if p_value < 0.01:
        return "**"
    if p_value < 0.05:
        return "*"
    return ""


def row_for_term(data: pd.DataFrame, term: str) -> pd.Series:
    row = data.loc[data["term"].eq(term)]
    if len(row) != 1:
        raise ValueError(f"Expected one row for term {term!r}; found {len(row)}.")
    return row.iloc[0]


def draw_prior_forest(separate: pd.DataFrame, block: pd.DataFrame, output_path: Path) -> None:
    rows: list[dict[str, float | str]] = []
    for language in LANGUAGE_ORDER:
        row = separate.loc[
            separate["language"].eq(language)
            & separate["term"].eq(SEPARATE_TERMS["prior"])
        ].iloc[0]
        rows.append(
            {
                "label": language,
                "estimate": float(row["Estimate"]),
                "se": float(row["Std_Error"]),
                "kind": "language",
            }
        )

    pooled = row_for_term(block, BLOCK_TERMS["prior"])
    rows.append(
        {
            "label": "Pooled block-diagonal",
            "estimate": float(pooled["Estimate"]),
            "se": float(pooled["Std_Error"]),
            "kind": "pooled",
        }
    )

    figure, axis = plt.subplots(figsize=(7.2, 5.9))
    y_positions = np.arange(len(rows))
    estimates = np.array([row["estimate"] for row in rows], dtype=float)
    errors = Z_95 * np.array([row["se"] for row in rows], dtype=float)

    for index, row in enumerate(rows):
        marker = "D" if row["kind"] == "pooled" else "o"
        color = "#a05a2c" if row["kind"] == "pooled" else "#1f5a85"
        axis.errorbar(
            estimates[index],
            y_positions[index],
            xerr=errors[index],
            fmt=marker,
            color=color,
            ecolor=color,
            markersize=6.4 if row["kind"] == "pooled" else 5.2,
            elinewidth=1.25,
            capsize=2.5,
            zorder=3,
        )

    axis.axvline(0, color="#4a4a4a", linewidth=0.9, linestyle="--", zorder=1)
    axis.set_yticks(y_positions, [str(row["label"]) for row in rows])
    axis.invert_yaxis()
    axis.set_xlabel("ERGM coefficient ($\\hat{\\theta}$)")
    axis.set_ylabel("")
    axis.grid(axis="x", color="#d9d9d9", linewidth=0.7, alpha=0.8)
    for side in ("top", "right", "left"):
        axis.spines[side].set_visible(False)
    axis.tick_params(axis="y", length=0)
    figure.tight_layout()
    figure.savefig(output_path, dpi=600, bbox_inches="tight")
    plt.close(figure)


def draw_covariate_heatmap(separate: pd.DataFrame, output_path: Path) -> None:
    estimates = np.empty((len(LANGUAGE_ORDER), len(HEATMAP_COLUMNS)))
    labels = np.empty((len(LANGUAGE_ORDER), len(HEATMAP_COLUMNS)), dtype=object)

    for row_index, language in enumerate(LANGUAGE_ORDER):
        language_rows = separate.loc[separate["language"].eq(language)]
        for column_index, (key, _) in enumerate(HEATMAP_COLUMNS):
            row = row_for_term(language_rows, SEPARATE_TERMS[key])
            estimate = float(row["Estimate"])
            estimates[row_index, column_index] = estimate
            labels[row_index, column_index] = f"{estimate:.2f}{stars(float(row['p_value']))}"

    limit = max(0.5, float(np.ceil(np.abs(estimates).max() * 10) / 10))
    figure, axis = plt.subplots(figsize=(8.3, 5.6))
    image = axis.imshow(estimates, cmap="RdBu_r", vmin=-limit, vmax=limit, aspect="auto")

    for row_index in range(estimates.shape[0]):
        for column_index in range(estimates.shape[1]):
            color = "white" if abs(estimates[row_index, column_index]) > limit * 0.53 else "black"
            axis.text(
                column_index,
                row_index,
                labels[row_index, column_index],
                ha="center",
                va="center",
                fontsize=8.2,
                color=color,
            )

    axis.set_xticks(
        np.arange(len(HEATMAP_COLUMNS)),
        [label for _, label in HEATMAP_COLUMNS],
        fontsize=8.6,
    )
    axis.set_yticks(np.arange(len(LANGUAGE_ORDER)), LANGUAGE_ORDER, fontsize=9)
    axis.tick_params(axis="both", length=0)
    axis.set_xticks(np.arange(-0.5, len(HEATMAP_COLUMNS), 1), minor=True)
    axis.set_yticks(np.arange(-0.5, len(LANGUAGE_ORDER), 1), minor=True)
    axis.grid(which="minor", color="white", linewidth=1.1)
    axis.tick_params(which="minor", bottom=False, left=False)

    colorbar = figure.colorbar(image, ax=axis, fraction=0.045, pad=0.03)
    colorbar.set_label("ERGM coefficient ($\\hat{\\theta}$)", fontsize=8.5)
    colorbar.ax.tick_params(labelsize=8)
    figure.tight_layout()
    figure.savefig(output_path, dpi=600, bbox_inches="tight")
    plt.close(figure)


def main() -> None:
    args = parse_arguments()
    output_dir = args.output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    separate = prepare_separate_data(args.separate.expanduser().resolve())
    block = prepare_block_data(args.block.expanduser().resolve())

    prior_path = output_dir / "figure_ghtorrent_m4_prior_forest.png"
    heatmap_path = output_dir / "figure_ghtorrent_m4_covariate_heatmap.png"
    draw_prior_forest(separate, block, prior_path)
    draw_covariate_heatmap(separate, heatmap_path)

    print(f"[SAVED] {prior_path}")
    print(f"[SAVED] {heatmap_path}")


if __name__ == "__main__":
    main()
