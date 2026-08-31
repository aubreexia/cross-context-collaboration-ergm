# Release checklist

- [ ] Confirm that the manuscript's reported SciSciNet coefficients match `results/model_fits/` exactly.
- [ ] Deposit the processed `data/processed/journals/` archive and replace the placeholder URL in `data/README.md` and `docs/SUBMISSION_TEXT.md`.
- [ ] Run `scripts/00_capture_session_info.R` in the final R environment and commit the saved output.
- [ ] Re-run M0--M4 and compare results with `scripts/05_verify_archived_results.py`.
- [ ] Re-run the figure script and inspect both PNGs.
- [ ] Update `CITATION.cff` and `.zenodo.json` with the final manuscript title, contributor list, ORCIDs, repository URL, and DOI.
- [ ] Tag the release (for example, `v1.0.0`) and archive that tag with Zenodo or OSF.
- [ ] If peer review is blinded, publish a separate anonymized copy rather than altering the archival release.
