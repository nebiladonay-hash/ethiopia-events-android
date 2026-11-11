package et.tiqet.control

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import et.tiqet.control.data.ApiException
import et.tiqet.control.data.ControlSession
import et.tiqet.control.data.SupabaseApi
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

private val Ink = Color(0xFF152C2A)
private val Muted = Color(0xFF75837E)
private val Canvas = Color(0xFFF4F6F3)
private val CardWhite = Color(0xFFFFFFFF)
private val Accent = Color(0xFFE36B4F)
private val AccentPale = Color(0xFFFFEEE8)
private val Teal = Color(0xFF347D71)
private val TealPale = Color(0xFFE4F1ED)
private val Border = Color(0xFFE3E9E4)
private val Danger = Color(0xFFB64646)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            TiqetControlTheme {
                TiqetControlApp(SupabaseApi())
            }
        }
    }
}

@Composable
private fun TiqetControlTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = Ink,
            onPrimary = Color.White,
            secondary = Teal,
            onSecondary = Color.White,
            tertiary = Accent,
            background = Canvas,
            surface = CardWhite,
            onSurface = Ink,
            onBackground = Ink,
            outline = Border,
            error = Danger
        ),
        content = content
    )
}

@Composable
private fun TiqetControlApp(api: SupabaseApi) {
    var session by remember { mutableStateOf<ControlSession?>(null) }
    if (session == null) {
        LoginScreen(api = api, onSignedIn = { session = it })
    } else {
        ControlWorkspace(
            api = api,
            session = session!!,
            onSignOut = { session = null }
        )
    }
}

@Composable
private fun LoginScreen(
    api: SupabaseApi,
    onSignedIn: (ControlSession) -> Unit
) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Canvas)
            .systemBarsPadding()
            .imePadding()
            .padding(22.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 460.dp)
                .clip(RoundedCornerShape(28.dp))
                .background(CardWhite)
                .padding(24.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(Ink),
                    contentAlignment = Alignment.Center
                ) {
                    Text("T", color = Color.White, fontWeight = FontWeight.Black, fontSize = 23.sp)
                }
                Spacer(Modifier.width(12.dp))
                Column {
                    Text("TIQET", color = Ink, fontSize = 18.sp, fontWeight = FontWeight.Black, letterSpacing = 2.sp)
                    Text("CONTROL", color = Teal, fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 2.2.sp)
                }
            }
            Spacer(Modifier.height(34.dp))
            Text("Platform operations", color = Ink, fontSize = 26.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(7.dp))
            Text(
                "Sign in with an account that has been granted Tiqet staff access.",
                color = Muted, fontSize = 13.sp, lineHeight = 19.sp
            )
            Spacer(Modifier.height(25.dp))
            OutlinedTextField(
                value = email,
                onValueChange = { email = it; error = null },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Email address") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                shape = RoundedCornerShape(14.dp)
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = password,
                onValueChange = { password = it; error = null },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Password") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                shape = RoundedCornerShape(14.dp)
            )
            if (error != null) {
                Spacer(Modifier.height(12.dp))
                Text(error!!, color = Danger, fontSize = 12.sp, lineHeight = 17.sp)
            }
            Spacer(Modifier.height(20.dp))
            Button(
                onClick = {
                    if (!api.isConfigured) {
                        error = "Supabase configuration is missing from this build."
                    } else if (email.isBlank() || password.isBlank()) {
                        error = "Enter your email and password."
                    } else {
                        busy = true
                        error = null
                        scope.launch {
                            try {
                                val newSession = api.signIn(email, password)
                                // This endpoint is protected by server-side staff-role checks.
                                api.getOverview(newSession)
                                onSignedIn(newSession)
                            } catch (e: Exception) {
                                error = e.message ?: "Sign-in failed."
                            } finally {
                                busy = false
                            }
                        }
                    }
                },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                shape = RoundedCornerShape(15.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Ink)
            ) {
                if (busy) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(19.dp))
                    Spacer(Modifier.width(10.dp))
                    Text("Checking access…")
                } else {
                    Text("Sign in to Control", fontWeight = FontWeight.SemiBold)
                }
            }
            Spacer(Modifier.height(14.dp))
            Text(
                "Access is granted by the Tiqet super administrator. Customer accounts cannot enter this workspace.",
                color = Muted, fontSize = 11.sp, lineHeight = 16.sp
            )
        }
    }
}

private enum class ControlTab(val label: String) {
    OVERVIEW("Overview"),
    ORGANISERS("Organisers"),
    EVENTS("Events"),
    TEAM("Team"),
    ACTIVITY("Activity"),
    FINANCE("Finance"),
    USERS("Users")
}

