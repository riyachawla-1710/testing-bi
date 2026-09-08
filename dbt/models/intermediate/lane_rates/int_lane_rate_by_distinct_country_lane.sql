{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.AVG_REVENUE_BY_DISTINCT_COUNTRY_LANE
--
-- Median rate per mile on the distinct country lane. Collapses LONG and
-- VERY LONG into one band.
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
    od_countrylane_distinct,
    order_direction,
    currency,
    case when distancetype in ('VERY LONG', 'LONG') then 'LONG'
         else distancetype end                                               as distancetype,
    percentile_cont(0.5) within group (order by (frt + fsc) / total_distance) as avg_rpm,
    percentile_cont(0.5) within group (order by frt / total_distance)         as avg_rpm_frt,
    percentile_cont(0.5) within group (order by fsc / total_distance)         as avg_rpm_fsc,
    percentile_cont(0.5) within group (order by frt + fsc)                    as avg_revenue,
    percentile_cont(0.5) within group (order by frt)                          as avg_frt,
    percentile_cont(0.5) within group (order by fsc)                          as avg_fsc
from {{ source('bi_analytics', 'orderlanerevenuemapping') }}
where delivereddate >= {{ dbt.dateadd('month', -3, 'current_date') }}
group by od_countrylane_distinct, order_direction, currency,
         case when distancetype in ('VERY LONG', 'LONG') then 'LONG' else distancetype end
