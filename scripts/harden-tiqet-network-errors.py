#!/usr/bin/env python3
"""Harden Tiqet Android network errors, add retry UX, and keep signup usable with the keyboard."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
api_path = root / "app/src/main/java/et/events/mobile/backend/TiqetApi.kt"
auth_path = root / "app/src/main/java/et/events/mobile/TiqetAuthScreen.kt"
main_path = root / "app/src/main/java/et/events/mobile/MainActivity.kt"
organiser_path = root / "app/src/main/java/et/events/mobile/TiqetOrganizerScreen.kt"


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    source = path.read_text()
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source anchor; found {count}")
    path.write_text(source.replace(old, new, 1))


def replace_message_expressions(path: Path, api_name: str) -> None:
    source = path.read_text()
    pattern = re.compile(
        r'(?P<lhs>\b(?:error|eventLoadError|bookingError|problem)\s*=\s*)'
        r'(?P<receiver>exception|error)\.message\s*\?:\s*'
        r'(?P<fallback>"(?:\\.|[^"\\])*")'
    )
    updated, count = pattern.subn(
        lambda m: f'{m.group("lhs")}{api_name}.userFacingError({m.group("receiver")}, {m.group("fallback")})',
        source
    )
    path.write_text(updated)
    print(f"{path.name}: converted {count} raw exception-message assignments")


# One user-facing error mapper is shared by auth, discovery, checkout and organiser flows.
api = api_path.read_text()
api = replace_once_text = api.replace(
    "import java.net.HttpURLConnection\n",
    "import java.net.HttpURLConnection\nimport java.net.UnknownHostException\nimport java.net.SocketTimeoutException\nimport java.net.ConnectException\nimport javax.net.ssl.SSLException\nimport java.util.Locale\n",
    1
)
if "fun userFacingError(error: Throwable, fallback: String): String" not in api:
    anchor = "    fun isConfigured(): Boolean = BuildConfig.SUPABASE_URL.isNotBlank() && BuildConfig.SUPABASE_ANON_KEY.isNotBlank()\n"
    if api.count(anchor) != 1:
        raise SystemExit("TiqetApi user-facing error insertion point missing or ambiguous.")
    mapper = """
    /** Converts technical HTTP/transport errors into clear, non-sensitive customer guidance. */
    fun userFacingError(error: Throwable, fallback: String): String {
        val apiError = error as? ApiException
        val message = apiError?.message.orEmpty().lowercase(Locale.US)
        val status = apiError?.httpCode
        return when {
            error is UnknownHostException || error is ConnectException ||
                message.contains("unknownhostexception") || message.contains("unable to resolve host") ||
                message.contains("no address associated with hostname") || message.contains("failed to connect") ||
                message.contains("network is unreachable") || message.contains("connection reset") ->
                "Couldn't connect to Tiqet. Check your internet connection and try again."
            error is SocketTimeoutException || message.contains("sockettimeoutexception") ||
                message.contains("timed out") ->
                "Tiqet is taking too long to respond. Check your connection and try again."
            error is SSLException || message.contains("sslhandshake") || message.contains("certpath") ->
                "A secure connection couldn't be made. Check your phone's date and time, then try again."
            message.contains("invalid login credentials") || message.contains("invalid_credentials") ->
                "That email and password don't match. Check them and try again."
            message.contains("email not confirmed") ->
                "Please confirm your email using the link we sent you."
            message.contains("otp_expired") || message.contains("email link is invalid") ||
                (message.contains("email confirmation") && message.contains("expired")) ->
                "This confirmation link has expired. Request a new confirmation email."
            message.contains("user already registered") || message.contains("already registered") ->
                "An account with this email already exists. Sign in instead."
            message.contains("password") && (message.contains("weak") || message.contains("characters")) ->
                "Choose a stronger password and try again."
            status == 401 ->
                "Your session has expired. Sign in again to continue."
            status == 403 ->
                "This account doesn't have permission to do that."
            status == 404 ->
                "This Tiqet feature is temporarily unavailable. Please try again shortly."
            status == 409 ->
                "This request has already been processed or needs a quick check. Refresh and try again."
            status == 422 ->
                "Some details need to be corrected. Check the form and try again."
            status == 429 ->
                "Too many attempts. Wait a moment, then try again."
            status != null && status >= 500 ->
                "Tiqet is temporarily unavailable. Please try again shortly."
            apiError != null && status == null ->
                apiError.message?.takeIf { it.isNotBlank() } ?: fallback
            else -> fallback
        }
    }

