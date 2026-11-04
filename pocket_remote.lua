-- Project Eclipse - Encrypted Multi-Window Pocket Strike & Radar Remote (CC:Tweaked)
-- Runs on a Wireless / Ender Pocket Computer (26x20 screen).
-- Communicates with radar.lua using encrypted + MAC-authenticated packets (ECLIPSE_ENC_V2).
-- Windows:
--   [1:STRIKE] - Target XYZ, GPS lock, Count, Spread, Mode (incl. THOR), Launch
--   [2:RADAR]  - Live subpixel radar scope, tap-to-aim on radar map, quick fire
--   [3:NODES]  - Remote Rocket/Device Registration (scanAndRegister / registerRocket) & Encryption Key

local CHANNEL       = 4920
local REPLY_CHANNEL = 4921
local PROTOCOL      = "ECLIPSE_ENC_V2"
local KEY_FILE      = ".eclipse_key"
local DEFAULT_KEY   = "ECLIPSE-77"

--------------------------------------------------------------------------------
-- 1. Encryption & Anti-Replay Security (Matches radar.lua)
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

local function decryptPacket(wrapper)
    if type(wrapper) ~= "table" or wrapper.protocol ~= PROTOCOL then
        return nil, "Bad protocol"
    end
    if type(wrapper.nonce) ~= "string" or type(wrapper.cipher) ~= "string" or type(wrapper.mac) ~= "string" then
        return nil, "Malformed packet"
    end
    if seenNonces[wrapper.nonce] then
        return nil, "Replay rejected"
    end
    local expectedMac = computeMac(SECRET_KEY, wrapper.nonce, wrapper.cipher)
    if expectedMac ~= wrapper.mac then
        return nil, "MAC mismatch (Check Key)"
    end

    seenNonces[wrapper.nonce] = true
    table.insert(seenNonceOrder, wrapper.nonce)
    if #seenNonceOrder > 64 then
        local old = table.remove(seenNonceOrder, 1)
        seenNonces[old] = nil
    end

    local rawCipher = fromHex(wrapper.cipher)
    if not rawCipher then return nil, "Bad hex" end
    local plain = cryptBytes(rawCipher, SECRET_KEY, wrapper.nonce)
    local ok, tbl = pcall(textutils.unserialize, plain)
    if not ok or type(tbl) ~= "table" then
        return nil, "Unserialize failed"
    end
    return tbl
end

--------------------------------------------------------------------------------
-- 2. Wireless Modem & Custom Palette Setup
--------------------------------------------------------------------------------
local modem = peripheral.find("modem", function(_, m)
    return m.isWireless and m.isWireless()
end)
if not modem then
    error("No Wireless Modem found! Use a Wireless Pocket Computer.")
end
modem.open(REPLY_CHANNEL)

local W, H = term.getSize() -- 26x20 on Pocket Computer

local SHADE_BLIT = {
    [0] = "f",
    [1] = "2",
    [2] = "3",
    [3] = "6",
    [4] = "b",
    [5] = "a",
    [6] = "5",
}

local function setupPalette()
    if not term.setPaletteColor then return end
    term.setPaletteColor(colors.black,     0x000000) -- 'f'
    term.setPaletteColor(colors.magenta,   0x031A05) -- '2'
    term.setPaletteColor(colors.lightBlue, 0x082E0B) -- '3'
    term.setPaletteColor(colors.pink,      0x0F4712) -- '6'
    term.setPaletteColor(colors.blue,      0x1A6B1E) -- 'b'
    term.setPaletteColor(colors.purple,    0x29A32E) -- 'a'
    term.setPaletteColor(colors.lime,      0x55FF55) -- '5'

    term.setPaletteColor(colors.red,       0xFF2222) -- 'e'
    term.setPaletteColor(colors.orange,    0xFF8800) -- '1'
    term.setPaletteColor(colors.yellow,    0xFFDD22) -- '4'
    term.setPaletteColor(colors.cyan,      0x33DDFF) -- '9'
    term.setPaletteColor(colors.white,     0xE8FFE8) -- '0'
    term.setPaletteColor(colors.lightGray, 0x77AA77) -- '8'
    term.setPaletteColor(colors.gray,      0x223822) -- '7'
