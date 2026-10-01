"""GEA schema test harness.

Applies the migrations to a throwaway PostgreSQL 16 instance, then asserts every
methodology rule by attempting an operation that violates it.

A rule test has two halves:
  1. the violating operation must be rejected
  2. with the rule removed, the same operation must succeed
The second half is what proves the test is testing the rule rather than passing
for some unrelated reason.
"""
import pathlib, sys, os, glob, traceback
import pgserver, psycopg

# Paths resolve relative to this file, so the harness runs from wherever the
# repository is checked out rather than one person's machine.
ROOT = pathlib.Path(__file__).resolve().parent
DATA = pathlib.Path(os.environ.get('GEA_PGDATA', ROOT / '.pgdata'))
MIG = sorted(str(p) for p in (ROOT / 'migrations').glob('*.sql'))

if not MIG:
    raise SystemExit(f'No migrations found in {ROOT / "migrations"}')


def connect():
    db = pgserver.get_server(DATA)
    return db, psycopg.connect(db.get_uri(), autocommit=True)


def rebuild(conn, skip_rule=None):
    with conn.cursor() as cur:
        cur.execute("drop schema if exists public cascade; create schema public;")
        cur.execute("drop schema if exists auth cascade;")
    for f in MIG:
        sql = pathlib.Path(f).read_text()
        with conn.cursor() as cur:
            cur.execute(sql)
    if skip_rule:
        with conn.cursor() as cur:
            cur.execute(skip_rule)


def seed(conn):
    """Minimal fixture: one draft instrument, two elements, an engagement, a user."""
    with conn.cursor() as cur:
        cur.execute("""
        insert into instrument_version (id,label,status) values
          ('11111111-1111-1111-1111-111111111111','0.6-test','draft');

        insert into element (id,instrument_version_id,ref,kind,stage_code,name,
                             ne_permitted,tier_dependent)
        values
          ('22222222-2222-2222-2222-222222222221','11111111-1111-1111-1111-111111111111',
           '1.1','element','01','ICP definition', true, false),
          ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111',
           '2.3','element','02','Proof architecture', false, false),
          ('22222222-2222-2222-2222-222222222223','11111111-1111-1111-1111-111111111111',
           '2.5','element','02','Discovery quality', true, true),
          ('22222222-2222-2222-2222-222222222224','11111111-1111-1111-1111-111111111111',
           'H01','handoff',null,'Stage 01 to 02', false, false);

        insert into app_user (id,auth_subject,email,display_name,org_role) values
          ('33333333-3333-3333-3333-333333333331','44444444-4444-4444-4444-444444444441',
           'ga@blend.test','GA One','ga'),
          ('33333333-3333-3333-3333-333333333332','44444444-4444-4444-4444-444444444442',
           'gc@blend.test','GC One','gc'),
          ('33333333-3333-3333-3333-333333333333','44444444-4444-4444-4444-444444444443',
           'out@blend.test','Outsider','gc');

        insert into client (id,company_name) values
          ('55555555-5555-5555-5555-555555555555','Fixture Co');

        insert into engagement (id,client_id,instrument_version_id,name,motion_in_scope,
                                window_start,window_end,storage_prefix)
        values ('66666666-6666-6666-6666-666666666666',
                '55555555-5555-5555-5555-555555555555',
                '11111111-1111-1111-1111-111111111111',
                'Fixture GEA','New business','2024-01-01','2025-12-31','eng/fixture');

        insert into engagement_member (engagement_id,app_user_id,engagement_role) values
          ('66666666-6666-6666-6666-666666666666','33333333-3333-3333-3333-333333333331','lead_architect'),
          ('66666666-6666-6666-6666-666666666666','33333333-3333-3333-3333-333333333332','lead_consultant');

        insert into population_count (id,engagement_id,key,value,exclusion_rule) values
          ('77777777-7777-7777-7777-777777777777','66666666-6666-6666-6666-666666666666',
           'closed_won',412,'Closed-won opportunities with a close date inside the window');

        insert into analysis_run (id,engagement_id,job_type,status,accepted_at) values
          ('88888888-8888-8888-8888-888888888881','66666666-6666-6666-6666-666666666666',
           'analysis:pricing','succeeded',now()),
          ('88888888-8888-8888-8888-888888888882','66666666-6666-6666-6666-666666666666',
           'analysis:pipeline','succeeded',null),
          ('88888888-8888-8888-8888-888888888883','66666666-6666-6666-6666-666666666666',
           'classify:discovery','succeeded',null);

        insert into score (id,engagement_id,element_id,state) values
          ('99999999-9999-9999-9999-999999999991','66666666-6666-6666-6666-666666666666',
           '22222222-2222-2222-2222-222222222221','unscored');
        """)


