-- 031 G2 requires the revenue paths committed.
--
-- G2 is the gate into Stage 3 and final scoring. Committing the paths belongs
-- behind it for the same reason everything else there does: after this point
-- the work is judgement rather than evidence gathering, and the model the
-- judgement rests on should have stopped moving.
--
-- The gate conditions live in docs/rules-and-gates.md and are enforced by the
-- application rather than in SQL, because most of them need a person to
-- confirm something. This records the condition so the application has one
-- place to read them from, rather than each screen carrying its own copy.

create table gate_condition (
  id          uuid primary key default gen_random_uuid(),
  gate_ref    text not null check (gate_ref in ('G0','G1','G2','G3','G4','G5')),
  ref         text not null,
  statement   text not null,
  consequence text not null,
  needs_human_confirmation boolean not null default false,
  sort_order  integer not null,
  unique (gate_ref, ref)
);

comment on table gate_condition is
  'What each gate tests. The application checks these; it does not invent its '
  'own. A condition that cannot be met is waived by the gate authoriser with a '
  'reason, and the consequence is applied.';

alter table gate_condition enable row level security;
create policy gate_condition_read on gate_condition
  for select to authenticated using (app_is_blend_user());

insert into gate_condition (gate_ref, ref, statement, consequence, needs_human_confirmation, sort_order) values
('G2','G2-1','Every supported analysis has been run and either accepted or discarded with a reason',
 'Scoring from analyses nobody reviewed means the figures behind a score have not been checked.', false, 10),
('G2','G2-2','Every classification run carries a validation set marked trustworthy, or is recorded as abandoned',
 'An unvalidated classified rate is a guess with a number attached.', false, 20),
('G2','G2-3','Every interview has been held, or recorded as declined with the consequence applied',
 'A missing interview caps the elements it was the evidence for.', false, 30),
('G2','G2-4','The revenue paths are committed',
 'The waterfall and the per-path figures are built from the paths. Changing them afterwards means rebuilding the model and rerunning anything cut by path.', false, 35),
('G2','G2-5','Most of the forty-eight elements carry a provisional score',
 'Scoring everything for the first time in week five leaves no time to go back for thin evidence.', false, 40),
('G2','G2-6','Every outstanding evidence item names its element and the score that follows from the gap',
 'An outstanding list without consequences is a list nobody acts on.', false, 50),
('G2','G2-7','Each outstanding item has been requested from the client',
 'Closing the stage without asking means the gap becomes a limitation by default rather than by decision.', true, 60),
('G2','G2-8','No analysis run is left unreviewed',
 'An unreviewed run is evidence nobody has looked at.', false, 70);

insert into gea_migration (filename, note) values
  ('031_g2_requires_committed_paths.sql',
   'Gate conditions are recorded rather than reimplemented per screen. G2 '
   'requires the revenue paths committed.');
