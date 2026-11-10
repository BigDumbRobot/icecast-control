#!/bin/bash
# Installs the Icecast Control plugin (a script) into OBS.
# Double-click this file. It copies the script, adds it to every OBS scene collection,
# and reopens OBS. Each scene collection is backed up first (*.json.before-icecast-control).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OBS_ID="com.obsproject.obs-studio"
OBS_DIR="$HOME/Library/Application Support/obs-studio"
SCRIPT_NAME="icecast-control-obs.lua"
TARGET="$OBS_DIR/scripts/$SCRIPT_NAME"

say_dialog() { # message [icon]
    osascript -e "display dialog \"$1\" with title \"Icecast Control OBS Plugin\" buttons {\"OK\"} default button 1 with icon ${2:-note}" >/dev/null 2>&1
}

echo "Installing the Icecast Control OBS plugin…"

if [[ -z "$(mdfind "kMDItemCFBundleIdentifier == '$OBS_ID'" | head -1)" && ! -d /Applications/OBS.app ]]; then
    say_dialog "OBS isn't installed. Install OBS from obsproject.com, open it once, then run this installer again." caution
    exit 1
fi
if [[ ! -d "$OBS_DIR/basic/scenes" ]]; then
    say_dialog "OBS hasn't been set up yet. Open OBS once, then run this installer again." caution
    exit 1
fi

# OBS rewrites its settings while it's open, so it has to close for a moment.
WAS_RUNNING=0
if pgrep -xq OBS; then
    WAS_RUNNING=1
    ANSWER=$(osascript -e 'button returned of (display dialog "OBS needs to close for a moment to add the plugin. It will reopen by itself.\n\nIf OBS is streaming or recording, it will ask you first." with title "Icecast Control OBS Plugin" buttons {"Cancel", "Close & Reopen OBS"} default button 2)' 2>/dev/null)
    [[ "$ANSWER" == "Close & Reopen OBS" ]] || { echo "Cancelled."; exit 0; }
    osascript -e "tell application id \"$OBS_ID\" to quit" >/dev/null 2>&1
    for _ in $(seq 1 120); do pgrep -xq OBS || break; sleep 0.5; done
    if pgrep -xq OBS; then
        say_dialog "OBS didn't close, so nothing was changed. Close OBS yourself and run this installer again." caution
        exit 1
    fi
fi

mkdir -p "$OBS_DIR/scripts"
cp "$HERE/$SCRIPT_NAME" "$TARGET"

# Add the script to each scene collection (JSON edit done with macOS's built-in JavaScript).
RESULT=$(osascript -l JavaScript - "$OBS_DIR/basic/scenes" "$TARGET" <<'JS'
ObjC.import('Foundation');
function run(argv) {
    const folder = argv[0], scriptPath = argv[1];
    const fm = $.NSFileManager.defaultManager;
    const names = ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError(folder, null)) || [];
    const entry = JSON.stringify({ path: scriptPath, settings: {} });
    let added = 0, already = 0, failed = 0;
    for (const name of names) {
        if (!name.endsWith('.json')) continue;
        const file = folder + '/' + name;
        const text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null));
        if (!text) { failed++; continue; }
        if (text.includes(scriptPath)) { already++; continue; }
        let updated;
        if (/"scripts-tool"\s*:\s*\[\s*\]/.test(text)) {
            updated = text.replace(/"scripts-tool"\s*:\s*\[\s*\]/, '"scripts-tool": [' + entry + ']');
        } else if (/"scripts-tool"\s*:\s*\[/.test(text)) {
            updated = text.replace(/"scripts-tool"\s*:\s*\[/, '"scripts-tool": [' + entry + ', ');
        } else {
            const json = JSON.parse(text);
            json.modules = json.modules || {};
            json.modules['scripts-tool'] = [JSON.parse(entry)];
            updated = JSON.stringify(json, null, 4);
        }
        try { JSON.parse(updated); } catch (e) { failed++; continue; }
        const backup = file + '.before-icecast-control';
        if (!fm.fileExistsAtPath(backup)) fm.copyItemAtPathToPathError(file, backup, null);
        $(updated).writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null);
        added++;
    }
    return added + ' ' + already + ' ' + failed;
}
JS
)
read -r ADDED ALREADY FAILED <<< "${RESULT:-0 0 1}"
echo "Scene collections: $ADDED updated, $ALREADY already had it, $FAILED skipped."

if [[ $WAS_RUNNING == 1 ]]; then open -b "$OBS_ID"; fi

if [[ "${FAILED:-0}" != "0" && "${ADDED:-0}" == "0" && "${ALREADY:-0}" == "0" ]]; then
    say_dialog "The plugin file was copied, but it couldn't be added to OBS automatically.\n\nIn OBS: Tools → Scripts → + and choose $SCRIPT_NAME (in Library/Application Support/obs-studio/scripts)." caution
    exit 1
fi
say_dialog "The Icecast Control plugin is installed in OBS.\n\nIn Icecast Control, set the Broadcast input to OBS. Now when you start streaming in OBS, your Icecast stream goes live with the same audio.\n\nUsing an audio track other than 1 for streaming? Change it in OBS → Tools → Scripts → $SCRIPT_NAME."
echo "Done. You can close this window."
