"""Generate the Zone A seed migrations from the six reference workbooks.

Deterministic. Re-run it after any workbook change and the output changes with
the source rather than drifting from it.

Foreign keys resolve by natural key at load time (element.ref, canonical_field.key,
interview_guide.ref) rather than by generated UUID, so the SQL stays readable and
a mis-ordered insert fails loudly instead of landing on the wrong row.

Decisions applied here that are not yet in the workbooks, from the review session
of 23 September 2026:
  campaign                             cap-bearing flag removed, no cap rule
  health_score_at                      6.4 cap raised from 2 to 3
  health_score                         stays cap-bearing, no cap rule
  first_value_at                       new rule, caps 6.2 at 2
  channel_source                       cap 2 on 3.1, replacing "Per element fallback rule"
  contact_role                         second rule, caps 2.2 at 3
  discovery_consistency_classification field requirements declared
  Note fields                          2.5 added to elements served
  export_line_element                  union of both sheets less T3-09/3.4 and T1-06/7.1
  interview_question_element           section-level mapping expanded to questions
"""
import json, re, collections, pathlib
import openpyxl

SRC = pathlib.Path('/mnt/project')
MAP = pathlib.Path('/mnt/user-data/outputs/Blend GEA_Interview Question Map_v0.3.xlsx')
OUT = pathlib.Path('/home/claude/gea-db/migrations')
IV = '0f6a0006-0000-4000-8000-000000000006'
LABEL = 'v0.6'

NE_FORBIDDEN = {'2.1', '2.3', '2.4', '3.3', '4.4', '7.4', '7.5', '8.1'}
TIER_DEPENDENT = {'2.5', '5.2', '6.1', 'H04', 'H05'}
EVIDENCE_DECAYS = {'2.1', '2.2', '2.3', '2.4', '3.2', '3.3',
                   '3.5', '4.1', '4.2', '7.2', '7.4'}
RETRIEVABILITY = {'H01', 'H02', 'H06'}

CAP_OVERRIDES = {            # (field, element) -> cap level
    ('health_score_at', '6.4'): 3,
    ('channel_source', '3.1'): 2,
}
CAP_ADDITIONS = [            # field, condition, element, cap
    ('first_value_at', 'Per-customer first value dates are not recorded, so time '
     'to first value cannot be computed for any customer', '6.2', 2),
    ('contact_role', 'Contact roles are not populated, so the buying group must '
     'be reconstructed from engagement history or interview', '2.2', 3),
]
CAP_UNFLAG = {'campaign'}
EXPORT_PAIRS_REMOVED = {('T3-09', '3.4'), ('T1-06', '7.1')}
NOTE_FIELDS_GAIN_25 = {'note_id', 'note_body', 'note_created_at', 'note_author',
                       'note_opportunity_id', 'meeting_at'}
DISCOVERY_REQUIRED = ['note_id', 'note_body', 'note_created_at', 'note_author',
                      'note_opportunity_id', 'meeting_at', 'activity_type',
                      'activity_at', 'activity_opportunity_id', 'activity_owner']
DISCOVERY_OPTIONAL = ['activity_id', 'opportunity_stage', 'opportunity_owner']

SOURCE_KIND = {'Export': 'export', 'Analysis': 'analysis',
               'Client document': 'client_document',
               'Public surface': 'public_surface',
               'External upload': 'external_upload',
               'Observation': 'observation', 'Interview': 'interview'}
LAG = {'Immediate': 'immediate', 'One quarter': 'one_quarter',
       'One sales cycle': 'one_sales_cycle',
       'One onboarding cycle': 'one_onboarding_cycle',
       'One renewal cycle': 'one_renewal_cycle'}


def q(v):
    """SQL literal."""
    if v is None or (isinstance(v, str) and not v.strip()):
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).strip().replace("'", "''") + "'"


def arr(vals):
    if not vals:
        return 'null'
    return 'array[' + ','.join(q(v) for v in vals) + ']::text[]'


def jsonb(obj):
    return q(json.dumps(obj, ensure_ascii=False)) + '::jsonb'


