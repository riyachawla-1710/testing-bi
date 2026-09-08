# charger_bi — dbt port of the Snowflake revenue layer

dbt models that reproduce the Snowflake views behind the **Revenue Performance
Analysis** dashboard, so the logic lives in this repo instead of inside
Snowflake and a `.twbx` file.

Read out of Snowflake on 2026-09-08 with `GET_DDL`, then ported.

---

## Lineage

```
PostgreSQL / AlloyDB  (THE source)       FX - not in Postgres yet
  probillsvc.order, ordercharge,           bocdailyfxrates
  orderchargetype, orderuser, salesrep,          │
  orderstatus, probill, taxcodes, taxitems       │
  invoicesvc.invoice, invoicecharge,             │
  invoiceadjustment, invoiceorderrel, currency   │
  customersvc.customer   usersvc.user            │
        │                                        │
        ├──► int_order_users                     │
        ├──► int_charge_adjustments              │
        ├──► int_manual_charges                  ▼
        ├──► int_order_charges          int_fx_rates_daily
        │        │                               │
        │        ▼                               │
        └──► int_order_charges_with_adjustment   │
                     │                           │
BI.ANALYTICS (not ported yet)                    │
  globalbrokerageanalysis ──► int_ts_hybrid_brokerage_pnl
  ordercartaportelifecycle             │         │
  opd_miles ───────────────────┐       │         │
  predicted_revenue_bs ────────┤       │         │
  salesreportaccess ───────────┤       │         │
  labatt_orderrevenue ─────────┤       │         │
  orderextracharges_vw ────────┤       │         │
                               ▼       ▼         ▼
                          fct_order_revenue  ◄───┘
                                   │
                                   ▼
                           Cube semantic model
```

## What is ported

| Model | Replaces | Notes |
|---|---|---|
`int_fx_rates_daily` | `BOCDAILYFXRATES_VW` | Faithful |
`int_order_users` | ORDERUSERS CTE | Faithful |
`int_charge_adjustments` | ADJUSTMENT CTE | Faithful; triple-repeated classification factored out |
`int_manual_charges` | ADJ_BY_INVOICE + RAW_MANUAL + MANUAL CTEs | Faithful |
`int_order_charges` | ORDERCHARGE CTE | Faithful; tax rate factored into its own CTE |
`int_order_charges_with_adjustment` | `ORDERCHARGES_WITHADJUSTMENT_VW` | Faithful, including the Labatt UNION ALL branch |
`int_ts_hybrid_brokerage_pnl` | `TSHYBRIDBROKERAGEPANDL_VW` | Faithful; needs `globalbrokerageanalysis` |
`int_opd_miles` | `OPD_MILES_VW` | Faithful. Reads only CHARGERFLEET |
`int_predicted_revenue` | `PREDICTED_REVENUE_BS_VW` | Faithful |
**10 × `int_lane_rate_by_*`** | the ten `AVG_REVENUE_BY_*` views | Faithful. `QUALIFY` and `MEDIAN` rewritten for Postgres |
`fct_order_revenue` | the Tableau workbook's custom SQL | **One deliberate change — see below** |

## What is NOT ported

Declared as sources in `models/sources/_sources.yml` so the DAG stays honest.
Each is its own piece of work:

| Object | Size | Why it matters |
|---|---|---|
`ORDERLANEREVENUEMAPPING` | table | The corpus all ten lane-rate models compute from. Port this and the layer is fully local. |
`ORDERCHARGES_BS_VW` | 7,532 chars | **Reads `OPSYNC.BILLINGSYSTEM` — not Postgres.** Blocks the cascade's "BILLING SYSTEM" step. |
`GLOBALBROKERAGEANALYSIS` | 17,596 chars | Feeds the brokerage P&L |
`ORDEREXTRACHARGES_VW` | 5,375 chars | Extra-charge detail strings |
`TONUORDERSBI_VW`, `KEURIG_SHUNTINGREVENUE_VW` | small | Cascade inputs |
`ORDERCARTAPORTELIFECYCLE` | table | TS match rates |

## The one deliberate change

`fct_order_revenue` **removes the `CURRENT_DATE` fallback** from the FX rate
date. The original was:

```sql
COALESCE(OC.INVOICEDATE::DATE, O.PICKEDUPDATE, O.DELIVEREDDATE, CURRENT_DATE)
```

Any order with none of those three dates was revalued at *today's* rate on every
refresh, so prior-period revenue changed between runs — and no incremental build
is possible against `CURRENT_DATE`. Those orders now get a NULL rate and NULL
converted revenue, which is visible instead of silently wrong.

To reproduce the old behaviour while reconciling, set
`fx_fallback_to_today = true` at the top of the model.

## Four decisions still needed from the business

1. **Fuel-surcharge default.** The Tableau parameter defaults to `fsc Only`, so
   the revenue dashboards may open showing fuel-surcharge revenue alone.
   `analyses/validate_dashboard_numbers.sql` computes all three variants — the
   one matching $7,450,826.44 tells you what has been on screen.
2. **FX rate date** when an order has no invoice, pickup or delivery date.
3. **Asset vs Brokerage.** Three different definitions exist depending on the
   `Hybrid Brokerage Type` parameter. Under the default, a pure-brokerage order
   that is not TS-hybrid is classified as **Asset**.
