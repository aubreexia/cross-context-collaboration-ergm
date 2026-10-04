# Data policy

No raw, actor-level, or dyad-level data are included in this public release.
The expected local structure is:

```text
data/
  raw/        # provider-supplied data; ignored by Git
  processed/  # locally generated ERGM input triplets; ignored by Git
  derived/    # optional locally generated diagnostics; ignored by Git
```

The public `results/` directory contains only aggregate release tables.  The
scripts may write actor IDs and dyad-level files locally; keep those files out
of a public remote unless data governance and provider terms explicitly permit
their release.
