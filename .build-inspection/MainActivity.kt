package et.events.mobile

import android.os.Bundle
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import android.graphics.Bitmap
import et.events.mobile.backend.TiqetApi
import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.roundToLong

private val BrandRed = Color(0xFFB82035)
private val BrandIvory = Color(0xFFF7F1E7)
private val Ink = Color(0xFF2B2020)
private val Muted = Color(0xFF8C7771)
private val Hairline = Color(0xFFE6D9CB)
private val SoftIvory = Color(0xFFFFFBF5)

class MainActivity : ComponentActivity() {
    private lateinit var tiqetApi: TiqetApi
    private var authSession by mutableStateOf<TiqetApi.Session?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = android.graphics.Color.rgb(247, 241, 231)
        window.navigationBarColor = android.graphics.Color.rgb(247, 241, 231)
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR

        val preferences = getSharedPreferences("tiqet_preferences", MODE_PRIVATE)
        tiqetApi = TiqetApi(this)
        authSession = tiqetApi.currentSession()
        processAuthIntent(intent)
        setContent {
            EventsTheme {
                var role by remember { mutableStateOf(preferences.getString("role", null)) }
                EventsRoot(
                    role = role,
                    session = authSession,
                    api = tiqetApi,
                    onChooseRole = { selected ->
                        role = selected
                        preferences.edit().putString("role", selected).apply()
                    },
                    onSessionChanged = { authSession = tiqetApi.currentSession() },
                    onSignOut = { tiqetApi.signOut(); authSession = null }
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        processAuthIntent(intent)
    }

    private fun processAuthIntent(intent: Intent?) {
        val callbackUri = intent?.data ?: return
        if (callbackUri.scheme != "tiqet") return
        try {
            authSession = tiqetApi.completeAuthCallback(callbackUri)
            Toast.makeText(this, "Email confirmed. Your Tiqet account is ready.", Toast.LENGTH_LONG).show()
        } catch (error: Exception) {
            Toast.makeText(this, error.message ?: "Tiqet could not complete email confirmation.", Toast.LENGTH_LONG).show()
        }
    }
}

@Composable
private fun EventsTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = BrandRed,
            onPrimary = BrandIvory,
            secondary = BrandRed,
            onSecondary = BrandIvory,
            background = BrandIvory,
            onBackground = Ink,
            surface = SoftIvory,
            onSurface = Ink,
            outline = Hairline
        ),
        content = content
    )
}

@Composable
private fun EventsRoot(
    role: String?,
    session: TiqetApi.Session?,
    api: TiqetApi,
    onChooseRole: (String?) -> Unit,
    onSessionChanged: () -> Unit,
    onSignOut: () -> Unit
) {
    when {
        role == null -> RoleChooser(onChoose = { selected -> onChooseRole(selected) })
        session == null -> TiqetAuthScreen(
            api = api,
            role = role ?: "buyer",
            onAuthenticated = onSessionChanged,
            onBack = { onChooseRole(null) }
        )
        role == "buyer" -> BuyerApp(onSwitchRole = { onChooseRole("organizer") }, api = api, onSignOut = onSignOut)
        else -> TiqetOrganizerScreen(api = api, onSwitchRole = { onChooseRole("buyer") }, onSignOut = onSignOut)
    }
}

@Composable
private fun BrandStamp() {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
        Box(
            modifier = Modifier
                .size(11.dp)
                .clip(CircleShape)
                .background(BrandRed)
        )
        Text(
            text = "TIQET",
            color = BrandRed,
            fontSize = 14.sp,
            fontWeight = FontWeight.ExtraBold,
            letterSpacing = 3.sp
        )
    }
}

@Composable
private fun RoleChooser(onChoose: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BrandIvory)
            .systemBarsPadding()
            .padding(horizontal = 24.dp, vertical = 25.dp)
    ) {
        BrandStamp()
        Spacer(Modifier.weight(1f))
        RoleCard(
            label = "I'm here to discover and book events.",
            isBuyer = true,
            onClick = { onChoose("buyer") }
        )
        Spacer(Modifier.height(13.dp))
        RoleCard(
            label = "I'm here to organise events.",
            isBuyer = false,
            onClick = { onChoose("organizer") }
        )
        Spacer(Modifier.weight(1.15f))
    }
}

