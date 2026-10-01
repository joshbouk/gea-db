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
| Policies | 30 |

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

Both need `openpyxl` and `python-docx`. Source workbooks live in the Assessment
Playbook folder.

## Known drift

The live database carries **46 policies against this repository's 30**. Sixteen
`*_read_authenticated` policies were added outside the migration set in response
to a Supabase security linter warning. Everything else — tables, columns,
constraints, triggers, enums and every reference row count — matches exactly.

Most of the sixteen are harmless and arguably an improvement: they grant read
access to Zone A reference data, which every consultant should see. One is not.
`client_read_authenticated` lets any authenticated user read every client company
name regardless of engagement membership, which contradicts the rule in `006`
that a user with no membership sees nothing.

Until that is resolved as a `015` migration, this repository does not reproduce
the live access control layer. Nothing else is outstanding.
