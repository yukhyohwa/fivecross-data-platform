# Slam Dunk KPI Target Completion

This case keeps regional KPI targets and the corresponding ThinkingData report SQL together. TC, KR, and GL SQL are November 2026. The legacy `main.py` reads root-level Excel files, so use the scoped update scripts documented below for monthly refreshes.

## TC November 2026 update

- Source: `input/《SD2》 TC每日KPI預估2026年11月.xlsx`, sheet `每日營收預估2026年11月_tc`, dates `B2:B31`, daily and cumulative targets `I2:J31`.
- All 30 dates and daily multiplication/cumulative addition formulas were validated against cached values. Unrounded monthly target is **2,674,919.23 CNY**; the existing independent whole-unit rounding gives a report month-end target of **2,674,919**. The rounded daily sum is also **2,674,919**; intermediate cumulative values retain independent source rounding.
- Updated only TC target rows, month metadata, and the actual-income date range to November 1–30. Actual-income logic, output aliases, and the KR/GL SQL files were preserved.
- Source verification, October backup, reviewed November SQL, and BI logs: `outputs/2026-11_tc_update/`. The scoped source update is `python outputs/2026-11_tc_update/update_targets.py`.
- Published on November 6 using `thinkingdata-bi-update/main.py` with the absolute TC SQL path. The updater recovered the expired login in the background, calculated the report, and confirmed the update. Report: https://ss-web.5xgames.com/#/tga/ide/20_4423?fromPanel=20_793 . Saved SQL and dashboard verification are retained in `remote_after/` and `remote_after_verification.json`.
- Do not run unfiltered `main.py` or `main.py --sql`: root `input/` contains both September and November TC workbooks, and other root inputs are September. For publishing, pass only the reviewed TC SQL path to the current `thinkingdata-bi-update` tool.

## KR / GL October 2026 update

- Sources: `input/2026-10/《SD2》KR每日KPI預估2026年10月.xlsx` and `input/2026-10/《SD2》WW每日KPI預估2026年10月.xlsx`, each using `工作表1!A2:C32` (日期 / 當日收入 / 當月累計收入).
- Updated only October 1–31 daily revenue and monthly cumulative revenue targets, the query date range and month metadata. Existing actual-income logic and result columns were preserved; TC SQL was not changed.
- Source cumulative values reconcile to the unrounded daily values on all 31 days. SQL retains the existing independent whole-unit rounding for both fields. KR October 31 cumulative is **752,527**; GL / WW is **374,165**. GL rounded daily values sum to **374,167**; the two-unit difference is rounding, so the source cumulative was retained instead of recomputed from rounded daily targets.
- Source checks and September SQL backups: `outputs/2026-10_kr_gl_update/`. BI update outcomes are recorded in `kr_bi_update.log` and `gl_bi_update.log` after invoking the shared `thinkingdata-bi-update/main.py` with each reviewed absolute SQL path.
- BI publication completed after debugging on October 8. Cold page loads exceeded the old 30-second readiness timeout; the updater also mistook the unchanged URL for a valid IDE session. Once loaded, local result aliases differed from the saved chart bindings, causing `图表未正常展示`. The two SQL files now preserve the remote `預估每日sales / 預估月度累積sales / 實際每日sales / 實際累計sales` aliases.
- Both reports were calculated and saved successfully. Reopened saved SQL matches local SQL and all 31 source target rows (`remote_after_verification.json`). GL calculation ID: `20261008_033219_05581_pex5n`; KR: `20261008_033252_05587_pex5n`. The KR dashboard URL is `https://ss-web.5xgames.com/#/panel/panel/22_830_0`; its SQL report URL is `https://ss-web.5xgames.com/#/tga/ide/22_4425?fromPanel=22_830`.
- The supplied KR dashboard was reopened and visually verified: the KPI chart renders October 1–31 daily and cumulative revenue series (`kr_panel_verification/panel.png`). Date labels are drawn on chart canvas, so DOM-only exact-text date checks are not suitable for this dashboard.
- Future updates run in the background without `--show`. The shared updater now also keeps automatic login recovery in the background, requires an actual editor or login form before continuing, reports invalid chart bindings explicitly, and retries browser launches outside the previous Playwright context.

## KR / GL November 2026 update

