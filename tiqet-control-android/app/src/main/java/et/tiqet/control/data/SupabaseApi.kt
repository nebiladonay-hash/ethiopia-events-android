package et.tiqet.control.data

import et.tiqet.control.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

data class ControlSession(
    val accessToken: String,
    val refreshToken: String,
    val userId: String,
    val email: String,
    val isPlatformOwner: Boolean = false
)

class SupabaseApi(
    private val projectUrl: String = BuildConfig.SUPABASE_URL.trimEnd('/'),
    private val publishableKey: String = BuildConfig.SUPABASE_ANON_KEY
) {
    val isConfigured: Boolean
        get() = projectUrl.startsWith("https://") && publishableKey.isNotBlank()

    suspend fun signIn(email: String, password: String): ControlSession = withContext(Dispatchers.IO) {
        val json = request(
            method = "POST",
            path = "/auth/v1/token?grant_type=password",
            body = JSONObject().put("email", email.trim()).put("password", password)
        )
        val user = json.optJSONObject("user") ?: throw ApiException("Supabase did not return a user.")
        ControlSession(
            accessToken = json.getString("access_token"),
            refreshToken = json.optString("refresh_token"),
            userId = user.getString("id"),
            email = user.optString("email", email.trim()),
            isPlatformOwner = user.optJSONObject("app_metadata")?.optString("tiqet_role") == "platform_owner"
        )
    }

    suspend fun getOverview(session: ControlSession): JSONObject =
        rpc(session, "get_tiqet_control_overview", JSONObject())

    suspend fun getOrganisers(session: ControlSession): JSONArray =
        getArray(session, "/rest/v1/organisations?select=id,name,legal_name,contact_phone,status,verification_notes,created_at&status=eq.pending&order=created_at.asc")

    suspend fun getVerifiedOrganisers(session: ControlSession): JSONArray {
        val result = rpc(session, "get_tiqet_verified_organisers", JSONObject())
        return result.optJSONArray("organisers") ?: JSONArray()
    }

    suspend fun setOrganiserAutoPublish(
        session: ControlSession,
        organisationId: String,
        enabled: Boolean,
        reason: String
    ): JSONObject = rpc(
        session,
        "set_organiser_auto_publish",
        JSONObject()
            .put("p_organisation_id", organisationId)
            .put("p_enabled", enabled)
            .put("p_reason", reason)
    )

    suspend fun getPendingEvents(session: ControlSession): JSONArray =
        getArray(session, "/rest/v1/events?select=id,title,description,category,starts_at,venue_name,address,city,organisation_id,created_at&status=eq.submitted&approval_status=eq.pending&order=created_at.asc")

    suspend fun getPublishedEventsForReview(session: ControlSession, limit: Int = 50): JSONArray {
        val result = rpc(
            session,
            "get_tiqet_published_events_for_review",
            JSONObject().put("p_limit", limit)
        )
        return result.optJSONArray("events") ?: JSONArray()
    }

    suspend fun flagPublishedEvent(session: ControlSession, eventId: String, reason: String): JSONObject =
        rpc(
            session,
            "flag_tiqet_event_for_review",
            JSONObject().put("p_event_id", eventId).put("p_reason", reason)
        )

    suspend fun getStaffDirectory(session: ControlSession): JSONArray {
        val result = rpc(session, "get_tiqet_staff_directory", JSONObject())
        return result.optJSONArray("staff") ?: JSONArray()
    }

    suspend fun getAuditLog(session: ControlSession): JSONArray {
        val result = rpc(session, "get_tiqet_admin_audit_log", JSONObject().put("p_limit", 60))
        return result.optJSONArray("entries") ?: JSONArray()
    }

    suspend fun getFinanceDashboard(session: ControlSession, limit: Int = 25): JSONObject =
        rpc(session, "get_tiqet_finance_dashboard", JSONObject().put("p_limit", limit))

    suspend fun getRefundsDashboard(session: ControlSession, limit: Int = 50): JSONObject =
        rpc(session, "get_tiqet_refunds_dashboard", JSONObject().put("p_limit", limit))

    suspend fun getChapaPayoutDestinations(session: ControlSession): JSONArray = withContext(Dispatchers.IO) {
        val result = request("GET", "/functions/v1/chapa-payout-banks", session = session)
        result.optJSONArray("destinations")
            ?: throw ApiException("Chapa did not return a payout destination list.")
    }

    suspend fun createPlatformPayout(
        session: ControlSession,
        amountMinor: Long,
        bankSlug: String,
        bankName: String,
        accountName: String,
        accountNumber: String
    ): JSONObject = withContext(Dispatchers.IO) {
        if (amountMinor < 100) throw ApiException("Minimum withdrawal is ETB 1.00.")
        request(
            method = "POST",
            path = "/functions/v1/create-platform-payout",
            body = JSONObject()
                .put("amount_etb", amountMinor.toDouble() / 100.0)
                .put("bank_slug", bankSlug)
                .put("bank_name", bankName)
                .put("account_name", accountName)
                .put("account_number", accountNumber),
            session = session
        )
    }

    suspend fun resolveOrganiserPayout(
        session: ControlSession,
        requestId: String,
        status: String,
        providerReference: String,
        operatorNote: String
    ): JSONObject = withContext(Dispatchers.IO) {
        request(
            method = "POST",
            path = "/functions/v1/tiqet-admin-organiser-payout",
            body = JSONObject()
                .put("request_id", requestId)
                .put("status", status)
                .put("provider_reference", providerReference)
                .put("operator_note", operatorNote),
            session = session
        )
    }

    suspend fun createChapaRefund(
        session: ControlSession,
        paymentId: String,
        amountMinor: Long?,
        reason: String,
        idempotencyKey: String
    ): JSONObject = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("payment_id", paymentId)
            .put("reason", reason)
            .put("idempotency_key", idempotencyKey)
        if (amountMinor != null) body.put("amount_minor", amountMinor)
        request(
            method = "POST",
            path = "/functions/v1/create-chapa-refund",
            body = body,
            session = session
        )
    }

    suspend fun verifyChapaRefund(session: ControlSession, refundId: String): JSONObject =
        withContext(Dispatchers.IO) {
            request(
                method = "POST",
                path = "/functions/v1/verify-chapa-refund",
                body = JSONObject().put("refund_id", refundId),
                session = session
            )
        }

    suspend fun searchUsers(session: ControlSession, query: String): JSONArray {
        val result = rpc(session, "search_tiqet_users", JSONObject().put("p_query", query).put("p_limit", 20))
        return result.optJSONArray("users") ?: JSONArray()
    }

    suspend fun getUserModerationHistory(session: ControlSession, userId: String): JSONArray {
        val result = rpc(
            session,
            "get_tiqet_user_moderation_history",
            JSONObject().put("p_user_id", userId).put("p_limit", 20)
        )
        return result.optJSONArray("history") ?: JSONArray()
    }

    suspend fun moderateUser(
        session: ControlSession,
        userId: String,
        action: String,
        duration: String?,
        reason: String
    ): JSONObject = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("target_user_id", userId)
            .put("action", action)
            .put("reason", reason)
        if (!duration.isNullOrBlank()) body.put("duration", duration)
        request(
            method = "POST",
            path = "/functions/v1/tiqet-admin-user-action",
            body = body,
            session = session
        )
    }

    suspend fun reviewOrganiser(
        session: ControlSession,
        organisationId: String,
        decision: String,
        notes: String
    ): JSONObject = rpc(
        session,
        "review_organiser_application",
        JSONObject()
            .put("p_organisation_id", organisationId)
            .put("p_decision", decision)
            .put("p_notes", notes)
    )

    suspend fun reviewEvent(
        session: ControlSession,
        eventId: String,
        decision: String,
        notes: String
    ): JSONObject = rpc(
        session,
        "review_event_submission",
        JSONObject()
            .put("p_event_id", eventId)
            .put("p_decision", decision)
            .put("p_notes", notes)
    )

    suspend fun assignStaffRole(
        session: ControlSession,
        userId: String,
        role: String,
        note: String
    ): JSONObject = rpc(
        session,
        "assign_tiqet_staff_role",
        JSONObject()
            .put("p_user_id", userId)
            .put("p_role", role)
            .put("p_note", note)
    )

    suspend fun revokeStaffRole(session: ControlSession, userId: String, note: String): JSONObject =
        rpc(
            session,
            "revoke_tiqet_staff_role",
            JSONObject().put("p_user_id", userId).put("p_note", note)
        )

    private suspend fun rpc(
        session: ControlSession,
        function: String,
        body: JSONObject
    ): JSONObject = withContext(Dispatchers.IO) {
        request(
            method = "POST",
            path = "/rest/v1/rpc/$function",
            body = body,
            session = session
        )
    }

    private suspend fun getArray(session: ControlSession, path: String): JSONArray =
        withContext(Dispatchers.IO) {
            requestArray("GET", path, session = session)
        }

    private fun request(
        method: String,
        path: String,
        body: JSONObject? = null,
        session: ControlSession? = null
    ): JSONObject {
        val response = openRequest(method, path, body, session)
        return try {
            JSONObject(response)
        } catch (_: Exception) {
            if (response.isBlank()) JSONObject() else throw ApiException("Unexpected response from Tiqet server.")
        }
    }

    private fun requestArray(
        method: String,
        path: String,
        session: ControlSession? = null
    ): JSONArray {
        val response = openRequest(method, path, null, session)
        return try {
            JSONArray(response)
        } catch (_: Exception) {
            throw ApiException("Unexpected list response from Tiqet server.")
        }
    }

    private fun openRequest(
        method: String,
        path: String,
        body: JSONObject?,
        session: ControlSession?
    ): String {
        if (!isConfigured) throw ApiException("Tiqet backend configuration is missing.")
        val connection = (URL(projectUrl + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 18_000
            readTimeout = 22_000
            setRequestProperty("apikey", publishableKey)
            setRequestProperty("Accept", "application/json")
            if (session != null) {
                setRequestProperty("Authorization", "Bearer ${session.accessToken}")
            }
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
            }
        }

        return try {
            if (body != null) {
                connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (status !in 200..299) {
                val message = try {
                    val err = JSONObject(text)
                    err.optString("message")
                        .ifBlank { err.optString("error_description") }
                        .ifBlank { err.optString("hint") }
                        .ifBlank { err.optString("error") }
                } catch (_: Exception) {
                    ""
                }
                throw ApiException(message.ifBlank { "Tiqet server returned HTTP $status." }, status)
            }
            text
        } catch (e: ApiException) {
            throw e
        } catch (e: Exception) {
            throw ApiException(e.message ?: "Could not connect to Tiqet.")
        } finally {
            connection.disconnect()
        }
    }
}

class ApiException(message: String, val statusCode: Int? = null) : Exception(message)
