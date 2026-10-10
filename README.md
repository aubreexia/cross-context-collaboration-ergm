# Cross-Context Collaboration ERGMs

Replication code and public aggregate results for a study of collaboration
networks in three settings: classroom project teams, open-source software
development, and scientific coauthorship. The analysis covers 30 undirected,
binary networks: 10 MyDreamTeam classroom sessions, 10 GHTorrent programming
language communities, and 10 SciSciNet journals.

The study asks whether prior collaboration, expertise, and leadership or
status are associated with focal-period collaboration across these distinct
settings. Separate-network ERGMs support the within-domain meta-analyses.
Pooled block-diagonal ERGMs provide the cross-network structural analyses.

## Study design

| Domain | Networks | Focal collaboration tie | Focal window | Expertise | Leadership or status |
| --- | ---: | --- | --- | --- | --- |
| MyDreamTeam | 10 classroom-team sessions | Collaboration between two students in a selected session | Ten selected classroom sessions | Skill measure | Leadership measure |
| GHTorrent | 10 programming languages | Two developers each made at least 10 April 2020 commits to the same language-matched repository | April 2020 | Pre-April count of focal-language repositories | Follower count from the documented snapshot |
| SciSciNet | 10 journals | Two retained authors coauthored a target-journal paper in 2020 | 2020 | Pre-2020 target-journal publication count | Author h-index |

All focal ties and prior-collaboration indicators are binary and undirected.
The same conceptual terms are operationalized within each setting rather than
assumed to be identical measures across settings.

## Model hierarchy

M4 is the shared dyad-independent reference specification:

    edges + prior collaboration + expertise level + expertise difference
          + status level + status difference

The current primary pooled block model is M5-D:

    M5-D = M4 + gwdegree(0.50, fixed = TRUE)

M5-D is estimated separately for MyDreamTeam, GHTorrent, and SciSciNet using
MCMLE. Each model retains one global edges term and the blockdiag constraint:
ties are permitted only within sessions, languages, or journals. Therefore,
the added GWdegree term is not a change to the density specification.

The older GHTorrent-only GWESP analysis is retained as M5-E, a supplementary
structural sensitivity analysis. It is not the cross-domain primary model and
is not interchangeable with M5-D.

| Domain | GWdegree estimate | Lowest final model-statistic GOF MC p-value |
| --- | ---: | ---: |
| MyDreamTeam | 6.101 | 0.936 |
| GHTorrent | 0.819 | 0.840 |
| SciSciNet | -1.263 | 0.664 |

These GOF values come from 500 constrained simulations of the final fitted
model statistics. They show that the observed fitted statistics fall within
the simulated distributions; they are not a general goodness-of-fit test for
all network features. The GWdegree coefficient is a nonlinear structural
parameter and is not reported as a dyadic odds ratio. See
docs/M5D_GWDEGREE.md for the full specification, diagnostics scope, and result
locations.

## Repository structure

| Location | Contents |
| --- | --- |
| configs/ | Session, language, journal, date-window, and selection settings. |
| scripts/python/sciscinet/ | SciSciNet author selection and ERGM-input construction. |
| scripts/python/ghtorrent/ | GHTorrent audit and language-network construction. |
| scripts/r/ | ERGM estimation, constrained GOF, and meta-analysis scripts. |
| results/ | Public aggregate results, including final M5-D coefficient and GOF tables. |
| docs/ | Variable definitions, M5-D specification, run order, and reproducibility notes. |
| environment/ | Python and R dependency installation files. |

## Quick start

Install the recorded dependencies:

    python -m pip install -r environment/requirements-python.txt
    Rscript environment/install_r_packages.R

Protected source data must be obtained separately and kept outside the
repository or in ignored data/raw paths. After creating local processed inputs,
run the domain workflow below.

SciSciNet:

    Rscript scripts/r/01_fit_sciscinet_separate_m0_m4.R data/processed/sciscinet
    Rscript scripts/r/02_fit_sciscinet_block_m0_m4.R data/processed/sciscinet
    Rscript scripts/r/12_fit_sciscinet_block_m5d_gwdegree.R data/processed/sciscinet
    Rscript scripts/r/15_gof_sciscinet_block_m5d_gwdegree.R data/processed/sciscinet

GHTorrent:

    Rscript scripts/r/03_fit_ghtorrent_separate_m0_m5.R data/processed/ghtorrent
    Rscript scripts/r/04_fit_ghtorrent_block_m0_m5.R data/processed/ghtorrent
    Rscript scripts/r/11_fit_ghtorrent_block_m5d_gwdegree.R data/processed/ghtorrent
    Rscript scripts/r/14_gof_ghtorrent_block_m5d_gwdegree.R data/processed/ghtorrent

MyDreamTeam:

    Rscript scripts/r/10_fit_mydreamteam_block_m5d_gwdegree.R data/processed/mydreamteam
    Rscript scripts/r/13_gof_mydreamteam_block_m5d_gwdegree.R data/processed/mydreamteam

The existing 05, 08, and related GWESP scripts remain in the repository for
historical M5-E replication. The M5-D scripts are the scripts corresponding
to the pooled primary model in the current manuscript. Use
docs/RUN_ORDER.md for preprocessing details and dependencies between scripts.

To reproduce the M4 random-effects meta-analysis from released aggregate
estimate and standard-error rows, without restricted source data, run:

    Rscript scripts/r/09_verify_public_meta_results.R results/meta

## Public-release boundaries

This is a public code-and-results release, not a redistribution of source
records. The results directory contains aggregate coefficients, model-fit
summaries, GOF tables, and result figures. It contains no raw records, actor
identifiers, dyad-level inputs, input matrices, absolute paths, or fitted RDS
objects.

MyDreamTeam data are restricted. GHTorrent and SciSciNet source data remain
subject to their respective access terms. See docs/DATA_ACCESS.md before
making a release.

## License and citation

Code is released under the MIT License. Before archival release, create a
tagged GitHub release, archive it with Zenodo, and add the resulting DOI and
recommended citation here.