@Composable
private fun ControlWorkspace(
    api: SupabaseApi,
    session: ControlSession,
    onSignOut: () -> Unit
) {
    var overview by remember { mutableStateOf(JSONObject()) }
    var organisers by remember { mutableStateOf(JSONArray()) }
    var verifiedOrganisers by remember { mutableStateOf(JSONArray()) }
    var events by remember { mutableStateOf(JSONArray()) }
    var publishedEvents by remember { mutableStateOf(JSONArray()) }
    var spotlightEvents by remember { mutableStateOf(JSONArray()) }
    var staff by remember { mutableStateOf(JSONArray()) }
    var audit by remember { mutableStateOf(JSONArray()) }
    var finance by remember { mutableStateOf(JSONObject()) }
    var refundsDashboard by remember { mutableStateOf(JSONObject()) }
    var payoutDestinations by remember { mutableStateOf(JSONArray()) }
    var selectedTab by remember { mutableStateOf(ControlTab.OVERVIEW) }
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    val isAdmin = overview.optBoolean("admin_access")
    val isSuperAdmin = overview.optBoolean("super_admin_access")

    fun refresh() {
        scope.launch {
            busy = true
            error = null
            try {
                overview = api.getOverview(session)
                events = api.getPendingEvents(session)
                if (overview.optBoolean("admin_access")) {
                    publishedEvents = api.getPublishedEventsForReview(session)
                    spotlightEvents = try { api.getSpotlightEvents(session) } catch (_: Exception) { JSONArray() }
                    organisers = api.getOrganisers(session)
                    verifiedOrganisers = api.getVerifiedOrganisers(session)
                    audit = api.getAuditLog(session)
                    finance = api.getFinanceDashboard(session)
                    refundsDashboard = api.getRefundsDashboard(session)
                }
                if (overview.optBoolean("super_admin_access")) {
                    staff = api.getStaffDirectory(session)
                }
            } catch (e: Exception) {
                error = e.message ?: "Unable to load Control data."
            } finally {
                busy = false
            }
        }
    }

    LaunchedEffect(session.accessToken) { refresh() }

    val visibleTabs = buildList {
        add(ControlTab.OVERVIEW)
        if (isAdmin) add(ControlTab.ORGANISERS)
        add(ControlTab.EVENTS)
        if (isSuperAdmin) add(ControlTab.TEAM)
        if (isAdmin) add(ControlTab.ACTIVITY)
        if (isAdmin) add(ControlTab.FINANCE)
        if (isAdmin) add(ControlTab.USERS)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Canvas)
            .systemBarsPadding()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 18.dp, end = 14.dp, top = 12.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("TIQET", color = Ink, fontSize = 16.sp, fontWeight = FontWeight.Black, letterSpacing = 1.8.sp)
                    Spacer(Modifier.width(8.dp))
                    Box(Modifier.clip(RoundedCornerShape(6.dp)).background(TealPale).padding(horizontal = 7.dp, vertical = 3.dp)) {
                        Text("CONTROL", color = Teal, fontSize = 9.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 1.1.sp)
                    }
                }
                Text(
                    if (isSuperAdmin) "Super administrator" else if (isAdmin) "Administrator" else "Moderator workspace",
                    color = Muted, fontSize = 11.sp
                )
            }
            TextButton(onClick = onSignOut) { Text("Sign out", color = Muted, fontSize = 12.sp) }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(CardWhite)
                .padding(5.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            visibleTabs.forEach { tab ->
                val active = selectedTab == tab
                TextButton(
                    onClick = { selectedTab = tab },
                    modifier = Modifier.weight(1f),
                    contentPadding = PaddingValues(horizontal = 6.dp, vertical = 9.dp),
                    colors = ButtonDefaults.textButtonColors(
                        containerColor = if (active) Ink else Color.Transparent,
                        contentColor = if (active) Color.White else Muted
                    ),
                    shape = RoundedCornerShape(11.dp)
                ) {
                    Text(tab.label, fontSize = 10.sp, fontWeight = if (active) FontWeight.Bold else FontWeight.Medium, maxLines = 1)
                }
            }
        }

        if (error != null) {
            MessageStrip(error!!, isError = true, onDismiss = { error = null })
        } else if (notice != null) {
            MessageStrip(notice!!, isError = false, onDismiss = { notice = null })
        }

        AnimatedContent(
            targetState = selectedTab,
            modifier = Modifier.weight(1f),
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            label = "control-tab"
        ) { tab ->
            when (tab) {
                ControlTab.OVERVIEW -> OverviewScreen(
                    overview = overview,
                    isAdmin = isAdmin,
                    isSuperAdmin = isSuperAdmin,
                    isBusy = busy,
                    onRefresh = { refresh() },
                    onOpenTab = { selectedTab = it }
                )
                ControlTab.ORGANISERS -> OrganiserQueueScreen(
                    items = organisers,
                    verifiedItems = verifiedOrganisers,
                    busy = busy,
                    onReview = { id, decision, notes ->
                        scope.launch {
                            busy = true
                            try {
                                api.reviewOrganiser(session, id, decision, notes)
                                notice = when (decision) {
                                    "approve" -> "Organiser approved. You can now choose whether to trust them for automatic publishing."
                                    "reject" -> "Organiser application rejected."
                                    else -> "Information request recorded."
                                }
                                refresh()
                            } catch (e: Exception) { error = e.message ?: "Could not review organiser." }
                            finally { busy = false }
                        }
                    },
                    onAutoPublish = { id, enabled, reason ->
                        scope.launch {
                            busy = true
                            try {
                                api.setOrganiserAutoPublish(session,id,enabled,reason)
                                notice = if(enabled) "Trusted organiser auto-publishing enabled." else "Automatic publishing disabled; future events return to review."
                                refresh()
                            } catch (e: Exception) { error = e.message ?: "Could not update organiser publishing policy." }
                            finally { busy = false }
                        }
                    }
                )
                ControlTab.EVENTS -> EventQueueScreen(
                    items = events,
                    publishedItems = publishedEvents,
                    spotlightItems = spotlightEvents,
                    busy = busy,
                    onReview = { id, decision, notes ->
                        scope.launch {
                            busy = true
                            try {
                                api.reviewEvent(session, id, decision, notes)
                                notice = if (decision == "approve") "Event approved and published." else "Event returned to the organiser for changes."
                                refresh()
                            } catch (e: Exception) { error = e.message ?: "Could not review event." }
                            finally { busy = false }
                        }
                    },
                    onFlagPublished = { id, reason ->
                        scope.launch {
                            busy = true
                            try {
                                api.flagPublishedEvent(session,id,reason)
                                notice = "Published event removed from public listings and sent to moderator review."
                                refresh()
                            } catch (e: Exception) { error = e.message ?: "Could not flag event." }
                            finally { busy = false }
                        }
                    },
                    onSetSpotlight = { id, featured ->
                        scope.launch {
                            busy = true
                            try {
                                api.setEventSpotlight(session, id, featured)
                                notice = if (featured) "Event added to Tiqet Spotlight. Its organizer-owned banner remains unchanged."
                                    else "Event removed from Tiqet Spotlight. Its organizer-owned banner remains unchanged."
                                refresh()
                            } catch (e: Exception) {
                                error = e.message ?: "Could not update Tiqet Spotlight."
                            } finally { busy = false }
                        }
                    }
                )
                ControlTab.TEAM -> TeamScreen(
                    api = api,
                    session = session,
                    staff = staff,
                    busy = busy,
                    onChanged = { notice = it; refresh() },
                    onError = { error = it }
                )
                ControlTab.ACTIVITY -> ActivityScreen(entries = audit, busy = busy)
                ControlTab.FINANCE -> FinanceScreen(
                    finance = finance,
                    refundsDashboard = refundsDashboard,
                    busy = busy,
                    isPlatformOwner = session.isPlatformOwner,
                    payoutDestinations = payoutDestinations,
                    onLoadPayoutDestinations = {
                        scope.launch {
                            try {
                                payoutDestinations = api.getChapaPayoutDestinations(session)
                            } catch (e: Exception) {
                                error = e.message ?: "Could not load Chapa payout destinations."
                            }
                        }
                    },
                    onCreatePlatformPayout = { amountMinor, bankSlug, bankName, accountName, accountNumber ->
                        scope.launch {
                            busy = true
                            error = null
                            try {
                                val result = api.createPlatformPayout(
                                    session, amountMinor, bankSlug, bankName, accountName, accountNumber
                                )
                                notice = "Platform withdrawal recorded with Chapa status ${result.optString("status", "pending")}. It remains under reconciliation until final confirmation."
                                finance = api.getFinanceDashboard(session)
                            } catch (e: Exception) {
                                error = e.message ?: "Could not submit the platform withdrawal."
                                try { finance = api.getFinanceDashboard(session) } catch (_: Exception) { }
                            } finally {
                                busy = false
                            }
                        }
                    },
                    onResolveOrganiserPayout = { requestId, status, providerReference, operatorNote ->
                        scope.launch {
                            busy = true
                            error = null
                            try {
                                val result = api.resolveOrganiserPayout(
                                    session, requestId, status, providerReference, operatorNote
                                )
                                notice = "Organiser payout request updated to ${result.optString("status", status)}. Settlement ledger and audit records were updated."
                                finance = api.getFinanceDashboard(session)
                                audit = api.getAuditLog(session)
                            } catch (e: Exception) {
                                error = e.message ?: "Could not update organiser payout request."
                                try {
                                    finance = api.getFinanceDashboard(session)
                                    audit = api.getAuditLog(session)
                                } catch (_: Exception) { }
                            } finally {
                                busy = false
                            }
                        }
                    },
                    onRequestRefund = { paymentId, amountMinor, reason, idempotencyKey ->
                        scope.launch {
                            busy = true
                            error = null
                            try {
                                val result = api.createChapaRefund(session, paymentId, amountMinor, reason, idempotencyKey)
                                notice = "Chapa refund request recorded: ${result.optString("status", "pending")}. Verify the individual refund before closing the finance review."
                                finance = api.getFinanceDashboard(session)
                                refundsDashboard = api.getRefundsDashboard(session)
                            } catch (e: Exception) {
                                error = e.message ?: "Could not create the Chapa refund request."
                                // A timeout can still leave a saved submission_unknown operation.
                                // Refresh so the operator can safely retry the same idempotency key.
                                try {
                                    finance = api.getFinanceDashboard(session)
                                    refundsDashboard = api.getRefundsDashboard(session)
                                } catch (_: Exception) { }
                            } finally {
                                busy = false
                            }
                        }
                    },
                    onRefresh = { refresh() },
                    onVerifyRefund = { refundId ->
                        scope.launch {
                            busy = true
                            error = null
                            try {
                                val result = api.verifyChapaRefund(session, refundId)
                                notice = "Chapa refund verification: ${result.optString("status", "unknown")}. Ticket and settlement reconciliation remains in the finance review queue."
                                finance = api.getFinanceDashboard(session)
                                refundsDashboard = api.getRefundsDashboard(session)
                            } catch (e: Exception) {
                                error = e.message ?: "Could not verify the Chapa refund."
                                // Keep pending/unknown verification states visible after provider outages.
                                try {
                                    finance = api.getFinanceDashboard(session)
                                    refundsDashboard = api.getRefundsDashboard(session)
                                } catch (_: Exception) { }
                            } finally {
                                busy = false
                            }
                        }
                    }
                )
                ControlTab.USERS -> UserModerationScreen(
                    api = api,
                    session = session,
                    onChanged = { notice = it; refresh() },
                    onError = { error = it }
                )
            }
        }
    }
}

@Composable
private fun OverviewScreen(
    overview: JSONObject,
    isAdmin: Boolean,
    isSuperAdmin: Boolean,
    isBusy: Boolean,
    onRefresh: () -> Unit,
    onOpenTab: (ControlTab) -> Unit
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 18.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(13.dp)
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Good to see you.", color = Muted, fontSize = 12.sp)
                    Text("Platform at a glance", color = Ink, fontSize = 25.sp, fontWeight = FontWeight.Bold)
                }
                TextButton(onClick = onRefresh, enabled = !isBusy) { Text("Refresh", color = Teal) }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                MetricCard("EVENT REVIEWS", overview.optInt("pending_events"), Accent, Modifier.weight(1f))
                if (isAdmin) MetricCard("ORGANISERS", overview.optInt("pending_organisers"), Teal, Modifier.weight(1f))
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                MetricCard("PUBLISHED", overview.optInt("published_events"), Ink, Modifier.weight(1f))
                if (isAdmin) MetricCard("VERIFIED", overview.optInt("verified_organisers"), Teal, Modifier.weight(1f))
            }
        }
        item {
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(19.dp)).background(Ink).padding(18.dp)
            ) {
                Text("OPERATIONS", color=Color(0xFFA9C4BC), fontSize=9.sp, fontWeight=FontWeight.Bold, letterSpacing=1.4.sp)
                Spacer(Modifier.height(6.dp))
                Text(
                    if (isSuperAdmin) "You have full platform control." else if (isAdmin) "You can verify organisers and manage reviews." else "You can review submitted events.",
                    color=Color.White, fontSize=17.sp, fontWeight=FontWeight.SemiBold
                )
                Spacer(Modifier.height(5.dp))
                Text("Every approval and staff permission change is recorded in the audit log.", color=Color(0xFFC5D5D0), fontSize=11.sp, lineHeight=16.sp)
            }
        }
        item {
            Text("WORK QUEUES", color=Muted, fontSize=10.sp, fontWeight=FontWeight.Bold, letterSpacing=1.2.sp)
        }
        item {
            QueueShortcut(
                title = "Event submissions",
                subtitle = "${overview.optInt("pending_events")} waiting for review",
                onClick = { onOpenTab(ControlTab.EVENTS) }
            )
        }
        if (isAdmin) {
            item {
                QueueShortcut(
                    title = "Organiser applications",
                    subtitle = "${overview.optInt("pending_organisers")} waiting for verification",
                    onClick = { onOpenTab(ControlTab.ORGANISERS) }
                )
            }
            item {
                QueueShortcut(
                    title = "Financial monitoring",
                    subtitle = "Payments, refunds, revenue and payout status",
                    onClick = { onOpenTab(ControlTab.FINANCE) }
                )
            }
            item {
                QueueShortcut(
                    title = "User moderation",
                    subtitle = "Search accounts, suspend future sign-ins and restore access",
                    onClick = { onOpenTab(ControlTab.USERS) }
                )
            }
            item {
                QueueShortcut(
                    title = "Administrative activity",
                    subtitle = "Approvals, decisions and staff changes",
                    onClick = { onOpenTab(ControlTab.ACTIVITY) }
                )
            }
        }
        if (isSuperAdmin) {
            item {
                QueueShortcut(
                    title = "Staff access",
                    subtitle = "Manage moderators and administrators",
                    onClick = { onOpenTab(ControlTab.TEAM) }
                )
            }
        }
    }
}

