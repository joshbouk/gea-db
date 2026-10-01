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

Run in filename order, each once. Migrations are not idempotent; running one
twice raises a duplicate key or a duplicate object error.

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
| Tables / columns | 48 / 526 |
| Check constraints / foreign keys / uniques | 30 / 106 / 32 |
| Triggers in `public` / enum types | 27 / 36 |
| Policies | 74 |

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

### Testing it

```
pip install -r requirements.txt
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
