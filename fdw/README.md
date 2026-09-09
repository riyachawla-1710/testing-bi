# Access request: what the reporting layer needs

## Background, in three sentences

Each microservice owns its own AlloyDB database — `alloydb_probillsvc_dev_01`,
`alloydb_invoicesvc_dev_01`, and so on. PostgreSQL cannot join across
databases, so the reporting SQL (which spans eight of them) cannot run against
any single connection. `postgres_fdw` is already installed on the instance and
makes those joins expressible from one database, which is all dbt and Cube need.

This is the job Snowflake currently does. Doing it in Postgres is what lets it
be retired.

## The ask

**1. One new database:** `alloydb_bi_dev_01`

Analytics only. No service writes to it. It holds the foreign-table definitions
plus the tables dbt builds.

**2. One new role:** `bi_dbt`

| Needs | Where | Why |
|---|---|---|
`CONNECT`, `CREATE` | `alloydb_bi_dev_01` | dbt materialises 11 tables here |
`OWNER` of schemas `reporting`, `intermediate`, `marts` | `alloydb_bi_dev_01` | where dbt writes |
`USAGE` + `SELECT` on the eight foreign schemas | `alloydb_bi_dev_01` | reads the service data |

`bi_dbt` needs **no privileges at all** on the service databases. It only ever
touches the analytics database.

**3. One read-only role on the eight service databases**

Used by the foreign servers, not by a person. `CONNECT` plus `SELECT` on the 23
tables in `public` listed in `01_setup_fdw.sql`. Its credentials go into the
`USER MAPPING` statements and are never stored in this repo.

**4. Run `01_setup_fdw.sql`** as `alloydbsuperuser`, connected to
`alloydb_bi_dev_01`, after replacing the two `REPLACE_WITH_*` values.

## Scope — deliberately small

**23 tables out of roughly 1,000** across the eight databases. Every one was
confirmed present in the live catalog on 2026-09-09, and every column the models
reference was verified against it (411 references, zero mismatches).

| Service database | Tables | Columns |
|---|---|---|
`alloydb_probillsvc_dev_01` | 11 | 289 |
`alloydb_invoicesvc_dev_01` | 5 | 108 |
`alloydb_customersvc_dev_01` | 1 | 90 |
`alloydb_usersvc_dev_01` | 1 | 43 |
`alloydb_fleetsvc_dev_01` | 2 | 33 |
`alloydb_trailersvc_dev_01` | 1 | 15 |
`alloydb_tripsvc_dev_01` | 1 | 12 |
`alloydb_addresssvc_dev_01` | 1 | 9 |

Nothing is written back to any service database. `IMPORT FOREIGN SCHEMA
... LIMIT TO` means only the named tables are exposed — not the whole schema.

## Performance, and why it is not a concern here

FDW joins across eight databases are slow. That would matter if dashboards
queried them directly. They don't: dbt runs the federated SQL **on a schedule**
and materialises 11 local tables, and Cube then serves dashboards from
pre-aggregations built off `reporting.fct_order_revenue`. The expensive query
runs about once an hour; a dashboard view costs nothing on the service
databases.

`use_remote_estimate 'true'` is set on every server so the planner pushes work
down rather than pulling whole tables across.

## Why not just grant cross-database access another way

There isn't one. PostgreSQL has no cross-database query capability besides
`postgres_fdw` and `dblink`, and Cube rejects joins spanning data sources
outright — *"A query that joins two cubes on different data sources is
rejected"*. Federation has to happen in the database.

## After it runs

Nothing in `dbt/models/sources/_sources.yml` changes. It already declares
`probillsvc`, `invoicesvc`, `customersvc`, `usersvc`, `trailersvc`, `fleetsvc`,
`tripsvc` and `addresssvc` as plain schemas — which is exactly what the foreign
schemas above are named. Point the dbt profile at `alloydb_bi_dev_01` and
`dbt build` runs.
