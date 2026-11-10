# Traditional Chinese Validation Input

`tracking.xlsx` is the Traditional Chinese source specification, moved from the former `inputs/tracking.xlsx` location without changing its bytes. The TC profile is `config/tc.json`.

The KR working copy in `inputs/kr/tracking.xlsx` was prepared from a snapshot of this document. Its preparation record retains the original location as historical provenance. Changes to the TC document do not automatically update the KR copy or validate either region's existing results.

The current TC input includes historical Sample and review columns. Its native layout differs from the raw template expected by the shared workbook writer. The project-local `debug/tc/build_review_20261110.py` adapts a copy for building with current evidence and retains every original value, moving historical samples/reviews to AC/AD in the delivered workbook. It records original/derived input hashes in the evidence manifest without rewriting query signatures. Use that adapter for a rebuild of this input version; the standard raw-template build must not overwrite its history columns.
