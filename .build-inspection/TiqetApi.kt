package et.events.mobile.backend

import android.content.Context
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import et.events.mobile.BuildConfig
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Tiqet's Android-to-Supabase REST adapter.
 * The app only contains the Supabase publishable/anon key. Chapa private keys remain in Edge Function secrets.
 */
class TiqetApi(context: Context) {
    private val appContext = context.applicationContext
    private val sessionStore = SecureSessionStore(appContext)

    data class Session(
        val accessToken: String,
        val refreshToken: String,
        val userId: String,
        val email: String
    )

    data class Event(
        val id: String,
        val title: String,
        val description: String,
        val category: String,
        val startsAt: String,
        val venueName: String,
        val address: String,
        val city: String,
        val imageUrl: String?,
        val minimumPriceEtb: Double?,
        val ticketTypeId: String?,
        val ticketTypeName: String?
    )

    data class Ticket(
        val id: String,
        val eventId: String,
        val status: String,
        val token: String,
        val issuedAt: String,
        val eventTitle: String
    )

    class ApiException(message: String, val httpCode: Int? = null) : Exception(message)

    fun isConfigured(): Boolean = BuildConfig.SUPABASE_URL.isNotBlank() && BuildConfig.SUPABASE_ANON_KEY.isNotBlank()

    fun currentSession(): Session? = sessionStore.read()

    companion object {
        const val AUTH_CALLBACK_URL = "tiqet://auth/callback"
    }

    fun signUp(email: String, password: String, fullName: String, phone: String): Session? {
        requireConfigured()
        val normalizedPhone = normalizeEthiopianPhone(phone)
        val body = JSONObject()
            .put("email", email.trim())
            .put("password", password)
            .put("data", JSONObject().put("full_name", fullName.trim()).put("phone", normalizedPhone))
        val redirect = URLEncoder.encode(AUTH_CALLBACK_URL, Charsets.UTF_8.name())
        val result = request("POST", "/auth/v1/signup?redirect_to=$redirect", body, useSession = false)
        return saveSessionIfPresent(result)
    }

