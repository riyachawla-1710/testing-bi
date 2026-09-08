{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.LABATT_ORDERREVENUE_VW
--          (populates LABATT_ORDERREVENUE, 43,383 rows)
--
-- Labatt shuttle work is billed as ONE manual invoice per month per side, not
-- per order. This model splits that monthly total back across the individual
-- orders so revenue reporting has a per-order number.
--
-- THE ALLOCATION -------------------------------------------------------------
--   order revenue = monthly invoice total
--                   x  sqrt(this order's distance)
--                   /  sum of sqrt(distance) over all orders that month/side
--
-- Note the SQUARE ROOT. Allocating on raw distance would give long moves too
-- much; sqrt compresses the spread, so a 100-mile move earns ~3x a 10-mile
-- move rather than 10x. That is a deliberate business choice, not a bug -
-- but it is invisible unless you read this SQL, which is exactly why it
-- belongs in a documented model.
--
-- Two paths, unioned:
--   MANUAL              order invoiced Single/Consolidated; the manual invoice
--                       is matched by month, one month BEHIND the pickup month
--   CONSOLIDATED MANUAL order invoiced ManualConsolidated; matched by invoice
--                       number directly, no month offset
--
-- TONU orders are excluded throughout - nothing moved, so nothing is allocated.
--
-- HARDCODED VALUES, kept for fidelity. Both belong in a seed:
--   invoice '8C860B4D-E3B7-42FB-BED4-08DC532CCA10' is shifted an EXTRA month
--     back (a one-off correction for a mis-dated invoice)
--   invoice externalid 30038318 is forced to the 'QC' side
--
-- SIDE detection: orders whose PO starts 'PORT' are Portside, everything else
-- is QC. Invoices are matched the other way round - PO containing 'QC' is QC.
--
-- POSTGRES PORT NOTES:
--   CONTAINS(a, b)      -> position(b in a) > 0   (done)
--   LISTAGG(x, sep)     -> string_agg(x, sep)     (done)
--   MONTH(d)            -> extract(month from d)  (done)
--   DATEADD / DATE_TRUNC / ::DATE / SQRT          -> dbt.dateadd, date_trunc, cast
--   GROUP BY ALL        -> explicit column lists
--   UNION (deduping)    -> kept as UNION, not UNION ALL - the original relies
--                          on it to drop duplicate rows
-- =============================================================================

{% set labatt = "'LABATT BREWING CO LTD (SHUTTLE)'" %}
{% set mis_dated_invoice = "'8C860B4D-E3B7-42FB-BED4-08DC532CCA10'" %}
{% set qc_invoice_externalid = 30038318 %}

with orders_base as (
    -- every live, non-TONU Labatt shuttle order since 2024
    select
        o.id                                        as orderguid,
        o.externalid                                as orderno,
        o.ponumber                                  as orderpo,
        o.customerid,
        o.invoiceid,
        opd.total_distance,
        sqrt(opd.total_distance)                    as adjusted_distance,
        cast(opd.pickedupdate as date)              as pickedupdate,
        cast(date_trunc('month', opd.pickedupdate) as date) as pickmonth,
        case when upper(o.ponumber) like 'PORT%' then 'PORTSIDE' else 'QC' end as order_side
    from {{ source('probillsvc', 'order') }} o
    left join {{ ref('int_opd_miles') }} opd on opd.orderguid = o.id
    left join {{ ref('int_tonu_orders') }} tb  on tb.orderid  = o.id
    where o.isrowdeleted = 0
      and o.orderstatusid <> '{{ var("order_status_cancelled_id") }}'
      and opd.customer = {{ labatt }}
      and opd.pickedupdate >= date '{{ var("labatt_start_date") }}'
      and tb.orderid is null
),

-- the manual invoices, with the mis-dated one corrected
manual_invoices as (
    select
        im.id,
        im.customerid,
        im.externalid,
        im.invoiceno,
        im.ponumber,
        im.currencyid,
        im.totalamount,
        im.taxamount,
        im.invoiceddate,
        case when im.id = {{ mis_dated_invoice }}
             then {{ dbt.dateadd('month', -1, 'im.invoiceddate') }}
             else im.invoiceddate end               as effective_invoiceddate,
        case when position('QC' in upper(im.ponumber)) > 0
               or im.externalid = {{ qc_invoice_externalid }}
             then 'QC' else 'PORTSIDE' end          as invoice_side
    from {{ source('invoicesvc', 'invoice') }} im
    where im.invoicetype = 'Invoice'
      and im.invoicestatusid <> '{{ var("invoice_status_void_id") }}'
),

-- ---------------------------------------------------------------- MANUAL ----
manual as (
    select
        ob.orderguid,
        ob.orderno,
        ob.orderpo,
        ob.total_distance,
        ob.adjusted_distance,
        ob.pickedupdate,
        ob.pickmonth,
        ob.order_side                                   as side,
        cast(i.invoiceddate as date)                    as order_invoiceddate,
        string_agg(mi.invoiceno, ', ')                  as manual_invoiceno,
        c.shortcode                                     as currency,
        sum(mi.totalamount)                             as manual_totalmonth,
        sum(mi.totalamount) - sum(mi.taxamount)         as manual_totalmonth_notax,
        sum(mi.taxamount)                               as manual_totalmonth_tax
    from orders_base ob
    -- order must be on a real Single/Consolidated invoice
    join {{ source('invoicesvc', 'invoice') }} ia
      on ia.id = ob.invoiceid
     and ia.invoicetype in ('Single', 'Consolidated')
     and ia.isrowdeleted = 0
     and ia.invoicestatusid <> '{{ var("invoice_status_void_id") }}'
    left join {{ source('invoicesvc', 'invoice') }} i
           on i.id = ob.invoiceid
          and i.invoicestatusid <> '{{ var("invoice_status_void_id") }}'
    -- the manual invoice for the month AFTER the pickup month, same side
    join manual_invoices mi
      on mi.customerid = ob.customerid
     and ob.order_side = mi.invoice_side
     and ob.pickmonth = cast(date_trunc('month',
             {{ dbt.dateadd('month', -1, 'mi.effective_invoiceddate') }}) as date)
    left join {{ source('invoicesvc', 'currency') }} c on c.id = mi.currencyid
    group by ob.orderguid, ob.orderno, ob.orderpo, ob.total_distance,
             ob.adjusted_distance, ob.pickedupdate, ob.pickmonth, ob.order_side,
             i.invoiceddate, c.shortcode
),

-- total sqrt(distance) per month and side - the allocation denominator
totalmiles_manual as (
    select
        ob.order_side  as side,
        ob.pickmonth,
        sum(ob.adjusted_distance) as total_ordermiles_adjusted,
        sum(ob.total_distance)    as total_ordermiles
    from orders_base ob
    join {{ source('invoicesvc', 'invoice') }} ia
      on ia.id = ob.invoiceid
     and ia.invoicetype in ('Single', 'Consolidated')
     and ia.isrowdeleted = 0
     and ia.invoicestatusid <> '{{ var("invoice_status_void_id") }}'
    group by ob.order_side, ob.pickmonth
),

-- ------------------------------------------------- CONSOLIDATED MANUAL ------
manual_consolidated as (
    select
        ob.orderguid,
        ob.orderno,
        ob.orderpo,
        ob.total_distance,
        ob.adjusted_distance,
        ob.pickedupdate,
        ob.pickmonth,
        case when position('QC' in upper(im.ponumber)) > 0
               or im.externalid = {{ qc_invoice_externalid }}
             then 'QC' else 'PORTSIDE' end          as side,
        cast(im.invoiceddate as date)               as order_invoiceddate,
        im.invoiceno                                as order_invoiceno,
        im.invoiceno                                as manual_invoiceno,
        c.shortcode                                 as currency,
        im.totalamount                              as manual_totalmonth,
        im.totalamount - im.taxamount               as manual_totalmonth_notax,
        im.taxamount                                as manual_totalmonth_tax
    from orders_base ob
    join {{ source('invoicesvc', 'invoice') }} im
      on im.id = ob.invoiceid
     and im.invoicetype = 'ManualConsolidated'
     and im.isrowdeleted = 0
     and im.invoicestatusid <> '{{ var("invoice_status_void_id") }}'
    left join {{ source('invoicesvc', 'currency') }} c on c.id = im.currencyid
),

totalmiles_invoice as (
    select
        im.invoiceno,
        sum(ob.adjusted_distance) as total_ordermiles_adjusted,
        sum(ob.total_distance)    as total_ordermiles
    from orders_base ob
    join {{ source('invoicesvc', 'invoice') }} im
      on im.id = ob.invoiceid
     and im.invoicetype = 'ManualConsolidated'
     and im.isrowdeleted = 0
     and im.invoicestatusid <> '{{ var("invoice_status_void_id") }}'
    group by im.invoiceno
)

-- UNION (not UNION ALL) - the original relies on it to dedupe
select
    o.orderguid,
    o.orderno,
    o.orderpo,
    o.side                                          as orderside,
    o.currency,
    o.order_invoiceddate,
    o.manual_invoiceno,
    o.total_distance                                as od_miles,
    o.pickedupdate,
    o.pickmonth,
    o.manual_totalmonth,
    o.manual_totalmonth_notax,
    o.manual_totalmonth_tax,
    round(o.manual_totalmonth       * o.adjusted_distance
          / nullif(tm.total_ordermiles_adjusted, 0), 2) as labatt_orderrev,
    round(o.manual_totalmonth_notax * o.adjusted_distance
          / nullif(tm.total_ordermiles_adjusted, 0), 2) as labatt_orderrevnotax,
    round(o.manual_totalmonth_tax   * o.adjusted_distance
          / nullif(tm.total_ordermiles_adjusted, 0), 2) as labatt_ordertax,
    count(distinct o.orderguid) over (partition by o.pickmonth, o.side) as ordersinmonth,
    'MANUAL'                                        as source
from manual o
left join totalmiles_manual tm
       on o.side = tm.side
      and o.pickmonth = tm.pickmonth

union

select
    o.orderguid,
    o.orderno,
    o.orderpo,
    o.side,
    o.currency,
    o.order_invoiceddate,
    o.manual_invoiceno,
    o.total_distance,
    o.pickedupdate,
    o.pickmonth,
    o.manual_totalmonth,
    o.manual_totalmonth_notax,
    o.manual_totalmonth_tax,
    round(o.manual_totalmonth       * o.adjusted_distance
          / nullif(tm.total_ordermiles_adjusted, 0), 2),
    round(o.manual_totalmonth_notax * o.adjusted_distance
          / nullif(tm.total_ordermiles_adjusted, 0), 2),
    round(o.manual_totalmonth_tax   * o.adjusted_distance
          / nullif(tm.total_ordermiles_adjusted, 0), 2),
    count(distinct o.orderguid) over (partition by o.order_invoiceno),
    'CONSOLIDATED MANUAL'
from manual_consolidated o
left join totalmiles_invoice tm
       on o.order_invoiceno = tm.invoiceno
