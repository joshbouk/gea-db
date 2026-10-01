"""Build Blend GEA_Interview Question Map_v0.3.xlsx.

Section-level element mappings for the seven interview guides, expanded to the
115 questions at import, with per-question overrides where a question carries
its own element reference in the source document.
"""
import json, re, collections
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment
from openpyxl.utils import get_column_letter

NAVY = 'FF181144'
BAND = 'FFF2F1F6'
GUIDES_DOC = ('/mnt/user-data/outputs/'
              'Blend GEA_Evidence Kit - Interview Guides_v0.2.docx')


def read_guides(path):
    """Questions come from the guides document, read by paragraph style.

    The document owns the questions. This script owns the element mapping.
    Neither is derived from the other, so a question added to the guides in
    Word appears here on the next run without anyone editing code."""
    import docx
    doc = docx.Document(path)
    guide = section = title = None
    out = []
    for para in doc.paragraphs:
        style, text = para.style.name, para.text.strip()
        if not text:
            continue
        if style == 'Heading 1' and text.startswith('Guide '):
            guide = int(text.split()[1])
            title = text.replace('Guide ', '', 1)
            section = None
        elif style == 'Heading 2' and guide:
            section = text
        elif style == 'List Paragraph' and guide and section:
            out.append(dict(guide=guide, guide_title=title,
                            section=section, question=text))
    return out


QS = read_guides(GUIDES_DOC)

# Guide-level coverage as declared in the source document.
GUIDE_DECLARED = {
    1: '1.1 1.2 1.4 1.5 H08',
    2: '2.1 2.2 2.3 2.4 3.1 3.2 3.3 3.5 4.1 4.2 4.4 H01 H02',
    3: '1.4 4.5 5.1 5.3 5.5 8.3 H04',
    4: '3.1 3.4 4.3 4.5 5.1 5.5 6.3 8.1 8.2 H03 H04',
    5: '6.1 6.2 6.3 6.4 6.5 7.1 7.5 8.4 8.5 H05 H06 H07',
    6: '1.5 3.4 5.5 8.4',
    7: '5.1 5.2 5.3 5.4 2.5 4.5 H04 H05',
}

