{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.KEURIG_SHUNTINGREVENUE_VW
--
-- Last step of the predicted-revenue cascade. Average revenue for Keurig
-- shunting work: zero-distance moves within Quebec.
--
-- The filters are extremely specific - one customer, one lane, distance = 0:
--     customer = 'KEURIG CANADA INC.'
--     od_statelane_distinct = 'QC - QC'
--     total_distance = 0
-- Shunting is yard movement, so there is no line-haul distance to rate. That
-- is why this exists as a special case rather than falling out of the
-- distance-based benchmarks.
--
-- ROLLING WINDOW: last 3 months by invoice date, relative to current_date.
-- Same caveat as the lane-rate models - the value moves as the window rolls.
--
-- POSTGRES PORT NOTES: ADD_MONTHS -> dbt.dateadd · GROUP BY ALL -> explicit
-- =============================================================================

select
    avg(oc.totalchargesnotax)  as avg_revenue,
    avg(oc.frt)                as avg_frt,
    avg(oc.fsc)                as avg_fsc,
    opd.od_statelane_distinct,
    oc.currency
from {{ ref('int_order_charges_with_adjustment') }} oc
left join {{ ref('int_opd_miles') }} opd
       on opd.orderguid = oc.orderguid
where oc.invoicestatus = 'INVOICED'
  and opd.total_distance = 0
  and opd.customer = 'KEURIG CANADA INC.'
  and opd.od_statelane_distinct = 'QC - QC'
  and oc.invoicedate >= {{ dbt.dateadd('month', -3, 'current_date') }}
group by opd.od_statelane_distinct, oc.currency
