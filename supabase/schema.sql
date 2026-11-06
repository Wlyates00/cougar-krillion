-- Cougar Krillion / Supabase setup. Run in Supabase SQL Editor.
-- Also enable Authentication > Providers > Anonymous sign-ins.
create extension if not exists pgcrypto;

create table if not exists public.questions (
 id uuid primary key default gen_random_uuid(), prompt text not null check(char_length(prompt) between 5 and 240),
 category text not null default 'General', is_active boolean not null default true, created_at timestamptz not null default now()
);
create unique index if not exists questions_prompt_unique on public.questions(lower(prompt));
create table if not exists public.teacher_users(user_id uuid primary key references auth.users(id) on delete cascade,created_at timestamptz not null default now());
create table if not exists public.daily_challenges(
 challenge_date date primary key, question_ids uuid[] not null check(array_length(question_ids,1)=7), created_at timestamptz not null default now()
);
create table if not exists public.submissions(
 id uuid primary key default gen_random_uuid(), player_id uuid not null references auth.users(id) on delete cascade,
 challenge_date date not null, submitted_at timestamptz not null default now(), unique(player_id,challenge_date)
);
create table if not exists public.submission_answers(
 id uuid primary key default gen_random_uuid(), submission_id uuid not null references public.submissions(id) on delete cascade,
 question_id uuid not null references public.questions(id), answer_text text not null check(char_length(answer_text) between 1 and 60),
 normalized_answer text generated always as(trim(regexp_replace(lower(answer_text),'[^a-z0-9 ]','','g'))) stored,
 review_status text not null default 'pending' check(review_status in ('pending','approved','rejected')), ai_verdict text check(ai_verdict in ('valid','invalid','uncertain')), ai_reason text, reviewed_at timestamptz,
 unique(submission_id,question_id)
);
create index if not exists submissions_date_idx on public.submissions(challenge_date);
create index if not exists answers_question_normalized_idx on public.submission_answers(question_id,normalized_answer) where review_status='approved';

create or replace function public.is_current_user_teacher() returns boolean
language sql stable security definer set search_path=public,auth
as $$ select exists(select 1 from public.teacher_users where user_id=auth.uid()); $$;

alter table public.questions enable row level security;
alter table public.teacher_users enable row level security;
alter table public.daily_challenges enable row level security;
revoke all on public.daily_challenges from anon,authenticated;
alter table public.submissions enable row level security;
alter table public.submission_answers enable row level security;
drop policy if exists "Anyone can read active questions" on public.questions;
create policy "Anyone can read active questions" on public.questions for select to anon,authenticated using(is_active or public.is_current_user_teacher());
drop policy if exists "Teachers manage questions" on public.questions;
create policy "Teachers manage questions" on public.questions for all to authenticated using(public.is_current_user_teacher()) with check(public.is_current_user_teacher());
drop policy if exists "Users can read own submission" on public.submissions;
create policy "Users can read own submission" on public.submissions for select to authenticated using(player_id=auth.uid() or public.is_current_user_teacher());
drop policy if exists "Users can read own answers" on public.submission_answers;
create policy "Users can read own answers" on public.submission_answers for select to authenticated using(exists(select 1 from public.submissions s where s.id=submission_id and (s.player_id=auth.uid() or public.is_current_user_teacher())));
drop policy if exists "Teachers manage answer review" on public.submission_answers;
create policy "Teachers manage answer review" on public.submission_answers for update to authenticated using(public.is_current_user_teacher()) with check(public.is_current_user_teacher());