@Composable
private fun MetricCard(label: String, value: Int, accent: Color, modifier: Modifier = Modifier) {
    Column(
        modifier
            .clip(RoundedCornerShape(18.dp))
            .background(CardWhite)
            .padding(15.dp)
    ) {
        Box(Modifier.width(25.dp).height(3.dp).clip(CircleShape).background(accent))
        Spacer(Modifier.height(12.dp))
        Text(value.toString(), color=Ink, fontSize=29.sp, fontWeight=FontWeight.Bold)
        Text(label, color=Muted, fontSize=8.sp, fontWeight=FontWeight.Bold, letterSpacing=1.sp)
    }
}

@Composable
private fun QueueShortcut(title: String, subtitle: String, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        color = CardWhite,
        shape = RoundedCornerShape(17.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, color=Ink, fontSize=14.sp, fontWeight=FontWeight.SemiBold)
                Spacer(Modifier.height(3.dp))
                Text(subtitle, color=Muted, fontSize=11.sp)
            }
            Text("→", color=Accent, fontSize=23.sp, fontWeight=FontWeight.Bold)
        }
    }
}

@Composable
private fun OrganiserQueueScreen(
    items: JSONArray,
    verifiedItems: JSONArray,
    busy: Boolean,
    onReview: (String, String, String) -> Unit,
    onAutoPublish: (String, Boolean, String) -> Unit
) {
    var notes by remember { mutableStateOf("") }
    var policyReason by remember { mutableStateOf("") }
    var selectedOrg by remember { mutableStateOf<JSONObject?>(null) }
    var selectedTrustEnabled by remember { mutableStateOf(false) }
    var showTrustConfirm by remember { mutableStateOf(false) }

    LazyColumn(
        modifier=Modifier.fillMaxSize().padding(horizontal=16.dp),
        verticalArrangement=Arrangement.spacedBy(11.dp),
        contentPadding=PaddingValues(bottom=28.dp)
    ) {
        item {
            ScreenHeading(
                "Organiser applications",
                "Verify organisers first. Trusted organisers can publish ordinary events without waiting for each event review."
            )
        }
        item {
            OutlinedTextField(
                value=notes, onValueChange={notes=it},
                modifier=Modifier.fillMaxWidth(),
                label={Text("Review note (optional)")},
                shape=RoundedCornerShape(13.dp), minLines=1, maxLines=3
            )
        }
        item {
            Text("PENDING APPLICATIONS · ${items.length()}",color=Muted,fontSize=9.sp,fontWeight=FontWeight.Bold,letterSpacing=1.sp)
        }
        if(items.length()==0) {
            item { EmptyState("No pending organiser applications","New applications will appear here.") }
        } else {
            items((0 until items.length()).mapNotNull{items.optJSONObject(it)},key={it.optString("id")}) { org ->
                ReviewCard(
                    title=org.optString("name","Organiser"),
                    subtitle=org.optString("legal_name"),
                    meta=listOf(org.optString("contact_phone"),org.optString("created_at").take(10))
                        .filter{it.isNotBlank()}.joinToString(" · "),
                    note=org.optString("verification_notes"),
                    busy=busy,
                    actions=listOf(
                        ReviewAction("Request info","request_info",Muted),
                        ReviewAction("Reject","reject",Danger),
                        ReviewAction("Approve","approve",Teal)
                    ),
                    onAction={decision->onReview(org.optString("id"),decision,notes.trim())}
                )
            }
        }
        item {
            Spacer(Modifier.height(8.dp))
            Text("VERIFIED ORGANISERS · ${verifiedItems.length()}",color=Muted,fontSize=9.sp,fontWeight=FontWeight.Bold,letterSpacing=1.sp)
            Text(
                "Auto-publishing is an explicit trust decision. Only verified organisers can receive it; flagged or rejected events still require human review.",
                color=Muted,fontSize=10.sp,lineHeight=15.sp
            )
        }
        if(verifiedItems.length()==0) {
            item { EmptyState("No verified organisers yet","Approved organisers will appear here for trust management.") }
        } else {
            items((0 until verifiedItems.length()).mapNotNull{verifiedItems.optJSONObject(it)},key={"trusted-${it.optString("id")}"}) { org ->
                val trusted=org.optBoolean("auto_publish_enabled")
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(CardWhite).padding(14.dp)
                ) {
                    Row(verticalAlignment=Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(org.optString("name","Organiser"),color=Ink,fontSize=13.sp,fontWeight=FontWeight.Bold)
                            Text(org.optString("legal_name"),color=Muted,fontSize=10.sp)
                            Text(org.optString("contact_phone"),color=Muted,fontSize=9.sp)
                        }
                        StatusPill(if(trusted) "auto publish" else "manual review")
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        if(trusted)
                            "New events from this organiser publish automatically after submission, unless a review flag is active."
                        else
                            "New events from this organiser enter the normal manual review queue.",
                        color=Muted,fontSize=10.sp,lineHeight=15.sp
                    )
                    Spacer(Modifier.height(7.dp))
                    OutlinedButton(
                        onClick={
                            selectedOrg=org
                            selectedTrustEnabled=!trusted
                            showTrustConfirm=true
                        },
                        enabled=!busy,
                        modifier=Modifier.fillMaxWidth(),
                        shape=RoundedCornerShape(11.dp)
                    ) {
                        Text(if(trusted) "Turn off automatic publishing" else "Trust organiser · enable auto-publish")
                    }
                }
            }
        }
    }

    val org=selectedOrg
    if(showTrustConfirm && org!=null) {
        AlertDialog(
            onDismissRequest={showTrustConfirm=false},
            title={Text(if(selectedTrustEnabled) "Trust this organiser?" else "Return organiser to manual review?")},
            text={
                Column {
                    Text(
                        if(selectedTrustEnabled)
                            "New unflagged events from ${org.optString("name")} will publish automatically. Event flags and unresolved rejections continue to require review."
                        else
                            "New events from ${org.optString("name")} will require moderator approval again.",
                        fontSize=12.sp,lineHeight=17.sp
                    )
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value=policyReason,onValueChange={policyReason=it},
                        modifier=Modifier.fillMaxWidth(),
                        label={Text("Reason (required)")},
                        minLines=2,maxLines=4,shape=RoundedCornerShape(12.dp)
                    )
                }
            },
            confirmButton={
                Button(
                    onClick={
                        showTrustConfirm=false
                        onAutoPublish(org.optString("id"),selectedTrustEnabled,policyReason.trim())
                        policyReason=""
                    },
                    enabled=policyReason.trim().length in 5..500,
                    colors=ButtonDefaults.buttonColors(containerColor=if(selectedTrustEnabled) Teal else Danger)
                ) { Text(if(selectedTrustEnabled) "Trust organiser" else "Disable auto-publish") }
            },
            dismissButton={TextButton(onClick={showTrustConfirm=false}) { Text("Cancel") }}
        )
    }
}

