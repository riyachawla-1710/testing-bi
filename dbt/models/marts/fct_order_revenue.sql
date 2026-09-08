{{ config(
    materialized='table',
    unique_key='orderno'
) }}
-- =============================================================================
-- fct_order_revenue
--
-- Port of the custom SQL embedded in the Tableau workbook
-- "Revenue Performance Analysis.twbx" (extract: 1,100,516 rows).
-- One row per order. This is the single table the Cube model sits on.
--
-- Feeds four dashboards:
--   Revenue Performance Analysis
--   Volume Performance Analysis
--   Revenue Execution Analysis: Customer
--   Revenue Execution Analysis: SalesRep
--
-- TWO DELIBERATE CHANGES FROM THE ORIGINAL ----------------------------------
--
-- 1. FX RATE DATE. The original ends its COALESCE chain with CURRENT_DATE:
--
--        COALESCE(OC.INVOICEDATE::DATE, O.PICKEDUPDATE, O.DELIVEREDDATE, CURRENT_DATE)
--
--    Any order with none of those three dates was therefore revalued at
--    *today's* rate on every refresh, so historical revenue moved between runs.
--    That also makes the table impossible to build incrementally.
--    Here the fallback is removed: such orders get a NULL rate_date and
--    therefore NULL converted revenue, which is visible rather than silently
--    wrong. Set fx_fallback_to_today = true below to restore old behaviour
--    while you reconcile against Tableau.
--
-- 2. ALIAS REUSE. Snowflake lets a SELECT reuse its own aliases (ORDERREVENUE
--    is defined and then multiplied by FX.CADRATE in the same select list, and
--    ORDERCURRENCY is used in a JOIN condition). Postgres does not allow
--    either. The query is therefore split into `base` -> `converted`.
-- =============================================================================

{% set fx_fallback_to_today = false %}

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

        case when oc.invoicestatus = 'INVOICED' then 'ACTUAL' else 'PREDICTED' end as revenuesource,

        case when oc.invoicestatus = 'INVOICED' then oc.totalchargesnotax
             else pr.predicted_revenue end                    as orderrevenue,
        case when oc.invoicestatus = 'INVOICED' then oc.currency
             else pr.currency end                             as ordercurrency,
        case when oc.invoicestatus = 'INVOICED' then oc.fsc
             else 0 end                                       as orderfscrevenue,

        b.purebrokerage                                       as brokerageorder,
        b.tshybridbrokerage,

        oc.manualchargesnotaxcad                              as raw_manualcad,
        oc.manualchargesnotaxusd                              as raw_manualusd,
        oc.manualchargesnotaxmxn                              as raw_manualmxn,

        b.brokeragegpcad,
        b.brokeragegpusd,
        b.brokeragerevenuecad,
        b.brokeragerevenueusd,
        b.carriercostusd,
        b.carriercostcad,
        b.transfercostusd,
        b.transfercostcad,
        b.trailercostusd,
        b.trailercostcad,
        b.tsrateusd,
        b.tsratecad,

        sra.businessunitcode,
        sra.businessunitdescription,

        -- the FX date, with the CURRENT_DATE fallback removed (see header)
        cast(
            coalesce(
                cast(oc.invoicedate as date),
                o.pickedupdate,
                o.delivereddate
                {%- if fx_fallback_to_today %}, current_date {%- endif %}
            ) as date
        )                                                     as rate_date

    from {{ ref('int_opd_miles') }} o

    join {{ source('probillsvc', 'order') }} og
      on og.id = o.orderguid

    left join {{ ref('int_order_charges_with_adjustment') }} oc
      on oc.orderguid = o.orderguid

    left join {{ ref('int_predicted_revenue') }} pr
      on pr.orderguid = o.orderguid

    left join {{ source('bi_analytics', 'salesreportaccess') }} sra
      on upper(sra.username) = upper(oc.salesrep)

    left join {{ ref('int_ts_hybrid_brokerage_pnl') }} b
      on b.orderguid = o.orderguid

    where o.customer not ilike '%TEST%'

),

-- Pivoted rate matrix, used for the tri-currency manual-charge roll-up.
-- Port of the inline FXM subquery in the original.
fx_matrix as (
    select
        calendardate,
        max(case when sourcecurrencycode = 'P' then usdrate end) as ptou,
        max(case when sourcecurrencycode = 'P' then cadrate end) as ptoc,
        max(case when sourcecurrencycode = 'U' then cadrate end) as utoc,
        max(case when sourcecurrencycode = 'C' then usdrate end) as ctou
    from {{ ref('int_fx_rates_daily') }}
    group by calendardate
),

converted as (

    select
        b.*,

        b.orderrevenue    * fx.cadrate  as orderrevenuecad,
        b.orderrevenue    * fx.usdrate  as orderrevenueusd,
        b.orderfscrevenue * fx.cadrate  as orderfscrevenuecad,
        b.orderfscrevenue * fx.usdrate  as orderfscrevenueusd,

        b.raw_manualcad
          + b.raw_manualusd * fxm.utoc
          + b.raw_manualmxn * fxm.ptoc  as manualchargesnotaxcad,

        b.raw_manualcad * fxm.ctou
          + b.raw_manualusd
          + b.raw_manualmxn * fxm.ptou  as manualchargesnotaxusd,

        fx.forexsource

    from base b
    left join {{ ref('int_fx_rates_daily') }} fx
           on fx.sourcecurrencycode = b.ordercurrency
          and fx.calendardate       = b.rate_date
    left join fx_matrix fxm
           on fxm.calendardate      = b.rate_date

)

select
    orderno,
    orderguid,
    customer,
    salesrep,
    businessunitcode,
    businessunitdescription,
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
    rate_date,
    revenuesource,
    ordercurrency,
    forexsource,

    orderrevenue,
    orderrevenuecad,
    orderrevenueusd,
    orderfscrevenue,
    orderfscrevenuecad,
    orderfscrevenueusd,
    manualchargesnotaxcad,
    manualchargesnotaxusd,

    brokerageorder,
    tshybridbrokerage,
    brokeragegpcad,
    brokeragegpusd,
    brokeragerevenuecad,
    brokeragerevenueusd,
    carriercostcad,
    carriercostusd,
    transfercostcad,
    transfercostusd,
    trailercostcad,
    trailercostusd,
    tsratecad,
    tsrateusd

from converted
