# Jump TC Opening-Week Revenue Attribution

A reproducible commercial-attribution case for **Jump Assemble TC / 3v3 OBT**, covering **June 24–30, 2026, inclusive (UTC+8)**. It reconstructs cash-bundle allocations from purchase and inventory events, separates consumed paid stars from cash revenue, and preserves the business-approved allocation scenarios.

This case belongs to `01_monetization`: the central question is **which heroes and manga franchises receive the value of opening-week products**, not payment reconciliation or recurring weekly reporting.

## Scope and final deliverables

| Dataset | Unit | Total | Unassigned in final scenario |
|---|---|---:|---:|
| Cash bundles | USD | 191,324.61 | 9,191.54 |
| Paid-star consumption | resource units | 18,979,060.00 | 705,406.00 |

The two rows **must not be added**. Star consumption is not cash revenue and is not limited to stars purchased during this week. Cash star-top-up products are excluded from the bundle table to prevent double-counting when analyzing the consumption side separately. Cash uses positive purchase amounts, not net-of-refund accounting revenue.

Current deliverables:

- [`outputs/final/礼包实付金额_英雄归因.csv`](outputs/final/礼包实付金额_英雄归因.csv)
- [`outputs/final/付费跃之星消耗_英雄归因.csv`](outputs/final/付费跃之星消耗_英雄归因.csv)
- [`outputs/final/首周收入归类.html`](outputs/final/首周收入归类.html)

Both matrices use **product → product ID → total → individual hero columns → unknown**. Hero headers also identify the manga franchise. CSVs are UTF-8 with BOM for Excel compatibility; IDs are text and should not be auto-converted by spreadsheet importers.

## Directory structure

```text
tc_firstweek_revenue_attribution_20260624/
├── README.md
├── .gitignore
├── config/
│   ├── case.json                 # Frozen window, roster, rarity and allocation rules
│   └── queries.json              # Existing client task metadata; links to SQL files
├── sql/                          # 38 successful query definitions
├── scripts/
│   ├── build_case.py             # Raw events → attribution → scenarios → final report
│   ├── fetch_queries.py          # Reuses fivecross-data-client; dry-run by default
│   ├── verify_case.py            # Source SHA-256, CSV counts and matrix integrity
│   └── test_allocations.py        # Unit tests for allocation and scope preservation
├── data/
│   ├── raw/                      # Immutable archived real-query CSVs
│   └── reruns/                   # New query runs, isolated from the frozen snapshot
├── outputs/
│   ├── reference/                # Exact original delivered CSV/HTML versions
│   ├── versions/                 # Rebuilt intermediate numeric scenarios
│   └── final/                    # Current accepted scenario
├── docs/
│   └── attribution_rules.md      # Business-readable Chinese rules and version lineage
└── validation/
    ├── source_manifest.json      # Original paths, sizes, row counts and hashes
    ├── rebuild_results.json      # Actual raw-to-final execution checks
    └── integrity_results.json    # Actual archive verification result
```

## Environment and dependencies

The calculation, archival verification and unit tests use **Python standard library only**. No new environment, database driver, API implementation or package installation is needed.

The validated existing interpreter is:

```text
C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe
```

Online extraction additionally requires the existing **fivecross-data-client** installation, its configured Global ThinkingData login/session and its existing Playwright dependencies. Credentials and session files are deliberately **not copied into this case**. The client handles expired-session recovery; inspect final export state before requesting manual login.

## Rebuild and verify offline

From this case directory, using Git Bash:

```bash
PY='C:/Users/5xgames/Desktop/github/fivecross-data-client/.venv/Scripts/python.exe'
"$PY" scripts/build_case.py --verify-reference
"$PY" scripts/verify_case.py
"$PY" scripts/test_allocations.py
```

The first command rebuilds attribution **from archived event CSVs**, not from the delivered final matrices. It then compares every cell of all six rebuilt output matrices with the applicable original delivered reference. This tests the direct-attribution baseline as well as the later business-allocation changes.

`build_case.py` overwrites generated files under `outputs/versions/`, `outputs/final/`, and its validation JSON. It never changes `data/raw/` or `outputs/reference/`. It is intentionally specific to this frozen seven-day case; changing the period requires reviewing daily extraction batches, target products, event semantics, mappings and roster. Do not treat editing dates alone as a validated new analysis.

## Re-run source queries

Stage all SQL tasks without connecting to ThinkingData:

```bash
"$PY" scripts/fetch_queries.py
```

This validates SQL paths and creates a timestamped `data/reruns/<run>/tasks.json`. **No online queries run without `--execute`.**

To actually re-query the original window:

```bash
"$PY" scripts/fetch_queries.py --execute
# Optional when the client is installed elsewhere:
"$PY" scripts/fetch_queries.py --execute --client-root 'C:/path/to/fivecross-data-client'
```