-- Freeze the seven selected question IDs for the day so all students see the same prompts.
create or replace function public.get_daily_challenge(p_date date default (now() at time zone 'America/New_York')::date)
returns table(question_id uuid,prompt text,category text) language plpgsql security definer set search_path=public,auth
as $$
declare v_ids uuid[];
begin
 if p_date<>(now() at time zone 'America/New_York')::date then raise exception 'Only today’s challenge is available.'; end if;
 select question_ids into v_ids from public.daily_challenges where challenge_date=p_date;
 if v_ids is null then
  select array_agg(id order by md5(id::text || p_date::text)) into v_ids from (select id from public.questions where is_active=true order by md5(id::text || p_date::text) limit 7) chosen;
  if coalesce(array_length(v_ids,1),0)<>7 then raise exception 'The teacher must publish at least seven active questions.'; end if;
  insert into public.daily_challenges(challenge_date,question_ids) values(p_date,v_ids) on conflict(challenge_date) do nothing;
  select question_ids into v_ids from public.daily_challenges where challenge_date=p_date;
 end if;
 return query select q.id,q.prompt,q.category from unnest(v_ids) with ordinality picked(id,ord) join public.questions q on q.id=picked.id order by picked.ord;
end; $$;

-- Student submissions are handled by the submit-daily-challenge Edge Function.
-- The function validates with OpenAI and calls this service-role-only RPC.
create or replace function public.submit_ai_validated_daily_challenge(p_player_id uuid,p_date date,p_answers jsonb) returns uuid
language plpgsql security definer set search_path=public,auth
as $$
declare v_submission uuid;
begin
 if p_player_id is null then raise exception 'Player account is required.'; end if;
 if p_date<>(now() at time zone 'America/New_York')::date then raise exception 'This challenge date is no longer active. Refresh the page.'; end if;
 if jsonb_typeof(p_answers)<>'array' or jsonb_array_length(p_answers)<>7 then raise exception 'A complete challenge requires exactly seven validated answers.'; end if;
 if exists(select 1 from jsonb_array_elements(p_answers) a where coalesce(trim(a->>'answer'),'')='' or char_length(a->>'answer')>60) then raise exception 'Each answer must contain 1 to 60 characters.'; end if;
 if exists(select 1 from jsonb_array_elements(p_answers) a where coalesce(a->>'verdict','') not in ('valid','uncertain')) then raise exception 'Only AI-approved or uncertain answers can be stored.'; end if;
 if (select count(distinct(a->>'question_id')) from jsonb_array_elements(p_answers) a)<>7 then raise exception 'Each question must be answered exactly once.'; end if;
 if not exists(select 1 from public.daily_challenges d where d.challenge_date=p_date) then raise exception 'Today’s challenge has not been initialized. Refresh the page.'; end if;
 if exists(select 1 from jsonb_array_elements(p_answers) a where not exists(select 1 from public.daily_challenges d, unnest(d.question_ids) qid where d.challenge_date=p_date and qid=(a->>'question_id')::uuid)) then raise exception 'One or more questions do not belong to today’s challenge.'; end if;
 insert into public.submissions(player_id,challenge_date) values(p_player_id,p_date) returning id into v_submission;
 insert into public.submission_answers(submission_id,question_id,answer_text,review_status,ai_verdict,ai_reason,reviewed_at)
 select v_submission,(a->>'question_id')::uuid,trim(a->>'answer'),case when a->>'verdict'='valid' then 'approved' else 'pending' end,a->>'verdict',left(coalesce(a->>'reason',''),500),case when a->>'verdict'='valid' then now() else null end
 from jsonb_array_elements(p_answers) a;
 return v_submission;
exception when unique_violation then raise exception 'You have already submitted today’s challenge.';
end; $$;

-- A unique approved answer is 100 points. If two players give the same answer to the same question, each gets 50, etc.
create or replace function public.get_daily_leaderboard(p_date date default (now() at time zone 'America/New_York')::date)
returns table(player_id uuid,score bigint) language sql stable security definer set search_path=public
as $$
 with approved as(
  select s.player_id,a.question_id,a.normalized_answer,count(*) over(partition by a.question_id,a.normalized_answer) answer_count
  from public.submission_answers a join public.submissions s on s.id=a.submission_id
  where s.challenge_date=p_date and a.review_status='approved' and a.normalized_answer<>'' and a.answer_text<>'No answer'
 ), totals as(select player_id,sum(floor(100.0/answer_count))::bigint points from approved group by player_id)
 select t.player_id,t.points from totals t order by t.points desc,t.player_id asc;
$$;

