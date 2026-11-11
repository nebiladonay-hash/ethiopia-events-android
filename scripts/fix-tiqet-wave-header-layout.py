#!/usr/bin/env python3
"""Make the shared Tiqet wave header full-bleed while keeping auth and organiser content inset."""
from pathlib import Path
import sys


def skip_quoted_or_comment(text: str, i: int) -> int | None:
    """Return the index after a Kotlin string/comment, or None when i starts normal code."""
    if text.startswith("//", i):
        end = text.find("\n", i)
        return len(text) if end < 0 else end
    if text.startswith("/*", i):
        depth = 1
        j = i + 2
        while j < len(text) and depth:
            if text.startswith("/*", j):
                depth += 1
                j += 2
            elif text.startswith("*/", j):
                depth -= 1
                j += 2
            else:
                j += 1
        if depth:
            raise SystemExit("Unclosed Kotlin block comment.")
        return j
    if text.startswith('"""', i):
        end = text.find('"""', i + 3)
        if end < 0:
            raise SystemExit("Unclosed Kotlin raw string.")
        return end + 3
    if text[i] == '"':
        j = i + 1
        while j < len(text):
            if text[j] == "\\":
                j += 2
            elif text[j] == '"':
                return j + 1
            else:
                j += 1
        raise SystemExit("Unclosed Kotlin string.")
    if text[i] == "'":
        j = i + 1
        while j < len(text):
            if text[j] == "\\":
                j += 2
            elif text[j] == "'":
                return j + 1
            else:
                j += 1
        raise SystemExit("Unclosed Kotlin character literal.")
    return None


def matching_delimiter(text: str, opening: int, left: str, right: str) -> int:
    if text[opening] != left:
        raise SystemExit(f"Expected {left!r} at source index {opening}.")
    depth = 0
    i = opening
    while i < len(text):
        skipped = skip_quoted_or_comment(text, i)
        if skipped is not None:
            i = skipped
            continue
        ch = text[i]
        if ch == left:
            depth += 1
        elif ch == right:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise SystemExit(f"Unclosed Kotlin delimiter {left}{right}.")


def find_root_column(text: str, function_name: str):
    fn = text.find(function_name)
    if fn < 0:
        raise SystemExit(f"Could not find {function_name}.")
    call = text.find("Column(", fn)
    if call < 0:
        raise SystemExit(f"Could not find root Column in {function_name}.")
    call_open = text.find("(", call)
    call_close = matching_delimiter(text, call_open, "(", ")")
    brace = call_close + 1
    while brace < len(text) and text[brace].isspace():
        brace += 1
    if brace >= len(text) or text[brace] != "{":
        raise SystemExit(f"Root Column in {function_name} does not have a content block.")
    return call, call_open, call_close, brace, matching_delimiter(text, brace, "{", "}")


def make_header_full_bleed(text: str, function_name: str, body_padding: str,
                           remove_root_padding: str | None = None,
                           remove_leading_spacer: bool = False) -> str:
    root_call, root_open, root_call_close, root_body, root_end = find_root_column(text, function_name)

    # Remove horizontal padding from the outer scroll container. This lets the Canvas header
    # measure against the actual screen width instead of the already-inset content width.
    if remove_root_padding:
        prefix = text[root_call:root_call_close + 1]
        if prefix.count(remove_root_padding) != 1:
            raise SystemExit(
                f"{function_name}: expected one root padding anchor {remove_root_padding!r}, "
                f"found {prefix.count(remove_root_padding)}."
            )
        prefix = prefix.replace(remove_root_padding, "", 1)
        text = text[:root_call] + prefix + text[root_call_close + 1:]
        root_call, root_open, root_call_close, root_body, root_end = find_root_column(text, function_name)

    header = text.find("TiqetWaveHeader(", root_body, root_end)
    if header < 0:
        raise SystemExit(f"{function_name}: TiqetWaveHeader call not found in root screen.")
    header_open = text.find("(", header)
    header_close = matching_delimiter(text, header_open, "(", ")")

    if remove_leading_spacer:
        before = text[max(root_body, header - 90):header]
        spacer = "        Spacer(Modifier.height(7.dp))\n"
        if before.endswith(spacer):
            at = header - len(spacer)
            text = text[:at] + text[header:]
            header -= len(spacer)
            header_open = text.find("(", header)
            header_close = matching_delimiter(text, header_open, "(", ")")
            # The outer block closes a little earlier after removing the spacer.
            root_call, root_open, root_call_close, root_body, root_end = find_root_column(text, function_name)

    # Add a padded inner content column after the header and close it before the root scroll column.
    inner_open = f"\n        Column(modifier = Modifier.fillMaxWidth().padding({body_padding})) {{"
    inner_close = "\n        }\n"
    text = text[:root_end] + inner_close + text[root_end:]
    text = text[:header_close + 1] + inner_open + text[header_close + 1:]
    return text


