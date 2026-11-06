-- Cougar Krillion school knowledge database
-- Run once in Supabase SQL Editor. Teachers manage entries from the Admin page.

create table if not exists public.school_knowledge (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 100),
  category text not null check (category in ('Teachers','Administrators','Coaches','Sports teams','Clubs','School locations','Other')),
  aliases text[] not null default '{}',
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists school_knowledge_active_category_idx
  on public.school_knowledge(category, name) where is_active = true;

alter table public.school_knowledge enable row level security;

-- Only authorized teachers can view or manage the list through the browser.
drop policy if exists "Teachers manage school knowledge" on public.school_knowledge;
create policy "Teachers manage school knowledge"
  on public.school_knowledge
  for all
  to authenticated
  using (public.is_current_user_teacher())
  with check (public.is_current_user_teacher());

revoke all on public.school_knowledge from anon, public;
grant select, insert, update, delete on public.school_knowledge to authenticated;
grant all on public.school_knowledge to service_role;
