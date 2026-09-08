# testing-bi

Cube semantic layer + dbt transformations for Charger Logistics reporting.
Replaces the Snowflake view layer and the Tableau workbooks behind it.

```
PostgreSQL (AlloyDB)  ──►  dbt  ──►  reporting.fct_order_revenue
                                            │
                                            ▼
                                     Cube (this repo)
                                            │
                                            ▼
                              dashboards · API · analytics chat
```

## Layout

| Path | What it is |
|---|---|
`cube.py` | Data source routing. **Read the header — this is what was forcing DuckDB.** |
`model/cubes/` | Cube definitions. Private; BI tools use the views. |
`model/views/` | The four views the dashboards point at. |
`dbt/` | dbt project that builds `fct_order_revenue`. See `dbt/README.md`. |
`agents/` | AI agent config, rules and certified queries (rename `.example` to activate). |

## Fix applied to `cube.py`

The previous `driver_factory` hardcoded `'type': 'duckdb'` and loaded Cube's
tutorial CSVs from S3. **A `driver_factory` in `cube.py` overrides the data
source connections configured in the Cube Cloud UI**, so every query — including
Source SQL tabs — was answered by an in-memory DuckDB. That is why:

- `select * from duckdb_databases()` returned `memory` / `system` / `temp`
- `select current_account()` failed
- `bi.information_schema.views` reported "Catalog BI does not exist"
- `information_schema.columns` returned `orders` / `users` / `line_items` with
  `dau` / `wau` / `mau` — Cube's tutorial model, not your data

`cube.py` now returns **one** connection: PostgreSQL. There is no Snowflake
branch — if a cube ever needs a `data_source:` other than `default`, that is a
bug. Set the variables in `.env.example` in **Cube Cloud → Settings →
Environment variables**.

The tutorial model (`base_orders`, `line_items`, `products`, `users`, plus the
`orders` and `customers` views and `testing.sql`) has been removed.

## The four views

| View | Replaces |
|---|---|
`revenue_by_customer` | Revenue Performance Analysis |
`volume` | Volume Performance Analysis |
`execution` | Revenue Execution Analysis: Customer |
`revenue_by_salesrep` | Revenue Execution Analysis: SalesRep |

Ten duplicated Tableau worksheets collapse into `category` as a dimension plus
a choice of row dimension.

## Three things done differently to Tableau

**Three named revenue measures instead of one parameter.** The workbook had a
single measure whose meaning changed with the `fsc Revenue Toggle` parameter,
which defaults to `fsc Only` — so the dashboards may have been showing
fuel-surcharge revenue alone. Now: `revenue_fsc_only_*`, `revenue_incl_fsc_*`,
`revenue_ex_fsc_*`.

**Ratios computed after aggregation.** `brokerage_gp_pct` divides the sums.
Computing it per order and averaging gives a different, wrong number — the most
common error when porting Tableau calcs.

**Row-level security is enforced, not advisory.** `business_unit` was an open
Tableau filter any viewer could widen. The `access_policy` on `order_revenue`
filters rows by a `business_unit` user attribute and hides cost measures from
the `sales_rep` role.

## Building the model on PostgreSQL only

Cube cannot invent a model. It reads a **catalog** — schemas, tables, columns —
and turns that into cubes. So the order is fixed:

**1. Make the tables exist in Postgres.** Nothing in Cube works before this.
`reporting.fct_order_revenue` is a dbt mart, not a Snowflake view, and it does
not exist until dbt has run:

```bash
cd dbt && dbt deps && dbt seed && dbt build
```

**2. Give Cube the connection.** `PG_*` in Cube Cloud → Settings →
Environment variables. `cube.py` returns Postgres and nothing else, so there is
no way for a cube to reach Snowflake even by accident.

*Blocker:* AlloyDB is on a private IP. Cube Cloud cannot route to it without
Private Service Connect, VPC peering or BYOC. This is the longest-lead item —
open the Cube support ticket before anything else.

**3. Confirm Cube sees Postgres, not the tutorial.** In a workbook's Source SQL
tab:

```sql
select table_schema, table_name from information_schema.tables
where table_schema = 'reporting';
```

Expect `fct_order_revenue`. If you get `orders` / `line_items` / `users`, the
connection is still wrong.

### Two ways to get the cubes written

**a. Use what is in `model/` (recommended).** Already done, already
Postgres-only. `order_revenue.yml` declares `data_source: default` and
`sql_table: reporting.fct_order_revenue`. The four views in `model/views/` are
the dashboard surface. Nothing to generate.

**b. Let Cube generate them, via the dbt integration.** Cube Cloud reads dbt's
`target/manifest.json` and writes one cube per dbt model, then keeps them in
sync. Run `dbt compile` to produce the manifest, then point Cube Cloud →
Settings → dbt integration at this repo's `dbt/` directory.

Worth knowing before you rely on it:

- It generates **dimensions, not measures**. Every number the dashboards
  actually show — the three fsc revenue variants, `brokerage_gp_pct`,
  `margin_status`, exact `count_distinct` on `orderno` — is business logic that
  was inside Tableau. Cube cannot read that from a table shape. It stays
  hand-written.
- dbt `metrics` and `semantic_models` are **ignored**.
- Regenerated files are **overwritten on every re-sync**. Customise with
  `extends:` in a separate file, never by editing a generated one.
- Column types fall back to **column-name heuristics** when dbt has no type.
  This is why `data_type` is declared on every column in
  `dbt/models/marts/_models.yml` — do not remove it.

So: (b) is a fast way to get a skeleton over the other 20-odd dbt models. For
the revenue dashboards, (a) is already further along than (b) can get.

## Validating

```bash
cd dbt && dbt deps
dbt seed
dbt build                                          # builds `reporting` in Postgres
dbt compile --select validate_dashboard_numbers    # expect 4,096 / 7,450,826.44
dbt compile --select validate_against_snowflake    # run the output in Snowsight
```

The last one is the only remaining Snowflake step, and it is a one-off
number-for-number diff pasted into Snowsight — not a connection Cube or dbt
holds.

Then in a Cube workbook (Semantic SQL tab):

```sql
SELECT MEASURE(order_count), MEASURE(revenue_incl_fsc_usd)
FROM revenue_by_customer
WHERE sales_rep = 'NICK BAUMER'
  AND business_unit = 'BO HOME'
  AND delivered_date >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '12 months');
```

## Open decisions

1. Fuel-surcharge default — is `fsc Only` what the dashboard should show?
2. FX rate date when an order has no invoice, pickup or delivery date. The dbt
   port removes the original `CURRENT_DATE` fallback, which made history move
   between refreshes.
3. Asset vs Brokerage — three definitions exist; `category` implements the
   Tableau default, under which a pure-brokerage non-TS-hybrid order counts as
   Asset.
4. Whether to enforce the `>= 2024-01-01` / no-future-dates guard that the
   workbook defines and applies to nothing.

## Not ported yet

`OPD_MILES_VW`, `PREDICTED_REVENUE_BS_VW`, `GLOBALBROKERAGEANALYSIS`,
`ORDEREXTRACHARGES_VW`, `ORDERCARTAPORTELIFECYCLE`. Declared as sources in
`dbt/models/sources/_sources.yml`. `fct_order_revenue` cannot build end-to-end
on Postgres until the first two are done.

Also note `WORKDAYBI.ANALYTICS.BOCDAILYFXRATES` is **not** Postgres data. It is
the only non-Postgres dependency in this chain, and it blocks every currency
conversion on the dashboard.
