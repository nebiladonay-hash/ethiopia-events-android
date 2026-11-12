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
