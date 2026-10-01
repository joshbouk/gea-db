"""Access control verification.

Proves the policies filter the way the access model says they do:

    read   any active Blend user, on every engagement
    write  the consultants assigned to that engagement
    raw    members with can_view_raw_data

The earlier version of this file connected as a Postgres role called
`rls_user`. Supabase puts a signed-in user into a role called `authenticated`,
and a policy written `to authenticated` never evaluates for anything else. So
sixteen policies on this database were invisible to the suite: it reported
15/15 while a user on no engagement could read every client record.

The test role is now a member of `authenticated`. If that grant is ever removed
these tests will go green while testing nothing, which is the failure mode worth
remembering about this file.

Run:  python3 rls_test.py
Exit: 0 if every check passes, 1 otherwise.
"""
import sys
from harness import connect, rebuild, seed

GA      = '44444444-4444-4444-4444-444444444441'  # lead architect, raw access
OBS     = '44444444-4444-4444-4444-444444444443'  # member, raw access denied
OUTSIDE = '44444444-4444-4444-4444-444444444449'  # active Blend user, not on it
LAPSED  = '44444444-4444-4444-4444-444444444448'  # app_user row, is_active false
NOBODY  = '00000000-0000-0000-0000-000000000000'  # token, no app_user row

ENGAGEMENT = '66666666-6666-6666-6666-666666666666'


def as_user(conn, sub, sql, fetch=True):
    """Run sql as a signed-in Blend user, the way Supabase would."""
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("select set_config('request.jwt.claim.sub', %s, true)", (sub,))
            cur.execute("select set_config('request.jwt.claim.role','authenticated', true)")
            cur.execute("set local role rls_user")
            cur.execute(sql)
            rows = cur.fetchall() if fetch else []
            cur.execute("reset role")
    return rows


def setup(conn):
    conn.execute("""
      do $$ begin
        if not exists (select 1 from pg_roles where rolname='rls_user') then
          create role rls_user;
        end if;
      end $$;

      grant usage on schema public to rls_user, authenticated;
      grant select, insert, update, delete on all tables in schema public
        to rls_user, authenticated;
      grant execute on all functions in schema public to rls_user, authenticated;
      grant usage on schema auth to rls_user, authenticated;
      grant execute on all functions in schema auth to rls_user, authenticated;

      -- Supabase puts a signed-in user in this role. Without the grant, every
      -- policy written `to authenticated` is silently skipped.
      grant authenticated to rls_user;

      -- a member who may not see raw client data
      insert into engagement_member (engagement_id, app_user_id, engagement_role,
                                     can_view_raw_data)
        values ('66666666-6666-6666-6666-666666666666',
                '33333333-3333-3333-3333-333333333333','observer', false);

      -- an active Blend user on no engagement at all
      insert into app_user (id, auth_subject, email, display_name, org_role)
        values ('33333333-3333-3333-3333-333333333339',
                '44444444-4444-4444-4444-444444444449',
                'outsider@blend.test','Outsider','gc');

      -- someone who has left: the identity resolves, the row is inactive
      insert into app_user (id, auth_subject, email, display_name, org_role, is_active)
        values ('33333333-3333-3333-3333-333333333338',
                '44444444-4444-4444-4444-444444444448',
                'lapsed@blend.test','Lapsed','gc', false);

      insert into artefact (engagement_id, kind, original_filename, storage_path, sha256)
        values ('66666666-6666-6666-6666-666666666666',
                'raw_export','deals.csv','p/1','h1');
    """)


