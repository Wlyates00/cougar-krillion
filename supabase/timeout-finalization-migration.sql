-- Cougar Krillion: finalize AI-invalid answers as zero points when correction time expires.
-- Run this once in Supabase SQL Editor before deploying the updated Edge Function.
-- Valid answers are approved and scored, uncertain answers remain pending for teacher review,
-- and invalid answers are stored as rejected so they earn zero points.

create or replace function public.submit_ai_validated_daily_challenge(
  p_player_id uuid,
  p_date date,
  p_answers jsonb
) returns uuid
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  v_submission uuid;
begin
  if p_player_id is null then raise exception 'Player account is required.'; end if;
  if p_date<>(now() at time zone 'America/New_York')::date then
    raise exception 'This challenge date is no longer active. Refresh the page.';
  end if;
  if jsonb_typeof(p_answers)<>'array' or jsonb_array_length(p_answers)<>7 then
    raise exception 'A complete challenge requires exactly seven validated answers.';
  end if;
  if exists(
    select 1 from jsonb_array_elements(p_answers) a
    where coalesce(trim(a->>'answer'),'')='' or char_length(a->>'answer')>60
  ) then raise exception 'Each answer must contain 1 to 60 characters.'; end if;
  if exists(
    select 1 from jsonb_array_elements(p_answers) a
    where coalesce(a->>'verdict','') not in ('valid','invalid','uncertain')
  ) then raise exception 'Each answer must have a recognized AI verdict.'; end if;
  if (select count(distinct(a->>'question_id')) from jsonb_array_elements(p_answers) a)<>7 then
    raise exception 'Each question must be answered exactly once.';
  end if;
  if not exists(select 1 from public.daily_challenges d where d.challenge_date=p_date) then
    raise exception 'Today’s challenge has not been initialized. Refresh the page.';
  end if;
  if exists(
    select 1 from jsonb_array_elements(p_answers) a
    where not exists(
      select 1 from public.daily_challenges d, unnest(d.question_ids) qid
      where d.challenge_date=p_date and qid=(a->>'question_id')::uuid
    )
  ) then raise exception 'One or more questions do not belong to today’s challenge.'; end if;

  insert into public.submissions(player_id,challenge_date)
  values(p_player_id,p_date)
  returning id into v_submission;

  insert into public.submission_answers(
    submission_id,question_id,answer_text,review_status,ai_verdict,ai_reason,reviewed_at
  )
  select
    v_submission,
    (a->>'question_id')::uuid,
    trim(a->>'answer'),
    case
      when a->>'verdict'='valid' then 'approved'
      when a->>'verdict'='invalid' then 'rejected'
      else 'pending'
    end,
    a->>'verdict',
    left(coalesce(a->>'reason',''),500),
    case when a->>'verdict' in ('valid','invalid') then now() else null end
  from jsonb_array_elements(p_answers) a;

  return v_submission;
exception when unique_violation then
  raise exception 'You have already submitted today’s challenge.';
end;
$$;

revoke all on function public.submit_ai_validated_daily_challenge(uuid,date,jsonb) from public,anon,authenticated;
grant execute on function public.submit_ai_validated_daily_challenge(uuid,date,jsonb) to service_role;
