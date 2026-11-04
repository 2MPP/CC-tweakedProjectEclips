-- Project Eclipse - Unified Radar, CIWS Defense & Encrypted Strike Server (CC:Tweaked)
-- Primary monitor: monitor_0 (51x19)
-- Optional secondary monitor (e.g. 4x2 touch keyboard monitor): auto-detected if connected
-- Includes:
--   * 102x57 square-subpixel phosphor radar scope + CIWS auto-intercept
--   * Built-in encrypted wireless launch server for pocket_remote.lua
--   * Main-screen click-to-target on radar circle + on-screen touch keypad & launch controls
--   * Automatic rocket/device registration via mcp.scanAndRegister() & mcp.registerRocket()

local MONITOR_NAME   = "monitor_0"
local CHANNEL        = 4920
local PROTOCOL       = "ECLIPSE_ENC_V2"
local KEY_FILE       = ".eclipse_key"
local DEFAULT_KEY    = "ECLIPSE-77"
local DEFAULT_RANGE  = 500
local POLL_INTERVAL  = 0.20
local ZONE_RADIUS    = 512
local DEFAULT_SPREAD = 16

--------------------------------------------------------------------------------
-- 1. Encryption & Anti-Replay Security (Shared with pocket_remote.lua)
--------------------------------------------------------------------------------
local bxor    = bit32.bxor
local band    = bit32.band
local lrotate = bit32.lrotate
local char    = string.char
local byte    = string.byte
local floor   = math.floor
local sqrt    = math.sqrt
local atan2   = math.atan2
local abs     = math.abs
local min     = math.min
local max     = math.max
local TWO_PI  = math.pi * 2

local function loadSecretKey()
    if fs.exists(KEY_FILE) then
        local f = fs.open(KEY_FILE, "r")
        if f then
            local k = f.readLine()
            f.close()
            if k and #k > 0 then return k end
        end
    end
    return DEFAULT_KEY
end

local function saveSecretKey(k)
    local f = fs.open(KEY_FILE, "w")
    if f then
        f.writeLine(k)
        f.close()
    end
end

local SECRET_KEY = loadSecretKey()

local function hashPair(str, seedA, seedB)
    local h1 = seedA or 0x811C9DC5
    local h2 = seedB or 0x9E3779B9
    for i = 1, #str do
        local b = byte(str, i)
        h1 = bxor(h1, b)
        h1 = band(h1 * 16777619, 0xFFFFFFFF)
        h1 = lrotate(h1, 5)
        h2 = bxor(h2, b + (i * 73))
        h2 = band(h2 * 2246822519, 0xFFFFFFFF)
        h2 = lrotate(h2, 11)
    end
    if h1 == 0 then h1 = 0x13579BDF end
    if h2 == 0 then h2 = 0x2468ACE0 end
    return h1, h2
end

local function cryptBytes(data, key, nonce)
    local s1, s2 = hashPair(key .. "|" .. tostring(nonce), 0xA5A5A5A5, 0x5A5A5A5A)
    local out = {}
    for i = 1, #data do
        s1 = bxor(s1, lrotate(s1, 13))
        s1 = bxor(s1, lrotate(s2, 7))
        s2 = band(s2 + 0x9E3779B9, 0xFFFFFFFF)
        local kByte = band(bxor(s1, s2), 0xFF)
        out[i] = char(bxor(byte(data, i), kByte))
    end
    return table.concat(out)
end

local function toHex(str)
    return (str:gsub(".", function(c)
        return string.format("%02x", byte(c))
    end))
end

local function fromHex(hex)
    if #hex % 2 ~= 0 then return nil end
    return (hex:gsub("..", function(cc)
        local n = tonumber(cc, 16)
        return n and char(n) or "\0"
    end))
end

local function computeMac(key, nonce, cipherHex)
    local h1, h2 = hashPair(key .. "|MAC|" .. tostring(nonce) .. "|" .. cipherHex, 0xCAFEBABE, 0xDEADBEEF)
    return string.format("%08x%08x", h1, h2)
end

local function encryptPacket(payloadTable)
    local nonce = tostring(math.random(100000, 999999)) .. "-" .. tostring(floor(os.clock() * 100))
    local plain = textutils.serialize(payloadTable, { compact = true })
    local cipherHex = toHex(cryptBytes(plain, SECRET_KEY, nonce))
    local mac = computeMac(SECRET_KEY, nonce, cipherHex)
    return {
        protocol = PROTOCOL,
        nonce = nonce,
        cipher = cipherHex,
        mac = mac,
    }
end

local seenNonces = {}
local seenNonceOrder = {}

local function decryptPacket(Wrapper)
    if type(Wrapper) ~= "table" or Wrapper.protocol ~= PROTOCOL then
        return nil, "Bad protocol"
    end
    if type(Wrapper.nonce) ~= "string" or type(Wrapper.cipher) ~= "string" or type(Wrapper.mac) ~= "string" then
        return nil, "Malformed packet"
    end
    if seenNonces[Wrapper.nonce] then
        return nil, "Replay rejected"
    end
    local expectedMac = computeMac(SECRET_KEY, Wrapper.nonce, Wrapper.cipher)
    if expectedMac ~= Wrapper.mac then
        return nil, "Auth MAC mismatch (wrong key)"
    end

    -- Record nonce to block replay attacks
    seenNonces[Wrapper.nonce] = true
    table.insert(seenNonceOrder, Wrapper.nonce)
    if #seenNonceOrder > 64 then
        local old = table.remove(seenNonceOrder, 1)
        seenNonces[old] = nil
    end

    local rawCipher = fromHex(Wrapper.cipher)
    if not rawCipher then return nil, "Bad hex" end
    local plain = cryptBytes(rawCipher, SECRET_KEY, Wrapper.nonce)
    local ok, tbl = pcall(textutils.unserialize, plain)
    if not ok or type(tbl) ~= "table" then
        return nil, "Unserialize failed"
    end
    return tbl
end

--------------------------------------------------------------------------------
-- 2. Peripheral Discovery (Monitors, MCP, Wireless Modem)
--------------------------------------------------------------------------------
local mon = peripheral.wrap(MONITOR_NAME) or peripheral.find("monitor")
if not mon then
    error("Could not find " .. MONITOR_NAME .. " (or any connected monitor)")
end
mon.setTextScale(1)
local W, H = mon.getSize()

-- Optional second monitor (e.g. a 4x2 touch keypad monitor)
local keyMon = nil
local keyMonName = nil
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" and name ~= MONITOR_NAME then
        local wrapped = peripheral.wrap(name)
        if wrapped and wrapped ~= mon then
            keyMon = wrapped
            keyMonName = name
            keyMon.setTextScale(1)
            break
        end
    end
end

-- Wireless / Ender Modem (optional but enables pocket_remote.lua)
local modem = peripheral.find("modem", function(_, m)
    return m.isWireless and m.isWireless()
end)
if modem then
    modem.open(CHANNEL)
end

-- Missile Control Panel
local mcp = peripheral.find("missile_control_panel")
if not mcp then
    error("No Missile Control Panel (missile_control_panel) found!")
end

local function ensureAuthenticated()
    if mcp.isAuthenticated() then return true end
    local ok = pcall(function() mcp.authenticate() end)
    if ok and mcp.isAuthenticated() then return true end

    print("========================================")
    print(" Project Eclipse - MCP Authentication")
    print("========================================")
    print("Run '/eclipse ccauto' in-game for permanent link,")
    print("OR run '/eclipse ccgrant' and enter token below.")
    while not mcp.isAuthenticated() do
        write("Enter token (or press Enter after /eclipse ccauto): ")
        local token = read()
        token = token and token:gsub("%s+", "") or ""
        local success, err = pcall(function()
            if token == "" then mcp.authenticate() else mcp.authenticate(token) end
        end)
        if success and mcp.isAuthenticated() then
            print("Authenticated with MCP!")
            break
        else
            print("Auth failed: " .. tostring(err))
        end
    end
    return true
end

ensureAuthenticated()

--------------------------------------------------------------------------------
-- 3. Auto-Registration, Air Defense & Dispersed Launch Logic
--------------------------------------------------------------------------------
local defenseConfigured = false
local function configureAirDefense(centerX, centerZ)
    pcall(mcp.setDefenseMode, "AUTO")
    pcall(mcp.setDefenseDoctrine, "MAXIMUM_DEFENSE")
    pcall(mcp.setInterceptorLauncherMode, "BOTH")
    pcall(mcp.setPursuitAuto, true)

    pcall(mcp.upsertDefenseZone, {
        name = "CIWS Defense Zone",
        x = centerX,
        z = centerZ,
        radius = ZONE_RADIUS,
        priority = "CRITICAL",
        autoEngage = true,
    })
    defenseConfigured = true
