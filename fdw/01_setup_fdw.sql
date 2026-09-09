-- =============================================================================
-- postgres_fdw setup: give ONE database a read-only view of the eight service
-- databases the reporting layer needs.
--
-- WHY: each microservice owns its own AlloyDB database, and PostgreSQL cannot
-- join across databases. Foreign tables make the joins expressible in one
-- connection, which is what dbt and Cube need.
--
-- RUN AS: a superuser / alloydbsuperuser, connected to alloydb_bi_dev_01.
-- Run 00_prerequisites first (see fdw/README.md).
--
-- SURFACE: 23 tables out of ~1,000 across the eight databases. Nothing else is
-- exposed. All read-only.
--
-- Generated from the live catalog on 2026-09-09 - every table below was
-- confirmed to exist in public on its service database.
-- =============================================================================

\set ON_ERROR_STOP on

create extension if not exists postgres_fdw;

-- The service databases live on this same AlloyDB instance, and the foreign
-- servers connect FROM INSIDE it - so this stays the PRIVATE address even
-- though the instance now also has a public endpoint (34.130.23.251).
-- Using the public IP here would hairpin out and back for no reason, and
-- would make the whole federation depend on the authorized-networks
-- allowlist. External clients (Cube Cloud, laptops) use the public IP; the
-- database talking to itself does not.
\set svc_host '172.23.210.10'
\set svc_port '5432'

-- Credentials the foreign server uses to read the service databases. This is a
-- READ-ONLY service account - see README.md.
\set svc_user 'REPLACE_WITH_READONLY_USER'
\set svc_pass 'REPLACE_WITH_READONLY_PASSWORD'


-- -----------------------------------------------------------------------------
-- probillsvc  ->  alloydb_probillsvc_dev_01
-- 11 table(s), 265 columns
-- -----------------------------------------------------------------------------
drop server if exists srv_probillsvc cascade;
create server srv_probillsvc
  foreign data wrapper postgres_fdw
  options (host :'svc_host', port :'svc_port', dbname 'alloydb_probillsvc_dev_01',
           -- keep the remote planner informed; without this FDW joins are poor
           use_remote_estimate 'true', fetch_size '10000');

create user mapping for bi_dbt
  server srv_probillsvc
  options (user :'svc_user', password :'svc_pass');

create schema if not exists probillsvc authorization bi_dbt;

import foreign schema public
  limit to ("order", ordercharge, orderchargetype, orderstatus, orderuser, pickdeldates, po, probill, salesrep, taxcodes, taxitems)
  from server srv_probillsvc into probillsvc;

grant usage on schema probillsvc to bi_dbt;
grant select on all tables in schema probillsvc to bi_dbt;

-- -----------------------------------------------------------------------------
-- invoicesvc  ->  alloydb_invoicesvc_dev_01
-- 5 table(s), 108 columns
-- -----------------------------------------------------------------------------
drop server if exists srv_invoicesvc cascade;
create server srv_invoicesvc
  foreign data wrapper postgres_fdw
  options (host :'svc_host', port :'svc_port', dbname 'alloydb_invoicesvc_dev_01',
           -- keep the remote planner informed; without this FDW joins are poor
           use_remote_estimate 'true', fetch_size '10000');

create user mapping for bi_dbt
  server srv_invoicesvc
  options (user :'svc_user', password :'svc_pass');

create schema if not exists invoicesvc authorization bi_dbt;

import foreign schema public
  limit to (currency, invoice, invoiceadjustment, invoicecharge, invoiceorderrel)
  from server srv_invoicesvc into invoicesvc;

grant usage on schema invoicesvc to bi_dbt;
grant select on all tables in schema invoicesvc to bi_dbt;

-- -----------------------------------------------------------------------------
-- customersvc  ->  alloydb_customersvc_dev_01
-- 1 table(s), 65 columns
-- -----------------------------------------------------------------------------
drop server if exists srv_customersvc cascade;
create server srv_customersvc
  foreign data wrapper postgres_fdw
  options (host :'svc_host', port :'svc_port', dbname 'alloydb_customersvc_dev_01',
           -- keep the remote planner informed; without this FDW joins are poor
           use_remote_estimate 'true', fetch_size '10000');

create user mapping for bi_dbt
  server srv_customersvc
  options (user :'svc_user', password :'svc_pass');

create schema if not exists customersvc authorization bi_dbt;

import foreign schema public
  limit to (customer)
  from server srv_customersvc into customersvc;

grant usage on schema customersvc to bi_dbt;
grant select on all tables in schema customersvc to bi_dbt;

-- -----------------------------------------------------------------------------
-- usersvc  ->  alloydb_usersvc_dev_01
-- 1 table(s), 13 columns
-- -----------------------------------------------------------------------------
drop server if exists srv_usersvc cascade;
create server srv_usersvc
  foreign data wrapper postgres_fdw
  options (host :'svc_host', port :'svc_port', dbname 'alloydb_usersvc_dev_01',
           -- keep the remote planner informed; without this FDW joins are poor
           use_remote_estimate 'true', fetch_size '10000');

