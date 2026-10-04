# gea-db

The database behind the Blend Growth Engineering Assessment. Schema, methodology
reference data, and the verification suites that prove both.

Two codebases share this database and neither owns it: the Lovable application
(screens, CRUD, access control) and the Python analysis service (every computed
figure). They communicate through the `analysis_run` table and nothing else.
That is why the migrations live here rather than in either repository.

## The point of this repository

The database enforces the methodology. A score cannot exceed a cap, Not Evidenced
cannot be recorded where the instrument forbids it, an activated instrument
version cannot be edited, and a final score cannot cite a run nobody accepted.
Those constraints are not defensive programming, they are the product. An
assessment is worth paying for because its conclusions can be traced back to
evidence, and the constraints are what make that true when nobody is watching.

**Never weaken a constraint to make a feature work.** If a change appears to
require it, the change is wrong. Read every migration before running it.

## Applying from empty

```
pip install -r requirements.txt
python apply.py
```

`requirements.txt` holds only what applying and verifying needs, so it installs
anywhere. `requirements-dev.txt` adds the local test harness and the seed
generators; its `pgserver` dependency publishes no Windows wheel, so on Windows
run the access tests under WSL or against a scratch Supabase project.

It applies whatever is pending, installs the four verification suites and runs
them. Expect **77/77**, 48 tables, 30 checks, 28 triggers, 75 policies, and
instrument v0.6 in draft with 48 elements and 288 anchors.

Running it twice is safe: it reads `gea_migration` to decide what is pending.
`--dry-run` lists what it would do; `--verify-only` checks a database without
touching it.

Each migration runs in its own transaction, so a failure rolls that one back
and stops. Never edit a migration that has already been applied somewhere —
write the next one.

Needs `DATABASE_URL`. Get it from the **Connect** button at the top of the
Supabase project page. Take **Direct connection** where it works; on an
IPv4-only network that hostname will not resolve at all, and **Session pooler**
is the one to use — same port, different host, and it holds a real session so
transactions and `set local` behave normally.

### By hand

Where a SQL editor is all you have, run these in filename order, each once.
Migrations are not idempotent; running one twice raises a duplicate key or
duplicate object error.

| File | What it does |
|---|---|
| `001_foundation.sql` | extensions, auth compatibility, helper functions |
| `002_zone_a_reference.sql` | methodology reference tables |
| `003_zone_b_c.sql` | engagement, evidence and analysis tables |
| `004_zone_d_e.sql` | scoring and output tables |
| `005_triggers.sql` | the ten cross-table rules |
| `006_rls.sql` | row-level security |
| `007_zone_a_additions.sql` | cap model, analysis field requirements, trigger coverage |
| `008_seed_instrument.sql` | instrument v0.6, 48 elements, 288 anchors |
| `009_seed_fields.sql` | 123 canonical fields, 12 cap rules, 122 analysis requirements |
| `010_seed_exports.sql` | 24 export lines, coverage map, 21 answer engine templates |
| `011_seed_interviews.sql` | 7 guides, 116 questions, 197 element links |
| `012_seed_requirements.sql` | 171 evidence requirements |
| `013_seed_prompts.sql` | 25 prompts, 16 measurement definitions |
| `014_activation_gate.sql` | the seven activation checks, enforced as a trigger |
| `015_migration_log.sql` | the applied-migration log, with 001 to 014 backfilled |
| `016_read_all_write_members.sql` | read for every Blend user, write for assigned members |
| `017_auth_bridge.sql` | Entra identities become Blend users on first sign-in |
| `018_run_enqueue.sql` | idempotent enqueue, realtime, stall detection |
| `019_run_claim.sql` | workers claim queued runs without colliding |

Then the four verification suites, which only define functions and can be
re-run at any time:

```
verify.sql        verify_007.sql        verify_seed.sql        verify_014.sql
```

## Proving it worked

```sql
select * from gea_verify();        -- 28 rules: the database refuses bad data
select * from gea_verify_007();    --  6 rules: reference immutability, cap model
select * from gea_verify_seed();   -- 31 rules: the loaded data matches the instrument
select * from gea_verify_014();    -- 12 rules: each activation check refuses its violation
```

**77 rules. Every row must read `pass`.** A failure means the change that
preceded it is wrong, not that the rule needs adjusting.

Expected shape after a clean run:

| | |
|---|---|
| Tables / columns | 48 / 528 |
| Check constraints / foreign keys / uniques | 30 / 106 / 32 |
| Triggers in `public` / enum types | 28 / 36 |
| Policies | 75 |

`gea_verify()` and `gea_verify_014()` write and roll back throwaway fixtures.
They are safe to run against a populated database and leave nothing behind.

## Activation

Instrument `v0.6` seeds as **draft** and stays there deliberately. Activation
makes it immutable and binds every engagement that pins it; correcting anything
afterwards means a v0.7 plus a declared change type on every element that moved.

```sql
select * from gea_activation_failures(
  (select id from instrument_version where label = 'v0.6'));
```

An empty result means it is ready. Immediately after seeding this returns 25
rows, all check A5: the prompts are still draft and the gate requires every
prompt referenced by a step to have an active version.

Activate through the wrapper, which returns a readable result rather than
raising:

