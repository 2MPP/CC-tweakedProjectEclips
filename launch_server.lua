-- Project Eclipse - Part 1: Base Launch Server (CC:Tweaked)
-- Runs on the computer connected to the Missile Control Panel (MCP) + a Wireless/Ender Modem.
-- Listens for strike commands from pocket_remote.lua and launches rockets across dispersed XYZ targets.

local CHANNEL = 4920
local PROTOCOL = "ECLIPSE_STRIKE_V1"
local DEFAULT_SPREAD = 16 -- Default spread radius in blocks when firing multiple rockets

-- Optional shared PIN (set to a string like "1234" to require PIN on pocket remote, or nil for none)
local ACCESS_PIN = nil

-- 1. Find Wireless / Ender Modem (ignores wired modems used for MCP cables)
local modem = peripheral.find("modem", function(_, m)
    return m.isWireless and m.isWireless()
end)
if not modem then
    error("No Wireless or Ender Modem found! Attach a Wireless/Ender Modem to this computer.")
end
modem.open(CHANNEL)

-- 2. Find & Authenticate with Missile Control Panel (MCP)
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

-- 3. Gather live MCP status (including standalone PLACED_MISSILE on the floor)
local OFFENSIVE_NODE_TYPES = {
    PLACED_MISSILE = true,
    CRUISE_MISSILE = true,
    ATTACK_LAUNCHER = true,
    POD_LAUNCHER = true,
    LAUNCH_PAD = true,
    STRATEGIC_SILO = true,
    CRUISE_LAUNCHER = true,
}

