#!/usr/bin/env python3
"""Add organizer category quick-picks and bind banner uploads to each event's organization."""
from pathlib import Path
import re
import sys

organizer = Path(sys.argv[1]) / "app/src/main/java/et/events/mobile/TiqetOrganizerScreen.kt"


def replace_once(old: str, new: str, label: str) -> None:
    source = organizer.read_text()
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source anchor; found {count}")
    organizer.write_text(source.replace(old, new, 1))


def regex_replace_once(pattern: str, replacement: str, label: str) -> None:
    source = organizer.read_text()
    updated, count = re.subn(pattern, replacement, source, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source line; found {count}")
    organizer.write_text(updated)


replace_once(
    "import androidx.compose.foundation.background\n",
    "import androidx.compose.foundation.background\nimport androidx.compose.foundation.horizontalScroll\n",
    "Organizer horizontal-scroll import"
)
replace_once(
    "    var selectedBannerEventId by remember { mutableStateOf<String?>(null) }\n",
    "    var selectedBannerEventId by remember { mutableStateOf<String?>(null) }\n"
    "    var selectedBannerOrganisationId by remember { mutableStateOf<String?>(null) }\n",
    "Selected banner organization state"
)
replace_once(
    "        val organisationId = verifiedOrganisationId\n",
    "        val organisationId = selectedBannerOrganisationId\n",
    "Use event-specific organization for banner upload"
)

regex_replace_once(
    r'^(\s*)selectedBannerEventId = event\.optString\("id"\)\s*$',
    r'\1selectedBannerEventId = event.optString("id")\n'
    r'\1selectedBannerOrganisationId = event.optString("organisation_id")',
    "Bind upload to event organization"
)
regex_replace_once(
    r'^(\s*)enabled = !working && !verifiedOrganisationId\.isNullOrBlank\(\),\s*$',
    r'\1enabled = !working && event.optString("organisation_id").isNotBlank() && event.optString("organisation_id") != "null",',
    "Enable upload only for event rows with an organization ID"
)

source = organizer.read_text()
lines = source.splitlines()
matches = [i for i, line in enumerate(lines) if 'OrgField("Event title"' in line]
if len(matches) != 1:
    context = [line for line in lines if "eventTitle" in line or "Event title" in line]
    raise SystemExit(
        f"Organizer category quick-picks: expected one event-title field; found {len(matches)}. "
        f"event-title references: {context}"
    )
index = matches[0]
indent = lines[index][:len(lines[index]) - len(lines[index].lstrip())]
block = [
    indent + 'Row(',
    indent + '    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),',
    indent + '    horizontalArrangement = Arrangement.spacedBy(6.dp)',
    indent + ') {',
    indent + '    listOf("Music", "Boxing Matches", "Culture", "Nightlife", "Sports", "Conference").forEach { category ->',
    indent + '        Button(',
    indent + '            onClick = { eventCategory = category },',
    indent + '            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 10.dp, vertical = 5.dp),',
    indent + '            colors = ButtonDefaults.buttonColors(',
    indent + '                containerColor = if (eventCategory == category) OrgRed else Color.White,',
    indent + '                contentColor = if (eventCategory == category) Color.White else OrgInk',
    indent + '            )',
    indent + '        ) { Text(category, fontSize = 10.sp) }',
    indent + '    }',
    indent + '}',
    indent + 'Spacer(Modifier.height(7.dp))',
]
lines[index + 1:index + 1] = block
organizer.write_text("\n".join(lines) + "\n")
print("Organizer category quick-picks and event-scoped banner uploads applied.")
