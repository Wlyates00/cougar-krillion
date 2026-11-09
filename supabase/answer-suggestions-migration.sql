-- Public, daily-only answer suggestions for the two-Enter correction UI.
-- This deliberately exposes only answer-bank entries for today's seven questions,
-- rather than granting anonymous users direct SELECT access to the full answer bank.

create or replace function public.get_daily_answer_bank(
  p_date date default (now() at time zone 'America/New_York')::date
)
returns table(question_id uuid, canonical_answer text, aliases text[])
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_question_ids uuid[];
begin
  if p_date <> (now() at time zone 'America/New_York')::date then
    raise exception 'Only today’s answer suggestions are available.';
  end if;

  select question_ids into v_question_ids
  from public.daily_challenges
  where challenge_date = p_date;

  if coalesce(array_length(v_question_ids, 1), 0) <> 7 then
    raise exception 'Today’s challenge is not initialized. Refresh the page.';
  end if;

  return query
    select b.question_id, b.canonical_answer, b.aliases
    from public.question_answer_bank b
    where b.question_id = any(v_question_ids)
      and b.is_active = true
    order by b.question_id, b.canonical_answer;
end;
$$;

revoke all on function public.get_daily_answer_bank(date) from public;
grant execute on function public.get_daily_answer_bank(date) to anon, authenticated;