"""
    api = api.replace(anchor, anchor + mapper, 1)
api_path.write_text(api)

# Auth: never show backend exception strings; keep the card centred and let it scroll above the keyboard.
replace_message_expressions(auth_path, "api")
replace_once(
    auth_path,
    'import androidx.compose.foundation.layout.height\n',
    'import androidx.compose.foundation.layout.height\nimport androidx.compose.foundation.layout.imePadding\n',
    "Auth IME import"
)
replace_once(
    auth_path,
    '.background(AuthIvory).verticalScroll(rememberScrollState())',
    '.background(AuthIvory).imePadding().verticalScroll(rememberScrollState())',
    "Auth keyboard-safe scroll modifier"
)
auth_source = auth_path.read_text()
auth_source = auth_source.replace(
    "The Tiqet backend is not connected yet. Configure SUPABASE_URL and SUPABASE_ANON_KEY in the repository's GitHub Actions variables, then rebuild the APK.",
    "Tiqet couldn't connect just now. Check your internet connection and try again. If it keeps happening, contact support.",
    1
)
auth_path.write_text(auth_source)

# Customer app: mapped messages for callback, event list, checkout and tickets.
replace_message_expressions(main_path, "api")
replace_once(
    main_path,
    'error.message ?: "Tiqet could not complete email confirmation."',
    'tiqetApi.userFacingError(error, "Tiqet could not complete email confirmation.")',
    "Auth callback toast error"
)

# Make Discover retryable without forcing the user to leave/relaunch the app.
main = main_path.read_text()
def main_replace(old: str, new: str, label: str):
    global main
    count = main.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source anchor; found {count}")
    main = main.replace(old, new, 1)

main_replace(
    '    var eventLoadError by remember { mutableStateOf("") }\n    var isLoadingEvents by remember { mutableStateOf(true) }\n    LaunchedEffect(api) {',
    '    var eventLoadError by remember { mutableStateOf("") }\n    var isLoadingEvents by remember { mutableStateOf(true) }\n    var eventReloadKey by remember { mutableStateOf(0) }\n    LaunchedEffect(api, eventReloadKey) {',
    "Discover refresh state"
)
main_replace(
    '                        loadError = eventLoadError,\n                        savedIds = savedIds,',
    '                        loadError = eventLoadError,\n                        onRetry = { eventReloadKey += 1 },\n                        savedIds = savedIds,',
    "Pass Discover retry callback"
)
main_replace(
    '    loadError: String,\n    onSearchChange: (String) -> Unit,',
    '    loadError: String,\n    onRetry: () -> Unit,\n    onSearchChange: (String) -> Unit,',
    "DiscoverScreen retry signature"
)
main_replace(
    '            } else if (filtered.isEmpty()) {\n                EmptyMessage(if (loadError.isNotBlank()) "Events could not be loaded: $loadError" else "No published events are available yet.")\n            } else {',
    '''            } else if (filtered.isEmpty()) {
                if (loadError.isNotBlank()) {
                    Column(
                        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                            .background(SoftIvory).border(1.dp, Hairline, RoundedCornerShape(16.dp)).padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(9.dp)
                    ) {
                        Text("Couldn't load events", color = Ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        Text(loadError, color = Muted, fontSize = 12.sp, lineHeight = 17.sp)
                        RedActionButton("Try again", onRetry, Modifier.width(145.dp))
                    }
                } else {
                    EmptyMessage("No published events are available yet.")
                }
            } else {''',
    "Replace raw Discover error state with retry card"
)
main_replace(
    '    var tickets by remember { mutableStateOf(emptyList<TiqetApi.Ticket>()) }\n    var loading by remember { mutableStateOf(true) }\n    var problem by remember { mutableStateOf("") }\n    LaunchedEffect(api) {\n        try {',
    '    var tickets by remember { mutableStateOf(emptyList<TiqetApi.Ticket>()) }\n    var loading by remember { mutableStateOf(true) }\n    var problem by remember { mutableStateOf("") }\n    var ticketReloadKey by remember { mutableStateOf(0) }\n    LaunchedEffect(api, ticketReloadKey) {\n        loading = true\n        problem = ""\n        try {',
    "Tickets refresh state"
)
main_replace(
    '            problem.isNotBlank() -> EmptyMessage(problem)\n',
    '''            problem.isNotBlank() -> Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                    .background(SoftIvory).border(1.dp, Hairline, RoundedCornerShape(16.dp)).padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(9.dp)
            ) {
                Text("Couldn't load your tickets", color = Ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text(problem, color = Muted, fontSize = 12.sp, lineHeight = 17.sp)
                RedActionButton("Try again", { ticketReloadKey += 1 }, Modifier.width(145.dp))
            }
''',
    "Replace Tickets raw error with retry card"
)
main_path.write_text(main)

# Organizer: clean connection/auth errors in ticket scan, settlement, applications and event creation.
replace_message_expressions(organiser_path, "api")

# The instant-publish transformer inserts a banner upload fallback string; clean the generated Kotlin too.
organiser_source = organiser_path.read_text()
banner_error = 'bannerError.message ?: "try again from Your event records"'
friendly_banner_error = 'api.userFacingError(bannerError, "try again from Your event records")'
if banner_error in organiser_source:
    organiser_path.write_text(organiser_source.replace(banner_error, friendly_banner_error, 1))

# Defensive assertions: no raw error body should be assigned to onboarding fields.
checks = {
    auth_path: [r'error\s*=\s*exception\.message', r'Text\(error,.*exception\.message'],
    main_path: [r'(eventLoadError|bookingError|problem)\s*=\s*(error|exception)\.message'],
    organiser_path: [r'error\s*=\s*exception\.message'],
}
for path, patterns in checks.items():
    data = path.read_text()
    for pattern in patterns:
        if re.search(pattern, data):
            raise SystemExit(f"Raw server error assignment remains in {path.name}: {pattern}")

print("Tiqet Android network messaging, signup keyboard handling and Discover retry are applied.")
