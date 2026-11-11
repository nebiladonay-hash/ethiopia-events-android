#!/usr/bin/env python3
"""Apply the Tiqet Spotlight + organizer-owned banner UI to the prepared V7.2 source."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
main = root / "app/src/main/java/et/events/mobile/MainActivity.kt"
api = root / "app/src/main/java/et/events/mobile/backend/TiqetApi.kt"
organizer = root / "app/src/main/java/et/events/mobile/TiqetOrganizerScreen.kt"
gradle = root / "app/build.gradle.kts"

def replace_once(path: Path, old: str, new: str, label: str) -> None:
    source = path.read_text()
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source anchor; found {count}")
    path.write_text(source.replace(old, new, 1))

# Main app: organizer images, Spotlight rail, Boxing Matches and minimalist tab icons.
replace_once(main,
    "import androidx.compose.foundation.BorderStroke\n",
    "import androidx.compose.foundation.BorderStroke\n"
    "import androidx.compose.material3.Icon\n"
    "import androidx.compose.material.icons.Icons\n"
    "import androidx.compose.material.icons.outlined.BookmarkBorder\n"
    "import androidx.compose.material.icons.outlined.ConfirmationNumber\n"
    "import androidx.compose.material.icons.outlined.Explore\n"
    "import androidx.compose.material.icons.outlined.PersonOutline\n"
    "import androidx.compose.ui.layout.ContentScale\n"
    "import coil.compose.AsyncImage\n",
    "Compose image and navigation imports"
)
replace_once(main,
    "    val tag: String,\n    val ticketTypeId: String?\n)",
    "    val tag: String,\n    val ticketTypeId: String?,\n"
    "    val imageUrl: String? = null,\n    val featuredLabel: String = \"\"\n)",
    "EventCardModel image metadata"
)
replace_once(main,
    "    var liveEvents by remember { mutableStateOf(emptyList<EventCardModel>()) }\n",
    "    var liveEvents by remember { mutableStateOf(emptyList<EventCardModel>()) }\n"
    "    var spotlightEvents by remember { mutableStateOf(emptyList<EventCardModel>()) }\n",
    "Spotlight state"
)
replace_once(main,
    "                        tag = \"LIVE\",\n                        ticketTypeId = event.ticketTypeId\n",
    "                        tag = \"LIVE\",\n                        ticketTypeId = event.ticketTypeId,\n"
    "                        imageUrl = event.imageUrl\n",
    "Published event image mapping"
)
replace_once(main,
    "            eventLoadError = \"\"\n",
    """            spotlightEvents = try {
                withContext(Dispatchers.IO) {
                    api.fetchSpotlightEvents().map { featured ->
                        val event = featured.event
                        EventCardModel(
                            id = event.id, title = event.title, description = event.description,
                            category = event.category, date = formatAddisDate(event.startsAt),
                            venue = listOf(event.venueName, event.city).filter { it.isNotBlank() }.joinToString(" · "),
                            price = event.minimumPriceEtb ?: 0.0, ticketName = event.ticketTypeName ?: "Admission",
                            tag = "SPOTLIGHT", ticketTypeId = event.ticketTypeId,
                            imageUrl = event.imageUrl, featuredLabel = featured.featuredLabel
                        )
                    }
                }
            } catch (_: Exception) { emptyList() }
            eventLoadError = ""
