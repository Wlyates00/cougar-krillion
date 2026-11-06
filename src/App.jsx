import { useEffect, useState } from "react";
import {
   Trophy,
   Gamepad2,
   Settings,
   ChevronRight,
   Clock3,
   Sparkles,
   Crown,
   Zap,
   Plus,
   Pencil,
   Trash2,
   Check,
   X,
   ShieldCheck,
   Users,
   CalendarDays,
   ArrowLeft,
   LogOut,
   RefreshCw,
} from "lucide-react";
import { isConfigured, supabase } from "./supabase";

const STARTERS = [
   ["Name something students get in trouble for.", "School life"],
   ["Name something you might find in a teacher’s classroom.", "Classrooms"],
   ["Name something students forget to bring to school.", "School life"],
   ["Name a place inside a school building.", "Places"],
   ["Name something you might hear a teacher say.", "Teachers"],
   ["Name something students carry in a backpack.", "School life"],
   ["Name something that can go wrong with a school computer.", "Technology"],
   ["Name a school event.", "Traditions"],
   ["Name something found in a gym.", "Sports"],
   ["Name a reason someone might be late to school.", "School life"],
   ["Name a school supply.", "School life"],
   ["Name a website students use for school.", "Technology"],
   ["Name something you might see in the cafeteria.", "Cafeteria"],
   ["Name something students do when the bell rings.", "School life"],
   ["Name a device used during the school day.", "Technology"],
   ["Name something you might find in a hallway.", "Places"],
   ["Name a subject taught in high school.", "Classes"],
   ["Name something students look forward to.", "School life"],
   ["Name something a substitute teacher might need help with.", "Teachers"],
   ["Name something you might hear at a school sporting event.", "Sports"],
   ["Name something students do during a fire drill.", "School life"],
   ["Name a computer accessory.", "Technology"],
   ["Name something that makes a school day feel longer.", "School life"],
   ["Name something you might see at a school game.", "Sports"],
   ["Name something that might be written on a classroom board.", "Classrooms"],
   ["Name something students might borrow from a friend.", "School life"],
   ["Name something that can make a classroom noisy.", "Classrooms"],
   ["Name a reason a student might visit the office.", "School life"],
   ["Name something that might be in a teacher’s desk drawer.", "Teachers"],
   ["Name something students do while waiting for class to start.", "School life"],
].map(([prompt, category], i) => ({ id: `starter-${i + 1}`, prompt, category }));
const today = () => new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(new Date());
const shuffleDaily = (list) => {
   const a = [...list];
   let seed = Number(today().replaceAll("-", ""));
   for (let i = a.length - 1; i > 0; i--) {
      seed = (seed * 9301 + 49297) % 233280;
      const j = Math.floor((seed / 233280) * (i + 1));
      [a[i], a[j]] = [a[j], a[i]];
   }
   return a.slice(0, 7);
};
const err = (e) => e?.message || "Something went wrong. Please try again.";