    /**
     * Completes the implicit-flow callback returned by Supabase after email verification.
     * Tokens arrive in the URI fragment, so they are never sent to the web server.
     */
    fun completeAuthCallback(uri: Uri): Session {
        if (uri.scheme != "tiqet" || uri.host != "auth" || uri.path != "/callback") {
            throw ApiException("This is not a valid Tiqet authentication link.")
        }
        val fragmentUri = Uri.parse("https://tiqet.invalid/?${uri.fragment.orEmpty()}")
        fun param(name: String): String? = uri.getQueryParameter(name) ?: fragmentUri.getQueryParameter(name)

        val callbackError = param("error_description") ?: param("error")
        if (!callbackError.isNullOrBlank()) {
            throw ApiException("Email confirmation failed: ${callbackError.replace('+', ' ')}")
        }
        val access = param("access_token").orEmpty()
        val refresh = param("refresh_token").orEmpty()
        if (access.isBlank() || refresh.isBlank()) {
            throw ApiException("The confirmation link did not return a session. Request a new confirmation email and try again.")
        }

        val jwtParts = access.split('.')
        if (jwtParts.size != 3) throw ApiException("The confirmation response was invalid. Please try again.")
        val claims = try {
            val decoded = Base64.decode(jwtParts[1], Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            JSONObject(String(decoded, Charsets.UTF_8))
        } catch (_: Exception) {
            throw ApiException("The confirmation response could not be read. Please try again.")
        }
        val expectedIssuer = BuildConfig.SUPABASE_URL.trimEnd('/') + "/auth/v1"
        val issuer = claims.optString("iss")
        if (issuer.isNotBlank() && issuer != expectedIssuer) {
            throw ApiException("This confirmation link belongs to a different project.")
        }
        val audience = claims.opt("aud")
        val audienceValid = when (audience) {
            is String -> audience == "authenticated"
            is JSONArray -> (0 until audience.length()).any { audience.optString(it) == "authenticated" }
            else -> false
        }
        if (!audienceValid) throw ApiException("The confirmation response was not a valid Tiqet user session.")
        val expiresAt = claims.optLong("exp", 0L)
        if (expiresAt > 0L && expiresAt <= System.currentTimeMillis() / 1000L) {
            throw ApiException("This confirmation link has expired. Request a new confirmation email.")
        }
        val userId = claims.optString("sub")
        val email = claims.optString("email")
        if (userId.isBlank() || email.isBlank()) throw ApiException("The confirmation response is missing account details.")

        val session = Session(access, refresh, userId, email)
        sessionStore.write(session)
        return session
    }

    fun signIn(email: String, password: String): Session {
        requireConfigured()
        val body = JSONObject().put("email", email.trim()).put("password", password)
        val result = request("POST", "/auth/v1/token?grant_type=password", body, useSession = false)
        return saveSessionIfPresent(result) ?: throw ApiException("Sign-in succeeded without a session. Check whether email confirmation is enabled.")
    }

    fun refreshSession(): Session? {
        val old = currentSession() ?: return null
        return try {
            val result = request(
                "POST", "/auth/v1/token?grant_type=refresh_token",
                JSONObject().put("refresh_token", old.refreshToken), useSession = false
            )
            saveSessionIfPresent(result)
        } catch (_: Exception) {
            // Keep the encrypted session on transient network errors; only a successful logout clears it.
            null
        }
    }

    fun signOut() {
        try { if (currentSession() != null) request("POST", "/auth/v1/logout", JSONObject(), useSession = true) } catch (_: Exception) { }
        sessionStore.clear()
    }

    fun fetchPublishedEvents(): List<Event> {
        requireConfigured()
        val query = "select=id,title,description,category,starts_at,venue_name,address,city,image_url,ticket_types(id,name,price_etb)" +
            "&status=eq.published&approval_status=eq.approved&order=starts_at.asc"
        val rows = requestArray("GET", "/rest/v1/events?$query", useSession = currentSession() != null)
        return (0 until rows.length()).mapNotNull { i ->
            val row = rows.optJSONObject(i) ?: return@mapNotNull null
            val ticketTypes = row.optJSONArray("ticket_types") ?: JSONArray()
            val ticketRows = (0 until ticketTypes.length()).mapNotNull { ticketTypes.optJSONObject(it) }
            val cheapest = ticketRows.minByOrNull { it.optDouble("price_etb", Double.MAX_VALUE) }
            Event(
                id = row.optString("id"),
                title = row.optString("title"),
                description = row.optString("description"),
                category = row.optString("category"),
                startsAt = row.optString("starts_at"),
                venueName = row.optString("venue_name"),
                address = row.optString("address"),
                city = row.optString("city"),
                imageUrl = row.optString("image_url").takeIf { it.isNotBlank() && it != "null" },
                minimumPriceEtb = cheapest?.optDouble("price_etb"),
                ticketTypeId = cheapest?.optString("id")?.takeIf { !it.isNullOrBlank() && it != "null" },
                ticketTypeName = cheapest?.optString("name")?.takeIf { !it.isNullOrBlank() && it != "null" }
            )
        }
    }

    fun fetchMyOrganisations(): JSONArray {
        requireSignedIn()
        return requestArray(
            "GET", "/rest/v1/organisations?select=id,name,legal_name,status,verification_notes,payout_method,payout_account_last4,payout_setup_at&order=created_at.desc",
            useSession = true
        )
    }

    fun submitOrganisationApplication(name: String, legalName: String, phone: String): JSONObject {
        requireSignedIn()
        val normalizedPhone = normalizeEthiopianPhone(phone)
        val result = request(
            "POST", "/rest/v1/organisations?select=id,name,status",
            JSONObject().put("owner_id", currentSession()!!.userId).put("name", name.trim()).put("legal_name", legalName.trim()).put("contact_phone", normalizedPhone),
            useSession = true,
            prefer = "return=representation"
        )
        return result.optJSONArray("data")?.optJSONObject(0) ?: result
    }

    fun createDraftEvent(
        organisationId: String,
        title: String,
        description: String,
        category: String,
        startsAtIso: String,
        venueName: String,
        address: String,
        city: String
    ): JSONObject {
        requireSignedIn()
        val row = JSONObject()
            .put("organisation_id", organisationId)
            .put("created_by", currentSession()!!.userId)
            .put("title", title.trim())
            .put("description", description.trim())
            .put("category", category.trim())
            .put("starts_at", startsAtIso)
            .put("venue_name", venueName.trim())
            .put("address", address.trim())
            .put("city", city.trim())
            .put("status", "draft")
            .put("approval_status", "pending")
        val result = request("POST", "/rest/v1/events?select=id,title,status", row, true, "return=representation")
        return result.optJSONArray("data")?.optJSONObject(0) ?: result
    }

    fun createEventSubmission(
        organisationId: String, title: String, description: String, category: String,
        startsAtIso: String, venueName: String, address: String, city: String,
        ticketName: String, priceEtb: Double, quantity: Int
    ): JSONObject {
        requireSignedIn()
        require(priceEtb >= 0.0 && quantity in 1..100000) { "Enter a valid ticket price and quantity." }
        return request(
            "POST", "/rest/v1/rpc/create_event_submission",
            JSONObject()
                .put("p_organisation_id", organisationId)
                .put("p_title", title.trim())
                .put("p_description", description.trim())
                .put("p_category", category.trim())
                .put("p_starts_at", startsAtIso)
                .put("p_venue_name", venueName.trim())
                .put("p_address", address.trim())
                .put("p_city", city.trim())
                .put("p_ticket_name", ticketName.trim())
                .put("p_price_etb", priceEtb)
                .put("p_quantity", quantity),
            useSession = true
        )
    }

    fun fetchMyOrganiserEvents(): JSONArray {
        requireSignedIn()
        return requestArray(
            "GET", "/rest/v1/events?select=id,title,status,approval_status,starts_at,venue_name,city&order=created_at.desc",
            useSession = true
        )
    }

    fun submitEventForReview(eventId: String): JSONObject {
        requireSignedIn()
        return request("POST", "/rest/v1/rpc/submit_event_for_review", JSONObject().put("p_event_id", eventId), true)
    }

    fun createTicketType(eventId: String, name: String, priceEtb: Double, quantity: Int): JSONObject {
        requireSignedIn()
        require(priceEtb >= 0.0 && quantity > 0) { "Enter a valid ticket price and quantity." }
        val row = JSONObject()
            .put("event_id", eventId)
            .put("name", name.trim())
            .put("price_etb", priceEtb)
            .put("quantity_total", quantity)
            .put("per_order_limit", minOf(quantity, 10))
        val result = request("POST", "/rest/v1/ticket_types?select=id,name,price_etb,quantity_total", row, true, "return=representation")
        return result.optJSONArray("data")?.optJSONObject(0) ?: result
    }

    fun fetchMyTickets(): List<Ticket> {
        requireSignedIn()
        val rows = requestArray(
            "GET", "/rest/v1/tickets?select=id,event_id,status,ticket_token,issued_at,events(title)&order=issued_at.desc",
            useSession = true
        )
        return (0 until rows.length()).mapNotNull { i ->
            val row = rows.optJSONObject(i) ?: return@mapNotNull null
            Ticket(
                id = row.optString("id"), eventId = row.optString("event_id"),
                status = row.optString("status"), token = row.optString("ticket_token"),
                issuedAt = row.optString("issued_at"),
                eventTitle = row.optJSONObject("events")?.optString("title") ?: "Tiqet event"
            )
        }
    }

    fun claimFreeTickets(ticketTypeId: String, quantity: Int): JSONObject {
        requireSignedIn()
        require(quantity in 1..10) { "Ticket quantity must be between 1 and 10." }
        return request(
            "POST", "/rest/v1/rpc/claim_free_tickets",
            JSONObject().put("p_ticket_type_id", ticketTypeId).put("p_quantity", quantity),
            useSession = true
        )
    }

    fun createPaymentIntent(ticketTypeId: String, quantity: Int, provider: String = "chapa", paymentMethod: String? = null): JSONObject {
        requireSignedIn()
        require(quantity in 1..10) { "Ticket quantity must be between 1 and 10." }
        require(provider.matches(Regex("[a-z][a-z0-9_]{1,31}"))) { "Invalid payment provider." }
        val body = JSONObject()
            .put("provider", provider)
            .put("ticket_type_id", ticketTypeId)
            .put("quantity", quantity)
        if (!paymentMethod.isNullOrBlank()) body.put("payment_method", paymentMethod)
        return request("POST", "/functions/v1/create-payment-intent", body, useSession = true)
    }

    // Backwards-compatible wrapper for current checkout screens.
    fun createChapaCheckout(ticketTypeId: String, quantity: Int): JSONObject =
        createPaymentIntent(ticketTypeId, quantity, provider = "chapa")

    fun fetchPaymentProviderCatalog(): JSONObject {
        requireSignedIn()
        return request("GET", "/functions/v1/payment-provider-catalog", useSession = true)
    }

    fun fetchOrganiserSettlementSummary(organisationId: String): JSONObject {
        requireSignedIn()
        return request(
            "POST", "/rest/v1/rpc/get_my_organiser_settlement_summary",
            JSONObject().put("p_organisation_id", organisationId), useSession = true
        )
    }

    fun fetchOrganiserSettlementHistory(organisationId: String, limit: Int = 30, offset: Int = 0): JSONObject {
        requireSignedIn()
        require(limit in 1..100 && offset >= 0) { "Invalid transaction history page." }
        return request(
            "POST", "/rest/v1/rpc/get_my_organiser_settlement_history",
            JSONObject().put("p_organisation_id", organisationId).put("p_limit", limit).put("p_offset", offset),
            useSession = true
        )
    }

    fun requestOrganiserPayout(organisationId: String, amountEtb: Double, provider: String = "chapa", idempotencyKey: String): JSONObject {
        requireSignedIn()
        require(amountEtb >= 1.0 && amountEtb <= 100000000.0) { "Enter a valid payout amount." }
        require(provider.matches(Regex("[a-z][a-z0-9_]{1,31}"))) { "Invalid payment provider." }
        return request(
            "POST", "/rest/v1/rpc/request_organiser_payout",
            JSONObject()
                .put("p_organisation_id", organisationId)
                .put("p_amount_minor", Math.round(amountEtb * 100.0))
                .put("p_provider", provider)
                .put("p_idempotency_key", idempotencyKey),
            useSession = true
        )
    }

    fun fetchChapaPayoutDestinations(): JSONArray {
        requireSignedIn()
        return request("GET", "/functions/v1/chapa-payout-banks", useSession = true)
            .optJSONArray("destinations") ?: JSONArray()
    }

    fun configureOrganiserPayout(
        organisationId: String,
        accountName: String,
        accountNumber: String,
        bankSlug: String
    ): JSONObject {
        requireSignedIn()
        return request(
            "POST", "/functions/v1/create-chapa-organizer-subaccount",
            JSONObject()
                .put("organisation_id", organisationId)
                .put("account_name", accountName.trim())
                .put("account_number", accountNumber.trim())
                .put("bank_slug", bankSlug.trim().lowercase()),
            useSession = true
        )
    }

    fun fetchPlatformRevenueSummary(): JSONObject {
        requireSignedIn()
        return request("GET", "/functions/v1/platform-revenue-summary", useSession = true)
    }

    fun withdrawPlatformRevenue(
        amountEtb: Double,
        accountName: String,
        accountNumber: String,
        bankSlug: String
    ): JSONObject {
        requireSignedIn()
        return request(
            "POST", "/functions/v1/create-platform-payout",
            JSONObject()
                .put("amount_etb", amountEtb)
                .put("account_name", accountName.trim())
                .put("account_number", accountNumber.trim())
                .put("bank_slug", bankSlug.trim().lowercase()),
            useSession = true
        )
    }

    fun checkInTicket(eventId: String, ticketToken: String, deviceReference: String? = null): JSONObject {
        requireSignedIn()
        return request(
            "POST", "/rest/v1/rpc/checkin_ticket",
            JSONObject().put("p_ticket_token", ticketToken).put("p_event_id", eventId).put("p_device_reference", deviceReference),
            useSession = true
        )
    }

    private fun saveSessionIfPresent(json: JSONObject): Session? {
        val access = json.optString("access_token")
        val refresh = json.optString("refresh_token")
        val user = json.optJSONObject("user")
        if (access.isBlank() || refresh.isBlank() || user == null) return null
        val session = Session(access, refresh, user.optString("id"), user.optString("email"))
        sessionStore.write(session)
        return session
    }

    private fun requestArray(method: String, path: String, useSession: Boolean): JSONArray {
        val result = request(method, path, null, useSession)
        return result.optJSONArray("data") ?: JSONArray()
    }

    private fun request(
        method: String,
        path: String,
        body: JSONObject? = null,
        useSession: Boolean = true,
        prefer: String? = null
    ): JSONObject {
        requireConfigured()
        val base = BuildConfig.SUPABASE_URL.trimEnd('/')
        val connection = (URL(base + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15_000
            readTimeout = 20_000
            setRequestProperty("apikey", BuildConfig.SUPABASE_ANON_KEY)
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Authorization", "Bearer " + if (useSession) currentSession()?.accessToken.orEmpty() else BuildConfig.SUPABASE_ANON_KEY)
            if (prefer != null) setRequestProperty("Prefer", prefer)
            if (body != null) doOutput = true
        }
        try {
            if (body != null) connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { reader -> reader.readText() }.orEmpty()
            if (code !in 200..299) {
                val message = try { JSONObject(text).optString("message").ifBlank { JSONObject(text).optString("error") } } catch (_: Exception) { text }
                if (code == 401 && useSession && currentSession() != null) {
                    val refreshed = refreshSession()
                    if (refreshed != null) return request(method, path, body, true, prefer)
                }
                throw ApiException(message.ifBlank { "Server request failed ($code)" }, code)
            }
            if (text.isBlank()) return JSONObject()
            return try { JSONObject().put("data", JSONArray(text)) } catch (_: Exception) {
                try { JSONObject(text) } catch (_: Exception) { JSONObject().put("raw", text) }
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun normalizeEthiopianPhone(input: String): String {
        val digits = input.trim().replace(" ", "").replace("-", "").replace("(", "").replace(")", "")
        val normalized = when {
            digits.startsWith("+251") -> digits
            digits.startsWith("251") -> "+$digits"
            digits.startsWith("0") -> "+251${digits.drop(1)}"
            else -> digits
        }
        if (!Regex("^\\+251[79]\\d{8}$").matches(normalized)) {
            throw ApiException("Enter a valid Ethiopian mobile number, for example +251911234567.")
        }
        return normalized
    }

    private fun requireConfigured() {
        if (!isConfigured()) throw ApiException("Tiqet backend is not configured. Add SUPABASE_URL and SUPABASE_ANON_KEY to the GitHub Actions repository variables.")
    }

    private fun requireSignedIn() {
        requireConfigured()
        if (currentSession() == null) throw ApiException("Sign in to continue.")
    }
}

/** Encrypts access and refresh tokens using a non-exportable Android Keystore AES key (API 23+). */
private class SecureSessionStore(context: Context) {
    private val prefs = context.getSharedPreferences("tiqet_secure_session", Context.MODE_PRIVATE)
    private val alias = "tiqet.session.aes.v1"

    fun write(session: TiqetApi.Session) {
        val raw = JSONObject()
            .put("access", session.accessToken)
            .put("refresh", session.refreshToken)
            .put("user", session.userId)
            .put("email", session.email)
            .toString().toByteArray(Charsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getKey())
        val ciphertext = cipher.doFinal(raw)
        val iv = Base64.encodeToString(cipher.iv, Base64.NO_WRAP)
        val encrypted = Base64.encodeToString(ciphertext, Base64.NO_WRAP)
        prefs.edit().putString("iv", iv).putString("blob", encrypted).apply()
    }

    fun read(): TiqetApi.Session? {
        val ivText = prefs.getString("iv", null) ?: return null
        val blobText = prefs.getString("blob", null) ?: return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, getKey(), GCMParameterSpec(128, Base64.decode(ivText, Base64.NO_WRAP)))
            val plaintext = cipher.doFinal(Base64.decode(blobText, Base64.NO_WRAP))
            val json = JSONObject(String(plaintext, Charsets.UTF_8))
            TiqetApi.Session(json.getString("access"), json.getString("refresh"), json.getString("user"), json.optString("email"))
        } catch (_: Exception) {
            clear()
            null
        }
    }

    fun clear() { prefs.edit().clear().apply() }

    private fun getKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }
}
