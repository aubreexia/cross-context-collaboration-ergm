"""Generate the two main-text SciSciNet ERGM figures from M4 estimates.

Outputs
-------
figure_sciscinet_m4_prior_forest.png
    Separate-journal prior-collaboration estimates with 95% Wald confidence
    intervals, plus the pooled block-diagonal estimate.

figure_sciscinet_m4_covariate_heatmap.png
    Separate-journal estimates for expertise and leadership covariates.

Example
-------
python generate_sciscinet_m4_figures.py \
    --separate "results/model_fits/separate_m0_m4/coefficients_m4.csv" \
    --block "results/model_fits/block_m0_m4/coefficients_m4.csv" \
    --output-dir "/path/to/LaTex-project/Figures"

Requirements
------------
pip install pandas openpyxl matplotlib numpy
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


PRIMARY_MODEL = "m4_full"
Z_95 = 1.96

JOURNAL_ORDER = [
    "Cell",
    "Geology",
    "Journal of the ACM",
    "Management Science",
    "Mind",
    "Nature Climate Change",
    "Nature Materials",
    "Psychological Science",
    "The Economic Journal",
    "The New England Journal of Medicine",
]

DISPLAY_LABELS = {
    "The New England Journal of Medicine": "The New England Journal\nof Medicine",
}

SEPARATE_TERMS = {
    "prior": "edgecov.prior",
    "expertise_level": "nodecov.expertise_model_z",
    "expertise_difference": "absdiff.expertise_model_z",
    "leadership_level": "nodecov.leadership_model_z",
    "leadership_difference": "absdiff.leadership_model_z",
}

BLOCK_PRIOR_TERM = "edgecov.prior_big"

HEATMAP_COLUMNS = [
    ("expertise_level", "Expertise\nlevel"),
    ("expertise_difference", "Expertise\nabsolute difference"),
    ("leadership_level", "Leadership\nlevel"),
    ("leadership_difference", "Leadership\nabsolute difference"),
]


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create the main-text SciSciNet M4 ERGM figures."
    )
    parser.add_argument(
        "--separate",
        type=Path,
        required=True,
        help="Separate-journal M4 coefficients (.csv or .xlsx workbook).",
    )
    parser.add_argument(
        "--block",
        type=Path,
        required=True,
        help="Block-diagonal M4 coefficients (.csv or .xlsx workbook).",
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
            f"{source.name} is missing required column(s): {', '.join(sorted(missing))}."
        )


def load_coefficients(source: Path) -> pd.DataFrame:
    """Read a coefficient table from the public CSV or an archived workbook."""
    if not source.is_file():
        raise FileNotFoundError(f"Coefficient file not found: {source}")

    suffix = source.suffix.lower()
    if suffix == ".csv":
        return pd.read_csv(source)
    if suffix in {".xlsx", ".xls"}:
        return pd.read_excel(source, sheet_name="coefficients_M4")
    raise ValueError(f"Unsupported coefficient file format: {source.suffix}")


def require_one_row(data: pd.DataFrame, description: str) -> pd.Series:
    if len(data) != 1:
        raise ValueError(f"Expected one row for {description}; found {len(data)}.")
    return data.iloc[0]


def load_separate_m4(workbook: Path) -> pd.DataFrame:
    """Load M4 rows for all plotted terms and validate journal coverage."""
    data = load_coefficients(workbook)
    require_columns(
        data,
        {"journal", "model", "term", "Estimate", "Std_Error", "p_value", "status"},
        workbook,
    )
    data = data.loc[
        data["model"].astype(str).eq(PRIMARY_MODEL)
        & data["term"].astype(str).isin(SEPARATE_TERMS.values())
        & data["status"].astype(str).str.lower().eq("ok")
    ].copy()
    data["journal"] = data["journal"].astype(str)
    for column in ("Estimate", "Std_Error", "p_value"):
        data[column] = pd.to_numeric(data[column], errors="raise")

    expected_pairs = {
        (journal, term)
        for journal in JOURNAL_ORDER
        for term in SEPARATE_TERMS.values()
    }
    observed_pairs = set(zip(data["journal"], data["term"]))
    missing = expected_pairs.difference(observed_pairs)
    unexpected = observed_pairs.difference(expected_pairs)
    if missing or unexpected:
        messages = []
        if missing:
            messages.append(
                "missing: "
                + "; ".join(
                    f"{journal} / {term}" for journal, term in sorted(missing)
                )
            )
        if unexpected:
            messages.append(
                "unexpected: "
                + "; ".join(
                    f"{journal} / {term}" for journal, term in sorted(unexpected)
                )
            )
        raise ValueError("Unexpected M4 coefficient coverage (" + " | ".join(messages) + ").")
    if data.duplicated(subset=["journal", "term"]).any():
        raise ValueError("Duplicate journal--term M4 coefficient rows were found.")
    return data


def load_block_prior(workbook: Path) -> pd.Series:
    """Load the pooled M4 prior-collaboration row."""
    data = load_coefficients(workbook)
    require_columns(
        data,
        {"model", "term", "Estimate", "Std_Error", "p_value", "status"},
        workbook,
    )
    data = data.loc[
        data["model"].astype(str).eq(PRIMARY_MODEL)
        & data["term"].astype(str).eq(BLOCK_PRIOR_TERM)
        & data["status"].astype(str).str.lower().eq("ok")
    ].copy()
    pooled = require_one_row(data, "the pooled M4 prior-collaboration estimate").copy()
    for column in ("Estimate", "Std_Error", "p_value"):
        pooled[column] = pd.to_numeric(pooled[column], errors="raise")
    return pooled


def row_for_term(data: pd.DataFrame, term: str) -> pd.Series:
    row = data.loc[data["term"].eq(term)]
    return require_one_row(row, f"term {term!r}")


def stars(p_value: float) -> str:
    if p_value < 0.001:
        return "***"
    if p_value < 0.01:
        return "**"
    if p_value < 0.05:
        return "*"
    return ""


def draw_prior_forest(
    separate: pd.DataFrame, pooled: pd.Series, output_path: Path
) -> None:
    rows: list[dict[str, float | str]] = []
    for journal in JOURNAL_ORDER:
        journal_rows = separate.loc[separate["journal"].eq(journal)]
        row = row_for_term(journal_rows, SEPARATE_TERMS["prior"])
        rows.append(
            {
                "label": DISPLAY_LABELS.get(journal, journal),
                "estimate": float(row["Estimate"]),
                "se": float(row["Std_Error"]),
                "kind": "journal",
            }
        )
    rows.append(
        {
            "label": "Pooled block-diagonal",
            "estimate": float(pooled["Estimate"]),
            "se": float(pooled["Std_Error"]),
            "kind": "pooled",
        }
    )

    figure, axis = plt.subplots(figsize=(7.7, 6.3))
    y_positions = np.arange(len(rows))
    for position, row in zip(y_positions, rows):
        is_pooled = row["kind"] == "pooled"
        color = "#a05a2c" if is_pooled else "#1f5a85"
        axis.errorbar(
            row["estimate"],
            position,
            xerr=Z_95 * row["se"],
            fmt="D" if is_pooled else "o",
            color=color,
            ecolor=color,
            markersize=6.4 if is_pooled else 5.2,
            elinewidth=1.25,
            capsize=2.5,
            zorder=3,
        )

    axis.axvline(0, color="#4a4a4a", linewidth=0.9, linestyle="--", zorder=1)
    axis.set_yticks(y_positions, [str(row["label"]) for row in rows])
    axis.invert_yaxis()
    axis.set_xlabel(r"ERGM coefficient ($\hat{\theta}$)")
    axis.grid(axis="x", color="#d9d9d9", linewidth=0.7, alpha=0.8)
    axis.margins(x=0.07)
    for side in ("top", "right", "left"):
        axis.spines[side].set_visible(False)
    axis.tick_params(axis="y", length=0)

    figure.tight_layout()
    figure.savefig(output_path, dpi=600, bbox_inches="tight")
    plt.close(figure)


def draw_covariate_heatmap(separate: pd.DataFrame, output_path: Path) -> None:
    """Draw coefficient labels and significance stars for four M4 covariates."""
    estimates = np.empty((len(JOURNAL_ORDER), len(HEATMAP_COLUMNS)))
    labels = np.empty((len(JOURNAL_ORDER), len(HEATMAP_COLUMNS)), dtype=object)

    for row_index, journal in enumerate(JOURNAL_ORDER):
        journal_rows = separate.loc[separate["journal"].eq(journal)]
        for column_index, (key, _) in enumerate(HEATMAP_COLUMNS):
            row = row_for_term(journal_rows, SEPARATE_TERMS[key])
            estimate = float(row["Estimate"])
            estimates[row_index, column_index] = estimate
            labels[row_index, column_index] = (
                f"{estimate:.2f}{stars(float(row['p_value']))}"
            )

    limit = max(0.5, float(np.ceil(np.abs(estimates).max() * 10) / 10))
    figure, axis = plt.subplots(figsize=(9.6, 6.3))
    image = axis.imshow(
        estimates,
        cmap="RdBu_r",
        vmin=-limit,
        vmax=limit,
        aspect="auto",
    )

    for row_index in range(estimates.shape[0]):
        for column_index in range(estimates.shape[1]):
            color = (
                "white"
                if abs(estimates[row_index, column_index]) > limit * 0.53
                else "black"
            )
            axis.text(
                column_index,
                row_index,
                labels[row_index, column_index],
                ha="center",
                va="center",
                fontsize=8.7,
                color=color,
            )

    axis.set_xticks(
        np.arange(len(HEATMAP_COLUMNS)),
        [label for _, label in HEATMAP_COLUMNS],
        fontsize=9.2,
    )
    axis.set_yticks(
        np.arange(len(JOURNAL_ORDER)),
        [DISPLAY_LABELS.get(journal, journal) for journal in JOURNAL_ORDER],
        fontsize=9.2,
    )
    axis.tick_params(axis="both", length=0)
    axis.set_xticks(np.arange(-0.5, len(HEATMAP_COLUMNS), 1), minor=True)
    axis.set_yticks(np.arange(-0.5, len(JOURNAL_ORDER), 1), minor=True)
    axis.grid(which="minor", color="white", linewidth=1.1)
    axis.tick_params(which="minor", bottom=False, left=False)

    colorbar = figure.colorbar(image, ax=axis, fraction=0.045, pad=0.03)
    colorbar.set_label(r"ERGM coefficient ($\hat{\theta}$)", fontsize=9)
    colorbar.ax.tick_params(labelsize=8.5)

    figure.tight_layout()
    figure.savefig(output_path, dpi=600, bbox_inches="tight")
    plt.close(figure)


def main() -> None:
    arguments = parse_arguments()
    output_dir = arguments.output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    separate = load_separate_m4(arguments.separate.expanduser().resolve())
    pooled = load_block_prior(arguments.block.expanduser().resolve())

    forest_path = output_dir / "figure_sciscinet_m4_prior_forest.png"
    heatmap_path = output_dir / "figure_sciscinet_m4_covariate_heatmap.png"
    draw_prior_forest(separate, pooled, forest_path)
    draw_covariate_heatmap(separate, heatmap_path)

    print(f"[SAVED] {forest_path}")
    print(f"[SAVED] {heatmap_path}")


if __name__ == "__main__":
    main()
