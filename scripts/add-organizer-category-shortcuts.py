#!/usr/bin/env python3
"""Add organizer category quick-picks and bind banner upload to the event's organization."""
from pathlib import Path
import sys

organizer = Path(sys.argv[1]) / "app/src/main/java/et/events/mobile/TiqetOrganizerScreen.kt"


def replace_once(old: str, new: str, label: str) -> None:
    source = organizer.read_text()
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source anchor; found {count}")
    organizer.write_text(source.replace(old, new, 1))


# The main Spotlight transformer adds this state next to selectedBannerEventId.
replace_once(
    "    var selectedBannerEventId by remember { mutableStateOf<String?>(null) }\n",
    "    var selectedBannerEventId by remember { mutableStateOf<String?>(null) }\n"
    "    var selectedBannerOrganisationId by remember { mutableStateOf<String?>(null) }\n",
    "Selected banner organization state"
)

# The organizer UI may manage multiple organizations. Use the organization on
# the specific event row, then let storage RLS and the assignment RPC verify ownership.
replace_once(
    "        val organisationId = verifiedOrganisationId\n",
    "        val organisationId = selectedBannerOrganisationId\n",
    "Use event-specific organization for banner upload"
)
replace_once(
    '                            selectedBannerEventId = event.optString("id")\n',
    '                            selectedBannerEventId = event.optString("id")\n'
    '                            selectedBannerOrganisationId = event.optString("organisation_id")\n',
    "Bind upload to event organization"
)
replace_once(
    "enabled = !working && !verifiedOrganisationId.isNullOrBlank(),",
    'enabled = !working && event.optString("organisation_id").isNotBlank() && event.optString("organisation_id") != "null",',
    "Enable banner upload for events with an organization ID"
)

# Add quick-picks after the event title input. The existing Category field remains
# present and receives the selected value through eventCategory.
replace_once(
    '            OrgField("Event title", eventTitle, { eventTitle = it })\n',
    '            OrgField("Event title", eventTitle, { eventTitle = it })\n'
    '            Row(\n'
    '                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),\n'
    '                horizontalArrangement = Arrangement.spacedBy(6.dp)\n'
    '            ) {\n'
    '                listOf("Music", "Boxing Matches", "Culture", "Nightlife", "Sports", "Conference").forEach { category ->\n'
    '                    Button(\n'
    '                        onClick = { eventCategory = category },\n'
    '                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 10.dp, vertical = 5.dp),\n'
    '                        colors = ButtonDefaults.buttonColors(\n'
    '                            containerColor = if (eventCategory == category) OrgRed else Color.White,\n'
    '                            contentColor = if (eventCategory == category) Color.White else OrgInk\n'
    '                        )\n'
    '                    ) { Text(category, fontSize = 10.sp) }\n'
    '                }\n'
    '            }\n'
    '            Spacer(Modifier.height(7.dp))\n',
    "Organizer category quick-picks including Boxing Matches"
)

# Add the horizontal-scroll layout import, leaving existing scroll-state import intact.
replace_once(
    "import androidx.compose.foundation.background\n",
    "import androidx.compose.foundation.background\nimport androidx.compose.foundation.horizontalScroll\n",
    "Organizer horizontal-scroll import"
)

print("Organizer category quick-picks and event-scoped organizer banner uploads applied.")
