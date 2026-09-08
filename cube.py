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
# Every cube either declares `data_source: default` or declares nothing, and
# both land here.
# -----------------------------------------------------------------------------

import os
from cube import config


@config('driver_factory')
def driver_factory(ctx: dict) -> dict:
    # AlloyDB read pool. Reads only - pre-aggregations materialise into
    # Cube Store, never back into Postgres, so a read replica is fine.
    return {
        'type': 'postgres',
        'host': os.environ['PG_HOST'],
        'port': int(os.getenv('PG_PORT', '5432')),
        'database': os.environ['PG_DATABASE'],
        'user': os.environ['PG_USER'],
        'password': os.environ['PG_PASSWORD'],
        'ssl': os.getenv('PG_SSL', 'true').lower() == 'true',
        # Keep the pool small so pre-aggregation builds cannot crowd out the
        # application traffic already using the read pool (~45% mean CPU).
        'maxPoolSize': int(os.getenv('PG_MAX_POOL', '8')),
    }
