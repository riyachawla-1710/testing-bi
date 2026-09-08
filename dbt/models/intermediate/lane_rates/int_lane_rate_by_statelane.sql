{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.AVG_REVENUE_BY_STATELANE
--
-- Rate per mile on a state-to-state lane, any customer. NOTE: when freight and
-- fuel are both zero it substitutes EXTRA charges - the only view in this layer
-- that does so.
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
with agg as (
    select
        od_statelane,
        distancetype,
        direction_ns                                                    as direction,
        currency,
        percentile_cont(0.5) within group (
            order by (case when (frt + fsc) = 0 then extra else frt + fsc end) / total_distance
        )                                                               as avg_rpm,
        percentile_cont(0.5) within group (order by fsc / total_distance) as avg_rpm_fsc,
        percentile_cont(0.5) within group (order by frt / total_distance) as avg_rpm_frt,
        avg(case when (frt + fsc) = 0 then extra else frt + fsc end)     as avg_revenue,
        avg(fsc)                                                         as avg_fsc,
        avg(frt)                                                         as avg_frt,
        count(*)                                                         as n
    from {{ source('pending', 'orderlanerevenuemapping') }}
    where delivereddate >= {{ dbt.dateadd('month', -6, 'current_date') }}
    group by od_statelane, distancetype, direction_ns, currency
),
ranked as (
    select *, row_number() over (partition by od_statelane, direction, distancetype
                                 order by n desc) as rn
    from agg
)
select od_statelane, distancetype, direction, currency,
       avg_rpm, avg_rpm_fsc, avg_rpm_frt, avg_revenue, avg_fsc, avg_frt
from ranked where rn = 1