4. **Date guard.** `delivereddate <= today AND >= 2024-01-01 AND pickedupdate <=
   tomorrow` is defined in the workbook and applied to no sheet. A warn-level
   test in `_models.yml` surfaces what it would have caught.

## The 2025-01-01 reporting cutoff

`fct_order_revenue` keeps only orders delivered on or after
`reporting_start_date` (set to **2025-01-01** in `dbt_project.yml`).

⚠️ **This removes the 2024 series from the YoY dashboard tiles.** Your
screenshot shows them comparing 2024 / 2025 / 2026. Lower the var if that
comparison is still wanted — it is one line.

The upstream models still cover from 2024-01-01, because that is the original
Snowflake views' own rule. Raising `brokerage_start_date` to match would cut
build time, at the cost of deviating from the source.

Note the lane-rate models use **rolling 3- and 6-month windows relative to
`current_date`** — deliberately, as a live benchmark. But it means predicted
revenue for a *past* order changes as the window moves forward. Historical
revenue is therefore not stable for un-invoiced orders, separately from the FX
issue. Worth raising with the revenue owner.

## PostgreSQL is the source

Every source in `models/sources/_sources.yml` is a **plain Postgres schema** —
`probillsvc`, `invoicesvc`, `customersvc`, `usersvc`, `trailersvc`, `fleetsvc`,
`addresssvc`. There is deliberately **no `database:` key** on any of them, so
they resolve to whatever database your profile connects to.

An earlier version carried `database: CHARGERFLEET` — Snowflake's three-part
naming. That has been removed. `order` and `user` are reserved words in
Postgres too, so those two tables set `quoting: identifier: true`.

Snowflake is reference only. Read view DDL from it, then delete the connection.
Validate the port by comparing **final numbers** (`analyses/`), not by running
dbt against Snowflake — the source definitions no longer resolve there.

### Seeds

`SALESREPORTACCESS` was a 59-row hand-maintained config table in Snowflake.
It is now **`seeds/sales_report_access.csv`** — version-controlled, so changes
arrive as pull requests. Data quality preserved as found and documented in
`seeds/_seeds.yml`: the Snowflake table stored the literal string `'NULL'` in
several id columns, and several `userid` values had trailing spaces.

### What still isn't in Postgres

Grouped under the `pending` source so the DAG is explicit rather than silent.
Override its schema with `--vars '{pending_schema: your_schema}'` as each object
lands.

| Object | Portable? | Notes |
|---|---|---|
`orderlanerevenuemapping` | **Yes** | The corpus behind all ten lane-rate models. **Biggest single win left** — port it and that whole layer is local. |
`globalbrokerageanalysis` | Yes | 17,596 chars. Only the Revenue Execution dashboards need it. |
`orderextracharges_vw` | Yes | 5,375 chars. |
`labatt_orderrevenue` | Yes | Small — may belong as a seed. |
`tonuordersbi_vw`, `keurig_shuntingrevenue_vw`, `ordercartaportelifecycle` | Yes | Small. |
`ordercharges_bs_vw` | **No** | Reads `OPSYNC.BILLINGSYSTEM`. Needs OPSYNC landed, or the cascade step dropped. |
`bocdailyfxrates` | **No** | Workday. Blocks every currency conversion. Land it in Postgres or pull from the Bank of Canada valet API. |

Only the last two need a decision beyond writing SQL.

## Running it

```bash
dbt deps

# 1. Snowflake first — this is how you prove the port
dbt build --target snowflake
dbt compile --select validate_against_snowflake   # then run in Snowsight
dbt compile --select validate_dashboard_numbers   # expect 4,096 / 7,450,826.44

# 2. Postgres once Snowflake ties out
dbt build --target postgres
```

`profiles.example.yml` has both targets. **dbt writes tables, so the Postgres
target needs a writable instance — not the AlloyDB read pool.** The read pool is
for Cube to read from.

## Postgres portability

Every Snowflake-specific construct is either already rewritten or flagged inline
with a `POSTGRES PORT NOTES` block. Handled: `IFF`, `IFNULL`, `ZEROIFNULL`,
`BOOLOR_AGG`, `LISTAGG`, `GROUP BY ALL`, `::` casts, alias reuse in `SELECT` and
`JOIN` (Snowflake allows it, Postgres does not).

Two that still need attention when you switch target:

- `LAST_VALUE(... IGNORE NULLS)` in `int_fx_rates_daily` — Postgres has no
  `IGNORE NULLS`. The gap-fill replacement is written out at the bottom of that
  model.
- `TABLE(GENERATOR(ROWCOUNT => n))` — replaced with `dbt_utils.date_spine`,
  which compiles on both adapters.

## Next step

`fct_order_revenue` is the single table the Cube model sits on. From here:

- one cube on `fct_order_revenue`
- 14 measures (three named fuel-surcharge variants rather than a parameter;
  ratios computed **after** aggregation, not per row)
- four views, four dashboards
- row-level security keyed on `businessunitcode` from `salesreportaccess` —
  enforced, replacing the open Tableau filter
