
-- =============================================================================
-- Port of: the ADJ_BY_INVOICE + RAW_MANUAL + MANUAL CTEs inside
--          ORDERCHARGES_WITHADJUSTMENT_VW
--
-- Manually raised invoices, pivoted into per-currency columns.
-- Currency short codes: C = CAD, U = USD, P = MXN.
--
-- POSTGRES PORT NOTES:
--   * ZEROIFNULL(x)   -> coalesce(x, 0)              (done)
--   * BOOLOR_AGG(x)   -> bool_or(x)                  (done)
--   * IFF(a, b, c)    -> case when a then b else c   (done)
--   * GROUP BY ALL    -> explicit column list        (done)
-- =============================================================================

with adj_by_invoice as (
    select
        invoiceid,
        sum(totalcharge)              as adj_charge,
        sum(coalesce(taxamount, 0))   as adj_tax
    from "test"."invoicesvc"."invoiceadjustment"
    where isrowdeleted = false
      and invoiceadjustmentreasonid = '056CD084-9779-4BC6-B138-675AF9718760'
    group by 1
),

raw_manual as (
    select
        o.id          as orderguid,
        o.externalid  as orderno,
        ic.shortcode  as currency,
        sum(i.totalamount - coalesce(i.taxamount, 0)
            + coalesce(adj.adj_charge, 0))                       as manualchargesnotax,
        sum(coalesce(i.taxamount, 0) + coalesce(adj.adj_tax, 0)) as manualchargetax,
        sum(i.totalamount + coalesce(adj.adj_charge, 0)
            + coalesce(adj.adj_tax, 0))                          as manualtotalcharges,
        bool_or(
            case when coalesce(adj.adj_charge, 0) + coalesce(adj.adj_tax, 0) = 0
                 then false else true end
        )                                                        as manualadjustmentflag
    from "test"."invoicesvc"."invoice" i
    left join adj_by_invoice adj
           on adj.invoiceid = i.id
    left join "test"."invoicesvc"."invoiceorderrel" ior
           on ior.invoiceid = i.id and ior.isrowdeleted = false
    left join "test"."invoicesvc"."currency" ic
           on ic.id = i.currencyid
    left join "test"."probillsvc"."order" o
           on o.id = ior.orderid
          and o.isrowdeleted = false
          and o.orderstatusid <> 'ABD88AC0-5970-40DA-8382-53DD000300B7'
    where i.invoicetype = 'Invoice'
      and i.invoicestatusid <> '8ACBC9AB-0298-43E1-85C7-DDE861F8B32C'
      and i.isrowdeleted = false
      and o.id is not null
    group by 1, 2, 3
)

select
    orderguid,
    orderno,
    sum(case when currency = 'P' then round(coalesce(manualchargesnotax, 0), 2) end) as manualchargesnotaxmxn,
    sum(case when currency = 'C' then round(coalesce(manualchargesnotax, 0), 2) end) as manualchargesnotaxcad,
    sum(case when currency = 'U' then round(coalesce(manualchargesnotax, 0), 2) end) as manualchargesnotaxusd,
    sum(case when currency = 'P' then round(coalesce(manualchargetax, 0), 2) end)    as manualchargetaxmxn,
    sum(case when currency = 'C' then round(coalesce(manualchargetax, 0), 2) end)    as manualchargetaxcad,
    sum(case when currency = 'U' then round(coalesce(manualchargetax, 0), 2) end)    as manualchargetaxusd,
    sum(case when currency = 'P' then round(coalesce(manualtotalcharges, 0), 2) end) as manualtotalchargesmxn,
    sum(case when currency = 'C' then round(coalesce(manualtotalcharges, 0), 2) end) as manualtotalchargescad,
    sum(case when currency = 'U' then round(coalesce(manualtotalcharges, 0), 2) end) as manualtotalchargesusd,
    bool_or(manualadjustmentflag)                                                    as manualadjustmentflag
from raw_manual
group by 1, 2