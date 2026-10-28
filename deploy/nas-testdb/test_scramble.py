"""scramble.sql on a small made-up schema, in a real Postgres.

Needs psql and a database you may write to (a throw-away one):

    TEST_PG_URL=postgresql://postgres@localhost:5432/scratch pytest deploy/nas-testdb/test_scramble.py

Skipped when TEST_PG_URL isn't set. Everything is made in its own schema
and dropped afterwards.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

URL = os.environ.get("TEST_PG_URL", "")
HERE = Path(__file__).resolve().parent
pytestmark = pytest.mark.skipif(not URL or not shutil.which("psql"), reason="TEST_PG_URL and psql needed")

SCHEMA = "scramble_t"

SETUP = f"""
drop schema if exists {SCHEMA} cascade;
create schema {SCHEMA};
create table {SCHEMA}.profiles (id int primary key, name text, phone text unique, email text, ic text,
  address text, avatar_url text, birth_date date, display_id text, status text, lat double precision);
create table {SCHEMA}.partners (id int primary key, name text, phone text, ic text, plate varchar(10), status text);
-- Like 0185/0277: an approved partner's name can't change. Scrambling turns triggers off.
create function {SCHEMA}.guard() returns trigger language plpgsql as $$
begin
  if old.status = 'approved' and new.name is distinct from old.name then
    raise exception 'guarded';
  end if;
  return new;
end $$;
create trigger guard before update on {SCHEMA}.partners for each row execute function {SCHEMA}.guard();
create table {SCHEMA}.services (id int primary key, name text, image_url text);
create table {SCHEMA}.ride_requests (id int primary key, rider_name text, rider_phone text, pickup_address text,
  pickup_name text, ip_address inet, options jsonb, service text);
create table {SCHEMA}.ride_messages (id int primary key, body text, kind text);
create table {SCHEMA}.app_settings (key text primary key, value jsonb);
create table {SCHEMA}.report_mail (id int primary key, emails text[]);
create table {SCHEMA}.app_branding (id int primary key, splash_image_url text);
insert into {SCHEMA}.profiles values
  (1, 'Aina Binti Ali', '+60123456789', 'aina@mail.my', '900101-14-5566', '12 Jalan Ampang', 'avatars/1.jpg',
   '1990-05-17', 'R0001', 'active', 3.15),
  (2, 'Ben Tan', '+60129999999', null, '', 'Lot 5', null, null, 'R0002', 'active', 3.2);
insert into {SCHEMA}.partners values (1, 'Aina Binti Ali', '+60123456789', '900101-14-5566', 'WXY 1234', 'approved');
insert into {SCHEMA}.services values (1, 'Car', 'services/car.png');
insert into {SCHEMA}.ride_requests values
  (1, 'Aina', '+60123456789', '12 Jalan Ampang', 'KLCC', '203.0.113.9', '{{"pets": true}}', 'car');
insert into {SCHEMA}.ride_messages values (1, 'I am at the blue gate, my number is 0123456789', 'text');
insert into {SCHEMA}.app_settings values
  ('api_providers', '[{{"id": "aws", "services": [{{"id": "x", "keys": [{{"value": "AKIA:SECRET", "label": "main"}}]}}]}}]'),
  ('payments', '{{"fiuu": {{"merchantId": "m1", "secretKey": "s3cr3t", "verifyKey": "v1"}}, "on": true}}'),
  ('nas_testdb', '{{"refreshAt": "02:30"}}');