root = Path(sys.argv[1])
auth_path = root / "app/src/main/java/et/events/mobile/TiqetAuthScreen.kt"
organiser_path = root / "app/src/main/java/et/events/mobile/TiqetOrganizerScreen.kt"

auth = auth_path.read_text()
for import_line, new_line in (
    ("import androidx.compose.foundation.layout.height\n", "import androidx.compose.foundation.layout.height\nimport androidx.compose.foundation.layout.heightIn\n"),
    ("import androidx.compose.foundation.layout.padding\n", "import androidx.compose.foundation.layout.padding\nimport androidx.compose.foundation.rememberScrollState\nimport androidx.compose.foundation.verticalScroll\n"),
):
    if import_line not in auth:
        raise SystemExit(f"Auth layout import anchor missing: {import_line.strip()}")
    if new_line not in auth:
        auth = auth.replace(import_line, new_line, 1)

auth = make_header_full_bleed(
    auth,
    "fun TiqetAuthScreen",
    "horizontal = 24.dp, vertical = 20.dp",
    remove_root_padding=".padding(horizontal = 24.dp, vertical = 26.dp)",
)
# Keep the red wave at the top; centre the sign-up/login card beneath it.
auth = auth.replace(
    ".background(AuthIvory)",
    ".background(AuthIvory).verticalScroll(rememberScrollState())",
    1,
)
old_body = "Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 20.dp)) {"
new_body = """Column(
            modifier = Modifier.fillMaxWidth()
                .heightIn(min = 560.dp)
                .padding(horizontal = 24.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.Center
        ) {"""
if auth.count(old_body) != 1:
    raise SystemExit(f"Auth body column anchor expected once; found {auth.count(old_body)}")
auth = auth.replace(old_body, new_body, 1)
auth = auth.replace(
    "Create an organiser account. Publishing requires verification.",
    "Publish events straight away. Connect a settlement account to sell paid tickets.",
    1
)
auth_path.write_text(auth)

organiser = organiser_path.read_text()
organiser = make_header_full_bleed(
    organiser,
    "fun TiqetOrganizerScreen",
    "horizontal = 21.dp",
    remove_root_padding=".padding(horizontal = 21.dp)",
    remove_leading_spacer=True,
)
organiser_path.write_text(organiser)

for path in (auth_path, organiser_path):
    source = path.read_text()
    # Assert that header is still present, and the scroll-column root is no longer horizontally inset.
    if "TiqetWaveHeader(" not in source:
        raise SystemExit(f"Missing TiqetWaveHeader after layout update in {path.name}.")
    if path == auth_path and ".padding(horizontal = 24.dp, vertical = 26.dp)" in source:
        raise SystemExit("Auth root still applies horizontal padding around the wave header.")
    if path == organiser_path and ".padding(horizontal = 21.dp)" in source.split("TiqetWaveHeader(", 1)[0]:
        raise SystemExit("Organiser root still applies horizontal padding around the wave header.")

print("Tiqet wave headers are now edge-to-edge on organiser and sign-up/login screens; body content retains consistent horizontal gutters.")
