# Current Deliverable

## Priority rule reference — 2026-11-06

- [活动规则与关键时间表](ACTIVITY_RULES.md), [reference JSON](../reference/activity_rules_reference.json), [CSV](../reference/activity_rules.csv), [confirmation](ACTIVITY_RULES_CONFIRMATION.md): 11 current-case entries, no new Excel/PPT or revenue/participant refresh.
- Camping/fishing/blind-box timing now uses confirmed **2026-11-04 natural-date start**, overriding the historical D22–D28 interpretation. End date and exact switches remain unknown; child independent switches remain unconfirmed.
- Historical report/config/SQL/metrics below remain unchanged, not recalculated under this rule. Read the rule reference first; query on demand and update Excel/PPT only when explicitly instructed.


[Case README](../README.md)

- [Current November4 operations presentation](../outputs/小新繁体_消费去向与活动效果_运营汇报版_20261104.pptx): exclusive cutoff **2026-11-04 16:58:14 Asia/Shanghai**; nine pages, including the preserved user cover and new fishing participation/bait/bundle topic. W3 is complete and W4 is explicitly partial. SHA-256 `4f80ce1defdc22b093efb4f357c88f5090b247a13ff5b85854bb00b8214f4f9a`.
- [Preserved October31 operations presentation](../outputs/小新繁体_消费去向与活动效果_运营汇报版_20261031.pptx): eight-page historical user file, unchanged SHA-256 `711a22dc9702b15c55505f21c79d57f8715d1a66809ed4413d3dfa185a4ad959`.
- Current reproducible entry point: `python scripts/current/run.py build`.
- Current private evidence: `verification/latest/validation.json`, `package_validation.json`, `receipts_manifest.json`, derived CSVs and all nine COM renders. Seventeen fresh source/control receipts and exact SQL live under `data/raw/20261104/`.
- `config/refresh.json` and `config/fishing.json` define the current cutoff and child-activity contract. The English README documents execution, filters, denominators, schedule mapping and unresolved timing anomalies.

## Independent archived supplements (not new PPT deliveries)

- [Daily dashboard SQL](../sql/dashboards): latest user-supplied fishing SQL and latest conservative blind-box SQL, copied byte-for-byte with source hashes.
- [Supplement evidence](../evidence/supplements): allowlisted fishing/blind-box aggregates and sanitized receipt metadata; no account-level rows or raw browser receipts.
- [November5 camping / party D1–D2 branch](../evidence/supplements/camp_d1d2): nine aggregate outputs, bounded SQL and original offline analyzer. All output rows reproduced by the isolated validator using seven external hash-checked dependencies; sensitive source inputs remain outside the archive.
- [Supplement validator](../scripts/supplements/validate.py), [manifest](activity_supplements_manifest.json) and [scope inventory](ACTIVITY_SUPPLEMENTS.md): offline verification, provenance, limits and reproducible commands are documented in the complete case README.
- Fishing was already connected to the official November4 report; its standalone dashboard is independent. Blind-box and the November5 D1–D2 analytical branch are **not connected to the official PPT pipeline**. Blind-box participation remains NULL, and magic-wand decrements may include end conversion.
- Supplement validation and full camp offline replay passed. Existing `run.py verify` and `refresh-help` passed with the preserved cover warning. Both approved PPT hashes above, template, active config and core metrics remain unchanged. No new live extraction, rendering, report publication or git commit/push was performed.

## Retained dependencies

The final Nov4 report, the required Oct31 template/report, original supplied schedule workbook, `scripts/current/`, `sql/current/`, active configs, dated Nov4 raw inputs and current verification are retained. Historical branches unrelated to this final report were removed. See [final-only cleanup](final_only_cleanup.json) for deleted paths, reasons and protected-file hashes.
