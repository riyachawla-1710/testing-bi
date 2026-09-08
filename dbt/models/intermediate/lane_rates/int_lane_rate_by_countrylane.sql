{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.AVG_REVENUE_BY_COUNTRYLANE
--
-- Rate per mile on a country-to-country lane.
-- QUIRK WORTH CHECKING: it groups by direction and currency but keeps only one
-- row per (od_countrylane, distancetype) - so the surviving row's direction is
-- whichever had the most orders. int_predicted_revenue then joins ON direction,
-- so this step often finds nothing. Probably not intended.
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
        currency,
        distancetype,
        direction_ns                                                            as direction,
        count(*)                                                                as currency_count,
        percentile_cont(0.5) within group (order by totalcharges / total_distance) as avg_rpm,
        percentile_cont(0.5) within group (order by frt / total_distance)          as avg_rpm_frt,
        percentile_cont(0.5) within group (order by fsc / total_distance)          as avg_rpm_fsc,
        avg(totalcharges)                                                          as avg_revenue,
        avg(frt)                                                                   as avg_frt,
        avg(fsc)                                                                   as avg_fsc
    from {{ source('pending', 'orderlanerevenuemapping') }}
    where delivereddate >= {{ dbt.dateadd('month', -3, 'current_date') }}
    group by od_countrylane, currency, distancetype, direction_ns
),
ranked as (
    select *, row_number() over (partition by od_countrylane, distancetype
                                 order by currency_count desc) as rn
    from agg
)
select od_countrylane, currency, distancetype, direction, currency_count,
       avg_rpm, avg_rpm_frt, avg_rpm_fsc, avg_revenue, avg_frt, avg_fsc
from ranked where rn = 1
