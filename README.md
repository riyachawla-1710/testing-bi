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

| View | Replaces | Currency slice required? |
|---|---|---|
`revenue_by_customer` | Revenue Performance Analysis | **Yes** |
`volume` | Volume Performance Analysis | No — no money measures |
`execution` | Revenue Execution Analysis: Customer | **Yes** (scope changed, see below) |
`revenue_by_salesrep` | Revenue Execution Analysis: SalesRep | **Yes** |

Ten duplicated Tableau worksheets collapse into a choice of row dimension.

`execution` no longer carries brokerage margin — see the note at the top of
`model/views/execution.yml`.

## Scope: three capabilities deliberately cut

So the stack has **zero external dependencies** and can ship today:

| Cut | What it costs you |
|---|---|
**Currency conversion** | Money is in each order's own currency. `currency` is a **mandatory slice** on every revenue measure — an ungrouped total adds CAD to USD to MXN. |
**Predicted revenue** | Revenue exists only for INVOICED orders. Non-invoiced orders keep their row and dates, so volume and lane analysis stay complete, but revenue is NULL. |
**Brokerage P&L** | No brokerage revenue, GP, GP%, carrier/transfer/trailer/TS cost, margin RAG tiles, or Asset-vs-Brokerage split. |

Business unit is gone with them — it came only from the removed
`sales_report_access` seed.

All of it is recoverable; `dbt/README.md` lists exactly which source objects
each one needs, and the deleted models are in git history at `1792a28`.

## Two things still done differently to Tableau

**Three named revenue measures instead of one parameter.** The workbook had a
single measure whose meaning changed with the `fsc Revenue Toggle` parameter,
which defaults to `fsc Only` — so the dashboards may have been showing
fuel-surcharge revenue alone. Now: `revenue_fsc_only`, `revenue_incl_fsc`,
`revenue_ex_fsc`.

**Ratios computed after aggregation.** `revenue_per_invoiced_order` and
`fsc_share_of_revenue` divide the sums. Computing per order and averaging gives
a different, wrong number — the most common error when porting Tableau calcs.

## Troubleshooting

Logs are at **Overview → Resources & Logs → Cube API**. There is no top-level
Logs section.

| Symptom | Cause | Fix |
|---|---|---|
Data-source list shows grey loading bars forever; **Run** greyed out; logs say `Missing environment variable(s): PG_HOST, ...` | `PG_*` not set on the deployment | Set them in **Settings → Environment variables** |
Same spinner, but logs say `ConnectionError: ... connect ETIMEDOUT 172.x.x.x:5432` | **Network, not config.** The variables are set and Cube is dialling, but the host is a private RFC1918 address Cube Cloud has no route to. `ETIMEDOUT` = packets go nowhere; a firewall reject gives `ECONNREFUSED`, bad DNS gives `ENOTFOUND`. | The database must become reachable — see below |
Errors naming a data source other than `default` | A leftover data source in the UI | Delete it in **Settings → Data Sources** |
`information_schema` returns `orders` / `line_items` / `users` | An old `cube.py` hardcoded a DuckDB driver, overriding UI connections | Fixed — check the deployment is on current `master` |
Cube compile error `accessPolicy[0].role is not allowed` | Cube requires `group:` / `groups:`, not `role:` | Fixed; the policy block is commented out |

The list spins rather than erroring because the TCP connect has to time out
first while the UI polls `/v1/data-sources`.

### Reaching a private-IP database from Cube Cloud

Cube's Postgres driver has **no SSH tunnel or bastion option**, so the database
itself has to be reachable. Three ways, cheapest first:

1. **AlloyDB inbound public IP + authorized networks.** One `gcloud` command,
   SSL enforced, allowlist restricted to Cube Cloud's egress addresses — which
   you have to ask Cube support for, as they aren't published. Confirm whether
   this can go on a read pool; if it's primary-only that is fine, because
   pre-aggregations mean Postgres sees roughly one query per refresh.
2. **Enterprise plan + Dedicated Infrastructure add-on** → Private Service
   Connect or VPC peering. Correct long-term, but a commercial change.