@Composable
private fun EventQueueScreen(
    items: JSONArray,
    publishedItems: JSONArray,
    spotlightItems: JSONArray,
    busy: Boolean,
    onReview: (String, String, String) -> Unit,
    onFlagPublished: (String,String) -> Unit,
    onSetSpotlight: (String, Boolean) -> Unit
) {
    var notes by remember { mutableStateOf("") }
    var flagReason by remember { mutableStateOf("") }
    var selectedPublishedEvent by remember { mutableStateOf<JSONObject?>(null) }
    var showFlagConfirm by remember { mutableStateOf(false) }
    val spotlightIds = remember(spotlightItems) {
        (0 until spotlightItems.length()).mapNotNull { spotlightItems.optJSONObject(it)?.optString("id")?.takeIf { id -> id.isNotBlank() } }.toSet()
    }

    LazyColumn(
        modifier=Modifier.fillMaxSize().padding(horizontal=16.dp),
        verticalArrangement=Arrangement.spacedBy(11.dp),
        contentPadding=PaddingValues(bottom=28.dp)
    ) {
        item {
            ScreenHeading("Event moderation","Review new submissions and investigate published listings reported or flagged for review.")
        }
        item {
            OutlinedTextField(
                value=notes,onValueChange={notes=it},
                modifier=Modifier.fillMaxWidth(),
                label={Text("Review note (optional)")},
                shape=RoundedCornerShape(13.dp),minLines=1,maxLines=3
            )
        }
        item {
            Text("PENDING SUBMISSIONS · ${items.length()}",color=Muted,fontSize=9.sp,fontWeight=FontWeight.Bold,letterSpacing=1.sp)
        }
        if(items.length()==0) {
            item { EmptyState("No pending event submissions","New events from manual-review organisers appear here.") }
        } else {
            items((0 until items.length()).mapNotNull{items.optJSONObject(it)},key={it.optString("id")}) { event ->
                ReviewCard(
                    title=event.optString("title","Untitled event"),
                    subtitle=event.optString("category"),
                    meta=listOf(event.optString("starts_at").replace("T"," ").take(16),event.optString("venue_name"),event.optString("city"))
                        .filter{it.isNotBlank()}.joinToString(" · "),
                    note=event.optString("description"),
                    busy=busy,
                    actions=listOf(
                        ReviewAction("Request changes","request_changes",Muted),
                        ReviewAction("Reject","reject",Danger),
                        ReviewAction("Approve & publish","approve",Teal)
                    ),
                    onAction={decision->onReview(event.optString("id"),decision,notes.trim())}
                )
            }
        }
        item {
            Spacer(Modifier.height(8.dp))
            Text("PUBLISHED EVENTS · ${publishedItems.length()}",color=Muted,fontSize=9.sp,fontWeight=FontWeight.Bold,letterSpacing=1.sp)
            Text("Flagging removes a published event from public listings and sends it back to the review queue.",color=Muted,fontSize=10.sp,lineHeight=15.sp)
        }
        if(publishedItems.length()==0) {
            item { EmptyState("No published events","Published events will appear here for ongoing moderation.") }
        } else {
            items((0 until publishedItems.length()).mapNotNull{publishedItems.optJSONObject(it)},key={"published-${it.optString("id")}"}) { event ->
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(CardWhite).padding(14.dp)) {
                    Text(event.optString("title","Untitled event"),color=Ink,fontSize=13.sp,fontWeight=FontWeight.Bold)
                    Text("${event.optString("organisation_name")} · ${event.optString("category")}",color=Teal,fontSize=10.sp)
                    Text(listOf(event.optString("starts_at").replace("T"," ").take(16),event.optString("venue_name"),event.optString("city"))
                        .filter{it.isNotBlank()}.joinToString(" · "),color=Muted,fontSize=9.sp)
                    if(event.optString("description").isNotBlank()) {
                        Text(event.optString("description"),color=Ink,fontSize=11.sp,lineHeight=15.sp,maxLines=3,overflow=TextOverflow.Ellipsis)
                    }
                    val isFeatured = spotlightIds.contains(event.optString("id"))
                    if (isFeatured) {
                        Spacer(Modifier.height(7.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            StatusPill("Spotlight")
                            Spacer(Modifier.width(8.dp))
                            Text("Curated placement is active", color = Teal, fontSize = 10.sp)
                        }
                    }
                    Spacer(Modifier.height(7.dp))
                    OutlinedButton(
                        onClick = { onSetSpotlight(event.optString("id"), !isFeatured) },
                        enabled = !busy,
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(11.dp),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = if (isFeatured) Danger else Teal)
                    ) { Text(if (isFeatured) "Remove from Tiqet Spotlight" else "Feature in Tiqet Spotlight", fontSize = 10.sp) }
                    Spacer(Modifier.height(4.dp))
                    Text("Spotlight uses the event banner supplied by its organizer. Tiqet does not replace event artwork.", color = Muted, fontSize = 9.sp, lineHeight = 13.sp)
                    Spacer(Modifier.height(7.dp))
                    OutlinedButton(
                        onClick={selectedPublishedEvent=event;showFlagConfirm=true},
                        enabled=!busy,
                        modifier=Modifier.fillMaxWidth(),
                        shape=RoundedCornerShape(11.dp),
                        colors=ButtonDefaults.outlinedButtonColors(contentColor=Danger)
                    ) { Text("Flag for moderator review",fontSize=10.sp) }
                }
            }
        }
    }

    val flaggedEvent=selectedPublishedEvent
    if(showFlagConfirm && flaggedEvent!=null) {
        AlertDialog(
            onDismissRequest={showFlagConfirm=false},
            title={Text("Flag published event?")},
            text={
                Column {
                    Text("The event will be removed from public listings and returned to the review queue.",fontSize=12.sp,lineHeight=17.sp)
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value=flagReason,onValueChange={flagReason=it},
                        modifier=Modifier.fillMaxWidth(),
                        label={Text("Reason (required)")},
                        minLines=2,maxLines=4,shape=RoundedCornerShape(12.dp)
                    )
                }
            },
            confirmButton={
                Button(
                    onClick={
                        showFlagConfirm=false
                        onFlagPublished(flaggedEvent.optString("id"),flagReason.trim())
                        flagReason=""
                    },
                    enabled=flagReason.trim().length in 5..1000,
                    colors=ButtonDefaults.buttonColors(containerColor=Danger)
                ) { Text("Flag event") }
            },
            dismissButton={TextButton(onClick={showFlagConfirm=false}) { Text("Cancel") }}
        )
    }
}

private data class ReviewAction(val label: String, val decision: String, val color: Color)

@Composable
private fun ReviewCard(
    title: String,
    subtitle: String,
    meta: String,
    note: String,
    busy: Boolean,
    actions: List<ReviewAction>,
    onAction: (String) -> Unit
) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(CardWhite).padding(15.dp).animateContentSize()
    ) {
        Text(title, color=Ink, fontSize=15.sp, fontWeight=FontWeight.Bold)
        if (subtitle.isNotBlank()) {
            Spacer(Modifier.height(3.dp))
            Text(subtitle, color=Teal, fontSize=11.sp, fontWeight=FontWeight.SemiBold)
        }
        if (meta.isNotBlank()) {
            Spacer(Modifier.height(7.dp))
            Text(meta, color=Muted, fontSize=10.sp, lineHeight=15.sp)
        }
        if (note.isNotBlank()) {
            Spacer(Modifier.height(9.dp))
            Text(note, color=Ink, fontSize=12.sp, lineHeight=17.sp, maxLines=5, overflow=TextOverflow.Ellipsis)
        }
        Spacer(Modifier.height(13.dp))
        FlowRowCompat(actions, busy, onAction)
    }
}

