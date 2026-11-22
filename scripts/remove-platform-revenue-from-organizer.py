#!/usr/bin/env python3
"""Keep TIQET platform revenue and withdrawals exclusively inside TIQET Control."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
organizer = root / "app/src/main/java/et/events/mobile/TiqetOrganizerScreen.kt"
api = root / "app/src/main/java/et/events/mobile/backend/TiqetApi.kt"


def remove_once(source: str, old: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source match; found {count}")
    return source.replace(old, "", 1)


source = organizer.read_text()

# These are platform-owner-only controls and have no place in the organizer app.
for declaration in (
    '    var ownerRevenue by remember { mutableStateOf(JSONObject()) }\n',
    '    var ownerCashoutAmount by remember { mutableStateOf("") }\n',
    '    var ownerCashoutBankSlug by remember { mutableStateOf("") }\n',
    '    var ownerCashoutAccountName by remember { mutableStateOf("") }\n',
    '    var ownerCashoutAccountNumber by remember { mutableStateOf("") }\n',
):
    source = remove_once(source, declaration, "Remove platform revenue state")

source = remove_once(
    source,
    '                try { ownerRevenue = withContext(Dispatchers.IO) { api.fetchPlatformRevenueSummary() } } catch (_: Exception) { ownerRevenue = JSONObject() }\n',
    "Remove platform-owner revenue fetch from organizer refresh",
)

# The entire owner-revenue card sits immediately before the normal organizer loading state.
start_marker = '        if (ownerRevenue.optBoolean("is_owner")) {\n'
end_marker = '        if (loading) {\n'
start = source.find(start_marker)
if start < 0:
    raise SystemExit("Platform revenue card was not found in organizer workspace.")
end = source.find(end_marker, start + len(start_marker))
if end < 0:
    raise SystemExit("Could not locate the organizer loading section after the platform revenue card.")
card_block = source[start:end]
if "Withdraw Tiqet revenue" not in card_block or "withdrawPlatformRevenue" not in card_block:
    raise SystemExit("The matched organizer block is not the complete platform withdrawal card.")
source = source[:start] + source[end:]

if "Locale." not in source:
    source = source.replace("import java.util.Locale\n", "")
organizer.write_text(source)

# Remove the platform-owner-only API methods from the customer/organizer client.
api_source = api.read_text()
api_start_marker = "    fun fetchPlatformRevenueSummary(): JSONObject {\n"
api_end_marker = "    fun checkInTicket("
api_start = api_source.find(api_start_marker)
if api_start < 0:
    raise SystemExit("Platform revenue summary client method was not found.")
api_end = api_source.find(api_end_marker, api_start + len(api_start_marker))
if api_end < 0:
    raise SystemExit("Could not locate the next API method after the platform withdrawal methods.")
api_block = api_source[api_start:api_end]
if "withdrawPlatformRevenue" not in api_block or "create-platform-payout" not in api_block:
    raise SystemExit("The matched API range does not contain the platform withdrawal methods.")
api_source = api_source[:api_start] + api_source[api_end:]
for forbidden in ("fetchPlatformRevenueSummary", "withdrawPlatformRevenue", "platform-revenue-summary", "create-platform-payout"):
    if forbidden in api_source:
        raise SystemExit(f"Organizer API still contains platform-owner operation: {forbidden}")
api.write_text(api_source)

for forbidden in ("TIQET PLATFORM REVENUE", "fetchPlatformRevenueSummary", "withdrawPlatformRevenue", "Withdraw Tiqet revenue"):
    if forbidden in source:
        raise SystemExit(f"Organizer workspace still contains platform-owner UI: {forbidden}")

print("Removed TIQET platform revenue summary and withdrawal controls from the organizer app; organizer settlement tools are unchanged.")
