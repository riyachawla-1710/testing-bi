# Configuration options: https://docs.cube.dev/reference/configuration/config
#
# -----------------------------------------------------------------------------
# THERE IS DELIBERATELY NO driver_factory HERE.
#
# A driver_factory in this file OVERRIDES every data source configured in the
# Cube Cloud UI. That is what caused two separate rounds of confusion:
#
#   1. The original version hardcoded {'type': 'duckdb'} with Cube's tutorial
#      CSVs. It always connected - DuckDB is in-memory, no network involved -
#      so a data source always appeared in workbooks and queries always
#      "worked". They just answered from tutorial data, which is why
#      information_schema listed orders / line_items / users and why
#      `BI.ANALYTICS` could not be found.
#
#   2. Replacing it with a Postgres factory meant the UI connection settings
#      were still ignored, so Settings -> Data Sources became a form that
#      looked authoritative and changed nothing.
#
# Connections now live in Cube Cloud -> Settings -> Data Sources, where they
# can be seen, edited and tested with a button. One data source, `default`.
#
# Add a driver_factory back only for something the UI genuinely cannot express
# - per-tenant connections, a custom pool size - and say so in a comment when
# you do. Environment variables alone (CUBEJS_DB_HOST and friends) do not need
# one. A reference implementation is in git history at 85dae97.
#
# -----------------------------------------------------------------------------
# IF THE DATA SOURCE LIST NEVER LOADS AND `Run` STAYS GREYED OUT
#
# Cube TESTS each connection while enumerating the list, so a data source it
# cannot reach is dropped rather than shown as broken - the list just spins
# until the TCP connect times out. Check
# Overview -> Resources & Logs -> Cube API:
#
#   "connect ETIMEDOUT 172.23.210.10:5432"
#       The host is a private RFC1918 address. Cube Cloud has no route to it.
#       This is a NETWORK problem and no Cube setting fixes it. See the
#       Troubleshooting section of README.md.
#
#   "password authentication failed" / "database does not exist"
#       Ordinary credential problem - fix it in Settings -> Data Sources.
# -----------------------------------------------------------------------------