def rows(path, sheet, header_row=1):
    ws = openpyxl.load_workbook(path, read_only=True, data_only=True)[sheet]
    hdr = list(next(ws.iter_rows(min_row=header_row, max_row=header_row,
                                 values_only=True)))
    return [dict(zip(hdr, r))
            for r in ws.iter_rows(min_row=header_row + 1, values_only=True)
            if r[0] is not None]


def refs_in(text):
    return re.findall(r'\b(?:[1-8]\.[1-5]|H0[1-8])\b', str(text or ''))


def header(n, title, note):
    return (f'-- {n} {title}\n--\n'
            + '\n'.join('-- ' + l for l in note.strip().split('\n'))
            + '\n\n')


files = {}

# ------------------------------------------------------- 008 instrument ----
els = rows(SRC / 'Blend_GEA_Scoring_Instrument_v0.6.xlsx'.replace('.', '_', 2)
           if False else SRC / 'Blend_GEA_Scoring_Instrument_v0_6.xlsx',
           'Element Spec', header_row=3)
anchors_ws = openpyxl.load_workbook(
    SRC / 'Blend_GEA_Scoring_Instrument_v0_6.xlsx', read_only=True)['Anchors']

sql = header('008', 'Seed: instrument version, 48 elements, 288 anchors', """
Loaded from Blend GEA_Scoring Instrument v0.6.
The version is created as draft. It stays draft until every seed migration has
run and the activation gate passes, because activating it makes all of this
immutable.
""")
sql += (f"insert into instrument_version (id, label, runbook_label, status, notes)\n"
        f"values ({q(IV)}, {q(LABEL)}, {q('Blend GEA Runbook v0.3')}, 'draft',\n"
        f"        {q('Seeded from the six reference workbooks. Cap rules, analysis field requirements and interview question mapping carry the review decisions of 23 September 2026.')});\n\n")

sql += ('insert into element (instrument_version_id, ref, kind, stage_code, '
        'from_stage, to_stage, name,\n  why_assessed, evidence_required, method, '
        'owner_role, support_role, fallback_rule,\n  ne_permitted, tier_dependent, '
        'evidence_decays, has_retrievability_test, sort_order) values\n')
parts = []
for i, e in enumerate(els, 1):
    ref = e['ID']
    handoff = ref.startswith('H')
    stage_code = from_stage = to_stage = None
    if handoff:
        m = re.search(r'Stage (\d+) (?:to|back to) Stage (\d+)', str(e['Stage']))
        from_stage, to_stage = (m.group(1), m.group(2)) if m else (None, None)
    else:
        stage_code = ref.split('.')[0].zfill(2)
    parts.append(
        f"  ({q(IV)}, {q(ref)}, {q('handoff' if handoff else 'element')}, "
        f"{q(stage_code)}, {q(from_stage)}, {q(to_stage)}, {q(e['Element'])},\n"
        f"   {q(e['Why this is assessed'])}, {q(e['Evidence required'])}, "
        f"{q(e['Method'])},\n   {q(e['Owner'])}, {q(e['Support'])}, "
        f"{q(e['If evidence cannot be obtained'])},\n   "
        f"{q(not (handoff or ref in NE_FORBIDDEN))}, {q(ref in TIER_DEPENDENT)}, "
        f"{q(handoff or ref in EVIDENCE_DECAYS)}, "
        f"{q(ref in RETRIEVABILITY)}, {i})")
sql += ',\n'.join(parts) + ';\n\n'

sql += ('insert into anchor (element_id, level, descriptor)\n'
        'select e.id, v.level, v.descriptor from (values\n')
parts, cur = [], None
for r in anchors_ws.iter_rows(min_row=5, values_only=True):
    if r[0]:
        cur = r[0]
    if r[2] is None:
        continue
    parts.append(f"  ({q(cur)}, {int(r[2])}, {q(r[3])})")
sql += ',\n'.join(parts)
sql += (f"\n) as v(ref, level, descriptor)\n"
        f"join element e on e.ref = v.ref and e.instrument_version_id = {q(IV)};\n")
files['008_seed_instrument.sql'] = sql