The wrapper stages a task in the existing client's `tasks/configs/adhoc/`, invokes `main.py fetch --task ...` with the client's own venv, and copies newly exported CSVs into an isolated rerun folder. It checks new file timestamps and each expected export; client exit code alone is insufficient. The result is labelled `exported_unreconciled`, not analytically verified. Reconcile fresh controls before deliberately promoting a new snapshot. Historical blacklist labels, dimensions and corrected source records can change, so a later extraction need not match the frozen references.

No cron job, weekly-report integration, database write or scheduled automation is created.

## Data sources, identities and exclusions

- Engine: ThinkingData / Trino; region: **Global**.
- Event source: `ta.v_event_23`; tag source: `user_result_cluster_23`.
- Unified account: `COALESCE(fc_sdk_common.lcx_id, sdkcommon.lcx_id, "#account_id")` using verified available fields.
- Exclude accounts in **`internal_users` or `is_water`** throughout revenue and behavioral traces. This is account-level attribution, not device-cohort KPI analysis.
- Use role identity for inventory and hero-event matching; purchase payload `PlayerId` supplies role where purchase `rolecommon` is empty.
- Cash: `PURCHASE`; exclude sandbox receipts; use order-date currency exchange from `ta_dim.ta_exchange`; exclude zero/nonpositive amounts from cash allocation.
- Validate exchange coverage and unique `purchaseid`. The archived wallet diagnostic has zero freeamount; do not generalize this to other periods without checking.
- Stars: `resource_change`, **`id=3`**, `gu_type=2`, `nums<0`; **ID 8 is excluded**. `reason='退款'` is a balance recovery, not product consumption: 90,532 units are excluded from this case's consumption table.
- Queries use the fixed `$part_date` window `2026-06-24` through `2026-06-30`. Purchases, consumptions and box-opening observation all stop on June 30. There is **no July follow-up opening window**.
- Product, hero and goods dimensions are preserved with their actual query output. Modern `.open.` channel SKUs can be grouped by validated suffix; legacy `.obt` and direct-charge gift suffixes must not be indiscriminately merged.

Some archived diagnostics intentionally retain excluded-control totals or inspect wallet events without an account filter; those diagnostics are **not inputs to attributed eligible-user revenue**.

## Direct attribution methodology

1. Assign explicit character awakening bundles to the verified character. Opening-week `gift8`, `gift9` and the user-confirmed **`gift19`** are assigned to Gojo; this is a window-specific business rule, not a permanent mapping for reused campaign SKUs.
2. Link `PURCHASE.payload.purchaseid` to `resource_change.sub_reason` for purchase-funded box grants, also requiring matching account.
3. For first-charge claims without order IDs, use the validated exclusive box mapping and a unique preceding account/role purchase: `gift20 → 7084005`, `gift21 → 7084006`, `gift22 → 7084045`. Unmatched cases remain unknown.
4. Match box consumption with `item_use` on account, role, box ID, before/after balances and a maximum two-second timestamp distance. In this archived dataset all 80,440 selected openings match uniquely; the maximum observed event-time difference is 0.025 seconds.
5. Read selected awakening/talent items from `item_use.resourceinfo`. Determine item-to-hero relationships from actual `card_awake` / `card_talent` consumption, not numeric ID patterns. For hero selections absent from the resource array, require a unique same-account/same-role `hero_add` with the box-opening reason, and prevent one acquisition from being reused.
6. Reconstruct inventory episodes until the item balance returns to zero. Preserve all paid and nonpaid gains. **Do not assume FIFO** for indistinguishable paid/free boxes. Mixed sources can be assigned when a completely depleted episode has one proven hero destination; multiple destinations require identifiable paid sources and compatible per-unit value. Otherwise keep the paid value unknown.
7. Allocate equal-value multi-unit selections by observed selected quantities. The whole package value follows the selected character units; generic bundled extras are not independently priced. Fractional allocated star units are therefore possible.
8. Treat unknown as a valid residual: unopened boxes, ambiguous stock origins, missing linkage and generic or unallocated uses. Neither global hero popularity nor ownership is a substitute for a missing event link unless a separate explicit business allocation rule authorizes it.

## Scenario lineage and final allocation rules

### V0 — Directly attributable baseline

- `outputs/versions/cash_direct.csv`
- `outputs/versions/stars_direct.csv`

These preserve uncertain value as unknown and form the frozen denominator for the first cash allocation update.

### V1 — Approved cash-bundle proportional allocation

