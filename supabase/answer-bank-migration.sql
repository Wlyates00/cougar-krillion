-- Cougar Krillion: replace live AI answer validation with deterministic answer-bank matching.
-- Run once in Supabase SQL Editor after the prior app schema and any existing timeout/school-knowledge migrations.

create extension if not exists fuzzystrmatch;

create or replace function public.krillion_normalize_answer(p_text text)
returns text
language sql immutable parallel safe
as $$
  select trim(regexp_replace(lower(regexp_replace(coalesce(p_text, ''), '[^[:alnum:]]+', ' ', 'g')), '[[:space:]]+', ' ', 'g'));
$$;

create table if not exists public.question_answer_bank (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id) on delete cascade,
  canonical_answer text not null check (char_length(trim(canonical_answer)) between 1 and 100),
  aliases text[] not null default '{}',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists question_answer_bank_canonical_unique
  on public.question_answer_bank(question_id, lower(canonical_answer));
create index if not exists question_answer_bank_question_idx
  on public.question_answer_bank(question_id) where is_active = true;

alter table public.question_answer_bank enable row level security;
drop policy if exists "Teachers manage question answer bank" on public.question_answer_bank;
create policy "Teachers manage question answer bank"
  on public.question_answer_bank for all to authenticated
  using (public.is_current_user_teacher())
  with check (public.is_current_user_teacher());
revoke all on public.question_answer_bank from anon, public;
grant select, insert, update, delete on public.question_answer_bank to authenticated;
grant all on public.question_answer_bank to service_role;

alter table public.submission_answers add column if not exists canonical_answer text;
alter table public.submission_answers drop column if exists ai_verdict;
alter table public.submission_answers drop column if exists ai_reason;

-- Retire the AI-only database entry points and replace the teacher queue.
drop function if exists public.submit_ai_validated_daily_challenge(uuid,date,jsonb);
drop function if exists public.teacher_get_answer_queue(text);
drop function if exists public.teacher_review_answer(uuid,text);