# (guide, section) -> (elements, basis for the mapping)
SECTION_MAP = {
    (1, 'Who you are for'): ('1.1 1.2',
        'Definition, exclusions, provenance and evidence base for the ICP. H01 is '
        'not inherited here: it is a retrievability test carried by one question, '
        'and the other four cannot evidence it.'),
    (1, 'Why you win, and where you do not'): ('1.4',
        'Differentiation claims and the alternative actually considered. Loss '
        'patterns surface here but are scored from the CRM census on 1.3.'),
    (1, 'Pricing and packaging'): ('1.5',
        'When packaging was set and whether discount authority holds in practice.'),
    (1, 'The loop back'): ('H08',
        'Whether retention evidence produced a recorded targeting change.'),
    (1, 'Scope and ownership'): ('',
        'Sponsor authority and disposition of uncomfortable findings. G0 setup, '
        'not element evidence.'),

    (2, 'Narrative and message, first priority'): ('2.1 2.2',
        'Core narrative and its owner, persona architecture and its provenance. '
        'H01 and H02 are not inherited here: each is a retrievability test carried '
        'by a named question, and the rest cannot evidence them.'),
    (2, 'Proof'): ('2.3',
        'Case study inventory, verified numbers, reference availability and the '
        'trigger for producing proof.'),
    (2, 'Channels'): ('3.1 3.2 3.3 3.5',
        'Budget logic, the stated job of each channel, owned reach if paid '
        'stopped, and answer engine visibility.'),
    (2, 'Engagement'): ('4.1 4.2 4.4',
        'Next-step design, content against research stage, and what happens to '
        'a contact who does not convert.'),
    (2, 'Qualification, ask this even though sales will also be asked'): ('4.5',
        'The marketing-side definition, captured separately so it can be '
        'compared against the sales-side answer in Guide 3.'),

    (3, 'Pipeline and process'): ('5.1',
        'Stage definitions, exit criteria and where deals stall.'),
    (3, 'Discovery and buyer process'): ('5.3',
        'Buying group, approval path, procurement timing and mutual action '
        'planning. Discovery quality itself is scored from the rep sessions.'),
    (3, 'Proposal and contracting'): ('5.4',
        'Elapsed time from discovery to proposal and what slows contracting.'),
    (3, 'Forecast'): ('5.5',
        'How the forecast is built, why it is wrong, and treatment of past-dated '
        'close dates.'),
    (3, 'Qualification, and what arrives'): ('4.5 H04',
        'The sales-side qualification definition and what actually arrives with '
        'a handover.'),

    (4, 'What the data can and cannot carry'): ('',
        'Field trustworthiness and reconciliation effort. Feeds the intake audit '
        'and the TCO reconciliation line, not a single element.'),
    (4, 'Signal, routing and handover'): ('4.3 H03 H04',
        'Form submission to first contact, lead score composition and validation, '
        'what travels to the rep, and pre-form behaviour.'),
    (4, 'Reporting and measurement'): ('5.5',
        'Provenance of reported numbers and their sensitivity to method. Weak '
        'mapping — review.'),
    (4, 'Stack'): ('',
        'Systems, integrations and breakages. Feeds the stack inventory and the '
        'TCO model, which are deliverables rather than scores.'),
    (4, 'Expansion and account data'): ('8.1 8.2',
        'Product ownership and white space, and whether expansion is '
        'distinguishable from new business in the data.'),

    (5, 'What arrives from sales'): ('6.1 H05',
        'How delivery learns what was sold, late-surfacing commitments, refusal '
        'rights, and whether signed scope becomes the plan.'),
    (5, 'Onboarding and first value'): ('6.2',
        'The defined first-value moment, whether duration is measured or '
        'estimated, and what makes an onboarding go badly.'),
    (5, 'Adoption and health'): ('6.3 6.4 6.5',
        'Usage visibility, early warning lead time, and what a red status '
        'actually triggers.'),
    (5, 'Capturing what customers say'): ('7.1 7.5 H06 H07',
        'What happens to a stated outcome, whether marketing can retrieve it '
        'later, and who acts on a strong satisfaction signal.'),
    (5, 'Renewal and expansion'): ('8.2 8.4 8.5',
        'Renewal timing, whether expansion is customer- or company-initiated, '
        'and account plan currency.'),

    (6, 'Cost of the stack'): ('',
        'Annual system cost, integration build and run, reconciliation headcount '
        'and third-party spend. TCO model inputs.'),
    (6, 'Retention arithmetic'): ('8.4',
        'Gross and net retention reported separately, cohorting, and the cost of '
        'a churn.'),
    (6, 'Pricing'): ('1.5',
        'Margin visibility by package and realised pricing against list.'),
    (6, 'Forecast and confidence'): ('3.4 5.5',
        'Trust in the sales forecast and the largest go-to-market spend that '
        'cannot be connected to an outcome.'),
    (6, 'If sponsor-backed'): ('',
        'Reporting burden and the least-supported growth assumption. Context for '
        'the readout, not element evidence.'),

    (7, 'The last deal you won'): ('5.2 5.3 5.4 H04',
        'What was known before first contact, what discovery established and '
        'where it was recorded, the buying group, and time to proposal.'),
    (7, 'The last deal you lost'): ('5.1',
        'What happened against what was recorded, and when it actually went '
        'wrong. Loss reason capture is scored from the census on 1.3.'),
    (7, 'What you use'): ('2.5',
        'Whether the deck in use is the current shared one, what the rep says '
        'unprompted against the approved claim, and where proof comes from.'),
    (7, 'What arrives from marketing'): ('4.5 H04',
        'What a marketing lead looks like on arrival and whether all are worked.'),
    (7, 'Handover onward'): ('H05',
        'What is handed to delivery, and commitments made outside scope.'),
}

# Questions carrying their own element reference in the source. These add to
# the section's set rather than replacing it.
OVERRIDES = {
    'Show me where that definition lives.': 'H01',
    'Did anything change in targeting or qualification as a result?': 'H08',
    'How many personas do you actively write for, and where does the persona definition come from?': 'H01',
    'Where does a campaign writer get an approved claim and the proof for it?': 'H02',
    'Where does whoever wrote your most recent outbound sequence get the approved message and the proof for it?': 'H02',
    'What information travels to the rep, and where does it appear for them?': 'H04',
    'What happens to the behaviour a contact showed before they filled in the form?': 'H03',
    'Is an expansion deal distinguishable from a new one in the data?': '8.2',
    'On the last customer you onboarded, how did you find out what had been sold?': 'H05',
    'Does the signed scope become the delivery plan, or do you rebuild it?': '6.1',
    'A customer tells you they hit a great result. What happens to that?': 'H06',
    'A customer scores you top marks in a survey. Who acts on that, and how?': 'H07',
    'Give me the last three expansions and tell me which of those it was.': '8.2',
    'What did you know about them before your first conversation, and where did you get it?': 'H04',
    'When you explain what the company does, what do you say?': '2.5',
    'After you close, what do you hand to delivery, and how?': 'H05',
}


def match_override(q):
    stem = q.split('[')[0].strip()
    for k, v in OVERRIDES.items():
        if stem.startswith(k[:60]):
            return v
    return ''


# ------------------------------------------------------------------ build
wb = openpyxl.Workbook()
hdr_font = Font(name='Arial', size=10, bold=True, color='FFFFFFFF')
hdr_fill = PatternFill('solid', start_color=NAVY)
band = PatternFill('solid', start_color=BAND)
body = Font(name='Arial', size=10)
wrap = Alignment(wrap_text=True, vertical='top')