end

setupPalette()

--------------------------------------------------------------------------------
-- 3. State & Encrypted Transmission
--------------------------------------------------------------------------------
local FIRE_MODES = { "AUTO", "1", "2", "3", "4", "5", "6", "BIG_ONE", "CRUISE", "SALVO", "THOR" }
local PROFILES   = { "HIGH_BALLISTIC", "LOW_TRAJECTORY", "TERRAIN_HUG" }
local IMPACTS    = { "SURFACE", "AIRBURST", "BUNKER_BUSTER" }

local state = {
    activeTab = 1, -- 1 = STRIKE, 2 = RADAR, 3 = NODES/KEY
    targetX = 0,
    targetY = 64,
    targetZ = 0,
    count = 4,
    spread = 16,
    modeIdx = 1,
    profileIdx = 1,
    impactIdx = 1,
    connected = false,
    serverStatus = {
        online = false,
        originX = 0,
        originY = 64,
        originZ = 0,
        radarRange = 500,
        radarCount = 0,
        readyCiws = 0,
        ciwsAmmo = 0,
        readyMissiles = 0,
        launcherCount = 0,
        placedCount = 0,
        activeFlights = 0,
        threatCount = 0,
        siloReady = 0,
        thorRods = 0,
        blips = {},
        threats = {},
    },
    statusMsg = "Connecting (Encrypted)...",
    statusColor = colors.yellow,
}

local reqCounter = math.random(1000, 9999)
local function sendEncrypted(pktType, payload)
    reqCounter = reqCounter + 1
    local msg = payload or {}
    msg.type = pktType
    msg.requestId = reqCounter
    modem.transmit(CHANNEL, REPLY_CHANNEL, encryptPacket(msg))
    return reqCounter
end

--------------------------------------------------------------------------------
-- 4. Pocket Radar Subpixel Engine (For Window 2: RADAR VIEW)
-- Renders onto rows 3..16 of the 26x20 pocket screen (14 rows = 52x42 square subpixels)
--------------------------------------------------------------------------------
local RDR_TOP_ROW = 3
local RDR_ROWS    = 14
local RPW         = W * 2         -- 52 subpixels wide
local RPH         = RDR_ROWS * 3  -- 42 subpixels tall
local RCX         = (RPW + 1) / 2
local RCY         = (RPH + 1) / 2
local R_RADIUS    = floor(min(RPW, RPH) / 2) - 1 -- 20 subpixels radius
local TRAIL_ARC   = math.rad(65)

local rStaticDist, rStaticAngle, rStaticInside, rStaticGrid, rStaticOuter = {}, {}, {}, {}, {}
local rFb, rOverlay, rOverlayPrio = {}, {}, {}

for py = 1, RPH do
    rStaticDist[py] = {}
    rStaticAngle[py] = {}
    rStaticInside[py] = {}
    rStaticGrid[py] = {}
    rStaticOuter[py] = {}
    rFb[py] = {}
    rOverlay[py] = {}
    rOverlayPrio[py] = {}

    local dy = py - RCY
    for px = 1, RPW do
        rFb[py][px] = 0
        local dx = px - RCX
        local dist = sqrt(dx * dx + dy * dy)
        rStaticDist[py][px] = dist
        if dist <= R_RADIUS + 0.45 then
            rStaticInside[py][px] = true
            local ang = (atan2(dx, -dy) + TWO_PI) % TWO_PI
            rStaticAngle[py][px] = ang
            local isOuter = abs(dist - R_RADIUS) <= 0.55
            rStaticOuter[py][px] = isOuter
            local isInner = abs(dist - (R_RADIUS * 0.5)) <= 0.42
            local isCard = (abs(dx) <= 0.45) or (abs(dy) <= 0.45)
            rStaticGrid[py][px] = isOuter or isInner or isCard
        else
            rStaticInside[py][px] = false
        end
    end
