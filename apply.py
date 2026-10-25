"""Apply the migrations to a database, then prove they worked.

    pip install -r requirements.txt
    python apply.py                 apply what is pending, then verify
    python apply.py --verify-only   verify without applying anything
    python apply.py --dry-run       list what would be applied

Needs DATABASE_URL — the Supabase connection string for your project, from
Project Settings, Database, Connection string, URI. Keep it in your
environment, never in this repository.

    setx DATABASE_URL "postgresql://..."     Windows, then a new terminal
    export DATABASE_URL="postgresql://..."   macOS, Linux

Already-applied migrations are skipped, so running this twice is safe. It reads
gea_migration to decide, which is the record each migration writes about
itself. A migration missing from that table will be applied again, so never
remove a row from it by hand.

Each migration runs in its own transaction. If one fails, that one rolls back,
nothing after it runs, and the error is printed in full. Fix the cause rather
than editing a migration that has already been applied elsewhere.
"""
from __future__ import annotations

import os
import pathlib
import sys

import psycopg

ROOT = pathlib.Path(__file__).resolve().parent
MIGRATIONS = sorted((ROOT / "migrations").glob("*.sql"))
VERIFIERS = ["verify.sql", "verify_007.sql", "verify_seed.sql", "verify_014.sql",
             "verify_derived.sql"]
SUITES = [
    ("gea_verify", 28, "the database refuses bad data"),
    ("gea_verify_007", 6, "reference immutability and the cap model"),
    ("gea_verify_seed", 31, "the loaded data matches the instrument"),
    ("gea_verify_014", 12, "each activation check refuses its violation"),
    ("gea_verify_derived", 12, "no judgement outlives the evidence it was about"),
]


def applied_already(conn) -> set[str]:
    with conn.cursor() as cur:
        cur.execute("select to_regclass('public.gea_migration')")
        if cur.fetchone()[0] is None:
            return set()
        cur.execute("select filename from gea_migration")
        return {row[0] for row in cur.fetchall()}


def apply_migrations(conn, dry_run: bool) -> int:
    done = applied_already(conn)
    pending = [m for m in MIGRATIONS if m.name not in done]

    if not pending:
        print(f"  all {len(MIGRATIONS)} migrations already applied")
        return 0

    print(f"  {len(done)} applied, {len(pending)} pending")
    for path in pending:
        if dry_run:
            print(f"    would apply  {path.name}")
            continue
        try:
            with conn.transaction():
                conn.execute(path.read_text(encoding="utf-8"))
                # Recorded here, not left to the migration.
                #
                # Every migration is supposed to write its own row, and
                # one shipped without it. It ran, changed the database,
                # left no record, and the next run tried it again — where
                # it failed on a column it had itself created. A rule
                # every file must remember is a rule that will be
                # forgotten; doing it here means it cannot be.
                # Guarded, because the table that holds these records
                # is itself created by one of the early migrations.
                cur = conn.execute(
                    "select to_regclass('public.gea_migration')")
                if cur.fetchone()[0] is not None:
                    conn.execute(
                        "insert into gea_migration (filename, note) "
                        "values (%s, %s) on conflict do nothing",
                        (path.name, "Recorded by apply.py."))
            print(f"    applied      {path.name}")
        except Exception as exc:                               # noqa: BLE001
            print(f"\n  FAILED on {path.name}\n", file=sys.stderr)
            print(f"  {exc}\n", file=sys.stderr)
            print("  Nothing after this ran. That migration rolled back "
                  "cleanly, so the database is as it was before it started.",
                  file=sys.stderr)
            return 1
    return 0


def install_verifiers(conn) -> None:
    for name in VERIFIERS:
        conn.execute((ROOT / name).read_text(encoding="utf-8"))
    print(f"  {len(VERIFIERS)} verification suites installed")


def verify(conn) -> int:
    total = failed = 0
    print()
    for function, expected, description in SUITES:
        with conn.cursor() as cur:
            cur.execute(f"select rule, description, result from {function}()")
            rows = cur.fetchall()
        bad = [r for r in rows if r[2] != "pass"]
        total += len(rows)
        failed += len(bad)

        count = f"{len(rows) - len(bad)}/{len(rows)}"
        note = "" if len(rows) == expected else f"  (expected {expected} rules)"
        print(f"  {function:<18} {count:>7}   {description}{note}")
        for rule, desc, result in bad:
            print(f"      FAIL  {rule}  {desc}")
            print(f"            {result}")

    print(f"\n  {total - failed}/{total} rules pass")
    return 1 if failed else 0


def shape(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("""
          select
            (select count(*) from information_schema.tables
              where table_schema='public' and table_type='BASE TABLE'),
            (select count(*) from pg_constraint
              where contype='c' and connamespace='public'::regnamespace),
            (select count(*) from pg_trigger t
               join pg_class c on c.oid=t.tgrelid
               join pg_namespace n on n.oid=c.relnamespace
              where not t.tgisinternal and n.nspname='public'),
            (select count(*) from pg_policies where schemaname='public'),
            (select count(*) from element e
               join instrument_version iv on iv.id = e.instrument_version_id
              where iv.status = 'active'),
            (select count(*) from anchor a
               join element e on e.id = a.element_id
               join instrument_version iv on iv.id = e.instrument_version_id
              where iv.status = 'active'),
            (select string_agg(label || ' (' || status || ')', ', '
                               order by label)
               from instrument_version)
        """)
        t, c, g, p, e, a, iv = cur.fetchone()
    print(f"\n  {t} tables, {c} checks, {g} triggers, {p} policies")
    print(f"  instruments: {iv}")
    print(f"  the active one has {e} elements and {a} anchors")


def main() -> int:
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        print("DATABASE_URL is not set. See the comment at the top of this "
              "file.", file=sys.stderr)
        return 1

    verify_only = "--verify-only" in sys.argv
    dry_run = "--dry-run" in sys.argv

    with psycopg.connect(dsn, autocommit=True) as conn:
        if not verify_only:
            print("Migrations")
            if apply_migrations(conn, dry_run):
                return 1
            if dry_run:
                return 0
            install_verifiers(conn)

        print("\nVerification")
        result = verify(conn)
        shape(conn)

    if result:
        print("\n  Something is wrong. Do not build on this until it passes.")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
