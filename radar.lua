-- Project Eclipse - Live MCP Radar & CIWS Air Defense Display (CC:Tweaked)
-- Target monitor: monitor_0 (51x19)
-- Uses 2x3 teletext subpixel rendering (102x57 square subpixels on a 51x19 monitor)

local MONITOR_NAME = "monitor_0"
local DEFAULT_RANGE = 500 -- Fallback radar range (blocks) if no radar reports range
local POLL_INTERVAL = 0.20 -- Poll MCP & engage threats every 0.20s (4 ticks)
local ZONE_RADIUS = 512   -- Auto-protected defense zone radius around base

-- 1. Connect to Monitor
local mon = peripheral.wrap(MONITOR_NAME) or peripheral.find("monitor")
if not mon then
    error("Could not find " .. MONITOR_NAME .. " (or any connected monitor)")
end

mon.setTextScale(1)
local W, H = mon.getSize()

-- 2. Connect & Authenticate with Missile Control Panel (MCP)
local mcp = peripheral.find("missile_control_panel")
if not mcp then
    error("No Missile Control Panel (missile_control_panel) found! Connect computer via modem/cable or place adjacent.")
end

local function ensureAuthenticated()
    if mcp.isAuthenticated() then
        return true
    end
    local ok = pcall(function() mcp.authenticate() end)
    if ok and mcp.isAuthenticated() then
        return true
    end

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
            if token == "" then
                mcp.authenticate()
            else
                mcp.authenticate(token)
            end
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

-- 3. Configure Automated CIWS & Air Defense on MCP
local defenseConfigured = false
local function configureAirDefense(centerX, centerZ)
    pcall(mcp.setDefenseMode, "AUTO")
    pcall(mcp.setDefenseDoctrine, "MAXIMUM_DEFENSE")
    pcall(mcp.setInterceptorLauncherMode, "BOTH")
    pcall(mcp.setPursuitAuto, true)

    -- Ensure a CRITICAL auto-engage Protected Defense Zone covers the base & CIWS
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

print("Radar & CIWS Air Defense active on " .. MONITOR_NAME .. " (" .. W .. "x" .. H .. ")")

-- 4. Custom Palette Setup (7 phosphor green shades + tactical blip & HUD colors)
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
    if not target.setPaletteColor then return end
    -- Radar green phosphor shades
    target.setPaletteColor(colors.black,     0x000000) -- 'f': Outside background
    target.setPaletteColor(colors.magenta,   0x031A05) -- '2': Shade 1 - Radar disc dark interior
    target.setPaletteColor(colors.lightBlue, 0x082E0B) -- '3': Shade 2 - Sweep trail tail
    target.setPaletteColor(colors.pink,      0x0F4712) -- '6': Shade 3 - Sweep trail mid
    target.setPaletteColor(colors.blue,      0x1A6B1E) -- 'b': Shade 4 - Range rings & spokes
    target.setPaletteColor(colors.purple,    0x29A32E) -- 'a': Shade 5 - Lit rings & near-beam glow
    target.setPaletteColor(colors.lime,      0x55FF55) -- '5': Shade 6 - Bright sweep beam

    -- Tactical blip & HUD colors
    target.setPaletteColor(colors.red,       0xFF2222) -- 'e': Hostile missile / critical threat
    target.setPaletteColor(colors.orange,    0xFF8800) -- '1': Hostile aircraft/player/vehicle track
    target.setPaletteColor(colors.yellow,    0xFFDD22) -- '4': Unknown radar contact / CIWS tracer
    target.setPaletteColor(colors.cyan,      0x33DDFF) -- '9': Friendly track / CIWS turret / UAV
    target.setPaletteColor(colors.white,     0xE8FFE8) -- '0': Crisp HUD value text
    target.setPaletteColor(colors.lightGray, 0x77AA77) -- '8': HUD secondary text
    target.setPaletteColor(colors.gray,      0x335533) -- '7': HUD labels
end

setupPalette(mon)
mon.setBackgroundColor(colors.black)
mon.clear()

-- 5. Subpixel Geometry (102x57 square subpixels on 51x19 monitor)
local PW = W * 2
local PH = H * 3

local CX = (PW + 1) / 2
local CY = (PH + 1) / 2
local RADIUS = math.floor(math.min(PW, PH) / 2) - 1 -- 27 subpixels on 51x19
local NUM_RINGS = 4
local NUM_SPOKES = 12
local TRAIL_ARC = math.rad(65)

local TWO_PI = math.pi * 2
local char = string.char
local floor = math.floor
local sqrt = math.sqrt
local atan2 = math.atan2
local abs = math.abs
local min = math.min
local max = math.max

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

-- Framebuffers:
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

