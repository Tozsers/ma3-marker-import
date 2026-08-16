--[[
  Marker Import v1.0.0 - grandMA3 plugin

  Reads a marker list from a text file and, for every marker, creates a Cue in an
  existing Sequence and a Timecode event that jumps to that Cue at the marker time.

  Supported input formats (auto-detected per line):
    1. Simple CSV      Name,Start,End          e.g.  Drop,84.5,86.0
    2. Audacity labels Start<TAB>End<TAB>Name  e.g.  84.500000  86.000000  Drop
    3. Reaper markers  #,Name,Start,End,...    e.g.  M1,Drop,1:24.500,,

  Supported time notations: 84.5   1:24.5   0:01:24.500
  (SMPTE hh:mm:ss:ff is NOT supported - see README.)

  Written by Claude (Anthropic's Claude Code).
  Directed and tested on real grandMA3 hardware by Tozsers.
  MIT licensed - see LICENSE.
]]

local PLUGIN = "Marker Import"
local VERSION = "1.0.0"

-- grandMA3 internal time unit: 1 second = 2^24
local ONE_SECOND = 16777216

local trackCache = {}

local function msg(t)
    Printf("[%s] %s", PLUGIN, t)
    Echo(t)
end

local function notify(title, body)
    Echo("[" .. PLUGIN .. "] " .. body)
    Printf("[%s] %s", PLUGIN, body)
    if MessageBox then
        MessageBox(title, body, "OK")
    end
end

local function err(t)
    ErrPrintf("[%s] %s", PLUGIN, t)
    Echo("ERROR: " .. t)
end

local function pathSep()
    return GetPathSeparator and GetPathSeparator() or "/"
end

local function libraryPath()
    if Enums and Enums.PathType and Enums.PathType.Library then
        return GetPath(Enums.PathType.Library)
    end
    return GetPath("gma3_library")
end

local function objName(h)
    if not h then
        return nil
    end
    if h.name then
        return h.name
    end
    if h.Get then
        return h:Get("name")
    end
    return nil
end

local function timeSecToInternal(sec)
    return math.floor(sec * ONE_SECOND + 0.5)
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--=============================================================================
-- Parsing  (pure Lua, no MA3 API - covered by tests/test_parser.lua)
--=============================================================================

--- Parse a time string into seconds.
--- Accepts: "84.5", "1:24.5" (m:s), "0:01:24.5" (h:m:s).
--- Returns nil if the string is not a time (e.g. a header cell).
local function parseTime(s)
    if not s then
        return nil
    end
    s = trim(s)
    if s == "" then
        return nil
    end

    -- Plain seconds
    local plain = tonumber(s)
    if plain then
        return plain
    end

    -- Colon-separated. 4 parts means SMPTE hh:mm:ss:ff, which we refuse on
    -- purpose: without knowing the frame rate we would silently import at the
    -- wrong times.
    local parts = {}
    for p in s:gmatch("[^:]+") do
        parts[#parts + 1] = p
    end
    if #parts < 2 or #parts > 3 then
        return nil
    end
    for i = 1, #parts do
        local n = tonumber(parts[i])
        if not n then
            return nil
        end
        parts[i] = n
    end
    if #parts == 2 then
        return parts[1] * 60 + parts[2]
    end
    return parts[1] * 3600 + parts[2] * 60 + parts[3]
end

--- Split a CSV line, honouring double quotes.
local function splitCsv(line)
    local parts = {}
    local field = ""
    local inq = false
    for i = 1, #line do
        local c = line:sub(i, i)
        if c == '"' then
            inq = not inq
        elseif c == "," and not inq then
            parts[#parts + 1] = field
            field = ""
        else
            field = field .. c
        end
    end
    parts[#parts + 1] = field
    return parts
end

local function splitTabs(line)
    local parts = {}
    for p in (line .. "\t"):gmatch("([^\t]*)\t") do
        parts[#parts + 1] = p
    end
    return parts
end

--- Turn one input line into { name = ..., start = seconds } or nil.
--- nil means "skip this line" - header rows, comments and blank lines all
--- land here, which is why no format needs to be declared up front.
local function parseMarkerLine(line)
    if not line then
        return nil
    end
    line = line:gsub("\r", "")
    line = trim(line)
    if line == "" or (line:sub(1, 1) == "#" and not line:find(",")) then
        return nil
    end

    -- Format 2: Audacity label track (tab separated: start, end, name)
    if line:find("\t") then
        local p = splitTabs(line)
        local startSec = parseTime(p[1])
        local name = trim(p[3] or "")
        if startSec and name ~= "" then
            return { name = name, start = startSec }
        end
        return nil
    end

    local p = splitCsv(line)
    for i = 1, #p do
        p[i] = trim(p[i])
    end
    if #p < 2 then
        return nil
    end

    -- Format 3: Reaper marker export (#,Name,Start,End,...) - first cell is an
    -- id like "M1" / "R3", the time sits in the third column.
    if #p >= 3 and p[1]:match("^[MRmr]?%d+$") then
        local startSec = parseTime(p[3])
        if startSec and p[2] ~= "" then
            return { name = p[2], start = startSec }
        end
    end

    -- Format 1: Name,Start[,End]
    local startSec = parseTime(p[2])
    if startSec and p[1] ~= "" then
        return { name = p[1], start = startSec }
    end

    -- Tolerated variant: Start,Name
    startSec = parseTime(p[1])
    if startSec and p[2] ~= "" then
        return { name = p[2], start = startSec }
    end

    return nil
end

--=============================================================================
-- grandMA3 side
--=============================================================================

local function readLines(filepath)
    if FileExists and not FileExists(filepath) then
        err("No such file: " .. filepath)
        return nil
    end
    local f, ferr = io.open(filepath, "r")
    if not f then
        err("Cannot open file: " .. tostring(ferr))
        return nil
    end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines
end

local function findSequenceByName(name)
    local pool = DataPool().sequences
    if not pool then
        return nil
    end
    if pool[name] then
        return pool[name]
    end
    local cnt = pool.Count and pool:Count() or 0
    for i = 1, cnt do
        local s = pool[i]
        if s and objName(s) == name then
            return s
        end
    end
    if pool.FindChild then
        local f = pool:FindChild(name)
        if f then
            return f
        end
    end
    return nil
end

--- Next free cue number in the sequence (existing cues are never touched).
local function getNextCueNumber(sequence)
    local maxNo = 0
    for i = 1, 200 do
        if sequence[i] then
            maxNo = i
        end
    end
    return maxNo + 1
end

local function escapeForCmd(s)
    return (s:gsub('"', ""))
end

local function storeCue(sequence, seqName, cueNo, cueName)
    local safeSeq = escapeForCmd(seqName)
    local safeName = escapeForCmd(cueName)
    local cmd = string.format('Store Sequence "%s" Cue %d "%s"', safeSeq, cueNo, safeName)
    Cmd(cmd)
    coroutine.yield(0.2)
    local cue = sequence[cueNo]
    if cue and cue[1] then
        return cue[1]
    end
    return cue
end

local function ensureTrackGroup(timecode)
    local tg = timecode[1]
    if tg then
        return tg
    end
    tg = timecode:Acquire()
    coroutine.yield(0.25)
    return timecode[1] or tg
end

local function trackMatchesSequence(track, sequence)
    if not track or not sequence then
        return false
    end
    local tgt = track.target
    if tgt == sequence then
        return true
    end
    if tgt and objName(tgt) == objName(sequence) then
        return true
    end
    local tn = objName(track) or ""
    local sn = objName(sequence) or ""
    if sn ~= "" and tn:find(sn, 1, true) then
        return true
    end
    return false
end

local function findTrackInGroup(trackGroup, sequence)
    if not trackGroup then
        return nil
    end
    for ti = 1, 64 do
        local track = trackGroup[ti]
        if track and trackMatchesSequence(track, sequence) then
            return track
        end
    end
    return nil
end

local function getOrCreateTrack(timecode, sequence)
    local seqName = objName(sequence) or "?"
    if trackCache[seqName] then
        return trackCache[seqName]
    end

    local tg = ensureTrackGroup(timecode)
    if not tg then
        err("Could not create a track group.")
        return nil
    end

    local track = findTrackInGroup(tg, sequence)
    if not track then
        track = tg:Acquire()
        coroutine.yield(0.2)
        if track and track.Set then
            track:Set("target", sequence)
        end
        track = findTrackInGroup(tg, sequence) or track
        msg("New track: " .. seqName)
    end

    if track then
        trackCache[seqName] = track
    end
    return track
end

local function getCmdSubTrack(track)
    if not track then
        return nil
    end
    local timeRange = track[1]
    if not timeRange then
        timeRange = track:Acquire()
        coroutine.yield(0.1)
    end
    if not timeRange then
        return nil
    end
    local sub = timeRange[1]
    if sub and sub.class and tostring(sub.class):find("CmdSubTrack") then
        return sub
    end
    for ci = 1, 16 do
        local c = timeRange[ci]
        if c and tostring(c):find("CmdSubTrack") then
            return c
        end
    end
    sub = timeRange:Acquire("CmdSubTrack")
    coroutine.yield(0.1)
    return sub
end

--- One trigger event per marker (no on/off pair, just "go to this cue").
local function addMarkerEvent(cmdSubTrack, startSec, cueHandle, name)
    local t = timeSecToInternal(startSec)

    local ev = cmdSubTrack:Acquire()
    if not ev then
        return false
    end
    ev:Set("name", name)
    ev:Set("rawtime", t)
    ev:Set("time", t)
    if cueHandle then
        ev:Set("cuedestination", cueHandle)
    end
    return true
end

local function importFile()
    trackCache = {}

    local tc = SelectedTimecode()
    if not tc then
        notify(PLUGIN, "Select a Timecode in the pool first (yellow frame). It may be empty.")
        return
    end
    local tcName = objName(tc) or "?"
    msg("Timecode: " .. tcName)

    local seqName = TextInput("Sequence name (must already exist, may be empty):", "Markers")
    if not seqName or seqName == "" then
        return
    end
    local sequence = findSequenceByName(seqName)
    if not sequence then
        notify(PLUGIN, "No such Sequence: \"" .. seqName .. "\".\nCreate it first (an empty one is fine), then run the plugin again.")
        return
    end

    local defaultFile = libraryPath() .. pathSep() .. "markers.csv"
    local filepath = TextInput("Full path of the marker file:", defaultFile)
    if not filepath or filepath == "" then
        return
    end

    local lines = readLines(filepath)
    if not lines then
        return
    end

    local track = getOrCreateTrack(tc, sequence)
    if not track then
        err("Could not create or find a track.")
        return
    end
    local sub = getCmdSubTrack(track)
    if not sub then
        err("Could not create a CmdSubTrack.")
        return
    end

    local nextCue = getNextCueNumber(sequence)
    local imported = 0
    local skipped = 0
    local errors = {}

    for _, line in ipairs(lines) do
        local row = parseMarkerLine(line)
        if row then
            local cue = storeCue(sequence, seqName, nextCue, row.name)
            if not cue then
                errors[#errors + 1] = "Cue was not created: " .. row.name
                skipped = skipped + 1
            else
                if addMarkerEvent(sub, row.start, cue, row.name) then
                    imported = imported + 1
                    msg(string.format("%s @ %.3fs -> Cue %d", row.name, row.start, nextCue))
                    nextCue = nextCue + 1
                else
                    errors[#errors + 1] = "Event was not created: " .. row.name
                    skipped = skipped + 1
                end
            end
        end
    end

    local summary = string.format(
        "Timecode: %s\nSequence: %s\nImported: %d markers\nSkipped: %d",
        tcName, seqName, imported, skipped
    )
    if #errors > 0 then
        summary = summary .. "\n\nErrors:\n" .. table.concat(errors, "\n")
    end
    if imported == 0 then
        summary = summary .. "\n\nTip: check the [" .. PLUGIN .. "] lines in the Command Line.\nIf it stays 0, run ReloadAllPlugins and try again."
    else
        summary = summary .. "\n\nOpen the Timecode window (event list) and the Sequence pool - they should be there."
    end

    notify(PLUGIN, summary)

    if imported == 0 and Confirm then
        if Confirm("Debug", "Dump the timecode structure to the Command Line?") then
            tc:Dump()
        end
    end
end

function Main()
    msg(PLUGIN .. " " .. VERSION)
    importFile()
end

function Cleanup()
end

-- Exposed for the offline parser tests; harmless inside grandMA3.
MarkerImportInternal = {
    parseTime = parseTime,
    parseMarkerLine = parseMarkerLine,
}

return Main, Cleanup