create user mapping for bi_dbt
  server srv_usersvc
  options (user :'svc_user', password :'svc_pass');

create schema if not exists usersvc authorization bi_dbt;

import foreign schema public
  limit to ("user")
  from server srv_usersvc into usersvc;

grant usage on schema usersvc to bi_dbt;
grant select on all tables in schema usersvc to bi_dbt;

-- -----------------------------------------------------------------------------
-- trailersvc  ->  alloydb_trailersvc_dev_01
-- 1 table(s), 8 columns
-- -----------------------------------------------------------------------------
drop server if exists srv_trailersvc cascade;
create server srv_trailersvc
  foreign data wrapper postgres_fdw
  options (host :'svc_host', port :'svc_port', dbname 'alloydb_trailersvc_dev_01',
           -- keep the remote planner informed; without this FDW joins are poor
           use_remote_estimate 'true', fetch_size '10000');

create user mapping for bi_dbt
  server srv_trailersvc
  options (user :'svc_user', password :'svc_pass');

create schema if not exists trailersvc authorization bi_dbt;

import foreign schema public
  limit to (trailertype)
  from server srv_trailersvc into trailersvc;

grant usage on schema trailersvc to bi_dbt;
grant select on all tables in schema trailersvc to bi_dbt;

-- -----------------------------------------------------------------------------
-- fleetsvc  ->  alloydb_fleetsvc_dev_01
-- 2 table(s), 78 columns
-- -----------------------------------------------------------------------------
drop server if exists srv_fleetsvc cascade;
create server srv_fleetsvc
  foreign data wrapper postgres_fdw
  options (host :'svc_host', port :'svc_port', dbname 'alloydb_fleetsvc_dev_01',
           -- keep the remote planner informed; without this FDW joins are poor
           use_remote_estimate 'true', fetch_size '10000');

create user mapping for bi_dbt
  server srv_fleetsvc
  options (user :'svc_user', password :'svc_pass');

create schema if not exists fleetsvc authorization bi_dbt;

import foreign schema public
  limit to (jurisdiction, location)
  from server srv_fleetsvc into fleetsvc;

grant usage on schema fleetsvc to bi_dbt;
grant select on all tables in schema fleetsvc to bi_dbt;

-- -----------------------------------------------------------------------------
-- tripsvc  ->  alloydb_tripsvc_dev_01
-- 1 table(s), 31 columns
-- -----------------------------------------------------------------------------
drop server if exists srv_tripsvc cascade;
create server srv_tripsvc
  foreign data wrapper postgres_fdw
  options (host :'svc_host', port :'svc_port', dbname 'alloydb_tripsvc_dev_01',
           -- keep the remote planner informed; without this FDW joins are poor
           use_remote_estimate 'true', fetch_size '10000');

create user mapping for bi_dbt
  server srv_tripsvc
  options (user :'svc_user', password :'svc_pass');

create schema if not exists tripsvc authorization bi_dbt;

import foreign schema public
  limit to (tripevent)
  from server srv_tripsvc into tripsvc;

grant usage on schema tripsvc to bi_dbt;
grant select on all tables in schema tripsvc to bi_dbt;

-- -----------------------------------------------------------------------------
-- addresssvc  ->  alloydb_addresssvc_dev_01
-- 1 table(s), 31 columns
-- -----------------------------------------------------------------------------
drop server if exists srv_addresssvc cascade;
create server srv_addresssvc
  foreign data wrapper postgres_fdw
  options (host :'svc_host', port :'svc_port', dbname 'alloydb_addresssvc_dev_01',
           -- keep the remote planner informed; without this FDW joins are poor
           use_remote_estimate 'true', fetch_size '10000');

create user mapping for bi_dbt
  server srv_addresssvc
  options (user :'svc_user', password :'svc_pass');

create schema if not exists addresssvc authorization bi_dbt;

import foreign schema public
  limit to (traveltime)
  from server srv_addresssvc into addresssvc;

grant usage on schema addresssvc to bi_dbt;
grant select on all tables in schema addresssvc to bi_dbt;


-- -----------------------------------------------------------------------------
-- Where dbt writes. The service schemas above are read-only foreign tables;
-- these three are real local tables owned by dbt.
-- -----------------------------------------------------------------------------
create schema if not exists reporting    authorization bi_dbt;
create schema if not exists intermediate authorization bi_dbt;
create schema if not exists marts        authorization bi_dbt;

-- -----------------------------------------------------------------------------
-- Verify: expect 23 rows, and every count(*) to succeed.
-- -----------------------------------------------------------------------------
select foreign_table_schema, foreign_table_name
from information_schema.foreign_tables
order by 1, 2;