end

local function scanAndRegisterDevices(radius)
    radius = math.max(1, math.min(64, tonumber(radius) or 64))
    if not mcp.scanAndRegister then
        return false, "scanAndRegister not supported"
    end
    local ok, res = pcall(mcp.scanAndRegister, radius)
    if ok and type(res) == "table" then
        return true, string.format("LINKED %d NODE(S) (%dm)", res.count or 0, res.radius or radius)
    end
    return false, tostring(res or "Scan failed")
end

-- Run an automatic scan on startup so nearby floor rockets/CIWS/radars link immediately
scanAndRegisterDevices(64)

-- Strike options shared by main monitor, 4x2 keypad monitor, and terminal
local FIRE_MODES = { "AUTO", "1", "2", "3", "4", "5", "6", "BIG_ONE", "CRUISE", "SALVO", "THOR" }
local PROFILES   = { "HIGH_BALLISTIC", "LOW_TRAJECTORY", "TERRAIN_HUG" }
local IMPACTS    = { "SURFACE", "AIRBURST", "BUNKER_BUSTER" }

local strikeCfg = {
    targetX = 0,
    targetY = 64,
    targetZ = 0,
    count = 4,
    spread = DEFAULT_SPREAD,
    modeIdx = 1,
    profileIdx = 1,
    impactIdx = 1,
    mainWindow = "RADAR", -- "RADAR" or "STRIKE" on monitor_0
    activeInputField = "X", -- "X", "Y", "Z", "CNT", "SPR" for touch keypad
    inputBuffer = "",
    lastStatus = "Click radar or [STRIKE] to aim",
}

local GOLDEN_ANGLE = math.pi * (3 - math.sqrt(5))

local function buildDispersedTargets(centerX, centerY, centerZ, count, spread)
    local targets = {}
    local baseAngle = math.random() * TWO_PI
    for i = 1, count do
        if i == 1 or spread <= 0 then
            table.insert(targets, { x = centerX, y = centerY, z = centerZ })
        else
            local fraction = (i - 1) / max(1, count - 1)
            local radius = spread * sqrt(fraction)
            local jitterR = (math.random() - 0.5) * (spread * 0.25)
            local r = max(2, radius + jitterR)
            local angle = baseAngle + (i - 1) * GOLDEN_ANGLE + (math.random() - 0.5) * 0.35
            local dx = floor(math.cos(angle) * r + 0.5)
            local dz = floor(math.sin(angle) * r + 0.5)
            local dy = math.random(-2, 2)
            local ty = max(-64, min(320, centerY + dy))
            table.insert(targets, { x = centerX + dx, y = ty, z = centerZ + dz })
        end
    end
    return targets
end