create or replace function public.submit_answer_bank_daily_challenge(p_date date, p_answers jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, auth, extensions
as $$
declare
  v_player uuid := auth.uid();
  v_submission uuid;
  v_item jsonb;
  v_question_id uuid;
  v_prompt text;
  v_answer text;
  v_norm text;
  v_canonical text;
  v_best_score real;
  v_results jsonb := '[]'::jsonb;
  v_status text;
  v_question_ids uuid[];
begin
  if v_player is null then raise exception 'Sign in before submitting.'; end if;
  if p_date <> (now() at time zone 'America/New_York')::date then
    raise exception 'Today’s challenge date has expired. Refresh the page.';
  end if;
  if jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) <> 7 then
    raise exception 'A complete challenge requires exactly seven answers.';
  end if;
  if (select count(distinct (x->>'question_id')) from jsonb_array_elements(p_answers) x) <> 7 then
    raise exception 'Each question must be answered exactly once.';
  end if;
  select question_ids into v_question_ids from public.daily_challenges where challenge_date = p_date;
  if coalesce(array_length(v_question_ids, 1), 0) <> 7 then
    raise exception 'Today’s challenge is not initialized. Refresh the page.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_answers) x
    where not ((x->>'question_id')::uuid = any(v_question_ids))
  ) then raise exception 'One or more questions do not belong to today’s challenge.'; end if;

  insert into public.submissions(player_id, challenge_date)
  values (v_player, p_date) returning id into v_submission;

  for v_item in select value from jsonb_array_elements(p_answers)
  loop
    v_question_id := (v_item->>'question_id')::uuid;
    v_answer := left(trim(coalesce(v_item->>'answer', '')), 60);
    v_norm := public.krillion_normalize_answer(v_answer);
    select prompt into v_prompt from public.questions where id = v_question_id;
    if v_prompt is null then raise exception 'A question could not be found.'; end if;

    v_canonical := null;
    v_best_score := 0;

    if v_norm <> '' and v_norm <> 'no answer' then
      -- First match the question's explicit answer bank (canonical answer + aliases).
      select candidate.canonical_answer, candidate.match_score
        into v_canonical, v_best_score
      from (
        select b.canonical_answer,
          case when public.krillion_normalize_answer(alias_value) = v_norm then 1000
               else -levenshtein(public.krillion_normalize_answer(alias_value), v_norm) end as match_score
        from public.question_answer_bank b
        cross join lateral unnest(array_prepend(b.canonical_answer, coalesce(b.aliases, '{}'::text[]))) as u(alias_value)
        where b.question_id = v_question_id and b.is_active
          and (public.krillion_normalize_answer(alias_value) = v_norm
               or (length(v_norm) >= 5 and levenshtein_less_equal(public.krillion_normalize_answer(alias_value), v_norm, 2) <= case when greatest(length(public.krillion_normalize_answer(alias_value)), length(v_norm)) >= 9 then 2 else 1 end))
        order by match_score desc, length(b.canonical_answer) asc
        limit 1
      ) candidate;

      -- If no question-specific entry matches, use school knowledge only when the prompt
      -- clearly asks for the corresponding kind of school-specific item.
      if v_canonical is null then
        select candidate.canonical_answer, candidate.match_score
          into v_canonical, v_best_score
        from (
          select sk.name as canonical_answer,
            case when public.krillion_normalize_answer(alias_value) = v_norm then 1000
                 else -levenshtein(public.krillion_normalize_answer(alias_value), v_norm) end as match_score
          from public.school_knowledge sk
          cross join lateral unnest(array_prepend(sk.name, coalesce(sk.aliases, '{}'::text[]))) as u(alias_value)
          where sk.is_active
            and (
              ((v_prompt ilike 'name a teacher%' or v_prompt ilike 'name one of the teachers%' or v_prompt ilike 'who is a teacher%') and sk.category = 'Teachers') or
              ((v_prompt ilike 'name a school administrator%' or v_prompt ilike 'name the principal%' or v_prompt ilike 'who is the principal%') and sk.category = 'Administrators') or
              ((v_prompt ilike 'name a coach%' or v_prompt ilike 'name one of the coaches%') and sk.category = 'Coaches') or
              ((v_prompt ilike 'name a school team%' or v_prompt ilike 'name a sports team%' or v_prompt ilike 'name a team%' or v_prompt ilike 'what is the school mascot%') and sk.category = 'Sports teams') or
              ((v_prompt ilike 'name a school club%' or v_prompt ilike 'name a club%') and sk.category = 'Clubs') or
              ((v_prompt ilike 'name a place inside a school%' or v_prompt ilike 'name a place in the school%' or v_prompt ilike 'name a school location%') and sk.category = 'School locations')
            )
            and (public.krillion_normalize_answer(alias_value) = v_norm
                 or (length(v_norm) >= 5 and levenshtein_less_equal(public.krillion_normalize_answer(alias_value), v_norm, 2) <= case when greatest(length(public.krillion_normalize_answer(alias_value)), length(v_norm)) >= 9 then 2 else 1 end))
          order by match_score desc, length(sk.name) asc
          limit 1
        ) candidate;
      end if;
    end if;

    if v_norm = '' or v_norm = 'no answer' then
      v_status := 'rejected';
      v_canonical := null;
    elsif v_canonical is not null then
      v_status := 'approved';
    else
      v_status := 'pending';
    end if;

    insert into public.submission_answers(submission_id, question_id, answer_text, canonical_answer, review_status, reviewed_at)
    values (v_submission, v_question_id, coalesce(nullif(v_answer, ''), 'No answer'), v_canonical, v_status,
            case when v_status in ('approved', 'rejected') then now() else null end);

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'question_id', v_question_id,
      'answer', coalesce(nullif(v_answer, ''), 'No answer'),
      'canonical_answer', v_canonical,
      'status', case when v_status = 'approved' then 'matched' when v_status = 'pending' then 'needs_review' else 'no_answer' end
    ));
  end loop;

  return jsonb_build_object('status', 'submitted', 'submission_id', v_submission, 'results', v_results);
exception when unique_violation then
  raise exception 'You have already submitted today’s challenge.';
end;
$$;