@Composable
private fun FlowRowCompat(actions: List<ReviewAction>, busy: Boolean, onAction: (String) -> Unit) {
    Column(verticalArrangement=Arrangement.spacedBy(7.dp)) {
        actions.chunked(2).forEach { row ->
            Row(horizontalArrangement=Arrangement.spacedBy(7.dp)) {
                row.forEach { action ->
                    OutlinedButton(
                        onClick={onAction(action.decision)},
                        enabled=!busy,
                        modifier=Modifier.weight(1f),
                        shape=RoundedCornerShape(12.dp),
                        colors=ButtonDefaults.outlinedButtonColors(contentColor=action.color),
                        contentPadding=PaddingValues(horizontal=7.dp,vertical=9.dp)
                    ) {
                        Text(action.label,fontSize=10.sp,fontWeight=FontWeight.SemiBold,maxLines=1)
                    }
                }
                if (row.size==1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun TeamScreen(
    api: SupabaseApi,
    session: ControlSession,
    staff: JSONArray,
    busy: Boolean,
    onChanged: (String) -> Unit,
    onError: (String) -> Unit
) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf(JSONArray()) }
    var note by remember { mutableStateOf("") }
    var searching by remember { mutableStateOf(false) }
    val scope=rememberCoroutineScope()

    Column(Modifier.fillMaxSize().padding(horizontal=16.dp)) {
        ScreenHeading("Staff access", "Only the super administrator can change staff permissions.")
        OutlinedTextField(
            value=query,onValueChange={query=it},
            modifier=Modifier.fillMaxWidth(),label={Text("Search a user by email")},
            singleLine=true,shape=RoundedCornerShape(13.dp)
        )
        OutlinedTextField(
            value=note,onValueChange={note=it},
            modifier=Modifier.fillMaxWidth(),label={Text("Reason for access change")},
            singleLine=true,shape=RoundedCornerShape(13.dp)
        )
        Button(
            onClick={
                scope.launch {
                    searching=true
                    try { results=api.searchUsers(session,query.trim()) }
                    catch(e:Exception){ onError(e.message ?: "Search failed.") }
                    finally { searching=false }
                }
            },
            enabled=!searching && query.trim().length>=3,
            modifier=Modifier.fillMaxWidth().height(46.dp),
            colors=ButtonDefaults.buttonColors(containerColor=Ink),
            shape=RoundedCornerShape(12.dp)
        ) {
            Text(if(searching) "Searching…" else "Search users")
        }
        Spacer(Modifier.height(13.dp))
        if(results.length()>0) {
            Text("MATCHING ACCOUNTS",color=Muted,fontSize=9.sp,fontWeight=FontWeight.Bold,letterSpacing=1.sp)
            Spacer(Modifier.height(6.dp))
            LazyColumn(Modifier.heightIn(max=240.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                items((0 until results.length()).mapNotNull{results.optJSONObject(it)},key={it.optString("user_id")}) { user ->
                    Column(Modifier.fillMaxWidth().background(CardWhite,RoundedCornerShape(14.dp)).padding(12.dp)) {
                        Text(user.optString("email"),color=Ink,fontSize=12.sp,fontWeight=FontWeight.SemiBold)
                        Text(user.optString("full_name"),color=Muted,fontSize=10.sp)
                        Text("Current role: ${user.optString("staff_role","none")}",color=Teal,fontSize=10.sp)
                        Spacer(Modifier.height(7.dp))
                        Row(horizontalArrangement=Arrangement.spacedBy(6.dp)) {
                            listOf("moderator","admin","super_admin").forEach { role ->
                                TextButton(onClick={
                                    scope.launch {
                                        try {
                                            api.assignStaffRole(session,user.optString("user_id"),role,note.trim())
                                            onChanged("Assigned $role access to ${user.optString("email")}.")
                                            results=api.searchUsers(session,query.trim())
                                        } catch(e:Exception){ onError(e.message ?: "Could not assign role.") }
                                    }
                                }) { Text(role.replace('_',' '),fontSize=9.sp,color=Teal) }
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
        }
        Text("CURRENT STAFF",color=Muted,fontSize=9.sp,fontWeight=FontWeight.Bold,letterSpacing=1.sp)
        Spacer(Modifier.height(7.dp))
        if(staff.length()==0) EmptyState("No staff accounts", "Assign the first moderator or administrator.")
        else LazyColumn(verticalArrangement=Arrangement.spacedBy(8.dp),contentPadding=PaddingValues(bottom=24.dp)) {
            items((0 until staff.length()).mapNotNull{staff.optJSONObject(it)},key={it.optString("user_id")}) { member ->
                Row(
                    Modifier.fillMaxWidth().background(CardWhite,RoundedCornerShape(14.dp)).padding(12.dp),
                    verticalAlignment=Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(member.optString("email"),color=Ink,fontSize=12.sp,fontWeight=FontWeight.SemiBold)
                        Text(member.optString("role").replace('_',' '),color=Teal,fontSize=10.sp)
                    }
                    TextButton(onClick={
                        scope.launch {
                            try {
                                api.revokeStaffRole(session,member.optString("user_id"),note.trim())
                                onChanged("Staff access revoked.")
                            } catch(e:Exception){ onError(e.message ?: "Could not revoke role.") }
                        }
                    }) { Text("Revoke",color=Danger,fontSize=10.sp) }
                }
            }
        }
    }
}

@Composable
private fun UserModerationScreen(
    api: SupabaseApi,
    session: ControlSession,
    onChanged: (String) -> Unit,
    onError: (String) -> Unit
) {
    var query by remember { mutableStateOf("") }
    var reason by remember { mutableStateOf("") }
    var results by remember { mutableStateOf(JSONArray()) }
    var history by remember { mutableStateOf(JSONArray()) }
    var historyTarget by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var selectedUser by remember { mutableStateOf<JSONObject?>(null) }
    var selectedAction by remember { mutableStateOf("suspend") }
    var selectedDuration by remember { mutableStateOf("24h") }
    var showConfirm by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize().padding(horizontal=16.dp)) {
        ScreenHeading("User moderation", "Review accounts and restrict future sign-ins when necessary.")
        OutlinedTextField(
            value=query, onValueChange={query=it},
            modifier=Modifier.fillMaxWidth(), label={Text("Search by email")},
            singleLine=true, shape=RoundedCornerShape(13.dp)
        )
        Spacer(Modifier.height(8.dp))
        Button(
            onClick={
                scope.launch {
                    busy=true
                    try { results=api.searchUsers(session,query.trim()) }
                    catch(e:Exception){ onError(e.message ?: "Search failed.") }
                    finally { busy=false }
                }
            },
            enabled=!busy && query.trim().length>=3,
            modifier=Modifier.fillMaxWidth().height(45.dp),
            colors=ButtonDefaults.buttonColors(containerColor=Ink),
            shape=RoundedCornerShape(12.dp)
        ) { Text(if(busy) "Searching…" else "Search accounts") }
        Spacer(Modifier.height(8.dp))
        Text(
            "Temporary bans block new sign-ins for the selected period. Existing access tokens are not immediately revoked.",
            color=Muted,fontSize=10.sp,lineHeight=15.sp
        )
        Spacer(Modifier.height(10.dp))
        if(results.length()==0) {
            EmptyState("No accounts loaded","Search by email to find an account.")
        } else {
            LazyColumn(verticalArrangement=Arrangement.spacedBy(9.dp),contentPadding=PaddingValues(bottom=24.dp)) {
                items((0 until results.length()).mapNotNull{results.optJSONObject(it)},key={it.optString("user_id")}) { user ->
                    val staffRole=user.optString("staff_role")
                    val banValue=user.optString("banned_until")
                    val banned=banValue.isNotBlank()
                    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp)).background(CardWhite).padding(13.dp)) {
                        Text(user.optString("email"),color=Ink,fontSize=12.sp,fontWeight=FontWeight.Bold)
                        if(user.optString("full_name").isNotBlank()) Text(user.optString("full_name"),color=Muted,fontSize=10.sp)
                        Text(if(banned) "Ban expiry: $banValue" else "No active ban recorded",color=if(banned) Danger else Teal,fontSize=10.sp)
                        TextButton(
                            onClick={
                                scope.launch {
                                    historyTarget=user.optString("user_id")
                                    try {
                                        history=api.getUserModerationHistory(session,historyTarget)
                                    } catch(e:Exception) {
                                        onError(e.message ?: "Could not load moderation history.")
                                    }
                                }
                            },
                            contentPadding=PaddingValues(horizontal=0.dp,vertical=2.dp)
                        ) { Text("View moderation history",color=Teal,fontSize=10.sp) }
                        if(historyTarget==user.optString("user_id")) {
                            if(history.length()==0) {
                                Text("No moderation actions recorded.",color=Muted,fontSize=9.sp)
                            } else {
                                for(index in 0 until minOf(history.length(),4)) {
                                    val entry=history.optJSONObject(index) ?: continue
                                    Text(
                                        "${entry.optString("action")} · ${entry.optString("status")} · ${entry.optString("created_at").take(16).replace("T"," ")}",
                                        color=Ink,fontSize=9.sp
                                    )
                                    if(entry.optString("reason").isNotBlank()) {
                                        Text(entry.optString("reason"),color=Muted,fontSize=9.sp)
                                    }
                                }
                            }
                        }
                        if(staffRole.isNotBlank()) {
                            Text("Staff account: $staffRole. Manage staff access in the Team section.",color=Muted,fontSize=10.sp)
                        } else {
                            OutlinedTextField(
                                value=reason,onValueChange={reason=it},
                                modifier=Modifier.fillMaxWidth(),
                                label={Text("Reason for moderation")},
                                singleLine=true,shape=RoundedCornerShape(11.dp)
                            )
                            Spacer(Modifier.height(6.dp))
                            Row(horizontalArrangement=Arrangement.spacedBy(5.dp)) {
                                listOf("24h" to "24h","168h" to "7d","720h" to "30d").forEach { (duration,label) ->
                                    OutlinedButton(
                                        onClick={selectedUser=user;selectedAction="suspend";selectedDuration=duration;showConfirm=true},
                                        enabled=!busy,
                                        modifier=Modifier.weight(1f),
                                        shape=RoundedCornerShape(10.dp),
                                        contentPadding=PaddingValues(horizontal=3.dp,vertical=7.dp)
                                    ) { Text("Suspend $label",fontSize=9.sp) }
                                }
                            }
                            if(banned) {
                                TextButton(
                                    onClick={selectedUser=user;selectedAction="restore";selectedDuration="";showConfirm=true},
                                    enabled=!busy
                                ) { Text("Restore sign-in access",color=Teal,fontSize=10.sp) }
                            }
                        }
                    }
                }
            }
        }
    }

    val target=selectedUser
    if(showConfirm && target!=null) {
        AlertDialog(
            onDismissRequest={showConfirm=false},
            title={Text(if(selectedAction=="suspend") "Confirm suspension" else "Restore access")},
            text={
                Column {
                    Text(
                        if(selectedAction=="suspend")
                            "Suspend future sign-ins for this account for $selectedDuration? Existing access tokens may still work until expiry."
                        else
                            "Clear the sign-in ban for this account?",
                        fontSize=12.sp
                    )
                    Spacer(Modifier.height(8.dp))
                    Text("Reason: $reason",fontSize=11.sp,color=Muted)
                }
            },
            confirmButton={
                Button(
                    onClick={
                        val action=selectedAction
                        val duration=if(action=="suspend") selectedDuration else null
                        showConfirm=false
                        scope.launch {
                            busy=true
                            try {
                                api.moderateUser(session,target.optString("user_id"),action,duration,reason.trim())
                                onChanged(if(action=="suspend") "Account sign-in suspended." else "Account sign-in restored.")
                                reason=""
                                results=api.searchUsers(session,query.trim())
                            } catch(e:Exception) {
                                onError(e.message ?: "Moderation action failed.")
                            } finally { busy=false }
                        }
                    },
                    enabled=reason.trim().length in 5..500,
                    colors=ButtonDefaults.buttonColors(containerColor=if(selectedAction=="suspend") Danger else Teal)
                ) { Text(if(selectedAction=="suspend") "Suspend" else "Restore") }
            },
            dismissButton={ TextButton(onClick={showConfirm=false}) { Text("Cancel") } }
        )
    }
}

@Composable
private fun FinanceScreen(
    finance: JSONObject,
    refundsDashboard: JSONObject,
    busy: Boolean,
    isPlatformOwner: Boolean,
    payoutDestinations: JSONArray,
    onLoadPayoutDestinations: () -> Unit,
    onCreatePlatformPayout: (amountMinor: Long, bankSlug: String, bankName: String, accountName: String, accountNumber: String) -> Unit,
    onResolveOrganiserPayout: (requestId: String, status: String, providerReference: String, operatorNote: String) -> Unit,
    onRequestRefund: (paymentId: String, amountMinor: Long?, reason: String, idempotencyKey: String) -> Unit,
    onVerifyRefund: (refundId: String) -> Unit,
    onRefresh: () -> Unit
) {
    val summary = finance.optJSONObject("summary") ?: JSONObject()
    val payments = finance.optJSONArray("recent_payments") ?: JSONArray()
    val refunds = finance.optJSONArray("refund_alerts") ?: JSONArray()
    val individualRefunds = refundsDashboard.optJSONArray("refunds") ?: JSONArray()
    val refundSummary = refundsDashboard.optJSONObject("summary") ?: JSONObject()
    val platformPayouts = finance.optJSONArray("platform_payouts") ?: JSONArray()
    var selectedPayment by remember { mutableStateOf<JSONObject?>(null) }
    var amountEtb by remember { mutableStateOf("") }
    var reason by remember { mutableStateOf("") }
    var idempotencyKey by remember { mutableStateOf("") }
    var formError by remember { mutableStateOf<String?>(null) }
    var showPayoutDialog by remember { mutableStateOf(false) }
    var payoutAmountEtb by remember { mutableStateOf("") }
    var payoutAccountName by remember { mutableStateOf("") }
    var payoutAccountNumber by remember { mutableStateOf("") }
    var selectedDestinationSlug by remember { mutableStateOf("") }
    var payoutMenuExpanded by remember { mutableStateOf(false) }
    var payoutFormError by remember { mutableStateOf<String?>(null) }
    var selectedOrganiserPayout by remember { mutableStateOf<JSONObject?>(null) }
    var organiserPayoutNextStatus by remember { mutableStateOf("") }
    var organiserPayoutProviderReference by remember { mutableStateOf("") }
    var organiserPayoutNote by remember { mutableStateOf("") }
    var organiserPayoutFormError by remember { mutableStateOf<String?>(null) }
    val destinations = (0 until payoutDestinations.length()).mapNotNull { payoutDestinations.optJSONObject(it) }
    val selectedDestination = destinations.firstOrNull { it.optString("slug") == selectedDestinationSlug }
    val organiserPayouts = finance.optJSONArray("organiser_payout_requests") ?: JSONArray()

    fun money(value: Double): String = "ETB " + String.format(Locale.US, "%,.2f", value)
    fun amount(row: JSONObject, key: String = "amount_minor"): String =
        money(row.optLong(key).toDouble() / 100.0)

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start=16.dp,end=16.dp,top=15.dp,bottom=28.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            Column {
                Row(verticalAlignment=Alignment.CenterVertically) {
                    Text("Financial operations",color=Ink,fontSize=23.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f))
                    TextButton(onClick=onRefresh,enabled=!busy) { Text("Refresh",color=Teal,fontSize=11.sp) }
                }
                Text("Verified payments, refund requests and settlement review.",color=Muted,fontSize=11.sp,lineHeight=16.sp)
                if (busy) {
                    Spacer(Modifier.height(8.dp))
                    LinearProgressIndicator(Modifier.fillMaxWidth(),color=Teal)
                }
            }
        }
        item {
            Row(horizontalArrangement=Arrangement.spacedBy(9.dp)) {
                FinanceMetric("NET PLATFORM REVENUE",money(summary.optDouble("net_platform_revenue_etb")),Teal,Modifier.weight(1f))
                FinanceMetric("PAID ORDERS",summary.optInt("paid_orders").toString(),Ink,Modifier.weight(1f))
            }
        }
        item {
            Row(horizontalArrangement=Arrangement.spacedBy(9.dp)) {
                FinanceMetric("PAYMENT REVIEW",summary.optInt("payment_reviews").toString(),Accent,Modifier.weight(1f))
                FinanceMetric("REFUNDS TO REVIEW",summary.optInt("refunds_needing_review").toString(),Danger,Modifier.weight(1f))
            }
        }
        item {
            Row(horizontalArrangement=Arrangement.spacedBy(9.dp)) {
                FinanceMetric("OPEN REFUND REQUESTS",refundSummary.optInt("open").toString(),Accent,Modifier.weight(1f))
                FinanceMetric("VERIFIED REFUNDS",refundSummary.optInt("succeeded").toString(),Teal,Modifier.weight(1f))
            }
        }
        item {
            Row(horizontalArrangement=Arrangement.spacedBy(9.dp)) {
                FinanceMetric("PLATFORM PAYOUTS IN FLIGHT",summary.optInt("platform_payouts_in_flight").toString(),Ink,Modifier.weight(1f))
                FinanceMetric("ORGANISER PAYOUT REQUESTS",summary.optInt("organiser_payout_requests_open").toString(),Teal,Modifier.weight(1f))
            }
        }
        item { FinanceSectionTitle("Recent payments",payments.length()) }
        if (payments.length()==0) {
            item { EmptyState("No payment records yet","Verified test or customer payments will appear here.") }
        } else {
            items((0 until payments.length()).mapNotNull{payments.optJSONObject(it)},key={it.optString("payment_id")}) { row ->
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp)).background(CardWhite).padding(13.dp)) {
                    Row(verticalAlignment=Alignment.CenterVertically) {
                        Text(amount(row),color=Ink,fontSize=16.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f))
                        StatusPill(row.optString("status"))
                    }
                    Text("${row.optString("provider")} · ${row.optString("payment_method")}",color=Teal,fontSize=10.sp)
                    Text("Order: ${row.optString("order_status")} · ${row.optString("buyer_email")}",color=Muted,fontSize=10.sp)
                    Text(row.optString("merchant_reference"),color=Muted,fontSize=9.sp)
                    Text(row.optString("created_at").replace("T"," ").take(16),color=Muted,fontSize=9.sp)
                    if (row.optString("provider") == "chapa" &&
                        row.optString("status") in listOf("succeeded","partially_refunded")) {
                        Spacer(Modifier.height(5.dp))
                        OutlinedButton(
                            onClick = {
                                selectedPayment = row
                                amountEtb = ""
                                reason = ""
                                formError = null
                                idempotencyKey = java.util.UUID.randomUUID().toString()
                            },
                            enabled = !busy,
                            shape = RoundedCornerShape(11.dp),
                            contentPadding = PaddingValues(horizontal=12.dp,vertical=7.dp)
                        ) {
                            Text("Request refund",fontSize=11.sp)
                        }
                    }
                }
            }
        }
        item { FinanceSectionTitle("Individual refund requests",individualRefunds.length()) }
        if (individualRefunds.length() == 0) {
            item { Text("No individual refund requests recorded.",color=Muted,fontSize=11.sp) }
        } else {
            items((0 until individualRefunds.length()).mapNotNull{individualRefunds.optJSONObject(it)},key={it.optString("id")}) { row ->
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp)).background(CardWhite).padding(13.dp)) {
                    Row(verticalAlignment=Alignment.CenterVertically) {
                        Text(amount(row),color=Ink,fontSize=15.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f))
                        StatusPill(row.optString("status"))
                    }
                    Text(row.optString("reason"),color=Muted,fontSize=10.sp)
                    Text("Payment: ${row.optString("payment_merchant_reference")}",color=Muted,fontSize=9.sp)
                    Text("Refund ref: ${row.optString("provider_reference").ifBlank { row.optString("merchant_reference") }}",color=Muted,fontSize=9.sp)
                    if (row.optString("status") in listOf("requested","pending","submission_unknown") &&
                        row.optString("provider_reference").isNotBlank()) {
                        TextButton(
                            onClick = { onVerifyRefund(row.optString("id")) },
                            enabled = !busy,
                            contentPadding = PaddingValues(horizontal=4.dp,vertical=3.dp)
                        ) { Text("Verify with Chapa",color=Teal,fontSize=11.sp) }
                    } else if (row.optString("status") in listOf("requested", "submission_unknown") &&
                        row.optString("provider_reference").isBlank() &&
                        row.optString("idempotency_key").isNotBlank()) {
                        TextButton(
                            onClick = {
                                val fullRefund = row.optBoolean("request_full_refund")
                                val partialAmount = if (fullRefund || row.isNull("requested_amount_minor")) null
                                    else row.optLong("requested_amount_minor")
                                onRequestRefund(
                                    row.optString("payment_id"),
                                    partialAmount,
                                    row.optString("reason"),
                                    row.optString("idempotency_key")
                                )
                            },
                            enabled = !busy,
                            contentPadding = PaddingValues(horizontal=4.dp,vertical=3.dp)
                        ) { Text("Retry same request",color=Teal,fontSize=11.sp) }
                    }
                    if (row.optString("error_message").isNotBlank()) {
                        Text(row.optString("error_message"),color=Danger,fontSize=10.sp)
                    }
                    Text(row.optString("created_at").replace("T"," ").take(16),color=Muted,fontSize=9.sp)
                }
            }
        }
        item { FinanceSectionTitle("Refund alerts",refunds.length()) }
        if (refunds.length()==0) {
            item { Text("No refund alerts recorded.",color=Muted,fontSize=11.sp) }
        } else {
            items((0 until refunds.length()).mapNotNull{refunds.optJSONObject(it)},key={it.optString("id")}) { row ->
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp)).background(CardWhite).padding(13.dp)) {
                    Row(verticalAlignment=Alignment.CenterVertically) {
                        Text(row.optString("event_name","Refund notice").replace('_',' '),color=Ink,fontSize=12.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f))
                        StatusPill(row.optString("review_status"))
                    }
                    Text("Refunded ${amount(row,"refunded_amount_minor")} / ${amount(row,"original_amount_minor")}",color=Ink,fontSize=11.sp)
                    Text("${row.optString("provider_status")} · ${row.optString("merchant_reference")}",color=Muted,fontSize=10.sp)
                    Text(row.optString("received_at").replace("T"," ").take(16),color=Muted,fontSize=9.sp)
                }
            }
        }
        item {
            Row(verticalAlignment=Alignment.CenterVertically) {
                Text("Platform withdrawals",color=Ink,fontSize=13.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f))
                Text(platformPayouts.length().toString(),color=Muted,fontSize=10.sp)
                if (isPlatformOwner) {
                    Spacer(Modifier.width(8.dp))
                    Button(
                        onClick = {
                            payoutAmountEtb = ""
                            payoutAccountName = ""
                            payoutAccountNumber = ""
                            selectedDestinationSlug = ""
                            payoutFormError = null
                            showPayoutDialog = true
                            onLoadPayoutDestinations()
                        },
                        enabled = !busy,
                        contentPadding = PaddingValues(horizontal=10.dp, vertical=6.dp),
                        colors = ButtonDefaults.buttonColors(containerColor=Ink)
                    ) { Text("Withdraw",fontSize=10.sp) }
                }
            }
        }
        if (isPlatformOwner) {
            item {
                Text(
                    "Withdrawals are restricted to the platform owner. Chapa verifies the destination and available balance before a request is reserved.",
                    color=Muted,fontSize=10.sp,lineHeight=15.sp
                )
            }
        }
        if(platformPayouts.length()==0) {
            item { Text("No platform withdrawals recorded.",color=Muted,fontSize=11.sp) }
        } else {
            items((0 until platformPayouts.length()).mapNotNull{platformPayouts.optJSONObject(it)},key={it.optString("id")}) { row ->
                FinanceRecord(
                    title=amount(row),
                    subtitle="${row.optString("bank_name")} · •• ${row.optString("account_last4")}",
                    reference=row.optString("merchant_reference"),
                    status=row.optString("status")
                )
            }
        }
        item { FinanceSectionTitle("Organiser payout requests",organiserPayouts.length()) }
        if(organiserPayouts.length()==0) {
            item { Text("No organiser payout requests recorded.",color=Muted,fontSize=11.sp) }
        } else {
            items((0 until organiserPayouts.length()).mapNotNull{organiserPayouts.optJSONObject(it)},key={it.optString("id")}) { row ->
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp)).background(CardWhite).padding(13.dp),
                    verticalArrangement=Arrangement.spacedBy(5.dp)
                ) {
                    Row(verticalAlignment=Alignment.CenterVertically) {
                        Text(amount(row),color=Ink,fontSize=15.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f))
                        StatusPill(row.optString("status"))
                    }
                    Text("${row.optString("organisation_name")} · ${row.optString("provider")}",color=Muted,fontSize=10.sp)
                    if (row.optString("provider_reference").isNotBlank()) {
                        Text("Provider ref: ${row.optString("provider_reference")}",color=Muted,fontSize=9.sp)
                    }
                    Text(row.optString("operator_note"),color=Muted,fontSize=10.sp)
                    val current = row.optString("status")
                    Row(horizontalArrangement=Arrangement.spacedBy(5.dp)) {
                        when (current) {
                            "requested" -> {
                                TextButton(
                                    onClick = {
                                        selectedOrganiserPayout=row
                                        organiserPayoutNextStatus="approved"
                                        organiserPayoutProviderReference=""
                                        organiserPayoutNote=""
                                        organiserPayoutFormError=null
                                    },
                                    enabled=!busy
                                ) { Text("Approve",color=Teal,fontSize=10.sp) }
                                TextButton(
                                    onClick = {
                                        selectedOrganiserPayout=row
                                        organiserPayoutNextStatus="rejected"
                                        organiserPayoutProviderReference=""
                                        organiserPayoutNote=""
                                        organiserPayoutFormError=null
                                    },
                                    enabled=!busy
                                ) { Text("Reject",color=Danger,fontSize=10.sp) }
                            }
                            "approved" -> {
                                TextButton(
                                    onClick = {
                                        selectedOrganiserPayout=row
                                        organiserPayoutNextStatus="processing"
                                        organiserPayoutProviderReference=""
                                        organiserPayoutNote=""
                                        organiserPayoutFormError=null
                                    },
                                    enabled=!busy
                                ) { Text("Start processing",color=Teal,fontSize=10.sp) }
                                TextButton(
                                    onClick = {
                                        selectedOrganiserPayout=row
                                        organiserPayoutNextStatus="rejected"
                                        organiserPayoutProviderReference=""
                                        organiserPayoutNote=""
                                        organiserPayoutFormError=null
                                    },
                                    enabled=!busy
                                ) { Text("Reject",color=Danger,fontSize=10.sp) }
                            }
                            "processing" -> {
                                TextButton(
                                    onClick = {
                                        selectedOrganiserPayout=row
                                        organiserPayoutNextStatus="paid"
                                        organiserPayoutProviderReference=""
                                        organiserPayoutNote=""
                                        organiserPayoutFormError=null
                                    },
                                    enabled=!busy
                                ) { Text("Confirm paid",color=Teal,fontSize=10.sp) }
                                TextButton(
                                    onClick = {
                                        selectedOrganiserPayout=row
                                        organiserPayoutNextStatus="failed"
                                        organiserPayoutProviderReference=""
                                        organiserPayoutNote=""
                                        organiserPayoutFormError=null
                                    },
                                    enabled=!busy
                                ) { Text("Mark failed",color=Danger,fontSize=10.sp) }
                            }
                            "paid" -> TextButton(
                                onClick = {
                                    selectedOrganiserPayout=row
                                    organiserPayoutNextStatus="reversed"
                                    organiserPayoutProviderReference=""
                                    organiserPayoutNote=""
                                    organiserPayoutFormError=null
                                },
                                enabled=!busy
                            ) { Text("Record reversal",color=Danger,fontSize=10.sp) }
                        }
                    }
                }
            }
        }
        item {
            Text(
                "Verified refunds remain in finance review until ticket entitlement and organiser/platform settlement are reconciled. This screen does not issue automatic organiser payouts.",
                color=Muted,fontSize=10.sp,lineHeight=15.sp
            )
        }
    }

    if (showPayoutDialog) {
        val parsedPayoutAmount = if (payoutAmountEtb.isBlank()) null else runCatching {
            java.math.BigDecimal(payoutAmountEtb.trim())
                .movePointRight(2)
                .setScale(0, java.math.RoundingMode.UNNECESSARY)
                .longValueExact()
        }.getOrNull()
        AlertDialog(
            onDismissRequest = {
                if (!busy) {
                    showPayoutDialog = false
                    payoutAccountNumber = ""
                }
            },
            title = { Text("Withdraw platform revenue",color=Ink,fontWeight=FontWeight.Bold) },
            text = {
                Column(
                    modifier = Modifier.heightIn(max=480.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(9.dp)
                ) {
                    Text(
                        "Request a Chapa transfer from TIQET's platform balance to a verified bank or wallet account. The server checks available funds and retains the request for reconciliation.",
                        color=Muted,fontSize=10.sp,lineHeight=15.sp
                    )
                    OutlinedTextField(
                        value=payoutAmountEtb,
                        onValueChange={payoutAmountEtb=it;payoutFormError=null},
                        modifier=Modifier.fillMaxWidth(),
                        label={Text("Amount in ETB")},
                        placeholder={Text("Minimum 1.00")},
                        singleLine=true,
                        keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Decimal)
                    )
                    Box(Modifier.fillMaxWidth()) {
                        OutlinedButton(
                            onClick={ payoutMenuExpanded = true },
                            modifier=Modifier.fillMaxWidth(),
                            enabled=destinations.isNotEmpty()
                        ) {
                            Text(selectedDestination?.optString("name") ?: if(destinations.isEmpty()) "Loading payout destinations…" else "Choose bank or wallet")
                        }
                        DropdownMenu(
                            expanded=payoutMenuExpanded,
                            onDismissRequest={payoutMenuExpanded=false},
                            modifier=Modifier.heightIn(max=260.dp)
                        ) {
                            destinations.forEach { destination ->
                                DropdownMenuItem(
                                    text={Text(destination.optString("name") + " · " + destination.optString("type","bank"))},
                                    onClick={
                                        selectedDestinationSlug=destination.optString("slug")
                                        payoutMenuExpanded=false
                                        payoutFormError=null
                                    }
                                )
                            }
                        }
                    }
                    OutlinedTextField(
                        value=payoutAccountName,
                        onValueChange={payoutAccountName=it;payoutFormError=null},
                        modifier=Modifier.fillMaxWidth(),
                        label={Text("Account holder name")},
                        singleLine=true
                    )
                    OutlinedTextField(
                        value=payoutAccountNumber,
                        onValueChange={payoutAccountNumber=it.filter(Char::isDigit);payoutFormError=null},
                        modifier=Modifier.fillMaxWidth(),
                        label={Text("Bank or wallet account number")},
                        singleLine=true,
                        keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Number)
                    )
                    Text(
                        "Only the last four digits are stored by TIQET. Do not submit another withdrawal while an earlier request is pending or uncertain.",
                        color=Muted,fontSize=10.sp,lineHeight=14.sp
                    )
                    if (payoutFormError != null) Text(payoutFormError!!,color=Danger,fontSize=10.sp)
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val cleanName=payoutAccountName.trim()
                        val cleanNumber=payoutAccountNumber.trim()
                        when {
                            parsedPayoutAmount == null || parsedPayoutAmount < 100 ->
                                payoutFormError="Enter an amount with up to two decimal places (minimum ETB 1.00)."
                            selectedDestination == null ->
                                payoutFormError="Choose an active Chapa bank or wallet destination."
                            cleanName.length < 2 ->
                                payoutFormError="Enter the account holder name."
                            !cleanNumber.matches(Regex("^[0-9]{6,30}$")) ->
                                payoutFormError="Enter a valid account number (6 to 30 digits)."
                            else -> {
                                onCreatePlatformPayout(
                                    parsedPayoutAmount,
                                    selectedDestinationSlug,
                                    selectedDestination.optString("name"),
                                    cleanName,
                                    cleanNumber
                                )
                                showPayoutDialog=false
                                payoutAccountNumber=""
                            }
                        }
                    },
                    enabled=!busy,
                    colors=ButtonDefaults.buttonColors(containerColor=Ink)
                ) { Text("Submit withdrawal") }
            },
            dismissButton = {
                TextButton(
                    onClick={showPayoutDialog=false;payoutAccountNumber=""},
                    enabled=!busy
                ) { Text("Cancel",color=Muted) }
            },
            shape=RoundedCornerShape(20.dp),
            containerColor=CardWhite
        )
    }

    if (selectedOrganiserPayout != null) {
        val payout = selectedOrganiserPayout!!
        val finalAction = organiserPayoutNextStatus in listOf("paid", "reversed")
        AlertDialog(
            onDismissRequest = { if (!busy) selectedOrganiserPayout = null },
            title = {
                Text(
                    when (organiserPayoutNextStatus) {
                        "approved" -> "Approve payout request"
                        "rejected" -> "Reject payout request"
                        "processing" -> "Start payout processing"
                        "paid" -> "Confirm organiser payout"
                        "failed" -> "Record payout failure"
                        "reversed" -> "Record payout reversal"
                        else -> "Update payout request"
                    },
                    color=Ink,fontWeight=FontWeight.Bold
                )
            },
            text = {
                Column(verticalArrangement=Arrangement.spacedBy(9.dp)) {
                    Text(
                        "${payout.optString("organisation_name")} · ${amount(payout)}",
                        color=Muted,fontSize=11.sp
                    )
                    if (finalAction) {
                        OutlinedTextField(
                            value=organiserPayoutProviderReference,
                            onValueChange={organiserPayoutProviderReference=it;organiserPayoutFormError=null},
                            modifier=Modifier.fillMaxWidth(),
                            label={Text("Provider transaction reference")},
                            singleLine=true
                        )
                    }
                    OutlinedTextField(
                        value=organiserPayoutNote,
                        onValueChange={organiserPayoutNote=it;organiserPayoutFormError=null},
                        modifier=Modifier.fillMaxWidth(),
                        label={Text("Operator note / evidence")},
                        minLines=2,
                        maxLines=4
                    )
                    if (organiserPayoutNextStatus == "paid") {
                        Text(
                            "Only confirm payment after the provider or bank transfer is independently confirmed. This action posts the payout debit to the organiser settlement ledger.",
                            color=Danger,fontSize=10.sp,lineHeight=14.sp
                        )
                    } else if (organiserPayoutNextStatus == "reversed") {
                        Text(
                            "Only record a reversal after the provider confirms that the previously paid transfer was reversed. This restores the settlement balance.",
                            color=Danger,fontSize=10.sp,lineHeight=14.sp
                        )
                    }
                    if (organiserPayoutFormError != null) {
                        Text(organiserPayoutFormError!!,color=Danger,fontSize=10.sp)
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val note=organiserPayoutNote.trim()
                        val reference=organiserPayoutProviderReference.trim()
                        when {
                            note.length !in 5..500 -> organiserPayoutFormError="Enter a note between 5 and 500 characters."
                            finalAction && reference.length < 3 -> organiserPayoutFormError="Enter the provider transaction reference."
                            else -> {
                                onResolveOrganiserPayout(
                                    payout.optString("id"),
                                    organiserPayoutNextStatus,
                                    reference,
                                    note
                                )
                                selectedOrganiserPayout=null
                            }
                        }
                    },
                    enabled=!busy,
                    colors=ButtonDefaults.buttonColors(containerColor=Ink)
                ) { Text("Confirm") }
            },
            dismissButton = {
                TextButton(onClick={selectedOrganiserPayout=null},enabled=!busy) {
                    Text("Cancel",color=Muted)
                }
            },
            shape=RoundedCornerShape(20.dp),
            containerColor=CardWhite
        )
    }

    if (selectedPayment != null) {
        val payment = selectedPayment!!
        AlertDialog(
            onDismissRequest = { if (!busy) selectedPayment = null },
            title = { Text("Request Chapa refund",color=Ink,fontWeight=FontWeight.Bold) },
            text = {
                Column(verticalArrangement=Arrangement.spacedBy(9.dp)) {
                    Text(
                        "Payment ${payment.optString("merchant_reference")} · ${amount(payment)}",
                        color=Muted,fontSize=11.sp
                    )
                    OutlinedTextField(
                        value=amountEtb,
                        onValueChange={amountEtb=it;formError=null},
                        modifier=Modifier.fillMaxWidth(),
                        label={Text("Refund amount in ETB")},
                        placeholder={Text("Leave blank for full refund")},
                        singleLine=true,
                        keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Decimal)
                    )
                    OutlinedTextField(
                        value=reason,
                        onValueChange={reason=it;formError=null},
                        modifier=Modifier.fillMaxWidth(),
                        label={Text("Reason for refund")},
                        minLines=2,
                        maxLines=3
                    )
                    Text(
                        "Chapa must confirm this refund. TIQET will then keep the order in finance review until ticket and settlement reconciliation is complete.",
                        color=Muted,fontSize=10.sp,lineHeight=14.sp
                    )
                    if (formError != null) Text(formError!!,color=Danger,fontSize=10.sp)
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val cleanedReason = reason.trim()
                        val amountMinor = if (amountEtb.isBlank()) null else runCatching {
                            java.math.BigDecimal(amountEtb.trim())
                                .movePointRight(2)
                                .setScale(0, java.math.RoundingMode.UNNECESSARY)
                                .longValueExact()
                        }.getOrNull()
                        val invalidAmount = amountEtb.isNotBlank() && (amountMinor == null || amountMinor < 100)
                        if (cleanedReason.isBlank() || cleanedReason.length > 400) {
                            formError = "Enter a reason from 1 to 400 characters."
                        } else if (invalidAmount) {
                            formError = "Enter a valid ETB amount with up to two decimal places (minimum ETB 1.00)."
                        } else if (idempotencyKey.isBlank()) {
                            formError = "A safe request key could not be created. Close and reopen this form."
                        } else {
                            onRequestRefund(payment.optString("payment_id"),amountMinor,cleanedReason,idempotencyKey)
                            selectedPayment = null
                        }
                    },
                    enabled=!busy,
                    colors=ButtonDefaults.buttonColors(containerColor=Ink)
                ) { Text("Send refund request") }
            },
            dismissButton = {
                TextButton(onClick={selectedPayment=null},enabled=!busy) { Text("Cancel",color=Muted) }
            },
            shape=RoundedCornerShape(20.dp),
            containerColor=CardWhite
        )
    }
}