# ----------------------------------------------- 009 fields, caps, analyses --
cf = rows(SRC / 'Blend_GEA_Canonical_Field_Vocabulary_v0_1.xlsx', 'Canonical Fields')
ar = rows(SRC / 'Blend_GEA_Canonical_Field_Vocabulary_v0_1.xlsx', 'Analysis Requirements')
cr = rows(SRC / 'Blend_GEA_Canonical_Field_Vocabulary_v0_1.xlsx', 'Cap Rules')

sql = header('009', 'Seed: 123 canonical fields, cap rules, analysis field requirements', """
Loaded from Blend GEA_Canonical Field Vocabulary v0.1, with the review decisions
of 23 September 2026 applied. Each decision is marked at the row it changes.
""")
sql += ('insert into canonical_field (instrument_version_id, key, name, description,\n'
        '  expected_type, expected_domain, source_export_refs, is_cap_bearing,\n'
        '  priority, element_refs) values\n')
parts = []
for f in cf:
    key = f['Key']
    bearing = str(f['Cap-bearing']).strip().lower() == 'yes' and key not in CAP_UNFLAG
    served = refs_in(f['Elements served'])
    if key in NOTE_FIELDS_GAIN_25 and '2.5' not in served:
        served = sorted(set(served) | {'2.5'})
    lines = re.findall(r'\bT[123]-\d{2}\b', str(f['Export lines'] or ''))
    note = '   -- campaign: cap-bearing flag removed, absence is expected\n' \
        if key in CAP_UNFLAG else ''
    parts.append(
        note + f"  ({q(IV)}, {q(key)}, {q(f['Name'])}, {q(f['Description'])},\n"
        f"   {q(f['Type'])}, {q(f['Expected domain'])}, {arr(lines)}, {q(bearing)},\n"
        f"   {q(str(f['Priority']).strip().lower())}, {arr(served)})")
sql += ',\n'.join(parts) + ';\n\n'

caps = []
for r in cr:
    field, el = r['Canonical field'], str(r['Element'])
    if field in CAP_UNFLAG:
        continue
    level = CAP_OVERRIDES.get((field, el))
    note = ''
    if level is not None:
        note = (f'  -- {field}: cap set to {level} by review decision\n')
    else:
        level = int(str(r['Cap']).strip())
    caps.append((field, el, level, r['Condition'], note))
for field, cond, el, level in CAP_ADDITIONS:
    caps.append((field, el, level, cond,
                 f'  -- {field}: rule added by review decision\n'))

sql += ('insert into canonical_field_cap (canonical_field_id, element_id, cap_level, condition)\n'
        'select f.id, e.id, v.cap_level, v.condition from (values\n')
sql += ',\n'.join(
    note + f"  ({q(f)}, {q(e)}, {lv}, {q(c)})" for f, e, lv, c, note in caps)
sql += (f"\n) as v(field_key, element_ref, cap_level, condition)\n"
        f"join canonical_field f on f.key = v.field_key and f.instrument_version_id = {q(IV)}\n"
        f"join element e on e.ref = v.element_ref and e.instrument_version_id = {q(IV)};\n\n")

reqs = [(r['Analysis key'], r['Canonical field'],
         str(r['Requirement']).strip().lower() == 'required') for r in ar]
reqs += [('discovery_consistency_classification', k, True) for k in DISCOVERY_REQUIRED]
reqs += [('discovery_consistency_classification', k, False) for k in DISCOVERY_OPTIONAL]

sql += ('-- discovery_consistency_classification declared by review decision: it was\n'
        '-- required by two evidence requirements with no field list, so its capability\n'
        '-- verdict computed as supported on every engagement.\n'
        'insert into analysis_field_requirement (instrument_version_id, analysis_key,\n'
        '  canonical_field_id, is_required)\n'
        'select ' + q(IV) + ', v.analysis_key, f.id, v.is_required from (values\n')
sql += ',\n'.join(f"  ({q(a)}, {q(k)}, {q(req)})" for a, k, req in reqs)
sql += (f"\n) as v(analysis_key, field_key, is_required)\n"
        f"join canonical_field f on f.key = v.field_key and f.instrument_version_id = {q(IV)};\n")
