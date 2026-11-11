#!/usr/bin/env python3
"""Add organizer category quick-picks and use the selected verified organization."""
from pathlib import Path
import sys

organizer = Path(sys.argv[1]) / "app/src/main/java/et/events/mobile/TiqetOrganizerScreen.kt"

def replace_once(old: str, new: str, label: str) -> None:
    source = organizer.read_text()
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source anchor; found {count}")
    organizer.write_text(source.replace(old, new, 1))

replace_once(
    "import androidx.compose.foundation.background\n",
    "import androidx.compose.foundation.background\nimport androidx.compose.foundation.horizontalScroll\n",
    "Organizer horizontal-scroll import"
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
print("Organizer event form quick-picks added, including Boxing Matches.")
