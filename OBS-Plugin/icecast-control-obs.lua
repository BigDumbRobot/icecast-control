--[[
Icecast Control — OBS script

Sends OBS's own audio mix (the same track your YouTube stream uses) to the
Icecast Control menu bar app, which puts it on the Icecast stream.
The audio source is always OBS itself; there are no other inputs here.

Install: OBS → Tools → Scripts → "+" → choose this file.
In Icecast Control, set the Broadcast input to "OBS".
]]

obs = obslua

local output = nil
local wanted = false          -- true while we should be sending
local cfg = { track = 1, follow = true, port = 8046 }

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
    if obs.obs_output_start(output) then
        log("Sending OBS audio (track " .. cfg.track .. ") to Icecast Control.")
    else
        local err = obs.obs_output_get_last_error(output)
        log("Icecast Control isn't reachable yet" .. (err and (": " .. err) or "") .. ". Will keep trying.")
    end
end

local function stop_output()
    if output ~= nil and obs.obs_output_active(output) then
        obs.obs_output_stop(output)
        log("Stopped sending audio.")
    end
end

-- Keeps the connection up while wanted (e.g. if Icecast Control was opened late or restarted).
local function watchdog()
    if wanted and (output == nil or not obs.obs_output_active(output)) then
        start_output()
    end
end

local function set_wanted(on)
    wanted = on
    if on then start_output() else stop_output() end
end

local function on_event(event)
    if not cfg.follow then return end
    if event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED then
        set_wanted(true)
    elseif event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPING or event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED then
        set_wanted(false)
    end
end

function script_description()
    return [[<h3>Icecast Control</h3>
<p>Sends OBS's audio mix to your Icecast stream through the Icecast Control menu bar app,
so Icecast listeners hear exactly what goes to YouTube.</p>
<p>In Icecast Control, set the Broadcast input to <b>OBS</b>.</p>]]
end

function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_int(props, "track", "Audio track (use your stream's track)", 1, 6, 1)
    obs.obs_properties_add_bool(props, "follow", "Start and stop with OBS streaming")
    obs.obs_properties_add_button(props, "start", "Start sending now", function()
        set_wanted(true)
        return false
    end)
    obs.obs_properties_add_button(props, "stop", "Stop sending", function()
        set_wanted(false)
        return false
    end)
    obs.obs_properties_add_int(props, "port", "Icecast Control port (advanced)", 1024, 65535, 1)
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "track", 1)
    obs.obs_data_set_default_bool(settings, "follow", true)
    obs.obs_data_set_default_int(settings, "port", 8046)
end

function script_update(settings)
    local track = obs.obs_data_get_int(settings, "track")
    local port = obs.obs_data_get_int(settings, "port")
    local changed = track ~= cfg.track or port ~= cfg.port
    cfg.track = track
    cfg.port = port
    cfg.follow = obs.obs_data_get_bool(settings, "follow")
    -- Apply track/port changes straight away if we're sending.
    if changed and output ~= nil and obs.obs_output_active(output) then
        stop_output()
        start_output()
    end
end

function script_load(settings)
    script_update(settings)
    obs.obs_frontend_add_event_callback(on_event)
    obs.timer_add(watchdog, 3000)
    -- Script loaded while already streaming: join in.
    if cfg.follow and obs.obs_frontend_streaming_active() then set_wanted(true) end
end

function script_unload()
    obs.timer_remove(watchdog)
    wanted = false
    if output ~= nil then
        stop_output()
        obs.obs_output_release(output)
        output = nil
    end
end