files['009_seed_fields.sql'] = sql

# ------------------------------------------------------- 010 export lines ---
ex = [r for r in rows(SRC / 'Blend_GEA_Evidence_Kit__Export_Specification_v0_2.xlsx',
                      'Export Specification', header_row=4) if r['Ref']]
cvr = [r for r in rows(SRC / 'Blend_GEA_Evidence_Kit__Export_Specification_v0_2.xlsx',
                       'Coverage Check', header_row=4)]
ae = [r for r in rows(SRC / 'Blend_GEA_Evidence_Kit__Export_Specification_v0_2.xlsx',
                      'AEO Prompt Set', header_row=4) if r['Ref'] and r['Category']]
elrefs = {e['ID'] for e in els}

pairs = set()
for x in ex:
    for t in refs_in(x['Elements it serves']):
        pairs.add((x['Ref'], t))
for x in cvr:
    if str(x['ID']) not in elrefs:
        continue
    for t in re.findall(r'\bT[123]-\d{2}\b', str(x['Fed by'] or '')):
        pairs.add((t, str(x['ID'])))
pairs -= EXPORT_PAIRS_REMOVED

sql = header('010', 'Seed: 24 export lines, coverage map, 21 answer engine templates', """
The coverage map is the union of the Export Specification sheet's "Elements it
serves" column and the Coverage Check sheet's "Fed by" column, which disagreed on
14 pairs. Two pairs are excluded by review decision: T3-09 feeds the stack cost
model rather than element 3.4, and T1-06 tickets do not evidence 7.1.
""")
sql += ('insert into export_line (instrument_version_id, tier, ref, title,\n'
        '  hubspot_guidance, salesforce_guidance, scope_notes) values\n')
sql += ',\n'.join(
    f"  ({q(IV)}, {int(x['Tier'])}, {q(x['Ref'])}, {q(x['What to ask for'])},\n"
    f"   {q(x['HubSpot'])}, {q(x['Salesforce'])}, {q(x['Scope, limits and known traps'])})"
    for x in ex) + ';\n\n'

sql += ('insert into export_line_element (export_line_id, element_id)\n'
        'select l.id, e.id from (values\n')
sql += ',\n'.join(f"  ({q(a)}, {q(b)})" for a, b in sorted(pairs))
sql += (f"\n) as v(line_ref, element_ref)\n"
        f"join export_line l on l.ref = v.line_ref and l.instrument_version_id = {q(IV)}\n"
        f"join element e on e.ref = v.element_ref and e.instrument_version_id = {q(IV)};\n\n")

def aeo_slots(x):
    text = str(x['Slots to fill'] or '') + ' ' + str(x['Template prompt'] or '')
    return sorted({s.strip() for s in re.findall(r'\[([^\]]+)\]', text)})


sql += ('insert into aeo_prompt_template (instrument_version_id, ref, category,\n'
        '  buyer_intent, template, slots) values\n')
sql += ',\n'.join(
    f"  ({q(IV)}, {q(x['Ref'])}, {q(x['Category'])}, {q(x['Buyer intent'])},\n"
    f"   {q(x['Template prompt'])}, {arr(aeo_slots(x))})"
    for x in ae) + ';\n'
files['010_seed_exports.sql'] = sql

# --------------------------------------------------------- 011 interviews ---
qmap = rows(MAP, 'Expanded Mapping')
guide_text = (SRC / 'Blend_GEA_Evidence_Kit_-_Interview_Guides_v0_1.docx').read_text(
    errors='replace')
guides = []
for part in re.split(r'^# \*\*Guide ', guide_text, flags=re.M)[1:]:
    n = int(part.split(' ')[0])
    title = part.split('**')[0].strip()
    name = title.split('—')[1].strip()
    pre = part.split('###')[0]
    who = re.search(r'\*\*Who\.\s*\*\*(.+)', pre)
    guides.append((n, name, who.group(1).strip() if who else None))