""",
    "Load curated Spotlight events"
)
replace_once(main,
    "                        events = liveEvents,\n                        isLoading = isLoadingEvents,",
    "                        events = liveEvents,\n                        spotlightEvents = spotlightEvents,\n                        isLoading = isLoadingEvents,",
    "Pass Spotlight events to Discover"
)
replace_once(main,
    "    events: List<EventCardModel>,\n    isLoading: Boolean,",
    "    events: List<EventCardModel>,\n    spotlightEvents: List<EventCardModel>,\n    isLoading: Boolean,",
    "Discover Spotlight parameter"
)
replace_once(main,
    '    val categories = listOf("All", "Music", "Comedy", "Culture", "Nightlife")',
    '    val categories = listOf("All", "Music", "Boxing Matches", "Culture", "Nightlife")',
    "Replace Comedy with Boxing Matches"
)
replace_once(main,
    """                if (events.isNotEmpty()) {
                    FeaturedEventCard(event = events.first(), onClick = { onOpenEvent(events.first()) })
                    Spacer(Modifier.height(23.dp))
                }""",
    """                if (spotlightEvents.isNotEmpty()) {
                    SpotlightSection(events = spotlightEvents, onOpenEvent = onOpenEvent)
                    Spacer(Modifier.height(23.dp))
                }""",
    "Use curated Spotlight instead of first-event promotion"
)
spotlight_ui = """
@Composable
private fun SpotlightSection(events: List<EventCardModel>, onOpenEvent: (EventCardModel) -> Unit) {
    Column {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Column {
                Text("Tiqet Spotlight", color = Ink, fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
                Text("Selected events worth going out for", color = Muted, fontSize = 10.sp)
            }
            Text("CURATED", color = BrandRed, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
        }
        Spacer(Modifier.height(12.dp))
        Row(modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            events.forEach { event -> SpotlightBannerCard(event = event, onClick = { onOpenEvent(event) }) }
        }
    }
}

@Composable
private fun SpotlightBannerCard(event: EventCardModel, onClick: () -> Unit) {
    Box(
        modifier = Modifier.width(292.dp).height(190.dp).clip(RoundedCornerShape(18.dp))
            .background(Color(0xFF5B172C)).clickable(onClick = onClick)
    ) {
        if (!event.imageUrl.isNullOrBlank()) {
            AsyncImage(
                model = event.imageUrl,
                contentDescription = "Organizer banner for ${event.title}",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop
            )
        }
        Box(Modifier.fillMaxSize().background(Color(0x880D080B)))
        Column(modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(17.dp)) {
            Text(event.featuredLabel.uppercase(), color = Color.White.copy(alpha = 0.85f), fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.2.sp)
            Spacer(Modifier.height(5.dp))
            Text(event.title, color = Color.White, fontSize = 20.sp, lineHeight = 24.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(6.dp))
            Text(listOf(event.date, event.venue).filter { it.isNotBlank() }.joinToString(" · "), color = Color.White.copy(alpha = 0.9f), fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box(Modifier.align(Alignment.TopEnd).padding(12.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.93f)).padding(horizontal = 10.dp, vertical = 6.dp)) {
            Text("VERIFIED EVENT", color = BrandRed, fontSize = 8.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.6.sp)
        }
    }
}
"""
replace_once(main,
    "@Composable\nprivate fun FeaturedEventCard(event: EventCardModel, onClick: () -> Unit) {",
    spotlight_ui + "\n@Composable\nprivate fun FeaturedEventCard(event: EventCardModel, onClick: () -> Unit) {",
    "Insert Spotlight banner components"
)
replace_once(main,
    """    ) {
        Column(modifier = Modifier.weight(1f).padding(end = 10.dp)) {
            Text(event.category.uppercase(), color = BrandRed, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp)""",
    """    ) {
        if (!event.imageUrl.isNullOrBlank()) {
            AsyncImage(
                model = event.imageUrl,
                contentDescription = "Organizer banner for ${event.title}",
                modifier = Modifier.size(width = 82.dp, height = 92.dp).clip(RoundedCornerShape(10.dp)),
                contentScale = ContentScale.Crop
            )
            Spacer(Modifier.width(11.dp))
        }
        Column(modifier = Modifier.weight(1f).padding(end = 10.dp)) {
            Text(event.category.uppercase(), color = BrandRed, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp)""",
    "Organizer banner thumbnails"
)
old_nav = """            Column(
                modifier = Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).clickable { onSelect(item) }.padding(vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Box(modifier = Modifier.width(22.dp).height(3.dp).clip(RoundedCornerShape(50)).background(if (item == selected) BrandRed else Color.Transparent))
                Text(
                    item,
                    color = if (item == selected) BrandRed else Muted,
                    fontSize = 10.sp,
                    fontWeight = if (item == selected) FontWeight.Bold else FontWeight.Medium,
                    maxLines = 1
                )
            }"""
new_nav = """            Column(
                modifier = Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).clickable { onSelect(item) }.padding(vertical = 5.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(3.dp)
            ) {
                val tint = if (item == selected) BrandRed else Muted
                when (item) {
                    "Discover" -> Icon(Icons.Outlined.Explore, contentDescription = "Discover", tint = tint, modifier = Modifier.size(21.dp))
                    "Tickets" -> Icon(Icons.Outlined.ConfirmationNumber, contentDescription = "Tickets", tint = tint, modifier = Modifier.size(21.dp))
                    "Saved" -> Icon(Icons.Outlined.BookmarkBorder, contentDescription = "Saved", tint = tint, modifier = Modifier.size(21.dp))
                    "Profile" -> Icon(Icons.Outlined.PersonOutline, contentDescription = "Profile", tint = tint, modifier = Modifier.size(21.dp))
                }
                Text(item, color = tint, fontSize = 10.sp, fontWeight = if (item == selected) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1)
                Box(modifier = Modifier.width(18.dp).height(2.dp).clip(RoundedCornerShape(50)).background(if (item == selected) BrandRed else Color.Transparent))
            }"""
replace_once(main, old_nav, new_nav, "Minimal four-tab icon navigation")

# TiqetApi: Spotlight reader and organizer-only storage upload + event image assignment.
replace_once(api,
    """    data class Ticket(
""",
    """    data class SpotlightEvent(val event: Event, val featuredLabel: String)

    data class Ticket(
""",
    "Spotlight API model"
)
spotlight_method = """
    fun fetchSpotlightEvents(limit: Int = 8): List<SpotlightEvent> {
        requireConfigured()
        val result = request(
            "POST", "/rest/v1/rpc/get_tiqet_spotlight_events",
            JSONObject().put("p_limit", limit.coerceIn(1, 20)),
            useSession = currentSession() != null
        )
        val rows = result.optJSONArray("events") ?: JSONArray()
        return (0 until rows.length()).mapNotNull { index ->
            val row = rows.optJSONObject(index) ?: return@mapNotNull null
            val ticketTypes = row.optJSONArray("ticket_types") ?: JSONArray()
            val cheapest = (0 until ticketTypes.length()).mapNotNull { ticketTypes.optJSONObject(it) }
                .minByOrNull { it.optDouble("price_etb", Double.MAX_VALUE) }
            SpotlightEvent(
                event = Event(
                    id = row.optString("id"), title = row.optString("title"),
                    description = row.optString("description"), category = row.optString("category"),
                    startsAt = row.optString("starts_at"), venueName = row.optString("venue_name"),
                    address = row.optString("address"), city = row.optString("city"),
                    imageUrl = row.optString("image_url").takeIf { it.isNotBlank() && it != "null" },
                    minimumPriceEtb = cheapest?.optDouble("price_etb"),
                    ticketTypeId = cheapest?.optString("id")?.takeIf { !it.isNullOrBlank() && it != "null" },
                    ticketTypeName = cheapest?.optString("name")?.takeIf { !it.isNullOrBlank() && it != "null" }
                ),
                featuredLabel = row.optString("featured_label", "Tiqet Spotlight")
            )
        }
    }

"""
replace_once(api, "    fun fetchMyOrganisations(): JSONArray {", spotlight_method + "    fun fetchMyOrganisations(): JSONArray {", "Spotlight API method")

banner_method = """
    /** Upload organizer-owned artwork; the database RPC verifies ownership before assigning it to the event. */
    fun uploadEventBanner(organisationId: String, eventId: String, uri: Uri): String {
        requireSignedIn()
        val resolver = appContext.contentResolver
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
        val base = BuildConfig.SUPABASE_URL.trimEnd('/')
        val connection = (URL("$base/storage/v1/object/tiqet-event-banners/$objectPath").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 20_000
            readTimeout = 30_000
            doOutput = true
            setRequestProperty("apikey", BuildConfig.SUPABASE_ANON_KEY)
            setRequestProperty("Authorization", "Bearer " + currentSession()!!.accessToken)
            setRequestProperty("Content-Type", mime)
            setRequestProperty("x-upsert", "false")
        }
        try {
            connection.outputStream.use { it.write(bytes) }
            val code = connection.responseCode
            if (code !in 200..299) {
                val errorText = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                throw ApiException("Banner upload failed ($code). ${errorText.take(180)}", code)
            }
        } finally { connection.disconnect() }

        val publicUrl = "$base/storage/v1/object/public/tiqet-event-banners/$objectPath"
        try {
            request("POST", "/rest/v1/rpc/set_organiser_event_banner",
                JSONObject().put("p_event_id", eventId).put("p_image_url", publicUrl), true)
        } catch (error: Exception) {
            try {
                val delete = (URL("$base/storage/v1/object/tiqet-event-banners/$objectPath").openConnection() as HttpURLConnection).apply {
                    requestMethod = "DELETE"
                    connectTimeout = 10_000
                    readTimeout = 10_000
                    setRequestProperty("apikey", BuildConfig.SUPABASE_ANON_KEY)
                    setRequestProperty("Authorization", "Bearer " + currentSession()!!.accessToken)
                }
                delete.responseCode
                delete.disconnect()
            } catch (_: Exception) { }
            throw error
        }
        return publicUrl
    }

"""
replace_once(api, "    fun fetchMyOrganiserEvents(): JSONArray {", banner_method + "    fun fetchMyOrganiserEvents(): JSONArray {", "Organizer banner upload API")
replace_once(api,
    "/rest/v1/events?select=id,title,status,approval_status,starts_at,venue_name,city&order=created_at.desc",
    "/rest/v1/events?select=id,organisation_id,title,status,approval_status,starts_at,venue_name,city,image_url&order=created_at.desc",
    "Organizer event image field"
)

# Organizer workspace: banner picker and owner-only update action.
replace_once(organizer,
    '            OrgField("Category", eventCategory, { eventCategory = it })\\n',
    '''            OrgField("Category", eventCategory, { eventCategory = it })
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                listOf("Music", "Boxing Matches", "Culture", "Nightlife", "Sports", "Conference").forEach { category ->
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
''',
    "Organizer category quick-picks including Boxing Matches"
)


replace_once(organizer,
    "import androidx.activity.compose.rememberLauncherForActivityResult\n",
    "import androidx.activity.compose.rememberLauncherForActivityResult\nimport androidx.activity.result.contract.ActivityResultContracts\n",
    "Organizer file picker import"
)
replace_once(organizer,
    "import androidx.compose.ui.graphics.Color\n",
    "import androidx.compose.ui.graphics.Color\nimport androidx.compose.ui.layout.ContentScale\nimport coil.compose.AsyncImage\n",
    "Organizer artwork preview imports"
)
replace_once(organizer,
    "    var selectedScanEventId by remember { mutableStateOf<String?>(null) }\n",
    "    var selectedScanEventId by remember { mutableStateOf<String?>(null) }\n    var selectedBannerEventId by remember { mutableStateOf<String?>(null) }\n",
    "Selected banner event state"
)
banner_picker = """
    val bannerPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        val eventId = selectedBannerEventId
        val currentOrganisation = organisations.optJSONObject(0)
        val organisationId = currentOrganisation?.takeIf { it.optString("status") == "verified" }?.optString("id")
        if (uri != null && !eventId.isNullOrBlank() && !organisationId.isNullOrBlank()) {
            scope.launch {
                working = true
                error = ""
                notice = "Uploading your event artwork…"
                try {
                    withContext(Dispatchers.IO) { api.uploadEventBanner(organisationId, eventId, uri) }
                    notice = "Your banner has been uploaded and attached to your event. Spotlight never replaces organizer artwork."
                    refresh()
                } catch (exception: Exception) {
                    error = exception.message ?: "Your event banner could not be uploaded."
                    notice = ""
                } finally {
                    working = false
                    selectedBannerEventId = null
                }
            }
        } else {
            selectedBannerEventId = null
        }
    }
"""
replace_once(organizer,
    "    val qrScanner = rememberLauncherForActivityResult(ScanContract()) { scanResult ->",
    banner_picker + "    val qrScanner = rememberLauncherForActivityResult(ScanContract()) { scanResult ->",
    "Organizer banner picker"
)
old_event = """                Column(modifier = Modifier.fillMaxWidth().padding(vertical = 9.dp)) {
                    Text(event.optString("title"), color = OrgInk, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text("${event.optString("status").uppercase()} · ${event.optString("approval_status").uppercase()}", color = OrgRed, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                    if (event.optString("status") == "published" && event.optString("approval_status") == "approved") {"""
new_event = """                Column(modifier = Modifier.fillMaxWidth().padding(vertical = 9.dp)) {
                    Text(event.optString("title"), color = OrgInk, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text("${event.optString("status").uppercase()} · ${event.optString("approval_status").uppercase()}", color = OrgRed, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                    val existingBanner = event.optString("image_url")
                    if (existingBanner.isNotBlank() && existingBanner != "null") {
                        Spacer(Modifier.height(7.dp))
                        AsyncImage(
                            model = existingBanner,
                            contentDescription = "Your uploaded banner for ${event.optString("title")}",
                            modifier = Modifier.fillMaxWidth().height(112.dp).clip(RoundedCornerShape(12.dp)),
                            contentScale = ContentScale.Crop
                        )
                    }
                    Spacer(Modifier.height(7.dp))
                    Button(
                        onClick = {
                            selectedBannerEventId = event.optString("id")
                            bannerPicker.launch("image/*")
                        },
                        enabled = !working && !verifiedOrganisationId.isNullOrBlank(),
                        colors = ButtonDefaults.buttonColors(containerColor = OrgRed)
                    ) { Text(if (existingBanner.isNotBlank() && existingBanner != "null") "Update my banner" else "Upload my event banner") }
                    Text("Only your organization can upload or replace this artwork. JPEG, PNG or WebP · up to 8 MB.", color = OrgMuted, fontSize = 10.sp, lineHeight = 14.sp)
                    if (event.optString("status") == "published" && event.optString("approval_status") == "approved") {"""
replace_once(organizer, old_event, new_event, "Organizer-owned banner upload button")
replace_once(gradle,
    '    implementation("androidx.compose.material3:material3")\n',
    '    implementation("androidx.compose.material3:material3")\n    implementation("androidx.compose.material:material-icons-extended")\n    implementation("io.coil-kt:coil-compose:2.7.0")\n',
    "Coil and icon dependencies"
)

print("Applied: Spotlight read API, owner-only banner upload UI/API, Boxing Matches, image cards and minimalist bottom navigation.")