```sql
select * from gea_activate_instrument('v0.6');
```

The wrapper is a convenience. The gate itself is a trigger on
`instrument_version`, so writing the `UPDATE` by hand hits it too.

## What has been applied

```sql
select filename, applied_at::date, note from gea_migration order by filename;
```

`supabase_migrations.schema_migrations` is Supabase's own table and pairs with
files in the Lovable repository's `supabase/migrations/` folder. It holds only
001 to 006 and will not be added to, because these migrations deliberately do
not live there. `gea_migration` is the record for this repository.

**Every migration ends with its own insert into `gea_migration`.** One that does
not log itself is incomplete.

## Handing work to the analysis service

The application and the Python analysis service share this database and talk
only through `analysis_run`. There is no HTTP between them.

```sql
select * from gea_enqueue_run(
  p_engagement => '...', p_job_type => 'parse',
  p_artefact_ids => array['...']::uuid[], p_hashes => array['sha256...']);
```

It returns the run whether it created one or found an identical one already
queued, so two people clicking the same button produce one run. Callers never
compute the idempotency key: it is a generated column, so it cannot be computed
two slightly different ways by two screens.

The key covers the engagement, the job type, the prompt version, the input
hashes sorted, and the parameters. **The contract document omits the job type
and the engagement.** Following it literally, `parse` and `profile` on the same
uploaded file — both with no prompt and no parameters — produce the same key,
and the second job is refused as a duplicate of the first. Those two run back to
back on every upload.

`analysis_run` is in the `supabase_realtime` publication, so a browser
subscription receives status and progress. Without that the subscription
connects successfully and receives nothing, which is worth knowing because it
looks like working code.

Read `analysis_run_state` rather than the table where a screen shows progress:
it adds `is_stalled` (running, but no heartbeat for ten minutes) and
`progress_percent`. The threshold is defined once there rather than invented per
screen.

## Regenerating the seed

`008` to `013` are generated, not hand-written. Re-run the generators after any
workbook change rather than editing the SQL:

- `build_question_map.py` reads the interview guides document by paragraph style
  and writes the question map workbook. The document owns the questions; the
  script owns the element mapping. Neither is derived from the other.
- `build_seed.py` reads the six reference workbooks plus the question map and
  writes `008` to `013`.

Both need `openpyxl` and `python-docx`, which are in `requirements.txt`. Source
workbooks live in the Assessment Playbook folder.

## Access control

    read   any active Blend user, on every engagement
    write  the consultants assigned to that engagement
    raw    members with can_view_raw_data

Blend is a small team and a consultant learning from a finished assessment is
the point of keeping a library of them, so reading is open across engagements.
`engagement_member` decides who can change a project, not who can see one.

**Raw client exports are the exception.** `artefact`, `dataset` and
`dataset_field_profile` hold the client's own CRM extract — deal records,
contact names, email addresses. Blend processes that under the contract with
that client for that assessment, which is not a basis for showing it to every
consultant on the platform. A migration that adds a read-all policy to one of
those three is undoing a decision, not extending one.

"Any Blend user" means an active row in `app_user`, not anyone holding a token.
Deactivating someone who has left revokes their reads even while their SSO
identity still resolves.

### Signing in

Authentication is Entra ID through Supabase Auth. There are no local accounts
and no password column anywhere.

A person cannot be provisioned before they first sign in, because
`app_user.auth_subject` is not null and nothing knows their Supabase identity
until it exists. So a trigger on `auth.users` creates the `app_user` row on
first sign-in, taking the display name from the Entra claim and falling back to
the local part of the address.

- The address must end `@blendb2b.com`. The Entra tenant already restricts who
  can authenticate; this makes a misconfigured provider fail loudly instead of
  quietly admitting someone.
- **The first person to sign in becomes an admin.** Everyone after is a Growth
  Consultant until an admin says otherwise. Without that bootstrap nobody can
  promote anybody and there is no way into the application.
- An identity rebuilt in Entra re-points the existing row by email rather than
  failing on the unique constraint, so nobody loses their history.
- The last active admin cannot be demoted or deactivated.

Admins maintain the directory. Deactivating someone revokes every read
immediately, because `app_is_blend_user()` requires an active row.

### Testing it

```
pip install -r requirements-dev.txt
python3 rls_test.py     # 25 checks
```

`harness.py` stands up a throwaway PostgreSQL 16 under `.pgdata/`, applies every
migration in order and hands back a connection. `rls_test.py` uses it; so does
anything else that needs a disposable database. Paths resolve relative to the
repository, so it runs from wherever this is checked out. Set `GEA_PGDATA` to
put the scratch database somewhere else.

`.pgdata/` is scratch and belongs in `.gitignore`.

This connects as a Postgres role that is a member of `authenticated`, which is
the role Supabase puts a signed-in user into. An earlier version of the file
connected as an unrelated role, so every policy written `to authenticated` was
silently skipped: the suite reported 15/15 while a user on no engagement could
read every client record. **If that grant is ever removed these tests go green
while testing nothing.**

The write checks count rows actually changed rather than watching for an
exception, because a policy that hides a row also makes an `UPDATE` against it
match nothing — the statement then succeeds having done nothing, and testing for
an error reports success on a write that was in fact prevented.