-- 6. Live MCP State, CIWS Tracking & Active Threat Engagement
local state = {
    online = true,
    empTicks = 0,
    originX = 0,
    originZ = 0,
    radarRange = DEFAULT_RANGE,
    radarCount = 0,
    defenseMode = "AUTO",
    defenseDoctrine = "MAX",
    readyCiws = 0,
    ciwsAmmo = 0,
    readyInterceptors = 0,
    ciwsNodes = {},   -- Connected CIWS positions { x, z, readyCount }
    blips = {},       -- { x, z, vx, vz, color, prio, pulse, engaged }
    threatList = {},  -- Sorted list for right-hand HUD
    threatCount = 0,
    trackCount = 0,
    flightCount = 0,
    engaging = false,
}

local function pollMcp()
    if not mcp.isAuthenticated() then return end

    local okInfo, netInfo = pcall(mcp.getNetworkInfo)
    if not okInfo or not netInfo then return end

    state.online = netInfo.networkOnline ~= false
    state.empTicks = netInfo.empRemainingTicks or 0
    state.defenseMode = netInfo.defenseMode or "AUTO"
    state.defenseDoctrine = netInfo.defenseDoctrine or "MAXIMUM_DEFENSE"
    state.readyCiws = netInfo.readyCiws or 0
    state.ciwsAmmo = netInfo.ciwsAmmo or 0
    state.readyInterceptors = netInfo.readyInterceptors or 0
    state.radarCount = netInfo.radarCount or 0

    local ox = netInfo.x or 0
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
    state.originZ = oz
    state.radarRange = (maxRange > 0) and maxRange or DEFAULT_RANGE

    -- Ensure AUTO defense mode, MAXIMUM_DEFENSE doctrine, and Protected Zone are active
    if not defenseConfigured or state.defenseMode ~= "AUTO" then
        configureAirDefense(ox, oz)
    end

    -- Discover connected CIWS turret nodes so we can display them & draw fire lines
    local ciwsNodes = {}
    local okNodes, nodes = pcall(mcp.getNodes)
    if okNodes and type(nodes) == "table" then
        for _, n in ipairs(nodes) do
            if n.type == "CIWS" and n.connected then
                table.insert(ciwsNodes, {
                    id = n.id,
                    x = n.x or ox,
                    z = n.z or oz,
                    ammo = n.readyCount or 0,
                })
            end
        end
    end
    state.ciwsNodes = ciwsNodes

    local blips = {}
    local threatList = {}
    local seenIds = {}
    local engageIds = {}
    local anyEngaging = false

    -- A. Evaluated incoming missile threats (Highest priority - Red 'e')
    local okContacts, contacts = pcall(mcp.getContacts)
    if okContacts and type(contacts) == "table" then
        state.threatCount = #contacts
        for _, c in ipairs(contacts) do
            if c.x and c.z then
                if c.id then
                    seenIds[c.id] = true
                    table.insert(engageIds, c.id)
                end
                local dx = c.x - ox
                local dz = c.z - oz
                local dist = sqrt(dx * dx + dz * dz)
                local isEngaged = (c.trackState == "ENGAGED") or (dist <= 200 and state.readyCiws > 0)
                if isEngaged then anyEngaging = true end

                table.insert(blips, {
                    x = c.x, z = c.z,
                    vx = c.vx or 0, vz = c.vz or 0,
                    color = "e", -- Red
                    prio = 4,
                    pulse = true,
                    engaged = isEngaged,
                })
                table.insert(threatList, {
                    kind = "MSL T" .. tostring(c.tier or "?"),
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

    -- B. Raw radar returns not already in evaluated contacts
    local okRaw, rawContacts = pcall(mcp.getRadarContacts)
    if okRaw and type(rawContacts) == "table" then
        for _, rc in ipairs(rawContacts) do
            if rc.x and rc.z and (not rc.id or not seenIds[rc.id]) then
                if rc.id then seenIds[rc.id] = true end
                local isOwn = rc.ownNetwork == true
                local col = isOwn and "9" or "e"
                local prio = isOwn and 2 or 4
                local dx = rc.x - ox
                local dz = rc.z - oz
                local dist = sqrt(dx * dx + dz * dz)
                local isEngaged = (not isOwn) and (dist <= 200 and state.readyCiws > 0)
                if isEngaged then anyEngaging = true end

                table.insert(blips, {
                    x = rc.x, z = rc.z,
                    vx = rc.vx or 0, vz = rc.vz or 0,
                    color = col,
                    prio = prio,
                    pulse = not isOwn,
                    engaged = isEngaged,
                })
                if not isOwn then
                    state.threatCount = state.threatCount + 1
                    if rc.id then table.insert(engageIds, rc.id) end
                    table.insert(threatList, {
                        kind = "RKT T" .. tostring(rc.tier or "?"),
                        dist = floor(dist + 0.5),
                        state = isEngaged and "CIWS FIRE" or "INCOMING",
                        color = "e",
                    })
                end
            end
        end
    end

    -- Actively command MCP defense network (CIWS + Interceptors) to engage all incoming rockets
    if state.threatCount > 0 or #engageIds > 0 then
        local okEng, launched = pcall(mcp.engageThreat)
        if okEng and launched then
            anyEngaging = true
        end
    end

    -- C. Airborne player / vehicle tracks (Hostile = Orange '1', Friendly = Cyan '9', Unknown = Yellow '4')
    local okTracks, tracks = pcall(mcp.getTracks)
    if okTracks and type(tracks) == "table" then
        state.trackCount = #tracks
        for _, t in ipairs(tracks) do
            if t.x and t.z then
                local col = "4" -- Yellow (UNKNOWN)
                local prio = 3
                if t.iff == "HOSTILE" then
                    col = "1" -- Orange
                    prio = 4
                elseif t.iff == "FRIENDLY" or t.friendly then
                    col = "9" -- Cyan
                    prio = 2
                end
                table.insert(blips, {
                    x = t.x, z = t.z,
                    vx = t.vx or 0, vz = t.vz or 0,
                    color = col,
                    prio = prio,
                    pulse = (t.iff == "HOSTILE"),
                })
                if t.iff ~= "FRIENDLY" and not t.friendly then
                    local dx = t.x - ox
                    local dz = t.z - oz
                    table.insert(threatList, {
                        kind = t.vehicle and "VEH" or "AIR",
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

    -- D. Own network airborne missile flights (Cyan '9')
    local okFlights, flights = pcall(mcp.getFlights)
    if okFlights and type(flights) == "table" then
        state.flightCount = #flights
        for _, f in ipairs(flights) do
            if f.x and f.z and (not f.id or not seenIds[f.id]) then
                table.insert(blips, {
                    x = f.x, z = f.z,
                    vx = f.vx or 0, vz = f.vz or 0,
                    color = "9",
                    prio = 2,
                })
            end
        end
    else
        state.flightCount = 0
    end

    -- E. Active reconnaissance UAVs (White '0')
    local okUavs, uavData = pcall(mcp.getUavs)
    if okUavs and type(uavData) == "table" and type(uavData.flights) == "table" then
        for _, u in ipairs(uavData.flights) do
            if u.x and u.z then
                table.insert(blips, {
                    x = u.x, z = u.z,
                    vx = 0, vz = 0,
                    color = "0",
                    prio = 1,
                })
            end
        end
    end

    table.sort(threatList, function(a, b) return a.dist < b.dist end)
    state.blips = blips
    state.threatList = threatList
    state.engaging = anyEngaging
end

-- Helper to plot a subpixel onto the overlay buffer
local function setOverlayPixel(px, py, color, prio)
    if px < 1 or px > PW or py < 1 or py > PH then return end
    if not staticInside[py][px] then return end
    if prio >= (overlayPrio[py][px] or 0) then
        overlay[py][px] = color
        overlayPrio[py][px] = prio
    end
end

-- Helper to draw a dashed tracer line between two subpixel points (CIWS engagement line)
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

-- 7. Render Subpixel Framebuffer + CIWS + Blips
local tickCounter = 0

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

local function updateFramebuffer(sweepAngle)
    for py = 1, PH do
        local ovRow = overlay[py]
        local prRow = overlayPrio[py]
        for px = 1, PW do
            ovRow[px] = nil
            prRow[px] = 0
        end
    end

    -- Update radar background & sweep
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
                            if t > 0.78 then
                                trailShade = 5
                            elseif t > 0.50 then
                                trailShade = 4
                            elseif t > 0.22 then
                                trailShade = 3
                            else
                                trailShade = 2
                            end
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

    -- Plot connected CIWS turrets (Cyan '9' markers near origin)
    for _, ciws in ipairs(state.ciwsNodes) do
        local cx, cy = worldToSubpixel(ciws.x, ciws.z)
        setOverlayPixel(cx, cy, "9", 2)
    end

    -- Plot live radar blips, velocity vectors & CIWS tracer lines
    local pulseOn = (tickCounter % 6) < 4
    local tracerPhase = tickCounter % 3

    for _, blip in ipairs(state.blips) do
        local bx, by = worldToSubpixel(blip.x, blip.z)

        -- If CIWS is engaging this threat, draw yellow tracer stream from nearest CIWS / center
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
            local dirX = vx / speed
            local dirZ = vz / speed
            for step = 1, 3 do
                local lx = floor(bx + dirX * step + 0.5)
                local ly = floor(by + dirZ * step + 0.5)
                setOverlayPixel(lx, ly, blip.color, blip.prio - 1)
            end
        end
    end
end

-- 8. Convert 2x3 Subpixels to Teletext Characters & Draw Corner HUD
local function writeHud(x, y, text, fg, bg)
    bg = bg or string.rep("f", #text)
    if #fg < #text then fg = string.rep(fg:sub(1, 1), #text) end
    mon.setCursorPos(x, y)
    mon.blit(text, fg, bg)
end

local function padRight(str, len)
    if #str >= len then return str:sub(1, len) end
    return str .. string.rep(" ", len - #str)
end

local function drawFrame()
    for cy = 1, H do
        local py0 = (cy - 1) * 3 + 1
        local row1, row2, row3 = fb[py0], fb[py0 + 1], fb[py0 + 2]
        local ov1, ov2, ov3 = overlay[py0], overlay[py0 + 1], overlay[py0 + 2]
        local pr1, pr2, pr3 = overlayPrio[py0], overlayPrio[py0 + 1], overlayPrio[py0 + 2]

        local chars = {}
        local fgs = {}
        local bgs = {}

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

    -- Left HUD Margin (Columns 1..11): Network & CIWS Status
    writeHud(1, 1, "ECLIPSE RDR", "5")
    if state.online then
        writeHud(1, 2, "NET: ONLINE", "77777555555")
    else
        writeHud(1, 2, "NET: EMP!  ", "77777eeeeee")
    end
    writeHud(1, 3, padRight("RDR: " .. state.radarCount, 11), "77777000000")
    writeHud(1, 4, padRight("RNG: " .. state.radarRange .. "m", 11), "77777888888")
    writeHud(1, 5, padRight("DEF: " .. state.defenseMode:sub(1, 6), 11), "77777555555")

    -- CIWS Turrets & Ammo Readout
    local ciwsColor = (state.readyCiws > 0) and "77777555555" or "77777eeeeee"
    writeHud(1, 7, padRight("CIWS:" .. state.readyCiws .. " RDY", 11), ciwsColor)
    writeHud(1, 8, padRight("AMMO:" .. state.ciwsAmmo, 11), (state.ciwsAmmo > 0) and "77777444444" or "77777eeeeee")
    writeHud(1, 9, padRight("INT: " .. state.readyInterceptors, 11), "77777999999")

    if state.threatCount > 0 then
        local flash = (tickCounter % 4 < 2)
        if state.engaging or state.readyCiws > 0 then
            writeHud(1, 11, "CIWS ACTIVE", flash and "44444444444" or "eeeeeeeeeee")
        else
            writeHud(1, 11, "MSL ALERT! ", flash and "eeeeeeeeeee" or "11111111111")
        end
    else
        writeHud(1, 11, "CIWS SENTRY", "77777555555")
    end

    -- Bottom-Left Contact Summary + Legend
    writeHud(1, 14, padRight("THR: " .. state.threatCount, 11), state.threatCount > 0 and "eeeee000000" or "77777888888")
    writeHud(1, 15, padRight("TRK: " .. state.trackCount, 11), "77777444444")
    writeHud(1, 16, padRight("FLT: " .. state.flightCount, 11), "77777999999")
    writeHud(1, 18, "*MSL *HOST ", "e8888188888")
    writeHud(1, 19, "*UNK *CIWS ", "48888988888")

    -- Right HUD Margin (Columns 41..51): Live Contacts & Engagement Feed
    writeHud(41, 1, "CONTACTS   ", "5")
    if #state.threatList == 0 then
        writeHud(41, 2, "SECTOR CLR ", "7")
    else
        local maxRows = min(#state.threatList, 5)
        for i = 1, maxRows do
            local item = state.threatList[i]
            local baseRow = 2 + (i - 1) * 3
            local line1 = padRight(string.format("%s %dm", item.kind, item.dist), 11)
            writeHud(41, baseRow, line1, item.color)

            local statusStr = item.state or "TRACKING"
            if item.eta then
                statusStr = string.format("%s %ds", statusStr:sub(1, 6), item.eta)
            end
            local stColor = (item.state == "CIWS FIRE") and "4" or "8"
            writeHud(41, baseRow + 1, padRight(" " .. statusStr, 11), stColor)
        end
    end

    -- Bottom-Right Coordinates
    writeHud(41, 18, padRight("X:" .. state.originX, 11), "77888888888")
    writeHud(41, 19, padRight("Z:" .. state.originZ, 11), "77888888888")
end

-- 9. Main Loop (20 FPS render, polls MCP & triggers engagement every POLL_INTERVAL seconds)
local sweepAngle = math.rad(45)
local SWEEP_SPEED = math.rad(6)
local lastPoll = 0

pollMcp()

while true do
    local now = os.clock()
    if now - lastPoll >= POLL_INTERVAL then
        pollMcp()
        lastPoll = now
    end

    tickCounter = tickCounter + 1
    updateFramebuffer(sweepAngle)
    drawFrame()

    if state.online then
        sweepAngle = (sweepAngle + SWEEP_SPEED) % TWO_PI
    end
    sleep(0.05)
end
