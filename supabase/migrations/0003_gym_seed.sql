-- Default push/pull/legs split so gym mode works out of the box.
-- Edit rows in the workouts table to change the split — no code involved.
insert into workouts (name, split_day, exercises)
select * from (values
  ('Push Day', 'push', '["Bench Press","Overhead Press","Incline Dumbbell Press","Lateral Raise","Tricep Pushdown"]'::jsonb),
  ('Pull Day', 'pull', '["Deadlift","Lat Pulldown","Barbell Row","Face Pull","Bicep Curl"]'::jsonb),
  ('Leg Day', 'legs', '["Squat","Romanian Deadlift","Leg Press","Leg Curl","Calf Raise"]'::jsonb)
) as seed(name, split_day, exercises)
where not exists (select 1 from workouts);
