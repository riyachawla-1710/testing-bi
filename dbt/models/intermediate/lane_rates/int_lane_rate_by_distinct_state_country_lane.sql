{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.AVG_REVENUE_BY_DISTINCT_STATE_COUNTRY_LANE
--
-- Mean rate per mile keyed on the distinct (first-to-last) state and country
-- lane plus whole-order direction. No dedupe - every combination is kept.
--
-- Part of the lane-rate benchmark layer: ten views over
-- BI.ANALYTICS.ORDERLANEREVENUEMAPPING that supply the fallback cascade in
-- int_predicted_revenue. Queried 1,085 times each per 90 days.
--
-- ROLLING WINDOW - IMPORTANT. This reads the last 3 months relative to
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
select
    od_statelane_distinct,
    od_countrylane_distinct,
    order_direction,
    currency,
    distancetype,
    avg((frt + fsc) / total_distance) as avg_rpm,
    avg(frt / total_distance)         as avg_rpm_frt,
    avg(fsc / total_distance)         as avg_rpm_fsc,
    avg(frt + fsc)                    as avg_revenue,
    avg(frt)                          as avg_frt,
    avg(fsc)                          as avg_fsc
from {{ source('bi_analytics', 'orderlanerevenuemapping') }}
where delivereddate >= {{ dbt.dateadd('month', -3, 'current_date') }}
group by od_statelane_distinct, od_countrylane_distinct, order_direction,
         currency, distancetype