- `gift23`, `gift7`, `gift6`, `gift24`: distribute by **V0 A-class assigned cash revenue**, normalized within A.
- `gift28`, `gift27`: distribute by **V0 assigned cash revenue across all heroes**.
- Both use the same pre-update baseline, exclude unknown and do not feed one newly allocated row into the next denominator.
- The current cash matrix is `outputs/versions/cash_proportional.csv`, identical numerically to the final cash deliverable.

### V2 — Alternative paid-star equal allocation (preserved, not final)

- Will crystals, both Battle Pass advancement products: equal shares across the 24 table heroes.
- Special launch box and special-publication reset: equal shares across the 8 table A heroes.
- Ordinary launch box and ordinary-publication reset: equal shares across the 15 table R heroes.
- Saved as `outputs/versions/stars_uniform.csv`.

### V3 — Current accepted paid-star allocation

- Will crystals (`item_id:2`), advanced BP (`battlepass:1_2`) and BP advancement (`battlepass:1_1`): proportions from **V1 current cash revenue across all heroes**.
- Special launch box (`goods_id:208012`) and special reset (`goods_id:201010`): proportions from **V1 A-class cash revenue**, normalized within A.
- Ordinary launch box (`goods_id:208013`) and ordinary reset (`goods_id:201012`): keep **V2 equal shares across R**, unchanged cell by cell.
- All other star-consumption rows remain unchanged from V0.
- Current cash-weight denominators: **182,133.07 USD overall; 106,255.24 USD within A**. Unknown is excluded.

These are explicit **business allocation estimates**, not newly observed player-level attribution. Preserve their labels when reporting by hero or manga. Never call proportionally assigned values direct order evidence.

## Roster, rounding and interpretation

The frozen matrix roster contains **24 heroes: 1 S, 8 A and 15 R**. It is the roster of this original attributed table, **not a claim to enumerate every released or owned character in the game**. R is the user's requested label for non-S/non-A; the operating SQL calls this residual class B. The current 24-column scope is intentional for these approved allocations.

`config/case.json` records IDs, display names, franchise labels and rarity. Source rarity categories were checked against the weekly-report hero-ownership SQL. No future character should silently enter an opening-week denominator.

Every matrix cell is displayed to two decimals. Largest-remainder allocation in cents preserves exact row totals, with deterministic column-order tie-breaking. Grand totals sum displayed cells, so a displayed unknown subtotal may differ by one cent from independently rounding an unrounded aggregate. Star fractional units reflect value allocation, not fractional game transactions.

## Verification and audit artifacts

Actual rebuild checks include:

- 44,282 eligible purchase records, unique purchase IDs and complete FX.
- Independent daily purchase and paid-star control totals.
- Daily extraction row-count checks against separate source aggregate queries.
- 80,440 matched selected-box openings and one-to-one hero fallback.
- 85,686 inventory episodes; zero stock discontinuities.
- Every product row and hero/unknown column conserves its displayed total.
- All intermediate and final CSV cells match preserved original delivered references.
- SHA-256 and row-count checks for every preserved raw query export and original result artifact.

The raw directory contains **38 real query exports**; the reference directory contains **9 original delivered files**. Their exact hashes and original paths are in `validation/source_manifest.json`. Offline rebuilding does not re-execute cloud queries; the archive records the real executions already performed for this case.

## Privacy and Git policy

`data/`, `outputs/` and the source-path manifest are case-locally Git-ignored. Raw extracts contain account/role IDs and purchase payloads and are not suitable for public repositories. Scripts, SQL, static rules and documentation can be reviewed independently of raw data. Do not copy `.env`, credentials, browser sessions or authentication state into this case.

No Git commit or push is performed by these scripts. Original client exports and previously delivered files remain untouched; the case preserves hash-verified copies. Git-ignore is not an independent backup: maintain a separate access-controlled backup before any source cleanup.

## Troubleshooting

| Symptom | Action |
|---|---|
| Missing `data/raw/*.csv` | Restore the case snapshot from controlled storage; offline build cannot synthesize it. |
| `reference mismatch` | Inspect the reported product and cell; do not overwrite `outputs/reference/` to hide a mismatch. |
| Source hash mismatch | Determine whether a file changed; retain the original manifest and investigate before promotion. |
| Unknown roster assertion | Review actual event data and source rarity, then explicitly approve a new case scope. |
| Missing FX, duplicate purchase or nonzero stock discontinuity | Stop using that result; investigate source data before allocation. |
| TA login expired | Allow the existing client's automatic recovery; inspect logs and actual exports. |
| Client exits successfully but export is missing | Treat the query as failed; inspect SQL/log feedback rather than accepting the exit code. |
| Fresh historical query differs | Compare labels, dimensions and repaired events; keep the frozen snapshot and new run separate. |
| User asks for another date window | Create a separately reviewed case/configuration; these seven-day scripts and campaign mappings are intentionally frozen. |
