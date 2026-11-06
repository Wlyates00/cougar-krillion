-- Cougar Krillion AI validation + automatic scoring migration
-- Run this once in Supabase SQL Editor after deploying the Edge Function.
alter table public.submission_answers add column if not exists ai_verdict text, add column if not exists ai_reason text;
do $$ begin if not exists (select 1 from pg_constraint where conname='submission_answers_ai_verdict_check') then alter table public.submission_answers add constraint submission_answers_ai_verdict_check check (ai_verdict is null or ai_verdict in ('valid','invalid','uncertain')); end if; end $$;
revoke all on function public.submit_daily_challenge(date,jsonb) from public,anon,authenticated;
create or replace function public.submit_ai_validated_daily_challenge(p_player_id uuid,p_date date,p_answers jsonb) returns uuid
language plpgsql security definer set search_path=public,auth as $$
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
 select v_submission,(a->>'question_id')::uuid,trim(a->>'answer'),case when a->>'verdict'='valid' then 'approved' else 'pending' end,a->>'verdict',left(coalesce(a->>'reason',''),500),case when a->>'verdict'='valid' then now() else null end from jsonb_array_elements(p_answers) a;
 return v_submission;
exception when unique_violation then raise exception 'You have already submitted today’s challenge.';
end; $$;
revoke all on function public.submit_ai_validated_daily_challenge(uuid,date,jsonb) from public,anon,authenticated;
grant execute on function public.submit_ai_validated_daily_challenge(uuid,date,jsonb) to service_role;
drop function if exists public.teacher_get_answer_queue(text);
create function public.teacher_get_answer_queue(p_status text default 'pending') returns table(answer_id uuid,answer_text text,question_prompt text,player_id uuid,challenge_date date,review_status text,ai_verdict text,ai_reason text)
language plpgsql security definer set search_path=public,auth as $$ begin
 if not public.is_current_user_teacher() then raise exception 'Teacher access required.'; end if;
 if p_status not in('pending','approved','rejected') then raise exception 'Invalid review status.'; end if;
 return query select a.id,a.answer_text,q.prompt,s.player_id,s.challenge_date,a.review_status,a.ai_verdict,a.ai_reason from public.submission_answers a join public.submissions s on s.id=a.submission_id join public.questions q on q.id=a.question_id where a.review_status=p_status order by s.submitted_at desc,a.id;
end; $$;
revoke all on function public.teacher_get_answer_queue(text) from public;
grant execute on function public.teacher_get_answer_queue(text) to authenticated;
