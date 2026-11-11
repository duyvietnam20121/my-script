-- FlySeat: fly + seat picker

--==================================================
-- SERVICES
--==================================================

-- Executor helpers (every function is optional and guarded)
local cloneRef = (type(cloneref) == "function" and cloneref)
    or function(obj) return obj end

local function getService(name)
    return cloneRef(game:GetService(name))
end

local Players = getService("Players")
local RunService = getService("RunService")
local UIS = getService("UserInputService")
local CAS = getService("ContextActionService")
local Workspace = getService("Workspace")
local CoreGui = getService("CoreGui")

-- Cached globals for hot paths (local access is faster than global lookup)
local mathExp, mathClamp, mathAbs = math.exp, math.clamp, math.abs
local mathMin, mathMax, mathAtan2 = math.min, math.max, math.atan2
local mathHuge = math.huge
local taskWait, taskDelay = task.wait, task.delay
local CFAngles = CFrame.Angles

-- Random instance names (new name for every instance)
local rng = Random.new()
local NAME_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

local function randomName()
    local len = rng:NextInteger(8, 14)
    local out = table.create(len)

    for i = 1, len do
        local n = rng:NextInteger(1, #NAME_CHARS)
        out[i] = NAME_CHARS:sub(n, n)
    end

    return table.concat(out)
end

local LP = Players.LocalPlayer
local Mouse = LP:GetMouse()

local ENV = (type(getgenv) == "function" and getgenv()) or _G

-- Cached enums / constants
local HState = Enum.HumanoidStateType
local KC = Enum.KeyCode
local UIT = Enum.UserInputType
local VEC_ZERO = Vector3.zero
local VEC_Y = Vector3.yAxis

--==================================================
-- CONFIG (keys, speed, update frequencies)
--==================================================

local CONFIG = {
    -- PC hotkeys
    KEYS = {
        FLY = KC.F,          -- toggle fly
        SEAT_PICKER = KC.G,  -- toggle Seat Picker
        EXIT_SEAT = KC.E,    -- leave the picked seat
    },

    -- Movement keys (action -> key codes)
    MOVE_KEYS = {
        W = { KC.W },
        A = { KC.A },
        S = { KC.S },
        D = { KC.D },
        Up = { KC.Space },
        Down = { KC.LeftControl, KC.RightControl },
    },

    -- Fly speed (studs/second)
    SPEED = {
        DEFAULT = 50,
        MIN = 10,
        MAX = 250,
        STEP = 10,
        SEATED_CAP = 80,  -- max speed while seated on a part (raise toward MAX for stronger control)
        SMOOTHING = 8,    -- acceleration easing (1/s); higher = snappier, 0 = instant. Smoother = less riders jitter
    },

    SEAT = {
        KEEP_SEATED = true,  -- if the humanoid leaves the picked seat by itself, sit back down (exit only with E / button)
        SUSPEND_PICKER = true,  -- pause the Seat Picker while seated; it comes back on exit
        ROTATE_WITH_CAMERA = true,  -- seated: false keeps the part's heading fixed so riders aren't spun around
    },

    -- Hold the part in place when idle (pulls it back after being pushed)
    HOLD = {
        ENABLED = true,
        DELAY = 0.15,          -- seconds without input before holding
        RESPONSIVENESS = 100,
        MAX_SPEED = 200,       -- studs/second used to snap back
        RIGID = true,          -- hold like a hard weld to the world (ignores RESPONSIVENESS / MAX_SPEED)
        SNAP_DISTANCE = 8,     -- studs: if the held part is pulled farther than this it is put back (0 = off)
    },

    -- Make the picked part (and its welded parts) feather-light while seated.
    -- Heavy parts are what makes them sag / fall; density is restored on exit.
    LIGHTEN = {
        ENABLED = true,
        TARGET_MASS = 25,      -- heavy parts are brought down to about this mass (never lighter than needed)
        MIN_DENSITY = 0.01,    -- lowest density Roblox allows
        MAX_PARTS = 40,        -- connected parts handled per pick
        UNIFORM = false,        -- every lightened part gets MIN_DENSITY (false = only bring heavy parts down to TARGET_MASS)
        ANTI_GRAVITY = true,   -- the picked assembly gets an upward force equal to its weight (weightless)

        -- Also lighten every loose part around you while seated
        NEARBY = {
            ENABLED = true,
            RADIUS = 40,       -- studs around you
            INTERVAL = 1,      -- seconds between passes
            PER_PASS = 25,     -- parts lightened per pass
            QUERY_MAX = 1000,  -- hard cap on parts returned per query
            INCLUDE_PLAYERS = true,  -- also other players' parts (local only; your own character is never touched)
        },
    },

    -- Make nearby players pass through the picked part locally so they can't push it (runs while a part is picked)
    PUSH = {
        ENABLED = true,
        RADIUS = 60,           -- studs around you
        REFRESH = 0.25,        -- seconds between nearby-player refreshes
    },

    -- Seconds between updates
    INTERVALS = {
        STATUS = 0.2,          -- status text
        HIGHLIGHT = 0.05,      -- Seat Picker highlight
        SIM_RADIUS = 0.1,      -- SimulationRadius write (while flying)
        CENTER_OF_MASS = 0.2,  -- assembly center-of-mass re-read (while flying)
        CENTER_OF_MASS_SEATED = 0.02,  -- same, but while seated (riders move the center of mass)
        STABILIZE = 1 / 30,    -- anti tilt / anti spin (while flying)
    },
}

-- Button labels (key hints come from CONFIG.KEYS)
local LABELS = {
    FLY_ON = ("FLY [%s]: ON"):format(CONFIG.KEYS.FLY.Name),
    FLY_OFF = ("FLY [%s]: OFF"):format(CONFIG.KEYS.FLY.Name),
    SEAT_ON = ("SEAT PICKER [%s]: ON"):format(CONFIG.KEYS.SEAT_PICKER.Name),
    SEAT_OFF = ("SEAT PICKER [%s]: OFF"):format(CONFIG.KEYS.SEAT_PICKER.Name),
    SEAT_PAUSED = ("SEAT PICKER [%s]: PAUSED"):format(CONFIG.KEYS.SEAT_PICKER.Name),
    EXIT = ("EXIT SEAT [%s]"):format(CONFIG.KEYS.EXIT_SEAT.Name),
}

--==================================================
-- CLEAN OLD SCRIPTS
--==================================================

local CLEANUP_NAMES = {
    "UnifiedFlySeatCleanup",
    "ExecutorFlyCleanup",
    "SeatPickerCleanup",
}

for _, name in ipairs(CLEANUP_NAMES) do
    local fn = ENV[name]

    if type(fn) == "function" then
        pcall(fn)
    end
end

do
    -- Leftovers from older versions that used fixed names
    local STALE = {
        SelectedSeat = true,
        SeatPickerHighlight = true,
        SeatPickerWeld = true,
        SeatPickerCharWeld = true,
    }

    -- Seats / highlight are direct Workspace children; welds live in the character
    for _, obj in ipairs(Workspace:GetChildren()) do
        if STALE[obj.Name] then
            pcall(obj.Destroy, obj)
        end
    end

    local char = LP.Character

    if char then
        for _, obj in ipairs(char:GetDescendants()) do
            if STALE[obj.Name] then
                pcall(obj.Destroy, obj)
            end
        end
    end
end

--==================================================
-- SETTINGS
--==================================================

local FREEZE_PART = false
local KEEP_SEATED = CONFIG.SEAT.KEEP_SEATED
local SUSPEND_PICKER = CONFIG.SEAT.SUSPEND_PICKER
local ROTATE_SEATED = CONFIG.SEAT.ROTATE_WITH_CAMERA

-- Fly
local speed = CONFIG.SPEED.DEFAULT
local minSpeed = CONFIG.SPEED.MIN
local maxSpeed = CONFIG.SPEED.MAX
local speedStep = CONFIG.SPEED.STEP

-- Seated speed
local SEATED_SPEED_CAP = CONFIG.SPEED.SEATED_CAP

-- Upright
local UPRIGHT_RESPONSIVENESS = 100
local UPRIGHT_MAX_TORQUE = mathHuge
local UPRIGHT_MAX_ANGULAR = 120

-- Anti spin
local NORMAL_DAMPING = 10
local SEATED_DAMPING = 15

local MAX_YAW_RATE = 8

-- GUI colors
local COLOR_ON = Color3.fromRGB(35, 160, 85)
local COLOR_OFF = Color3.fromRGB(38, 38, 48)

--==================================================
-- STATE
--==================================================

local flying = false
local seatPickerEnabled = false

local currentSeat = nil
local pendingSeat = nil
local charWeldInst = nil
local pickedPart = nil  -- the part we picked (anti-push pairs collisions against it)
local startPushGuard, stopPushGuard  -- anti-push, defined further below

-- Seat Picker is paused while seated (functions are defined after setSeatPicker)
local pickerSuspended = false
local suspendPicker, resumePicker

local highlight = nil

local root = nil
local humanoid = nil

local attachment = nil
local velocity = nil
local orientation = nil
local alignPos = nil   -- holds position while idle
local holding = false
local idleTimer = 0

local oldAutoRotate = nil
local lastYaw = 0
local seatYaw = 0  -- heading kept while seated (riders are not spun by camera turns)

-- Last values written to the fly constraints (skip redundant writes)
local lastVel = nil
local lastAppliedYaw = nil
local lastAttPos = nil

local connections = {}

local inputConn = nil
local seatStateConnection = nil

local previousReplicationFocus = nil
local savedReplicationFocus = false

-- Input state (declared BEFORE any function that uses them)
local keys = {
    W = false,
    A = false,
    S = false,
    D = false,
    Up = false,
    Down = false,
}

local heldInputs = {}

--==================================================
-- CONNECTION MANAGER
--==================================================

local function connect(signal, callback)
    local c = signal:Connect(callback)
    connections[#connections + 1] = c
    return c
end

local function clearKeys()
    table.clear(heldInputs)

    for k in pairs(keys) do
        keys[k] = false
    end
end

--==================================================
-- CHARACTER
--==================================================

local function getCharacter()
    return LP.Character
end

local function getHumanoid()
    local char = LP.Character

    return char and char:FindFirstChildOfClass("Humanoid")
end

local function isSeated()
    local hum = humanoid or getHumanoid()

    if not hum or not hum.Parent then
        return false
    end

    return hum.SeatPart ~= nil
        or hum.Sit
        or hum:GetState() == HState.Seated
end

--==================================================
-- BLOCK SPACE WHILE SEATED
--==================================================

local SPACE_ACTION = randomName()

CAS:BindActionAtPriority(
    SPACE_ACTION,
    function(_, state)
        keys.Up = state == Enum.UserInputState.Begin

        if isSeated() then
            return Enum.ContextActionResult.Sink
        end

        return Enum.ContextActionResult.Pass
    end,
    false,
    3000,
    KC.Space
)

-- Also prevent mobile JumpRequest from exiting the seat
connect(UIS.JumpRequest, function()
    if isSeated() then
        local hum = getHumanoid()

        if hum then
            hum.Jump = false
        end
    end
end)

--==================================================
-- NETWORK
--==================================================

pcall(function()
    previousReplicationFocus = LP.ReplicationFocus
    savedReplicationFocus = true

    LP.ReplicationFocus = Workspace
end)

-- Resolved once; used by the fly loop (SimulationRadius)
local setHidden = type(sethiddenproperty) == "function"
    and sethiddenproperty
    or nil

--==================================================
-- GUI PARENT
--==================================================

local guiParent

if type(gethui) == "function" then
    local ok, result = pcall(gethui)

    if ok and result then
        guiParent = result
    end
end

guiParent = guiParent or CoreGui

local PlayerGui = LP:WaitForChild("PlayerGui")

--==================================================
-- GUI HELPERS
--==================================================

local function addCorner(obj, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius)
    c.Parent = obj
end

local function createButton(text, size, position, parent)
    local b = Instance.new("TextButton")

    b.Name = randomName()
    b.Text = text

    b.Size = size
    b.Position = position

    b.BackgroundColor3 = COLOR_OFF
    b.TextColor3 = Color3.new(1, 1, 1)

    b.Font = Enum.Font.GothamBold
    b.TextSize = 13

    b.AutoButtonColor = true
    b.Parent = parent

    addCorner(b, 7)

    return b
end

local function createLabel(size, position, text, font, textSize, color, parent)
    local l = Instance.new("TextLabel")
    l.Name = randomName()

    l.Size = size
    l.Position = position
    l.BackgroundTransparency = 1

    l.Text = text
    l.TextColor3 = color

    l.Font = font
    l.TextSize = textSize

    l.Parent = parent

    return l
end

--==================================================
-- MAIN GUI
--==================================================

local gui = Instance.new("ScreenGui")

gui.Name = randomName()
gui.ResetOnSpawn = false
gui.DisplayOrder = 100

local protectGui = (type(syn) == "table" and syn.protect_gui)
    or (type(protect_gui) == "function" and protect_gui)
    or (type(protectgui) == "function" and protectgui)

if protectGui and guiParent == CoreGui then
    pcall(protectGui, gui)
end

if not pcall(function()
    gui.Parent = guiParent
end) then
    gui.Parent = PlayerGui
end

local main = Instance.new("Frame")

main.Name = randomName()
main.Size = UDim2.fromOffset(190, 224)
main.Position = UDim2.new(0, 20, 0.35, 0)

main.BackgroundColor3 = Color3.fromRGB(24, 24, 32)

main.Active = true
main.Parent = gui

addCorner(main, 10)

local WHITE = Color3.new(1, 1, 1)
local GREY = Color3.fromRGB(180, 180, 190)

createLabel(
    UDim2.new(1, 0, 0, 27), UDim2.new(),
    "FLYSEAT",
    Enum.Font.GothamBold, 12, WHITE, main
)

-- FLY BUTTON
local flyButton = createButton(
    LABELS.FLY_OFF,
    UDim2.new(1, -16, 0, 31),
    UDim2.fromOffset(8, 32),
    main
)

-- SPEED
local minus = createButton(
    "-",
    UDim2.fromOffset(42, 27),
    UDim2.fromOffset(8, 69),
    main
)

local speedLabel = createLabel(
    UDim2.fromOffset(82, 27), UDim2.fromOffset(54, 69),
    tostring(speed),
    Enum.Font.GothamBold, 14, WHITE, main
)

local plus = createButton(
    "+",
    UDim2.fromOffset(42, 27),
    UDim2.fromOffset(140, 69),
    main
)

-- SEAT PICKER
local seatButton = createButton(
    LABELS.SEAT_OFF,
    UDim2.new(1, -16, 0, 31),
    UDim2.fromOffset(8, 103),
    main
)

-- EXIT SEAT
local exitButton = createButton(
    LABELS.EXIT,
    UDim2.new(1, -16, 0, 31),
    UDim2.fromOffset(8, 140),
    main
)

exitButton.BackgroundColor3 = Color3.fromRGB(180, 55, 55)

-- STATUS
local statusLabel = createLabel(
    UDim2.new(1, -12, 0, 23), UDim2.fromOffset(6, 180),
    "NOT SEATED",
    Enum.Font.Gotham, 11, GREY, main
)

--==================================================
-- GUI UPDATE
--==================================================

local function updateGUI()
    flyButton.Text = flying and LABELS.FLY_ON or LABELS.FLY_OFF
    flyButton.BackgroundColor3 = flying and COLOR_ON or COLOR_OFF

    seatButton.Text = seatPickerEnabled and LABELS.SEAT_ON
        or (pickerSuspended and LABELS.SEAT_PAUSED or LABELS.SEAT_OFF)
    seatButton.BackgroundColor3 = seatPickerEnabled and COLOR_ON or COLOR_OFF

    speedLabel.Text = tostring(speed)
end

--==================================================
-- HIGHLIGHT (single reusable instance)
--==================================================

local GREEN = Color3.fromRGB(0, 255, 0)

-- NOTE: a Highlight with no Adornee highlights its PARENT (Workspace = the
-- whole screen). So it is always disabled before the Adornee is cleared.
local function clearHighlight()
    if highlight then
        highlight.Enabled = false
        highlight.Adornee = nil
    end
end

--- Highlights `part` only if it is a valid, unanchored, non-character part.
--- Safe to call repeatedly: redundant writes are skipped.
local function updateHighlight(part)
    local valid = part ~= nil
        and part.Parent ~= nil
        and part:IsA("BasePart")
        and not part.Anchored

    if valid then
        local char = getCharacter()

        if char and part:IsDescendantOf(char) then
            valid = false
        end
    end

    if not valid then
        clearHighlight()
        return
    end

    -- (Re)create if missing or removed by the game
    if not highlight or not highlight.Parent then
        highlight = Instance.new("Highlight")

        highlight.Name = randomName()

        highlight.FillColor = GREEN
        highlight.FillTransparency = 0.5

        highlight.OutlineColor = GREEN
        highlight.OutlineTransparency = 0

        -- Adornee is set BEFORE parenting so it never flashes the whole world
        highlight.Enabled = false
        highlight.Adornee = part
        highlight.Parent = Workspace
    end

    if highlight.Adornee ~= part then
        highlight.Adornee = part
    end

    if not highlight.Enabled then
        highlight.Enabled = true
    end
end

--- Re-evaluates what is under the cursor (also called on a timer and on click,
--- so the highlight never goes stale when the camera/character moves
--- without mouse movement, or on touch devices where Mouse.Move never fires).
local function refreshHighlight()
    if not seatPickerEnabled then
        return
    end

    -- A part is already picked: no highlight until the seat is released
    if currentSeat then
        clearHighlight()
        return
    end

    updateHighlight(Mouse.Target)
end

--==================================================
-- SEAT CLEANUP
--==================================================

-- Parts made light: part -> original CustomPhysicalProperties (false = default)
local lightened = {}
local lightenSeen = setmetatable({}, { __mode = "k" })  -- parts already evaluated

-- Weightless part: an upward VectorForce equal to the assembly's weight
local antiGen = 0
local antiObjects = {}

local function stopAntiGravity()
    antiGen += 1

    for _, obj in ipairs(antiObjects) do
        pcall(obj.Destroy, obj)
    end

    table.clear(antiObjects)
end

local function startAntiGravity(part)
    if not CONFIG.LIGHTEN.ANTI_GRAVITY then
        return
    end

    stopAntiGravity()

    local att = Instance.new("Attachment")
    att.Name = randomName()
    att.Parent = part

    local force = Instance.new("VectorForce")
    force.Name = randomName()
    force.Attachment0 = att
    force.RelativeTo = Enum.ActuatorRelativeTo.World
    force.ApplyAtCenterOfMass = true
    force.Force = VEC_ZERO
    force.Parent = part

    antiObjects[1] = att
    antiObjects[2] = force

    local gen = antiGen

    task.spawn(function()
        while gen == antiGen and currentSeat and part.Parent do
            pcall(function()
                force.Force = Vector3.new(0, part.AssemblyMass * Workspace.Gravity, 0)
            end)

            taskWait(0.25)
        end
    end)
end

local function restoreLightened()
    for part, original in pairs(lightened) do
        pcall(function()
            part.CustomPhysicalProperties = original or nil
        end)
    end

    table.clear(lightened)
    table.clear(lightenSeen)

    stopAntiGravity()
end

-- Lightens one loose part. Returns true if it changed.
-- UNIFORM: every part gets MIN_DENSITY, so nearby parts all weigh alike
-- (riders and the part they stand on keep a sane mass ratio).
-- Otherwise only parts heavier than TARGET_MASS are brought down to it.
local function lightenOne(p, cfg)
    if lightenSeen[p] or p.Anchored then
        return false
    end

    lightenSeen[p] = true

    local cur = p.CurrentPhysicalProperties
    local density = cfg.MIN_DENSITY

    if not cfg.UNIFORM then
        local volume = p.Size.X * p.Size.Y * p.Size.Z

        density = mathClamp(cfg.TARGET_MASS / volume, cfg.MIN_DENSITY, 100)
    end

    if density >= cur.Density then
        return false
    end

    lightened[p] = p.CustomPhysicalProperties or false

    pcall(function()
        p.CustomPhysicalProperties = PhysicalProperties.new(
            density,
            cur.Friction,
            cur.Elasticity,
            cur.FrictionWeight,
            cur.ElasticityWeight
        )
    end)

    return true
end

-- The picked part and the parts welded to it (never characters)
local function lightenPart(part)
    local cfg = CONFIG.LIGHTEN

    if not cfg.ENABLED then
        return
    end

    local list = { part }
    local ok, connected = pcall(part.GetConnectedParts, part, true)

    if ok then
        for _, p in ipairs(connected) do
            if p ~= part and #list < cfg.MAX_PARTS then
                local model = p.Parent

                if not (model and model:FindFirstChildOfClass("Humanoid")) then
                    list[#list + 1] = p
                end
            end
        end
    end

    for _, p in ipairs(list) do
        lightenOne(p, cfg)
    end

    -- Weightless while seated (removed on exit)
    startAntiGravity(part)
end

-- Every loose part within NEARBY.RADIUS studs of the player (never characters)
local nearbyParams = OverlapParams.new()
nearbyParams.MaxParts = CONFIG.LIGHTEN.NEARBY.QUERY_MAX

local function lightenNearby()
    local cfg = CONFIG.LIGHTEN
    local nearby = cfg.NEARBY

    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")

    if not hrp then
        return
    end

    local ok, parts = pcall(
        Workspace.GetPartBoundsInRadius,
        Workspace,
        hrp.Position,
        nearby.RADIUS,
        nearbyParams
    )

    if not ok then
        return
    end

    local changed = 0

    for i = 1, #parts do
        local p = parts[i]

        if not lightenSeen[p] and not p.Anchored then
            local model = p.Parent
            local isCharacter = model and model:FindFirstChildOfClass("Humanoid")

            if not isCharacter or (nearby.INCLUDE_PLAYERS and model ~= char) then
                if lightenOne(p, cfg) then
                    changed += 1

                    if changed >= nearby.PER_PASS then
                        break
                    end
                end
            end
        end
    end
end

local function cleanupSeat(resetHumanoid)
    if seatStateConnection then
        seatStateConnection:Disconnect()
        seatStateConnection = nil
    end

    local oldSeat = currentSeat
    local tempSeat = pendingSeat

    currentSeat = nil
    pendingSeat = nil

    if oldSeat then
        -- The assembly carries fly velocity; clear it first so the picked
        -- part isn't flung away when the seat is removed.
        if flying then
            local p = oldSeat:IsA("BasePart") and oldSeat
                or (oldSeat:IsA("JointInstance") and oldSeat.Part0)

            if p then
                pcall(function()
                    p.AssemblyLinearVelocity = VEC_ZERO
                    p.AssemblyAngularVelocity = VEC_ZERO
                end)
            end
        end

        pcall(oldSeat.Destroy, oldSeat)
    end

    if tempSeat and tempSeat ~= oldSeat then
        pcall(tempSeat.Destroy, tempSeat)
    end

    restoreLightened()

    pickedPart = nil

    if stopPushGuard then
        stopPushGuard()
    end

    if charWeldInst then
        pcall(charWeldInst.Destroy, charWeldInst)
        charWeldInst = nil
    end

    if resetHumanoid then
        local hum = getHumanoid()

        if hum and hum.Health > 0 then
            pcall(function()
                hum.Jump = false
                hum.Sit = false

                hum:ChangeState(HState.GettingUp)
            end)
        end
    end

    if pickerSuspended then
        resumePicker()
    end
end

--==================================================
-- STAND UP LISTENER
--==================================================

local function setupStandUpListener(hum, obj)
    if seatStateConnection then
        seatStateConnection:Disconnect()
        seatStateConnection = nil
    end

    seatStateConnection = hum.StateChanged:Connect(function(_, newState)
        if newState == HState.Seated then
            return
        end

        taskDelay(0.35, function()
            if currentSeat ~= obj then
                return
            end

            if not hum.Parent or hum.Health <= 0 then
                cleanupSeat(false)
                return
            end

            local stillSeated

            if obj:IsA("Seat") then
                stillSeated = hum.SeatPart == obj
            else
                stillSeated = hum.SeatPart == nil
                    and (hum.Sit or hum:GetState() == HState.Seated)
            end

            if stillSeated then
                return
            end

            if KEEP_SEATED and obj.Parent then
                -- Left the seat unexpectedly: sit back down instead of falling off
                if obj:IsA("Seat") then
                    pcall(obj.Sit, obj, hum)
                else
                    pcall(function()
                        hum.Sit = true

                        hum:ChangeState(HState.Seated)
                    end)
                end

                return
            end

            cleanupSeat(false)
        end)
    end)
end

--==================================================
-- ORIGINAL SEAT LOGIC v3
--==================================================

-- Short on-screen notice (status label) explaining why a pick was refused
local notice = nil
local noticeUntil = 0

local function notify(text)
    notice = text
    noticeUntil = os.clock() + 2.5

    warn("[FlySeat] " .. text)
end

-- Monotonic token: bumping it cancels any in-flight sitOnPart
local sitToken = 0

--- Waits `t` seconds, then reports whether the sit operation is still valid.
--- @param token number        token captured when the operation started
--- @param t number            seconds to wait
--- @param resetOnCancel boolean? undo partial work if the picker was disabled
--- @return boolean            true = keep going, false = cancelled
local function sitSleep(token, t, resetOnCancel)
    taskWait(t)

    if token == sitToken then
        return true
    end

    if resetOnCancel and not seatPickerEnabled then
        cleanupSeat(true)
    end

    return false
end

local function sitOnPart(part)
    if not seatPickerEnabled then return end

    local char = getCharacter()
    if not char then return end

    local hum = char:FindFirstChildOfClass("Humanoid")
    local rootPart = char:FindFirstChild("HumanoidRootPart")

    if not (hum and rootPart) then return end

    if not part or not part.Parent then
        return
    end

    if part.Anchored then
        notify("ANCHORED - PICK AN UNANCHORED PART")
        return
    end

    if part:IsDescendantOf(char) then
        return
    end

    -- Prevent sitting on another real game seat
    if hum.SeatPart and hum.SeatPart ~= currentSeat then
        notify("STAND UP FROM THE GAME SEAT FIRST")
        return
    end

    -- A new attempt supersedes (cancels) any older one still waiting
    sitToken += 1
    local token = sitToken

    cleanupSeat(false)

    -- ORIGINAL HUMANOID RESET
    pcall(function()
        hum.Sit = false

        hum:ChangeState(HState.GettingUp)
    end)

    if not sitSleep(token, 0.25) or not part.Parent then
        return
    end

    -- ORIGINAL DISTANCE HANDLING
    local distance = (part.Position - rootPart.Position).Magnitude

    if distance > 50 then
        pcall(function()
            char:PivotTo(
                part.CFrame * CFrame.new(0, part.Size.Y / 2 + 5, 0)
            )
        end)

        if not sitSleep(token, 0.15) then
            return
        end
    end

    if token ~= sitToken or not part.Parent then
        return
    end

    -- ORIGINAL SIT POSITION
    local sitPos = part.CFrame * CFrame.new(0, part.Size.Y / 2 + 2.5, 0)
    local seatCFrame = sitPos - Vector3.new(0, 2.5, 0)

    -- METHOD 1: SEAT:SIT
    local seat = Instance.new("Seat")

    seat.Name = randomName()
    seat.Size = Vector3.new(2, 0.2, 2)

    seat.CFrame = seatCFrame

    seat.Anchored = true
    seat.Transparency = 1

    seat.CanCollide = false
    seat.CanTouch = false
    seat.CanQuery = false

    seat.Massless = true
    seat.Parent = Workspace

    pendingSeat = seat

    pcall(seat.Sit, seat, hum)

    if not sitSleep(token, 0.15, true) then
        return
    end

    if hum.SeatPart == seat then
        -- ORIGINAL METHOD 1 SUCCESS
        if not FREEZE_PART then
            local weld = Instance.new("WeldConstraint")

            weld.Name = randomName()
            weld.Part0 = seat
            weld.Part1 = part

            weld.Parent = seat

            if not sitSleep(token, 0.05, true) then
                return
            end

            seat.Anchored = false
        end

        currentSeat = seat
        pendingSeat = nil

        setupStandUpListener(hum, seat)

        clearHighlight()

        if SUSPEND_PICKER then
            suspendPicker()
        end

        pickedPart = part
        lightenPart(part)
        startPushGuard()

        print("[FlySeat] Sit successful (Seat:Sit)")
        return
    end

    -- METHOD 2: ORIGINAL WELD FALLBACK
    print("[FlySeat] Seat:Sit failed -> Weld fallback")

    seat:Destroy()
    pendingSeat = nil

    if not sitSleep(token, 0.05) or not part.Parent then
        return
    end

    pcall(char.PivotTo, char, sitPos)

    if not sitSleep(token, 0.1) then
        return
    end

    pcall(function()
        hum.Sit = true

        hum:ChangeState(HState.Seated)
    end)

    if not sitSleep(token, 0.1, true) then
        return
    end

    if FREEZE_PART then
        local frozenSeat = Instance.new("Part")

        frozenSeat.Name = randomName()
        frozenSeat.Size = Vector3.new(2, 0.2, 2)

        frozenSeat.CFrame = seatCFrame

        frozenSeat.Anchored = true
        frozenSeat.Transparency = 1

        frozenSeat.CanCollide = false
        frozenSeat.CanTouch = false
        frozenSeat.CanQuery = false

        frozenSeat.Parent = Workspace

        local partWeld = Instance.new("WeldConstraint")

        partWeld.Name = randomName()
        partWeld.Part0 = frozenSeat
        partWeld.Part1 = part

        partWeld.Parent = frozenSeat

        currentSeat = frozenSeat

        local charWeld = Instance.new("Weld")

        charWeld.Name = randomName()
        charWeld.Part0 = frozenSeat
        charWeld.Part1 = rootPart

        charWeld.C0 = CFrame.new(0, 2.5, 0)
        charWeld.Parent = rootPart

        charWeldInst = charWeld

        setupStandUpListener(hum, frozenSeat)

    else
        local weld = Instance.new("Weld")

        weld.Name = randomName()
        weld.Part0 = part
        weld.Part1 = rootPart

        weld.C0 = CFrame.new(0, part.Size.Y / 2 + 2.5, 0)

        weld.Parent = rootPart

        currentSeat = weld

        setupStandUpListener(hum, weld)
    end

    clearHighlight()

    if SUSPEND_PICKER then
        suspendPicker()
    end

    pickedPart = part
    lightenPart(part)
    startPushGuard()

    print("[FlySeat] Sit successful (Weld)")
end

--==================================================
-- EXIT SEAT BUTTON
--==================================================

local function exitSeat()
    -- Cancel any in-flight sit attempt, then remove seat/welds and reset the humanoid
    sitToken += 1
    cleanupSeat(true)

    print("[FlySeat] Exit seat requested")
end

--==================================================
-- SEAT PICKER TOGGLE
--==================================================

local function setSeatPicker(state)
    -- Any explicit toggle ends the automatic pause
    pickerSuspended = false

    if seatPickerEnabled == state then
        return
    end

    seatPickerEnabled = state

    -- Cancels any in-flight sitOnPart (on enable too, so stale ones stay dead)
    sitToken += 1

    if seatPickerEnabled then
        inputConn = UIS.InputBegan:Connect(function(input, gp)
            if gp then
                return
            end

            local t = input.UserInputType

            if t ~= UIT.MouseButton1 and t ~= UIT.Touch then
                return
            end

            -- Sync the highlight with the part that is about to be used
            refreshHighlight()

            local target = Mouse.Target

            if target and target:IsA("BasePart") then
                sitOnPart(target)
            end
        end)

    else
        if inputConn then
            inputConn:Disconnect()
            inputConn = nil
        end

        clearHighlight()

        -- Cancel only an unfinished seat operation.
        -- Do not kick the player out of the current seat.
        if pendingSeat then
            pcall(pendingSeat.Destroy, pendingSeat)

            pendingSeat = nil
        end
    end

    updateGUI()
end

-- Pauses the picker after a successful pick; resumed when the seat is released
suspendPicker = function()
    if not seatPickerEnabled then
        return
    end

    setSeatPicker(false)
    pickerSuspended = true

    updateGUI()
end

resumePicker = function()
    if pickerSuspended then
        setSeatPicker(true)
    end
end

--==================================================
-- FLY PHYSICS CLEANUP
--==================================================

local function removeFlyPhysics()
    if velocity then pcall(velocity.Destroy, velocity) end
    if orientation then pcall(orientation.Destroy, orientation) end
    if alignPos then pcall(alignPos.Destroy, alignPos) end
    if attachment then pcall(attachment.Destroy, attachment) end

    velocity = nil
    orientation = nil
    alignPos = nil
    attachment = nil

    holding = false
    idleTimer = 0

    lastVel = nil
    lastAppliedYaw = nil
    lastAttPos = nil
end

--==================================================
-- FLAT YAW
--==================================================

local function getFlatYaw(cf)
    local look = cf.LookVector

    -- Only update when the look vector isn't (nearly) vertical
    if look.X * look.X + look.Z * look.Z > 0.000001 then
        lastYaw = mathAtan2(-look.X, -look.Z)
    end

    return lastYaw
end

--==================================================
-- ASSEMBLY CONTROL
--==================================================

-- Constraints stay on the HumanoidRootPart: they act on the whole welded
-- assembly anyway, and (unlike the assembly root part) the root can't be
-- destroyed together with the picked part or the seat.
local function updateActuatorAssembly(force)
    if not attachment or not root or not root.Parent then
        return nil
    end

    -- Apply force at the assembly's center of mass (re-read only when forced)
    if force or not lastAttPos then
        local attPos = root.CFrame:PointToObjectSpace(root.AssemblyCenterOfMass)

        if attPos ~= lastAttPos then
            attachment.Position = attPos
            lastAttPos = attPos
        end
    end

    return root
end

local function createFlyPhysics()
    attachment = Instance.new("Attachment")
    attachment.Name = randomName()
    attachment.Parent = root

    velocity = Instance.new("LinearVelocity")
    velocity.Name = randomName()

    velocity.Attachment0 = attachment
    velocity.RelativeTo = Enum.ActuatorRelativeTo.World

    velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector

    velocity.ForceLimitsEnabled = false
    velocity.VectorVelocity = VEC_ZERO

    velocity.Parent = root

    orientation = Instance.new("AlignOrientation")
    orientation.Name = randomName()

    orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment

    orientation.Attachment0 = attachment

    orientation.RigidityEnabled = false
    orientation.Responsiveness = UPRIGHT_RESPONSIVENESS
    orientation.MaxTorque = UPRIGHT_MAX_TORQUE
    orientation.MaxAngularVelocity = UPRIGHT_MAX_ANGULAR

    orientation.Enabled = true
    orientation.Parent = root

    alignPos = Instance.new("AlignPosition")
    alignPos.Name = randomName()

    alignPos.Mode = Enum.PositionAlignmentMode.OneAttachment
    alignPos.Attachment0 = attachment

    alignPos.RigidityEnabled = CONFIG.HOLD.RIGID
    alignPos.MaxForce = mathHuge
    alignPos.MaxVelocity = CONFIG.HOLD.MAX_SPEED
    alignPos.Responsiveness = CONFIG.HOLD.RESPONSIVENESS

    alignPos.Enabled = false
    alignPos.Parent = root

    lastYaw = getFlatYaw(root.CFrame)

    lastVel = VEC_ZERO
    lastAppliedYaw = nil
    lastAttPos = nil

    updateActuatorAssembly(true)
end

--==================================================
-- ANTI TILT / YAW ONLY
--==================================================

local function stabilizeAssembly(assembly, seated, dt)
    if not assembly or not assembly.Parent then
        return
    end

    local angular = assembly.AssemblyAngularVelocity

    local factor = mathExp(-(seated and SEATED_DAMPING or NORMAL_DAMPING) * dt)

    -- Remove pitch and roll
    local x = angular.X * factor
    local z = angular.Z * factor

    -- Keep yaw rotation, but limit excessive spinning
    local y = mathClamp(angular.Y, -MAX_YAW_RATE, MAX_YAW_RATE)

    if mathAbs(x) > 0.01
        or mathAbs(z) > 0.01
        or mathAbs(angular.Y) > MAX_YAW_RATE then

        assembly.AssemblyAngularVelocity = Vector3.new(x, y, z)
    end
end

--==================================================
-- FLY ON / OFF
--==================================================

local statusTimer = 0
local highlightTimer = 0
local nearbyTimer = 0
local simTimer = 0
local comTimer = 0
local stabTimer = 0
local lastSeatedState = nil
local smoothVel = Vector3.zero

local STATUS_INTERVAL = CONFIG.INTERVALS.STATUS
local SIM_INTERVAL = CONFIG.INTERVALS.SIM_RADIUS
local COM_INTERVAL = CONFIG.INTERVALS.CENTER_OF_MASS
local COM_INTERVAL_SEATED = CONFIG.INTERVALS.CENTER_OF_MASS_SEATED
local SPEED_SMOOTHING = CONFIG.SPEED.SMOOTHING
local STAB_INTERVAL = CONFIG.INTERVALS.STABILIZE
local HIGHLIGHT_INTERVAL = CONFIG.INTERVALS.HIGHLIGHT
local HOLD_ENABLED = CONFIG.HOLD.ENABLED
local HOLD_DELAY = CONFIG.HOLD.DELAY
local HOLD_SNAP = CONFIG.HOLD.SNAP_DISTANCE

-- The fly loop is connected only while fly is ON (defined further below)
local flyStep
local flyConn = nil

local function setFly(state)
    if state == flying then
        return
    end

    if state then
        local char = getCharacter()

        if not char then return end

        local newRoot = char:FindFirstChild("HumanoidRootPart")
        local newHum = char:FindFirstChildOfClass("Humanoid")

        if not newRoot or not newHum or newHum.Health <= 0 then
            return
        end

        root = newRoot
        humanoid = newHum

        oldAutoRotate = humanoid.AutoRotate
        humanoid.AutoRotate = false

        if not isSeated() then
            humanoid:ChangeState(HState.Physics)
        end

        createFlyPhysics()

        flying = true

        simTimer = SIM_INTERVAL
        comTimer = 0
        stabTimer = 0
        lastSeatedState = nil
        smoothVel = VEC_ZERO

        flyConn = RunService.Heartbeat:Connect(flyStep)

    else
        local wasSeated = isSeated()

        flying = false
        clearKeys()

        if flyConn then
            flyConn:Disconnect()
            flyConn = nil
        end


        removeFlyPhysics()

        if root and root.Parent then
            pcall(function()
                root.AssemblyLinearVelocity = VEC_ZERO
                root.AssemblyAngularVelocity = VEC_ZERO
            end)
        end

        if humanoid and humanoid.Parent then
            if oldAutoRotate ~= nil then
                humanoid.AutoRotate = oldAutoRotate
            else
                humanoid.AutoRotate = true
            end

            if humanoid.Health > 0 and not wasSeated then
                humanoid:ChangeState(HState.GettingUp)
            end
        end

        root = nil
        humanoid = nil
        oldAutoRotate = nil
    end

    updateGUI()
end

--==================================================
-- STATUS TEXT
--==================================================

local STATUS_BLUE = Color3.fromRGB(100, 180, 255)
local STATUS_GREEN = Color3.fromRGB(80, 220, 130)
local STATUS_WARN = Color3.fromRGB(255, 190, 80)

local lastStatus = nil

local function updateStatus(seated)
    local text, color

    if seated and flying then
        text, color = "SEATED | FLYING", STATUS_GREEN
    elseif seated then
        text, color = "SEATED", STATUS_GREEN
    elseif flying then
        text, color = "FLYING", STATUS_BLUE
    else
        text, color = "READY", GREY
    end

    if notice and os.clock() < noticeUntil then
        text, color = notice, STATUS_WARN
    end

    if text ~= lastStatus then
        lastStatus = text
        statusLabel.Text = text
        statusLabel.TextColor3 = color
    end
end

--==================================================
-- UI LOOP (always) + FLY LOOP (only while flying)
--==================================================

-- Camera cached; refreshed only when Workspace.CurrentCamera changes
local camera = Workspace.CurrentCamera

connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
    camera = Workspace.CurrentCamera
end)

-- Light UI loop: status text + seat-picker highlight
connect(RunService.Heartbeat, function(dt)
    statusTimer += dt

    if statusTimer >= STATUS_INTERVAL then
        statusTimer = 0
        updateStatus(isSeated())
    end

    if seatPickerEnabled then
        highlightTimer += dt

        if highlightTimer >= HIGHLIGHT_INTERVAL then
            highlightTimer = 0
            refreshHighlight()
        end
    end

    -- Lighten loose parts around you while a part is picked
    if currentSeat and CONFIG.LIGHTEN.ENABLED and CONFIG.LIGHTEN.NEARBY.ENABLED then
        nearbyTimer += dt

        if nearbyTimer >= CONFIG.LIGHTEN.NEARBY.INTERVAL then
            nearbyTimer = 0
            lightenNearby()
        end
    else
        nearbyTimer = CONFIG.LIGHTEN.NEARBY.INTERVAL
    end
end)

-- Fly loop: connected in setFly(true), disconnected in setFly(false)
local function flyStepBody(dt)
    if not flying then
        return
    end

    -- Simulation radius (executor only)
    if setHidden then
        simTimer += dt

        if simTimer >= SIM_INTERVAL then
            simTimer = 0
            pcall(setHidden, LP, "SimulationRadius", mathHuge)
            pcall(setHidden, LP, "MaximumSimulationRadius", mathHuge)
        end
    end

    -- Re-acquire the character parts instead of switching fly off on a hiccup
    local char = LP.Character

    if char then
        if not root or not root.Parent then
            root = char:FindFirstChild("HumanoidRootPart")
        end

        if not humanoid or not humanoid.Parent then
            humanoid = char:FindFirstChildOfClass("Humanoid")
        end
    end

    if not root or not root.Parent
        or not humanoid or not humanoid.Parent
        or humanoid.Health <= 0 then

        setFly(false)
        return
    end

    if not (velocity and velocity.Parent
        and orientation and orientation.Parent
        and alignPos and alignPos.Parent
        and attachment and attachment.Parent) then

        removeFlyPhysics()
        createFlyPhysics()
    end

    if not camera then
        return
    end

    local cf = camera.CFrame
    local direction = VEC_ZERO

    if keys.W then direction += cf.LookVector end
    if keys.S then direction -= cf.LookVector end
    if keys.A then direction -= cf.RightVector end
    if keys.D then direction += cf.RightVector end
    if keys.Up then direction += VEC_Y end
    if keys.Down then direction -= VEC_Y end

    if direction.Magnitude > 1 then
        direction = direction.Unit
    end

    local seated = isSeated()

    -- Re-read center of mass only on seat change or every COM_INTERVAL
    local force = lastSeatedState ~= seated

    -- Capture the heading the moment we become seated
    if seated and not lastSeatedState then
        local look = root.CFrame.LookVector

        if look.X * look.X + look.Z * look.Z > 0.000001 then
            seatYaw = mathAtan2(-look.X, -look.Z)
        end
    end

    lastSeatedState = seated

    comTimer += dt

    if comTimer >= (seated and COM_INTERVAL_SEATED or COM_INTERVAL) then
        comTimer = 0
        force = true
    end

    local assembly = updateActuatorAssembly(force)

    if not assembly then
        return
    end

    -- Speed control, eased: abrupt velocity jumps would jerk riders on the part
    local inputVel = direction
        * (seated and mathMin(speed, SEATED_SPEED_CAP) or speed)

    local wanted = inputVel.Magnitude

    local ease = SPEED_SMOOTHING > 0 and (1 - mathExp(-SPEED_SMOOTHING * dt)) or 1

    smoothVel = smoothVel:Lerp(inputVel, ease)

    if wanted < 0.01 and smoothVel.Magnitude < 0.05 then
        smoothVel = VEC_ZERO
    end

    if smoothVel ~= lastVel then
        velocity.VectorVelocity = smoothVel
        lastVel = smoothVel
    end

    -- Position hold: while seated and idle, pull the assembly back to where it
    -- stopped (velocity lock alone lets repeated pushes accumulate as drift)
    if HOLD_ENABLED and seated and wanted < 0.01 and smoothVel.Magnitude < 1 then
        idleTimer += dt

        if not holding and idleTimer >= HOLD_DELAY then
            alignPos.Position = attachment.WorldPosition
            alignPos.Enabled = true
            velocity.Enabled = false
            holding = true
        end

        -- Safety net: if the held part still got pulled away, put it back
        if holding and HOLD_SNAP > 0 then
            local delta = alignPos.Position - attachment.WorldPosition

            if delta.Magnitude > HOLD_SNAP then
                root.CFrame = root.CFrame + delta
                root.AssemblyLinearVelocity = VEC_ZERO
                root.AssemblyAngularVelocity = VEC_ZERO
            end
        end
    else
        idleTimer = 0

        if holding then
            holding = false
            alignPos.Enabled = false
            velocity.Enabled = true
        end
    end

    -- Keep the constraints consistent with the hold state
    if not holding then
        if not velocity.Enabled then
            velocity.Enabled = true
        end

        if alignPos.Enabled then
            alignPos.Enabled = false
        end
    end

    if not orientation.Enabled then
        orientation.Enabled = true
    end

    -- Keep assembly upright, only yaw is allowed
    if orientation then
        local yaw = getFlatYaw(cf)

        if seated and not ROTATE_SEATED then
            yaw = seatYaw
        end

        if yaw ~= lastAppliedYaw then
            orientation.CFrame = CFAngles(0, yaw, 0)
            lastAppliedYaw = yaw
        end
    end

    -- Anti tilt and anti spin (30 Hz, damping uses the accumulated dt)
    stabTimer += dt

    if stabTimer >= STAB_INTERVAL then
        stabilizeAssembly(assembly, seated, stabTimer)
        stabTimer = 0
    end
end

-- A runtime error inside the fly step would silently stop the fly: show it instead
local lastFlyError = nil

flyStep = function(dt)
    local ok, err = pcall(flyStepBody, dt)

    if not ok then
        local msg = tostring(err)

        if msg ~= lastFlyError then
            lastFlyError = msg
            warn("[FlySeat] fly error: " .. msg)
            notify("FLY ERROR: " .. msg:sub(1, 60))
        end
    end
end

--==================================================
-- KEYBOARD
--==================================================

local FLY_TOGGLE_KEY = CONFIG.KEYS.FLY
local SEAT_TOGGLE_KEY = CONFIG.KEYS.SEAT_PICKER
local EXIT_SEAT_KEY = CONFIG.KEYS.EXIT_SEAT

-- key code -> movement action
local keyMap = {}

for action, codes in pairs(CONFIG.MOVE_KEYS) do
    for _, code in ipairs(codes) do
        keyMap[code] = action
    end
end

connect(UIS.InputBegan, function(input, processed)
    if processed then return end

    -- PC hotkey: toggle fly
    if input.KeyCode == FLY_TOGGLE_KEY then
        setFly(not flying)
        return
    end

    -- PC hotkey: toggle Seat Picker
    if input.KeyCode == SEAT_TOGGLE_KEY then
        setSeatPicker(not seatPickerEnabled)
        return
    end

    -- PC hotkey: exit seat
    if input.KeyCode == EXIT_SEAT_KEY then
        if currentSeat or pendingSeat or isSeated() then
            exitSeat()
        end

        return
    end

    local key = keyMap[input.KeyCode]

    if key then
        keys[key] = true
    end
end)

connect(UIS.InputEnded, function(input)
    local key = keyMap[input.KeyCode]

    if key then
        keys[key] = false
    end

    local mobileKey = heldInputs[input]

    if mobileKey then
        keys[mobileKey] = false
        heldInputs[input] = nil
    end
end)

connect(UIS.WindowFocusReleased, clearKeys)

--==================================================
-- MOBILE CONTROLS
--==================================================

local mobile = Instance.new("Frame")

mobile.Name = randomName()
mobile.Size = UDim2.fromOffset(160, 145)

mobile.Position = UDim2.new(1, -175, 1, -165)

mobile.BackgroundTransparency = 1
mobile.Visible = UIS.TouchEnabled

mobile.Parent = gui

local BUTTON_SIZE = UDim2.fromOffset(48, 42)

local function holdButton(text, key, x, y)
    local b = createButton(
        text,
        BUTTON_SIZE,
        UDim2.fromOffset(x, y),
        mobile
    )

    connect(b.InputBegan, function(input)
        local t = input.UserInputType

        if t == UIT.Touch or t == UIT.MouseButton1 then
            keys[key] = true
            heldInputs[input] = key
        end
    end)
end

holdButton("W", "W", 56, 0)
holdButton("A", "A", 4, 47)
holdButton("S", "S", 56, 47)
holdButton("D", "D", 108, 47)
holdButton("UP", "Up", 30, 94)
holdButton("DOWN", "Down", 82, 94)

--==================================================
-- CUSTOM DRAG (replaces deprecated Frame.Draggable)
--==================================================

do
    local dragInput, dragStart, startPos, moveConn

    local function stopDrag()
        dragInput = nil

        if moveConn then
            moveConn:Disconnect()
            moveConn = nil
        end
    end

    connect(main.InputBegan, function(input)
        local t = input.UserInputType

        if t ~= UIT.MouseButton1 and t ~= UIT.Touch then
            return
        end

        stopDrag()

        dragInput = input
        dragStart = input.Position
        startPos = main.Position

        -- Mouse: any movement. Touch: only the finger that started the drag.
        moveConn = UIS.InputChanged:Connect(function(changed)
            if changed.UserInputType ~= UIT.MouseMovement
                and changed ~= dragInput then
                return
            end

            local delta = changed.Position - dragStart

            main.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end)

        local c
        c = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                if dragInput == input then
                    stopDrag()
                end

                c:Disconnect()
            end
        end)
    end)

    connect(gui.Destroying, stopDrag)
end

--==================================================
-- GUI BUTTON EVENTS
--==================================================

connect(flyButton.Activated, function()
    setFly(not flying)
end)

connect(seatButton.Activated, function()
    setSeatPicker(not seatPickerEnabled)
end)

connect(exitButton.Activated, exitSeat)

connect(minus.Activated, function()
    speed = mathMax(minSpeed, speed - speedStep)

    updateGUI()
end)

connect(plus.Activated, function()
    speed = mathMin(maxSpeed, speed + speedStep)

    updateGUI()
end)

--==================================================
-- RESPAWN
--==================================================

connect(LP.CharacterAdded, function()
    sitToken += 1

    setFly(false)

    cleanupSeat(false)
    clearHighlight()
end)

--==================================================
-- ANTI-PUSH (runs while a part is picked)
--==================================================
-- Two layers, both local to this client's simulation:
--  1. NoCollisionConstraint between nearby players' main parts and the picked
--     part. Humanoids never touch these, so they hold.
--  2. CanCollide = false on those parts every Stepped and Heartbeat, because
--     Humanoids re-enable collision on their torso / head / root.

local PUSH_RADIUS = CONFIG.PUSH.RADIUS
local PUSH_REFRESH = CONFIG.PUSH.REFRESH

local PUSH_KEY_PARTS = {
    HumanoidRootPart = true,
    Head = true,
    Torso = true,
    UpperTorso = true,
    LowerTorso = true,
}

local pushTargets = {}
local pushChanged = setmetatable({}, { __mode = "k" })  -- parts we turned non-collidable
local pushPairs = {}   -- their part -> NoCollisionConstraint
local pushTimer = 0
local pushConns = {}

local function refreshPushTargets()
    table.clear(pushTargets)

    -- Drop constraints whose parts are gone
    for part, constraint in pairs(pushPairs) do
        if not part.Parent or not constraint.Parent then
            pcall(constraint.Destroy, constraint)
            pushPairs[part] = nil
        end
    end

    local char = LP.Character
    local myRoot = char and char:FindFirstChild("HumanoidRootPart")

    if not myRoot then
        return
    end

    local origin = myRoot.Position
    local created = 0

    for _, plr in ipairs(Players:GetPlayers()) do
        local c = plr ~= LP and plr.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")

        if r and (r.Position - origin).Magnitude <= PUSH_RADIUS then
            for _, obj in ipairs(c:GetChildren()) do
                if obj:IsA("BasePart") and (obj.CanCollide or PUSH_KEY_PARTS[obj.Name]) then
                    pushTargets[#pushTargets + 1] = obj

                    -- Layer 1: a constraint against the picked part
                    if pickedPart and pickedPart.Parent
                        and PUSH_KEY_PARTS[obj.Name]
                        and not pushPairs[obj]
                        and created < 20 then

                        local ok, constraint = pcall(function()
                            local nc = Instance.new("NoCollisionConstraint")

                            nc.Name = randomName()
                            nc.Part0 = obj
                            nc.Part1 = pickedPart
                            nc.Parent = pickedPart

                            return nc
                        end)

                        if ok then
                            pushPairs[obj] = constraint
                            created += 1
                        end
                    end
                end
            end
        end
    end
end

local function restorePush()
    for _, constraint in pairs(pushPairs) do
        pcall(constraint.Destroy, constraint)
    end

    for part in pairs(pushChanged) do
        pcall(function()
            part.CanCollide = true
        end)
    end

    table.clear(pushPairs)
    table.clear(pushChanged)
    table.clear(pushTargets)
end

-- Layer 2, applied twice per frame (Stepped and Heartbeat)
local function pushApply()
    for i = 1, #pushTargets do
        local part = pushTargets[i]

        if part.CanCollide then
            part.CanCollide = false
            pushChanged[part] = true
        end
    end
end

local function pushStep(_, dt)
    if not currentSeat then
        if next(pushChanged) or next(pushPairs) then
            restorePush()
        end

        return
    end

    pushTimer += dt

    if pushTimer >= PUSH_REFRESH then
        pushTimer = 0
        refreshPushTargets()
    end

    pushApply()
end

function startPushGuard()
    if not CONFIG.PUSH.ENABLED or pushConns[1] then
        return
    end

    pushTimer = PUSH_REFRESH

    pushConns[1] = RunService.Stepped:Connect(pushStep)
    pushConns[2] = RunService.Heartbeat:Connect(pushApply)
end

function stopPushGuard()
    for i = 1, #pushConns do
        pushConns[i]:Disconnect()
    end

    table.clear(pushConns)

    restorePush()
end

--==================================================
-- GLOBAL CLEANUP
--==================================================

local function fullCleanup()
    setFly(false)

    setSeatPicker(false)

    cleanupSeat(true)

    stopPushGuard()

    if highlight then
        pcall(highlight.Destroy, highlight)
        highlight = nil
    end

    if seatStateConnection then
        seatStateConnection:Disconnect()
        seatStateConnection = nil
    end

    CAS:UnbindAction(SPACE_ACTION)

    for _, c in ipairs(connections) do
        pcall(c.Disconnect, c)
    end

    table.clear(connections)

    removeFlyPhysics()

    if savedReplicationFocus then
        pcall(function()
            LP.ReplicationFocus = previousReplicationFocus
        end)
    end

    if gui and gui.Parent then
        gui:Destroy()
    end

    for _, name in ipairs(CLEANUP_NAMES) do
        ENV[name] = nil
    end
end

for _, name in ipairs(CLEANUP_NAMES) do
    ENV[name] = fullCleanup
end

--==================================================
-- START
--==================================================

updateGUI()

print("[FlySeat] Loaded")