sql = header('011', 'Seed: 7 interview guides, 115 questions, question-to-element mapping', """
Question-to-element mapping is authored at section level in Blend GEA_Interview
Question Map v0.1 and expanded to every question in the section, with per-question
overrides where the source guide names an element. Guide-level mapping alone was
too coarse for transcript synthesis and left H01, H02 and H06 with no link from
the element to the question that evidences it.
""")
sql += ('insert into interview_guide (instrument_version_id, ref, function_name,\n'
        '  duration_minutes, preamble) values\n')
sql += ',\n'.join(f"  ({q(IV)}, {n}, {q(name)}, 60, {q(who)})"
                  for n, name, who in guides) + ';\n\n'

sql += ('insert into interview_question (interview_guide_id, section_title,\n'
        '  sort_order, question_text)\n'
        'select g.id, v.section_title, v.sort_order, v.question_text from (values\n')
parts, order = [], collections.Counter()
for r in qmap:
    g = int(r['Guide'])
    order[g] += 1
    parts.append(f"  ({g}, {q(r['Section'])}, {order[g]}, {q(r['Question'])})")
sql += ',\n'.join(parts)
sql += (f"\n) as v(guide_ref, section_title, sort_order, question_text)\n"
        f"join interview_guide g on g.ref = v.guide_ref "
        f"and g.instrument_version_id = {q(IV)};\n\n")

sql += ('insert into interview_question_element (interview_question_id, element_id)\n'
        'select qq.id, e.id from (values\n')
parts, order = [], collections.Counter()
for r in qmap:
    g = int(r['Guide'])
    order[g] += 1
    for el in str(r['Elements loaded'] or '').split():
        parts.append(f"  ({g}, {order[g]}, {q(el)})")
sql += ',\n'.join(parts)
sql += (f"\n) as v(guide_ref, sort_order, element_ref)\n"
        f"join interview_guide g on g.ref = v.guide_ref and g.instrument_version_id = {q(IV)}\n"
        f"join interview_question qq on qq.interview_guide_id = g.id "
        f"and qq.sort_order = v.sort_order\n"
        f"join element e on e.ref = v.element_ref and e.instrument_version_id = {q(IV)};\n")
files['011_seed_interviews.sql'] = sql

# ------------------------------------------------------- 012 requirements ---
er = rows(SRC / 'Blend_GEA_Evidence_Requirements_v0_1.xlsx', 'Evidence Requirements')
sql = header('012', 'Seed: 171 evidence requirements', """
Loaded from Blend GEA_Evidence Requirements v0.1. The source reference resolves to
one of three columns depending on the source kind: export line refs, an interview
guide, or an analysis key. Everything else leaves all three null.
""")
sql += ('insert into evidence_requirement (instrument_version_id, element_id, ref,\n'
        '  source_kind, export_line_refs, interview_guide_id, analysis_key,\n'
        '  description, is_mandatory, waiver_consequence)\n'
        f'select {q(IV)}, e.id, v.ref, v.source_kind::req_source_kind,\n'
        '  v.export_line_refs, g.id, v.analysis_key, v.description,\n'
        '  v.is_mandatory, v.waiver_consequence\nfrom (values\n')
parts = []
for r in er:
    kind = SOURCE_KIND[r['Source kind']]
    ref_txt = str(r['Source reference'] or '')
    lines = re.findall(r'\bT[123]-\d{2}\b', ref_txt) if kind == 'export' else []
    guide = int(ref_txt.split()[0]) if kind == 'interview' else None
    akey = ref_txt.strip() if kind == 'analysis' else None
    parts.append(
        f"  ({q(r['Element'])}, {q(r['Requirement'])}, {q(kind)}, {arr(lines)},\n"
        f"   {guide if guide else 'null'}, {q(akey)}, {q(r['What is needed'])},\n"
        f"   {q(str(r['Mandatory']).strip().lower() in ('yes', 'true'))}, "
        f"{q(r['Consequence if it cannot be obtained'])})")
sql += ',\n'.join(parts)
sql += (f"\n) as v(element_ref, ref, source_kind, export_line_refs, guide_ref,\n"
        f"       analysis_key, description, is_mandatory, waiver_consequence)\n"
        f"join element e on e.ref = v.element_ref and e.instrument_version_id = {q(IV)}\n"
        f"left join interview_guide g on g.ref = v.guide_ref "
        f"and g.instrument_version_id = {q(IV)};\n")
