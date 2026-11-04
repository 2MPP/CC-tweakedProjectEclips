-- Project Eclipse - Part 2: Pocket Computer Strike Remote (CC:Tweaked)
-- Runs on a Wireless / Ender Pocket Computer (26x20 screen).
-- Connects to launch_server.lua to set target coordinates, spread radius, and launch rockets.

local CHANNEL = 4920
local REPLY_CHANNEL = 4921
local PROTOCOL = "ECLIPSE_STRIKE_V1"
local ACCESS_PIN = nil -- Match ACCESS_PIN in launch_server.lua if set

-- 1. Find Wireless Modem on Pocket Computer
local modem = peripheral.find("modem", function(_, m)
    return m.isWireless and m.isWireless()
end)
if not modem then
    error("No Wireless Modem found! Use a Wireless Pocket Computer.")
end
modem.open(REPLY_CHANNEL)

local W, H = term.getSize()

-- 2. Options & State
local FIRE_MODES = { "AUTO", "1", "2", "3", "4", "5", "6", "BIG_ONE", "CRUISE", "SALVO" }
local PROFILES   = { "HIGH_BALLISTIC", "LOW_TRAJECTORY", "TERRAIN_HUG" }
local IMPACTS    = { "SURFACE", "AIRBURST", "BUNKER_BUSTER" }

local state = {
    targetX = 0,
    targetY = 64,
    targetZ = 0,
    count = 4,
    spread = 16, -- Spread radius in blocks so rockets hit dispersed XYZ spots
    modeIdx = 1,
    profileIdx = 1,
    impactIdx = 1,
    connected = false,
    serverStatus = {
        online = false,
        readyMissiles = 0,
        launcherCount = 0,
        activeFlights = 0,
        siloReady = 0,
    },
    statusMsg = "Pinging base server...",
    statusColor = colors.yellow,
}

local reqCounter = math.random(1000, 9999)
local function sendPacket(pktType, payload)
    reqCounter = reqCounter + 1
    local msg = payload or {}
    msg.protocol = PROTOCOL
    msg.type = pktType
    msg.requestId = reqCounter
    msg.pin = ACCESS_PIN
    modem.transmit(CHANNEL, REPLY_CHANNEL, msg)
    return reqCounter
end

-- 3. UI Rendering Helpers (Designed for 26x20 Pocket Screen)
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

local function drawUI()
    term.setBackgroundColor(colors.black)
    term.clear()

    -- Header Bar (Row 1)
    drawLine(1, " ECLIPSE STRIKE REMOTE", colors.black, colors.lime)

    -- Network Link & Missile Telemetry (Rows 2-3)
    if state.connected and state.serverStatus.online then
        drawLine(2, string.format(" LINK:ONLINE  IN-FLT:%d", state.serverStatus.activeFlights), colors.lime, colors.gray)
    elseif state.connected then
        drawLine(2, " LINK: MCP EMP/OFFLINE", colors.red, colors.gray)
    else
        drawLine(2, " LINK: SEARCHING...", colors.yellow, colors.gray)
    end

    drawLine(3, string.format(" READY:%-3d LNCH:%-2d SILO:%d",
        state.serverStatus.readyMissiles,
        state.serverStatus.launcherCount,
        state.serverStatus.siloReady), colors.white, colors.black)

    -- Target Coordinates Section (Rows 4-8)
    drawLine(4, "---- TARGET COORDS -------", colors.green, colors.black)

    drawLine(5, string.format(" X: %-10d", state.targetX), colors.white, colors.black)
    drawButton(16, 5, "[EDIT X]", colors.black, colors.lightGray)

    drawLine(6, string.format(" Y: %-10d", state.targetY), colors.white, colors.black)
    drawButton(16, 6, "[EDIT Y]", colors.black, colors.lightGray)

    drawLine(7, string.format(" Z: %-10d", state.targetZ), colors.white, colors.black)
    drawButton(16, 7, "[EDIT Z]", colors.black, colors.lightGray)

    drawButton(2, 8, "[ GPS HERE ]", colors.black, colors.cyan)
    drawButton(15, 8, "[ARM SILO]", colors.black, colors.orange)

    -- Strike Parameters Section (Rows 9-15)
    drawLine(9, "---- STRIKE OPTIONS ------", colors.green, colors.black)

    -- Count row (Row 10)
    drawLine(10, string.format(" COUNT  : %-3d", state.count), colors.white, colors.black)
    drawButton(16, 10, "[-]", colors.white, colors.gray)
    drawButton(20, 10, "[+]", colors.white, colors.gray)

    -- Spread radius row (Row 11)
    drawLine(11, string.format(" SPREAD : %-3dm", state.spread), colors.lime, colors.black)
    drawButton(16, 11, "[-]", colors.white, colors.gray)
    drawButton(20, 11, "[+]", colors.white, colors.gray)

    -- Fire Mode / Tier (Row 12)
    local modeName = FIRE_MODES[state.modeIdx]
    drawLine(12, " MODE   : ", colors.lightGray, colors.black)
    drawButton(11, 12, string.format("[ %-10s ]", modeName), colors.yellow, colors.gray)

    -- Attack Profile (Row 13)
    local profName = PROFILES[state.profileIdx]
    drawLine(13, " PROFILE: ", colors.lightGray, colors.black)
    drawButton(11, 13, string.format("[ %-12s ]", profName:sub(1, 12)), colors.cyan, colors.gray)

    -- Impact Mode (Row 14)
    local impName = IMPACTS[state.impactIdx]
    drawLine(14, " IMPACT : ", colors.lightGray, colors.black)
    drawButton(11, 14, string.format("[ %-12s ]", impName:sub(1, 12)), colors.orange, colors.gray)

    -- Launch Button (Rows 16-18)
    drawLine(16, "==========================", colors.red, colors.black)
    drawLine(17, "  >>> LAUNCH STRIKE <<<   ", colors.white, colors.red)
    drawLine(18, "==========================", colors.red, colors.black)

    -- Status Bar (Rows 19-20)
    drawLine(19, " " .. (state.statusMsg or ""), state.statusColor, colors.black)
    drawLine(20, " Tap field or press [F]ire", colors.gray, colors.black)