@Composable
private fun FinanceMetric(label: String, value: String, color: Color, modifier: Modifier = Modifier) {
    Column(modifier.clip(RoundedCornerShape(15.dp)).background(CardWhite).padding(13.dp)) {
        Text(label,color=Muted,fontSize=8.sp,fontWeight=FontWeight.Bold,letterSpacing=.7.sp)
        Spacer(Modifier.height(7.dp))
        Text(value,color=color,fontSize=18.sp,fontWeight=FontWeight.Bold,maxLines=2)
    }
}

@Composable
private fun FinanceSectionTitle(title: String, count: Int) {
    Row(verticalAlignment=Alignment.CenterVertically) {
        Text(title,color=Ink,fontSize=13.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f))
        Text(count.toString(),color=Muted,fontSize=10.sp)
    }
}

@Composable
private fun FinanceRecord(title: String, subtitle: String, reference: String, status: String) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(15.dp)).background(CardWhite).padding(13.dp)) {
        Row(verticalAlignment=Alignment.CenterVertically) {
            Text(title,color=Ink,fontSize=15.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f))
            StatusPill(status)
        }
        Text(subtitle,color=Muted,fontSize=10.sp)
        if(reference.isNotBlank()) Text(reference,color=Muted,fontSize=9.sp)
    }
}