files['012_seed_requirements.sql'] = sql

# ------------------------------------------- 013 prompts and measurements ---
pr = rows(SRC / 'Blend_GEA_Prompt_Library_v0_1.xlsx', 'Prompts')
sl = rows(SRC / 'Blend_GEA_Prompt_Library_v0_1.xlsx', 'Slots')
dc = rows(SRC / 'Blend_GEA_Prompt_Library_v0_1.xlsx', 'Discard conditions')
oc = rows(SRC / 'Blend_GEA_Prompt_Library_v0_1.xlsx', 'Output contract')
sm = rows(SRC / 'Blend_GEA_Measurement_Definition_Set_v0_1.xlsx', 'Stage Metrics')
hf = rows(SRC / 'Blend_GEA_Measurement_Definition_Set_v0_1.xlsx', 'Handoff Rates')
fi = rows(SRC / 'Blend_GEA_Measurement_Definition_Set_v0_1.xlsx', 'Field Inputs')

slots = collections.defaultdict(list)
for s in sl:
    slots[s['Ref']].append(str(s['Slot']).strip())
contract = collections.defaultdict(dict)
for o in oc:
    contract[o['Ref']][str(o['Field'])] = {
        'type': o['Type'],
        'required': str(o['Required']).strip().lower() in ('yes', 'true'),
        'notes': o['Notes']}
discards = collections.defaultdict(list)
for d in dc:
    discards[d['Ref']].append({
        'ref': d['Condition ref'], 'code': d['Code'], 'condition': d['Condition'],
        'machine_checkable': str(d['Machine-checkable']).strip().lower() == 'yes',
        'how_checked': d['How it is checked']})

sql = header('013', 'Seed: 25 prompts, 16 measurement definitions', """
Prompts are versioned independently of the instrument, so prompt_version carries
no instrument_version_id and is not covered by the reference immutability trigger.
Output contracts and discard conditions are stored as jsonb because the analysis
service validates against them rather than the application reading them field by
field.
""")
sql += ('insert into prompt_version (ref, version, title, purpose, inputs_required,\n'
        '  template, slots, execution_mode, output_contract, discard_conditions,\n'
        '  step_ref, owner_role, status) values\n')
sql += ',\n'.join(
    f"  ({q(p['Ref'])}, {q('0.1')}, {q(p['Title'])}, {q(p['Purpose'])}, {q(p['Inputs'])},\n"
    f"   {q(p['Template'])},\n   {arr(slots[p['Ref']])}, "
    f"{q(str(p['Mode']).strip().lower())},\n   {jsonb(contract[p['Ref']])},\n"
    f"   {jsonb(discards[p['Ref']])},\n   {q(p['Step'])}, {q(p['Owner'])}, 'draft')"
    for p in pr) + ';\n\n'

required = collections.defaultdict(list)
for r in fi:
    if str(r['Role']).strip().lower() == 'required':
        required[r['Metric ref']].append(r['Canonical field'])

sql += ('insert into measurement_definition_template (instrument_version_id, metric_key,\n'
        '  name, definition, formula, required_fields, owning_function, cadence, lag,\n'
        '  why_it_matters, computability_note) values\n')
sql += ',\n'.join(
    f"  ({q(IV)}, {q(m['Ref'])}, {q(m['Metric'])}, {q(m['Definition'])},\n"
    f"   {q(m['Formula'])}, {arr(required[m['Ref']])}, {q(m['Owning function'])},\n"
    f"   {q(m['Cadence'])}, {q(LAG[str(m['Response lag']).strip()])},\n"
    f"   {q(m['Why it matters'])}, {q(m['What it requires to be computable'])})"
    for m in sm + hf) + ';\n'
files['013_seed_prompts.sql'] = sql

OUT.mkdir(parents=True, exist_ok=True)
for name, body in files.items():
    (OUT / name).write_text(body)
    print(f'{name:32} {len(body):>8,} bytes')
print(f'\nexport_line_element pairs: {len(pairs)}')
print(f'cap rules: {len(caps)}   analysis field requirements: {len(reqs)}')