# ---------------------------------------------------------------------------
# Each rule: (id, description, violating SQL, SQL that removes the rule)
# ---------------------------------------------------------------------------

RULES = [
("R1a", "Reference data cannot be inserted against an activated instrument version",
 """update instrument_version set status='active', activated_at=now()
      where id='11111111-1111-1111-1111-111111111111';
    insert into anchor (element_id, level, descriptor)
      values ('22222222-2222-2222-2222-222222222221', 0, 'sneaked in');""",
 "drop trigger anchor_draft_only on anchor;"),

("R1b", "Anchor text cannot be edited on an activated instrument version",
 """insert into anchor (id, element_id, level, descriptor)
      values ('aaaaaaa1-0000-0000-0000-000000000001',
              '22222222-2222-2222-2222-222222222221', 3, 'original');
    update instrument_version set status='active', activated_at=now()
      where id='11111111-1111-1111-1111-111111111111';
    update anchor set descriptor='rewritten'
      where id='aaaaaaa1-0000-0000-0000-000000000001';""",
 "drop trigger anchor_draft_only on anchor;"),

("R2", "A rate metric cannot be stored without a denominator",
 """insert into metric (engagement_id, metric_key, value, unit)
      values ('66666666-6666-6666-6666-666666666666','win_rate',0.42,'rate');""",
 "alter table metric drop constraint metric_rate_needs_denominator;"),

("R3", "A score cannot carry both a value and Not Evidenced",
 """insert into score (engagement_id, element_id, value, not_evidenced, ne_reason)
      values ('66666666-6666-6666-6666-666666666666',
              '22222222-2222-2222-2222-222222222223', 3, true, 'both');""",
 "alter table score drop constraint score_value_xor_ne;"),

("R4", "Not Evidenced is refused on an element that forbids it",
 """insert into score (engagement_id, element_id, not_evidenced, ne_reason)
      values ('66666666-6666-6666-6666-666666666666',
              '22222222-2222-2222-2222-222222222222', true, 'no evidence found');""",
 "drop trigger score_ne_permitted on score;"),

("R5", "Not Evidenced is refused on a handoff",
 """update element set ne_permitted = true
      where id = '22222222-2222-2222-2222-222222222224';""",
 "alter table element drop constraint element_handoff_no_ne;"),

("R6", "A score cannot exceed a cap applied to it",
 """insert into score (engagement_id, element_id, value, cap_applied, cap_reason)
      values ('66666666-6666-6666-6666-666666666666',
              '22222222-2222-2222-2222-222222222223', 4, 2, 'loss_reason unmapped');""",
 "alter table score drop constraint score_within_cap;"),

("R7", "A tier-dependent element cannot exceed the evidence tier ceiling",
 """insert into evidence_tier (engagement_id, tier, verdict, score_ceiling)
      values ('66666666-6666-6666-6666-666666666666','C','fail',4);
    insert into score (engagement_id, element_id, value)
      values ('66666666-6666-6666-6666-666666666666',
              '22222222-2222-2222-2222-222222222223', 5);""",
 "drop trigger score_tier_ceiling on score;"),

("R8", "A score cannot become final without a citation",
 """update score set value = 3, state = 'final'
      where id = '99999999-9999-9999-9999-999999999991';""",
 "drop trigger score_final_requires_citation on score;"),

("R9", "A score cannot cite a run that has not been accepted",
 """insert into score_citation (score_id, analysis_run_id)
      values ('99999999-9999-9999-9999-999999999991',
              '88888888-8888-8888-8888-888888888882');""",
 "drop trigger citation_requires_accepted_run on score_citation;"),

("R10", "A citation must point at something retrievable",
 """insert into score_citation (score_id, note)
      values ('99999999-9999-9999-9999-999999999991','I remember seeing it');""",
 "alter table score_citation drop constraint citation_needs_a_source;"),

("R11", "A score cannot become final while citing a stale run",
 """insert into score_citation (score_id, analysis_run_id)
      values ('99999999-9999-9999-9999-999999999991',
              '88888888-8888-8888-8888-888888888881');
    update analysis_run set is_stale = true
      where id = '88888888-8888-8888-8888-888888888881';
    update score set value = 3, state = 'final'
      where id = '99999999-9999-9999-9999-999999999991';""",
 "drop trigger score_final_requires_citation on score;"),

("R12", "A completed analysis run's output cannot be edited",
 """update analysis_run set compute_output = '{"rewritten": true}'::jsonb
      where id = '88888888-8888-8888-8888-888888888881';""",
 "drop trigger run_append_only on analysis_run;"),

("R13", "A classification run cannot be accepted without a trusted validation set",
 """update analysis_run set accepted_at = now()
      where id = '88888888-8888-8888-8888-888888888883';""",
 "drop trigger run_classification_gate on analysis_run;"),

("R14", "A population count cannot be stored without an exclusion rule",
 """insert into population_count (engagement_id, key, value, exclusion_rule)
      values ('66666666-6666-6666-6666-666666666666','closed_lost',700,'   ');""",
 "alter table population_count drop constraint population_count_exclusion_rule_check;"),

("R15", "An analysis cannot be marked supported without naming supporting fields",
 """insert into analysis_capability (engagement_id, analysis_key, verdict)
      values ('66666666-6666-6666-6666-666666666666','forecast_accuracy','supported');""",
 "alter table analysis_capability drop constraint capability_supported_needs_fields;"),

("R16", "A cost line with a figure must trace to a source document",
 """insert into tco_line (engagement_id, category, annual_cost, is_open_input)
      values ('66666666-6666-6666-6666-666666666666','Duplicate licensing',48000,false);""",
 "alter table tco_line drop constraint tco_cost_needs_source;"),

("R17", "A requirement cannot be waived without a reason",
 """insert into evidence_requirement (instrument_version_id, element_id, ref, source_kind,
                                      description, waiver_consequence)
      values ('11111111-1111-1111-1111-111111111111',
              '22222222-2222-2222-2222-222222222221','1.1-R1','export',
              'Closed opportunity export','Element 1.1 scored on interview alone');
    insert into engagement_requirement (engagement_id, evidence_requirement_id, state)
      select '66666666-6666-6666-6666-666666666666', id, 'waived'
        from evidence_requirement where ref = '1.1-R1';""",
 "alter table engagement_requirement drop constraint requirement_waiver_needs_reason;"),

("R18", "The library record cannot contain identifiable data",
 """insert into library_record (engagement_id, instrument_version_id, segment_attributes,
                                snapshot, contains_identifiable_data)
      values ('66666666-6666-6666-6666-666666666666',
              '11111111-1111-1111-1111-111111111111','{}'::jsonb,'{}'::jsonb, true);""",
 "alter table library_record drop constraint library_no_identifiable_data;"),

("R19", "A threshold change must name the metric to be recompared",
 """insert into instrument_version (id,label,status)
      values ('1111111a-1111-1111-1111-111111111111','0.7-test','draft');
    insert into element_version_change (from_instrument_version_id, to_instrument_version_id,
                                        element_ref, change_type)
      values ('11111111-1111-1111-1111-111111111111',
              '1111111a-1111-1111-1111-111111111111','2.5','threshold');""",
 "alter table element_version_change drop constraint change_threshold_needs_metric;"),

("R20", "A metric marked computable must name its source fields",
 """insert into measurement_definition (engagement_id, metric_key, name, is_computable)
      values ('66666666-6666-6666-6666-666666666666','m04','Signal to first contact', true);""",
 "alter table measurement_definition drop constraint measurement_computable_needs_fields;"),

("R21", "A frozen scorecard cannot be changed",
 """insert into honesty_test (engagement_id, question_one_answer, question_two_answer)
      values ('66666666-6666-6666-6666-666666666666','Yes','No');
    update score set value = 3, state = 'provisional'
      where id = '99999999-9999-9999-9999-999999999991';
    update engagement set score_frozen_at = now()
      where id = '66666666-6666-6666-6666-666666666666';
    update score set value = 4
      where id = '99999999-9999-9999-9999-999999999991';""",
 "drop trigger score_frozen on score;"),

("R22", "An engagement cannot be frozen while a challenge is open",
 """insert into honesty_test (engagement_id, question_one_answer, question_two_answer)
      values ('66666666-6666-6666-6666-666666666666','Yes','No');
    update score set value = 3, state = 'provisional'
      where id = '99999999-9999-9999-9999-999999999991';
    insert into challenge (engagement_id, element_id, challenge_text)
      values ('66666666-6666-6666-6666-666666666666',
              '22222222-2222-2222-2222-222222222221','Single source');
    update engagement set score_frozen_at = now()
      where id = '66666666-6666-6666-6666-666666666666';""",
 "drop trigger engagement_freeze_gate on engagement;"),

("R23", "An engagement cannot be frozen without the honesty test",
 """update score set value = 3, state = 'provisional'
      where id = '99999999-9999-9999-9999-999999999991';
    update engagement set score_frozen_at = now()
      where id = '66666666-6666-6666-6666-666666666666';""",
 "drop trigger engagement_freeze_gate on engagement;"),

("R24", "An engagement cannot hold two active lead consultants",
 """insert into engagement_member (engagement_id, app_user_id, engagement_role)
      values ('66666666-6666-6666-6666-666666666666',
              '33333333-3333-3333-3333-333333333333','lead_consultant');""",
 "drop index engagement_one_lead_consultant;"),

("R25", "The last active lead architect cannot be removed",
 """update engagement_member set to_date = current_date
      where engagement_id = '66666666-6666-6666-6666-666666666666'
        and engagement_role = 'lead_architect';""",
 "drop trigger member_lead_architect on engagement_member;"),

("R26", "The same file cannot be registered twice against one engagement",
 """insert into artefact (engagement_id, kind, original_filename, storage_path, sha256)
      values ('66666666-6666-6666-6666-666666666666','raw_export','deals.csv','p/1','abc123');
    insert into artefact (engagement_id, kind, original_filename, storage_path, sha256)
      values ('66666666-6666-6666-6666-666666666666','raw_export','deals-copy.csv','p/2','abc123');""",
 "alter table artefact drop constraint artefact_engagement_id_sha256_key;"),
]


