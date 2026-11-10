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

const allowedDurations = new Set(["24h", "168h", "720h"]);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "Sign-in required" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "Moderation service is not configured" }, 503);

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

  let body: { target_user_id?: string; action?: string; duration?: string; reason?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }

  const targetId = (body.target_user_id ?? "").trim();
  const action = (body.action ?? "").trim();
  const duration = (body.duration ?? "").trim();
  const reason = (body.reason ?? "").trim();

  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(targetId)) {
    return json({ error: "A valid target user ID is required" }, 400);
  }
  if (action !== "suspend" && action !== "restore") return json({ error: "Action must be suspend or restore" }, 400);
  if (action === "suspend" && !allowedDurations.has(duration)) {
    return json({ error: "Suspension duration must be 24h, 168h or 720h" }, 400);
  }
  if (action === "restore" && duration !== "") return json({ error: "Do not provide a duration when restoring an account" }, 400);
  if (reason.length < 5 || reason.length > 500) {
    return json({ error: "Provide a moderation reason between 5 and 500 characters" }, 400);
  }
  if (targetId === actor.id) return json({ error: "You cannot suspend or restore your own account" }, 403);

  const { data: targetData, error: targetError } = await admin.auth.admin.getUserById(targetId);
  const target = targetData?.user;
  if (targetError || !target) return json({ error: "Target account was not found" }, 404);

  const { data: targetStaff, error: targetStaffError } = await admin
    .from("tiqet_staff_roles").select("role").eq("user_id", targetId).maybeSingle();
  if (targetStaffError) return json({ error: "Could not verify target staff status" }, 500);
  if (targetStaff?.role === "super_admin") {
    return json({ error: "Super-administrator accounts cannot be moderated through this endpoint" }, 403);
  }
  if (targetStaff?.role) {
    const { data: actorIsSuperAdmin } = await userClient.rpc("is_tiqet_super_admin");
    if (actorIsSuperAdmin !== true) {
      return json({ error: "Only the super administrator can moderate staff accounts" }, 403);
    }
  }

  const { data: logRow, error: logInsertError } = await admin
    .from("tiqet_user_moderation_log")
    .insert({
      actor_user_id: actor.id, target_user_id: targetId, action,
      ban_duration: action === "suspend" ? duration : null,
      reason, status: "pending",
    })
    .select("id").single();
  if (logInsertError || !logRow) {
    console.error("Could not create moderation audit record", logInsertError?.message);
    return json({ error: "Could not create the moderation audit record" }, 500);
  }

  const banDuration = action === "suspend" ? duration : "none";
  const { data: updateData, error: updateError } = await admin.auth.admin.updateUserById(
    targetId, { ban_duration: banDuration }
  );

  if (updateError || !updateData?.user) {
    const errorMessage = updateError?.message ?? "Auth Admin did not return the updated user";
    await admin.from("tiqet_user_moderation_log").update({
      status: "failed", error_message: errorMessage.slice(0, 500),
      completed_at: new Date().toISOString(),
    }).eq("id", logRow.id);
    console.error("Auth account moderation failed", errorMessage);
    return json({ error: "The moderation request was recorded but Auth did not apply it" }, 502);
  }

  const bannedUntil = updateData.user.banned_until ?? null;
  const { error: updateLogError } = await admin
    .from("tiqet_user_moderation_log")
    .update({ status: "completed", banned_until: bannedUntil, completed_at: new Date().toISOString() })
    .eq("id", logRow.id);

  if (updateLogError) {
    console.error("Auth moderation succeeded but audit completion update failed", updateLogError.message);
    return json({ error: "The Auth change succeeded but the audit record needs review", moderation_id: logRow.id, applied: true }, 500);
  }

  await admin.from("tiqet_admin_audit_log").insert({
    actor_user_id: actor.id,
    action: action === "suspend" ? "user_suspended" : "user_restored",
    target_type: "user",
    target_id: targetId,
    reason,
    after_state: {
      action, duration: action === "suspend" ? duration : null,
      banned_until: bannedUntil, moderation_log_id: logRow.id,
    },
  });

  return json({
    moderation_id: logRow.id, target_user_id: targetId, action,
    status: "completed", banned_until: bannedUntil,
    note: "A temporary ban prevents new sign-ins for its duration. Already-issued access tokens are not immediately revoked; sensitive backend operations must continue to enforce authorization.",
  });
});
