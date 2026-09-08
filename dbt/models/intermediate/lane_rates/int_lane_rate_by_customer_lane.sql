{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.AVG_REVENUE_BY_CUSTOMER_LANE
--
-- Median revenue for a customer on an exact city-to-city lane. Falls back
-- to older data (6 months) when nothing in the last 3 months exists for that
-- customer/lane pair - that is what the IS_RECENT flag is for.
--
-- Part of the lane-rate benchmark layer: ten views over
-- BI.ANALYTICS.ORDERLANEREVENUEMAPPING that supply the fallback cascade in
-- int_predicted_revenue. Queried 1,085 times each per 90 days.
--
-- ROLLING WINDOW - IMPORTANT. This reads the last 6 months relative to
-- CURRENT_DATE. That is deliberate (a live benchmark), but it means predicted
-- revenue for a PAST order changes as the window rolls forward. Historical
-- revenue is therefore not stable for un-invoiced orders, independently of the
-- FX fix in fct_order_revenue. Raise it with the revenue owner.
--
-- POSTGRES PORT NOTES:
--   QUALIFY ROW_NUMBER() OVER (...) = 1  -> already rewritten as a subquery
--                                           with `where rn = 1` (no QUALIFY in
--                                           Postgres)
--   MEDIAN(x)        -> percentile_cont(0.5) within group (order by x)
--   ADD_MONTHS(d,-n) -> d - interval 'n months'
--   GROUP BY ALL     -> explicit column list (done)
--   IFF(a,b,c)       -> case when a then b else c end (done)
-- =============================================================================
with base as (
    select
        customer,
        od_lane,
        currency,
        count(*)                                                        as currency_count,
        percentile_cont(0.5) within group (order by frt + fsc)          as avg_revenue,
        percentile_cont(0.5) within group (order by fsc)                as avg_fsc,
        percentile_cont(0.5) within group (order by frt)                as avg_frt,
        max(delivereddate) >= {{ dbt.dateadd('month', -3, 'current_date') }} as is_recent
    from {{ source('pending', 'orderlanerevenuemapping') }}
    where delivereddate >= {{ dbt.dateadd('month', -6, 'current_date') }}
    group by customer, od_lane, currency
),

filtered as (
    -- keep recent rows; keep stale rows only when that pair has nothing recent
    select b.*
    from base b
    where b.is_recent
       or not exists (
            select 1 from base x
            where x.customer = b.customer
              and x.od_lane  = b.od_lane
              and x.is_recent
       )
),

ranked as (
    select *,
           row_number() over (partition by customer, od_lane
                              order by currency_count desc) as rn
    from filtered
)

select customer, od_lane, currency, avg_revenue, avg_fsc, avg_frt
from ranked
where rn = 1