def attempt(conn, sql):
    """Run sql in a transaction. Return None if it succeeded, else the error text."""
    try:
        with conn.transaction():
            with conn.cursor() as cur:
                cur.execute(sql)
        return None
    except Exception as e:
        return str(e).strip().splitlines()[0]


def main():
    db, conn = connect()
    conn.autocommit = True
    results = []

    for rid, desc, bad_sql, drop_sql in RULES:
        # half one: the rule is present, the violation must be rejected
        rebuild(conn)
        seed(conn)
        err = attempt(conn, bad_sql)
        enforced = err is not None

        # half two: with the rule removed, the same violation must succeed
        rebuild(conn, skip_rule=drop_sql)
        seed(conn)
        err2 = attempt(conn, bad_sql)
        mutation_ok = err2 is None

        results.append((rid, desc, enforced, mutation_ok, err, err2))

    conn.close()

    width = max(len(r[1]) for r in results)
    print(f"{'':5} {'RULE':<{width}}  ENFORCED  TEST-VALID")
    print("-" * (width + 30))
    fails = 0
    for rid, desc, enforced, mut, err, err2 in results:
        a = "yes" if enforced else "NO "
        b = "yes" if mut else "NO "
        if not (enforced and mut):
            fails += 1
        print(f"{rid:5} {desc:<{width}}  {a:^8}  {b:^10}")
        if not enforced:
            print(f"      ^ violation was ACCEPTED — the rule is not enforced")
        if not mut:
            print(f"      ^ violation still rejected with the rule removed: {err2}")
    print("-" * (width + 30))
    print(f"{len(results)-fails}/{len(results)} rules enforced and proven")
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