- Sources: `input/《SD2》KR每日KPI預估2026年11月.xlsx` and `input/《SD2》WW每日KPI預估2026年11月.xlsx`. Each source contains 30 daily target rows for November 1–30; the scoped script validates the complete date coverage and imports the daily and cumulative target values into the paired SQL.
- November target month-end values are **696,029** for KR and **331,555** for GL / WW. The source daily target sums are **696,031** and **331,555**, respectively; KR's two-unit difference is retained from the source cumulative column rather than recomputed from rounded daily values.
- Updated only `sql/sd_kr_kpi_target_completion.sql` and `sql/sd_gl_kpi_target_completion.sql`; TC SQL and the existing actual-income logic/output aliases were preserved. Evidence, SQL backups, validated copies, and BI logs are under `outputs/2026-11_kr_gl_update/`. Re-run the scoped source update with `python outputs/2026-11_kr_gl_update/update_targets.py`.
- Both ThinkingData reports were recalculated and updated successfully using the absolute reviewed SQL paths. Remote readback in `kr_remote_after/remote.sql` and `gl_remote_after/remote.sql` confirms November 1–30 target rows and query bounds; KR login recovery was required and completed automatically.

## TC October 2026 update

- Source: `input/2026-10/《SD2》 TC每日KPI預估2026年10月.xlsx`, sheet `每日營收預估2026年9月_tc` (old sheet name; the actual dates are October 1–31).
- Imported only `I2:I32` (預估每日sales) and `J2:J32` (預估月度累積sales), using dates `B2:B32`. All 31 daily formulas and cumulative formulas matched their cached values. Daily sum and October 31 cumulative are both **3,097,836**, on the existing report's CNY basis; no conversion using the separate T/V columns was applied.
- Updated report: https://ss-web.5xgames.com/#/tga/ide/20_4423?fromPanel=20_793 . Existing remote result-column aliases, actual-income logic and report parameters were preserved.
- Evidence and September SQL backups: `outputs/2026-10_tc_update/`. `remote_after_verification.json` confirms all 31 remote target rows match the source and KR/GL SQL hashes are unchanged. Successful calculation ID: `20260930_071812_17000_pex5n`.
- The actual shared updater directory is now `thinkingdata-bi-update`, not the legacy `fivecross-tdbi-update` path still referenced by the runner below. This TC-only update directly called that shared updater with the absolute TC SQL path.
- **Do not run the unfiltered `main.py` / `main.py --sql` for this October refresh:** the legacy runner reads the September root-level inputs, would roll all three SQL files back to September, and processes all three regions. October's original sources are retained in a dated subdirectory to preserve the September inputs. To republish a reviewed current SQL file, run `thinkingdata-bi-update/main.py` with its absolute path, using the updater-compatible Python environment.


## Directory layout

- `input/`: source Excel workbooks supplied by the operations team.
- `sql/`: report SQL files. Each file contains the target ThinkingData IDE URL in its opening comment and can be uploaded to that report.
- `main.py`: Excel-to-SQL synchronisation and report-update runner. It delegates only the ThinkingData update to the shared `fivecross-tdbi-update` repository.

Keep these directory names as `input/` and `sql/`. `input/` is the conventional name for raw source files in this case, while `sql/` makes the report payloads unambiguous. Renaming them to `inputs/` or `data/` provides no benefit and would require changing the runner and documentation.

## Commands

Before a BI update, configure the shared updater once in the sibling repository `C:\Users\5xgames\Desktop\github\fivecross-tdbi-update` (including its `.env`, dependencies, and first login). The case runner does not implement database connections, browser login, SQL calculation, or report submission; it passes completed SQL files to that shared updater unchanged.

Run the following commands from this case directory. They update ThinkingData reports, so do not run them until the KPI SQL has been reviewed.

```powershell
# Full update: Excel → SQL → ThinkingData
python main.py

# Only update SQL from the Excel workbooks; no ThinkingData update
python main.py --sql

# Only update ThinkingData from the existing SQL files; do not read Excel
python main.py --bi

# Show the browser while updating
python main.py --bi --show
```

`main.py` uses only the Python standard library for Excel reads. For a BI update, use the same Python environment as the shared updater so its dependencies are available.

## KPI maintenance flow

1. Update the relevant daily revenue and monthly cumulative revenue target in the Excel workbook under `input/`.
2. Run `python main.py --sql`. It selects the newest complete month in each workbook and writes its dates, daily revenue, and monthly cumulative revenue into the paired SQL `KpiTarget` block.
3. Review the SQL changes and confirm that each opening-comment ThinkingData URL still points to the intended report.
4. Run `python main.py --bi` to update the three reports, or `python main.py` to run both steps consecutively.

WW and GL refer to the same worldwide/global report version. Keep the existing file name `sd_gl_kpi_target_completion.sql`; the source workbook may use WW terminology.