local function getStatusPayload()
    local okInfo, info = pcall(mcp.getNetworkInfo)
    info = (okInfo and type(info) == "table") and info or {}

    local readyMissiles = info.readyMissiles or 0
    local launcherCount = info.launcherCount or 0
    local placedCount = 0

    local okReady, directReady = pcall(mcp.getReadyMissileCount)
    if okReady and type(directReady) == "number" and directReady > readyMissiles then
        readyMissiles = directReady
    end

    local okLaunchers, launchers = pcall(mcp.getLaunchers)
    if okLaunchers and type(launchers) == "table" then
        if #launchers > launcherCount then
            launcherCount = #launchers
        end
        local sumLoaded = 0
        for _, l in ipairs(launchers) do
            if l.type == "PLACED_MISSILE" then
                placedCount = placedCount + 1
                if l.ready ~= false then
                    sumLoaded = sumLoaded + math.max(1, l.loadedCount or 1)
                end
            else
                sumLoaded = sumLoaded + (l.loadedCount or (l.ready and 1 or 0))
            end
        end
        if sumLoaded > readyMissiles then
            readyMissiles = sumLoaded
        end
    end

    local okNodes, nodes = pcall(mcp.getNodes)
    local totalNodes = 0
    if okNodes and type(nodes) == "table" then
        totalNodes = #nodes
        local nodeOffensiveCount = 0
        local nodeReadySum = 0
        local nodePlaced = 0
        for _, n in ipairs(nodes) do
            if OFFENSIVE_NODE_TYPES[n.type] and n.connected ~= false then
                nodeOffensiveCount = nodeOffensiveCount + 1
                if n.type == "PLACED_MISSILE" or n.type == "CRUISE_MISSILE" then
                    nodePlaced = nodePlaced + 1
                    nodeReadySum = nodeReadySum + math.max(1, n.readyCount or 1)
                else
                    nodeReadySum = nodeReadySum + (n.readyCount or 0)
                end
            end
        end
        if nodeOffensiveCount > launcherCount then
            launcherCount = nodeOffensiveCount
        end
        if nodeReadySum > readyMissiles then
            readyMissiles = nodeReadySum
        end
        if nodePlaced > placedCount then
            placedCount = nodePlaced
        end
    end

    local siloReady = 0
    local okSilos, silos = pcall(mcp.getSilos)
    if okSilos and type(silos) == "table" then
        for _, s in ipairs(silos) do
            if s.ready then siloReady = siloReady + 1 end
        end
    end

    local flightsBrief = {}
    local okFlights, flights = pcall(mcp.getFlights)
    if okFlights and type(flights) == "table" then
        for i = 1, math.min(#flights, 3) do
            local f = flights[i]
            table.insert(flightsBrief, {
                tier = f.tier,
                phase = f.phase,
                eta = f.remainingSeconds,
                progress = f.progress,
            })
        end
    end

    return {
        online = info.networkOnline ~= false,
        empTicks = info.empRemainingTicks or 0,
        mcpX = info.x or 0,
        mcpY = info.y or 64,
        mcpZ = info.z or 0,
        launcherCount = launcherCount,
        readyMissiles = readyMissiles,
        placedCount = placedCount,
        totalNodes = totalNodes,
        activeFlights = info.activeFlights or 0,
        siloReady = siloReady,
        flights = flightsBrief,
    }
end

-- 4. Generate dispersed XYZ impact points around (centerX, centerY, centerZ)
-- Uses a golden-angle spiral + random jitter so rockets spread evenly across the area
-- without clumping on the same coordinate.
local GOLDEN_ANGLE = math.pi * (3 - math.sqrt(5)) -- ~137.5 degrees

local function buildDispersedTargets(centerX, centerY, centerZ, count, spread)
    local targets = {}
    local baseAngle = math.random() * math.pi * 2

    for i = 1, count do
        if i == 1 or spread <= 0 then
            -- First rocket hits dead-center on the primary coordinate
            table.insert(targets, { x = centerX, y = centerY, z = centerZ })
        else
            -- Subsequent rockets spread across the circle/volume around the target
            local fraction = (i - 1) / math.max(1, count - 1)
            local radius = spread * math.sqrt(fraction)
            local jitterR = (math.random() - 0.5) * (spread * 0.25)
            local r = math.max(2, radius + jitterR)

            local angle = baseAngle + (i - 1) * GOLDEN_ANGLE + (math.random() - 0.5) * 0.35
            local dx = math.floor(math.cos(angle) * r + 0.5)
            local dz = math.floor(math.sin(angle) * r + 0.5)
            local dy = math.random(-2, 2)

            local ty = math.max(-64, math.min(320, centerY + dy))
            table.insert(targets, {
                x = centerX + dx,
                y = ty,
                z = centerZ + dz,
            })
        end
    end

    return targets
end

-- 5. Execute a launch request from the Pocket Remote
local function executeLaunch(cmd)
    local x = tonumber(cmd.x)
    local y = tonumber(cmd.y) or 64
    local z = tonumber(cmd.z)
    local count = math.max(1, math.min(64, tonumber(cmd.count) or 1))
    local spread = tonumber(cmd.spread)
    if spread == nil then spread = DEFAULT_SPREAD end
    spread = math.max(0, math.min(256, spread))

    if not x or not z then
        return false, "Invalid X/Z coordinates"
    end

    local targets = buildDispersedTargets(x, y, z, count, spread)

    local fireMode = cmd.fireMode or "AUTO"
    local attackProfile = cmd.attackProfile or "HIGH_BALLISTIC"
    local impactMode = cmd.impactMode or "SURFACE"
    local delaySeconds = tonumber(cmd.delaySeconds) or 0

    local isSimpleFire = (fireMode == "AUTO")
        and (attackProfile == "HIGH_BALLISTIC")
        and (impactMode == "SURFACE")
        and (delaySeconds == 0)

    -- Rapid setTarget + fire(1) loop:
    -- Per MCP API docs, rapid calls in a for-loop within the same tick are automatically
    -- coalesced into a multi-target salvo and load-balanced across all launchers/floor missiles!
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
            return true, string.format("FIRED %d (SPREAD %dm)", firedCount, spread)
        elseif lastErr then
            return false, tostring(lastErr)
        end
    end

    -- Advanced multi-mission fire plan (up to 48 missions in executeFirePlan)
    local missions = {}
    local parsedMode = tonumber(fireMode) or fireMode
    local bunkerDepth = tonumber(cmd.bunkerDepth) or 10

    for i = 1, math.min(#targets, 48) do
        local t = targets[i]
        table.insert(missions, {
            name = string.format("Strike #%d", i),
            x = t.x,
            y = t.y,
            z = t.z,
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

    -- Fallback: individual setTarget + fire(1) per dispersed coordinate
    local firedCount = 0
    local lastErr = resPlan
    for i = 1, #targets do
        local t = targets[i]
        local okSet = pcall(mcp.setTarget, t.x, t.y, t.z)
        if okSet then
            local okFire, resFire = pcall(mcp.fire, 1)
            if okFire then
                firedCount = firedCount + 1
            else
                lastErr = resFire
            end
        end
    end

    if firedCount > 0 then
        return true, string.format("FIRED %d (SPREAD %dm)", firedCount, spread)
    end
    return false, tostring(lastErr or "Launch failed")
end

-- 6. Terminal UI & Event Loop
local function drawServerScreen(lastLog)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    term.setTextColor(colors.lime)
    print("=== ECLIPSE LAUNCH SERVER ===")
    term.setTextColor(colors.lightGray)
    print(("Computer ID: %d  |  Channel: %d"):format(os.getComputerID(), CHANNEL))
    print("---------------------------------------")

    local status = getStatusPayload()
    term.setTextColor(status.online and colors.lime or colors.red)
    print("MCP Network : " .. (status.online and "ONLINE" or "OFFLINE / EMP"))
    term.setTextColor(colors.white)
    print(("MCP Coords  : %d, %d, %d"):format(status.mcpX or 0, status.mcpY or 0, status.mcpZ or 0))
    print(("Launchers   : %d (%d floor missiles)"):format(status.launcherCount, status.placedCount or 0))
    print(("Ready Msls  : %d ready (%d Silos armed)"):format(status.readyMissiles, status.siloReady))
    print(("In Flight   : %d active missile(s)"):format(status.activeFlights))

    if status.readyMissiles == 0 then
        term.setTextColor(colors.orange)
        print("TIP: Floor missiles must be connected")
        print("to the MCP network via MCP Cable or")
        print("Wireless Extender to appear on MCP!")
    end

    print("---------------------------------------")
    term.setTextColor(colors.yellow)
    print("Last Event:")
    term.setTextColor(colors.white)
    print(lastLog or "Waiting for Pocket Remote...")
end

local lastLog = "Listening for Pocket Remote on ch " .. CHANNEL
drawServerScreen(lastLog)

local refreshTimer = os.startTimer(2)

while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()

    if event == "modem_message" then
        local replyChannel, message = p3, p4
        if type(message) == "table" and message.protocol == PROTOCOL then
            if ACCESS_PIN and message.pin ~= ACCESS_PIN then
                modem.transmit(replyChannel, CHANNEL, {
                    protocol = PROTOCOL,
                    type = "ERROR",
                    requestId = message.requestId,
                    message = "Invalid PIN",
                })
                lastLog = "Rejected unauthorized remote request"
                drawServerScreen(lastLog)
            elseif message.type == "PING" or message.type == "STATUS" then
                modem.transmit(replyChannel, CHANNEL, {
                    protocol = PROTOCOL,
                    type = "STATUS_REPLY",
                    requestId = message.requestId,
                    serverId = os.getComputerID(),
                    status = getStatusPayload(),
                })
            elseif message.type == "FIRE" then
                local tx, ty, tz = tonumber(message.x) or 0, tonumber(message.y) or 64, tonumber(message.z) or 0
                local cnt = tonumber(message.count) or 1
                local spr = tonumber(message.spread) or DEFAULT_SPREAD
                local mode = tostring(message.fireMode or "AUTO")
                lastLog = ("FIRE %dx (Spr:%dm) -> (%d,%d,%d)"):format(cnt, spr, tx, ty, tz)

                local ok, resMsg = executeLaunch(message)
                if ok then
                    lastLog = lastLog .. "\nResult: " .. resMsg
                else
                    lastLog = lastLog .. "\nERROR: " .. resMsg
                end

                modem.transmit(replyChannel, CHANNEL, {
                    protocol = PROTOCOL,
                    type = "FIRE_REPLY",
                    requestId = message.requestId,
                    ok = ok,
                    message = resMsg,
                    status = getStatusPayload(),
                })
                drawServerScreen(lastLog)
            elseif message.type == "SILO_ARM" then
                local armedCount = 0
                local okSilos, silos = pcall(mcp.getSilos)
                if okSilos and type(silos) == "table" then
                    for _, s in ipairs(silos) do
                        if not s.valvesOpen then pcall(mcp.siloAction, s.id, "VALVES") end
                        if pcall(mcp.siloAction, s.id, "ARM") then
                            armedCount = armedCount + 1
                        end
                    end
                end
                lastLog = ("Remote armed %d Strategic Silo(s)"):format(armedCount)
                modem.transmit(replyChannel, CHANNEL, {
                    protocol = PROTOCOL,
                    type = "FIRE_REPLY",
                    requestId = message.requestId,
                    ok = true,
                    message = ("ARMED %d SILO(S)"):format(armedCount),
                    status = getStatusPayload(),
                })
                drawServerScreen(lastLog)
            end
        end
    elseif event == "timer" and p1 == refreshTimer then
        drawServerScreen(lastLog)
        refreshTimer = os.startTimer(2)
    end
end
