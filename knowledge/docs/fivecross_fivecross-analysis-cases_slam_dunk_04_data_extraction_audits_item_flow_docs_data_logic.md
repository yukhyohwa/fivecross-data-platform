# Data Logic

## Version routing

| Version | Event table | `a_rst` format | Role extraction |
|---|---|---|---|
| TW | `ta.v_event_20` | `array(varchar)` containing JSON strings | `SPLIT(a_usr, '@')[2]` |
| GL | `ta.v_event_21` | `array(row(before, obj, diff, after))` | `SPLIT(a_usr, '@')[2]` |
| KR | `ta.v_event_22` | JSON-string resource entries | `SPLIT(a_usr, '@')[2]` |

## Item filter

The SQL filters resource entries where the object namespace is `item`, then keeps item IDs `930000002` and `930000003` with positive `diff`.

## Event name

`"$part_event"` is selected as `发生事件名`. This identifies the event that carried the resource change transaction.

## Date and partition filter

The query uses the fixed partition range `"$part_date" BETWEEN '2026-07-30' AND '2026-08-20'` (inclusive).
