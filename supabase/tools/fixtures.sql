insert into public.nicknames (nickname, person_real_name, created_by_user_id) values
 ('Sir Staplesalot', 'Elien', 'b064ee54-08c8-4d80-863a-b75d6a46b523'),
 ('The Printer Whisperer', 'Karen', '3a5ad158-62db-4852-90b4-e1034adf894d'),
 ('Meeting Ghost', 'Bert', '809714bc-e4c4-4628-b624-94a2803d16de'),
 ('Fridge Bandit', 'Sofie', 'b064ee54-08c8-4d80-863a-b75d6a46b523');
insert into public.poems (author_user_id, title, content, mood) values
 ('b064ee54-08c8-4d80-863a-b75d6a46b523', 'Ode to Coffee', 'Roses are red the coffee is cold the stapler is lost and the meeting is old', 'nonsense'),
 ('3a5ad158-62db-4852-90b4-e1034adf894d', 'Printer Blues', 'It jams on Monday it jams on Friday it jams in between in its own special way', 'nonsense'),
 ('809714bc-e4c4-4628-b624-94a2803d16de', 'Ode to the Fridge', 'Cold and humming in the corner you guard the lunch of all the departed', 'nonsense');
update public.poems set created_at = now() - interval '10 days' where title = 'Ode to Coffee';
