# Configuration options: https://docs.cube.dev/reference/configuration/config
#
# -----------------------------------------------------------------------------
# ONE DATA SOURCE: PostgreSQL (AlloyDB).
#
# A driver_factory in cube.py OVERRIDES the data source connections configured
# in the Cube Cloud UI. So this file is the single place that decides what Cube
# talks to. It talks to Postgres, and only Postgres.
#
# There is deliberately no Snowflake branch. Snowflake was read once with
# GET_DDL to recover the view logic; that logic now lives in /dbt as SQL. If a
# cube ever needs a `data_source:` other than `default`, that is a bug - it
# means something is being built on a source we are removing.
#
# -----------------------------------------------------------------------------
# SYMPTOM -> CAUSE, so nobody loses an afternoon to this again
#
# "In a workbook, the Source SQL Query data-source list shows grey loading
#  bars forever and the Run button stays greyed out."
#
#     -> The PG_* environment variables are not set on this deployment.
#
# An earlier version of this file read them as os.environ['PG_HOST'], which
# raises a bare KeyError inside driver_factory. Cube cannot resolve the data
# source, so the list never populates and there is no visible error anywhere
# in the workbook UI - it just spins.
#
# This version checks up front and raises a message that names the missing
# variables, which shows up in Deployment -> Logs. Set them in
# Cube Cloud -> Settings -> Environment variables (see .env.example).
# -----------------------------------------------------------------------------

import os
from cube import config

# Variables with no safe default. PG_PORT, PG_SSL and PG_MAX_POOL are optional.
_REQUIRED = ('PG_HOST', 'PG_DATABASE', 'PG_USER', 'PG_PASSWORD')


@config('driver_factory')
def driver_factory(ctx: dict) -> dict:
    missing = [name for name in _REQUIRED if not os.getenv(name)]
    if missing:
        raise RuntimeError(
            'Cube cannot connect to PostgreSQL. Missing environment '
            'variable(s): ' + ', '.join(missing) + '. '
            'Set them in Cube Cloud -> Settings -> Environment variables; '
            '.env.example in this repo lists all of them. '
            'While they are unset, a workbook shows grey loading bars where '
            'the data source list should be and the Run button stays disabled.'
        )

    # AlloyDB. Reads only - pre-aggregations materialise into Cube Store,
    # never back into Postgres, so a read replica is fine.
    return {
        'type': 'postgres',
        'host': os.environ['PG_HOST'],
        'port': int(os.getenv('PG_PORT', '5432')),
        'database': os.environ['PG_DATABASE'],
        'user': os.environ['PG_USER'],
        'password': os.environ['PG_PASSWORD'],
        'ssl': os.getenv('PG_SSL', 'true').lower() == 'true',
        # Keep the pool small so pre-aggregation builds cannot crowd out the
        # application traffic already using the instance (~45% mean CPU).
        'maxPoolSize': int(os.getenv('PG_MAX_POOL', '8')),
    }
