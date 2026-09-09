
  create view "test"."reporting_intermediate"."int_order_charges__dbt_tmp"
    
    
  as (
    
-- =============================================================================
-- Port of: the ORDERCHARGE CTE inside ORDERCHARGES_WITHADJUSTMENT_VW
--
-- Order-grain charges straight off the operational tables, with tax computed
-- from up to two tax items per charge (TAXITEM + TAXITEM2).
--
-- POSTGRES PORT NOTES:
--   * IFNULL      -> coalesce                 (done)
--   * GROUP BY ALL -> explicit column list    (done)
-- =============================================================================

with tax_rate as (
    -- Combined rate for a charge: primary tax item + optional second tax item.
    -- NEWRATE wins over CURRENTRATE when present.
    select
        oc.id as orderchargeid,
        coalesce(
            coalesce(ti.newrate, ti.currentrate)
            + coalesce(coalesce(ti2.newrate, ti2.currentrate), 0)
        , 0) as combined_rate
    from "test"."probillsvc".ordercharge oc
    left join "test"."probillsvc".taxcodes tc
           on tc.id = oc.taxcodeid and tc.isrowdeleted = false
    left join "test"."probillsvc".taxitems ti
           on ti.id = tc.taxitemid and ti.isrowdeleted = false
    left join "test"."probillsvc".taxitems ti2
           on tc.taxitem2id is not null
          and ti2.id = tc.taxitem2id and ti2.isrowdeleted = false
    where oc.isrowdeleted = false
)

select
    o.id                                as orderguid,
    o.externalid                        as orderno,
    o.ponumber,
    coalesce(ou.salesrep, sr.name, 'NONE') as salesrep,
    ou.spotbidlead,
    ou.accountmanager,
    ou.csr,
    o.currency,
    case when o.invoiceid is not null then 'INVOICED' else 'NOT INVOICED' end as invoicestatus,
    cast(i.invoiceddate as date)        as invoicedate,
    c.legalbusinessname                 as customer,
    os.name                             as orderstatus,

    sum(oc.totalcharges)                                    as totalchargesnotax,
    sum(oc.totalcharges * tr.combined_rate)                 as taxamount,
    sum(oc.totalcharges)
      + sum(oc.totalcharges * tr.combined_rate)             as totalcharges,

    sum(case when oct.chargetype = 'Freight Rate'   then oc.totalcharges else 0 end) as frt,
    sum(case when oct.chargetype = 'Fuel Surcharge' then oc.totalcharges else 0 end) as fsc,
    sum(case when oct.chargetype = 'Extra Charge'   then oc.totalcharges else 0 end) as extra

from "test"."probillsvc"."order" o
left join "test"."probillsvc".orderstatus os on os.id = o.orderstatusid
left join "test"."probillsvc".salesrep    sr on sr.id = o.salesrepfk
left join "test"."reporting_intermediate"."int_order_users"              ou on ou.orderguid = o.id
left join "test"."invoicesvc"."invoice"     i
       on i.id = o.invoiceid
      and i.isrowdeleted = false
      and i.invoicestatusid <> '8ACBC9AB-0298-43E1-85C7-DDE861F8B32C'
left join "test"."customersvc"."customer"   c  on c.id = o.customerid
left join "test"."probillsvc".ordercharge oc on oc.orderid = o.id and oc.isrowdeleted = false
left join "test"."probillsvc".orderchargetype oct
       on oct.id = oc.orderchargetypeid and oct.isrowdeleted = false
left join tax_rate tr on tr.orderchargeid = oc.id

where o.isrowdeleted = false
  and o.orderstatusid <> 'ABD88AC0-5970-40DA-8382-53DD000300B7'
  and o.externalid >= 10000000

group by
    o.id, o.externalid, o.ponumber,
    ou.salesrep, sr.name, ou.spotbidlead, ou.accountmanager, ou.csr,
    o.currency, o.invoiceid, i.invoiceddate,
    c.legalbusinessname, os.name
  );