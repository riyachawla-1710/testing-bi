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
# 1. "The Source SQL Query data-source list shows grey loading bars forever
#     and the Run button stays greyed out."
#
#    Look in Overview -> Resources & Logs -> Cube API. Two possibilities:
#
#    a) "Missing environment variable(s): PG_HOST, ..." - the PG_* variables
#       are not set. Set them in Settings -> Environment variables.
#
#    b) "ConnectionError: ... connect ETIMEDOUT <private ip>:5432" - the
#       variables ARE set and Cube is reaching the network, but the host is a
#       private RFC1918 address (10.x, 172.16-31.x, 192.168.x) that Cube Cloud
#       has no route to. ETIMEDOUT means the packets go nowhere - a firewall
#       rejecting would give ECONNREFUSED, bad DNS would give ENOTFOUND.
#       This is a NETWORK problem, not a config problem. The database has to
#       become reachable: an AlloyDB inbound public IP with Cube Cloud's
#       egress addresses in the authorized-networks allowlist, or Enterprise
#       plan + Dedicated Infrastructure for Private Service Connect.
#
#    The list spins rather than erroring because the TCP connect has to time
#    out first, and the UI polls /v1/data-sources while that happens.
#
# 2. Errors naming a data source other than `default` (e.g. `snowflake_testing`)
#    mean a leftover data source is still configured in the Cube Cloud UI.
#    driver_factory below refuses to serve it. Delete it in
#    Settings -> Data Sources; it only doubles the noise in the logs.
# -----------------------------------------------------------------------------

import os
from cube import config

# Variables with no safe default. PG_PORT, PG_SSL and PG_MAX_POOL are optional.
_REQUIRED = ('PG_HOST', 'PG_DATABASE', 'PG_USER', 'PG_PASSWORD')


@config('driver_factory')
def driver_factory(ctx: dict) -> dict:
    data_source = ctx.get('dataSource', 'default')

    # Exactly one data source is expected. Returning the Postgres config for
    # any name would hand these credentials to whatever leftover data source
    # someone left in the UI, and its failures would look like ours.
    if data_source != 'default':
        raise RuntimeError(
            f"Unexpected data source '{data_source}'. This project has one "
            "data source, `default`, on PostgreSQL. Delete the extra data "
            "source in Cube Cloud -> Settings -> Data Sources, or add a "
            "branch here if it is genuinely needed."
        )

    missing = [name for name in _REQUIRED if not os.getenv(name)]
    if missing:
        raise RuntimeError(
            'Cube cannot connect to PostgreSQL. Missing environment '
            'variable(s): ' + ', '.join(missing) + '. '
            'Set them in Cube Cloud -> Settings -> Environment variables; '
            '.env.example in this repo lists all of them.'
        )

    # AlloyDB. Reads only - pre-aggregations materialise into Cube Store,
    # never back into Postgres, so a read replica is fine.
    #
    # NOTE: PG_HOST must be an address Cube Cloud can actually route to. A
    # private IP times out - see (1b) in the header.
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
