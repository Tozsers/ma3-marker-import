--[[
  Offline tests for the file-parsing half of MarkerImport.lua.

  The grandMA3 half (cues, tracks, timecode events) cannot run outside a
  console, so it is not covered here - that part is unchanged from the version
  that was verified on real hardware. What IS covered is every line of input
  parsing, which is where a wrong result would silently place markers at the
  wrong time.

  Run:  lua tests/test_parser.lua
]]

-- Stub the handful of globals the plugin touches at load time.
Printf = function() end
Echo = function() end
ErrPrintf = function() end

local chunk = assert(loadfile("MarkerImport/MarkerImport.lua"))
chunk()
local P = MarkerImportInternal

local failures = 0
local checks = 0

local function eq(actual, expected, label)
    checks = checks + 1
    local ok
    if type(expected) == "number" and type(actual) == "number" then
        ok = math.abs(actual - expected) < 1e-6
    else
        ok = actual == expected
    end
    if not ok then
        failures = failures + 1
        print(string.format("FAIL  %s\n        expected: %s\n        actual:   %s",
            label, tostring(expected), tostring(actual)))
    end
end

local function marker(line, expName, expStart, label)
    local r = P.parseMarkerLine(line)
    checks = checks + 1
    if not r then
        failures = failures + 1
        print(string.format("FAIL  %s\n        line was skipped: %q", label, line))
        return
    end
    eq(r.name, expName, label .. " (name)")
    eq(r.start, expStart, label .. " (time)")
end

local function skipped(line, label)
    checks = checks + 1
    local r = P.parseMarkerLine(line)
    if r ~= nil then
        failures = failures + 1
        print(string.format("FAIL  %s\n        expected skip, got: %s @ %s",
            label, tostring(r.name), tostring(r.start)))
    end
end

-- ---------------------------------------------------------------- time --
eq(P.parseTime("84.5"), 84.5, "plain seconds")
eq(P.parseTime("0"), 0, "zero")
eq(P.parseTime("1:24.5"), 84.5, "m:s")
eq(P.parseTime("0:01:24.5"), 84.5, "h:m:s")
eq(P.parseTime("1:00:00"), 3600, "one hour")
eq(P.parseTime("  12.25  "), 12.25, "surrounding spaces")
eq(P.parseTime("Start"), nil, "header cell is not a time")
eq(P.parseTime(""), nil, "empty is not a time")
eq(P.parseTime("00:01:24:12"), nil, "SMPTE is refused, not guessed")

-- ------------------------------------------------------- simple CSV --
marker("Drop,84.5,86.0", "Drop", 84.5, "CSV name,start,end")
marker("Drop,84.5", "Drop", 84.5, "CSV name,start")
marker('"Big, loud drop",84.5,86.0', "Big, loud drop", 84.5, "CSV quoted comma in name")
marker("Chorus 2,1:24.5,", "Chorus 2", 84.5, "CSV with m:s time")
marker("84.5,Drop", "Drop", 84.5, "tolerated start,name order")
skipped("Name,Start,End", "CSV header row")
skipped("", "blank line")
skipped("   ", "whitespace-only line")

-- --------------------------------------------------- Audacity labels --
marker("84.500000\t86.000000\tDrop", "Drop", 84.5, "Audacity label")
marker("0.000000\t0.000000\tIntro", "Intro", 0, "Audacity point label at zero")
marker("12.5\t13.0\tName, with comma", "Name, with comma", 12.5, "Audacity name containing a comma")
skipped("84.5\t86.0\t", "Audacity row without a name")

-- ----------------------------------------------------- Reaper export --
marker("M1,Drop,1:24.500,,", "Drop", 84.5, "Reaper marker")
marker("R3,Chorus,0:01:24.500,0:01:30.000,", "Chorus", 84.5, "Reaper region")
marker("1,Drop,84.5,,", "Drop", 84.5, "Reaper id without letter")
skipped("#,Name,Start,End,Length", "Reaper header row")

-- ------------------------------------------------------------ misc --
skipped("# a comment line", "comment line")
marker("Drop,84.5,86.0\r", "Drop", 84.5, "CRLF line ending")

