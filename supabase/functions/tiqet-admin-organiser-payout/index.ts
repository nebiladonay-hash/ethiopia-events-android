import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const transitions: Record<string, Set<string>> = {
  requested: new Set(["approved", "rejected"]),
  approved: new Set(["processing", "rejected", "failed"]),
  processing: new Set(["paid", "failed"]),
  paid: new Set(["reversed"]),
  rejected: new Set(),
  failed: new Set(),
  reversed: new Set(),
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "Sign-in required" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "Payout review service is not configured" }, 503);

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  const actor = authData?.user;
  if (authError || !actor) return json({ error: "Invalid or expired session" }, 401);

  const { data: isAdmin, error: roleError } = await userClient.rpc("is_tiqet_admin");
  if (roleError || isAdmin !== true) return json({ error: "Tiqet administrator permission required" }, 403);

  let body: {
    request_id?: string;
    status?: string;
    provider_reference?: string;
    operator_note?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const requestId = String(body.request_id ?? "").trim();
  const nextStatus = String(body.status ?? "").trim().toLowerCase();
  const providerReference = String(body.provider_reference ?? "").trim();
  const operatorNote = String(body.operator_note ?? "").trim();

  if (!uuidPattern.test(requestId)) return json({ error: "A valid organiser payout request ID is required" }, 400);
  if (!Object.hasOwn(transitions, nextStatus)) {
    return json({ error: "Status must be approved, processing, paid, rejected, failed or reversed" }, 400);
  }
  if (operatorNote.length < 5 || operatorNote.length > 500) {
    return json({ error: "Provide an operator note between 5 and 500 characters" }, 400);
  }
  if (["paid", "reversed"].includes(nextStatus) && providerReference.length < 3) {
    return json({ error: "A provider transaction reference is required to confirm a payout or reversal" }, 400);
  }
  if (providerReference.length > 160) return json({ error: "Provider reference is too long" }, 400);

  const { data: requestRow, error: requestError } = await admin
    .from("organiser_payout_requests")
    .select("id,organisation_id,provider,amount_minor,currency,status,provider_reference,requested_by")
    .eq("id", requestId)
    .maybeSingle();
  if (requestError) {
    console.error("Could not load organiser payout request", requestError.message);
    return json({ error: "Could not load the payout request" }, 500);
  }
  if (!requestRow) return json({ error: "Organiser payout request was not found" }, 404);

  const currentStatus = String(requestRow.status ?? "");
  if (!transitions[currentStatus]?.has(nextStatus)) {
    return json({
      error: `Payout cannot move from ${currentStatus || "unknown"} to ${nextStatus}. Refresh the finance queue and review its current state.`,
      current_status: currentStatus,
    }, 409);
  }
  if (nextStatus === "paid" && !providerReference) {
    return json({ error: "Payout cannot be marked paid without a verified provider reference" }, 400);
  }

  // The database RPC row-locks the request and writes the settlement ledger
  // debit/reversal in the same transaction as the state change.
  const { data: result, error: resolveError } = await admin.rpc("resolve_organiser_payout_request", {
    p_request_id: requestId,
    p_status: nextStatus,
    p_provider_reference: providerReference || null,
    p_operator_note: operatorNote,
  });
  if (resolveError) {
    console.error("Could not resolve organiser payout request", resolveError.message);
    return json({ error: "The payout request was not changed. Refresh and try again." }, 409);
  }

  const { error: auditError } = await admin.from("tiqet_admin_audit_log").insert({
    actor_user_id: actor.id,
    action: `organiser_payout_${nextStatus}`,
    target_type: "organiser_payout_request",
    target_id: requestId,
    reason: operatorNote,
    before_state: {
      status: currentStatus,
      provider: requestRow.provider,
      amount_minor: requestRow.amount_minor,
      currency: requestRow.currency,
      provider_reference: requestRow.provider_reference,
    },
    after_state: {
      status: nextStatus,
      provider_reference: providerReference || requestRow.provider_reference,
    },
  });
  if (auditError) {
    console.error("Organiser payout was updated but audit insertion failed", auditError.message);
    return json({
      error: "The payout status changed, but the audit record could not be saved. Keep the request open for administrator review.",
      applied: true,
      request_id: requestId,
      status: result?.status ?? nextStatus,
    }, 500);
  }

  return json({
    request_id: requestId,
    status: result?.status ?? nextStatus,
    previous_status: currentStatus,
    provider_reference: providerReference || requestRow.provider_reference,
    ledger_updated: ["paid", "reversed"].includes(nextStatus),
  });
});
