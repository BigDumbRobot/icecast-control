--[[
Icecast Control — OBS script

Sends OBS's own audio mix (the same track your YouTube stream uses) to the
Icecast Control menu bar app whenever OBS is open, streaming or not.
It only sends audio; it doesn't change anything in OBS.

Install: OBS → Tools → Scripts → "+" → choose this file.
In Icecast Control, set the Broadcast input to "OBS".
]]

obs = obslua

local output = nil
local cfg = { track = 1, port = 8046 }
local announced = false       -- log "sending" once, not on every reconnect attempt

local function log(msg)
    obs.script_log(obs.LOG_INFO, "[Icecast Control] " .. msg)
end

local function make_settings()
    local s = obs.obs_data_create()
    -- Uncompressed WAV over a local-only connection; Icecast Control encodes the MP3.
    obs.obs_data_set_string(s, "url", "tcp://127.0.0.1:" .. tostring(cfg.port))
    obs.obs_data_set_string(s, "format_name", "wav")
    obs.obs_data_set_string(s, "format_mime_type", "audio/wav")
    return s
end

local function start_output()
    if output ~= nil and obs.obs_output_active(output) then return end
    local s = make_settings()
    if output == nil then
        output = obs.obs_output_create("ffmpeg_output", "icecast_control_audio", s, nil)
    else
        obs.obs_output_update(output, s)
    end
    obs.obs_data_release(s)
    if output == nil then
        log("Couldn't create the output.")
        return
    end
    -- Only the chosen audio track (no video is encoded or sent).
    obs.obs_output_set_mixers(output, bit.lshift(1, cfg.track - 1))
    obs.obs_output_set_media(output, obs.obs_get_video(), obs.obs_get_audio())
    if obs.obs_output_start(output) and not announced then
        log("Sending OBS audio (track " .. cfg.track .. ") to Icecast Control.")
        announced = true
    end
end

local function stop_output()
    if output ~= nil and obs.obs_output_active(output) then
        obs.obs_output_stop(output)
    end
    announced = false
end

-- Keeps the connection up (e.g. if Icecast Control was opened late or restarted).
local function watchdog()
    if output == nil or not obs.obs_output_active(output) then
        start_output()
    end
end

function script_description()
    return [[<h3>Icecast Control</h3>
<p>Sends OBS's audio mix to the Icecast Control menu bar app whenever OBS is open,
streaming or not.</p>
<p>In Icecast Control, set the Broadcast input to <b>OBS</b>.</p>]]
end

function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_int(props, "track", "Audio track (use your stream's track)", 1, 6, 1)
    obs.obs_properties_add_int(props, "port", "Icecast Control port (advanced)", 1024, 65535, 1)
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "track", 1)
    obs.obs_data_set_default_int(settings, "port", 8046)
end

function script_update(settings)
    local track = obs.obs_data_get_int(settings, "track")
    local port = obs.obs_data_get_int(settings, "port")
    local changed = track ~= cfg.track or port ~= cfg.port
    cfg.track = track
    cfg.port = port
    -- Apply track/port changes straight away.
    if changed and output ~= nil and obs.obs_output_active(output) then
        stop_output()
        start_output()
    end
end

function script_load(settings)
    script_update(settings)
    obs.timer_add(watchdog, 3000)
    start_output()
end

function script_unload()
    obs.timer_remove(watchdog)
    if output ~= nil then
        stop_output()
        obs.obs_output_release(output)
        output = nil
    end
end
