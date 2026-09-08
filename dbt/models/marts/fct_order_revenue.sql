{{ config(
    materialized='table',
    unique_key='orderno'
) }}
-- =============================================================================
-- fct_order_revenue
--
-- Port of the custom SQL embedded in the Tableau workbook
-- "Revenue Performance Analysis.twbx". One row per order. This is the single
-- table the Cube model sits on.
--
-- SCOPE: no currency conversion, no predicted revenue, no brokerage P&L.
-- Everything here comes from PostgreSQL. There are no external dependencies.
--
-- WHAT THAT MEANS, PLAINLY --------------------------------------------------
--
-- 1. MONEY IS IN THE ORDER'S OWN CURRENCY. There is no FX table, so nothing is
--    converted. `order_currency` is therefore a MANDATORY slice on every
--    revenue figure. Summing revenue without it adds Canadian dollars to US
--    dollars to Mexican pesos and produces a number that means nothing. The
--    Cube measures carry the same warning, and the pre-aggregations all group
--    by currency so the rollups cannot hide the problem.
--
-- 2. REVENUE EXISTS ONLY FOR INVOICED ORDERS. The original filled in a modelled
--    figure for everything else. That model needed ORDERLANEREVENUEMAPPING,
--    which is not in PostgreSQL, so it is gone. Non-invoiced orders keep their
--    row and their dates - so order counts, lanes and volume are still complete
--    - but `order_revenue` is NULL. Use `revenue_status` to separate them.
--
--    Knock-on effect worth knowing: the Labatt shuttle rule in
--    int_order_charges_with_adjustment deliberately flips some INVOICED orders
--    back to NOT INVOICED so they would pick up modelled revenue instead.
--    With no model behind it, those orders now show NULL revenue rather than an
--    estimate. Small population, but it is a real behaviour change.
--
-- 3. NO BUSINESS UNIT, NO BROKERAGE. `businessunitcode` came only from the
--    sales_report_access seed, which is removed. The brokerage P&L needed both
--    FX and GLOBALBROKERAGEANALYSIS, so brokerage revenue, GP, carrier /
--    transfer / trailer cost and the margin RAG tiles are all gone.
--
-- 4. ALIAS REUSE. Snowflake lets a SELECT reuse its own aliases; PostgreSQL does
--    not. Hence `base` -> final select rather than one flat query.
-- =============================================================================

with base as (

    select
        o.orderno,
        o.orderguid,
        o.customer,
        oc.salesrep,
        o.pickcity,
        o.pickstate,
        o.delcity,
        o.delstate,
        o.spot_status,

        case o.pickcountry when 'C' then 'CAN' when 'U' then 'USA' when 'M' then 'MEX' end as pickcountry,
        case o.delcountry  when 'C' then 'CAN' when 'U' then 'USA' when 'M' then 'MEX' end as delcountry,

        o.od_lane_distinct                                    as lane,
        og.pickedupdate,
        og.delivereddate,
        oc.invoicedate,

        oc.invoicestatus,
        case when oc.invoicestatus = 'INVOICED'
             then 'INVOICED' else 'NOT INVOICED' end          as revenue_status,

        -- Single-character code as stored: C = CAD, U = USD, P = MXN.
        oc.currency                                           as order_currency_code,

        -- Revenue only where there is an invoice behind it. NULL otherwise,
        -- which is visible rather than silently zero.
        case when oc.invoicestatus = 'INVOICED'
             then oc.totalchargesnotax end                    as order_revenue,
        case when oc.invoicestatus = 'INVOICED'
             then oc.fsc end                                  as order_fsc_revenue,

        -- Manual charges are already stored per currency upstream, so they need
        -- no conversion - but an order can carry manual charges in a currency
        -- other than its own. Both facts are surfaced below.
        coalesce(oc.manualchargesnotaxcad, 0)                 as manual_charges_cad,
        coalesce(oc.manualchargesnotaxusd, 0)                 as manual_charges_usd,
        coalesce(oc.manualchargesnotaxmxn, 0)                 as manual_charges_mxn

    from {{ ref('int_opd_miles') }} o

    join {{ source('probillsvc', 'order') }} og
      on og.id = o.orderguid

    left join {{ ref('int_order_charges_with_adjustment') }} oc
      on oc.orderguid = o.orderguid

    where o.customer not ilike '%TEST%'
      -- Reporting cutoff. See reporting_start_date in dbt_project.yml.
      and og.delivereddate >= date '{{ var("reporting_start_date") }}'

)

select
    orderno,
    orderguid,
    customer,
    salesrep,
    pickcity,
    pickstate,
    pickcountry,
    delcity,
    delstate,
    delcountry,
    lane,
    spot_status,
    pickedupdate,
    delivereddate,
    invoicedate,
    invoicestatus,
    revenue_status,

    order_currency_code,
    case order_currency_code
         when 'C' then 'CAD'
         when 'U' then 'USD'
         when 'P' then 'MXN'
    end                                                       as order_currency,

    order_revenue,
    order_fsc_revenue,

    -- Revenue net of fuel surcharge. totalchargesnotax already includes fsc.
    case when order_revenue is not null
         then order_revenue - coalesce(order_fsc_revenue, 0)
    end                                                       as order_revenue_ex_fsc,

    -- Manual charges expressed in the order's own currency, so this can be
    -- added to order_revenue without conversion.
    case order_currency_code
         when 'C' then manual_charges_cad
         when 'U' then manual_charges_usd
         when 'P' then manual_charges_mxn
         else 0
    end                                                       as manual_charges,

    -- True when the order carries manual charges billed in some OTHER currency.
    -- Those amounts are excluded from `manual_charges` because there is no rate
    -- to convert them with. This flag is how you find them instead of losing
    -- them quietly.
    (
        case order_currency_code when 'C' then 0 else manual_charges_cad end
      + case order_currency_code when 'U' then 0 else manual_charges_usd end
      + case order_currency_code when 'P' then 0 else manual_charges_mxn end
    ) <> 0                                                    as manual_charges_currency_mismatch,

    manual_charges_cad,
    manual_charges_usd,
    manual_charges_mxn

from base