insert into {SCHEMA}.report_mail values (1, array['boss@mail.my', 'ops@mail.my']);
insert into {SCHEMA}.app_branding values (1, 'brand/splash.png');
"""


def psql(sql: str, *, scramble: bool = False) -> str:
    env = {**os.environ, "PGOPTIONS": f"-c getride.scramble_schemas={SCHEMA}"
           + (" -c getride.test_copy=yes" if scramble else "")}
    args = ["psql", URL, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"]
    args += ["-f", str(HERE / "scramble.sql")] if scramble else ["-c", sql]
    r = subprocess.run(args, env=env, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()


@pytest.fixture(scope="module")
def scrambled():
    psql(SETUP)
    psql("", scramble=True)
    yield
    psql(f"drop schema if exists {SCHEMA} cascade")


def one(sql: str) -> str:
    return psql(sql)


def test_refuses_outside_a_test_copy():
    with pytest.raises(RuntimeError, match="only runs on the test copy"):
        env = {**os.environ, "PGOPTIONS": "-c getride.scramble_schemas=nothing_here"}
        r = subprocess.run(["psql", URL, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(HERE / "scramble.sql")],
                           env=env, capture_output=True, text=True, check=False)
        if r.returncode != 0:
            raise RuntimeError(r.stderr)


def test_people_are_scrambled(scrambled):
    name, phone, email, ic, address, avatar, born = one(
        f"select concat_ws('|', name, phone, email, ic, address, avatar_url, birth_date) from {SCHEMA}.profiles where id = 1"
    ).split("|")
    assert name.startswith("Test ") and "Aina" not in name
    assert phone.startswith("+601") and len(phone) == 14 and phone != "+60123456789"
    assert email.endswith("@example.invalid")
    assert ic.startswith("TEST") and "900101" not in ic
    assert address.startswith("Test address ")
    assert avatar.startswith("scrambled/") and avatar.endswith(".jpg")
    assert born == "1990-01-01"


def test_same_value_same_result_everywhere(scrambled):
    assert one(f"select p.phone = r.phone and p.ic = r.ic and p.name = r.name from {SCHEMA}.profiles p, "
               f"{SCHEMA}.partners r where p.id = 1 and r.id = 1") == "t"
    assert one(f"select (select phone from {SCHEMA}.profiles where id = 1) = rider_phone from {SCHEMA}.ride_requests") == "t"
    assert one(f"select count(distinct phone) from {SCHEMA}.profiles") == "2", "still unique"


def test_guarded_partner_and_short_columns(scrambled):
    assert one(f"select name like 'Test %' and plate like 'TST%' and length(plate) <= 10 from {SCHEMA}.partners") == "t"


def test_rides_messages_and_lists(scrambled):
    row = one(f"select concat_ws('|', rider_name, pickup_address, pickup_name, host(ip_address), options::text, service) "
              f"from {SCHEMA}.ride_requests")
    rider, pickup, place, ip, options, service = row.split("|")
    assert rider.startswith("Test ") and pickup.startswith("Test address ") and place.startswith("Place ")
    assert ip.startswith("192.0.2.")
    assert options == '{"pets": true}' and service == "car", "settings and choices kept"
    assert one(f"select body from {SCHEMA}.ride_messages") == "[scrambled]"
    assert one(f"select bool_and(e like '%@example.invalid') from {SCHEMA}.report_mail, unnest(emails) e") == "t"


def test_kept_as_they_are(scrambled):
    assert one(f"select concat_ws('|', display_id, status, lat, email is null, ic) from {SCHEMA}.profiles where id = 2") \
        == "R0002|active|3.2|t|", "ids, statuses, coordinates, nulls and empty strings"
    assert one(f"select name || '|' || image_url from {SCHEMA}.services") == "Car|services/car.png", "catalogue names"
    assert one(f"select splash_image_url from {SCHEMA}.app_branding") == "brand/splash.png"


def test_secrets_blanked(scrambled):
    assert one(f"select value #>> '{{0,services,0,keys,0,value}}' from {SCHEMA}.app_settings where key = 'api_providers'") == ""
    assert one(f"select value #>> '{{0,services,0,keys,0,label}}' from {SCHEMA}.app_settings where key = 'api_providers'") == "main"
    pay = one(f"select concat_ws('|', value #>> '{{fiuu,merchantId}}', value #>> '{{fiuu,secretKey}}', "
              f"value #>> '{{fiuu,verifyKey}}', value ->> 'on') from {SCHEMA}.app_settings where key = 'payments'")
    assert pay == "m1|||true"
    assert one(f"select value ->> 'refreshAt' from {SCHEMA}.app_settings where key = 'nas_testdb'") == "02:30"


def test_triggers_back_on_after(scrambled):
    with pytest.raises(RuntimeError, match="guarded"):
        psql(f"update {SCHEMA}.partners set name = 'x' where id = 1")
