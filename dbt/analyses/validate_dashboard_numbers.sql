-- =============================================================================
-- The dashboard test case, taken off a screenshot of the live Tableau
-- dashboard:
--
--   Filters : Sales rep = NICK BAUMER, Business unit = BO HOME,
--             Currency = USD, Revenue month = Last 12 Months
--   Expected: 4,096 orders and 7,450,826.44 total order revenue
--
-- THIS NUMBER CANNOT BE REPRODUCED ANY MORE, AND THAT IS EXPECTED.
--
-- The Tableau figure was built from three things this project no longer has:
--
--   1. FX conversion. Tableau's "Currency = USD" converted CAD-billed orders
--      into USD at the Bank of Canada daily rate. With no FX table, USD here
--      means "orders that were billed in USD" - a smaller, different
--      population. This alone moves the number a long way.
--   2. Predicted revenue. Tableau filled in a modelled figure for
--      non-invoiced orders. Revenue here is invoiced-only.
--   3. The business-unit filter. BO HOME came from the SALESREPORTACCESS
--      seed, which is removed, so the filter cannot be applied at all.
--
-- So treat the query below as a REGRESSION BASELINE, not a reconciliation:
-- run it once, write the answers down, and use it to catch changes from here
-- on. Do not expect 4,096 / 7,450,826.44 and do not chase the difference.
--
-- If you ever need to tie back to Tableau properly, you need FX and predicted
-- revenue back first. Both are recoverable - see git history at 1792a28 for
-- the deleted models and the five source objects they needed.
-- =============================================================================

-- 1. Revenue by currency for one rep, last 12 months.
--    Note the GROUP BY currency: without it these amounts are meaningless.
select
    order_currency,
    revenue_status,
    count(distinct orderno)                                as orders,
    round(sum(order_fsc_revenue), 2)                       as revenue_fsc_only,
    round(sum(order_revenue), 2)                           as revenue_incl_fsc,
    round(sum(order_revenue_ex_fsc), 2)                    as revenue_ex_fsc,
    round(sum(manual_charges), 2)                          as manual_charges,
    count(distinct orderno)
        filter (where manual_charges_currency_mismatch)     as fx_mismatch_orders
from {{ ref('fct_order_revenue') }}
where salesrep = 'NICK BAUMER'
  and delivereddate >= date_trunc('month', current_date - interval '12 month')
group by order_currency, revenue_status
order by order_currency, revenue_status

/*
-- 2. Whole-mart shape. Run this after every build; the row count and the
--    invoiced share are the two numbers that move when something upstream
--    breaks.
select
    order_currency,
    revenue_status,
    count(*)                                               as rows,
    count(distinct orderno)                                as orders,
    min(delivereddate)                                     as first_delivery,
    max(delivereddate)                                     as last_delivery,
    round(sum(order_revenue), 2)                           as revenue_incl_fsc
from reporting.fct_order_revenue
group by order_currency, revenue_status
order by order_currency, revenue_status;

-- 3. How much revenue is being dropped because manual charges were billed in
--    a currency other than the order's. If this is material, FX is not
--    optional after all.
--    Each sum EXCLUDES the order's own currency, so these are only the
--    amounts actually being dropped.
select
    order_currency,
    count(*)                                               as orders,
    round(sum(case when order_currency_code = 'C' then 0
                   else manual_charges_cad end), 2)        as stranded_cad,
    round(sum(case when order_currency_code = 'U' then 0
                   else manual_charges_usd end), 2)        as stranded_usd,
    round(sum(case when order_currency_code = 'P' then 0
                   else manual_charges_mxn end), 2)        as stranded_mxn
from reporting.fct_order_revenue
where manual_charges_currency_mismatch
group by order_currency, order_currency_code
order by order_currency;
*/
