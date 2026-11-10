-- Fix exact canonical answer priority when an alias overlaps another answer.

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
        order by match_score desc, (public.krillion_normalize_answer(b.canonical_answer) = v_norm) desc, length(b.canonical_answer) asc
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
          order by match_score desc, (public.krillion_normalize_answer(sk.name) = v_norm) desc, length(sk.name) asc
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

