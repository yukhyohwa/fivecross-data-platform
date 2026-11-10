# Fivecross Analysis Cases

This repository serves as a centralized collection of ad-hoc data analysis projects, historical data extractions, cross-platform reconciliations, and KPI aggregation tools for various games published by 5X Games.

> **Note:** This repository was previously purposed for "Game Player Tagging". It has since been repurposed and entirely rewritten to host specific analysis cases.

## Repository Structure

The repository is organized primarily by game or analytical domain:

### 1. `jump_assemble/` (JUMP: Assemble)
Contains deep-dive analytical cases and historical data management for JUMP: Assemble (TC).
- **active_duration_lifecycle_mix**: Analysis of player active duration across different lifecycle stages (D1 vs M2).
- **card_pool_monetization**: Monetization performance and pulling behaviors for different gacha card pools.
- **ranked_match_balance**: Matchmaking balance, win rates, and ranking distributions.
- **Historical Data**: Extractions of user profiles and CBT (Closed Beta Test) splitting logic for historical comparisons. *(Note: Large raw data backups inside `bacakups/` are ignored in Git)*.

### 2. `crayon_shinchan/` (Crayon Shin-chan)
The [Crayon Shin-chan case index](crayon_shinchan/README.md) groups 15 cases into five business themes, following the same game → theme → case structure used elsewhere in this repository:

| Theme | Scope |
| --- | --- |
| `01_kpi_reports` | CBT/OBT KPI, daily and first-week reports |
| `02_monetization_liveops` | Product purchases, spending, activity comparisons and event timetables |
| `03_user_lifecycle_progression` | New-user lifecycle, tutorial dropout and stage progression |
| `04_surveys_retention` | Questionnaire linkage and retention diagnostics |
| `05_data_audits` | Customer-support lists, mount-feed matching and toy-reset compensation |

Tracking documentation is maintained in the separate [shinchan-events-tracking](../shinchan-events-tracking/README.md) project; shared acceptance execution belongs to [thinkingdata-events-validation](../thinkingdata-events-validation/README.md).

### 3. `slam_dunk/` (Slam Dunk)
Contains cross-platform and regional behavioral analysis for Slam Dunk.
- **au_user_revenue_decline_analysis**: Root-cause analysis of revenue decline trends among AU (Australian) users.
- **cross_platform_monthly_user_kpi**: Consolidated monthly KPI reporting across multiple platforms (KR, GL, etc.).
- **cross_platform_new_user_d30_rank_distribution**: D30 ranking achievement distributions for newly registered users across different platforms.

### 4. `kurokos_basketball/` (Kuroko's Basketball)
The [Kuroko case index](kurokos_basketball/README.md) groups nine cases into four themes: `01_kpi_reports`, `02_monetization_liveops`, `03_player_cultivation_resources`, and `04_data_audits`. Each case retains its SQL, scripts, outputs and documentation. The former `new_card` case is now `tc_lg_midorima_acquisition_cultivation_20260819_20260823` under player cultivation and resources.

### 5. `platforms/kpi_overview_v1/`
Generic, cross-game tools for automated KPI aggregation.
- Connects to multiple data engines (TA, ODPS, Hologres) to fetch daily/monthly metrics (MAU, DAU, Revenue, MPU, ARPPU).
- Automatically merges metrics against KPI targets to calculate achievement rates and generates unified `.xlsx` reports.

### 6. `platforms/`
Tools for cross-platform data reconciliation and auditing.
- **wallet_logs_alicoud_vs_ta**: Automated scripts to extract, match, and reconcile wallet (currency/diamond) log discrepancies between AliCloud (ODPS) data warehouses and ThinkingData (TA).

## Usage & Execution

Most Python scripts within these analysis cases rely on the `fivecross-data-client` repository to execute queries against Trino/ODPS. The scripts are designed to dynamically resolve the client path via relative directory traversals (e.g., `../../../fivecross-data-client`).

**Requirements:**
- Python 3.8+
- The `fivecross-data-client` repository cloned at the same parent directory level as this repository.
- Required python packages (usually `pandas`, `openpyxl`).

## Maintenance

- Large CSV or SQLite `.db` output files generated during historical data extractions should remain strictly local. The `.gitignore` excludes `jump_assemble/90_archive/backups/` so local historical exports are not pushed to the remote repository.