create or replace function public.get_daily_leaderboard(p_date date default (now() at time zone 'America/New_York')::date)
returns table(player_id uuid, score bigint)
language sql stable security definer set search_path = public
as $$
  with approved as (
    select s.player_id, a.question_id,
      coalesce(nullif(public.krillion_normalize_answer(a.canonical_answer), ''), a.normalized_answer) as answer_key,
      count(*) over (
        partition by a.question_id,
        coalesce(nullif(public.krillion_normalize_answer(a.canonical_answer), ''), a.normalized_answer)
      ) as answer_count
    from public.submission_answers a
    join public.submissions s on s.id = a.submission_id
    where s.challenge_date = p_date and a.review_status = 'approved'
      and coalesce(nullif(public.krillion_normalize_answer(a.canonical_answer), ''), a.normalized_answer) <> ''
      and a.answer_text <> 'No answer'
  ), totals as (
    select player_id, sum(floor(100.0 / answer_count))::bigint points
    from approved group by player_id
  )
  select t.player_id, t.points from totals t order by t.points desc, t.player_id asc;
$$;

create or replace function public.teacher_get_answer_queue(p_status text default 'pending')
returns table(answer_id uuid, answer_text text, question_id uuid, question_prompt text, player_id uuid, challenge_date date, review_status text)
language plpgsql security definer set search_path = public, auth
as $$
begin
  if not public.is_current_user_teacher() then raise exception 'Teacher access required.'; end if;
  if p_status not in ('pending', 'approved', 'rejected') then raise exception 'Invalid review status.'; end if;
  return query
    select a.id, a.answer_text, a.question_id, q.prompt, s.player_id, s.challenge_date, a.review_status
    from public.submission_answers a
    join public.submissions s on s.id = a.submission_id
    join public.questions q on q.id = a.question_id
    where a.review_status = p_status
    order by s.submitted_at desc, a.id;
end;
$$;

create or replace function public.teacher_resolve_answer(p_answer_id uuid, p_action text, p_answer_bank_id uuid default null)
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_question_id uuid;
  v_answer text;
  v_canonical text;
  v_aliases text[];
begin
  if not public.is_current_user_teacher() then raise exception 'Teacher access required.'; end if;
  select question_id, answer_text into v_question_id, v_answer
    from public.submission_answers where id = p_answer_id and review_status = 'pending' for update;
  if not found then raise exception 'Pending answer not found.'; end if;

  if p_action = 'reject' then
    update public.submission_answers set review_status = 'rejected', reviewed_at = now() where id = p_answer_id;
    return;
  elsif p_action = 'new' then
    insert into public.question_answer_bank(question_id, canonical_answer)
      values (v_question_id, v_answer)
      on conflict (question_id, (lower(canonical_answer))) do nothing;
    select canonical_answer into v_canonical from public.question_answer_bank
      where question_id = v_question_id and lower(canonical_answer) = lower(v_answer) limit 1;
  elsif p_action = 'alias' and p_answer_bank_id is not null then
    select canonical_answer, aliases into v_canonical, v_aliases
      from public.question_answer_bank where id = p_answer_bank_id and question_id = v_question_id and is_active;
    if not found then raise exception 'Choose an active answer for this question.'; end if;
    if public.krillion_normalize_answer(v_answer) <> public.krillion_normalize_answer(v_canonical)
       and not exists (select 1 from unnest(coalesce(v_aliases, '{}'::text[])) a where public.krillion_normalize_answer(a) = public.krillion_normalize_answer(v_answer)) then
      update public.question_answer_bank set aliases = array_append(coalesce(aliases, '{}'::text[]), v_answer), updated_at = now()
        where id = p_answer_bank_id;
    end if;
  else
    raise exception 'Invalid answer review action.';
  end if;

  update public.submission_answers
    set review_status = 'approved', canonical_answer = v_canonical, reviewed_at = now()
    where question_id = v_question_id and review_status in ('pending', 'approved')
      and public.krillion_normalize_answer(answer_text) = public.krillion_normalize_answer(v_answer);
end;
$$;

revoke all on function public.submit_answer_bank_daily_challenge(date,jsonb) from public, anon;
revoke all on function public.get_daily_leaderboard(date) from public;
revoke all on function public.teacher_get_answer_queue(text) from public;
revoke all on function public.teacher_resolve_answer(uuid,text,uuid) from public;
grant execute on function public.submit_answer_bank_daily_challenge(date,jsonb) to authenticated;
grant execute on function public.get_daily_leaderboard(date) to anon, authenticated;
grant execute on function public.teacher_get_answer_queue(text) to authenticated;
grant execute on function public.teacher_resolve_answer(uuid,text,uuid) to authenticated;

-- Keep the former Edge Function from being used by older clients. Delete its deployed
-- function in Supabase Dashboard > Edge Functions after deploying the frontend update.
