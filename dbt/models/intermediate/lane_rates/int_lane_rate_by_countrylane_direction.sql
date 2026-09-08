{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.AVG_REVENUE_BY_COUNTRYLANE_DIRECTION
--
-- Rate per mile on a country lane, kept per direction (unlike the view above).
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
with agg as (
    select
        od_countrylane,
        distancetype,
        currency,
        direction,
        percentile_cont(0.5) within group (order by (frt + fsc) / total_distance) as avg_rpm,
        percentile_cont(0.5) within group (order by fsc / total_distance)          as avg_rpm_fsc,
        percentile_cont(0.5) within group (order by frt / total_distance)          as avg_rpm_frt,
        avg(frt + fsc)                                                            as avg_revenue,
        avg(fsc)                                                                  as avg_fsc,
        avg(frt)                                                                  as avg_frt,
        count(*)                                                                  as n
    from {{ source('pending', 'orderlanerevenuemapping') }}
    where delivereddate >= {{ dbt.dateadd('month', -3, 'current_date') }}
    group by od_countrylane, distancetype, currency, direction
),
ranked as (
    select *, row_number() over (partition by od_countrylane, distancetype, direction
                                 order by n desc) as rn
    from agg
)
select od_countrylane, distancetype, currency, direction,
       avg_rpm, avg_rpm_fsc, avg_rpm_frt, avg_revenue, avg_fsc, avg_frt
from ranked where rn = 1
