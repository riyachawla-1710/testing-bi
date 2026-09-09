
  
    

  create  table "test"."reporting_intermediate"."int_order_extra_charges__dbt_tmp"
  
  
    as
  
  (
    
-- =============================================================================
-- Port of: BI.ANALYTICS.ORDEREXTRACHARGES_VW
--
-- Builds two JSON detail blobs per order - a breakdown of "extra" charges
-- (anything that is neither freight rate nor fuel surcharge), keyed by charge
-- code and nested by currency:
--
--     orderextracharge_details   {"C": {"DETENTION": 150, "LUMPER": 75}}
--     manualextracharge_details  {"U": {"STORAGE": 200}}
--
-- Three sources are unioned: order charges typed 'Extra Charge', billable
-- invoice adjustments typed 'Extra Charge', and manually raised invoice lines.
--
-- POSTGRES PORT NOTES:
--   OBJECT_AGG(k, v)  -> jsonb_object_agg(k, v)  - done. Note jsonb_object_agg
--                        ERRORS on a NULL key, where Snowflake's OBJECT_AGG
--                        skips the pair, so the null guards below matter.
--   NVL2(a, b, c)     -> case when a is not null then b else c end
--   IFNULL            -> coalesce
--   GROUP BY ALL      -> explicit column list
-- =============================================================================

with raw_invoiceadjustment as (
    select
        ia.orderid      as orderguid,
        o.externalid    as orderno,
        o.currency,
        oct.chargetype,
        ia.chargecode,
        ia.description,
        ia.totalcharge,
        ia.taxamount
    from "test"."invoicesvc"."invoiceadjustment" ia
    left join "test"."invoicesvc"."invoice" iv on ia.invoiceid = iv.id
    left join "test"."invoicesvc"."invoicecharge" ic
           on ia.invoicechargeid = ic.id and ic.isrowdeleted = false
    left join "test"."probillsvc".orderchargetype oct
           on ic.orderchargetypeid = oct.id and oct.isrowdeleted = false
    left join "test"."probillsvc"."order" o
           on o.id = ia.orderid
          and o.isrowdeleted = false
          and o.orderstatusid <> 'ABD88AC0-5970-40DA-8382-53DD000300B7'
    where ia.invoiceadjustmentreasonid = '056CD084-9779-4BC6-B138-675AF9718760'
      and ia.chargecode not in ('BAL DUE')
      and iv.invoicestatusid <> '8ACBC9AB-0298-43E1-85C7-DDE861F8B32C'
      and iv.isrowdeleted = false
      -- note: EXCLUDES real invoices here, unlike int_charge_adjustments
      and iv.invoicetype <> 'Invoice'
      and ia.isrowdeleted = false
),

invoiceadjustment as (
    select
        orderguid,
        currency,
        orderno,
        coalesce(
            chargetype,
            case
                when chargecode  ilike '%FRT%'
                  or chargecode  ilike '%FREIGHT%'
                  or description ilike '%SERVICIOS%' then 'Freight Rate'
                when chargecode  ilike '%FSC%'
                  or chargecode  ilike '%FUEL%'      then 'Fuel Surcharge'
                else 'Extra Charge'
            end
        ) as chargetype,
        chargecode,
        description,
        totalcharge,
        taxamount
    from raw_invoiceadjustment
),

raw_ordercharge as (
    select
        oc.orderid    as orderguid,
        o.externalid  as orderno,
        o.currency,
        oct.chargecode,
        sum(oc.totalcharges) as totalcharges
    from "test"."probillsvc"."order" o
    left join "test"."probillsvc".ordercharge oc
           on oc.orderid = o.id and oc.isrowdeleted = false
    left join "test"."probillsvc".orderchargetype oct
           on oc.orderchargetypeid = oct.id
    where oct.chargetype = 'Extra Charge'
      and o.isrowdeleted = false
      and o.orderstatusid <> 'ABD88AC0-5970-40DA-8382-53DD000300B7'
    group by oc.orderid, o.externalid, o.currency, oct.chargecode

    union all

    select
        orderguid,
        orderno,
        currency,
        chargecode,
        sum(totalcharge)
    from invoiceadjustment
    where chargetype = 'Extra Charge'
    group by orderguid, orderno, currency, chargecode
),

ordercharge as (
    select
        orderguid,
        orderno,
        currency,
        'ORDER'              as source,
        chargecode,
        sum(totalcharges)    as totalcharges
    from raw_ordercharge
    group by orderguid, orderno, currency, chargecode
    having sum(totalcharges) <> 0
),

raw_revenue_extracharges as (
    select orderguid, orderno, currency, source, chargecode, totalcharges
    from ordercharge

    union all

    -- manual invoice lines
    select
        o.id            as orderguid,
        o.externalid    as orderno,
        ic.shortcode    as currency,
        'MANUAL'        as source,
        iv.description  as chargecode,
        sum(iv.amount)  as totalcharges
    from "test"."invoicesvc"."invoice" i
    left join "test"."invoicesvc"."invoicecharge" iv
           on iv.invoiceid = i.id and iv.isrowdeleted = false
    left join "test"."invoicesvc"."currency" ic on ic.id = i.currencyid
    left join "test"."probillsvc"."order" o
           on o.id = iv.orderid
          and o.isrowdeleted = false
          and o.orderstatusid <> 'ABD88AC0-5970-40DA-8382-53DD000300B7'
    where i.invoicetype = 'Invoice'
      and i.invoicestatusid <> '8ACBC9AB-0298-43E1-85C7-DDE861F8B32C'
      and i.isrowdeleted = false
      and o.id is not null
    group by o.id, o.externalid, ic.shortcode, iv.description

    union all

    -- adjustments attached to manual invoices, via the order relation table
    select
        o.id              as orderguid,
        o.externalid      as orderno,
        ic.shortcode      as currency,
        'MANUAL'          as source,
        ia.description    as chargecode,
        sum(ia.totalcharge)
    from "test"."invoicesvc"."invoice" i
    left join "test"."invoicesvc"."invoicecharge" iv
           on iv.invoiceid = i.id and iv.isrowdeleted = false
    left join "test"."invoicesvc"."invoiceadjustment" ia
           on ia.invoiceid = i.id and ia.isrowdeleted = false
    left join "test"."invoicesvc"."invoiceorderrel" ior
           on i.id = ior.invoiceid and ior.isrowdeleted = false
    left join "test"."invoicesvc"."currency" ic on ic.id = i.currencyid
    left join "test"."probillsvc"."order" o
           on o.id = ior.orderid
          and o.isrowdeleted = false
          and o.orderstatusid <> 'ABD88AC0-5970-40DA-8382-53DD000300B7'
    where i.invoicetype = 'Invoice'
      and i.invoicestatusid <> '8ACBC9AB-0298-43E1-85C7-DDE861F8B32C'
      and i.isrowdeleted = false
      and o.id is not null
    group by o.id, o.externalid, ic.shortcode, ia.description
),

revenue_extracharges as (
    select
        orderguid,
        orderno,
        currency,
        chargecode,
        sum(case when source = 'ORDER'  then totalcharges end) as totalcharges_order,
        sum(case when source = 'MANUAL' then totalcharges end) as totalcharges_manual
    from raw_revenue_extracharges
    where chargecode is not null   -- jsonb_object_agg errors on a null key
    group by orderguid, orderno, currency, chargecode
),

by_currency as (
    select
        orderguid,
        orderno,
        currency,
        sum(totalcharges_order)  as totalcharges_order,
        sum(totalcharges_manual) as totalcharges_manual,
        jsonb_object_agg(chargecode, totalcharges_order)  as orderextracharge_details,
        jsonb_object_agg(chargecode, totalcharges_manual) as manualextracharge_details
    from revenue_extracharges
    group by orderguid, orderno, currency
),

nested as (
    select
        orderguid,
        orderno,
        sum(totalcharges_order)  as totalcharges_order,
        sum(totalcharges_manual) as totalcharges_manual,
        jsonb_object_agg(currency, orderextracharge_details)  as orderextracharge_details,
        jsonb_object_agg(currency, manualextracharge_details) as manualextracharge_details
    from by_currency
    where currency is not null
    group by orderguid, orderno
)

select
    orderguid,
    orderno,
    case when totalcharges_order  is not null
         then orderextracharge_details  end as orderextracharge_details,
    case when totalcharges_manual is not null
         then manualextracharge_details end as manualextracharge_details
from nested
  );
  