3. **Self-host Cube Core inside the VPC.** Reaches the private IP directly, but
   gives up Cube Cloud's workbooks and dashboards — which is the reason for
   choosing Cube here in the first place.

Cube reads exactly **one table**, `reporting.fct_order_revenue`. That is the
whole surface that needs to be reachable — not AlloyDB, not 23 tables.

## Building the model on PostgreSQL only

Cube cannot invent a model. It reads a **catalog** — schemas, tables, columns —
and turns that into cubes. So the order is fixed:

**1. Make the tables exist in Postgres.** Nothing in Cube works before this.
`reporting.fct_order_revenue` is a dbt mart, not a Snowflake view, and it does
not exist until dbt has run:

```bash
cd dbt && dbt deps && dbt build
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
  actually show — the three fsc revenue variants, `revenue_per_invoiced_order`,
  `fsc_share_of_revenue`, exact `count_distinct` on `orderno` — is business
  logic that was inside Tableau. Cube cannot read that from a table shape. It
  stays hand-written.
- dbt `metrics` and `semantic_models` are **ignored**.
- Regenerated files are **overwritten on every re-sync**. Customise with
  `extends:` in a separate file, never by editing a generated one.
- Column types fall back to **column-name heuristics** when dbt has no type.
  This is why `data_type` is declared on every column in
  `dbt/models/marts/_models.yml` — do not remove it.

So: (b) is a fast way to get a skeleton over the other ten dbt models. For
the revenue dashboards, (a) is already further along than (b) can get.

## Validating

```bash
cd dbt && dbt deps
dbt build                                          # 11 models, no blockers
dbt compile --select validate_dashboard_numbers
```

The old Tableau target of 4,096 orders / $7,450,826.44 **cannot be reproduced**
and should not be chased — it assumed USD conversion, predicted revenue and a
business-unit filter, none of which exist here. Use the analysis as a
regression baseline instead.

Then in a Cube workbook (Semantic SQL tab) — note the `currency` in the GROUP BY:

```sql
SELECT currency,
       MEASURE(order_count),
       MEASURE(invoiced_order_count),
       MEASURE(revenue_incl_fsc)
FROM revenue_by_customer
WHERE sales_rep = 'NICK BAUMER'
  AND delivered_date >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '12 months')
GROUP BY currency;
```

## Open decisions

1. **Fuel-surcharge default** — is `fsc Only` what the dashboard should show?
2. **The unused date guard** — the workbook defines a `>= 2024-01-01` /
   no-future-dates guard and applies it to no sheet. A warn-level dbt test
   surfaces what it would have caught.
3. **The 2025-01-01 cutoff** — the YoY tiles compare 2024/2025/2026, so with
   this cutoff the 2024 series is empty.
4. **Stranded manual charges** — some orders carry manual charges in a currency
   other than their own, and those amounts are dropped because there is no rate
   to convert them. `currency_mismatch_order_count` counts them. If the total is
   material, FX is not optional after all.

## Recoverable, not ported

Five PostgreSQL-absent objects, each the sole dependency of a deleted model:

| Object | Was needed by | Notes |
|---|---|---|
`ORDERLANEREVENUEMAPPING` | the ten lane-rate models | Derived from Postgres data. Cheapest of the five to port. |
`ORDERCHARGES_BS_VW` | `int_predicted_revenue` | Reads `OPSYNC.BILLINGSYSTEM`. Needs OPSYNC landed. |
`BOCDAILYFXRATES` | `int_fx_rates_daily` | Workday. Or pull the Bank of Canada valet API. |
`GLOBALBROKERAGEANALYSIS` | `int_ts_hybrid_brokerage_pnl` | Not a view port — needs a new contract/trip costing tier (11 tables). |
`ORDERCARTAPORTELIFECYCLE` | `int_ts_hybrid_brokerage_pnl` | Not a view port — the view is self-referential and emits different columns than the table. |

Full analysis and the deleted model SQL: git history at commit `1792a28`.
