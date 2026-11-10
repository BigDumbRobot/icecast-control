#!/bin/bash
# Removes the Icecast Control plugin from OBS.
set -uo pipefail
OBS_ID="com.obsproject.obs-studio"
OBS_DIR="$HOME/Library/Application Support/obs-studio"
TARGET="$OBS_DIR/scripts/icecast-control-obs.lua"

WAS_RUNNING=0
if pgrep -xq OBS; then
    WAS_RUNNING=1
    ANSWER=$(osascript -e 'button returned of (display dialog "OBS needs to close for a moment to remove the plugin." with title "Icecast Control OBS Plugin" buttons {"Cancel", "Close & Reopen OBS"} default button 2)' 2>/dev/null)
    [[ "$ANSWER" == "Close & Reopen OBS" ]] || exit 0
    osascript -e "tell application id \"$OBS_ID\" to quit" >/dev/null 2>&1
    for _ in $(seq 1 120); do pgrep -xq OBS || break; sleep 0.5; done
    pgrep -xq OBS && { echo "OBS didn't close; nothing changed."; exit 1; }
fi

osascript -l JavaScript - "$OBS_DIR/basic/scenes" "$TARGET" <<'JS' >/dev/null
ObjC.import('Foundation');
function run(argv) {
    const folder = argv[0], scriptPath = argv[1];
    const fm = $.NSFileManager.defaultManager;
    const names = ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError(folder, null)) || [];
    for (const name of names) {
        if (!name.endsWith('.json')) continue;
        const file = folder + '/' + name;
        const text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null));
        if (!text || !text.includes(scriptPath)) continue;
        const json = JSON.parse(text);
        const list = (json.modules || {})['scripts-tool'] || [];
        json.modules['scripts-tool'] = list.filter(s => s.path !== scriptPath);
        $(JSON.stringify(json, null, 4)).writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null);
    }
    return 'ok';
}
JS
rm -f "$TARGET"
[[ $WAS_RUNNING == 1 ]] && open -b "$OBS_ID"
osascript -e 'display dialog "The Icecast Control plugin was removed from OBS." with title "Icecast Control OBS Plugin" buttons {"OK"} default button 1' >/dev/null 2>&1