create or replace function public.teacher_get_answer_queue(p_status text default 'pending')
returns table(answer_id uuid,answer_text text,question_prompt text,player_id uuid,challenge_date date,review_status text,ai_verdict text,ai_reason text)
language plpgsql security definer set search_path=public,auth
as $$ begin
 if not public.is_current_user_teacher() then raise exception 'Teacher access required.'; end if;
 if p_status not in('pending','approved','rejected') then raise exception 'Invalid review status.'; end if;
 return query select a.id,a.answer_text,q.prompt,s.player_id,s.challenge_date,a.review_status,a.ai_verdict,a.ai_reason from public.submission_answers a
 join public.submissions s on s.id=a.submission_id join public.questions q on q.id=a.question_id
 where a.review_status=p_status order by s.submitted_at desc,a.id;
end; $$;
create or replace function public.teacher_review_answer(p_answer_id uuid,p_status text) returns void
language plpgsql security definer set search_path=public,auth
as $$ begin
 if not public.is_current_user_teacher() then raise exception 'Teacher access required.'; end if;
 if p_status not in('approved','rejected','pending') then raise exception 'Invalid review status.'; end if;
 update public.submission_answers set review_status=p_status,reviewed_at=case when p_status='pending' then null else now() end where id=p_answer_id;
 if not found then raise exception 'Answer not found.'; end if;
end; $$;

revoke all on function public.get_daily_challenge(date) from public;
revoke all on function public.submit_ai_validated_daily_challenge(uuid,date,jsonb) from public,anon,authenticated;
revoke all on function public.get_daily_leaderboard(date) from public;
revoke all on function public.teacher_get_answer_queue(text) from public;
revoke all on function public.teacher_review_answer(uuid,text) from public;
revoke all on function public.is_current_user_teacher() from public;
grant execute on function public.get_daily_challenge(date) to anon,authenticated;
grant execute on function public.submit_ai_validated_daily_challenge(uuid,date,jsonb) to service_role;
grant execute on function public.get_daily_leaderboard(date) to anon,authenticated;
grant execute on function public.teacher_get_answer_queue(text) to authenticated;
grant execute on function public.teacher_review_answer(uuid,text) to authenticated;
grant execute on function public.is_current_user_teacher() to authenticated;
grant select on public.questions to anon,authenticated;
grant select on public.submissions,public.submission_answers to authenticated;
grant insert,update on public.questions to authenticated;
grant update on public.submission_answers to authenticated;

insert into public.questions(prompt,category) values
('Name something students get in trouble for.','School life'),('Name something you might find in a teacher’s classroom.','Classrooms'),('Name something students forget to bring to school.','School life'),('Name a place inside a school building.','Places'),('Name something you might hear a teacher say.','Teachers'),('Name something students carry in a backpack.','School life'),('Name something that can go wrong with a school computer.','Technology'),('Name a school event.','Traditions'),('Name something found in a gym.','Sports'),('Name a reason someone might be late to school.','School life'),('Name a school supply.','School life'),('Name a website students use for school.','Technology'),('Name something you might see in the cafeteria.','Cafeteria'),('Name something students do when the bell rings.','School life'),('Name a device used during the school day.','Technology'),('Name something you might find in a hallway.','Places'),('Name a subject taught in high school.','Classes'),('Name something students look forward to.','School life'),('Name something a substitute teacher might need help with.','Teachers'),('Name something you might hear at a school sporting event.','Sports'),('Name something students do during a fire drill.','School life'),('Name a computer accessory.','Technology'),('Name something that makes a school day feel longer.','School life'),('Name something you might see at a school game.','Sports'),('Name something that might be written on a classroom board.','Classrooms'),('Name something students might borrow from a friend.','School life'),('Name something that can make a classroom noisy.','Classrooms'),('Name a reason a student might visit the office.','School life'),('Name something that might be in a teacher’s desk drawer.','Teachers'),('Name something students do while waiting for class to start.','School life')
on conflict do nothing;

-- Create a teacher account in Supabase Auth, then authorize it with:
-- insert into public.teacher_users(user_id) select id from auth.users where email='YOUR-TEACHER-EMAIL';
