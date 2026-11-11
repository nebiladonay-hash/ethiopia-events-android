#!/usr/bin/env python3
"""Simplify Tiqet event creation, publish instantly, fit uploaded artwork, and expose ticket tiers."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
organizer = root / "app/src/main/java/et/events/mobile/TiqetOrganizerScreen.kt"
api = root / "app/src/main/java/et/events/mobile/backend/TiqetApi.kt"
main = root / "app/src/main/java/et/events/mobile/MainActivity.kt"


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    source = path.read_text()
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor in {path.name}; found {count}")
    path.write_text(source.replace(old, new, 1))


def replace_region(path: Path, start_marker: str, end_marker: str, replacement: str, label: str) -> None:
    source = path.read_text()
    start = source.find(start_marker)
    if start < 0:
        raise SystemExit(f"{label}: start anchor not found in {path.name}")
    end = source.find(end_marker, start + len(start_marker))
    if end < 0:
        raise SystemExit(f"{label}: end anchor not found in {path.name}")
    path.write_text(source[:start] + replacement + source[end:])


# ---------- Organizer event creation ----------
replace_once(organizer,
    "import com.journeyapps.barcodescanner.ScanOptions\n",
    "import com.journeyapps.barcodescanner.ScanOptions\nimport android.net.Uri\n",
    "Organizer image Uri import")
replace_once(organizer,
    "    val verifiedOrganisationId = if (organisationStatus == \"verified\") organisation?.optString(\"id\") else null\n",
    "    val verifiedOrganisationId = if (organisationStatus == \"verified\") organisation?.optString(\"id\") else null\n"
    "    val eventOrganisationId = organisation?.optString(\"id\")?.takeIf { it.isNotBlank() && it != \"null\" }\n",
    "Allow event creation for owned organiser profiles")
replace_once(organizer,
    "    var ticketName by remember { mutableStateOf(\"Regular\") }\n"
    "    var price by remember { mutableStateOf(\"\") }\n"
    "    var quantity by remember { mutableStateOf(\"\") }\n",
    "    var regularPrice by remember { mutableStateOf(\"0\") }\n"
    "    var regularQuantity by remember { mutableStateOf(\"100\") }\n"
    "    var includeVip by remember { mutableStateOf(false) }\n"
    "    var vipPrice by remember { mutableStateOf(\"\") }\n"
    "    var vipQuantity by remember { mutableStateOf(\"50\") }\n"
    "    var includeVvip by remember { mutableStateOf(false) }\n"
    "    var vvipPrice by remember { mutableStateOf(\"\") }\n"
    "    var vvipQuantity by remember { mutableStateOf(\"25\") }\n"
    "    var eventBannerUri by remember { mutableStateOf<Uri?>(null) }\n",
    "Simple regular VIP VVIP ticket form state")
replace_once(organizer,
    "    val bannerPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->",
    "    val eventBannerPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->\n"
    "        eventBannerUri = uri\n"
    "    }\n"
    "    val bannerPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->",
    "Event creation banner picker")

replace_once(organizer,
    'Text("Your organisation must be verified before you can create events for sale.", color = OrgMuted, fontSize = 12.sp, lineHeight = 18.sp)',
    'Text("Create and publish events in a few simple steps.", color = OrgMuted, fontSize = 12.sp, lineHeight = 18.sp)',
    "Remove verification gate copy from organiser workspace header")
replace_once(organizer,
    'Text("Submit your organisation details. Tiqet will review the application before enabling event publishing.", color = OrgMuted, fontSize = 12.sp, lineHeight = 18.sp)',
    'Text("Add your organiser details once. You can publish events straight away; paid ticket sales need a connected settlement account.", color = OrgMuted, fontSize = 12.sp, lineHeight = 18.sp)',
    "Simplify first organiser profile explanation")
replace_once(organizer,
    'OrgActionButton("Submit verification application", working) {',
    'OrgActionButton("Create organiser profile", working) {',
    "Rename organiser profile action")
replace_once(organizer,
    'notice = "Application submitted. Your status is now pending review."',
    'notice = "Organiser profile created. You can publish events now."',
    "Remove approval copy from organiser application")

old_status = """        } else if (organisationStatus == "pending") {
            StatusPanel("Application under review", "${organisation.optString("name")} has been submitted. Event creation will unlock after verification.", "PENDING")
        } else if (organisationStatus == "rejected" || organisationStatus == "suspended") {
            StatusPanel("Organiser access unavailable", organisation.optString("verification_notes", "Contact Tiqet support for the next steps."), organisationStatus.uppercase())
        } else if (verifiedOrganisationId != null) {
            StatusPanel("Organisation verified", "${organisation.optString("name")} is verified. Connect a settlement destination before paid ticket sales can start.", "VERIFIED")"""
new_status = """        } else if (organisationStatus == "suspended") {
            StatusPanel("Organiser access unavailable", organisation.optString("verification_notes", "Contact Tiqet support for the next steps."), "SUSPENDED")
        } else if (organisation != null) {
            if (verifiedOrganisationId != null) {
                StatusPanel("Organisation verified", "${organisation.optString("name")} is verified. Your settlement account can receive paid ticket proceeds.", "VERIFIED")"""
replace_once(organizer, old_status, new_status, "Allow pending and rejected organiser profiles to publish")

replace_once(
    organizer,
    '            Spacer(Modifier.height(20.dp))\n            Text("Create an event", color = OrgInk, fontSize = 19.sp, fontWeight = FontWeight.Bold)',
    '''            } else {
                StatusPanel(
                    "You can publish events now",
                    "Free events can go live immediately. Paid ticket sales turn on once your settlement account is connected.",
                    "OPEN"
                )
            }
            Spacer(Modifier.height(20.dp))
            Text("Create an event", color = OrgInk, fontSize = 19.sp, fontWeight = FontWeight.Bold)''',
    "Separate event publishing from paid settlement verification"
)

new_form = """            Text("Create an event", color = OrgInk, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(5.dp))
            Text("Add the basics, choose your tickets and publish. Your event goes live immediately.", color = OrgMuted, fontSize = 11.sp, lineHeight = 16.sp)
            Spacer(Modifier.height(10.dp))
            OrgField("Event name", eventTitle, { eventTitle = it })
            OrgField("Category", eventCategory, { eventCategory = it })
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                listOf("Music", "Boxing Matches", "Culture", "Nightlife", "Sports", "Conference", "Other").forEach { category ->
                    Button(
                        onClick = { eventCategory = category },
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 10.dp, vertical = 5.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (eventCategory == category) OrgRed else Color.White,
                            contentColor = if (eventCategory == category) Color.White else OrgInk
                        )
                    ) { Text(category, fontSize = 10.sp) }
                }
            }
            OrgField("Short description (optional)", eventDescription, { eventDescription = it }, singleLine = false)
            OrgField("Date and time · Addis Ababa (YYYY-MM-DD HH:MM)", eventDate, { eventDate = it })
            OrgField("Venue", venueName, { venueName = it })
            OrgField("Address (optional)", address, { address = it })
            OrgField("City", city, { city = it })

            Spacer(Modifier.height(9.dp))
            Text("EVENT BANNER", color = OrgInk, fontWeight = FontWeight.Bold, fontSize = 11.sp, letterSpacing = 0.8.sp)
            Spacer(Modifier.height(6.dp))
            if (eventBannerUri != null) {
                AsyncImage(
                    model = eventBannerUri,
                    contentDescription = "Selected event artwork",
                    modifier = Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(13.dp)),
                    contentScale = ContentScale.Fit
                )
                Spacer(Modifier.height(6.dp))
            }
            Button(
                onClick = { eventBannerPicker.launch("image/*") },
                enabled = !working,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = if (eventBannerUri == null) OrgRed else Color.White, contentColor = if (eventBannerUri == null) Color.White else OrgInk)
            ) { Text(if (eventBannerUri == null) "Choose event poster / photo" else "Change event poster") }
            Text("No special banner size needed. Tiqet automatically resizes and fits your photo into a wide event banner.", color = OrgMuted, fontSize = 10.sp, lineHeight = 14.sp)

            Spacer(Modifier.height(14.dp))
            Text("TICKET OPTIONS", color = OrgInk, fontWeight = FontWeight.Bold, fontSize = 12.sp, letterSpacing = 0.8.sp)
            Text("Regular is included. Add VIP or VVIP only when you need them.", color = OrgMuted, fontSize = 10.sp)
            Spacer(Modifier.height(7.dp))
            Column(Modifier.fillMaxWidth().background(Color.White, RoundedCornerShape(13.dp)).padding(12.dp)) {
                Text("REGULAR", color = OrgInk, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                OrgField("Regular price in ETB (0 = free)", regularPrice, { regularPrice = it.filter { c -> c.isDigit() || c == '.' } }, KeyboardType.Decimal)
                OrgField("Regular tickets available", regularQuantity, { regularQuantity = it.filter(Char::isDigit) }, KeyboardType.Number)
            }
            Spacer(Modifier.height(7.dp))
            if (includeVip) {
                Column(Modifier.fillMaxWidth().background(Color.White, RoundedCornerShape(13.dp)).padding(12.dp)) {
                    Text("VIP", color = OrgRed, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                    OrgField("VIP price in ETB", vipPrice, { vipPrice = it.filter { c -> c.isDigit() || c == '.' } }, KeyboardType.Decimal)
                    OrgField("VIP tickets available", vipQuantity, { vipQuantity = it.filter(Char::isDigit) }, KeyboardType.Number)
                }
            }
            if (includeVvip) {
                Column(Modifier.fillMaxWidth().background(Color.White, RoundedCornerShape(13.dp)).padding(12.dp)) {
                    Text("VVIP", color = OrgRed, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                    OrgField("VVIP price in ETB", vvipPrice, { vvipPrice = it.filter { c -> c.isDigit() || c == '.' } }, KeyboardType.Decimal)
                    OrgField("VVIP tickets available", vvipQuantity, { vvipQuantity = it.filter(Char::isDigit) }, KeyboardType.Number)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp), modifier = Modifier.fillMaxWidth()) {
                if (!includeVip) {
                    Button(
                        onClick = { includeVip = true },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = OrgRed)
                    ) { Text("+ Add VIP", fontSize = 11.sp) }
                }
                if (!includeVvip) {
                    Button(
                        onClick = { includeVvip = true },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = OrgRed)
                    ) { Text("+ Add VVIP", fontSize = 11.sp) }
                }
            }
            Spacer(Modifier.height(12.dp))
            OrgActionButton("Publish event now", working) {
                val parsedRegularPrice = regularPrice.toDoubleOrNull()
                val parsedRegularQuantity = regularQuantity.toIntOrNull()
                val parsedVipPrice = if (includeVip) vipPrice.toDoubleOrNull() else null
                val parsedVipQuantity = if (includeVip) vipQuantity.toIntOrNull() else null
                val parsedVvipPrice = if (includeVvip) vvipPrice.toDoubleOrNull() else null
                val parsedVvipQuantity = if (includeVvip) vvipQuantity.toIntOrNull() else null
                val startsAt = try {
                    val inputFormat = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).apply {
                        isLenient = false
                        timeZone = TimeZone.getTimeZone("Africa/Addis_Ababa")
                    }
                    val parsed: Date = inputFormat.parse(eventDate.trim())
                        ?: throw IllegalArgumentException("Invalid date")
                    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).format(parsed)
                } catch (_: Exception) { null }

                val ticketOptions = JSONArray()
                if (parsedRegularPrice != null && parsedRegularQuantity != null) {
                    ticketOptions.put(JSONObject().put("name", "Regular").put("price_etb", parsedRegularPrice).put("quantity_total", parsedRegularQuantity))
                }
                if (includeVip && parsedVipPrice != null && parsedVipQuantity != null) {
                    ticketOptions.put(JSONObject().put("name", "VIP").put("price_etb", parsedVipPrice).put("quantity_total", parsedVipQuantity))
                }
                if (includeVvip && parsedVvipPrice != null && parsedVvipQuantity != null) {
                    ticketOptions.put(JSONObject().put("name", "VVIP").put("price_etb", parsedVvipPrice).put("quantity_total", parsedVvipQuantity))
                }
                val hasPaidTickets = (0 until ticketOptions.length()).any {
                    (ticketOptions.optJSONObject(it)?.optDouble("price_etb") ?: 0.0) > 0.0
                }

                when {
                    eventOrganisationId.isNullOrBlank() -> error = "Create your organiser profile first."
                    eventTitle.isBlank() || venueName.isBlank() || startsAt == null -> error = "Add an event name, venue and valid future date."
                    parsedRegularPrice == null || parsedRegularPrice < 0.0 || parsedRegularQuantity == null || parsedRegularQuantity !in 1..100000 -> error = "Enter a valid Regular ticket price and quantity."
                    includeVip && (parsedVipPrice == null || parsedVipPrice < 0.0 || parsedVipQuantity == null || parsedVipQuantity !in 1..100000) -> error = "Check the VIP price and quantity."
                    includeVvip && (parsedVvipPrice == null || parsedVvipPrice < 0.0 || parsedVvipQuantity == null || parsedVvipQuantity !in 1..100000) -> error = "Check the VVIP price and quantity."
                    hasPaidTickets && organisation.optString("payout_account_last4").isBlank() -> error = "To sell paid tickets, first connect your bank or mobile-money settlement account. You can publish a free event now."
                    else -> {
                        working = true
                        error = ""
                        notice = ""
                        val selectedBanner = eventBannerUri
                        val ownerOrganisationId = eventOrganisationId ?: ""
                        scope.launch {
                            try {
                                val submission = withContext(Dispatchers.IO) {
                                    api.createEventWithTicketOptions(
                                        ownerOrganisationId, eventTitle, eventDescription, eventCategory,
                                        startsAt, venueName, address, city, ticketOptions
                                    )
                                }
                                val newEventId = submission.optString("event_id")
                                if (newEventId.isBlank()) throw IllegalStateException("Tiqet did not return an event ID.")
                                var bannerNote = ""
                                if (selectedBanner != null) {
                                    try {
                                        withContext(Dispatchers.IO) { api.uploadEventBanner(ownerOrganisationId, newEventId, selectedBanner) }
                                    } catch (bannerError: Exception) {
                                        bannerNote = " Your event is live, but its banner could not be uploaded: ${bannerError.message ?: "try again from Your event records"}."
                                    }
                                }
                                notice = "Your event is live on Tiqet!" + bannerNote
                                eventTitle = ""
                                eventDescription = ""
                                eventDate = ""
                                venueName = ""
                                address = ""
                                regularPrice = ""
                                regularQuantity = "100"
                                includeVip = false
                                vipPrice = ""
                                vipQuantity = "50"
                                includeVvip = false
                                vvipPrice = ""
                                vvipQuantity = "25"
                                eventBannerUri = null
                                refresh()
                            } catch (exception: Exception) {
                                error = exception.message ?: "Event could not be published."
                            } finally {
                                working = false
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
"""
replace_region(
    organizer,
    '            Text("Create an event", color = OrgInk, fontSize = 19.sp, fontWeight = FontWeight.Bold)',
    '            Text("Your event records", color = OrgInk, fontSize = 18.sp, fontWeight = FontWeight.Bold)',
    new_form,
    "Replace event creation with simple instant-publish form and tier options"
)
replace_once(
    organizer,
    'Text("${event.optString("status").uppercase()} · ${event.optString("approval_status").uppercase()}", color = OrgRed, fontSize = 10.sp, fontWeight = FontWeight.Bold)',
    'Text(if (event.optString("status") == "published") "LIVE ON TIQET" else event.optString("status").uppercase(), color = OrgRed, fontSize = 10.sp, fontWeight = FontWeight.Bold)',
    "Remove approval label from organiser event records"
)

# ---------- TiqetApi ticket options and automatic banner fitting ----------
replace_once(api,
    "import android.content.Context\n",
    "import android.content.Context\n"
    "import android.graphics.Bitmap\n"
    "import android.graphics.BitmapFactory\n"
    "import android.graphics.Canvas\n"
    "import android.graphics.Color\n"
    "import android.graphics.Paint\n"
    "import android.graphics.Path\n"
    "import android.graphics.RectF\n",
    "Android bitmap image processing imports")
replace_once(api,
    "import java.net.HttpURLConnection\n",
    "import java.io.ByteArrayOutputStream\nimport java.net.HttpURLConnection\n",
    "Compressed banner output stream import")
replace_once(api,
    "    data class Event(\n",
    "    data class TicketOption(val id: String, val name: String, val priceEtb: Double)\n\n"
    "    data class Event(\n",
    "Ticket option model")
replace_once(api,
    "        val minimumPriceEtb: Double?,\n"
    "        val ticketTypeId: String?,\n"
    "        val ticketTypeName: String?\n"
    "    )",
    "        val minimumPriceEtb: Double?,\n"
    "        val ticketTypeId: String?,\n"
    "        val ticketTypeName: String?,\n"
    "        val ticketOptions: List<TicketOption> = emptyList()\n"
    "    )",
    "Event model ticket options")
replace_once(api,
    '"&status=eq.published&approval_status=eq.approved&order=starts_at.asc"',
    '"&status=eq.published&order=starts_at.asc"',
    "Remove event approval filter from public discovery")
api_source = api.read_text()
published_start = api_source.find("    fun fetchPublishedEvents(")
spotlight_start = api_source.find("    fun fetchSpotlightEvents(", published_start + 1)
if published_start < 0 or spotlight_start < 0:
    raise SystemExit("Could not find public/Spotlight event reader boundaries.")
published_region = api_source[published_start:spotlight_start]
old_public_event = """                ticketTypeName = cheapest?.optString("name")?.takeIf { !it.isNullOrBlank() && it != "null" }
"""
new_public_event = """                ticketTypeName = cheapest?.optString("name")?.takeIf { !it.isNullOrBlank() && it != "null" },
                ticketOptions = ticketRows.mapNotNull { ticket ->
                    val id = ticket.optString("id")
                    if (id.isBlank() || id == "null") null else TicketOption(id, ticket.optString("name", "Regular"), ticket.optDouble("price_etb"))
                }
"""
if published_region.count(old_public_event) != 1:
    raise SystemExit(
        "Public event ticket tier mapping: expected one constructor inside fetchPublishedEvents; "
        f"found {published_region.count(old_public_event)}"
    )
published_region = published_region.replace(old_public_event, new_public_event, 1)
api.write_text(api_source[:published_start] + published_region + api_source[spotlight_start:])

replace_once(api,
    "    fun createEventSubmission(\n",
    """    fun createEventWithTicketOptions(
        organisationId: String, title: String, description: String, category: String,
        startsAtIso: String, venueName: String, address: String, city: String,
        ticketOptions: JSONArray
    ): JSONObject {
        requireSignedIn()
        require(ticketOptions.length() in 1..3) { "Add at least one ticket option." }
        return request(
            "POST", "/rest/v1/rpc/create_event_with_ticket_options",
            JSONObject()
                .put("p_organisation_id", organisationId)
                .put("p_title", title.trim())
                .put("p_description", description.trim())
                .put("p_category", category.trim())
                .put("p_starts_at", startsAtIso)
                .put("p_venue_name", venueName.trim())
                .put("p_address", address.trim())
                .put("p_city", city.trim())
                .put("p_ticket_options", ticketOptions),
            useSession = true
        )
    }

    fun createEventSubmission(
""",
    "Add tiered instant-publish API method")

old_upload = """        val resolver = appContext.contentResolver
        val mime = resolver.getType(uri)?.lowercase() ?: throw ApiException("Choose a JPEG, PNG or WebP image.")
        val extension = when (mime) {
            "image/jpeg", "image/jpg" -> "jpg"
            "image/png" -> "png"
            "image/webp" -> "webp"
            else -> throw ApiException("Only JPEG, PNG and WebP event banners are supported.")
        }
        val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw ApiException("The selected banner could not be opened.")
        if (bytes.isEmpty() || bytes.size > 8 * 1024 * 1024) throw ApiException("Event banners must be smaller than 8 MB.")
        val objectPath = "$organisationId/$eventId/${java.util.UUID.randomUUID()}.$extension"
"""
new_upload = """        val resolver = appContext.contentResolver
        val mime = resolver.getType(uri)?.lowercase()
        if (mime != null && !mime.startsWith("image/")) throw ApiException("Choose a photo or event poster image.")
        val original = resolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw ApiException("The selected image could not be opened.")
        if (original.isEmpty() || original.size > 25 * 1024 * 1024) {
            throw ApiException("Choose an image smaller than 25 MB.")
        }
        val bytes = fitTiqetEventBanner(original)
        val extension = "jpg"
        val uploadMime = "image/jpeg"
        val objectPath = "$organisationId/$eventId/${java.util.UUID.randomUUID()}.$extension"
"""
replace_once(api, old_upload, new_upload, "Create 16:9 resized JPEG banner before upload")
replace_once(api,
    '            setRequestProperty("Content-Type", mime)\n',
    '            setRequestProperty("Content-Type", uploadMime)\n',
    "Upload transformed banner as JPEG"
)

banner_helper = """
private fun fitTiqetEventBanner(original: ByteArray): ByteArray {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(original, 0, original.size, bounds)
    if (bounds.outWidth < 1 || bounds.outHeight < 1) {
        throw IllegalArgumentException("This image could not be read. Choose another photo.")
    }

    var sample = 1
    while (bounds.outWidth / sample > 2600 || bounds.outHeight / sample > 2600) sample *= 2
    val source = BitmapFactory.decodeByteArray(
        original, 0, original.size,
        BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
    ) ?: throw IllegalArgumentException("This image could not be resized. Choose another photo.")

    val width = 1600
    val height = 900
    val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    try {
        val canvas = Canvas(output)
        val imagePaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        val shadePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(150, 20, 10, 18) }

        // A full-bleed background fills the landscape banner, while the complete poster is
        // fitted on top so important text on portrait flyers is not cut off.
        val coverScale = maxOf(width.toFloat() / source.width, height.toFloat() / source.height)
        val coverWidth = source.width * coverScale
        val coverHeight = source.height * coverScale
        val coverRect = RectF(
            (width - coverWidth) / 2f,
            (height - coverHeight) / 2f,
            (width + coverWidth) / 2f,
            (height + coverHeight) / 2f
        )
        canvas.drawBitmap(source, null, coverRect, imagePaint)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), shadePaint)

        val fitScale = minOf(1460f / source.width, 820f / source.height)
        val fitWidth = source.width * fitScale
        val fitHeight = source.height * fitScale
        val fitted = RectF(
            (width - fitWidth) / 2f,
            (height - fitHeight) / 2f,
            (width + fitWidth) / 2f,
            (height + fitHeight) / 2f
        )
        val card = RectF(fitted.left - 8f, fitted.top - 8f, fitted.right + 8f, fitted.bottom + 8f)
        canvas.drawRoundRect(card, 20f, 20f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE })
        val clipPath = Path().apply {
            addRoundRect(fitted, 12f, 12f, Path.Direction.CW)
        }
        val save = canvas.save()
        canvas.clipPath(clipPath)
        canvas.drawBitmap(source, null, fitted, imagePaint)
        canvas.restoreToCount(save)

        var quality = 90
        var result: ByteArray
        do {
            val stream = ByteArrayOutputStream()
            if (!output.compress(Bitmap.CompressFormat.JPEG, quality, stream)) {
                throw IllegalStateException("The event banner could not be compressed.")
            }
            result = stream.toByteArray()
            quality -= 8
        } while (result.size > 7 * 1024 * 1024 && quality >= 66)

        if (result.size > 8 * 1024 * 1024) {
            throw IllegalArgumentException("The resized banner is still too large. Choose a smaller image.")
        }
        return result
    } finally {
        source.recycle()
        output.recycle()
    }
}

"""
replace_once(api, "class TiqetApi(context: Context) {", banner_helper + "class TiqetApi(context: Context) {", "Add automatic event banner fitter")
api_source = api.read_text()
spotlight_start = api_source.find("    fun fetchSpotlightEvents(")
spotlight_end = api_source.find("    fun fetchMyOrganisations(", spotlight_start + 1)
if spotlight_start < 0 or spotlight_end < 0:
    raise SystemExit("Could not find Spotlight API reader boundaries.")
spotlight_region = api_source[spotlight_start:spotlight_end]
old_spotlight_event = """                    ticketTypeName = cheapest?.optString("name")?.takeIf { !it.isNullOrBlank() && it != "null" }
                ),"""
new_spotlight_event = """                    ticketTypeName = cheapest?.optString("name")?.takeIf { !it.isNullOrBlank() && it != "null" },
                    ticketOptions = (0 until ticketTypes.length()).mapNotNull { ticketIndex ->
                        val option = ticketTypes.optJSONObject(ticketIndex) ?: return@mapNotNull null
                        val id = option.optString("id")
                        if (id.isBlank() || id == "null") null else TicketOption(id, option.optString("name", "Regular"), option.optDouble("price_etb"))
                    }
                ),"""
if spotlight_region.count(old_spotlight_event) != 1:
    raise SystemExit(
        "Spotlight ticket tier mapping: expected one matching Event constructor inside fetchSpotlightEvents; "
        f"found {spotlight_region.count(old_spotlight_event)}"
    )
spotlight_region = spotlight_region.replace(old_spotlight_event, new_spotlight_event, 1)
api.write_text(api_source[:spotlight_start] + spotlight_region + api_source[spotlight_end:])


# ---------- Customer event cards and checkout ticket selection ----------
replace_once(main,
    '    val featuredLabel: String = ""\n)',
    '    val featuredLabel: String = "",\n    val ticketOptions: List<TiqetApi.TicketOption> = emptyList()\n)',
    "Add ticket tiers to event cards")
replace_once(main,
    "                        imageUrl = event.imageUrl\n",
    "                        imageUrl = event.imageUrl,\n                        ticketOptions = event.ticketOptions\n",
    "Map public event ticket tiers to cards")
replace_once(main,
    "                            imageUrl = event.imageUrl, featuredLabel = featured.featuredLabel\n",
    "                            imageUrl = event.imageUrl, featuredLabel = featured.featuredLabel,\n                            ticketOptions = event.ticketOptions\n",
    "Map Spotlight ticket tiers to cards")
replace_once(main,
    "    var ticketCount by remember(event.id) { mutableStateOf(1) }\n",
    "    var ticketCount by remember(event.id) { mutableStateOf(1) }\n"
    "    var selectedTicketOption by remember(event.id) { mutableStateOf(event.ticketOptions.firstOrNull()) }\n",
    "Selected ticket tier state")

old_hero = """        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(200.dp)
                .clip(RoundedCornerShape(22.dp))
                .background(BrandRed),
            contentAlignment = Alignment.Center
        ) {
            TicketMark(color = BrandIvory.copy(alpha = 0.9f), modifier = Modifier.size(86.dp))
        }"""
new_hero = """        if (!event.imageUrl.isNullOrBlank()) {
            AsyncImage(
                model = event.imageUrl,
                contentDescription = "Event poster for ${event.title}",
                modifier = Modifier.fillMaxWidth().height(200.dp).clip(RoundedCornerShape(22.dp)),
                contentScale = ContentScale.Crop
            )
        } else {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp)
                    .clip(RoundedCornerShape(22.dp))
                    .background(BrandRed),
                contentAlignment = Alignment.Center
            ) {
                TicketMark(color = BrandIvory.copy(alpha = 0.9f), modifier = Modifier.size(86.dp))
            }
        }"""
replace_once(main, old_hero, new_hero, "Show uploaded event poster on event detail page")
replace_once(
    main,
    """    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BrandIvory)
            .padding(horizontal = 21.dp)
    ) {
        Spacer(Modifier.height(15.dp))""",
    """    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BrandIvory)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 21.dp)
    ) {
        Spacer(Modifier.height(15.dp))""",
    "Allow event details with multiple ticket tiers to scroll"
)
replace_once(
    main,
    "        Spacer(Modifier.weight(1f))\n        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {",
    "        Spacer(Modifier.height(16.dp))\n        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {",
    "Keep checkout controls in the scrollable event detail"
)

old_ticket_block = """        Text("Tickets", color = Ink, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        Row(
            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp)).background(SoftIvory).border(1.dp, Hairline, RoundedCornerShape(15.dp)).padding(15.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(event.ticketName, color = Ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text("${formatEtb(event.price)} / ticket", color = Muted, fontSize = 11.sp)
            }
            Text("−", color = BrandRed, fontSize = 23.sp, modifier = Modifier.clickable { if (ticketCount > 1) ticketCount-- }.padding(horizontal = 10.dp))
            Text(ticketCount.toString(), color = Ink, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            Text("+", color = BrandRed, fontSize = 23.sp, modifier = Modifier.clickable { if (ticketCount < 10) ticketCount++ }.padding(horizontal = 10.dp))
        }"""
new_ticket_block = """        val chosenTicket = selectedTicketOption ?: event.ticketOptions.firstOrNull()
        val chosenTicketPrice = chosenTicket?.priceEtb ?: event.price
        val chosenTicketTypeId = chosenTicket?.id ?: event.ticketTypeId
        Text("Tickets", color = Ink, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        if (event.ticketOptions.size > 1) {
            event.ticketOptions.forEach { option ->
                val selected = chosenTicket?.id == option.id
                Row(
                    modifier = Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(13.dp))
                        .background(if (selected) Color(0xFFFFE9E6) else SoftIvory)
                        .border(1.dp, if (selected) BrandRed else Hairline, RoundedCornerShape(13.dp))
                        .clickable { selectedTicketOption = option }
                        .padding(13.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(option.name, color = Ink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        Text("${formatEtb(option.priceEtb)} per ticket", color = Muted, fontSize = 10.sp)
                    }
                    Text(if (selected) "SELECTED" else "CHOOSE", color = if (selected) BrandRed else Muted, fontSize = 9.sp, fontWeight = FontWeight.Bold)
                }
                Spacer(Modifier.height(6.dp))
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp)).background(SoftIvory).border(1.dp, Hairline, RoundedCornerShape(15.dp)).padding(15.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(chosenTicket?.name ?: event.ticketName, color = Ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text("${formatEtb(chosenTicketPrice)} / ticket", color = Muted, fontSize = 11.sp)
            }
            Text("−", color = BrandRed, fontSize = 23.sp, modifier = Modifier.clickable { if (ticketCount > 1) ticketCount-- }.padding(horizontal = 10.dp))
            Text(ticketCount.toString(), color = Ink, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            Text("+", color = BrandRed, fontSize = 23.sp, modifier = Modifier.clickable { if (ticketCount < 10) ticketCount++ }.padding(horizontal = 10.dp))
        }"""
replace_once(main, old_ticket_block, new_ticket_block, "Add selectable Regular VIP VVIP customer ticket options")
replace_once(main, "val ticketSubtotal = event.price * ticketCount.toDouble()", "val ticketSubtotal = chosenTicketPrice * ticketCount.toDouble()", "Calculate selected tier total")
replace_once(main, "                    val ticketTypeId = event.ticketTypeId", "                    val ticketTypeId = chosenTicketTypeId", "Checkout selected ticket tier")
replace_once(main, "                                if (event.price == 0.0) {", "                                if (chosenTicketPrice == 0.0) {", "Use selected tier price for free or paid checkout")

print("Applied instant publishing, simplified organiser form, automatic landscape banner fitting, Regular/VIP/VVIP ticket creation and customer tier selection.")
