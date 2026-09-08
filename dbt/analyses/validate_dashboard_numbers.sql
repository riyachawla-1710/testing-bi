-- =============================================================================
-- The dashboard test case, taken straight off a screenshot of the live
-- Tableau dashboard.
--
--   Filters : Sales rep = NICK BAUMER, Business unit = BO HOME,
--             Currency = USD, Revenue month = Last 12 Months
--   Expected: 4,096 orders and 7,450,826.44 total order revenue
--
-- NOTE ON WHICH REVENUE MEASURE: the Tableau parameter "fsc Revenue Toggle"
-- defaults to 'fsc Only', so the dashboard's headline number may be
-- fuel-surcharge revenue alone rather than total revenue. All three variants
-- are computed below - whichever one returns 7,450,826.44 tells you what the
-- dashboard has actually been showing.
-- =============================================================================

select
    count(distinct orderno)                                     as total_orders,
    round(sum(orderfscrevenueusd), 2)                           as revenue_fsc_only,
    round(sum(orderrevenueusd + manualchargesnotaxusd), 2)      as revenue_incl_fsc,
    round(sum(orderrevenueusd + manualchargesnotaxusd
              - orderfscrevenueusd), 2)                         as revenue_ex_fsc
from {{ ref('fct_order_revenue') }}
where salesrep = 'NICK BAUMER'
  and businessunitcode = 'BO HOME'
  and delivereddate >= date_trunc('month', current_date - interval '12 month')
