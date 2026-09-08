# charger_bi — the revenue layer, in dbt on PostgreSQL

dbt models that reproduce the Snowflake views behind the **Revenue Performance
Analysis** Tableau workbook, reading **only from PostgreSQL**.

Snowflake was read **once**, with `GET_DDL` on 2026-09-08, to recover the view
logic. That logic is SQL in this project now and the connection is not needed
again.

## Scope: what this does and does not cover

Three capabilities were deliberately cut so the project has **zero external
dependencies** and can be built and shipped today:

| Cut | What it cost | To get it back you need |
|---|---|---|
**Currency conversion** | Money is in each order's own currency. `order_currency` is a mandatory slice; nothing is comparable across currencies. | `BOCDAILYFXRATES` in Postgres (it lives in Workday), or the Bank of Canada valet API |
**Predicted revenue** | Revenue exists only for INVOICED orders. Non-invoiced orders keep their row and dates but have NULL revenue. | `ORDERLANEREVENUEMAPPING` and `ORDERCHARGES_BS_VW` (the latter reads OPSYNC) |
**Brokerage P&L** | No brokerage revenue, GP, GP%, carrier/transfer/trailer/TS cost, margin RAG tiles, or Asset-vs-Brokerage split. | `GLOBALBROKERAGEANALYSIS` and `ORDERCARTAPORTELIFECYCLE`, plus FX |

The deleted models and the full analysis of those five source objects are in
git history at commit **`1792a28`**. Nothing is lost, only parked.

Two knock-on effects worth knowing before anyone asks:

- The **Labatt shuttle rule** in `int_order_charges_with_adjustment` flips some
  INVOICED orders back to NOT INVOICED so they would pick up modelled revenue
  instead. With no model behind it, those orders now show NULL revenue rather
  than an estimate. Small population, real behaviour change.
- **Business unit is gone entirely.** `businessunitcode` came only from the
  `SALESREPORTACCESS` seed, which is removed. Dashboards slice by customer,
  sales rep, lane, geography and date.

## Lineage

```
probillsvc / invoicesvc / customersvc / usersvc /
trailersvc / fleetsvc / tripsvc / addresssvc          (8 Postgres schemas,
        |                                              23 tables)
        v
int_order_users        int_charge_adjustments   int_manual_charges
int_order_extra_charges  int_tonu_orders        int_opd_miles
        |                        |                     |
        +--> int_order_charges <-+                     |
        |            |                                 |
        |            v                                 |
        |    int_labatt_order_revenue <----------------+
        |            |
        v            v
   int_order_charges_with_adjustment
                     |
                     v
             fct_order_revenue          <- the only table Cube reads
```

`int_keurig_shunting_revenue` builds standalone and is not in this lineage —
it fed predicted revenue. See the note above its entry in
`models/intermediate/_models.yml`.

## What is ported

| Model | Replaces | Notes |
|---|---|---|
`int_order_users` | ORDERUSERS CTE | Faithful |
`int_charge_adjustments` | ADJUSTMENT CTE | Faithful; triple-repeated classification factored out |
`int_manual_charges` | ADJ_BY_INVOICE + RAW_MANUAL + MANUAL CTEs | Faithful |
`int_order_charges` | ORDERCHARGE CTE | Faithful; tax rate factored into its own CTE |
`int_order_extra_charges` | `ORDEREXTRACHARGES_VW` | Faithful. `OBJECT_AGG` -> `jsonb_object_agg` |
`int_tonu_orders` | `TONUORDERSBI_VW` | Faithful |
`int_labatt_order_revenue` | `LABATT_ORDERREVENUE_VW` | Faithful. Allocation is by **sqrt(distance)** |
`int_order_charges_with_adjustment` | `ORDERCHARGES_WITHADJUSTMENT_VW` | Faithful, including the Labatt UNION ALL branch |
`int_opd_miles` | `OPD_MILES_VW` | Faithful |
`int_keurig_shunting_revenue` | `KEURIG_SHUNTINGREVENUE_VW` | Faithful. Standalone — nothing consumes it |
`fct_order_revenue` | the Tableau workbook's custom SQL | Rewritten for native currency, invoiced-only |

## PostgreSQL is the only source

Every source in `models/sources/_sources.yml` is a **plain Postgres schema** —
`probillsvc`, `invoicesvc`, `customersvc`, `usersvc`, `trailersvc`, `fleetsvc`,
`tripsvc`, `addresssvc`. There is deliberately **no `database:` key** on any of
them, so they resolve to whatever database your profile connects to.

`order` and `user` are reserved words in Postgres, so those two tables set
`quoting: identifier: true`.

There is no `pending` group and no `fx` group any more. Every object that was
in them was read by exactly one model, and all of those models are deleted.

> **Unverified assumption.** These 23 table definitions were written from
> Snowflake DDL, not from Postgres introspection. Table and column names are
> therefore *assumed*. Run `analyses/`-adjacent
> `information_schema.columns` check against the real database before trusting
> a build — a wrong name here shows up as 24 models failing at once.

## Running it

One target: Postgres. `dbt` cannot be pointed at Snowflake — the source
definitions are Postgres-shaped and will not resolve there.

```bash
dbt deps
dbt build            # 11 models. No seeds, no pending sources, no blockers.

dbt compile --select validate_dashboard_numbers
```

**dbt writes tables, so it needs a writable instance — not the AlloyDB read
pool.** The read pool is what Cube reads from. Two different connections on
purpose; see `profiles.example.yml`.

### On validating against Tableau

The old target of **4,096 orders / $7,450,826.44** cannot be reproduced and
should not be chased. It came from a USD-converted, predicted-revenue-inclusive,
business-unit-filtered query — all three of which are gone. Treat
`analyses/validate_dashboard_numbers.sql` as a **regression baseline**: run it
once, write the answers down, and use it to catch drift from here on.

## Postgres portability

Every Snowflake-specific construct is either already rewritten or flagged
inline with a `POSTGRES PORT NOTES` block. Handled: `IFF`, `IFNULL`,
`ZEROIFNULL`, `BOOLOR_AGG`, `LISTAGG`, `OBJECT_AGG`, `QUALIFY`, `MEDIAN`,
`GROUP BY ALL`, `::` casts, and alias reuse in `SELECT` and `JOIN` (Snowflake
allows it, Postgres does not).

Three behavioural differences that bite silently rather than erroring:

- **`LAST_VALUE` / `FIRST_VALUE` default window frame.** Snowflake defaults to
  the whole partition, Postgres to the current row. Left unhandled this makes
  delivery city and state equal the pickup values.
- **`LISTAGG(DISTINCT x) WITHIN GROUP (ORDER BY y)`.** Postgres cannot DISTINCT
  and ORDER BY different expressions in one aggregate.
- **`GREATEST` with NULLs.** Snowflake returns NULL; Postgres ignores the NULLs.

## Four decisions still needed from the business

1. **Which fsc variant is the headline number?** The Tableau parameter defaulted
   to `fsc Only`, so the dashboards may have been showing fuel-surcharge revenue
   alone. Three named measures now exist; someone has to pick.
2. **Enforce the unused date guard?** The workbook defines a "Del Date less than
   today" guard and applies it to no sheet. A warn-level test surfaces what it
   would have caught.
3. **Is the 2025-01-01 cutoff right?** The YoY tiles compare 2024/2025/2026;
   with this cutoff the 2024 series is empty. See `reporting_start_date`.
4. **Do stranded manual charges matter?** Query 3 in the validation analysis
   counts orders whose manual charges were billed in a foreign currency and are
   therefore dropped. If that total is material, FX is not optional after all.
