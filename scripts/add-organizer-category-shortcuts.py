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
replace_once(
    """        val currentOrganisation = organisations.optJSONObject(0)
        val organisationId = currentOrganisation?.takeIf { it.optString("status") == "verified" }?.optString("id")""",
    """        val organisationId = verifiedOrganisationId""",
    "Use selected verified organization for banner upload"
)
replace_once(
    """            OrgField("Category", eventCategory, { eventCategory = it })
            OrgField("Description", eventDescription, { eventDescription = it }, singleLine = false)""",
    """            OrgField("Category", eventCategory, { eventCategory = it })
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
            OrgField("Description", eventDescription, { eventDescription = it }, singleLine = false)""",
    "Organizer category quick-picks including Boxing Matches"
)

print("Organizer event form now includes Boxing Matches and banner upload uses the selected verified organization.")
