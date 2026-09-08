{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.ORDERCHARGES_WITHADJUSTMENT_VW  (the whole thing)
--
-- Order-grain charges = base charges + billable adjustments + manual invoices,
-- with a UNION ALL branch that replaces the values entirely for orders present
-- in LABATT_ORDERREVENUE.
--
-- Materialised as a table, not a view: it is the single most-queried object in
-- the revenue chain (10,894 queries / 90 days, 11 distinct users) and it joins
-- five upstream models.
--
-- BUSINESS RULE WORTH FLAGGING -----------------------------------------------
-- The "Labatt shuttle" rule silently reclassifies an INVOICED order back to
-- NOT INVOICED (and nulls its invoice date) when all of:
--     customer = 'LABATT BREWING CO LTD (SHUTTLE)'
--     invoiced on/after 2025-01-01
--     total charges <= 1
-- That means these orders fall through to PREDICTED revenue instead of actual.
-- Confirm this is still wanted before shipping.
-- =============================================================================

with base as (

    select
        oc.orderguid,
        oc.orderno,
        oc.ponumber,
        -- alias fix reapplied here exactly as the original view does
        case when oc.salesrep ilike 'JORGE LOPEZ'
             then 'JORGE BENJAMIN LOPEZ SOLORZANO'
             else oc.salesrep end                                as salesrep,
        oc.spotbidlead,
        oc.accountmanager,
        oc.csr,
        oc.currency,

        case when lb.orderguid is null
              and oc.customer      = 'LABATT BREWING CO LTD (SHUTTLE)'
              and oc.invoicestatus = 'INVOICED'
              and oc.invoicedate  >= date '2025-01-01'
              and oc.totalcharges <= 1
             then 'NOT INVOICED'
             else oc.invoicestatus end                           as invoicestatus,

        case when lb.orderguid is null
              and oc.customer      = 'LABATT BREWING CO LTD (SHUTTLE)'
              and oc.invoicestatus = 'INVOICED'
              and oc.invoicedate  >= date '2025-01-01'
              and oc.totalcharges <= 1
             then null
             else oc.invoicedate end                             as invoicedate,

        oc.customer,
        oc.orderstatus,

        round(oc.frt   + coalesce(a.frt,   0), 2)                as frt,
        round(oc.fsc   + coalesce(a.fsc,   0), 2)                as fsc,
        round(oc.extra + coalesce(a.extra, 0), 2)                as extra,

        oec.manualextracharge_details,
        oec.orderextracharge_details,

        coalesce(m.manualchargesnotaxmxn, 0)                     as manualchargesnotaxmxn,
        coalesce(m.manualchargesnotaxcad, 0)                     as manualchargesnotaxcad,
        coalesce(m.manualchargesnotaxusd, 0)                     as manualchargesnotaxusd,
        coalesce(m.manualchargetaxmxn,    0)                     as manualchargetaxmxn,
        coalesce(m.manualchargetaxcad,    0)                     as manualchargetaxcad,
        coalesce(m.manualchargetaxusd,    0)                     as manualchargetaxusd,
        coalesce(m.manualtotalchargesmxn, 0)                     as manualtotalchargesmxn,
        coalesce(m.manualtotalchargescad, 0)                     as manualtotalchargescad,
        coalesce(m.manualtotalchargesusd, 0)                     as manualtotalchargesusd,

        round(oc.totalcharges      + coalesce(a.totalcharges,      0), 2) as totalcharges,
        round(oc.totalchargesnotax + coalesce(a.totalchargesnotax, 0), 2) as totalchargesnotax,
        round(oc.taxamount         + coalesce(a.taxamount,         0), 2) as taxamount,

        case when a.orderno is null then false else true end     as adjustmentflag,
        case when m.orderno is null then false else true end     as manualflag,
        coalesce(m.manualadjustmentflag, false)                  as manualadjustmentflag

    from {{ ref('int_order_charges') }} oc
    left join {{ ref('int_charge_adjustments') }} a on a.orderguid = oc.orderguid
    left join {{ ref('int_manual_charges') }}     m on m.orderguid = oc.orderguid
    left join {{ source('pending', 'labatt_orderrevenue') }} lb
           on lb.orderguid = oc.orderguid
    left join {{ source('pending', 'orderextracharges_vw') }} oec
           on oec.orderguid = oc.orderguid
    where lb.orderguid is null

),

labatt_override as (

    -- Orders that DO appear in LABATT_ORDERREVENUE: values come from there
    -- entirely, currency forced to CAD, no FSC, no manual charges.
    select
        oc.orderguid,
        oc.orderno,
        oc.ponumber,
        case when oc.salesrep ilike 'JORGE LOPEZ'
             then 'JORGE BENJAMIN LOPEZ SOLORZANO'
             else oc.salesrep end                as salesrep,
        oc.spotbidlead,
        oc.accountmanager,
        oc.csr,
        'C'                                      as currency,
        oc.invoicestatus,
        lb.order_invoiceddate                    as invoicedate,
        oc.customer,
        oc.orderstatus,
        round(lb.labatt_orderrevnotax, 2)        as frt,
        0                                        as fsc,
        0                                        as extra,
        cast(null as {{ dbt.type_string() }})    as manualextracharge_details,
        cast(null as {{ dbt.type_string() }})    as orderextracharge_details,
        0 as manualchargesnotaxmxn, 0 as manualchargesnotaxcad, 0 as manualchargesnotaxusd,
        0 as manualchargetaxmxn,    0 as manualchargetaxcad,    0 as manualchargetaxusd,
        0 as manualtotalchargesmxn, 0 as manualtotalchargescad, 0 as manualtotalchargesusd,
        round(lb.labatt_orderrev,      2)        as totalcharges,
        round(lb.labatt_orderrevnotax, 2)        as totalchargesnotax,
        round(lb.labatt_ordertax,      2)        as taxamount,
        false                                    as adjustmentflag,
        true                                     as manualflag,
        false                                    as manualadjustmentflag
    from {{ ref('int_order_charges') }} oc
    join {{ source('pending', 'labatt_orderrevenue') }} lb
      on lb.orderguid = oc.orderguid

)

select * from base
union all
select * from labatt_override
