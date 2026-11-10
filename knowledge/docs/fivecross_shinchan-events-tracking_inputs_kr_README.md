# Prepared KR Validation Input

`tracking.xlsx` is the KR working copy prepared from the [TC source specification](../tc/tracking.xlsx). The original file was relocated from `inputs/tracking.xlsx` to `inputs/tc/tracking.xlsx` without changing its bytes.

The source includes historical Traditional Chinese samples and review results. This copy retains events, properties, descriptions, original developer feedback and acceptance notes. It removes the previous samples and review conclusions, reduces type labels containing SQL annotations to their base documented type, and clears old pass statuses. Existing "not currently required" markers are preserved. Apart from the event-sheet column projection and its associated layout, the other native workbook content is unchanged.

This copy does not establish that KR reports any field. Actual KR types, statuses and non-empty samples are queried from `ta.v_event_24`. Source and prepared-file hashes, the column mapping and verification records are retained locally in `.cache/kr/source/normalization_receipt.json`.

This is a snapshot of the shared specification at preparation time. After updating the shared document, regenerate or maintain this KR copy before running another audit; an older prepared copy must not be treated as the latest specification.