-- ------------------------------------------------------ cue numbering --
-- A fake sequence. grandMA3 reports cue numbers in thousandths - the cue shown
-- as "1" has no = 1000 - so the fixture does the same. `numbers` are given the
-- way a user reads them; opts.rawScale models a hypothetical version that
-- reports plain numbers instead.
local function fakeSequence(numbers, opts)
    opts = opts or {}
    local scale = opts.rawScale and 1 or 1000
    local kids = {}
    if not opts.noCueZero then
        kids[#kids + 1] = opts.noProperty and {} or { no = 0 }
    end
    for _, n in ipairs(numbers) do
        kids[#kids + 1] = opts.noProperty and {} or { no = n * scale }
    end
    if not opts.noOffCue then
        kids[#kids + 1] = {}
    end

    local seq = {}
    if opts.noChildrenMethod then
        for i, k in ipairs(kids) do
            seq[i] = k
        end
    else
        seq.Children = function() return kids end
    end
    return seq
end

local function startsAt(numbers, expected, label, opts)
    local used, seenAny, count = P.collectCueNumbers(fakeSequence(numbers, opts))
    local first = P.firstFreeCueNumber(used, seenAny, count)
    eq(P.nextFreeCueNumber(used, first), expected, label)
end

startsAt({}, 1, "empty sequence starts at cue 1")
startsAt({ 1 }, 2, "one existing cue -> starts at 2 (the 2026-08-16 hardware bug)")
startsAt({ 1, 2, 3 }, 4, "three cues in a row")
startsAt({ 1, 2, 3, 5 }, 6, "sparse numbering never lands on the existing cue 5")
startsAt({ 10, 20, 30 }, 31, "high numbers")
startsAt({ 2.5 }, 3, "decimal cue number")
startsAt({ 1000 }, 1001, "cue 1000 is not confused with the thousandths scale")
startsAt({}, 3, "no readable numbers -> falls back to child count, never lower",
    { noProperty = true })
startsAt({ 1, 2 }, 3, "index access when Children() is unavailable",
    { noChildrenMethod = true })

-- If some version ever reported plain numbers instead of thousandths, the
-- starting point would be too low - but the taken-check must still refuse to
-- hand out a number that exists, so nothing is ever overwritten.
startsAt({ 1, 2, 3 }, 4, "unscaled numbers: still never lands on an existing cue",
    { rawScale = true })

-- Numbers handed out during one import must not collide with existing cues.
do
    local used = P.collectCueNumbers(fakeSequence({ 1, 3, 4 }))
    local handed = {}
    local n = 1 -- deliberately start low to prove the skipping works
    for _ = 1, 4 do
        n = P.nextFreeCueNumber(used, n)
        P.markCueTaken(used, n)
        handed[#handed + 1] = n
        n = n + 1
    end
    eq(table.concat(handed, ","), "2,5,6,7", "assigned numbers skip taken ones")
end

-- ------------------------------------------------- sequence lookup --
-- Typing "Markers" when the sequence is called "markers" must work; getting
-- this wrong cost a hardware test on 2026-08-16.
local function stubPool(names)
    local pool = { Count = function() return #names end }
    for i, n in ipairs(names) do
        pool[i] = { name = n }
    end
    DataPool = function() return { sequences = pool } end
end

stubPool({ "Default", "markers", "SFX" })
do
    local h = P.findSequenceByName("markers")
    eq(h and h.name, "markers", "exact name found")

    h = P.findSequenceByName("Markers")
    eq(h and h.name, "markers", "different capitalisation found")

    h = P.findSequenceByName("  MARKERS  ")
    eq(h and h.name, "markers", "spaces and caps ignored")

    local missing, seqs = P.findSequenceByName("nope")
    eq(missing, nil, "unknown name returns nil")
    eq(#seqs, 3, "the pool contents come back for the error message")
    eq(P.describeSequences(seqs),
        'Sequences in the loaded show: "Default", "markers", "SFX"',
        "error message lists what is actually there")
end

stubPool({})
eq(P.describeSequences(select(2, P.findSequenceByName("markers"))),
    "The sequence pool of the loaded show is empty.",
    "empty pool says so plainly")

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