end

local function setPocketOverlay(px, py, col, prio)
    if px < 1 or px > RPW or py < 1 or py > RPH then return end
    if not rStaticInside[py][px] then return end
    if prio >= (rOverlayPrio[py][px] or 0) then
        rOverlay[py][px] = col
        rOverlayPrio[py][px] = prio
    end
end

local sweepAngle = math.rad(45)
local tickCounter = 0

local function renderPocketRadar(sweep)
    for py = 1, RPH do
        for px = 1, RPW do
            rOverlay[py][px] = nil
            rOverlayPrio[py][px] = 0
            if not rStaticInside[py][px] then
                rFb[py][px] = 0
            else
                local dist = rStaticDist[py][px]
                if dist <= 0.8 then
                    rFb[py][px] = 6
                else
                    local ang = rStaticAngle[py][px]
                    local behind = (sweep - ang) % TWO_PI
                    local arcDist = behind * dist
                    if (behind < 0.20 or (TWO_PI - behind) < 0.05) and arcDist <= 0.75 then
                        rFb[py][px] = 6
                    else
                        local trailShade = 1
                        if behind <= TRAIL_ARC then
                            local t = 1.0 - (behind / TRAIL_ARC)
                            if t > 0.75 then trailShade = 5
                            elseif t > 0.45 then trailShade = 4
                            elseif t > 0.20 then trailShade = 3
                            else trailShade = 2 end
                        end
                        if rStaticOuter[py][px] then
                            rFb[py][px] = (trailShade >= 5) and 6 or 5
                        elseif rStaticGrid[py][px] then
                            rFb[py][px] = (trailShade >= 4) and 5 or 4
                        else
                            rFb[py][px] = trailShade
                        end
                    end
                end
            end
        end
    end

    local range = max(1, state.serverStatus.radarRange or 500)
    local usableR = R_RADIUS - 1.2

    -- Draw selected Target Crosshair (+) on the pocket radar
    local tdx = (state.targetX - (state.serverStatus.originX or 0)) / range
    local tdz = (state.targetZ - (state.serverStatus.originZ or 0)) / range
    local tDist = sqrt(tdx * tdx + tdz * tdz)
    if tDist > 1.0 then tdx, tdz = tdx / tDist, tdz / tDist end
    local tx = floor(RCX + tdx * usableR + 0.5)
    local tz = floor(RCY + tdz * usableR + 0.5)
    local crossCol = (tickCounter % 6 < 3) and "1" or "0"
    setPocketOverlay(tx - 1, tz, crossCol, 3)
    setPocketOverlay(tx + 1, tz, crossCol, 3)
    setPocketOverlay(tx, tz - 1, crossCol, 3)
    setPocketOverlay(tx, tz + 1, crossCol, 3)

    -- Plot live blips streamed from radar.lua
    local blips = state.serverStatus.blips or {}
    for _, b in ipairs(blips) do
        local nx = (b.dx or 0) / range
        local nz = (b.dz or 0) / range
        local nd = sqrt(nx * nx + nz * nz)
        if nd > 1.0 then nx, nz = nx / nd, nz / nd end
        local bx = floor(RCX + nx * usableR + 0.5)
        local by = floor(RCY + nz * usableR + 0.5)
        setPocketOverlay(bx, by, b.c or "e", b.p or 4)
        if (b.p or 0) >= 4 and (tickCounter % 4 < 2) then
            setPocketOverlay(bx + 1, by, b.c or "e", b.p or 4)
            setPocketOverlay(bx, by + 1, b.c or "e", b.p or 4)
        end
    end

    -- Blit rows 3..16
    for r = 1, RDR_ROWS do
        local py0 = (r - 1) * 3 + 1
        local row1, row2, row3 = rFb[py0], rFb[py0 + 1], rFb[py0 + 2]
        local ov1, ov2, ov3 = rOverlay[py0], rOverlay[py0 + 1], rOverlay[py0 + 2]
        local pr1, pr2, pr3 = rOverlayPrio[py0], rOverlayPrio[py0 + 1], rOverlayPrio[py0 + 2]
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
                local mask = (o1 and 1 or 0) + (o2 and 2 or 0) + (o3 and 4 or 0) + (o4 and 8 or 0) + (o5 and 16 or 0)
                if o6 then
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
                    local mask = ((s1 > mid) and 1 or 0)
                        + ((s2 > mid) and 2 or 0)
                        + ((s3 > mid) and 4 or 0)
                        + ((s4 > mid) and 8 or 0)
                        + ((s5 > mid) and 16 or 0)
                    local fgColor = SHADE_BLIT[maxS]
                    local bgColor = SHADE_BLIT[minS]
                    if s6 > mid then
                        mask = 31 - mask
                        fgColor, bgColor = bgColor, fgColor
                    end
                    chars[cx] = char(128 + mask)
                    fgs[cx] = fgColor
                    bgs[cx] = bgColor
                end
            end
        end

        term.setCursorPos(1, RDR_TOP_ROW + r - 1)
        term.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
    end
