
-- =============================================================================
-- Port of: the ADJUSTMENT CTE inside ORDERCHARGES_WITHADJUSTMENT_VW
--
-- Billable invoice adjustments, classified into FRT / FSC / EXTRA.
-- The classification falls back to keyword matching on the charge code and
-- description when ORDERCHARGETYPE has no row - that fallback is repeated three
-- times in the original view; here it is computed once in `classified`.
-- =============================================================================

with classified as (
    select
        ia.orderid                    as orderguid,
        o.externalid                  as orderno,
        o.currency,
        ia.totalcharge,
        coalesce(ia.taxamount, 0)     as taxamount,
        coalesce(
            oct.chargetype,
            case
                when ia.chargecode  ilike '%FRT%'
                  or ia.chargecode  ilike '%FREIGHT%'
                  or ia.description ilike '%SERVICIOS%' then 'Freight Rate'
                when ia.chargecode  ilike '%FSC%'
                  or ia.chargecode  ilike '%FUEL%'      then 'Fuel Surcharge'
                else 'Extra Charge'
            end
        )                             as chargetype
    from "test"."invoicesvc"."invoiceadjustment" ia
    left join "test"."invoicesvc"."invoice" iv
           on ia.invoiceid = iv.id
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
      and ia.isrowdeleted = false
)

select
    orderguid,
    orderno,
    currency,
    sum(totalcharge)                as totalchargesnotax,
    sum(taxamount)                  as taxamount,
    sum(totalcharge + taxamount)    as totalcharges,
    sum(case when chargetype = 'Freight Rate'   then totalcharge else 0 end) as frt,
    sum(case when chargetype = 'Fuel Surcharge' then totalcharge else 0 end) as fsc,
    sum(case when chargetype = 'Extra Charge'   then totalcharge else 0 end) as extra
from classified
group by 1, 2, 3