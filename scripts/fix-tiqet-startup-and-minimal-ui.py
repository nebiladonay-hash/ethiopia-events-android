#!/usr/bin/env python3
"""Keep Tiqet launch responsive, simplify the entry UI, and bound auth retry behaviour."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
main_path = root / "app/src/main/java/et/events/mobile/MainActivity.kt"
api_path = root / "app/src/main/java/et/events/mobile/backend/TiqetApi.kt"


def skip_literal_or_comment(source: str, index: int) -> int | None:
    if source.startswith("//", index):
        end = source.find("\n", index)
        return len(source) if end < 0 else end
    if source.startswith("/*", index):
        depth, pos = 1, index + 2
        while pos < len(source) and depth:
            if source.startswith("/*", pos):
                depth += 1
                pos += 2
            elif source.startswith("*/", pos):
                depth -= 1
                pos += 2
            else:
                pos += 1
        if depth:
            raise SystemExit("Unclosed Kotlin comment.")
        return pos
    if source.startswith('"""', index):
        end = source.find('"""', index + 3)
        if end < 0:
            raise SystemExit("Unclosed Kotlin raw string.")
        return end + 3
    if source[index] == '"':
        pos = index + 1
        while pos < len(source):
            if source[pos] == "\\":
                pos += 2
            elif source[pos] == '"':
                return pos + 1
            else:
                pos += 1
        raise SystemExit("Unclosed Kotlin string.")
    if source[index] == "'":
        pos = index + 1
        while pos < len(source):
            if source[pos] == "\\":
                pos += 2
            elif source[pos] == "'":
                return pos + 1
            else:
                pos += 1
        raise SystemExit("Unclosed Kotlin character literal.")
    return None


def function_region(source: str, signature: str) -> tuple[int, int]:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f"Missing Kotlin function {signature}.")
    opening = source.find("{", start + len(signature))
    if opening < 0:
        raise SystemExit(f"Missing function body for {signature}.")
    depth, pos = 0, opening
    while pos < len(source):
        skipped = skip_literal_or_comment(source, pos)
        if skipped is not None:
            pos = skipped
            continue
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
            if depth == 0:
                return start, pos + 1
        pos += 1
    raise SystemExit(f"Unclosed function body for {signature}.")


def replace_function(source: str, signature: str, replacement: str) -> str:
    start, end = function_region(source, signature)
    return source[:start] + replacement.rstrip() + source[end:]


main = main_path.read_text()
height_import = "import androidx.compose.foundation.layout.height\n"
if main.count(height_import) != 1:
    raise SystemExit("MainActivity height import anchor missing or ambiguous.")
main = main.replace(height_import, height_import + "import androidx.compose.foundation.layout.heightIn\n", 1)

# Do not make a slow Spotlight call hold the entire Discover screen in its loading state.
# The live event list and curated banner rail load independently.
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

# Simplify the role chooser: equal neutral choices, restrained red accents, no oversized solid-red card.
role_chooser = r'''private fun RoleChooser(onChoose: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BrandIvory)
            .systemBarsPadding()
            .padding(horizontal = 24.dp, vertical = 26.dp)
    ) {
        BrandStamp()
        Spacer(Modifier.weight(0.85f))
        Text(
            "Make room for good plans.",
            color = Ink,
            fontSize = 29.sp,
            lineHeight = 34.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = (-0.7).sp
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "What would you like to do on Tiqet?",
            color = Muted,
            fontSize = 13.sp,
            lineHeight = 18.sp
        )
        Spacer(Modifier.height(27.dp))
        RoleCard(
            label = "Find events and book your tickets.",
            isBuyer = true,
            onClick = { onChoose("buyer") }
        )
        Spacer(Modifier.height(11.dp))
        RoleCard(
            label = "Publish events and manage ticket sales.",
            isBuyer = false,
            onClick = { onChoose("organizer") }
        )
        Spacer(Modifier.weight(1.15f))
        Text(
            "MADE FOR GOING OUT IN ETHIOPIA",
            color = Muted,
            fontSize = 9.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 1.1.sp
        )
    }
}
'''
main = replace_function(main, "private fun RoleChooser(", role_chooser)

role_card = r'''private fun RoleCard(label: String, isBuyer: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 94.dp)
            .clip(RoundedCornerShape(17.dp))
            .background(SoftIvory)
            .border(1.dp, Hairline, RoundedCornerShape(17.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 17.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                if (isBuyer) "Discover events" else "Organise events",
                color = Ink,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold
            )
            Spacer(Modifier.height(4.dp))
            Text(label, color = Muted, fontSize = 11.sp, lineHeight = 15.sp)
        }
        Spacer(Modifier.width(12.dp))
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(CircleShape)
                .background(BrandRed.copy(alpha = 0.08f)),
            contentAlignment = Alignment.Center
        ) {
            Text("→", color = BrandRed, fontSize = 17.sp, fontWeight = FontWeight.Medium)
        }
    }
}
'''
main = replace_function(main, "private fun RoleCard(", role_card)

if "api.fetchSpotlightEvents()" not in main:
    raise SystemExit("Independent Spotlight loader was not applied.")
if "private fun RoleChooser" not in main or 'Make room for good plans.' not in main:
    raise SystemExit("Minimal role chooser was not applied.")
main_path.write_text(main)

# Expired-token refresh must only retry once; repeated 401s can otherwise recurse indefinitely.
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

print("Discover and Spotlight now load independently; role selection is calmer and simpler; Supabase 401 refresh is limited to one retry.")