@Composable
private fun RoleCard(label: String, isBuyer: Boolean, onClick: () -> Unit) {
    val background = if (isBuyer) BrandRed else BrandIvory
    val foreground = if (isBuyer) BrandIvory else BrandRed
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(133.dp)
            .clip(RoundedCornerShape(22.dp))
            .background(background)
            .then(
                if (isBuyer) Modifier else Modifier.border(1.4.dp, BrandRed, RoundedCornerShape(22.dp))
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 21.dp, vertical = 20.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = label,
                color = foreground,
                fontSize = 17.sp,
                lineHeight = 23.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f).padding(end = 14.dp)
            )
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                TicketMark(color = foreground, modifier = Modifier.size(37.dp))
                Text("↗", color = foreground, fontSize = 19.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

@Composable
private fun TicketMark(color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        val left = size.width * 0.12f
        val top = size.height * 0.21f
        val width = size.width * 0.76f
        val height = size.height * 0.58f
        drawRoundRect(
            color = color,
            topLeft = Offset(left, top),
            size = Size(width, height),
            cornerRadius = CornerRadius(5.dp.toPx()),
            style = Stroke(width = 1.7.dp.toPx())
        )
        drawLine(
            color = color,
            start = Offset(size.width * 0.5f, top + 2.dp.toPx()),
            end = Offset(size.width * 0.5f, top + height - 2.dp.toPx()),
            strokeWidth = 1.4.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))
        )
    }
}

private data class EventCardModel(
    val id: String,
    val title: String,
    val description: String,
    val category: String,
    val date: String,
    val venue: String,
    val price: Double,
    val ticketName: String,
    val tag: String,
    val ticketTypeId: String?
)

private fun formatEtb(amount: Double): String {
    val whole = abs(amount - amount.roundToLong().toDouble()) < 0.005
    val pattern = if (whole) "ETB %,.0f" else "ETB %,.2f"
    return String.format(Locale.US, pattern, amount)
}

private fun formatAddisDate(raw: String): String {
    return try {
        val normalized = raw.replace(Regex("\\.(\\d+)(?=Z|[+-]\\d{2}:?\\d{2}$)"), "")
        val parser = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).apply {
            isLenient = false
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val parsed: Date = parser.parse(normalized) ?: return raw
        val formatter = SimpleDateFormat("EEE, d MMM · h:mm a", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("Africa/Addis_Ababa")
        }
        formatter.format(parsed) + " EAT"
    } catch (_: Exception) {
        raw.replace('T', ' ').take(16)
    }
}

private enum class BuyerTab(val label: String) {
    DISCOVER("Discover"), TICKETS("Tickets"), SAVED("Saved"), PROFILE("Profile")
}

@Composable
private fun BuyerApp(onSwitchRole: () -> Unit, api: TiqetApi, onSignOut: () -> Unit) {
    var liveEvents by remember { mutableStateOf(emptyList<EventCardModel>()) }
    var eventLoadError by remember { mutableStateOf("") }
    var isLoadingEvents by remember { mutableStateOf(true) }
    LaunchedEffect(api) {
        isLoadingEvents = true
        try {
            liveEvents = withContext(Dispatchers.IO) {
                api.fetchPublishedEvents().map { event ->
                    EventCardModel(
                        id = event.id,
                        title = event.title,
                        description = event.description,
                        category = event.category,
                        date = formatAddisDate(event.startsAt),
                        venue = listOf(event.venueName, event.city).filter { it.isNotBlank() }.joinToString(" · "),
                        price = event.minimumPriceEtb ?: 0.0,
                        ticketName = event.ticketTypeName ?: "Admission",
                        tag = "LIVE",
                        ticketTypeId = event.ticketTypeId
                    )
                }
            }
            eventLoadError = ""
        } catch (error: Exception) {
            eventLoadError = error.message ?: "Could not load events."
            liveEvents = emptyList()
        } finally {
            isLoadingEvents = false
        }
    }
    var selectedTab by remember { mutableStateOf(BuyerTab.DISCOVER) }
    var search by remember { mutableStateOf("") }
    var selectedCategory by remember { mutableStateOf("All") }
    var selectedEvent by remember { mutableStateOf<EventCardModel?>(null) }
    var savedIds by remember { mutableStateOf(setOf<String>()) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BrandIvory)
            .systemBarsPadding()
    ) {
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            if (selectedEvent != null) {
                EventDetailScreen(
                    event = selectedEvent!!,
                    isSaved = savedIds.contains(selectedEvent!!.id),
                    api = api,
                    onBack = { selectedEvent = null },
                    onToggleSaved = {
                        val id = selectedEvent!!.id
                        savedIds = if (savedIds.contains(id)) savedIds - id else savedIds + id
                    }
                )
            } else {
                when (selectedTab) {
                    BuyerTab.DISCOVER -> DiscoverScreen(
                        search = search,
                        onSearchChange = { search = it },
                        selectedCategory = selectedCategory,
                        onCategoryChange = { selectedCategory = it },
                        events = liveEvents,
                        isLoading = isLoadingEvents,
                        loadError = eventLoadError,
                        savedIds = savedIds,
                        onOpenEvent = { selectedEvent = it },
                        onToggleSaved = { event ->
                            savedIds = if (savedIds.contains(event.id)) savedIds - event.id else savedIds + event.id
                        }
                    )
                    BuyerTab.TICKETS -> TicketsScreen(api = api)
                    BuyerTab.SAVED -> SavedScreen(
                        savedEvents = liveEvents.filter { savedIds.contains(it.id) },
                        onOpenEvent = { selectedEvent = it },
                        onToggleSaved = { event -> savedIds = savedIds - event.id }
                    )
                    BuyerTab.PROFILE -> AccountScreen(
                        roleLabel = "Ticket buyer",
                        switchLabel = "Switch to organiser",
                        onSwitchRole = onSwitchRole,
                        onSignOut = onSignOut
                    )
                }
            }
        }
        if (selectedEvent == null) {
            BottomBar(
                items = BuyerTab.entries.map { it.label },
                selected = selectedTab.label,
                onSelect = { label -> selectedTab = BuyerTab.entries.first { it.label == label } }
            )
        }
    }
}

