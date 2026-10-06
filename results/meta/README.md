# Random-effects meta-analysis

`M4_meta_input_estimates.csv` contains the 30 network-specific M4 estimates
and standard errors for five theory-relevant terms.  
`M4_random_effects_meta_summary.csv` contains the within-domain REML results
with Knapp--Hartung confidence intervals, `tau^2`, `I^2`, Cochran's Q, and
95% prediction intervals.

Run `scripts/r/09_verify_public_meta_results.R results/meta` to refit these
models directly from the public aggregate table.  The script writes a new
`M4_random_effects_meta_recomputed.csv` file locally. Review the result before
deciding whether to commit it as a new release artifact.