end

-- Prompt user to type a coordinate/number value on row 19
local function promptNumber(label, currentVal)
    term.setCursorPos(1, 19)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.clearLine()
    term.write("Enter " .. label .. ": ")
    term.setCursorBlink(true)
    local input = read()
    term.setCursorBlink(false)
    local num = tonumber(input)
    if num then
        return math.floor(num)
    end
    return currentVal
end

local function triggerLaunch()
    state.statusMsg = "Transmitting FIRE order..."
    state.statusColor = colors.yellow
    drawUI()
    sendPacket("FIRE", {
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

-- 4. Initial Ping & Main UI Loop
drawUI()
sendPacket("STATUS")
local pollTimer = os.startTimer(2)

while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()

    if event == "modem_message" then
        local msg = p4
        if type(msg) == "table" and msg.protocol == PROTOCOL then
            state.connected = true
            if msg.status then
                state.serverStatus = msg.status
            end
            if msg.type == "STATUS_REPLY" then
                if state.statusMsg == "Pinging base server..." then
                    state.statusMsg = "Connected to MCP Server"
                    state.statusColor = colors.lime
                end
            elseif msg.type == "FIRE_REPLY" then
                state.statusMsg = tostring(msg.message or (msg.ok and "LAUNCHED!" or "FAILED"))
                state.statusColor = msg.ok and colors.lime or colors.red
            elseif msg.type == "ERROR" then
                state.statusMsg = "ERR: " .. tostring(msg.message)
                state.statusColor = colors.red
            end
            drawUI()
        end

    elseif event == "mouse_click" then
        local button, x, y = p1, p2, p3

        if y == 5 then
            state.targetX = promptNumber("Target X", state.targetX)
            drawUI()
        elseif y == 6 then
            state.targetY = math.max(-64, math.min(320, promptNumber("Target Y", state.targetY)))
            drawUI()
        elseif y == 7 then
            state.targetZ = promptNumber("Target Z", state.targetZ)
            drawUI()
        elseif y == 8 and x >= 2 and x <= 13 then
            -- [ GPS HERE ]
            state.statusMsg = "Locating via GPS..."
            state.statusColor = colors.cyan
            drawUI()
            local gx, gy, gz = gps.locate(1.5)
            if gx then
                state.targetX = math.floor(gx)
                state.targetY = math.floor(gy)
                state.targetZ = math.floor(gz)
                state.statusMsg = "GPS coordinates locked!"
                state.statusColor = colors.lime
            else
                state.statusMsg = "No GPS signal found"
                state.statusColor = colors.orange
            end
            drawUI()
        elseif y == 8 and x >= 15 and x <= 24 then
            -- [ ARM SILO ]
            state.statusMsg = "Arming Strategic Silos..."
            state.statusColor = colors.orange
            drawUI()
            sendPacket("SILO_ARM")
        elseif y == 10 then
            if x >= 16 and x <= 18 then
                state.count = math.max(1, state.count - 1)
            elseif x >= 20 and x <= 22 then
                state.count = math.min(64, state.count + 1)
            else
                state.count = math.max(1, math.min(64, promptNumber("Missile Count (1-64)", state.count)))
            end
            drawUI()
        elseif y == 11 then
            if x >= 16 and x <= 18 then
                state.spread = math.max(0, state.spread - 4)
            elseif x >= 20 and x <= 22 then
                state.spread = math.min(256, state.spread + 4)
            else
                state.spread = math.max(0, math.min(256, promptNumber("Spread Radius (0-256m)", state.spread)))
            end
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

    elseif event == "key" then
        local key = p1
        if key == keys.x then
            sleep(0.05)
            state.targetX = promptNumber("Target X", state.targetX)
            drawUI()
        elseif key == keys.y then
            sleep(0.05)
            state.targetY = math.max(-64, math.min(320, promptNumber("Target Y", state.targetY)))
            drawUI()
        elseif key == keys.z then
            sleep(0.05)
            state.targetZ = promptNumber("Target Z", state.targetZ)
            drawUI()
        elseif key == keys.s then
            sleep(0.05)
            state.spread = math.max(0, math.min(256, promptNumber("Spread Radius (0-256m)", state.spread)))
            drawUI()
        elseif key == keys.f or key == keys.enter then
            triggerLaunch()
        elseif key == keys.up or key == keys.equals then
            state.count = math.min(64, state.count + 1)
            drawUI()
        elseif key == keys.down or key == keys.minus then
            state.count = math.max(1, state.count - 1)
            drawUI()
        elseif key == keys.m then
            state.modeIdx = (state.modeIdx % #FIRE_MODES) + 1
            drawUI()
        end

    elseif event == "timer" and p1 == pollTimer then
        sendPacket("STATUS")
        pollTimer = os.startTimer(2)
    end
end