@Composable
private fun DiscoverScreen(
    search: String,
    events: List<EventCardModel>,
    isLoading: Boolean,
    loadError: String,
    onSearchChange: (String) -> Unit,
    selectedCategory: String,
    onCategoryChange: (String) -> Unit,
    savedIds: Set<String>,
    onOpenEvent: (EventCardModel) -> Unit,
    onToggleSaved: (EventCardModel) -> Unit
) {
    val categories = listOf("All", "Music", "Comedy", "Culture", "Nightlife")
    val filtered = events.filter { event ->
        (selectedCategory == "All" || event.category == selectedCategory) &&
            (search.isBlank() || event.title.contains(search, ignoreCase = true) || event.category.contains(search, ignoreCase = true))
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BrandIvory)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScrollCompat()
                .padding(horizontal = 21.dp)
        ) {
            Spacer(Modifier.height(19.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                BrandStamp()
                Text(
                    text = "ADDIS ABABA  ·  ETH",
                    color = Muted,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.1.sp
                )
            }
            Spacer(Modifier.height(25.dp))
            Text("Discover", color = Ink, fontSize = 31.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.8).sp)
            Spacer(Modifier.height(14.dp))
            SearchField(value = search, onValueChange = onSearchChange)
            Spacer(Modifier.height(17.dp))
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                categories.forEach { category ->
                    CategoryChip(category, selectedCategory == category) { onCategoryChange(category) }
                }
            }
            Spacer(Modifier.height(22.dp))
            if (events.isNotEmpty()) {
                FeaturedEventCard(event = events.first(), onClick = { onOpenEvent(events.first()) })
                Spacer(Modifier.height(25.dp))
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("Coming up", color = Ink, fontSize = 21.sp, fontWeight = FontWeight.Bold)
                Text(if (isLoading) "UPDATING" else "ETB · LIVE LISTINGS", color = Muted, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
            }
            Spacer(Modifier.height(11.dp))
            if (isLoading) {
                EmptyMessage("Loading live events from Tiqet…")
            } else if (filtered.isEmpty()) {
                EmptyMessage(if (loadError.isNotBlank()) "Events could not be loaded: $loadError" else "No published events are available yet.")
            } else {
                filtered.forEach { event ->
                    EventListItem(
                        event = event,
                        isSaved = savedIds.contains(event.id),
                        onClick = { onOpenEvent(event) },
                        onToggleSaved = { onToggleSaved(event) }
                    )
                    Spacer(Modifier.height(9.dp))
                }
            }
            Spacer(Modifier.height(14.dp))
        }
    }
}

@Composable
private fun Modifier.verticalScrollCompat(): Modifier = this.verticalScroll(rememberScrollState())

