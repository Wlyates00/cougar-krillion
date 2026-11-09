# Cougar Krillion — answer-bank scoring

React + Vite daily rare-answer game for Pulaski County High School. Students use anonymous Supabase accounts. Supabase Postgres stores questions, accepted answers, submissions, teacher review, and the daily leaderboard. **Student answer validation no longer uses OpenAI or a Supabase Edge Function.**

## What changed

- Every question has its own answer bank.
- Each answer has one canonical answer and optional accepted variations.
- Punctuation, capitalization, and extra spaces are normalized.
- Conservative typo matching catches small spelling mistakes (one edit for shorter words and up to two for longer answers).
- Variations of the same canonical answer are grouped together for rarity scoring. For example, `Pack up`, `Packing up`, and `Pack up backpack` can all map to `Pack up`.
- Answers that do not match the question's bank are placed in the teacher review queue. Teachers can reject them, add them as variations of an existing answer, or approve them as a new canonical answer.
- The School Knowledge list is retained. Entries are used only for clearly school-specific prompts such as “Name a teacher,” “Name a coach,” or “Name a school team.”
- There is no AI correction screen or 30-second correction window. The existing 25-second timer remains for each question.

## 1. Update an existing Cougar Krillion Supabase project

Do these steps in order. You already ran the earlier AI, timeout, and school-knowledge migrations, so **do not rerun those old migrations**.

1. Open Supabase Dashboard → SQL Editor.
2. Open `supabase/answer-bank-migration.sql` from this project.
3. Copy the entire file into SQL Editor and click **Run**. Run this migration once. It creates the question answer bank, adds canonical-answer tracking, replaces the AI submission RPC with deterministic matching, and updates the leaderboard to group answer variations together.
4. Keep the SQL Editor result visible. If it reports an error, stop and resolve that before deploying the frontend.

This migration preserves existing submissions. Previously AI-approved answers continue to score using their original normalized text. Previously pending answers remain available in the teacher review queue; review them and add them to the appropriate answer bank entries.

## 2. Update the local project safely

Do not replace your entire Git repository folder with the ZIP. Keep your existing `.git` folder and `.env` file.

Copy these updated project files into your existing `cougar-krillion` folder:

- `src/App.jsx`
- `src/styles.css`
- `supabase/schema.sql` (reference for fresh installs only)
- `supabase/answer-bank-migration.sql`
- `README.md`

The old `supabase/functions/submit-daily-challenge/` function is no longer included or used. Do not deploy it again.

In Terminal, from the project folder, run:

```bash
npm install
npm run build
```

If the build succeeds, commit and push the changes:

```bash
git add src/App.jsx src/styles.css README.md supabase/answer-bank-migration.sql supabase/schema.sql
git commit -m "Replace AI scoring with question answer bank"
git push origin main
```

Vercel should deploy the updated frontend automatically. Keep your existing Vercel environment variables (`VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`).

## 3. Remove the old AI service

After the new frontend is deployed and you confirm it is submitting through the answer bank:

1. In Supabase Dashboard → Edge Functions, delete the old `submit-daily-challenge` function. The new frontend no longer calls it.
2. In Supabase Dashboard → Edge Functions → Secrets, remove `OPENAI_API_KEY` if you added it for this project. Do not remove your Supabase project URL, anon key, or any Supabase-managed secrets.
3. You do not need to deploy a replacement Edge Function. The database RPC performs the matching and submission.

The old `ai-scoring-migration.sql` and `timeout-finalization-migration.sql` files are retained as historical upgrade files; they are not part of the new setup and should not be run again.

## 4. Populate the answer bank

This is important: **the answer bank starts empty.** Before students play a question for points, add the accepted answers for that question in Admin → Question answer bank.

For example, for “Name something students do before leaving class”:

- Canonical answer: `Pack up`
- Accepted variations: `Packing up, Pack up backpack, Put away my stuff, Pack my things`

Add other distinct canonical answers separately, such as `Clean up`, with their own variations. The system will treat all variations in one group as the same answer when calculating rarity.

You can add, edit, or deactivate canonical answers and their variations from Admin. Use the question dropdown to choose which question the entry belongs to.

## 5. How spelling and new answers work

- Exact matches ignore capitalization, punctuation, and repeated spaces.
- Conservative edit-distance matching recognizes small typos in words of at least five characters. It does not rewrite the student's stored answer; it maps the answer to the canonical answer for scoring.
- Longer wording differences should be entered as accepted variations. For example, `Pack up backpack` is not just a spelling mistake, so add it explicitly as an alias of `Pack up`.
- If the system cannot safely match an answer, it goes to Admin → Unrecognized answers and earns no points until reviewed.
- A teacher can choose an existing canonical answer and click **Add as variation**, click **Approve as new answer** to create a new canonical answer, or reject it.
- When an answer is approved as a variation, that submission is attached to the selected canonical answer. Future students using that variation will match automatically.

## 6. School-specific answers

Keep using Admin → School knowledge to manage teachers, administrators, coaches, teams, clubs, and school locations. The matching function consults the relevant category only when the prompt clearly asks for that kind of school-specific answer. For custom wording that does not fit those prompt patterns, add the names directly to that question's answer bank as well.

## Scoring

Each approved canonical answer is worth `floor(100 / number of approved players with that same canonical answer to that question)`. A unique answer is 100 points; two players with the same canonical answer each receive 50; three receive 33 each. All listed variations of a canonical answer share that rarity group. The maximum daily score is 700 points.

New/unrecognized answers stay pending and do not count until a teacher resolves them. The leaderboard recalculates after teacher review.

## Fresh installation

For a brand-new Supabase project, enable Authentication → Providers → Anonymous sign-ins, then run the complete `supabase/schema.sql` file in SQL Editor. The answer-bank schema and deterministic submission functions are included at the end of that file. Create and authorize a teacher account using the instructions at the bottom of `schema.sql`.

## Important limitations

- Fuzzy spelling matching is deliberately conservative. It catches small typos, not arbitrary paraphrases. Add common ways of saying an answer as explicit variations.
- An answer bank is question-specific. The same word can be valid for one question and invalid for another.
- Anonymous auth is not a verified student identity. A student can clear browser data or switch devices to create a new anonymous account.
- The 25-second per-question timer is a client-side experience, not a tamper-proof deadline.
- Keep Supabase backups and rate limits enabled. Never expose a service-role key.

## Key files

- `src/App.jsx` — game UI, answer submission, teacher workspace
- `src/styles.css` — game and admin styling
- `src/supabase.js` — Supabase browser client
- `supabase/schema.sql` — complete fresh-install schema
- `supabase/answer-bank-migration.sql` — upgrade for an existing AI-scoring project
- `.env.example` — required frontend environment variables

## Bulk importing accepted answers (JSON)

Teachers can import many canonical answers and accepted variations from the Admin → Question answer bank section. Use the downloadable `public/answer-bank-template.json` as a starting point. Each question must match an existing active question prompt (or its question UUID) and each answer group has a `canonical` value plus an optional `aliases` array.

Example:

```json
{
  "questions": [
    {
      "question": "Name something students do before leaving class.",
      "answers": [
        { "canonical": "Pack up", "aliases": ["Packing up", "Pack up backpack"] },
        { "canonical": "Clean up", "aliases": ["Clean my desk"] }
      ]
    }
  ]
}
```

Imports are additive: an existing canonical answer is preserved and new aliases are merged into it. The importer does not delete existing entries. The Admin answer tester previews exact and typo-tolerant matches for the selected question. Answers with genuinely different wording should only be grouped after a teacher confirms they mean the same thing; the app does not guess semantic equivalence.
