#!/usr/bin/env python3
"""Keep Tiqet launch responsive without replacing the established red/ivory wave UI."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
main_path = root / "app/src/main/java/et/events/mobile/MainActivity.kt"
api_path = root / "app/src/main/java/et/events/mobile/backend/TiqetApi.kt"

main = main_path.read_text()

# Preserve the original Tiqet role chooser and ticket cards. Do not restyle them here.
# This script only decouples Spotlight loading from the main event request.
spotlight_pattern = re.compile(
    r'(?ms)^(?P<indent>[ \t]*)spotlightEvents = try \{\n'
    r'.*?^(?P=indent)eventLoadError = ""\n'
)
main, count = spotlight_pattern.subn(
    lambda match: match.group("indent") + 'eventLoadError = ""\n',
    main,
    count=1
)
if count != 1:
    raise SystemExit("Could not isolate Spotlight loading from the main Discover load.")

selected_tab = '    var selectedTab by remember { mutableStateOf(BuyerTab.DISCOVER) }'
spotlight_effect = r'''
    LaunchedEffect(api) {
        spotlightEvents = try {
            withContext(Dispatchers.IO) {
                api.fetchSpotlightEvents().map { featured ->
                    val event = featured.event
                    EventCardModel(
                        id = event.id,
                        title = event.title,
                        description = event.description,
                        category = event.category,
                        date = formatAddisDate(event.startsAt),
                        venue = listOf(event.venueName, event.city).filter { it.isNotBlank() }.joinToString(" · "),
                        price = event.minimumPriceEtb ?: 0.0,
                        ticketName = event.ticketTypeName ?: "Admission",
                        tag = "SPOTLIGHT",
                        ticketTypeId = event.ticketTypeId,
                        imageUrl = event.imageUrl,
                        featuredLabel = featured.featuredLabel
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

'''
if main.count(selected_tab) != 1:
    raise SystemExit("BuyerApp selected-tab insertion point is missing or ambiguous.")
main = main.replace(selected_tab, spotlight_effect + selected_tab, 1)

# Restore the established Tiqet red/ivory role chooser and ticket cards after the older UI patch.
role_chooser = r'''@Composable
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
'''

role_card = r'''@Composable
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
'''

main, role_count = re.subn(
    r'(?ms)(?:@Composable\s+)?private fun RoleChooser\(.*?(?=(?:@Composable\s+)?private fun RoleCard\()',
    role_chooser + "\n",
    main,
    count=1
)
if role_count != 1:
    raise SystemExit(f"Could not restore original RoleChooser; matches={role_count}.")
# Replace RoleCard by matching its Kotlin block so nested click/layout lambdas are preserved.
role_signature = "private fun RoleCard("
role_start = main.find(role_signature)
if role_start < 0:
    raise SystemExit("Original RoleCard function is missing.")
annotation_start = main.rfind("@Composable", 0, role_start)
if annotation_start < 0 or role_start - annotation_start > 40:
    annotation_start = role_start
opening = main.find("{", role_start + len(role_signature))
if opening < 0:
    raise SystemExit("Original RoleCard body is missing.")
depth = 0
closing = -1
for index in range(opening, len(main)):
    if main[index] == "{":
        depth += 1
    elif main[index] == "}":
        depth -= 1
        if depth == 0:
            closing = index + 1
            break
if closing < 0:
    raise SystemExit("Original RoleCard body is not balanced.")
main = main[:annotation_start] + role_card + main[closing:]


# Fail the build if a future edit silently swaps out the original Tiqet entry UI.
if "private fun RoleChooser" not in main or "I'm here to discover and book events." not in main:
    raise SystemExit("Original Tiqet role chooser text is missing; refusing an unintended entry UI replacement.")
if "private fun RoleCard" not in main or "TicketMark(color = foreground" not in main:
    raise SystemExit("Original Tiqet red/ivory ticket cards are missing.")
if 'Make room for good plans.' in main:
    raise SystemExit("Unapproved minimalist role-chooser replacement detected.")
main_path.write_text(main)

# Expired-token refresh gets one retry only, never an unbounded recursive retry.
api = api_path.read_text()
old_signature = '''        useSession: Boolean = true,
        prefer: String? = null
    ): JSONObject {'''
new_signature = '''        useSession: Boolean = true,
        prefer: String? = null,
        retryAuth: Boolean = true
    ): JSONObject {'''
if api.count(old_signature) != 1:
    raise SystemExit(f"Request signature anchor expected once; found {api.count(old_signature)}.")
api = api.replace(old_signature, new_signature, 1)

old_auth = '''                if (code == 401 && useSession && currentSession() != null) {
                    val refreshed = refreshSession()
                    if (refreshed != null) return request(method, path, body, true, prefer)
                }'''
new_auth = '''                if (code == 401 && useSession && retryAuth && currentSession() != null) {
                    val refreshed = refreshSession()
                    if (refreshed != null) return request(method, path, body, true, prefer, retryAuth = false)
                }'''
if api.count(old_auth) != 1:
    raise SystemExit(f"401 retry anchor expected once; found {api.count(old_auth)}.")
api = api.replace(old_auth, new_auth, 1)
api_path.write_text(api)

print("Original Tiqet red/ivory ticket-card UI preserved; Spotlight loads independently; Supabase 401 refresh is bounded to one retry.")
