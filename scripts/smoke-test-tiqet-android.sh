#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_DIR:?PROJECT_DIR is not set}"
: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"

APK="$PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
test -s "$APK"

adb install -r "$APK"
adb logcat -c
adb shell am force-stop et.events.mobile || true
adb shell am start -W -n et.events.mobile/.MainActivity
sleep 3
adb shell pidof et.events.mobile >/dev/null

adb shell uiautomator dump /sdcard/tiqet-entry.xml >/dev/null
adb shell cat /sdcard/tiqet-entry.xml > "$RUNNER_TEMP/tiqet-entry.xml"
ENTRY_BOUNDS="$(python3 - "$RUNNER_TEMP/tiqet-entry.xml" <<'PY'
import re, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for node in root.iter("node"):
    if "discover and book events" in node.attrib.get("text", "").lower():
        match = re.search(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.attrib.get("bounds", ""))
        if match:
            left, top, right, bottom = map(int, match.groups())
            print((left + right) // 2, (top + bottom) // 2)
            raise SystemExit(0)
raise SystemExit("Tiqet buyer-entry option was not present in the first screen.")
PY
)"
read -r ENTRY_X ENTRY_Y <<< "$ENTRY_BOUNDS"
adb shell input tap "$ENTRY_X" "$ENTRY_Y"
sleep 2
adb shell pidof et.events.mobile >/dev/null

adb shell uiautomator dump /sdcard/tiqet-auth.xml >/dev/null
adb shell cat /sdcard/tiqet-auth.xml > "$RUNNER_TEMP/tiqet-auth.xml"
python3 - "$RUNNER_TEMP/tiqet-auth.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
texts = [node.attrib.get("text", "") for node in ET.parse(sys.argv[1]).getroot().iter("node")]
if not any("Welcome back" in value for value in texts):
    raise SystemExit("Tiqet did not reach the login screen after selecting buyer.")
if not any("Create an account" in value for value in texts):
    raise SystemExit("Tiqet signup action was not rendered on the login screen.")
PY

CREATE_BOUNDS="$(python3 - "$RUNNER_TEMP/tiqet-auth.xml" <<'PY'
import re, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for node in root.iter("node"):
    value = node.attrib.get("text", "")
    if "New to Tiqet?" in value and "Create an account" in value:
        match = re.search(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.attrib.get("bounds", ""))
        if match:
            left, top, right, bottom = map(int, match.groups())
            print((left + right) // 2, (top + bottom) // 2)
            raise SystemExit(0)
raise SystemExit("Could not locate the signup toggle.")
PY
)"
read -r CREATE_X CREATE_Y <<< "$CREATE_BOUNDS"
adb shell input tap "$CREATE_X" "$CREATE_Y"
sleep 2
adb shell pidof et.events.mobile >/dev/null

adb shell uiautomator dump /sdcard/tiqet-signup.xml >/dev/null
adb shell cat /sdcard/tiqet-signup.xml > "$RUNNER_TEMP/tiqet-signup.xml"
python3 - "$RUNNER_TEMP/tiqet-signup.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
texts = [node.attrib.get("text", "") for node in ET.parse(sys.argv[1]).getroot().iter("node")]
if not any("Create your account" in value for value in texts):
    raise SystemExit("Tiqet did not render the signup screen.")
PY

adb shell screencap -p /sdcard/tiqet-signup.png
adb pull /sdcard/tiqet-signup.png "$RUNNER_TEMP/tiqet-signup.png"

if adb logcat -d -t 5000 | grep -F -e "FATAL EXCEPTION" -e "Process: et.events.mobile"; then
  echo "Android runtime crash detected during launch/auth navigation."
  exit 1
fi

echo "Tiqet launched, opened login, and opened signup without a fatal runtime exception."