def write(ws, headers, data, widths, freeze):
    for i, h in enumerate(headers, 1):
        c = ws.cell(1, i, h)
        c.font, c.fill, c.alignment = hdr_font, hdr_fill, wrap
    for r, row in enumerate(data, 2):
        for i, v in enumerate(row, 1):
            c = ws.cell(r, i, v)
            c.font, c.alignment = body, wrap
            if r % 2 == 0:
                c.fill = band
    for i, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = freeze
    ws.row_dimensions[1].height = 30


# README
ws = wb.active
ws.title = 'README'
ws.column_dimensions['B'].width = 26
ws.column_dimensions['C'].width = 104
ws['B2'] = 'Blend GEA — Interview Question Map'
ws['B2'].font = Font(name='Arial', size=14, bold=True, color=NAVY)
readme = [
    ('Version', 'v0.3 — read directly from Interview Guides v0.2'),
    ('Purpose',
     'Supplies the question-to-element mapping the application needs for '
     'interview_question_element. The source guides map to elements at guide '
     'level only, which is too coarse for transcript synthesis and leaves H01, '
     'H02 and H06 with no link between the element and the question that '
     'evidences it.'),
    ('How it works',
     'Elements are authored once per section on the Section Map sheet and '
     'expanded to every question in that section at import. Where a question '
     'carries its own element reference in the source document, that reference '
     'is added to the inherited set. The Expanded Mapping sheet is the result '
     'and is what loads.'),
    ('Sections with no element',
     'Five sections carry no element mapping. They gather sponsor authority, '
     'field trustworthiness, stack inventory and cost. Those feed G0, the '
     'intake audit and the TCO model rather than a score.'),
    ('Gaps', 'The Gaps sheet lists two kinds of disagreement between the '
     'guide-level coverage table in the source document and the section '
     'mappings here. Both need a decision before this version is activated.'),
    ('Source', 'Blend GEA_Evidence Kit - Interview Guides v0.2, seven guides, '
     '35 sections, 116 questions.'),
    ('Maintenance', 'Versioned and activated with the instrument. An activated '
     'instrument version cannot be edited.'),
]
for i, (k, v) in enumerate(readme, 4):
    ws.cell(i, 2, k).font = Font(name='Arial', size=10, bold=True)
    c = ws.cell(i, 3, v)
    c.font, c.alignment = body, wrap
    ws.row_dimensions[i].height = max(15, 13 * (len(v) // 100 + 1))

# Section Map
rows = []
for (g, sec), (els, basis) in SECTION_MAP.items():
    n = sum(1 for q in QS if q['guide'] == g and q['section'] == sec)
    title = next(q['guide_title'] for q in QS if q['guide'] == g)
    rows.append([g, title, sec, n, els, basis])
ws = wb.create_sheet('Section Map')
write(ws, ['Guide', 'Guide title', 'Section', 'Questions', 'Elements',
           'Basis for the mapping'],
      rows, [7, 26, 40, 11, 20, 62], 'D2')

# Expanded Mapping
rows = []
for q in QS:
    sec_els = SECTION_MAP[(q['guide'], q['section'])][0].split()
    ov = match_override(q['question'])
    final = list(dict.fromkeys(sec_els + ([ov] if ov else [])))
    rows.append([q['guide'], q['section'], q['question'],
                 ' '.join(sec_els), ov, ' '.join(final)])
ws = wb.create_sheet('Expanded Mapping')
write(ws, ['Guide', 'Section', 'Question', 'From section',
           'Question override', 'Elements loaded'],
      rows, [7, 32, 72, 18, 14, 20], 'D2')

# Gaps
gaps = []
for g, decl in GUIDE_DECLARED.items():
    declared = set(decl.split())
    mapped = set()
    for (gg, sec), (els, _) in SECTION_MAP.items():
        if gg == g:
            mapped.update(els.split())
    for q in QS:
        if q['guide'] == g:
            ov = match_override(q['question'])
            if ov:
                mapped.add(ov)
    title = next(q['guide_title'] for q in QS if q['guide'] == g)
    for e in sorted(declared - mapped):
        gaps.append([g, title, e, 'Declared, not mapped',
                     'The guide coverage table claims this element but no '
                     'section asks about it. Either a question is missing from '
                     'the guide or the claim should be dropped.'])
    for e in sorted(mapped - declared):
        gaps.append([g, title, e, 'Mapped, not declared',
                     'A section asks about this element but the guide coverage '
                     'table omits it. The coverage table needs the addition.'])
ws = wb.create_sheet('Gaps')
write(ws, ['Guide', 'Guide title', 'Element', 'Kind', 'What it means'],
      gaps, [7, 26, 10, 22, 78], 'D2')

wb.save('/mnt/user-data/outputs/Blend GEA_Interview Question Map_v0.3.xlsx')
print(f'{len(SECTION_MAP)} sections, {len(QS)} questions, {len(gaps)} gaps')
for row in gaps:
    print(f'  G{row[0]} {row[2]:5} {row[3]}')
