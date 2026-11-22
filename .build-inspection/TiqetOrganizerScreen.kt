package et.events.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import et.events.mobile.backend.TiqetApi
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

private val OrgRed = Color(0xFFB82035)
private val OrgIvory = Color(0xFFF7F1E7)
private val OrgInk = Color(0xFF2B2020)
private val OrgMuted = Color(0xFF8C7771)

@Composable
fun TiqetOrganizerScreen(api: TiqetApi, onSwitchRole: () -> Unit, onSignOut: () -> Unit) {
    var organisations by remember { mutableStateOf(JSONArray()) }
    var events by remember { mutableStateOf(JSONArray()) }
    var loading by remember { mutableStateOf(true) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    var notice by remember { mutableStateOf("") }
    var selectedScanEventId by remember { mutableStateOf<String?>(null) }
    var payoutDestinations by remember { mutableStateOf(JSONArray()) }
    var ownerRevenue by remember { mutableStateOf(JSONObject()) }
    var organiserSettlementSummary by remember { mutableStateOf(JSONObject()) }
    var organiserSettlementHistory by remember { mutableStateOf(JSONObject()) }
    var ownerCashoutAmount by remember { mutableStateOf("") }
    var ownerCashoutBankSlug by remember { mutableStateOf("") }
    var ownerCashoutAccountName by remember { mutableStateOf("") }
    var ownerCashoutAccountNumber by remember { mutableStateOf("") }
    var organiserBankSlug by remember { mutableStateOf("") }
    var organiserAccountName by remember { mutableStateOf("") }
    var organiserAccountNumber by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val qrScanner = rememberLauncherForActivityResult(ScanContract()) { scanResult ->
        val token = scanResult.contents
        val eventId = selectedScanEventId
        if (!token.isNullOrBlank() && !eventId.isNullOrBlank()) {
            scope.launch {
                error = ""
                notice = "Checking ticket…"
                try {
                    val result = withContext(Dispatchers.IO) {
                        api.checkInTicket(eventId, token, android.os.Build.MODEL)
                    }
                    notice = when {
                        result.optBoolean("valid") -> "ENTRY APPROVED · Ticket checked in successfully."
                        result.optString("reason") == "already_checked_in" -> "DUPLICATE · This ticket has already been scanned."
                        result.optString("reason") == "ticket_not_found" -> "INVALID · This ticket does not belong to this event."
                        else -> "INVALID · This ticket cannot be used for entry."
                    }
                } catch (exception: Exception) {
                    error = exception.message ?: "Ticket validation failed."
                    notice = ""
                } finally {
                    selectedScanEventId = null
                }
            }
        } else {
            selectedScanEventId = null
        }
    }

    fun refresh() {
        scope.launch {
            loading = true
            try {
                val result = withContext(Dispatchers.IO) {
                    api.fetchMyOrganisations() to api.fetchMyOrganiserEvents()
                }
                organisations = result.first
                events = result.second
                try { payoutDestinations = withContext(Dispatchers.IO) { api.fetchChapaPayoutDestinations() } } catch (_: Exception) { payoutDestinations = JSONArray() }
                try { ownerRevenue = withContext(Dispatchers.IO) { api.fetchPlatformRevenueSummary() } } catch (_: Exception) { ownerRevenue = JSONObject() }
                error = ""
            } catch (exception: Exception) {
                error = exception.message ?: "Could not load organiser information."
            } finally { loading = false }
        }
    }

    LaunchedEffect(api) { refresh() }

    val organisation = organisations.optJSONObject(0)
    val organisationStatus = organisation?.optString("status", "") ?: ""
    val verifiedOrganisationId = if (organisationStatus == "verified") organisation?.optString("id") else null

    LaunchedEffect(verifiedOrganisationId) {
        val id = verifiedOrganisationId
        if (!id.isNullOrBlank()) {
            try {
                val data = withContext(Dispatchers.IO) {
                    api.fetchOrganiserSettlementSummary(id) to api.fetchOrganiserSettlementHistory(id, 8, 0)
                }
                organiserSettlementSummary = data.first
                organiserSettlementHistory = data.second
            } catch (_: Exception) {
                organiserSettlementSummary = JSONObject()
                organiserSettlementHistory = JSONObject()
            }
        } else {
            organiserSettlementSummary = JSONObject()
            organiserSettlementHistory = JSONObject()
        }
    }

    var organisationName by remember { mutableStateOf("") }
    var legalName by remember { mutableStateOf("") }
    var contactPhone by remember { mutableStateOf("") }
    var eventTitle by remember { mutableStateOf("") }
    var eventDescription by remember { mutableStateOf("") }
    var eventCategory by remember { mutableStateOf("Music") }
    var eventDate by remember { mutableStateOf("") }
    var venueName by remember { mutableStateOf("") }
    var address by remember { mutableStateOf("") }
    var city by remember { mutableStateOf("Addis Ababa") }
    var ticketName by remember { mutableStateOf("Regular") }
    var price by remember { mutableStateOf("") }
    var quantity by remember { mutableStateOf("") }

    Column(modifier = Modifier.fillMaxSize().background(OrgIvory).verticalScroll(rememberScrollState()).padding(horizontal = 21.dp)) {
        Spacer(Modifier.height(22.dp))
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("TIQET", color = OrgRed, fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 3.sp)
            Text("ORGANISER", color = OrgMuted, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.2.sp)
        }
        Spacer(Modifier.height(23.dp))
        Text("Organiser workspace", color = OrgInk, fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(7.dp))
        Text("Your organisation must be verified before you can create events for sale.", color = OrgMuted, fontSize = 12.sp, lineHeight = 18.sp)
        Spacer(Modifier.height(19.dp))

        if (ownerRevenue.optBoolean("is_owner")) {
            Column(modifier = Modifier.fillMaxWidth().background(Color.White, RoundedCornerShape(16.dp)).padding(16.dp)) {
                Text("TIQET PLATFORM REVENUE", color = OrgRed, fontSize = 9.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 1.3.sp)
                Spacer(Modifier.height(7.dp))
                Text("ETB ${"%.2f".format(Locale.US, ownerRevenue.optDouble("ledger_available_etb"))}", color = OrgInk, fontSize = 25.sp, fontWeight = FontWeight.Bold)
                Text("Ledger amount available before payment fees, taxes, refunds, disputes and operating costs.", color = OrgMuted, fontSize = 11.sp, lineHeight = 16.sp)
                Spacer(Modifier.height(8.dp))
                Text("Gross Tiqet revenue: ETB ${"%.2f".format(Locale.US, ownerRevenue.optDouble("gross_platform_revenue_etb"))}", color = OrgInk, fontSize = 11.sp)
                Text("Successfully withdrawn: ETB ${"%.2f".format(Locale.US, ownerRevenue.optDouble("total_successful_withdrawals_etb"))}", color = OrgMuted, fontSize = 11.sp)
                Text("Successful payout fees: ETB ${"%.2f".format(Locale.US, ownerRevenue.optDouble("successful_payout_fees_etb"))}", color = OrgMuted, fontSize = 11.sp)
                Spacer(Modifier.height(11.dp))
                Text("Active payout destinations: " + (0 until payoutDestinations.length()).mapNotNull { i ->
                    payoutDestinations.optJSONObject(i)?.let { "${it.optString("name")} (${it.optString("slug")})" }
                }.joinToString(" · ").ifBlank { "Not available" }, color = OrgMuted, fontSize = 10.sp, lineHeight = 15.sp)
                Spacer(Modifier.height(8.dp))
                OrgField("Withdrawal amount in ETB", ownerCashoutAmount, { ownerCashoutAmount = it.filter { c -> c.isDigit() || c == '.' } }, KeyboardType.Decimal)
                OrgField("Destination bank / wallet slug", ownerCashoutBankSlug, { ownerCashoutBankSlug = it.trim().lowercase() })
                OrgField("Account holder name", ownerCashoutAccountName, { ownerCashoutAccountName = it })
                OrgField("Bank or wallet account number", ownerCashoutAccountNumber, { ownerCashoutAccountNumber = it.filter(Char::isDigit) }, KeyboardType.Number)
                OrgActionButton("Withdraw Tiqet revenue", working) {
                    val amount = ownerCashoutAmount.toDoubleOrNull()
                    if (amount == null || amount <= 0 || ownerCashoutBankSlug.isBlank() || ownerCashoutAccountName.isBlank() || ownerCashoutAccountNumber.isBlank()) {
                        error = "Complete the amount and destination account details first."
                    } else {
                        working = true; error = ""; notice = ""
                        scope.launch {
                            try {
                                val payout = withContext(Dispatchers.IO) {
                                    api.withdrawPlatformRevenue(amount, ownerCashoutAccountName, ownerCashoutAccountNumber, ownerCashoutBankSlug)
                                }
                                notice = "Withdrawal submitted: ${payout.optString("merchant_reference")}. Status: ${payout.optString("status").uppercase()}. It is not complete until Chapa confirms success."
                                ownerCashoutAmount = ""
                                ownerRevenue = withContext(Dispatchers.IO) { api.fetchPlatformRevenueSummary() }
                            } catch (exception: Exception) { error = exception.message ?: "Withdrawal could not be submitted." }
                            finally { working = false }
                        }
                    }
                }
            }
            Spacer(Modifier.height(18.dp))
        }

        if (loading) {
            Text("Loading your organiser status…", color = OrgMuted, fontSize = 13.sp)
        } else if (organisation == null) {
            Text("Apply to organise events", color = OrgInk, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            Text("Submit your organisation details. Tiqet will review the application before enabling event publishing.", color = OrgMuted, fontSize = 12.sp, lineHeight = 18.sp)
            Spacer(Modifier.height(14.dp))
            OrgField("Public organisation name", organisationName, { organisationName = it })
            OrgField("Registered / legal name", legalName, { legalName = it })
            OrgField("Contact phone (+251…)", contactPhone, { contactPhone = it }, KeyboardType.Phone)
            Spacer(Modifier.height(12.dp))
            OrgActionButton("Submit verification application", working) {
                if (organisationName.isBlank() || legalName.isBlank() || contactPhone.isBlank()) {
                    error = "Complete all organisation fields first."
                } else {
                    working = true; error = ""; notice = ""
                    scope.launch {
                        try {
                            withContext(Dispatchers.IO) { api.submitOrganisationApplication(organisationName, legalName, contactPhone) }
                            notice = "Application submitted. Your status is now pending review."
                            refresh()
                        } catch (exception: Exception) { error = exception.message ?: "Application could not be submitted." }
                        finally { working = false }
                    }
                }
            }
        } else if (organisationStatus == "pending") {
            StatusPanel("Application under review", "${organisation.optString("name")} has been submitted. Event creation will unlock after verification.", "PENDING")
        } else if (organisationStatus == "rejected" || organisationStatus == "suspended") {
            StatusPanel("Organiser access unavailable", organisation.optString("verification_notes", "Contact Tiqet support for the next steps."), organisationStatus.uppercase())
        } else if (verifiedOrganisationId != null) {
            StatusPanel("Organisation verified", "${organisation.optString("name")} is verified. Connect a settlement destination before paid ticket sales can start.", "VERIFIED")
            if (organiserSettlementSummary.has("earned_etb")) {
                Spacer(Modifier.height(14.dp))
                Column(modifier = Modifier.fillMaxWidth().background(Color.White, RoundedCornerShape(15.dp)).padding(16.dp)) {
                    Text("SETTLEMENT LEDGER", color = OrgRed, fontSize = 9.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 1.2.sp)
                    Spacer(Modifier.height(7.dp))
                    Text("ETB ${"%.2f".format(Locale.US, organiserSettlementSummary.optDouble("earned_etb"))}", color = OrgInk, fontSize = 23.sp, fontWeight = FontWeight.Bold)
                    Text("Net organiser settlement recorded by Tiqet", color = OrgMuted, fontSize = 11.sp)
                    Text("This is an internal accounting record, not proof of cleared or unpaid money. The provider's settlement statement is authoritative.", color = OrgMuted, fontSize = 10.sp, lineHeight = 15.sp)
                    val rows = organiserSettlementHistory.optJSONArray("transactions") ?: JSONArray()
                    if (rows.length() > 0) {
                        Spacer(Modifier.height(12.dp))
                        Text("RECENT TRANSACTIONS", color = OrgMuted, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                        for (index in 0 until minOf(5, rows.length())) {
                            val row = rows.optJSONObject(index) ?: continue
                            Row(modifier = Modifier.fillMaxWidth().padding(top = 7.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(row.optString("entry_type").replace('_', ' ').replaceFirstChar { it.uppercase() }, color = OrgInk, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                                    Text(row.optString("created_at").take(10), color = OrgMuted, fontSize = 9.sp)
                                }
                                Text("ETB ${"%.2f".format(Locale.US, row.optDouble("amount_etb"))}", color = OrgInk, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
            Text("Organiser settlement", color = OrgInk, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            if (organisation.optString("payout_account_last4").isNotBlank()) {
                StatusPanel("Settlement destination connected", "${organisation.optString("payout_method")} account ending ${organisation.optString("payout_account_last4")}. Chapa routes the organiser's ticket proceeds directly to this destination, less Tiqet's stated organiser commission and provider charges.", "CONNECTED")
            } else {
                Text("Choose a live bank or mobile-money destination from the list below. Your full account number is sent to Chapa over HTTPS and is not saved in Tiqet's database.", color = OrgMuted, fontSize = 11.sp, lineHeight = 16.sp)
                val payoutOptionsText = (0 until payoutDestinations.length()).mapNotNull { i ->
                    payoutDestinations.optJSONObject(i)?.let { "${it.optString("name")} — ${it.optString("slug")}" }
                }.joinToString(" · ")
                Text("Enabled destinations: " + payoutOptionsText.ifBlank { "Unavailable until Chapa payout methods are enabled." }, color = OrgMuted, fontSize = 10.sp, lineHeight = 15.sp)
                Spacer(Modifier.height(8.dp))
                OrgField("Exact bank / wallet slug", organiserBankSlug, { organiserBankSlug = it.trim().lowercase() })
                OrgField("Account holder name", organiserAccountName, { organiserAccountName = it })
                OrgField("Bank or wallet account number", organiserAccountNumber, { organiserAccountNumber = it.filter(Char::isDigit) }, KeyboardType.Number)
                OrgActionButton("Connect settlement destination", working) {
                    if (organiserBankSlug.isBlank() || organiserAccountName.isBlank() || organiserAccountNumber.isBlank()) {
                        error = "Complete all settlement destination fields first."
                    } else {
                        working = true; error = ""; notice = ""
                        scope.launch {
                            try {
                                withContext(Dispatchers.IO) {
                                    api.configureOrganiserPayout(verifiedOrganisationId, organiserAccountName, organiserAccountNumber, organiserBankSlug)
                                }
                                organiserAccountNumber = ""
                                notice = "Chapa settlement destination connected. Paid event checkout can now route proceeds to your account."
                                refresh()
                            } catch (exception: Exception) { error = exception.message ?: "Could not connect settlement destination." }
                            finally { working = false }
                        }
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
            Text("Create an event", color = OrgInk, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            OrgField("Event title", eventTitle, { eventTitle = it })
            OrgField("Category", eventCategory, { eventCategory = it })
            OrgField("Description", eventDescription, { eventDescription = it }, singleLine = false)
            OrgField("Date and time in Addis Ababa (YYYY-MM-DD HH:MM)", eventDate, { eventDate = it })
            OrgField("Venue name", venueName, { venueName = it })
            OrgField("Street address", address, { address = it })
            OrgField("City", city, { city = it })
            Spacer(Modifier.height(8.dp))
            Text("First ticket type", color = OrgInk, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            OrgField("Ticket label", ticketName, { ticketName = it })
            OrgField("Price in ETB", price, { price = it.filter { c -> c.isDigit() || c == '.' } }, KeyboardType.Decimal)
            OrgField("Quantity available", quantity, { quantity = it.filter(Char::isDigit) }, KeyboardType.Number)
            Spacer(Modifier.height(12.dp))
            OrgActionButton("Submit event for review", working) {
                val parsedPrice = price.toDoubleOrNull()
                val parsedQuantity = quantity.toIntOrNull()
                val startsAt = try {
                    val inputFormat = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).apply {
                        isLenient = false
                        timeZone = TimeZone.getTimeZone("Africa/Addis_Ababa")
                    }
                    val parsed: Date = inputFormat.parse(eventDate.trim())
                        ?: throw IllegalArgumentException("Invalid date")
                    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).format(parsed)
                } catch (_: Exception) { null }
                when {
                    eventTitle.isBlank() || venueName.isBlank() || startsAt == null || parsedPrice == null || parsedPrice < 0.0 || parsedQuantity == null || parsedQuantity < 1 || ticketName.isBlank() -> {
                        error = "Check the event title, venue, date format, ticket price and ticket quantity."
                    }
                    parsedPrice > 0.0 && organisation.optString("payout_account_last4").isBlank() -> {
                        error = "Connect your bank or mobile-money settlement destination before submitting a paid event. Free events do not need a payout account."
                    }
                    else -> {
                        working = true; error = ""; notice = ""
                        scope.launch {
                            try {
                                val submission = withContext(Dispatchers.IO) {
                                    api.createEventSubmission(
                                        verifiedOrganisationId, eventTitle, eventDescription, eventCategory,
                                        startsAt, venueName, address, city, ticketName, parsedPrice, parsedQuantity
                                    )
                                }
                                if (submission.optString("event_id").isBlank()) {
                                    throw IllegalStateException("The server did not confirm the event submission.")
                                }
                                notice = "Event submitted to Tiqet for review. It will appear publicly only after approval."
                                eventTitle = ""; eventDescription = ""; eventDate = ""; venueName = ""; address = ""; price = ""; quantity = ""
                                refresh()
                            } catch (exception: Exception) { error = exception.message ?: "Event could not be submitted." }
                            finally { working = false }
                        }
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
            Text("Your event records", color = OrgInk, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            if (events.length() == 0) Text("No events created yet.", color = OrgMuted, fontSize = 12.sp)
            for (index in 0 until events.length()) {
                val event = events.optJSONObject(index) ?: continue
                Column(modifier = Modifier.fillMaxWidth().padding(vertical = 9.dp)) {
                    Text(event.optString("title"), color = OrgInk, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text("${event.optString("status").uppercase()} · ${event.optString("approval_status").uppercase()}", color = OrgRed, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                    if (event.optString("status") == "published" && event.optString("approval_status") == "approved") {
                        Spacer(Modifier.height(7.dp))
                        Button(
                            onClick = {
                                selectedScanEventId = event.optString("id")
                                val options = ScanOptions()
                                    .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                    .setPrompt("Scan a Tiqet ticket for ${event.optString("title")}")
                                    .setBeepEnabled(true)
                                    .setOrientationLocked(false)
                                qrScanner.launch(options)
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = OrgRed)
                        ) { Text("Scan entry QR") }
                    }
                }
            }
        }

        if (error.isNotBlank()) {
            Spacer(Modifier.height(10.dp)); Text(error, color = OrgRed, fontSize = 12.sp, lineHeight = 17.sp)
        }
        if (notice.isNotBlank()) {
            Spacer(Modifier.height(10.dp)); Text(notice, color = OrgInk, fontSize = 12.sp, lineHeight = 17.sp)
        }
        if (!loading) {
            Spacer(Modifier.height(22.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                Button(onClick = onSwitchRole, modifier = Modifier.weight(1f), colors = ButtonDefaults.buttonColors(containerColor = OrgRed)) { Text("Buyer view") }
                Button(onClick = onSignOut, modifier = Modifier.weight(1f), colors = ButtonDefaults.buttonColors(containerColor = OrgMuted)) { Text("Sign out") }
            }
        }
        Spacer(Modifier.height(28.dp))
    }
}

@Composable
private fun OrgField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    keyboardType: KeyboardType = KeyboardType.Text,
    singleLine: Boolean = true
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
        label = { Text(label) },
        singleLine = singleLine,
        minLines = if (singleLine) 1 else 3,
        shape = RoundedCornerShape(11.dp),
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType)
    )
}

@Composable
private fun OrgActionButton(text: String, working: Boolean, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = !working,
        modifier = Modifier.fillMaxWidth().height(50.dp),
        shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(containerColor = OrgRed)
    ) { Text(if (working) "Saving…" else text, fontWeight = FontWeight.Bold) }
}

@Composable
private fun StatusPanel(title: String, description: String, label: String) {
    Column(modifier = Modifier.fillMaxWidth().background(Color.White, RoundedCornerShape(15.dp)).padding(17.dp)) {
        Text(label, color = OrgRed, fontSize = 9.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 1.3.sp)
        Spacer(Modifier.height(7.dp))
        Text(title, color = OrgInk, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Text(description, color = OrgMuted, fontSize = 12.sp, lineHeight = 18.sp)
    }
}