end

local function pocketRadarClickToWorld(charX, charY)
    local relRow = charY - RDR_TOP_ROW + 1
    if relRow < 1 or relRow > RDR_ROWS then return nil, nil end
    local px = (charX - 0.5) * 2
    local py = (relRow - 0.5) * 3
    local dx = px - RCX
    local dy = py - RCY
    if sqrt(dx * dx + dy * dy) > R_RADIUS then return nil, nil end
    local usableR = R_RADIUS - 1.2
    local range = max(1, state.serverStatus.radarRange or 500)
    local wx = floor((state.serverStatus.originX or 0) + (dx / usableR) * range + 0.5)
    local wz = floor((state.serverStatus.originZ or 0) + (dy / usableR) * range + 0.5)
    return wx, wz
end

--------------------------------------------------------------------------------
-- 5. Multi-Window UI Rendering (26x20 Pocket Computer)
--------------------------------------------------------------------------------
local function drawLine(y, text, fg, bg)
    term.setCursorPos(1, y)
    term.setTextColor(fg or colors.white)
    term.setBackgroundColor(bg or colors.black)
    if #text < W then
        text = text .. string.rep(" ", W - #text)
    elseif #text > W then
        text = text:sub(1, W)
    end
    term.write(text)
end

local function drawButton(x, y, label, fg, bg)
    term.setCursorPos(x, y)
    term.setTextColor(fg)
    term.setBackgroundColor(bg)
    term.write(label)
end

local function drawTabBar()
    drawLine(1, "", colors.white, colors.gray)
    drawButton(1,  1, " 1:STRIKE ", state.activeTab == 1 and colors.black or colors.white, state.activeTab == 1 and colors.lime or colors.gray)
    drawButton(11, 1, " 2:RADAR ",  state.activeTab == 2 and colors.black or colors.white, state.activeTab == 2 and colors.lime or colors.gray)
    drawButton(20, 1, " 3:LINK",    state.activeTab == 3 and colors.black or colors.white, state.activeTab == 3 and colors.lime or colors.gray)

    if state.connected and state.serverStatus.online then
        drawLine(2, string.format(" ENC:OK  MSLS:%-2d THR:%d",
            state.serverStatus.readyMissiles or 0,
            state.serverStatus.threatCount or 0), colors.lime, colors.black)
    elseif state.connected then
        drawLine(2, " ENC:OK  MCP:EMP/OFFLINE", colors.red, colors.black)
    else
        drawLine(2, " ENC:SEARCHING SERVER...", colors.yellow, colors.black)
    end
end

local function drawUI()
    if state.activeTab ~= 2 then
        term.setBackgroundColor(colors.black)
        term.clear()
    end

    drawTabBar()

    if state.activeTab == 1 then
        -- WINDOW 1: STRIKE CONTROLLER
        drawLine(3, string.format(" LNCH:%-2d SILO:%-1d THOR:%d",
            state.serverStatus.launcherCount or 0,
            state.serverStatus.siloReady or 0,
            state.serverStatus.thorRods or 0), colors.lightGray, colors.black)

        drawLine(4, "---- TARGET COORDS -------", colors.green, colors.black)
        drawLine(5, string.format(" X: %-10d", state.targetX), colors.white, colors.black)
        drawButton(16, 5, "[EDIT X]", colors.black, colors.lightGray)

        drawLine(6, string.format(" Y: %-10d", state.targetY), colors.white, colors.black)
        drawButton(16, 6, "[EDIT Y]", colors.black, colors.lightGray)

        drawLine(7, string.format(" Z: %-10d", state.targetZ), colors.white, colors.black)
        drawButton(16, 7, "[EDIT Z]", colors.black, colors.lightGray)

        drawButton(2,  8, "[ GPS HERE ]", colors.black, colors.cyan)
        drawButton(15, 8, "[ARM SILO]",   colors.black, colors.orange)

        drawLine(9, "---- STRIKE OPTIONS ------", colors.green, colors.black)

        drawLine(10, string.format(" COUNT  : %-3d", state.count), colors.white, colors.black)
        drawButton(16, 10, "[-]", colors.white, colors.gray)
        drawButton(20, 10, "[+]", colors.white, colors.gray)

        drawLine(11, string.format(" SPREAD : %-3dm", state.spread), colors.lime, colors.black)
        drawButton(16, 11, "[-]", colors.white, colors.gray)
        drawButton(20, 11, "[+]", colors.white, colors.gray)

        local modeName = FIRE_MODES[state.modeIdx]
        drawLine(12, " MODE   : ", colors.lightGray, colors.black)
        drawButton(11, 12, string.format("[ %-10s ]", modeName), colors.yellow, colors.gray)

        local profName = PROFILES[state.profileIdx]
        drawLine(13, " PROFILE: ", colors.lightGray, colors.black)
        drawButton(11, 13, string.format("[ %-12s ]", profName:sub(1, 12)), colors.cyan, colors.gray)

        local impName = IMPACTS[state.impactIdx]
        drawLine(14, " IMPACT : ", colors.lightGray, colors.black)
        drawButton(11, 14, string.format("[ %-12s ]", impName:sub(1, 12)), colors.orange, colors.gray)

        drawLine(16, "==========================", colors.red, colors.black)
        drawLine(17, "  >>> LAUNCH STRIKE <<<   ", colors.white, colors.red)
        drawLine(18, "==========================", colors.red, colors.black)

    elseif state.activeTab == 2 then
        -- WINDOW 2: LIVE POCKET RADAR SCOPE (Rows 3..16)
        renderPocketRadar(sweepAngle)
        drawLine(17, string.format(" AIM:%d,%d RNG:%dm",
            state.targetX, state.targetZ, state.serverStatus.radarRange or 500), colors.white, colors.black)
        drawLine(18, "   [ >> FIRE AT AIM << ]  ", colors.white, colors.red)

    elseif state.activeTab == 3 then
        -- WINDOW 3: ROCKET REGISTRATION & ENCRYPTION SETTINGS
        drawLine(4, "-- ROCKET REGISTRATION ---", colors.green, colors.black)
        drawLine(5, string.format(" Floor Msls: %d | Total: %d",
            state.serverStatus.placedCount or 0,
            state.serverStatus.readyMissiles or 0), colors.white, colors.black)

        drawButton(2, 7,  "[ SCAN & REGISTER (64m) ]", colors.black, colors.lime)
        drawButton(2, 9,  "[ REGISTER @ TARGET XYZ ]", colors.black, colors.cyan)
        drawButton(2, 11, "[ REGISTER @ MY GPS XYZ ]", colors.black, colors.orange)

        drawLine(13, "-- ENCRYPTION SECURITY ---", colors.green, colors.black)
        drawLine(14, " Key: " .. SECRET_KEY, colors.yellow, colors.black)
        drawLine(15, " Cipher: XOR-64 + KeyedMAC", colors.lightGray, colors.black)
        drawButton(2, 17, "[ CHANGE ENCRYPTION KEY ]", colors.black, colors.yellow)
    end

    drawLine(19, " " .. (state.statusMsg or ""), state.statusColor, colors.black)
    drawLine(20, " [Tab] Switch Win [F] Fire", colors.lightGray, colors.black)
end

local function promptInput(label, currentVal, isNumber)
    term.setCursorPos(1, 19)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.clearLine()
    term.write(label .. ": ")
    term.setCursorBlink(true)
    local input = read()
    term.setCursorBlink(false)
    if isNumber then
        local num = tonumber(input)
        return num and floor(num) or currentVal
    end
    if input and #input > 0 then return input end
    return currentVal
end

local function triggerLaunch()
    state.statusMsg = "Sending encrypted FIRE..."
    state.statusColor = colors.yellow
    drawUI()
    sendEncrypted("FIRE", {
        x = state.targetX,
        y = state.targetY,
        z = state.targetZ,
        count = state.count,
        spread = state.spread,
        fireMode = FIRE_MODES[state.modeIdx],
        attackProfile = PROFILES[state.profileIdx],
        impactMode = IMPACTS[state.impactIdx],
    })
end

--------------------------------------------------------------------------------
-- 6. Main Pocket Loop
--------------------------------------------------------------------------------
drawUI()
sendEncrypted("STATUS")
local pollTimer = os.startTimer(0.8)
local animTimer = os.startTimer(0.1)

while true do
    local event, p1, p2, p3, p4 = os.pullEvent()

    if event == "modem_message" then
        local wrapper = p4
        local msg, err = decryptPacket(wrapper)
        if msg then
            state.connected = true
            if msg.status then
                state.serverStatus = msg.status
            end
            if msg.type == "STATUS_REPLY" then
                if state.statusMsg == "Connecting (Encrypted)..." then
                    state.statusMsg = "Encrypted Link Active"
                    state.statusColor = colors.lime
                end
            elseif msg.type == "FIRE_REPLY" then
                state.statusMsg = tostring(msg.message or (msg.ok and "SUCCESS" or "FAILED"))
                state.statusColor = msg.ok and colors.lime or colors.red
            end
            drawUI()
        elseif err and err:find("MAC mismatch") then
            state.statusMsg = "KEY MISMATCH! Check Tab 3"
            state.statusColor = colors.red
            drawUI()
        end

    elseif event == "mouse_click" then
        local _, x, y = p1, p2, p3

        -- Top Tab Bar (Row 1)
        if y == 1 then
            if x <= 10 then state.activeTab = 1
            elseif x <= 19 then state.activeTab = 2
            else state.activeTab = 3 end
            drawUI()

        elseif state.activeTab == 1 then
            if y == 5 then
                state.targetX = promptInput("Target X", state.targetX, true)
                drawUI()
            elseif y == 6 then
                state.targetY = max(-64, min(320, promptInput("Target Y", state.targetY, true)))
                drawUI()
            elseif y == 7 then
                state.targetZ = promptInput("Target Z", state.targetZ, true)
                drawUI()
            elseif y == 8 and x >= 2 and x <= 13 then
                state.statusMsg = "Locating via GPS..."
                state.statusColor = colors.cyan
                drawUI()
                local gx, gy, gz = gps.locate(1.5)
                if gx then
                    state.targetX, state.targetY, state.targetZ = floor(gx), floor(gy), floor(gz)
                    state.statusMsg = "GPS locked!"
                    state.statusColor = colors.lime
                else
                    state.statusMsg = "No GPS signal"
                    state.statusColor = colors.orange
                end
                drawUI()
            elseif y == 8 and x >= 15 and x <= 24 then
                state.statusMsg = "Arming Strategic Silos..."
                state.statusColor = colors.orange
                drawUI()
                sendEncrypted("SILO_ARM")
            elseif y == 10 then
                if x >= 16 and x <= 18 then state.count = max(1, state.count - 1)
                elseif x >= 20 and x <= 22 then state.count = min(64, state.count + 1)
                else state.count = max(1, min(64, promptInput("Count (1-64)", state.count, true))) end
                drawUI()
            elseif y == 11 then
                if x >= 16 and x <= 18 then state.spread = max(0, state.spread - 4)
                elseif x >= 20 and x <= 22 then state.spread = min(256, state.spread + 4)
                else state.spread = max(0, min(256, promptInput("Spread (0-256m)", state.spread, true))) end
                drawUI()
            elseif y == 12 then
                state.modeIdx = (state.modeIdx % #FIRE_MODES) + 1
                drawUI()
            elseif y == 13 then
                state.profileIdx = (state.profileIdx % #PROFILES) + 1
                drawUI()
            elseif y == 14 then
                state.impactIdx = (state.impactIdx % #IMPACTS) + 1
                drawUI()
            elseif y >= 16 and y <= 18 then
                triggerLaunch()
            end

        elseif state.activeTab == 2 then
            if y >= RDR_TOP_ROW and y < RDR_TOP_ROW + RDR_ROWS then
                local wx, wz = pocketRadarClickToWorld(x, y)
                if wx and wz then
                    state.targetX = wx
                    state.targetZ = wz
                    state.statusMsg = string.format("Radar Aim: %d, %d", wx, wz)
                    state.statusColor = colors.lime
                    drawUI()
                end
            elseif y == 18 then
                triggerLaunch()
            end

        elseif state.activeTab == 3 then
            if y == 7 then
                state.statusMsg = "Scanning 64m for rockets..."
                state.statusColor = colors.cyan
                drawUI()
                sendEncrypted("SCAN_REGISTER", { radius = 64 })
            elseif y == 9 then
                state.statusMsg = "Registering @ Target XYZ..."
                state.statusColor = colors.cyan
                drawUI()
                sendEncrypted("REGISTER_XYZ", { x = state.targetX, y = state.targetY, z = state.targetZ })
            elseif y == 11 then
                local gx, gy, gz = gps.locate(1.5)
                if gx then
                    state.statusMsg = string.format("Reg @ GPS %d,%d,%d", floor(gx), floor(gy), floor(gz))
                    state.statusColor = colors.cyan
                    drawUI()
                    sendEncrypted("REGISTER_XYZ", { x = floor(gx), y = floor(gy), z = floor(gz) })
                else
                    state.statusMsg = "No GPS signal found"
                    state.statusColor = colors.orange
                    drawUI()
                end
            elseif y == 17 then
                local newKey = promptInput("New Secret Key", SECRET_KEY, false)
                SECRET_KEY = newKey
                saveSecretKey(SECRET_KEY)
                state.statusMsg = "Key saved!"
                state.statusColor = colors.lime
                drawUI()
                sendEncrypted("STATUS")
            end
        end

    elseif event == "key" then
        local key = p1
        if key == keys.tab then
            state.activeTab = (state.activeTab % 3) + 1
            drawUI()
        elseif key == keys.one then
            state.activeTab = 1; drawUI()
        elseif key == keys.two then
            state.activeTab = 2; drawUI()
        elseif key == keys.three then
            state.activeTab = 3; drawUI()
        elseif key == keys.f or key == keys.enter then
            triggerLaunch()
        elseif key == keys.r then
            sendEncrypted("SCAN_REGISTER", { radius = 64 })
        end

    elseif event == "timer" and p1 == pollTimer then
        sendEncrypted("STATUS")
        pollTimer = os.startTimer(0.8)

    elseif event == "timer" and p1 == animTimer then
        tickCounter = tickCounter + 1
        sweepAngle = (sweepAngle + math.rad(10)) % TWO_PI
        if state.activeTab == 2 then
            renderPocketRadar(sweepAngle)
        end
        animTimer = os.startTimer(0.1)
    end
end