local function executeLaunch(cmd)
    local x = tonumber(cmd.x)
    local y = tonumber(cmd.y) or 64
    local z = tonumber(cmd.z)
    local count = max(1, min(64, tonumber(cmd.count) or 1))
    local spread = tonumber(cmd.spread)
    if spread == nil then spread = DEFAULT_SPREAD end
    spread = max(0, min(256, spread))

    if not x or not z then
        return false, "Invalid X/Z coordinates"
    end

    local fireMode = tostring(cmd.fireMode or "AUTO")
    local attackProfile = cmd.attackProfile or "HIGH_BALLISTIC"
    local impactMode = cmd.impactMode or "SURFACE"
    local delaySeconds = tonumber(cmd.delaySeconds) or 0

    -- Project Thor Orbital Kinetic Strike support
    if fireMode == "THOR" then
        if not mcp.fireOrbitalStrike then
            return false, "Thor API unavailable"
        end
        local targets = buildDispersedTargets(x, y, z, count, spread)
        local dispatched = 0
        local lastErr = nil
        for _, t in ipairs(targets) do
            local okThor, resThor = pcall(mcp.fireOrbitalStrike, t.x, t.z, t.y)
            if okThor and type(resThor) == "table" then
                dispatched = dispatched + 1
            else
                lastErr = resThor
            end
        end
        if dispatched > 0 then
            return true, string.format("THOR STRIKE x%d (3.5s)", dispatched)
        end
        return false, tostring(lastErr or "No Thor rods available")
    end

    local targets = buildDispersedTargets(x, y, z, count, spread)
    local isSimpleFire = (fireMode == "AUTO")
        and (attackProfile == "HIGH_BALLISTIC")
        and (impactMode == "SURFACE")
        and (delaySeconds == 0)

    if isSimpleFire then
        local firedCount = 0
        local lastErr = nil
        for i = 1, #targets do
            local t = targets[i]
            local okSet, errSet = pcall(mcp.setTarget, t.x, t.y, t.z)
            if okSet then
                local okFire, resFire = pcall(mcp.fire, 1)
                if okFire then
                    firedCount = firedCount + 1
                else
                    lastErr = resFire
                end
            else
                lastErr = errSet
            end
        end
        if firedCount > 0 then
            return true, string.format("FIRED %d (SPR %dm)", firedCount, spread)
        elseif lastErr then
            return false, tostring(lastErr)
        end
    end

    local missions = {}
    local parsedMode = tonumber(fireMode) or fireMode
    local bunkerDepth = tonumber(cmd.bunkerDepth) or 10

    for i = 1, min(#targets, 48) do
        local t = targets[i]
        table.insert(missions, {
            name = string.format("Strike #%d", i),
            x = t.x, y = t.y, z = t.z,
            count = 1,
            fireMode = parsedMode,
            attackProfile = attackProfile,
            impactMode = impactMode,
            bunkerDepth = bunkerDepth,
        })
    end

    local okPlan, resPlan = pcall(mcp.executeFirePlan, missions, delaySeconds)
    if okPlan and resPlan then
        return true, tostring(resPlan)
    end

    local firedCount = 0
    local lastErr = resPlan
    for i = 1, #targets do
        local t = targets[i]
        if pcall(mcp.setTarget, t.x, t.y, t.z) then
            local okFire, resFire = pcall(mcp.fire, 1)
            if okFire then firedCount = firedCount + 1 else lastErr = resFire end
        end
    end
    if firedCount > 0 then
        return true, string.format("FIRED %d (SPR %dm)", firedCount, spread)
    end
    return false, tostring(lastErr or "Launch failed")
end

--------------------------------------------------------------------------------
-- 4. Custom Palette Setup (7 phosphor green shades + tactical blip & HUD colors)
--------------------------------------------------------------------------------
local SHADE_BLIT = {
    [0] = "f", -- Black (outside circle)
    [1] = "2", -- Deepest radar background green
    [2] = "3", -- Trail fade 1 (dim)
    [3] = "6", -- Trail fade 2 (low-mid)
    [4] = "b", -- Grid lines / Trail fade 3 (mid)
    [5] = "a", -- Highlighted grid / Trail fade 4 (bright)
    [6] = "5", -- Sweep leading edge & center dot (neon green)
}

local function setupPalette(target)
    if not target or not target.setPaletteColor then return end
    target.setPaletteColor(colors.black,     0x000000) -- 'f'
    target.setPaletteColor(colors.magenta,   0x031A05) -- '2'
    target.setPaletteColor(colors.lightBlue, 0x082E0B) -- '3'
    target.setPaletteColor(colors.pink,      0x0F4712) -- '6'
    target.setPaletteColor(colors.blue,      0x1A6B1E) -- 'b'
    target.setPaletteColor(colors.purple,    0x29A32E) -- 'a'
    target.setPaletteColor(colors.lime,      0x55FF55) -- '5'

    target.setPaletteColor(colors.red,       0xFF2222) -- 'e'
    target.setPaletteColor(colors.orange,    0xFF8800) -- '1'
    target.setPaletteColor(colors.yellow,    0xFFDD22) -- '4'
    target.setPaletteColor(colors.cyan,      0x33DDFF) -- '9'
    target.setPaletteColor(colors.white,     0xE8FFE8) -- '0'
    target.setPaletteColor(colors.lightGray, 0x77AA77) -- '8'
    target.setPaletteColor(colors.gray,      0x223822) -- '7'
end

setupPalette(mon)
mon.setBackgroundColor(colors.black)
mon.clear()

if keyMon then
    keyMon.setBackgroundColor(colors.black)
    keyMon.clear()
end

--------------------------------------------------------------------------------
-- 5. Subpixel Geometry (102x57 square subpixels on 51x19 monitor)
--------------------------------------------------------------------------------
local PW = W * 2
local PH = H * 3

local CX = (PW + 1) / 2
local CY = (PH + 1) / 2
local RADIUS = floor(min(PW, PH) / 2) - 1 -- 27 subpixels on 51x19
local NUM_RINGS = 4
local NUM_SPOKES = 12
local TRAIL_ARC = math.rad(65)

local staticDist = {}
local staticAngle = {}
local staticInside = {}
local staticIsGrid = {}
local staticIsOuterRing = {}

for py = 1, PH do
    staticDist[py] = {}
    staticAngle[py] = {}
    staticInside[py] = {}
    staticIsGrid[py] = {}
    staticIsOuterRing[py] = {}

    local dy = py - CY
    for px = 1, PW do
        local dx = px - CX
        local dist = sqrt(dx * dx + dy * dy)
        staticDist[py][px] = dist

        if dist <= RADIUS + 0.45 then
            staticInside[py][px] = true
            local ang = (atan2(dx, -dy) + TWO_PI) % TWO_PI
            staticAngle[py][px] = ang

            local isOuter = abs(dist - RADIUS) <= 0.55
            staticIsOuterRing[py][px] = isOuter

            local isInnerRing = false
            for r = 1, NUM_RINGS - 1 do
                local ringR = (RADIUS / NUM_RINGS) * r
                if abs(dist - ringR) <= 0.42 then
                    isInnerRing = true
                    break
                end
            end

            local isCardinal = (abs(dx) <= 0.45) or (abs(dy) <= 0.45)
            local isSpoke = false
            if dist >= 3.0 then
                local spokeStep = TWO_PI / NUM_SPOKES
                local nearestSpoke = floor((ang + spokeStep * 0.5) / spokeStep) * spokeStep
                local angDiff = abs(ang - nearestSpoke)
                if angDiff > math.pi then angDiff = TWO_PI - angDiff end
                isSpoke = (dist * angDiff) <= 0.38
            end

            staticIsGrid[py][px] = isOuter or isInnerRing or isCardinal or isSpoke
        else
            staticInside[py][px] = false
        end
    end
end

local fb = {}
local overlay = {}
local overlayPrio = {}
for py = 1, PH do
    fb[py] = {}
    overlay[py] = {}
    overlayPrio[py] = {}
    for px = 1, PW do
        fb[py][px] = 0
    end
end

--------------------------------------------------------------------------------
-- 6. Live MCP State, CIWS Defense & Offensive Inventory
--------------------------------------------------------------------------------
local OFFENSIVE_NODE_TYPES = {
    PLACED_MISSILE = true,
    CRUISE_MISSILE = true,
    ATTACK_LAUNCHER = true,
    POD_LAUNCHER = true,
    LAUNCH_PAD = true,
    STRATEGIC_SILO = true,
    CRUISE_LAUNCHER = true,
}

local state = {
    online = true,
    empTicks = 0,
    originX = 0,
    originY = 64,
    originZ = 0,
    radarRange = DEFAULT_RANGE,
    radarCount = 0,
    defenseMode = "AUTO",
    readyCiws = 0,
    ciwsAmmo = 0,
    readyInterceptors = 0,
    launcherCount = 0,
    readyMissiles = 0,
    placedCount = 0,
    siloReady = 0,
    thorRods = 0,
    satCount = 0,
    ciwsNodes = {},
    blips = {},
    threatList = {},
    threatCount = 0,
    trackCount = 0,
    flightCount = 0,
    engaging = false,
    targetInitialized = false,
}

local function pollMcp()
    if not mcp.isAuthenticated() then return end

    local okInfo, netInfo = pcall(mcp.getNetworkInfo)
    if not okInfo or not netInfo then return end

    state.online = netInfo.networkOnline ~= false
    state.empTicks = netInfo.empRemainingTicks or 0
    state.defenseMode = netInfo.defenseMode or "AUTO"
    state.readyCiws = netInfo.readyCiws or 0
    state.ciwsAmmo = netInfo.ciwsAmmo or 0
    state.readyInterceptors = netInfo.readyInterceptors or 0
    state.radarCount = netInfo.radarCount or 0

    local ox = netInfo.x or 0
    local oy = netInfo.y or 64
    local oz = netInfo.z or 0
    local maxRange = 0

    local okRadars, radars = pcall(mcp.getRadars)
    if okRadars and type(radars) == "table" and #radars > 0 then
        state.radarCount = #radars
        local sumX, sumZ = 0, 0
        for _, r in ipairs(radars) do
            sumX = sumX + (r.x or ox)
            sumZ = sumZ + (r.z or oz)
            if (r.range or 0) > maxRange then
                maxRange = r.range
            end
        end
        ox = floor(sumX / #radars + 0.5)
        oz = floor(sumZ / #radars + 0.5)
    end

    state.originX = ox
    state.originY = oy
    state.originZ = oz
    state.radarRange = (maxRange > 0) and maxRange or DEFAULT_RANGE

    if not state.targetInitialized then
        strikeCfg.targetX = ox + 100
        strikeCfg.targetY = oy
        strikeCfg.targetZ = oz
        state.targetInitialized = true
    end

    if not defenseConfigured or state.defenseMode ~= "AUTO" then
        configureAirDefense(ox, oz)
    end

    -- Count offensive missiles & launchers (including PLACED_MISSILE on floor)
    local readyMissiles = netInfo.readyMissiles or 0
    local launcherCount = netInfo.launcherCount or 0
    local placedCount = 0

    local okReady, directReady = pcall(mcp.getReadyMissileCount)
    if okReady and type(directReady) == "number" and directReady > readyMissiles then
        readyMissiles = directReady
    end

    local okLaunchers, launchers = pcall(mcp.getLaunchers)
    if okLaunchers and type(launchers) == "table" then
        if #launchers > launcherCount then launcherCount = #launchers end
        local sumLoaded = 0
        for _, l in ipairs(launchers) do
            if l.type == "PLACED_MISSILE" then
                placedCount = placedCount + 1
                if l.ready ~= false then sumLoaded = sumLoaded + max(1, l.loadedCount or 1) end
            else
                sumLoaded = sumLoaded + (l.loadedCount or (l.ready and 1 or 0))
            end
        end
        if sumLoaded > readyMissiles then readyMissiles = sumLoaded end
    end

    local ciwsNodes = {}
    local okNodes, nodes = pcall(mcp.getNodes)
    if okNodes and type(nodes) == "table" then
        local nodeOffCount, nodeReadySum, nodePlaced = 0, 0, 0
        for _, n in ipairs(nodes) do
            if n.type == "CIWS" and n.connected then
                table.insert(ciwsNodes, { id = n.id, x = n.x or ox, z = n.z or oz, ammo = n.readyCount or 0 })
            end
            if OFFENSIVE_NODE_TYPES[n.type] and n.connected ~= false then
                nodeOffCount = nodeOffCount + 1
                if n.type == "PLACED_MISSILE" or n.type == "CRUISE_MISSILE" then
                    nodePlaced = nodePlaced + 1
                    nodeReadySum = nodeReadySum + max(1, n.readyCount or 1)
                else
                    nodeReadySum = nodeReadySum + (n.readyCount or 0)
                end
            end
        end
        if nodeOffCount > launcherCount then launcherCount = nodeOffCount end
        if nodeReadySum > readyMissiles then readyMissiles = nodeReadySum end
        if nodePlaced > placedCount then placedCount = nodePlaced end
    end
    state.ciwsNodes = ciwsNodes
    state.launcherCount = launcherCount
    state.readyMissiles = readyMissiles
    state.placedCount = placedCount

    local siloReady = 0
    local okSilos, silos = pcall(mcp.getSilos)
    if okSilos and type(silos) == "table" then
        for _, s in ipairs(silos) do
            if s.ready then siloReady = siloReady + 1 end
        end
    end
    state.siloReady = siloReady

    -- Space Assets (Satellites & Project Thor)
    if mcp.getThorStatus then
        local okThor, thor = pcall(mcp.getThorStatus)
        if okThor and type(thor) == "table" then
            state.thorRods = thor.rodsRemaining or 0
        end
    end
    if mcp.getSatellites then
        local okSats, sats = pcall(mcp.getSatellites)
        if okSats and type(sats) == "table" then
            state.satCount = #sats
        end
    end

    -- Gather Radar Contacts, Tracks & Flights
    local blips = {}
    local threatList = {}
    local seenIds = {}
    local engageIds = {}
    local anyEngaging = false

    local okContacts, contacts = pcall(mcp.getContacts)
    if okContacts and type(contacts) == "table" then
        state.threatCount = #contacts
        for _, c in ipairs(contacts) do
            if c.x and c.z then
                if c.id then
                    seenIds[c.id] = true
                    table.insert(engageIds, c.id)
                end
                local dx, dz = c.x - ox, c.z - oz
                local dist = sqrt(dx * dx + dz * dz)
                local isEngaged = (c.trackState == "ENGAGED") or (dist <= 200 and state.readyCiws > 0)
                if isEngaged then anyEngaging = true end

                table.insert(blips, {
                    x = c.x, z = c.z,
                    vx = c.vx or 0, vz = c.vz or 0,
                    color = "e", prio = 4, pulse = true, engaged = isEngaged,
                })
                table.insert(threatList, {
                    kind = "MSL T" .. tostring(c.tier or "?"),
                    x = floor(c.x), z = floor(c.z),
                    dist = floor(dist + 0.5),
                    eta = c.etaTicks and floor(c.etaTicks / 20) or nil,
                    state = isEngaged and "CIWS FIRE" or (c.trackState or "TRACKING"),
                    color = "e",
                })
            end
        end
    else
        state.threatCount = 0
    end

    local okRaw, rawContacts = pcall(mcp.getRadarContacts)
    if okRaw and type(rawContacts) == "table" then
        for _, rc in ipairs(rawContacts) do
            if rc.x and rc.z and (not rc.id or not seenIds[rc.id]) then
                if rc.id then seenIds[rc.id] = true end
                local isOwn = rc.ownNetwork == true
                local col = isOwn and "9" or "e"
                local prio = isOwn and 2 or 4
                local dx, dz = rc.x - ox, rc.z - oz
                local dist = sqrt(dx * dx + dz * dz)
                local isEngaged = (not isOwn) and (dist <= 200 and state.readyCiws > 0)
                if isEngaged then anyEngaging = true end

                table.insert(blips, {
                    x = rc.x, z = rc.z,
                    vx = rc.vx or 0, vz = rc.vz or 0,
                    color = col, prio = prio, pulse = not isOwn, engaged = isEngaged,
                })
                if not isOwn then
                    state.threatCount = state.threatCount + 1
                    if rc.id then table.insert(engageIds, rc.id) end
                    table.insert(threatList, {
                        kind = "RKT T" .. tostring(rc.tier or "?"),
                        x = floor(rc.x), z = floor(rc.z),
                        dist = floor(dist + 0.5),
                        state = isEngaged and "CIWS FIRE" or "INCOMING",
                        color = "e",
                    })
                end
            end
        end
    end

    if state.threatCount > 0 or #engageIds > 0 then
        local okEng, launched = pcall(mcp.engageThreat)
        if okEng and launched then anyEngaging = true end
    end

    local okTracks, tracks = pcall(mcp.getTracks)
    if okTracks and type(tracks) == "table" then
        state.trackCount = #tracks
        for _, t in ipairs(tracks) do
            if t.x and t.z then
                local col, prio = "4", 3
                if t.iff == "HOSTILE" then col, prio = "1", 4
                elseif t.iff == "FRIENDLY" or t.friendly then col, prio = "9", 2 end
                table.insert(blips, {
                    x = t.x, z = t.z,
                    vx = t.vx or 0, vz = t.vz or 0,
                    color = col, prio = prio, pulse = (t.iff == "HOSTILE"),
                })
                if t.iff ~= "FRIENDLY" and not t.friendly then
                    local dx, dz = t.x - ox, t.z - oz
                    table.insert(threatList, {
                        kind = t.vehicle and "VEH" or "AIR",
                        x = floor(t.x), z = floor(t.z),
                        dist = floor(sqrt(dx * dx + dz * dz) + 0.5),
                        state = t.iff or "UNK",
                        color = col,
                    })
                end
            end
        end
    else
        state.trackCount = 0
    end

    local okFlights, flights = pcall(mcp.getFlights)
    if okFlights and type(flights) == "table" then
        state.flightCount = #flights
        for _, f in ipairs(flights) do
            if f.x and f.z and (not f.id or not seenIds[f.id]) then
                table.insert(blips, {
                    x = f.x, z = f.z,
                    vx = f.vx or 0, vz = f.vz or 0,
                    color = "9", prio = 2,
                })
            end
        end
    else
        state.flightCount = 0
    end

    table.sort(threatList, function(a, b) return a.dist < b.dist end)
    state.blips = blips
    state.threatList = threatList
    state.engaging = anyEngaging
end

-- Build compact status + radar snapshot for pocket_remote.lua
local function buildRemoteStatusPayload()
    local compactBlips = {}
    for i = 1, min(#state.blips, 24) do
        local b = state.blips[i]
        table.insert(compactBlips, {
            dx = floor(b.x - state.originX + 0.5),
            dz = floor(b.z - state.originZ + 0.5),
            c = b.color,
            p = b.prio,
        })
    end

    local compactThreats = {}
    for i = 1, min(#state.threatList, 5) do
        local t = state.threatList[i]
        table.insert(compactThreats, {
            kind = t.kind,
            dist = t.dist,
            eta = t.eta,
            state = t.state,
            x = t.x,
            z = t.z,
            c = t.color,
        })
    end

    return {
        online = state.online,
        originX = state.originX,
        originY = state.originY,
        originZ = state.originZ,
        radarRange = state.radarRange,
        radarCount = state.radarCount,
        readyCiws = state.readyCiws,
        ciwsAmmo = state.ciwsAmmo,
        launcherCount = state.launcherCount,
        readyMissiles = state.readyMissiles,
        placedCount = state.placedCount,
        siloReady = state.siloReady,
        thorRods = state.thorRods,
        satCount = state.satCount,
        activeFlights = state.flightCount,
        threatCount = state.threatCount,
        blips = compactBlips,
        threats = compactThreats,
    }
end

--------------------------------------------------------------------------------
-- 7. Subpixel Framebuffer Rendering & Coordinate Conversion
--------------------------------------------------------------------------------
local tickCounter = 0

local function setOverlayPixel(px, py, color, prio)
    if px < 1 or px > PW or py < 1 or py > PH then return end
    if not staticInside[py][px] then return end
    if prio >= (overlayPrio[py][px] or 0) then
        overlay[py][px] = color
        overlayPrio[py][px] = prio
    end
end

local function drawTracerLine(x0, y0, x1, y1, color, prio, phase)
    local dx = x1 - x0
    local dy = y1 - y0
    local steps = max(abs(dx), abs(dy))
    if steps < 2 then return end
    for i = 1, steps - 1 do
        if (i + phase) % 3 == 0 then
            local px = floor(x0 + (dx * i) / steps + 0.5)
            local py = floor(y0 + (dy * i) / steps + 0.5)
            setOverlayPixel(px, py, color, prio)
        end
    end
end

local function worldToSubpixel(wx, wz)
    local range = max(1, state.radarRange)
    local usableRadius = RADIUS - 1.2
    local normX = (wx - state.originX) / range
    local normZ = (wz - state.originZ) / range
    local normDist = sqrt(normX * normX + normZ * normZ)
    if normDist > 1.0 then
        normX = normX / normDist
        normZ = normZ / normDist
    end
    local bx = floor(CX + normX * usableRadius + 0.5)
    local by = floor(CY + normZ * usableRadius + 0.5)
    return bx, by
end

-- Convert a monitor character click (charX, charY) inside the radar circle into world (X, Z)
local function monitorClickToWorld(charX, charY)
    local px = (charX - 0.5) * 2
    local py = (charY - 0.5) * 3
    local dx = px - CX
    local dy = py - CY
    local dist = sqrt(dx * dx + dy * dy)
    if dist > RADIUS then
        return nil, nil
    end
    local usableRadius = RADIUS - 1.2
    local wx = floor(state.originX + (dx / usableRadius) * state.radarRange + 0.5)
    local wz = floor(state.originZ + (dy / usableRadius) * state.radarRange + 0.5)
    return wx, wz
end

local function updateFramebuffer(sweepAngle)
    for py = 1, PH do
        local ovRow = overlay[py]
        local prRow = overlayPrio[py]
        for px = 1, PW do
            ovRow[px] = nil
            prRow[px] = 0
        end
    end

    for py = 1, PH do
        local insideRow = staticInside[py]
        local distRow = staticDist[py]
        local angRow = staticAngle[py]
        local gridRow = staticIsGrid[py]
        local outerRow = staticIsOuterRing[py]
        local fbRow = fb[py]

        for px = 1, PW do
            if not insideRow[px] then
                fbRow[px] = 0
            elseif not state.online then
                fbRow[px] = outerRow[px] and 4 or (gridRow[px] and 2 or 1)
            else
                local dist = distRow[px]
                if dist <= 0.8 then
                    fbRow[px] = 6
                else
                    local ang = angRow[px]
                    local behind = (sweepAngle - ang) % TWO_PI
                    local arcDist = behind * dist

                    if (behind < 0.18 or (TWO_PI - behind) < 0.04) and arcDist <= 0.75 then
                        fbRow[px] = 6
                    else
                        local trailShade = 1
                        if behind <= TRAIL_ARC then
                            local t = 1.0 - (behind / TRAIL_ARC)
                            if t > 0.78 then trailShade = 5
                            elseif t > 0.50 then trailShade = 4
                            elseif t > 0.22 then trailShade = 3
                            else trailShade = 2 end
                        end

                        if outerRow[px] then
                            fbRow[px] = (trailShade >= 5) and 6 or 5
                        elseif gridRow[px] then
                            fbRow[px] = (trailShade >= 4) and 5 or 4
                        else
                            fbRow[px] = trailShade
                        end
                    end
                end
            end
        end
    end

    -- Draw selected Strike Target crosshair (+) on the radar map in orange/white
    local tx, tz = worldToSubpixel(strikeCfg.targetX, strikeCfg.targetZ)
    local blinkCol = (tickCounter % 8 < 4) and "1" or "0"
    setOverlayPixel(tx - 1, tz, blinkCol, 3)
    setOverlayPixel(tx + 1, tz, blinkCol, 3)
    setOverlayPixel(tx, tz - 1, blinkCol, 3)
    setOverlayPixel(tx, tz + 1, blinkCol, 3)

    -- Plot connected CIWS turrets
    for _, ciws in ipairs(state.ciwsNodes) do
        local cx, cy = worldToSubpixel(ciws.x, ciws.z)
        setOverlayPixel(cx, cy, "9", 2)
    end

    -- Plot live radar blips & CIWS tracers
    local pulseOn = (tickCounter % 6) < 4
    local tracerPhase = tickCounter % 3

    for _, blip in ipairs(state.blips) do
        local bx, by = worldToSubpixel(blip.x, blip.z)

        if blip.engaged and state.readyCiws > 0 then
            local sx, sy = floor(CX + 0.5), floor(CY + 0.5)
            if #state.ciwsNodes > 0 then
                sx, sy = worldToSubpixel(state.ciwsNodes[1].x, state.ciwsNodes[1].z)
            end
            drawTracerLine(sx, sy, bx, by, "4", 3, tracerPhase)
        end

        setOverlayPixel(bx, by, blip.color, blip.prio)
        if blip.pulse and pulseOn then
            setOverlayPixel(bx + 1, by, blip.color, blip.prio)
            setOverlayPixel(bx - 1, by, blip.color, blip.prio)
            setOverlayPixel(bx, by + 1, blip.color, blip.prio)
            setOverlayPixel(bx, by - 1, blip.color, blip.prio)
        end

        local vx, vz = blip.vx or 0, blip.vz or 0
        local speed = sqrt(vx * vx + vz * vz)
        if speed > 0.05 then
            local dirX, dirZ = vx / speed, vz / speed
            for step = 1, 3 do
                local lx = floor(bx + dirX * step + 0.5)
                local ly = floor(by + dirZ * step + 0.5)
                setOverlayPixel(lx, ly, blip.color, blip.prio - 1)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- 8. Main Monitor Rendering (Window 1: RADAR + Quick Launch | Window 2: STRIKE KEYPAD)
--------------------------------------------------------------------------------
local function writeHud(target, x, y, text, fg, bg)
    bg = bg or string.rep("f", #text)
    if #fg < #text then fg = string.rep(fg:sub(1, 1), #text) end
    if #bg < #text then bg = string.rep(bg:sub(1, 1), #text) end
    target.setCursorPos(x, y)
    target.blit(text, fg:sub(1, #text), bg:sub(1, #text))
end

local function padRight(str, len)
    str = tostring(str or "")
    if #str >= len then return str:sub(1, len) end
    return str .. string.rep(" ", len - #str)
end

local function drawStrikeKeypadPanel(target, tw, th, isMainMonitor)
    target.setBackgroundColor(colors.black)
    target.clear()

    -- Top Header / Window Switcher
    if isMainMonitor then
        writeHud(target, 1, 1, padRight(" ECLIPSE STRIKE & KEYPAD CONSOLE", tw - 12), "f", "5")
        writeHud(target, tw - 11, 1, "[<< RADAR]  ", "0", "7")
    else
        writeHud(target, 1, 1, padRight(" ECLIPSE KEYPAD", tw), "f", "5")
    end

    -- Left Column: Field Selector & Current Values
    local fields = {
        { id = "X",   label = "TGT X :", val = tostring(strikeCfg.targetX), row = 3 },
        { id = "Y",   label = "TGT Y :", val = tostring(strikeCfg.targetY), row = 4 },
        { id = "Z",   label = "TGT Z :", val = tostring(strikeCfg.targetZ), row = 5 },
        { id = "CNT", label = "COUNT :", val = tostring(strikeCfg.count),   row = 6 },
        { id = "SPR", label = "SPREAD:", val = tostring(strikeCfg.spread) .. "m", row = 7 },
    }

    for _, f in ipairs(fields) do
        if f.row <= th then
            local active = (strikeCfg.activeInputField == f.id)
            local shownVal = (active and strikeCfg.inputBuffer ~= "") and (strikeCfg.inputBuffer .. "_") or f.val
            local line = string.format("[%s] %-7s %-8s", f.id:sub(1, 1), f.label, shownVal)
            writeHud(target, 2, f.row, padRight(line, 21), active and "4" or "0", active and "7" or "f")
        end
    end

    -- Mode / Profile / Impact cyclers
    if th >= 11 then
        local modeName = FIRE_MODES[strikeCfg.modeIdx]
        local profName = PROFILES[strikeCfg.profileIdx]
        local impName  = IMPACTS[strikeCfg.impactIdx]
        writeHud(target, 2, 9,  padRight("MODE: [" .. modeName .. "]", 21), "4", "7")
        writeHud(target, 2, 10, padRight("PROF: [" .. profName:sub(1, 12) .. "]", 21), "9", "7")
        writeHud(target, 2, 11, padRight("IMPT: [" .. impName:sub(1, 12) .. "]", 21), "1", "7")
    end

    if th >= 14 then
        writeHud(target, 2, 13, "[SCAN & LINK 64m]    ", "f", "9")
        writeHud(target, 2, 14, "[ARM STRATEGIC SILO] ", "f", "1")
    end

    if th >= 17 then
        writeHud(target, 2, 16, "=====================", "e", "f")
        writeHud(target, 2, 17, " >>> LAUNCH STRIKE <<<", "0", "e")
        writeHud(target, 2, 18, "=====================", "e", "f")
    elseif th >= 12 then
        -- Compact layout for 4x2 monitor (39x12)
        writeHud(target, 2, 8,  "[MODE:" .. FIRE_MODES[strikeCfg.modeIdx]:sub(1, 6) .. "]", "4", "7")
        writeHud(target, 16, 8, "[LINK 64m]", "f", "9")
        writeHud(target, 2, 10, " >>> LAUNCH STRIKE <<< ", "0", "e")
        writeHud(target, 2, 12, padRight(strikeCfg.lastStatus, tw - 2), "5", "f")
    end

    if th >= 19 then
        writeHud(target, 2, 19, padRight(strikeCfg.lastStatus, tw - 2), "5", "f")
    end

    -- Right Column: On-Screen Touch Numeric Keypad (Cols 25..39)
    local kx = min(25, max(16, tw - 14))
    writeHud(target, kx, 2, "TOUCH KEYPAD ", "5", "f")
    writeHud(target, kx, 3, "[ 7 ] [ 8 ] [ 9 ]", "0", "7")
    writeHud(target, kx, 5, "[ 4 ] [ 5 ] [ 6 ]", "0", "7")
    writeHud(target, kx, 7, "[ 1 ] [ 2 ] [ 3 ]", "0", "7")
    writeHud(target, kx, 9, "[ - ] [ 0 ] [CLR]", "4", "7")
    writeHud(target, kx, 11, "[  APPLY / SET  ]", "f", "5")
end

local function drawMainMonitor()
    if strikeCfg.mainWindow == "STRIKE" then
        drawStrikeKeypadPanel(mon, W, H, true)
        return
    end

    -- Window 1: Subpixel Radar Scope + Left/Right Tactical & Launch HUD
    for cy = 1, H do
        local py0 = (cy - 1) * 3 + 1
        local row1, row2, row3 = fb[py0], fb[py0 + 1], fb[py0 + 2]
        local ov1, ov2, ov3 = overlay[py0], overlay[py0 + 1], overlay[py0 + 2]
        local pr1, pr2, pr3 = overlayPrio[py0], overlayPrio[py0 + 1], overlayPrio[py0 + 2]

        local chars, fgs, bgs = {}, {}, {}

        for cx = 1, W do
            local px0 = (cx - 1) * 2 + 1
            local s1, s2 = row1[px0], row1[px0 + 1]
            local s3, s4 = row2[px0], row2[px0 + 1]
            local s5, s6 = row3[px0], row3[px0 + 1]

            local o1, o2 = ov1[px0], ov1[px0 + 1]
            local o3, o4 = ov2[px0], ov2[px0 + 1]
            local o5, o6 = ov3[px0], ov3[px0 + 1]

            if o1 or o2 or o3 or o4 or o5 or o6 then
                local bestColor = o1 or o2 or o3 or o4 or o5 or o6
                local bestPrio = -1
                local oList = { o1, o2, o3, o4, o5, o6 }
                local pList = { pr1[px0], pr1[px0 + 1], pr2[px0], pr2[px0 + 1], pr3[px0], pr3[px0 + 1] }
                for i = 1, 6 do
                    if oList[i] and pList[i] > bestPrio then
                        bestPrio = pList[i]
                        bestColor = oList[i]
                    end
                end

                local bgShade = max(s1, s2, s3, s4, s5, s6)
                local fgColor = bestColor
                local bgColor = SHADE_BLIT[bgShade]

                local b1 = o1 and 1 or 0
                local b2 = o2 and 2 or 0
                local b3 = o3 and 4 or 0
                local b4 = o4 and 8 or 0
                local b5 = o5 and 16 or 0
                local b6 = o6 and 1 or 0

                local mask = b1 + b2 + b3 + b4 + b5
                if b6 == 1 then
                    mask = 31 - mask
                    fgColor, bgColor = bgColor, fgColor
                end

                chars[cx] = char(128 + mask)
                fgs[cx] = fgColor
                bgs[cx] = bgColor
            else
                local minS = min(s1, s2, s3, s4, s5, s6)
                local maxS = max(s1, s2, s3, s4, s5, s6)

                if minS == maxS then
                    chars[cx] = "\128"
                    local c = SHADE_BLIT[minS]
                    fgs[cx] = c
                    bgs[cx] = c
                else
                    local mid = (minS + maxS) * 0.5
                    local b1 = (s1 > mid) and 1 or 0
                    local b2 = (s2 > mid) and 2 or 0
                    local b3 = (s3 > mid) and 4 or 0
                    local b4 = (s4 > mid) and 8 or 0
                    local b5 = (s5 > mid) and 16 or 0
                    local b6 = (s6 > mid) and 1 or 0

                    local mask = b1 + b2 + b3 + b4 + b5
                    local fgColor = SHADE_BLIT[maxS]
                    local bgColor = SHADE_BLIT[minS]

                    if b6 == 1 then
                        mask = 31 - mask
                        fgColor, bgColor = bgColor, fgColor
                    end

                    chars[cx] = char(128 + mask)
                    fgs[cx] = fgColor
                    bgs[cx] = bgColor
                end
            end
        end

        mon.setCursorPos(1, cy)
        mon.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
    end

    -- Left HUD Margin (Cols 1..11): Defense, Inventory & Direct Launch Controls
    writeHud(mon, 1, 1, "ECLIPSE RDR", "5")
    if state.online then
        writeHud(mon, 2, 2, "ONLINE", "5")
    else
        writeHud(mon, 2, 2, "EMP!  ", "e")
    end
    writeHud(mon, 1, 3, padRight("CIWS:" .. state.readyCiws .. "/" .. state.ciwsAmmo, 11), state.readyCiws > 0 and "77777555555" or "77777eeeeee")
    writeHud(mon, 1, 4, padRight("MSLS:" .. state.readyMissiles .. " RDY", 11), state.readyMissiles > 0 and "77777000000" or "77777eeeeee")
    if state.thorRods > 0 then
        writeHud(mon, 1, 5, padRight("THOR:" .. state.thorRods .. " ROD", 11), "77777444444")
    else
        writeHud(mon, 1, 5, padRight("RNG :" .. state.radarRange .. "m", 11), "77777888888")
    end

    if state.threatCount > 0 then
        local flash = (tickCounter % 4 < 2)
        writeHud(mon, 1, 7, "CIWS ACTIVE", flash and "4" or "e")
    else
        writeHud(mon, 1, 7, "CIWS SENTRY", "5")
    end

    -- Main-Screen Interactive Strike Controls (Rows 9..19, Cols 1..11)
    writeHud(mon, 1, 9,  "[LINK 64m] ", "f", "9")
    writeHud(mon, 1, 10, padRight("X:" .. strikeCfg.targetX, 11), "0")
    writeHud(mon, 1, 11, padRight("Z:" .. strikeCfg.targetZ, 11), "0")
    writeHud(mon, 1, 12, padRight(string.format("C:%-2d [-] [+]", strikeCfg.count), 11), "4")
    writeHud(mon, 1, 13, padRight(string.format("S:%-2d [-] [+]", strikeCfg.spread), 11), "8")
    writeHud(mon, 1, 14, padRight("M:" .. FIRE_MODES[strikeCfg.modeIdx]:sub(1, 9), 11), "9")
    writeHud(mon, 1, 16, "[KEYPAD/XY]", "f", "4")
    writeHud(mon, 1, 18, "[>>FIRE!<<]", "0", "e")
    writeHud(mon, 1, 19, padRight(strikeCfg.lastStatus:sub(1, 11), 11), "8")

    -- Right HUD Margin (Cols 41..51): Live Contacts (Tap contact row to lock target!)
    writeHud(mon, 41, 1, "CONTACTS   ", "5")
    if #state.threatList == 0 then
        writeHud(mon, 41, 2, "SECTOR CLR ", "8")
    else
        local maxRows = min(#state.threatList, 5)
        for i = 1, maxRows do
            local item = state.threatList[i]
            local baseRow = 2 + (i - 1) * 3
            local line1 = padRight(string.format("%s %dm", item.kind, item.dist), 11)
            writeHud(mon, 41, baseRow, line1, item.color)

            local statusStr = item.state or "TRACKING"
            if item.eta then
                statusStr = string.format("%s %ds", statusStr:sub(1, 6), item.eta)
            end
            local stColor = (item.state == "CIWS FIRE") and "4" or "8"
            writeHud(mon, 41, baseRow + 1, padRight(" " .. statusStr, 11), stColor)
        end
    end

    writeHud(mon, 41, 17, "TAP RADAR  ", "8")
    writeHud(mon, 41, 18, "TO AIM X/Z ", "8")
    writeHud(mon, 41, 19, padRight("THR:" .. state.threatCount .. " FLT:" .. state.flightCount, 11), "9")
end

--------------------------------------------------------------------------------
-- 9. Touch Handler for Main Monitor & Optional 4x2 Keypad Monitor
--------------------------------------------------------------------------------
local function applyKeypadBuffer()
    local num = tonumber(strikeCfg.inputBuffer)
    if num then
        num = floor(num)
        if strikeCfg.activeInputField == "X" then strikeCfg.targetX = num
        elseif strikeCfg.activeInputField == "Y" then strikeCfg.targetY = max(-64, min(320, num))
        elseif strikeCfg.activeInputField == "Z" then strikeCfg.targetZ = num
        elseif strikeCfg.activeInputField == "CNT" then strikeCfg.count = max(1, min(64, num))
        elseif strikeCfg.activeInputField == "SPR" then strikeCfg.spread = max(0, min(256, num)) end
        strikeCfg.lastStatus = strikeCfg.activeInputField .. " = " .. tostring(num)
    end
    strikeCfg.inputBuffer = ""
end

local function handleKeypadMonitorTouch(tw, th, x, y, isMainMonitor)
    if isMainMonitor and y == 1 and x >= tw - 11 then
        applyKeypadBuffer()
        strikeCfg.mainWindow = "RADAR"
        return
    end

    -- Field selection (Left side rows 3..7)
    local fieldByRow = { [3] = "X", [4] = "Y", [5] = "Z", [6] = "CNT", [7] = "SPR" }
    if x <= 22 and fieldByRow[y] then
        applyKeypadBuffer()
        strikeCfg.activeInputField = fieldByRow[y]
        strikeCfg.inputBuffer = ""
        return
    end

    -- Numeric keypad (Right side cols kx..kx+16)
    local kx = min(25, max(16, tw - 14))
    if x >= kx then
        local colIdx = floor((x - kx) / 6) + 1 -- 1, 2, or 3
        local keyPressed = nil
        if y == 3 then keyPressed = ({ "7", "8", "9" })[colIdx]
        elseif y == 5 then keyPressed = ({ "4", "5", "6" })[colIdx]
        elseif y == 7 then keyPressed = ({ "1", "2", "3" })[colIdx]
        elseif y == 9 then keyPressed = ({ "-", "0", "CLR" })[colIdx]
        elseif y == 11 then keyPressed = "ENTER" end

        if keyPressed == "CLR" then
            strikeCfg.inputBuffer = ""
        elseif keyPressed == "ENTER" then
            applyKeypadBuffer()
        elseif keyPressed == "-" then
            if strikeCfg.inputBuffer == "" then strikeCfg.inputBuffer = "-" end
        elseif keyPressed then
            strikeCfg.inputBuffer = strikeCfg.inputBuffer .. keyPressed
        end
        return
    end

    -- Mode / Profile / Impact / Action buttons on Left side
    if th >= 17 then
        if y == 9 then strikeCfg.modeIdx = (strikeCfg.modeIdx % #FIRE_MODES) + 1
        elseif y == 10 then strikeCfg.profileIdx = (strikeCfg.profileIdx % #PROFILES) + 1
        elseif y == 11 then strikeCfg.impactIdx = (strikeCfg.impactIdx % #IMPACTS) + 1
        elseif y == 13 then
            local ok, msg = scanAndRegisterDevices(64)
            strikeCfg.lastStatus = msg
        elseif y == 14 then
            local armed = 0
            local okS, silos = pcall(mcp.getSilos)
            if okS and type(silos) == "table" then
                for _, s in ipairs(silos) do
                    if not s.valvesOpen then pcall(mcp.siloAction, s.id, "VALVES") end
                    if pcall(mcp.siloAction, s.id, "ARM") then armed = armed + 1 end
                end
            end
            strikeCfg.lastStatus = string.format("ARMED %d SILO(S)", armed)
        elseif y >= 16 and y <= 18 then
            applyKeypadBuffer()
            local ok, msg = executeLaunch({
                x = strikeCfg.targetX, y = strikeCfg.targetY, z = strikeCfg.targetZ,
                count = strikeCfg.count, spread = strikeCfg.spread,
                fireMode = FIRE_MODES[strikeCfg.modeIdx],
                attackProfile = PROFILES[strikeCfg.profileIdx],
                impactMode = IMPACTS[strikeCfg.impactIdx],
            })
            strikeCfg.lastStatus = msg
        end
    else
        -- Compact 4x2 monitor buttons
        if y == 8 and x < 15 then
            strikeCfg.modeIdx = (strikeCfg.modeIdx % #FIRE_MODES) + 1
        elseif y == 8 and x >= 15 then
            local _, msg = scanAndRegisterDevices(64)
            strikeCfg.lastStatus = msg
        elseif y >= 10 and y <= 11 then
            applyKeypadBuffer()
            local _, msg = executeLaunch({
                x = strikeCfg.targetX, y = strikeCfg.targetY, z = strikeCfg.targetZ,
                count = strikeCfg.count, spread = strikeCfg.spread,
                fireMode = FIRE_MODES[strikeCfg.modeIdx],
                attackProfile = PROFILES[strikeCfg.profileIdx],
                impactMode = IMPACTS[strikeCfg.impactIdx],
            })
            strikeCfg.lastStatus = msg
        end
    end
end

local function handleMainRadarTouch(x, y)
    if strikeCfg.mainWindow == "STRIKE" then
        handleKeypadMonitorTouch(W, H, x, y, true)
        return
    end

    -- Left HUD buttons (Cols 1..11)
    if x <= 11 then
        if y == 9 then
            local _, msg = scanAndRegisterDevices(64)
            strikeCfg.lastStatus = msg
        elseif y == 10 or y == 11 or y == 16 then
            strikeCfg.mainWindow = "STRIKE"
        elseif y == 12 then
            if x >= 6 and x <= 8 then
                strikeCfg.count = max(1, strikeCfg.count - 1)
            elseif x >= 9 then
                strikeCfg.count = min(64, strikeCfg.count + 1)
            end
        elseif y == 13 then
            if x >= 6 and x <= 8 then
                strikeCfg.spread = max(0, strikeCfg.spread - 4)
            elseif x >= 9 then
                strikeCfg.spread = min(256, strikeCfg.spread + 4)
            end
        elseif y == 14 then
            strikeCfg.modeIdx = (strikeCfg.modeIdx % #FIRE_MODES) + 1
        elseif y == 18 then
            local _, msg = executeLaunch({
                x = strikeCfg.targetX, y = strikeCfg.targetY, z = strikeCfg.targetZ,
                count = strikeCfg.count, spread = strikeCfg.spread,
                fireMode = FIRE_MODES[strikeCfg.modeIdx],
                attackProfile = PROFILES[strikeCfg.profileIdx],
                impactMode = IMPACTS[strikeCfg.impactIdx],
            })
            strikeCfg.lastStatus = msg
        end
        return
    end

    -- Right HUD: Tap a threat contact row to lock its coordinates!
    if x >= 41 then
        local idx = floor((y - 2) / 3) + 1
        local item = state.threatList[idx]
        if item and item.x and item.z then
            strikeCfg.targetX = item.x
            strikeCfg.targetZ = item.z
            strikeCfg.lastStatus = string.format("LOCK %d,%d", item.x, item.z)
        end
        return
    end

    -- Center Radar Circle: Click anywhere on the radar disc to aim at those world coordinates!
    local wx, wz = monitorClickToWorld(x, y)
    if wx and wz then
        strikeCfg.targetX = wx
        strikeCfg.targetZ = wz
        strikeCfg.lastStatus = string.format("AIM %d,%d", wx, wz)
    end
end

--------------------------------------------------------------------------------
-- 10. Computer Terminal UI (Keyboard Control & Encryption Key Setup)
--------------------------------------------------------------------------------
local function drawComputerTerminal()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.lime)
    print("=== ECLIPSE RADAR + CIWS + STRIKE SERVER ===")
    term.setTextColor(colors.lightGray)
    print(string.format("Monitor: %s (%dx%d) | Wireless Ch: %s",
        MONITOR_NAME, W, H, modem and tostring(CHANNEL) or "NONE"))
    print(string.format("Encryption Key: [%s] (Press [K] to change)", SECRET_KEY))
    print("---------------------------------------------")
    term.setTextColor(colors.white)
    print(string.format("Target XYZ : %d, %d, %d", strikeCfg.targetX, strikeCfg.targetY, strikeCfg.targetZ))
    print(string.format("Count/Sprd : %d missiles | %dm spread | Mode: %s",
        strikeCfg.count, strikeCfg.spread, FIRE_MODES[strikeCfg.modeIdx]))
    print(string.format("Inventory  : %d Ready Missiles (%d Floor) | %d CIWS",
        state.readyMissiles, state.placedCount, state.readyCiws))
    print("---------------------------------------------")
    term.setTextColor(colors.cyan)
    print("[X/Y/Z] Set Coords   [C] Count   [S] Spread")
    print("[M] Mode   [R] Scan & Register Rockets (64m)")
    print("[G] Register Rocket at XYZ   [F] LAUNCH STRIKE")
    term.setTextColor(colors.yellow)
    print("\nLast Status: " .. tostring(strikeCfg.lastStatus))
end

local function promptTerminalLine(promptText)
    term.setCursorPos(1, 15)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.clearLine()
    term.write(promptText)
    term.setCursorBlink(true)
    local val = read()
    term.setCursorBlink(false)
    return val
end

--------------------------------------------------------------------------------
-- 11. Encrypted Wireless Packet Handler (from pocket_remote.lua)
--------------------------------------------------------------------------------
local function handleModemMessage(replyChannel, wrapper)
    if not modem then return end
    local msg, err = decryptPacket(wrapper)
    if not msg then return end

    if msg.type == "PING" or msg.type == "STATUS" then
        modem.transmit(replyChannel, CHANNEL, encryptPacket({
            type = "STATUS_REPLY",
            requestId = msg.requestId,
            serverId = os.getComputerID(),
            status = buildRemoteStatusPayload(),
        }))
    elseif msg.type == "FIRE" then
        local ok, resMsg = executeLaunch(msg)
        strikeCfg.lastStatus = "REMOTE: " .. tostring(resMsg)
        pollMcp()
        modem.transmit(replyChannel, CHANNEL, encryptPacket({
            type = "FIRE_REPLY",
            requestId = msg.requestId,
            ok = ok,
            message = resMsg,
            status = buildRemoteStatusPayload(),
        }))
        drawComputerTerminal()
    elseif msg.type == "SCAN_REGISTER" then
        local ok, resMsg = scanAndRegisterDevices(msg.radius or 64)
        strikeCfg.lastStatus = "REMOTE: " .. tostring(resMsg)
        pollMcp()
        modem.transmit(replyChannel, CHANNEL, encryptPacket({
            type = "FIRE_REPLY",
            requestId = msg.requestId,
            ok = ok,
            message = resMsg,
            status = buildRemoteStatusPayload(),
        }))
        drawComputerTerminal()
    elseif msg.type == "REGISTER_XYZ" then
        local rx, ry, rz = tonumber(msg.x), tonumber(msg.y), tonumber(msg.z)
        local okReg, resReg = false, "Invalid XYZ"
        if rx and ry and rz and mcp.registerRocket then
            local callOk, tbl = pcall(mcp.registerRocket, rx, ry, rz, msg.name)
            if callOk and type(tbl) == "table" then
                okReg = tbl.registered == true
                resReg = tostring(tbl.message or (okReg and "REGISTERED" or "FAILED"))
            else
                resReg = tostring(tbl)
            end
        end
        pollMcp()
        modem.transmit(replyChannel, CHANNEL, encryptPacket({
            type = "FIRE_REPLY",
            requestId = msg.requestId,
            ok = okReg,
            message = resReg,
            status = buildRemoteStatusPayload(),
        }))
        drawComputerTerminal()
    elseif msg.type == "SILO_ARM" then
        local armedCount = 0
        local okSilos, silos = pcall(mcp.getSilos)
        if okSilos and type(silos) == "table" then
            for _, s in ipairs(silos) do
                if not s.valvesOpen then pcall(mcp.siloAction, s.id, "VALVES") end
                if pcall(mcp.siloAction, s.id, "ARM") then armedCount = armedCount + 1 end
            end
        end
        pollMcp()
        modem.transmit(replyChannel, CHANNEL, encryptPacket({
            type = "FIRE_REPLY",
            requestId = msg.requestId,
            ok = true,
            message = string.format("ARMED %d SILO(S)", armedCount),
            status = buildRemoteStatusPayload(),
        }))
    end
end

--------------------------------------------------------------------------------
-- 12. Main Concurrent Event + Render Loop
--------------------------------------------------------------------------------
local sweepAngle = math.rad(45)
local SWEEP_SPEED = math.rad(6)
local lastPoll = 0

pollMcp()
drawComputerTerminal()

local frameTimer = os.startTimer(0.05)

while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()

    if event == "timer" and p1 == frameTimer then
        local now = os.clock()
        if now - lastPoll >= POLL_INTERVAL then
            pollMcp()
            lastPoll = now
        end

        tickCounter = tickCounter + 1
        updateFramebuffer(sweepAngle)
        drawMainMonitor()

        if keyMon then
            local kw, kh = keyMon.getSize()
            drawStrikeKeypadPanel(keyMon, kw, kh, false)
        end

        if state.online then
            sweepAngle = (sweepAngle + SWEEP_SPEED) % TWO_PI
        end
        frameTimer = os.startTimer(0.05)

    elseif event == "monitor_touch" then
        local side, tx, ty = p1, p2, p3
        if keyMonName and side == keyMonName then
            local kw, kh = keyMon.getSize()
            handleKeypadMonitorTouch(kw, kh, tx, ty, false)
            drawStrikeKeypadPanel(keyMon, kw, kh, false)
        else
            handleMainRadarTouch(tx, ty)
            drawMainMonitor()
        end
        drawComputerTerminal()

    elseif event == "modem_message" then
        local replyChannel, wrapper = p3, p4
        handleModemMessage(replyChannel, wrapper)

    elseif event == "key" then
        local k = p1
        if k == keys.x then
            sleep(0.05)
            local v = tonumber(promptTerminalLine("Enter Target X: "))
            if v then strikeCfg.targetX = floor(v) end
            drawComputerTerminal()
            frameTimer = os.startTimer(0.05)
        elseif k == keys.y then
            sleep(0.05)
            local v = tonumber(promptTerminalLine("Enter Target Y: "))
            if v then strikeCfg.targetY = max(-64, min(320, floor(v))) end
            drawComputerTerminal()
            frameTimer = os.startTimer(0.05)
        elseif k == keys.z then
            sleep(0.05)
            local v = tonumber(promptTerminalLine("Enter Target Z: "))
            if v then strikeCfg.targetZ = floor(v) end
            drawComputerTerminal()
            frameTimer = os.startTimer(0.05)
        elseif k == keys.c then
            sleep(0.05)
            local v = tonumber(promptTerminalLine("Enter Missile Count (1-64): "))
            if v then strikeCfg.count = max(1, min(64, floor(v))) end
            drawComputerTerminal()
            frameTimer = os.startTimer(0.05)
        elseif k == keys.s then
            sleep(0.05)
            local v = tonumber(promptTerminalLine("Enter Spread Radius (0-256m): "))
            if v then strikeCfg.spread = max(0, min(256, floor(v))) end
            drawComputerTerminal()
            frameTimer = os.startTimer(0.05)
        elseif k == keys.m then
            strikeCfg.modeIdx = (strikeCfg.modeIdx % #FIRE_MODES) + 1
            drawComputerTerminal()
        elseif k == keys.r then
            local _, msg = scanAndRegisterDevices(64)
            strikeCfg.lastStatus = msg
            pollMcp()
            drawComputerTerminal()
        elseif k == keys.g then
            sleep(0.05)
            local raw = promptTerminalLine("Register Rocket 'X Y Z': ")
            local rx, ry, rz = raw:match("(-?%d+)%s+(-?%d+)%s+(-?%d+)")
            if rx and ry and rz and mcp.registerRocket then
                local okR, resR = pcall(mcp.registerRocket, tonumber(rx), tonumber(ry), tonumber(rz))
                if okR and type(resR) == "table" then
                    strikeCfg.lastStatus = tostring(resR.message)
                end
                pollMcp()
            end
            drawComputerTerminal()
            frameTimer = os.startTimer(0.05)
        elseif k == keys.k then
            sleep(0.05)
            local newK = promptTerminalLine("New Secret Key (match on pocket): ")
            if newK and #newK > 0 then
                SECRET_KEY = newK
                saveSecretKey(SECRET_KEY)
                strikeCfg.lastStatus = "Encryption key updated!"
            end
            drawComputerTerminal()
            frameTimer = os.startTimer(0.05)
        elseif k == keys.f or k == keys.enter then
            local _, msg = executeLaunch({
                x = strikeCfg.targetX, y = strikeCfg.targetY, z = strikeCfg.targetZ,
                count = strikeCfg.count, spread = strikeCfg.spread,
                fireMode = FIRE_MODES[strikeCfg.modeIdx],
                attackProfile = PROFILES[strikeCfg.profileIdx],
                impactMode = IMPACTS[strikeCfg.impactIdx],
            })
            strikeCfg.lastStatus = msg
            pollMcp()
            drawComputerTerminal()
        end
    end
end