@Composable
private fun StatusPill(status: String) {
    val good = status.lowercase() in listOf("paid","succeeded","verified","approved","reconciled","partially_refunded")
    Box(
        Modifier.clip(RoundedCornerShape(20.dp))
            .background(if(good) TealPale else AccentPale)
            .padding(horizontal=8.dp,vertical=4.dp)
    ) {
        Text(status.replace('_',' '),color=if(good) Teal else Accent,fontSize=9.sp,fontWeight=FontWeight.Bold)
    }
}

@Composable
private fun ActivityScreen(entries: JSONArray, busy: Boolean) {
    Column(Modifier.fillMaxSize().padding(horizontal=16.dp)) {
        ScreenHeading("Activity log", "A record of reviews and administrative access changes.")
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth(),color=Teal)
        if (entries.length()==0) EmptyState("No activity yet","Important administrative actions will appear here.")
        else LazyColumn(verticalArrangement=Arrangement.spacedBy(9.dp),contentPadding=PaddingValues(bottom=24.dp)) {
            items((0 until entries.length()).mapNotNull{entries.optJSONObject(it)},key={it.optString("id")}) { entry ->
                Column(Modifier.fillMaxWidth().background(CardWhite,RoundedCornerShape(14.dp)).padding(13.dp)) {
                    Text(entry.optString("action").replace('_',' '),color=Ink,fontSize=12.sp,fontWeight=FontWeight.Bold)
                    Text(entry.optString("actor_email"),color=Teal,fontSize=10.sp)
                    if(entry.optString("reason").isNotBlank()) Text(entry.optString("reason"),color=Muted,fontSize=11.sp)
                    Text(entry.optString("created_at").replace("T"," ").take(16),color=Muted,fontSize=9.sp)
                }
            }
        }
    }
}

