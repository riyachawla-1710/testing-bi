-- =============================================================================
-- Reconciliation. Run this on the SNOWFLAKE target, after `dbt build`.
-- Every model here replaces a live Snowflake view; this proves they agree.
--
--   dbt compile --select validate_against_snowflake
--   then paste the compiled SQL into Snowsight.
--
-- Anything other than zero in the diff columns is a defect. Fix before
-- switching the target to Postgres.
-- =============================================================================

-- 1. ORDERCHARGES_WITHADJUSTMENT_VW -----------------------------------------
with ported as (
    select count(*) as rows_,
           sum(totalchargesnotax) as notax,
           sum(fsc) as fsc,
           count(distinct orderguid) as orders
    from {{ ref('int_order_charges_with_adjustment') }}
),
original as (
    select count(*) as rows_,
           sum(totalchargesnotax) as notax,
           sum(fsc) as fsc,
           count(distinct orderguid) as orders
    from BI.ANALYTICS.ORDERCHARGES_WITHADJUSTMENT_VW
)
select 'ORDERCHARGES_WITHADJUSTMENT_VW' as object,
       p.rows_ - o.rows_    as row_diff,
       p.notax - o.notax    as notax_diff,
       p.fsc   - o.fsc      as fsc_diff,
       p.orders - o.orders  as order_diff
from ported p cross join original o

union all

-- 2. BOCDAILYFXRATES_VW ------------------------------------------------------
select 'BOCDAILYFXRATES_VW',
       (select count(*) from {{ ref('int_fx_rates_daily') }})
         - (select count(*) from BI.ANALYTICS.BOCDAILYFXRATES_VW),
       (select round(sum(cadrate), 4) from {{ ref('int_fx_rates_daily') }})
         - (select round(sum(cadrate), 4) from BI.ANALYTICS.BOCDAILYFXRATES_VW),
       null, null

union all

-- 3. TSHYBRIDBROKERAGEPANDL_VW ----------------------------------------------
select 'TSHYBRIDBROKERAGEPANDL_VW',
       (select count(*) from {{ ref('int_ts_hybrid_brokerage_pnl') }})
         - (select count(*) from BI.ANALYTICS.TSHYBRIDBROKERAGEPANDL_VW),
       (select round(sum(brokeragegpcad), 2) from {{ ref('int_ts_hybrid_brokerage_pnl') }})
         - (select round(sum(brokeragegpcad), 2) from BI.ANALYTICS.TSHYBRIDBROKERAGEPANDL_VW),
       null, null