export default function App() {
   const [tab, setTab] = useState("play"),
      [session, setSession] = useState(null),
      [booting, setBooting] = useState(true),
      [questions, setQuestions] = useState([]),
      [daily, setDaily] = useState([]),
      [playerId, setPlayerId] = useState(""),
      [completed, setCompleted] = useState(false),
      [index, setIndex] = useState(0),
      [answer, setAnswer] = useState(""),
      [seconds, setSeconds] = useState(25),
      [state, setState] = useState("ready"),
      [answers, setAnswers] = useState([]),
      [board, setBoard] = useState([]),
      [notice, setNotice] = useState(""),
      [busy, setBusy] = useState(false),
      [email, setEmail] = useState(""),
      [password, setPassword] = useState(""),
      [teacher, setTeacher] = useState(false),
      [editing, setEditing] = useState(null),
      [draft, setDraft] = useState(""),
      [category, setCategory] = useState("School life"),
      [queue, setQueue] = useState([]),
      [filter, setFilter] = useState("pending"),
      [invalidAnswers, setInvalidAnswers] = useState([]),
      [validationResults, setValidationResults] = useState([]),
      [retrySeconds, setRetrySeconds] = useState(30),
      [retryTimed, setRetryTimed] = useState(false);
   const current = daily[index],
      total = answers.reduce((s, a) => s + a.points, 0),
      playerLabel = playerId ? `COUGAR ${playerId.slice(0, 4).toUpperCase()}` : "ANONYMOUS PLAYER";
   async function loadData(s = session) {
      if (!supabase || !s) return;
      const [qr, dr, br, challengeRes] = await Promise.all([
         supabase.from("questions").select("id,prompt,category").eq("is_active", true).order("prompt"),
         supabase.from("submissions").select("id").eq("challenge_date", today()).eq("player_id", s.user.id).maybeSingle(),
         supabase.rpc("get_daily_leaderboard", { p_date: today() }),
         supabase.rpc("get_daily_challenge", { p_date: today() }),
      ]);
      if (qr.error) throw qr.error;
      if (challengeRes.error) throw challengeRes.error;
      setQuestions(qr.data || []);
      setDaily((challengeRes.data || []).map((q) => ({ ...q, id: q.question_id })));
      setCompleted(Boolean(dr.data));
      setBoard(br.data || []);
      setPlayerId(s.user.id);
   }
   useEffect(() => {
      let alive = true;
      let sub;
      (async () => {
         if (!isConfigured) {
            setBooting(false);
            return;
         }
         try {
            const {
               data: { session: old },
            } = await supabase.auth.getSession();
            let active = old;
            if (!active) {
               const { data, error } = await supabase.auth.signInAnonymously();
               if (error) throw error;
               active = data.session;
            }
            if (alive) {
               setSession(active);
               await loadData(active);
            }
         } catch (e) {
            if (alive) setNotice(err(e));
         } finally {
            if (alive) setBooting(false);
         }
      })();
      const auth = supabase?.auth.onAuthStateChange((_e, s) => setSession(s));
      sub = auth?.data?.subscription;
      return () => {
         alive = false;
         sub?.unsubscribe();
      };
   }, []);
   useEffect(() => {
      if (state !== "playing") return;
      if (seconds <= 0) {
         submitAnswer(true);
         return;
      }
      const t = setTimeout(() => setSeconds((x) => x - 1), 1000);
      return () => clearTimeout(t);
   }, [state, seconds]);
   useEffect(() => {
      if (state !== "retry" || !retryTimed) return;
      if (retrySeconds <= 0) {
         setRetryTimed(false);
         retryValidation();
         return;
      }
      const t = setTimeout(() => setRetrySeconds((x) => x - 1), 1000);
      return () => clearTimeout(t);
   }, [state, retryTimed, retrySeconds]);
   useEffect(() => {
      if (tab === "admin" && teacher) loadQueue();
   }, [tab, teacher, filter]);
   async function refresh() {
      try {
         setBusy(true);
         await loadData(session);
         setNotice("Game data refreshed.");
      } catch (e) {
         setNotice(err(e));
      } finally {
         setBusy(false);
      }
   }
   async function refreshBoard() {
      const { data, error } = await supabase.rpc("get_daily_leaderboard", { p_date: today() });
      if (error) throw error;
      setBoard(data || []);
   }
   function start() {
      if (completed) {
         setState("already");
         return;
      }
      setIndex(0);
      setAnswer("");
      setSeconds(25);
      setAnswers([]);
      setState("playing");
   }
   async function sendAnswersForValidation(payload) {
      setBusy(true);
      try {
         const { data, error } = await supabase.functions.invoke("submit-daily-challenge", {
            body: { challenge_date: today(), answers: payload.map((x) => ({ question_id: x.question_id, answer: x.answer })) },
         });
         if (error) throw error;
         if (data?.status === "retry") {
            setAnswers(payload);
            setInvalidAnswers(data.invalid_answers || []);
            setRetrySeconds(30);
            setRetryTimed(true);
            setState("retry");
            setNotice("A few answers need another try. You have 30 seconds to make corrections.");
            return;
         }
         if (data?.status === "already_submitted") {
            setAnswers(payload);
            setValidationResults([]);
            setCompleted(true);
            setState("finished");
            setNotice("Your challenge was already saved. Loading your score.");
            try {
               await refreshBoard();
            } catch {}
            return;
         }
         if (data?.status !== "submitted") throw new Error(data?.error || "The answer checker returned an unexpected response.");
         setAnswers(payload);
         setInvalidAnswers([]);
         setValidationResults(data.results || []);
         setCompleted(true);
         setState("finished");
         setNotice("");
         try {
            await refreshBoard();
         } catch (boardError) {
            setNotice("Your answers were saved, but the leaderboard could not refresh. Use Refresh leaderboard in a moment.");
         }
      } catch (e) {
         setAnswers(payload);
         setInvalidAnswers([]);
         setRetryTimed(false);
         setState("retry");
         setNotice(`${err(e)} You can try the AI check again.`);
      } finally {
         setBusy(false);
      }
   }
   async function submitAnswer(timeout = false) {
      if (state !== "playing" || busy || !current) return;
      const value = answer.trim();
      if (!value && !timeout) return;
      const next = [...answers, { question_id: current.id, answer: value || "No answer", prompt: current.prompt, points: 0 }];
      setAnswers(next);
      setAnswer("");
      if (index === 6) {
         await sendAnswersForValidation(next);
      } else {
         setIndex((x) => x + 1);
         setSeconds(25);
      }
   }
   function updateRetryAnswer(questionId, value) {
      setAnswers((currentAnswers) => currentAnswers.map((item) => (item.question_id === questionId ? { ...item, answer: value } : item)));
   }
   async function retryValidation() {
      setRetryTimed(false);
      if (answers.some((a) => !a.answer.trim())) {
         setNotice("Please enter an answer for all seven questions.");
         return;
      }
      await sendAnswersForValidation(answers);
   }
   async function login(e) {
      e.preventDefault();
      setBusy(true);
      try {
         const { data, error } = await supabase.auth.signInWithPassword({ email, password });
         if (error) throw error;
         const { data: ok, error: check } = await supabase.rpc("is_current_user_teacher");
         if (check) throw check;
         if (!ok) throw new Error("This account is not authorized as a teacher.");
         setSession(data.session);
         setTeacher(true);
         setPassword("");
         setNotice("Teacher access granted.");
      } catch (e) {
         setNotice(err(e));
      } finally {
         setBusy(false);
      }
   }
   async function logout() {
      await supabase.auth.signOut();
      setSession(null);
      setTeacher(false);
      setNotice("Signed out. Reload the page to start a player session.");
   }
   async function loadQueue() {
      const { data, error } = await supabase.rpc("teacher_get_answer_queue", { p_status: filter });
      if (error) {
         setNotice(err(error));
         return;
      }
      setQueue(data || []);
   }
   async function review(id, status) {
      setBusy(true);
      try {
         const { error } = await supabase.rpc("teacher_review_answer", { p_answer_id: id, p_status: status });
         if (error) throw error;
         await loadQueue();
         await refreshBoard();
         setNotice(`Answer ${status}.`);
      } catch (e) {
         setNotice(err(e));
      } finally {
         setBusy(false);
      }
   }
   function newQuestion() {
      setEditing("new");
      setDraft("");
      setCategory("School life");
   }
   function editQuestion(q) {
      setEditing(q.id);
      setDraft(q.prompt);
      setCategory(q.category);
   }
   async function saveQuestion() {
      if (!draft.trim()) return;
      setBusy(true);
      try {
         const payload = { prompt: draft.trim(), category, is_active: true };
         const res = editing === "new" ? await supabase.from("questions").insert(payload) : await supabase.from("questions").update(payload).eq("id", editing);
         if (res.error) throw res.error;
         setEditing(null);
         await loadData(session);
         setNotice("Question saved.");
      } catch (e) {
         setNotice(err(e));
      } finally {
         setBusy(false);
      }
   }
   async function archiveQuestion(id) {
      if (questions.length <= 7) {
         setNotice("Keep at least seven active questions.");
         return;
      }
      setBusy(true);
      try {
         const { error } = await supabase.from("questions").update({ is_active: false }).eq("id", id);
         if (error) throw error;
         await loadData(session);
         setNotice("Question archived.");
      } catch (e) {
         setNotice(err(e));
      } finally {
         setBusy(false);
      }
   }
   if (!isConfigured) return <SetupScreen />;
   if (booting)
      return (
         <div className="app-shell">
            <main className="main-content">
               <div className="admin-login">
                  <h1>
                     Connecting to <span>Cougar Krillion…</span>
                  </h1>
                  <p>Creating your anonymous player session.</p>
               </div>
            </main>
         </div>
      );
   return (
      <div className="app-shell">
         <header className="topbar">
            <div className="brand" onClick={() => setTab("play")} role="button" tabIndex="0">
               <div className="brand-mark">
                  <span>CK</span>
               </div>
               <div>
                  <div className="brand-name">
                     COUGAR <b>KRILLION</b>
                  </div>
                  <div className="brand-sub">PULASKI COUNTY HIGH SCHOOL</div>
               </div>
            </div>
            <nav className="nav-tabs">
               <button className={tab === "play" ? "active" : ""} onClick={() => setTab("play")}>
                  <Gamepad2 size={17} /> Play
               </button>
               <button
                  className={tab === "leaderboard" ? "active" : ""}
                  onClick={() => {
                     setTab("leaderboard");
                     refreshBoard();
                  }}
               >
                  <Trophy size={17} /> Leaderboard
               </button>
               <button className={tab === "admin" ? "active" : ""} onClick={() => setTab("admin")}>
                  <Settings size={17} /> Admin
               </button>
            </nav>
            <div className="player-chip">
               <span className="online-dot" />
               <span>{playerLabel}</span>
            </div>
         </header>
         <main className="main-content">
            {notice && (
               <div className="notice">
                  {notice}
                  <button className="icon-btn" onClick={() => setNotice("")}>
                     <X size={15} />
                  </button>
               </div>
            )}
            {tab === "play" && (
               <section className="play-view">
                  {state === "ready" && (
                     <>
                        <div className="hero">
                           <div className="eyebrow">
                              <span className="eyebrow-line" /> DAILY SCHOOL CHALLENGE <span className="eyebrow-line" />
                           </div>
                           <div className="hero-title">
                              THINK <span>DIFFERENT.</span>
                              <br />
                              SCORE <span>RARE.</span>
                           </div>
                           <p className="hero-copy">
                              Seven questions about school. One shot at each. The more unexpected your answer, the more points you could earn.
                           </p>
                           <div className="hero-actions">
                              <button className="primary-btn" onClick={start} disabled={completed || daily.length < 7}>
                                 {completed ? "Challenge completed" : "Play today’s challenge"} <ChevronRight size={18} />
                              </button>
                              <div className="hero-meta">
                                 <span>
                                    <Clock3 size={15} /> 25 SEC / QUESTION
                                 </span>
                                 <span>
                                    <Sparkles size={15} /> 7 QUESTIONS
                                 </span>
                              </div>
                           </div>
                           <div className="hero-watermark">CK</div>
                        </div>
                        <div className="below-hero">
                           <div className="section-heading">
                              <div>
                                 <div className="section-kicker">HOW TO PLAY</div>
                                 <h2>Be clever. Be uncommon.</h2>
                              </div>
                              <span className="today-date">
                                 <CalendarDays size={15} /> {new Date().toLocaleDateString(undefined, { month: "long", day: "numeric" })}
                              </span>
                           </div>
                           <div className="info-grid">
                              <InfoCard icon={<Zap />} number="01" title="Answer fast" body="You have 25 seconds to enter one answer for each prompt." />
                              <InfoCard
                                 icon={<Sparkles />}
                                 number="02"
                                 title="Think rare"
                                 body="Unusual valid answers earn more points when fewer players submit them."
                              />
                              <InfoCard
                                 icon={<Trophy />}
                                 number="03"
                                 title="Climb the board"
                                 body="AI checks relevance and automatically scores valid answers."
                              />
                           </div>
                           <div className="callout">
                              <div className="callout-icon">
                                 <ShieldCheck size={20} />
                              </div>
                              <div>
                                 <b>AI-powered scoring</b>
                                 <p>Relevant answers are scored automatically. Unclear answers are held for a quick teacher check.</p>
                              </div>
                           </div>
                           <button className="secondary-btn" onClick={refresh} disabled={busy}>
                              <RefreshCw size={15} /> Refresh game data
                           </button>
                           {daily.length < 7 && <p className="demo-warning">At least seven active questions are needed to start today’s challenge.</p>}
                        </div>
                     </>
                  )}
                  {state === "playing" && current && (
                     <div className="game-card">
                        <div className="game-topline">
                           <button className="back-btn" onClick={() => setState("ready")}>
                              <ArrowLeft size={16} /> Exit challenge
                           </button>
                           <span className="game-day">TODAY’S CHALLENGE</span>
                        </div>
                        <div className="progress-row">
                           <span>
                              QUESTION {index + 1} <i>OF 7</i>
                           </span>
                           <span>{Math.round((index / 7) * 100)}% COMPLETE</span>
                        </div>
                        <div className="progress-track">
                           <div style={{ width: `${(index / 7) * 100}%` }} />
                        </div>
                        <div className="question-category">{current.category}</div>
                        <h1 className="question-prompt">{current.prompt}</h1>
                        <p className="question-hint">Go beyond the obvious. Your first thought might be everyone else’s first thought, too.</p>
                        <div className={`timer ${seconds <= 7 ? "urgent" : ""}`}>
                           <Clock3 size={19} />
                           <strong>00:{String(seconds).padStart(2, "0")}</strong>
                           <span>TIME LEFT</span>
                           <div className="timer-track">
                              <div style={{ width: `${(seconds / 25) * 100}%` }} />
                           </div>
                        </div>
                        <form
                           className="answer-form"
                           onSubmit={(e) => {
                              e.preventDefault();
                              submitAnswer();
                           }}
                        >
                           <label htmlFor="answer">YOUR ANSWER</label>
                           <input
                              id="answer"
                              autoFocus
                              maxLength={60}
                              value={answer}
                              onChange={(e) => setAnswer(e.target.value)}
                              placeholder="Type something unexpected…"
                           />
                           <div className="answer-bottom">
                              <span>{answer.length}/60 characters</span>
                              <button className="primary-btn" type="submit" disabled={!answer.trim() || busy}>
                                 {busy ? "Submitting…" : "Lock in answer"} <ChevronRight size={17} />
                              </button>
                           </div>
                        </form>
                        <div className="game-footnote">
                           <ShieldCheck size={15} /> One answer per question. Keep it school-appropriate.
                        </div>
                     </div>
                  )}
                  {state === "retry" && (
                     <div className="result-card">
                        <div className="result-icon">
                           <ShieldCheck size={30} />
                        </div>
                        <div className="section-kicker">ONE MORE CHECK</div>
                        <h1>{invalidAnswers.length ? "Let’s fix a couple answers." : "Let’s try that check again."}</h1>
                        <p className="result-copy">
                           {invalidAnswers.length
                              ? "The AI checker found answers that do not clearly fit their questions. Change only the flagged answers, then submit again. Your challenge is not used up yet."
                              : "The AI checker did not finish. Your answers are still here; try the check again in a moment."}
                        </p>
                        <div className={`timer retry-timer ${retrySeconds <= 7 ? "urgent" : ""}`}>
                           <Clock3 size={19} />
                           <strong>00:{String(retrySeconds).padStart(2, "0")}</strong>
                           <span>TIME TO FIX ANSWERS</span>
                           <div className="timer-track">
                              <div style={{ width: `${(retrySeconds / 30) * 100}%` }} />
                           </div>
                        </div>
                        <div className="result-list">
                           {answers.map((a, i) => {
                              const issue = invalidAnswers.find((x) => x.question_id === a.question_id);
                              return (
                                 <div className="result-row" key={a.question_id}>
                                    <span className="result-number">{String(i + 1).padStart(2, "0")}</span>
                                    <div className="result-answer">
                                       <small>{a.prompt}</small>
                                       {issue ? (
                                          <>
                                             <input
                                                className="retry-answer-input"
                                                maxLength={60}
                                                value={a.answer === "No answer" ? "" : a.answer}
                                                onChange={(e) => updateRetryAnswer(a.question_id, e.target.value)}
                                                placeholder="Enter a different answer"
                                             />
                                             <small className="retry-reason">{issue.reason}</small>
                                          </>
                                       ) : (
                                          <b>{a.answer}</b>
                                       )}
                                    </div>
                                    <strong>{issue ? "Try again" : "No change needed"}</strong>
                                 </div>
                              );
                           })}
                        </div>
                        <button className="primary-btn" onClick={retryValidation} disabled={busy}>
                           {busy ? "Checking answers…" : "Recheck answers"} <ChevronRight size={17} />
                        </button>
                     </div>
                  )}
                  {state === "finished" && (
                     <div className="result-card">
                        <div className="result-icon">
                           <Trophy size={30} />
                        </div>
                        <div className="section-kicker">AI CHECK COMPLETE</div>
                        <h1>Nice work, Cougar.</h1>
                        <p className="result-copy">
                           Relevant answers have been approved and scored automatically. Any answer the AI was unsure about is waiting for a teacher check.
                        </p>
                        <div className="score-total">
                           <strong>{Number(board.find((p) => p.player_id === playerId)?.score || 0).toLocaleString()}</strong>
                           <span>POINTS SO FAR</span>
                        </div>
                        <div className="result-list">
                           {answers.map((a, i) => {
                              const result = validationResults.find((x) => x.question_id === a.question_id);
                              return (
                                 <div className="result-row" key={a.question_id}>
                                    <span className="result-number">{String(i + 1).padStart(2, "0")}</span>
                                    <div className="result-answer">
                                       <b>{a.answer}</b>
                                       <small>{a.prompt}</small>
                                    </div>
                                    <strong>{result?.verdict === "valid" ? "Scored" : result?.verdict === "uncertain" ? "Teacher check" : "Saved"}</strong>
                                 </div>
                              );
                           })}
                        </div>
                        <button
                           className="primary-btn"
                           onClick={() => {
                              setTab("leaderboard");
                              setState("ready");
                           }}
                        >
                           See daily leaderboard <ChevronRight size={17} />
                        </button>
                     </div>
                  )}
                  {state === "already" && (
                     <div className="result-card compact">
                        <div className="result-icon">
                           <Check size={28} />
                        </div>
                        <h1>You’re all done for today.</h1>
                        <p className="result-copy">This anonymous player account has already submitted today’s challenge.</p>
                        <button className="primary-btn" onClick={() => setState("ready")}>
                           Back to home
                        </button>
                     </div>
                  )}
               </section>
            )}
            {tab === "leaderboard" && (
               <section className="leaderboard-view">
                  <div className="page-heading">
                     <div className="section-kicker">THE DAILY RANKINGS</div>
                     <h1>
                        Today’s <span>leaderboard.</span>
                     </h1>
                     <p>AI-approved answers earn points automatically. Only uncertain answers wait for teacher review.</p>
                  </div>
                  <div className="leaderboard-panel">
                     <div className="panel-top">
                        <div>
                           <div className="section-kicker">PULASKI COUNTY HIGH SCHOOL</div>
                           <h2>
                              <Trophy size={20} /> Daily standings
                           </h2>
                        </div>
                        <span className="live-pill">
                           <i /> TODAY
                        </span>
                     </div>
                     {board.length ? (
                        <div className="leader-list">
                           {board.map((p, i) => (
                              <div className="leader-row" key={p.player_id}>
                                 <div className={`rank rank-${i + 1}`}>{i === 0 ? <Crown size={17} /> : String(i + 1).padStart(2, "0")}</div>
                                 <div className="leader-avatar">CK</div>
                                 <div className="leader-name">
                                    <b>COUGAR {String(p.player_id).slice(0, 4).toUpperCase()}</b>
                                 </div>
                                 <strong>
                                    {Number(p.score).toLocaleString()} <small>PTS</small>
                                 </strong>
                              </div>
                           ))}
                        </div>
                     ) : (
                        <div className="empty-board">
                           <Trophy size={32} />
                           <h3>No scores yet today.</h3>
                           <p>Scores appear as soon as the AI validates relevant answers.</p>
                           <button className="primary-btn" onClick={() => setTab("play")}>
                              Play today <ChevronRight size={17} />
                           </button>
                        </div>
                     )}
                     <div className="board-footer">
                        <span>
                           <Users size={15} /> {board.length} {board.length === 1 ? "PLAYER" : "PLAYERS"} ON THE BOARD
                        </span>
                        <span>RESETS DAILY</span>
                     </div>
                  </div>
                  <button className="secondary-btn" onClick={refresh} disabled={busy}>
                     <RefreshCw size={15} /> Refresh leaderboard
                  </button>
               </section>
            )}
            {tab === "admin" && (
               <section className="admin-view">
                  {!teacher ? (
                     <div className="admin-login">
                        <div className="admin-lock">
                           <Settings size={26} />
                        </div>
                        <div className="section-kicker">TEACHER ACCESS</div>
                        <h1>
                           Admin <span>workspace.</span>
                        </h1>
                        <p>Sign in with your authorized teacher account.</p>
                        <form onSubmit={login}>
                           <label htmlFor="email">TEACHER EMAIL</label>
                           <input
                              id="email"
                              type="email"
                              autoComplete="username"
                              value={email}
                              onChange={(e) => setEmail(e.target.value)}
                              placeholder="teacher@school.org"
                              required
                           />
                           <label htmlFor="password">PASSWORD</label>
                           <input
                              id="password"
                              type="password"
                              autoComplete="current-password"
                              value={password}
                              onChange={(e) => setPassword(e.target.value)}
                              placeholder="Password"
                              required
                           />
                           <button className="primary-btn" type="submit" disabled={busy}>
                              {busy ? "Signing in…" : "Sign in"} <ChevronRight size={17} />
                           </button>
                        </form>
                        <small className="demo-warning">
                           Teacher accounts must be created in Supabase and explicitly authorized. There is no shared demo PIN.
                        </small>
                     </div>
                  ) : (
                     <>
                        <div className="admin-header">
                           <div>
                              <div className="section-kicker">TEACHER WORKSPACE</div>
                              <h1>
                                 Question <span>manager.</span>
                              </h1>
                              <p>Manage prompts and review only the answers the AI could not confidently classify.</p>
                           </div>
                           <button className="primary-btn" onClick={newQuestion}>
                              <Plus size={17} /> Add question
                           </button>
                        </div>
                        <div className="admin-stats">
                           <div>
                              <span>QUESTION BANK</span>
                              <b>{questions.length}</b>
                           </div>
                           <div>
                              <span>DAILY PROMPTS</span>
                              <b>7</b>
                           </div>
                           <div>
                              <span>PLAYER MODE</span>
                              <b>Anonymous</b>
                           </div>
                        </div>
                        {editing && (
                           <div className="edit-panel">
                              <div className="edit-panel-head">
                                 <h3>{editing === "new" ? "Add a question" : "Edit question"}</h3>
                                 <button className="icon-btn" onClick={() => setEditing(null)}>
                                    <X size={18} />
                                 </button>
                              </div>
                              <label>QUESTION PROMPT</label>
                              <input value={draft} onChange={(e) => setDraft(e.target.value)} placeholder="Write your question…" />
                              <label>CATEGORY</label>
                              <select value={category} onChange={(e) => setCategory(e.target.value)}>
                                 {["School life", "Teachers", "Classrooms", "Places", "Technology", "Sports", "Cafeteria", "Traditions", "Classes"].map((c) => (
                                    <option key={c}>{c}</option>
                                 ))}
                              </select>
                              <div className="edit-actions">
                                 <button className="secondary-btn" onClick={() => setEditing(null)}>
                                    Cancel
                                 </button>
                                 <button className="primary-btn" onClick={saveQuestion} disabled={busy}>
                                    <Check size={17} /> Save question
                                 </button>
                              </div>
                           </div>
                        )}
                        <div className="question-bank-head">
                           <h2>Question bank</h2>
                           <span>{questions.length} ACTIVE QUESTIONS</span>
                        </div>
                        <div className="question-bank">
                           {questions.map((q, i) => (
                              <div className="bank-row" key={q.id}>
                                 <div className="bank-index">{String(i + 1).padStart(2, "0")}</div>
                                 <div className="bank-content">
                                    <b>{q.prompt}</b>
                                    <span>{q.category}</span>
                                 </div>
                                 <button className="icon-btn" title="Edit question" onClick={() => editQuestion(q)}>
                                    <Pencil size={17} />
                                 </button>
                                 <button className="icon-btn danger" title="Archive question" onClick={() => archiveQuestion(q.id)}>
                                    <Trash2 size={17} />
                                 </button>
                              </div>
                           ))}
                        </div>
                        <div className="edit-panel">
                           <div className="edit-panel-head">
                              <h3>AI uncertainty review</h3>
                              <span>{queue.length} answers</span>
                           </div>
                           <div className="edit-actions">
                              {["pending", "approved", "rejected"].map((x) => (
                                 <button key={x} className={filter === x ? "primary-btn" : "secondary-btn"} onClick={() => setFilter(x)}>
                                    {x[0].toUpperCase() + x.slice(1)}
                                 </button>
                              ))}
                           </div>
                           {queue.length ? (
                              queue.map((a) => (
                                 <div className="bank-row" key={a.answer_id}>
                                    <div className="bank-index">{String(a.answer_text).slice(0, 1).toUpperCase()}</div>
                                    <div className="bank-content">
                                       <b>{a.answer_text}</b>
                                       <span>
                                          {a.question_prompt} · {String(a.player_id).slice(0, 4).toUpperCase()}
                                          {a.ai_reason ? ` · AI: ${a.ai_reason}` : ""}
                                       </span>
                                    </div>
                                    {filter === "pending" && (
                                       <>
                                          <button className="icon-btn" title="Approve" onClick={() => review(a.answer_id, "approved")}>
                                             <Check size={17} />
                                          </button>
                                          <button className="icon-btn danger" title="Reject" onClick={() => review(a.answer_id, "rejected")}>
                                             <X size={17} />
                                          </button>
                                       </>
                                    )}
                                 </div>
                              ))
                           ) : (
                              <p>No {filter} answers.</p>
                           )}
                        </div>
                        <div className="admin-bottom">
                           <button className="secondary-btn" onClick={logout}>
                              <LogOut size={16} /> Sign out
                           </button>
                        </div>
                     </>
                  )}
               </section>
            )}
         </main>
         <footer className="footer">
            <div className="footer-brand">
               COUGAR <b>KRILLION</b>
            </div>
            <span>MADE FOR PULASKI COUNTY HIGH SCHOOL</span>
            <span>DAILY CHALLENGE · {new Date().getFullYear()}</span>
         </footer>
      </div>
   );
}
function InfoCard({ icon, number, title, body }) {
   return (
      <div className="info-card">
         <div className="info-card-top">
            <span className="info-icon">{icon}</span>
            <span>{number}</span>
         </div>
         <h3>{title}</h3>
         <p>{body}</p>
      </div>
   );
}
function SetupScreen() {
   return (
      <div className="app-shell">
         <main className="main-content">
            <div className="admin-login">
               <div className="section-kicker">BACKEND SETUP REQUIRED</div>
               <h1>
                  Connect <span>Supabase.</span>
               </h1>
               <p>
                  Add your Supabase project URL and public anon key to a <code>.env</code> file, then run <code>supabase/schema.sql</code> in the Supabase SQL
                  Editor.
               </p>
               <p className="demo-warning">
                  Create <b>.env</b> from <b>.env.example</b>. Never put a Supabase service-role key in this frontend.
               </p>
            </div>
         </main>
      </div>
   );
}