@Composable
private fun ScreenHeading(title: String, subtitle: String) {
    Column(Modifier.padding(top=16.dp,bottom=12.dp)) {
        Text(title,color=Ink,fontSize=22.sp,fontWeight=FontWeight.Bold)
        Spacer(Modifier.height(4.dp))
        Text(subtitle,color=Muted,fontSize=11.sp,lineHeight=16.sp)
    }
}

@Composable
private fun EmptyState(title: String, subtitle: String) {
    Column(
        Modifier.fillMaxWidth().padding(vertical=36.dp),
        horizontalAlignment=Alignment.CenterHorizontally
    ) {
        Box(Modifier.size(42.dp).clip(CircleShape).background(TealPale),contentAlignment=Alignment.Center) {
            Text("✓",color=Teal,fontWeight=FontWeight.Bold,fontSize=18.sp)
        }
        Spacer(Modifier.height(12.dp))
        Text(title,color=Ink,fontWeight=FontWeight.SemiBold,fontSize=13.sp)
        Spacer(Modifier.height(3.dp))
        Text(subtitle,color=Muted,fontSize=10.sp)
    }
}

@Composable
private fun MessageStrip(message: String, isError: Boolean, onDismiss: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal=16.dp, vertical=5.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if(isError) AccentPale else TealPale)
            .padding(horizontal=12.dp,vertical=9.dp),
        verticalAlignment=Alignment.CenterVertically
    ) {
        Text(message,color=if(isError) Danger else Teal,fontSize=11.sp,modifier=Modifier.weight(1f))
        TextButton(onClick=onDismiss,contentPadding=PaddingValues(4.dp)) {
            Text("×",color=if(isError) Danger else Teal,fontSize=17.sp)
        }
    }
}
