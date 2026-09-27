// Drives "Simulate matches" batches server-side instead of from the
// browser -- see migration 0123 for why (no PostgREST 8s statement_timeout,
// no need to keep the admin tab open for a long run, service_role key
// never touches the browser). The actual game-engine logic is completely
// unchanged: this only relocates the LOOP that calls
// admin_run_training_batch, so simulated games stay byte-for-byte the same
// PL/pgSQL rules engine real matches use.
//
// Auth model: verify_jwt is on, so any signed-in user can reach this far --
// but nothing here trusts that alone. The caller's own JWT is used only to
// look up *who* they are (admin_id). Every actual write goes through
// admin_run_training_batch_as(p_admin, ...), which independently re-checks
// that admin_id is a real admin (see 0123) before doing anything. A
// non-admin's call authenticates fine and then fails on that DB-side
// check -- there is no path from "any logged-in user" to "can run a
// training batch."
//
// Deployed via the Supabase MCP's deploy_edge_function tool -- this file
// is kept here purely as the source of record / for `supabase functions
// deploy` if the CLI is ever set up locally. Edit here AND redeploy, they
// don't sync automatically.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "missing Authorization header" }, 401);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Identify the caller from their own JWT -- the only thing the browser
  // is trusted for. See the file header: the real gate is server-side.
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !userData?.user) return json({ error: "not authenticated" }, 401);
  const adminId = userData.user.id;

  let body: {
    run_id?: string;
    wall_budget_ms?: number;
    batch_deadline_seconds?: number;
    batch_size?: number;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const runId = body.run_id;
  if (!runId) return json({ error: "run_id is required" }, 400);

  // This is ONE invocation's time budget, not the whole run's -- kept well
  // under the platform's own edge-function wall-clock ceiling so this
  // always returns cleanly. A run bigger than this just needs another
  // invocation, exactly the same resumable shape admin_run_training_batch
  // always had (the client already loops -- see AdminTraining.tsx).
  const wallBudgetMs = Math.min(50000, Math.max(1000, body.wall_budget_ms ?? 20000));
  // service_role has no statement_timeout, so this is a deliberate choice
  // (fairness/interleaving with other traffic), not a forced ceiling --
  // still well above the 3s a direct browser/authenticated call is stuck
  // with under PostgREST's 8s limit.
  const batchDeadlineSeconds = Math.min(15, Math.max(1, body.batch_deadline_seconds ?? 6));
  const batchSize = Math.min(200, Math.max(1, body.batch_size ?? 60));

  const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const start = Date.now();
  let run: Record<string, unknown> | null = null;
  let batches = 0;

  while (Date.now() - start < wallBudgetMs) {
    const { data, error } = await db.rpc("admin_run_training_batch_as", {
      p_admin: adminId,
      p_run: runId,
      p_batch: batchSize,
      p_deadline_seconds: batchDeadlineSeconds,
    });
    if (error) return json({ error: error.message }, 400);
    run = data as Record<string, unknown>;
    batches += 1;
    if (["completed", "failed", "cancelled"].includes(run.status as string)) break;
    // A short breathing gap between chained batches -- the same courtesy
    // the old client-side 300ms pacing gave the database (see
    // AdminTraining.tsx / 0119-0122), kept here now that the loop itself
    // lives server-side.
    await new Promise((r) => setTimeout(r, 200));
  }

  return json({ run, batches, wall_ms: Date.now() - start });
});