def main():
    db, conn = connect()
    conn.autocommit = True
    rebuild(conn)
    seed(conn)
    setup(conn)

    checks = []

    def reads(name, sql, sub, want):
        try:
            got = len(as_user(conn, sub, sql))
        except Exception:
            got = 'denied'
        checks.append((name, str(got), str(want), got == want))

    def writes(name, sql, sub, should_work):
        """Count rows actually changed.

        A policy that hides a row also makes an UPDATE against it match
        nothing. The statement then succeeds having done nothing, so testing
        for an exception reports 'allowed' on a write that was in fact
        prevented. Only the row count distinguishes the two."""
        try:
            n = as_user(conn, sub, sql + ' returning 1')
            got = 'wrote %d' % len(n)
            ok = (len(n) > 0) == should_work
        except Exception:
            got = 'refused'
            ok = not should_work
        want = 'writes' if should_work else 'no write'
        checks.append((name, got, want, ok))

    # --- an assigned member ------------------------------------------------
    reads("member reads the engagement",      "select id from engagement",   GA, 1)
    reads("member reads its scores",          "select id from score",        GA, 1)
    reads("member reads its artefacts",       "select id from artefact",     GA, 1)
    reads("member reads its runs",            "select id from analysis_run", GA, 3)
    writes("member can write a task",
           "insert into task (engagement_id, step_ref, title, task_type) values "
           "('%s','1.1','written by a member','setup')" % ENGAGEMENT, GA, True)

    # --- a member without raw access ---------------------------------------
    reads("no-raw member reads scores",       "select id from score",        OBS, 1)
    reads("no-raw member denied artefacts",   "select id from artefact",     OBS, 0)
    reads("no-raw member denied datasets",    "select id from dataset",      OBS, 0)
    writes("no-raw member can still write a task",
           "insert into task (engagement_id, step_ref, title, task_type) values "
           "('%s','1.2','written by an observer','setup')" % ENGAGEMENT, OBS, True)

    # --- a Blend user on no engagement: reads everything, writes nothing ---
    reads("outsider reads the engagement",    "select id from engagement",   OUTSIDE, 1)
    reads("outsider reads its scores",        "select id from score",        OUTSIDE, 1)
    reads("outsider reads its metrics",       "select id from metric",       OUTSIDE, 0)
    reads("outsider reads clients",           "select id from client",       OUTSIDE, 1)
    reads("outsider reads the instrument",    "select id from element",      OUTSIDE, 52)
    reads("outsider DENIED artefacts",        "select id from artefact",     OUTSIDE, 0)
    reads("outsider DENIED datasets",         "select id from dataset",      OUTSIDE, 0)
    writes("outsider cannot write a task",
           "insert into task (engagement_id, step_ref, title, task_type) values "
           "('%s','1.3','should not land','setup')" % ENGAGEMENT, OUTSIDE, False)
    writes("outsider cannot change a score",
           "update score set scoring_note = 'tampered'", OUTSIDE, False)
    writes("outsider cannot delete a score",
           "delete from score", OUTSIDE, False)

    # --- someone who has left Blend ----------------------------------------
    reads("deactivated user reads nothing",   "select id from engagement",   LAPSED, 0)
    reads("deactivated user reads no scores", "select id from score",        LAPSED, 0)
    reads("deactivated user reads no clients","select id from client",       LAPSED, 0)

    # --- a token with no Blend identity behind it --------------------------
    reads("unknown identity reads nothing",   "select id from engagement",   NOBODY, 0)
    reads("unknown identity reads no scores", "select id from score",        NOBODY, 0)
    reads("unknown identity reads no clients","select id from client",       NOBODY, 0)

    w = max(len(c[0]) for c in checks)
    print(f"{'CHECK':<{w}}  {'GOT':^8} {'WANT':^8}  RESULT")
    print("-" * (w + 30))
    bad = 0
    for name, got, want, ok in checks:
        if not ok:
            bad += 1
        print(f"{name:<{w}}  {got:^8} {want:^8}  {'pass' if ok else 'FAIL'}")
    print("-" * (w + 30))
    print(f"{len(checks) - bad}/{len(checks)} access checks pass")
    return 1 if bad else 0


if __name__ == '__main__':
    raise SystemExit(main())
