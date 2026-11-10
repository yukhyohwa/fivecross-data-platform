# Shared-model case configuration

The project-specific AU input rules live here. The reusable forecasting engine is `../../../../../fivecross-forecast-models`; it does not embed this game's table, identity or paths.

From this directory, using the existing Python environment:

```powershell
$python = "../../../../../fivecross-data-client/venv/Scripts/python.exe"
$engine = "../../../../../fivecross-forecast-models/run.py"
& $python $engine describe --method au_retention_convolution
& $python $engine validate --case case.json --refresh
& $python $engine run --case case.json
& $python $engine run --case case.json --method au_fixed_nuu_comparator
```

`--refresh` is the only option that executes SQL through data-client; without it, cached CSVs are required. Both `validate` and `run` support it. SQL and this configuration intentionally retain the historical observation window, 2026-06-24 through 2026-09-22. Re-running with a later forecast end does not refresh that observation window. To change the observed interval, update and review the case-owned SQL and metric context together.

The retention source is filtered to `record_type=forecast_curve` by this case configuration; this is not an engine-wide rule. Inputs go to `../data/forecast/`; each model execution writes CSV plus a manifest with source hashes and non-null field samples to `../outputs/model_runs/`. Those generated artifacts are ignored by Git.

The historical report scripts remain in `../scripts/`; the model-run result is a separate reproducible output and does not overwrite the existing report. P10/P90 labels from historical scenario reports remain parameter-sensitivity ranges rather than statistical confidence intervals.
