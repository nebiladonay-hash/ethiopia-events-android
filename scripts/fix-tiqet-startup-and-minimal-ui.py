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

def replace_function_by_braces(source: str, signature: str, replacement: str) -> str:
    fn_start = source.find(signature)
    if fn_start < 0:
        raise SystemExit(f"Missing source function: {signature}")
    annotation = source.rfind("@Composable", 0, fn_start)
    start = annotation if annotation >= 0 and fn_start - annotation < 50 else fn_start
    opening = source.find("{", fn_start + len(signature))
    if opening < 0:
        raise SystemExit(f"Missing body for source function: {signature}")
    depth = 0
    closing = -1
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                closing = index + 1
                break
    if closing < 0:
        raise SystemExit(f"Unbalanced body for source function: {signature}")
    return source[:start] + replacement.rstrip() + source[closing:]

main = replace_function_by_braces(main, "private fun RoleChooser(", role_chooser)
main = replace_function_by_braces(main, "private fun RoleCard(", role_card)

# The full-refresh patch removed the original ticket glyph while the restored cards still use it.
ticket_imports = [
    "import androidx.compose.foundation.Canvas\n",
    "import androidx.compose.ui.geometry.CornerRadius\n",
    "import androidx.compose.ui.geometry.Offset\n",
    "import androidx.compose.ui.geometry.Size\n",
    "import androidx.compose.ui.graphics.PathEffect\n",
    "import androidx.compose.ui.graphics.drawscope.Stroke\n",
]
for import_line in ticket_imports:
    if import_line not in main:
        if import_line.startswith("import androidx.compose.foundation."):
            anchor = "import androidx.compose.foundation.background\n"
        elif import_line.startswith("import androidx.compose.ui.geometry."):
            anchor = "import androidx.compose.ui.graphics.Color\n"
        else:
            anchor = "import androidx.compose.ui.graphics.PathEffect\n" if "drawscope" in import_line else "import androidx.compose.ui.geometry.Size\n"
        if main.count(anchor) != 1:
            raise SystemExit(f"Missing or ambiguous import insertion point: {anchor.strip()}")
        main = main.replace(anchor, anchor + import_line, 1)

if "private fun TicketMark(" not in main:
    ticket_mark = r'''@Composable
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

'''
    insert_at = main.find("private data class EventCardModel(")
    if insert_at < 0:
        raise SystemExit("Could not find EventCardModel insertion point for ticket glyph.")
    main = main[:insert_at] + ticket_mark + main[insert_at:]

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