@Composable
private fun SearchField(value: String, onValueChange: (String) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(SoftIvory)
            .border(1.dp, Hairline, RoundedCornerShape(14.dp))
            .padding(horizontal = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text("⌕", color = BrandRed, fontSize = 23.sp, fontWeight = FontWeight.Medium)
        Box(modifier = Modifier.weight(1f)) {
            if (value.isEmpty()) {
                Text("Search events or artists", color = Muted, fontSize = 14.sp)
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(color = Ink, fontSize = 14.sp),
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

@Composable
private fun CategoryChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (selected) BrandRed else SoftIvory)
            .border(1.dp, if (selected) BrandRed else Hairline, RoundedCornerShape(50))
            .clickable(onClick = onClick)
            .padding(horizontal = 15.dp, vertical = 9.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            label,
            color = if (selected) BrandIvory else Ink,
            fontSize = 12.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium
        )
    }
}

@Composable
private fun FeaturedEventCard(event: EventCardModel, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(190.dp)
            .clip(RoundedCornerShape(21.dp))
            .background(BrandRed)
            .clickable(onClick = onClick)
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = 1.2.dp.toPx()
            for (i in 0..4) {
                val inset = i * 17.dp.toPx()
                drawCircle(
                    color = BrandIvory.copy(alpha = 0.12f),
                    radius = 63.dp.toPx() + inset,
                    center = Offset(size.width * 0.88f, size.height * 0.53f),
                    style = Stroke(stroke)
                )
            }
            drawLine(
                color = BrandIvory.copy(alpha = 0.16f),
                start = Offset(size.width * 0.58f, 0f),
                end = Offset(size.width * 0.58f, size.height),
                strokeWidth = stroke
            )
        }
        Column(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .padding(start = 20.dp, top = 18.dp, bottom = 18.dp, end = 16.dp)
        ) {
            Text("TIQET SPOTLIGHT", color = BrandIvory.copy(alpha = 0.78f), fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.6.sp)
            Spacer(Modifier.height(12.dp))
            Text(event.title.uppercase(), color = BrandIvory, fontSize = 25.sp, lineHeight = 27.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.7).sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(11.dp))
            Text("${event.category.uppercase()}  ·  ${event.venue.uppercase()}", color = BrandIvory.copy(alpha = 0.85f), fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(16.dp)
                .size(35.dp)
                .clip(CircleShape)
                .background(BrandIvory),
            contentAlignment = Alignment.Center
        ) {
            Text("↗", color = BrandRed, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun EventListItem(
    event: EventCardModel,
    isSaved: Boolean,
    onClick: () -> Unit,
    onToggleSaved: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(15.dp))
            .background(SoftIvory)
            .border(1.dp, Hairline, RoundedCornerShape(15.dp))
            .clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(62.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(BrandRed.copy(alpha = 0.11f)),
            contentAlignment = Alignment.Center
        ) {
            TicketMark(color = BrandRed, modifier = Modifier.size(35.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(event.date, color = BrandRed, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp)
            Spacer(Modifier.height(3.dp))
            Text(event.title, color = Ink, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(3.dp))
            Text(event.venue, color = Muted, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(5.dp))
            Text("From ${formatEtb(event.price)}", color = Ink, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
        Text(
            text = if (isSaved) "♥" else "♡",
            color = BrandRed,
            fontSize = 22.sp,
            modifier = Modifier
                .padding(start = 7.dp)
                .clip(CircleShape)
                .clickable(onClick = onToggleSaved)
                .padding(5.dp)
        )
    }
}

@Composable
private fun EventDetailScreen(
    event: EventCardModel,
    isSaved: Boolean,
    api: TiqetApi,
    onBack: () -> Unit,
    onToggleSaved: () -> Unit
) {
    var ticketCount by remember(event.id) { mutableStateOf(1) }
    var bookingBusy by remember { mutableStateOf(false) }
    var bookingError by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BrandIvory)
            .padding(horizontal = 21.dp)
    ) {
        Spacer(Modifier.height(15.dp))
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text("←", color = BrandRed, fontSize = 25.sp, modifier = Modifier.clickable(onClick = onBack).padding(end = 17.dp))
            Text("EVENT DETAILS", color = Muted, fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.5.sp)
            Spacer(Modifier.weight(1f))
            Text(if (isSaved) "♥" else "♡", color = BrandRed, fontSize = 23.sp, modifier = Modifier.clickable(onClick = onToggleSaved))
        }
        Spacer(Modifier.height(19.dp))
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
        Spacer(Modifier.height(21.dp))
        Text(event.category.uppercase() + "  ·  " + event.tag, color = BrandRed, fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.2.sp)
        Spacer(Modifier.height(6.dp))
        Text(event.title, color = Ink, fontSize = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.6).sp)
        Spacer(Modifier.height(8.dp))
        Text(event.date + "    ·    " + event.venue, color = Muted, fontSize = 12.sp, lineHeight = 18.sp)
        if (event.description.isNotBlank()) {
            Spacer(Modifier.height(12.dp))
            Text(event.description, color = Ink, fontSize = 13.sp, lineHeight = 20.sp)
        }
        Spacer(Modifier.height(26.dp))
        Text("Tickets", color = Ink, fontSize = 18.sp, fontWeight = FontWeight.Bold)
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
        }
        Spacer(Modifier.weight(1f))
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.weight(1f)) {
                val ticketSubtotal = event.price * ticketCount.toDouble()
                val serviceFee = if (ticketSubtotal <= 0.0) 0.0 else minOf(100.0, kotlin.math.floor(ticketSubtotal * 0.05 * 100.0 + 0.5) / 100.0)
                Text("TICKETS ${formatEtb(ticketSubtotal)}", color = Muted, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.5.sp)
                Text("Tiqet service fee (5%; max ETB 100): ${formatEtb(serviceFee)}", color = Muted, fontSize = 9.sp)
                Text(formatEtb(ticketSubtotal + serviceFee), color = Ink, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }
            RedActionButton(
                text = if (bookingBusy) "Loading…" else "Continue",
                onClick = {
                    val ticketTypeId = event.ticketTypeId
                    if (ticketTypeId.isNullOrBlank()) {
                        bookingError = "Tickets are not configured for this event yet."
                    } else {
                        bookingBusy = true
                        bookingError = ""
                        scope.launch {
                            try {
                                if (event.price == 0.0) {
                                    withContext(Dispatchers.IO) { api.claimFreeTickets(ticketTypeId, ticketCount) }
                                    bookingError = "Free tickets issued. Open the Tickets tab to view your QR code."
                                } else {
                                    val checkout = withContext(Dispatchers.IO) { api.createChapaCheckout(ticketTypeId, ticketCount) }
                                    val url = checkout.optString("checkout_url")
                                    if (url.isBlank()) throw IllegalStateException("Payment provider did not return a checkout link.")
                                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                                }
                            } catch (error: Exception) {
                                bookingError = error.message ?: "Unable to start checkout."
                            } finally { bookingBusy = false }
                        }
                    }
                },
                modifier = Modifier.width(150.dp)
            )
        }
        if (bookingError.isNotBlank()) {
            Spacer(Modifier.height(9.dp))
            Text(bookingError, color = BrandRed, fontSize = 11.sp, lineHeight = 15.sp)
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun TicketsScreen(api: TiqetApi) {
    var tickets by remember { mutableStateOf(emptyList<TiqetApi.Ticket>()) }
    var loading by remember { mutableStateOf(true) }
    var problem by remember { mutableStateOf("") }
    LaunchedEffect(api) {
        try {
            tickets = withContext(Dispatchers.IO) { api.fetchMyTickets() }
        } catch (error: Exception) {
            problem = error.message ?: "Unable to load tickets."
        } finally { loading = false }
    }
    Column(modifier = Modifier.fillMaxSize().background(BrandIvory).verticalScrollCompat().padding(horizontal = 21.dp)) {
        Spacer(Modifier.height(22.dp))
        BrandStamp()
        Spacer(Modifier.height(22.dp))
        Text("Your tickets", color = Ink, fontSize = 29.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(13.dp))
        when {
            loading -> EmptyMessage("Loading your issued tickets…")
            problem.isNotBlank() -> EmptyMessage(problem)
            tickets.isEmpty() -> EmptyMessage("Tickets will appear here after the payment provider confirms your purchase.")
            else -> tickets.forEach { ticket ->
                Column(
                    modifier = Modifier.fillMaxWidth().padding(bottom = 13.dp).clip(RoundedCornerShape(18.dp))
                        .background(SoftIvory).border(1.dp, Hairline, RoundedCornerShape(18.dp)).padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(ticket.eventTitle, color = Ink, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(7.dp))
                    Text(ticket.status.uppercase().replace('_', ' '), color = BrandRed, fontSize = 9.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 1.2.sp)
                    Spacer(Modifier.height(12.dp))
                    TicketQr(ticket.token)
                    Spacer(Modifier.height(9.dp))
                    Text("Show this QR code at the entrance.", color = Muted, fontSize = 11.sp)
                }
            }
        }
    }
}

@Composable
private fun TicketQr(token: String) {
    val bitmap = remember(token) {
        try {
            val matrix = QRCodeWriter().encode(token, BarcodeFormat.QR_CODE, 420, 420)
            Bitmap.createBitmap(420, 420, Bitmap.Config.ARGB_8888).also { image ->
                for (x in 0 until 420) for (y in 0 until 420) {
                    image.setPixel(x, y, if (matrix[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
                }
            }
        } catch (_: Exception) { null }
    }
    if (bitmap != null) {
        Image(bitmap.asImageBitmap(), contentDescription = "Ticket QR code", modifier = Modifier.size(210.dp))
    } else {
        Text("QR code unavailable", color = BrandRed, fontSize = 11.sp)
    }
}

@Composable
private fun SavedScreen(
    savedEvents: List<EventCardModel>,
    onOpenEvent: (EventCardModel) -> Unit,
    onToggleSaved: (EventCardModel) -> Unit
) {
    Column(modifier = Modifier.fillMaxSize().background(BrandIvory).padding(horizontal = 21.dp)) {
        Spacer(Modifier.height(22.dp))
        BrandStamp()
        Spacer(Modifier.height(22.dp))
        Text("Saved", color = Ink, fontSize = 30.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(15.dp))
        if (savedEvents.isEmpty()) {
            EmptyMessage("Events you save will appear here.")
        } else {
            savedEvents.forEach { event ->
                EventListItem(event, true, { onOpenEvent(event) }, { onToggleSaved(event) })
                Spacer(Modifier.height(9.dp))
            }
        }
    }
}

@Composable
private fun EmptyScreen(title: String, message: String, mark: String) {
    Column(
        modifier = Modifier.fillMaxSize().background(BrandIvory).padding(horizontal = 22.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier.size(76.dp).clip(RoundedCornerShape(22.dp)).background(BrandRed.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center
        ) {
            Text(mark, color = BrandRed, fontSize = 33.sp)
        }
        Spacer(Modifier.height(19.dp))
        Text(title, color = Ink, fontSize = 23.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(7.dp))
        Text(message, color = Muted, fontSize = 13.sp)
    }
}

@Composable
private fun EmptyMessage(message: String) {
    Box(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(SoftIvory).border(1.dp, Hairline, RoundedCornerShape(14.dp)).padding(19.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(message, color = Muted, fontSize = 12.sp)
    }
}

@Composable
private fun AccountScreen(roleLabel: String, switchLabel: String, onSwitchRole: () -> Unit, onSignOut: () -> Unit = {}) {
    Column(modifier = Modifier.fillMaxSize().background(BrandIvory).padding(horizontal = 21.dp)) {
        Spacer(Modifier.height(22.dp))
        BrandStamp()
        Spacer(Modifier.height(24.dp))
        Text("Account", color = Ink, fontSize = 30.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Text(roleLabel, color = Muted, fontSize = 13.sp)
        Spacer(Modifier.height(25.dp))
        Row(
            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp)).background(SoftIvory).border(1.dp, Hairline, RoundedCornerShape(15.dp)).clickable(onClick = onSwitchRole).padding(17.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(switchLabel, color = Ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text("↗", color = BrandRed, fontSize = 20.sp)
        }
        Spacer(Modifier.height(17.dp))
        Spacer(Modifier.height(8.dp))
        Box(modifier = Modifier.fillMaxWidth().height(48.dp).clip(RoundedCornerShape(12.dp)).border(1.dp, Hairline, RoundedCornerShape(12.dp)).clickable(onClick = onSignOut), contentAlignment = Alignment.Center) {
            Text("Sign out", color = BrandRed, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun RedActionButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(50.dp)
            .clip(RoundedCornerShape(13.dp))
            .background(BrandRed)
            .clickable(onClick = onClick)
            .padding(horizontal = 17.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(text, color = BrandIvory, fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun BottomBar(items: List<String>, selected: String, onSelect: (String) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(BrandIvory)
            .border(BorderStroke(0.7.dp, Hairline))
            .padding(horizontal = 5.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically
    ) {
        items.forEach { item ->
            Column(
                modifier = Modifier.weight(1f).clip(RoundedCornerShape(12.dp)).clickable { onSelect(item) }.padding(vertical = 7.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Box(modifier = Modifier.width(22.dp).height(3.dp).clip(RoundedCornerShape(50)).background(if (item == selected) BrandRed else Color.Transparent))
                Text(
                    item,
                    color = if (item == selected) BrandRed else Muted,
                    fontSize = 9.sp,
                    fontWeight = if (item == selected) FontWeight.Bold else FontWeight.Medium,
                    maxLines = 1
                )
            }
        }
    }
}
