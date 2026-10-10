# Data access and release boundaries

This repository is a public code-and-results release, not a redistribution of
the underlying records.

| Domain | Source material needed locally | Public-release status |
| --- | --- | --- |
| MyDreamTeam | Approved classroom-team files | Restricted; do not upload. |
| GHTorrent | The documented snapshot/export of projects, commits, and followers | Obtain under the source's applicable terms; do not publish actor/dyad extracts here. |
| SciSciNet | Papers, journals, paper-author affiliations, and author records | Obtain from the SciSciNet source under its applicable terms; do not publish constructed author/dyad extracts here. |

Before publishing, inspect `git status --ignored` and verify that no `data/raw/`,
`data/processed/`, output `.rds`, absolute paths, author/user IDs, or dyad
files have been staged.  The release tables included under `results/` are
aggregate-only and have been stripped of machine-specific path columns.

If a reviewer requires restricted materials, use the approved institutional
or data-provider access route rather than adding them to this repository.
