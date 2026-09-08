{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.AVG_REVENUE_BY_COUNTRYLANE_ROUNDTRIP
--
-- Round-trip lanes only: multi-probill orders that either return (roundtrip_check)
-- or are already flagged 'RT'. Collapses MEDIUM, LONG and VERY LONG into LONG.
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
    case when distancetype in ('LONG', 'VERY LONG', 'MEDIUM') then 'LONG'
         else distancetype end                                                 as distancetype,
    currency,
    case when roundtrip_check then 'RT' else order_direction end               as order_direction,
    percentile_cont(0.5) within group (order by totalcharges / total_distance)  as avg_rpm,
    percentile_cont(0.5) within group (order by frt / total_distance)           as avg_rpm_frt,
    percentile_cont(0.5) within group (order by fsc / total_distance)           as avg_rpm_fsc,
    avg(totalcharges)                                                           as avg_revenue,
    avg(frt)                                                                    as avg_frt,
    avg(fsc)                                                                    as avg_fsc,
    countriescount
from {{ source('bi_analytics', 'orderlanerevenuemapping') }}
where delivereddate >= {{ dbt.dateadd('month', -3, 'current_date') }}
  and (roundtrip_check = true or order_direction = 'RT')
  and probillcount > 1
group by od_countrylane_distinct,
         case when distancetype in ('LONG', 'VERY LONG', 'MEDIUM') then 'LONG' else distancetype end,
         currency,
         case when roundtrip_check then 'RT' else order_direction end,
         countriescount
