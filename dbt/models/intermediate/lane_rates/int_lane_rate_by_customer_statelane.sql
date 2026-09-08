{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.AVG_REVENUE_BY_CUSTOMER_STATELANE
--
-- Rate per mile for a customer on a state-to-state lane. Excludes lanes whose
-- reverse is identical (od_statelane <> od_reverse_statelane) and trips under
-- 50 miles, both of which distort a per-mile rate.
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
        customer,
        od_statelane,
        direction_ns                                                            as direction,
        distancetype,
        currency,
        percentile_cont(0.5) within group (order by (frt + fsc) / total_distance) as avg_rpm,
        percentile_cont(0.5) within group (order by frt / total_distance)         as avg_rpm_frt,
        percentile_cont(0.5) within group (order by fsc / total_distance)         as avg_rpm_fsc,
        avg(frt + fsc)                                                           as avg_revenue,
        avg(frt)                                                                 as avg_frt,
        avg(fsc)                                                                 as avg_fsc,
        count(*)                                                                 as n
    from {{ source('pending', 'orderlanerevenuemapping') }}
    where delivereddate >= {{ dbt.dateadd('month', -6, 'current_date') }}
      and od_statelane <> od_reverse_statelane
      and total_distance > 50
    group by customer, od_statelane, direction_ns, distancetype, currency
),
ranked as (
    select *, row_number() over (partition by customer, od_statelane, direction, distancetype
                                 order by n desc) as rn
    from agg
)
select customer, od_statelane, direction, distancetype, currency,
       avg_rpm, avg_rpm_frt, avg_rpm_fsc, avg_revenue, avg_frt, avg_fsc
from ranked where rn = 1
