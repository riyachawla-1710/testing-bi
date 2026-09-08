# Configuration options: https://docs.cube.dev/reference/configuration/config
#
# -----------------------------------------------------------------------------
# WHY THIS FILE CHANGED
#
# The previous version hardcoded `'type': 'duckdb'` and loaded Cube's tutorial
# CSVs from S3. A driver_factory in cube.py OVERRIDES the data source
# connections configured in the Cube Cloud UI - so every query, including
# Source SQL tabs, was answered by an in-memory DuckDB with the tutorial data
# attached. That is why `select * from duckdb_databases()` returned
# memory/system/temp, and why `current_account()` and BI.ANALYTICS were not
# found.
#
# This version routes by data_source instead:
#     default    -> PostgreSQL (AlloyDB read pool)   <- build cubes on this
#     snowflake  -> Snowflake                        <- reference only, temporary
#
# A cube picks its source with `data_source: snowflake`; anything without a
# data_source uses `default`.
# -----------------------------------------------------------------------------

import os
from cube import config


@config('driver_factory')
def driver_factory(ctx: dict) -> dict:
    data_source = ctx.get('dataSource', 'default')

    if data_source == 'snowflake':
        # Reference only, for diffing ported models against the original views.
        # Delete this branch once the port is validated - otherwise someone
        # will build a cube on it and recreate the dependency we are removing.
        return {
            'type': 'snowflake',
            'account': os.environ['SNOWFLAKE_ACCOUNT'],
            'username': os.environ['SNOWFLAKE_USER'],
            'password': os.environ['SNOWFLAKE_PASSWORD'],
            'database': os.getenv('SNOWFLAKE_DATABASE', 'BI'),
            'warehouse': os.environ['SNOWFLAKE_WAREHOUSE'],
            'role': os.getenv('SNOWFLAKE_ROLE', 'DATA_ENGINEER'),
        }

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
