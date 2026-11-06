# Cougar Krillion — live Supabase version

React + Vite daily rare-answer game for Pulaski County High School. Uses Supabase anonymous Auth for student player IDs, Postgres for shared questions/submissions, AI answer validation, automatic scoring, and a school-wide leaderboard.

## 1. Create the Supabase project
1. Create a project at https://supabase.com/.
2. In **Authentication → Providers**, enable **Anonymous sign-ins**.
3. Open **SQL Editor**, paste and run the entire `supabase/schema.sql` file. It creates tables, row-level security, scoring functions, and 30 starter questions. For an existing project, use the AI scoring migration instead (see below).
4. In **Project Settings → API**, copy the Project URL and public anon/publishable key. Never use the service-role/secret key in this frontend.

## 2. Configure and run
1. Copy `.env.example` to `.env`.
2. Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` to your project values.
3. Run `npm install`, then `npm run dev`.
4. Deploy the Vite project to Vercel, Netlify, or another static host. Build command: `npm run build`; output folder: `dist`. Set the same two environment variables in the hosting dashboard.

## 3. Create teacher access
1. In Supabase **Authentication → Users**, create a teacher user with an email and strong password.
2. Run this in SQL Editor, replacing the email:

```sql
insert into public.teacher_users(user_id)
select id from auth.users where email = 'YOUR-TEACHER-EMAIL';
```

Only accounts in `teacher_users` can manage questions or review uncertain answers. There is no public teacher registration or demo PIN.

## Scoring and review
- Each student receives a Supabase anonymous-auth account. The browser persists its session. A server-side daily challenge record freezes the same seven question IDs for every player; the database permits one submission per account per Eastern-time calendar day.
- The server atomically validates a full seven-answer submission and a unique constraint prevents duplicate submissions for the same account/day.
- The AI validates each answer. Clearly relevant answers are approved automatically; clearly irrelevant answers are returned to the student to retry; uncertain answers remain pending for optional teacher review.
- Each approved answer earns `floor(100 / number of approved players with that normalized answer to that question)`. A unique answer is 100 points; two matching answers are 50 each; three are 33 each. Maximum score: 700. Scores update as soon as the AI-approved answers are saved (or when a teacher resolves an uncertain answer).
- Matching ignores case and punctuation. Teachers should approve only relevant, school-appropriate answers and judge equivalent wording consistently.
- Public leaderboard displays anonymous player UUID fragments, not student names or email addresses.

## Important limitations
- Anonymous auth is not a verified student identity. A student may clear browser data or switch devices/browsers to get a new anonymous account. Strong one-student-one-entry enforcement requires school-issued accounts, SSO/roster integration, or individual access codes.
- The 25-second timer is a client-side experience, not a secure deadline. The server enforces the daily one-submission rule and seven-answer structure.
- Keep Supabase rate limits and backups enabled. Never expose a service-role key.

## Files
- `src/App.jsx` — game UI, Supabase calls, teacher workspace
- `src/supabase.js` — Supabase client
- `supabase/schema.sql` — fresh-install database schema, RLS, RPCs, starter questions
- `supabase/ai-scoring-migration.sql` — upgrade script for an existing database
- `supabase/functions/submit-daily-challenge/index.ts` — secure AI validation and submission function
- `.env.example` — required environment variables


## AI answer validation and automatic scoring

Each completed set of seven answers is sent to the `submit-daily-challenge` Supabase Edge Function. It verifies the player's Supabase session, loads the official daily questions, and asks OpenAI to classify each answer:

- `valid`: saved as approved and included in automatic scoring.
- `invalid`: not saved; the student can edit only flagged answers and submit again.
- `uncertain`: saved as pending for teacher review.

### Upgrade an existing Supabase project

1. In Supabase Dashboard → SQL Editor, run `supabase/ai-scoring-migration.sql` once.
2. Deploy `supabase/functions/submit-daily-challenge` (from this project folder, use `supabase functions deploy submit-daily-challenge`).
3. Add `OPENAI_API_KEY` under Supabase Dashboard → Edge Functions → Secrets. Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions. Never put the OpenAI key or service-role key in the React `.env` file.
4. Redeploy the React site.

For a brand-new database, run `supabase/schema.sql` instead of the migration. Do not run both SQL files on a fresh database.

If any answer is clearly irrelevant, the whole challenge remains unsubmitted and the student gets a retry screen for the flagged answers. When all answers are valid or uncertain, valid answers count immediately; uncertain answers stay pending for teacher review. AI/API failures do not approve answers or consume the daily submission. Existing submissions from before this upgrade remain pending and are not automatically reclassified.
