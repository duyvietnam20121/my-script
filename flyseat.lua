--[[
    FlySeat v2: fly + seat picker (Roblox executor script)

    Controls (PC):
        F            toggle fly
        G            toggle Seat Picker (click an unanchored part to sit on it)
        E            exit the picked seat
        = / -        speed up / down
        RightShift   show / hide the panel
        W A S D / Space / Ctrl   move / up / down

    Changes vs v1:
        * Movement input is polled with UIS:IsKeyDown -> no more "stuck keys"
          (e.g. releasing LeftCtrl while RightCtrl is held)
        * Panel is dragged by its title bar only (buttons no longer start a drag)
        * Hotkeys for speed and panel visibility
        * Leaving a seat while flying puts the humanoid back into Physics state
        * sitOnPart split into small helpers (no duplicated "picked" block)
        * `new()` helper removes ~200 lines of Instance boilerplate
        * Drag connection no longer leaks on cleanup
        * Cleanup also runs on CharacterRemoving (not only CharacterAdded)
]]

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

-- Cached globals for hot paths
local mathExp, mathClamp, mathAbs = math.exp, math.clamp, math.abs
local mathMin, mathMax, mathAtan2 = math.min, math.max, math.atan2
local mathHuge = math.huge
local taskWait, taskDelay = task.wait, task.delay
local CFAngles = CFrame.Angles

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
-- UTILITIES
--==================================================

local rng = Random.new()
local NAME_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

--- Random 8-14 character name (a new one for every instance).
local function randomName()
    local len = rng:NextInteger(8, 14)
    local out = table.create(len)

    for i = 1, len do
        local n = rng:NextInteger(1, #NAME_CHARS)
        out[i] = NAME_CHARS:sub(n, n)
    end

    return table.concat(out)
end

--- Creates an instance with a random name. Properties are applied BEFORE
--- parenting (cheaper, and avoids flashes such as an Adornee-less Highlight).
--- @param className string
--- @param props table? property -> value
--- @param parent Instance?
local function new(className, props, parent)
    local inst = Instance.new(className)
    inst.Name = randomName()

    if props then
        for k, v in pairs(props) do
            inst[k] = v
        end
    end

    inst.Parent = parent

    return inst
end

--- Destroys an instance, ignoring nil / already destroyed.
local function destroy(inst)
    if inst then
        pcall(inst.Destroy, inst)
    end
end

--==================================================
-- CONFIG
--==================================================

local CONFIG = {
    -- PC hotkeys
    KEYS = {
        FLY = KC.F,
        SEAT_PICKER = KC.G,
        EXIT_SEAT = KC.E,
        SPEED_UP = KC.Equals,
        SPEED_DOWN = KC.Minus,
        TOGGLE_GUI = KC.RightShift,
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
        SEATED_CAP = 80,  -- max speed while seated on a part
        SMOOTHING = 8,    -- acceleration easing (1/s); 0 = instant
    },

    SEAT = {
        KEEP_SEATED = true,        -- sit back down if the humanoid leaves by itself
        SUSPEND_PICKER = true,     -- pause the Seat Picker while seated
        ROTATE_WITH_CAMERA = true, -- false keeps the heading fixed while seated
        FREEZE_PART = false,       -- keep the seat anchored instead of welding it to the part
    },

    -- Hold the part in place when idle
    HOLD = {
        ENABLED = true,
        DELAY = 0.15,
        RESPONSIVENESS = 100,
        MAX_SPEED = 200,
        RIGID = true,
        SNAP_DISTANCE = 8,  -- studs (0 = off)
    },

    -- Feather-light picked part (density restored on exit)
    LIGHTEN = {
        ENABLED = true,
        TARGET_MASS = 25,
        MIN_DENSITY = 0.01,
        MAX_PARTS = 40,
        UNIFORM = false,
        ANTI_GRAVITY = true,

        -- Other players near you (PUSH.RADIUS) are re-enforced every PUSH.REFRESH
        -- seconds: MIN_DENSITY + Massless, so they can't shove your picked part.
        PLAYERS = {
            ENABLED = true,
            MASSLESS = true,  -- limbs / head stop adding mass (the root part keeps its tiny mass)
        },

        -- Every unanchored part in the whole Workspace gets MIN_DENSITY
        -- (processed in batches so big maps don't freeze; new parts are caught too)
        GLOBAL = {
            ENABLED = true,
            BUDGET = 0.003,          -- seconds of work per frame (bigger = faster, but can drop FPS)
            RESCAN = 2,              -- seconds between re-checks (catches parts that were unanchored later)
            INCLUDE_PLAYERS = true,  -- other players' parts too (your own character is never touched)
        },

        NEARBY = {
            ENABLED = true,
            RADIUS = 40,
            INTERVAL = 1,
            PER_PASS = 25,
            QUERY_MAX = 1000,
            INCLUDE_PLAYERS = true,
        },
    },

    -- Nearby players pass through the picked part (local only)
    PUSH = {
        ENABLED = true,
        RADIUS = 60,
        REFRESH = 0.25,
    },

    -- Seconds between updates
    INTERVALS = {
        STATUS = 0.2,
        HIGHLIGHT = 0.05,
        SIM_RADIUS = 0.1,
        CENTER_OF_MASS = 0.2,
        CENTER_OF_MASS_SEATED = 0.02,
        STABILIZE = 1 / 30,
    },
}

local K = CONFIG.KEYS

local LABELS = {
    FLY_ON = ("FLY [%s]: ON"):format(K.FLY.Name),
    FLY_OFF = ("FLY [%s]: OFF"):format(K.FLY.Name),
    SEAT_ON = ("SEAT PICKER [%s]: ON"):format(K.SEAT_PICKER.Name),
    SEAT_OFF = ("SEAT PICKER [%s]: OFF"):format(K.SEAT_PICKER.Name),
    SEAT_PAUSED = ("SEAT PICKER [%s]: PAUSED"):format(K.SEAT_PICKER.Name),
    EXIT = ("EXIT SEAT [%s]"):format(K.EXIT_SEAT.Name),
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

    for _, obj in ipairs(Workspace:GetChildren()) do
        if STALE[obj.Name] then
            destroy(obj)
        end
    end

    local char = LP.Character

    if char then
        for _, obj in ipairs(char:GetDescendants()) do
            if STALE[obj.Name] then
                destroy(obj)
            end
        end
    end
end

--==================================================
-- SETTINGS (mutable at runtime)
--==================================================

local KEEP_SEATED = CONFIG.SEAT.KEEP_SEATED
local SUSPEND_PICKER = CONFIG.SEAT.SUSPEND_PICKER
local ROTATE_SEATED = CONFIG.SEAT.ROTATE_WITH_CAMERA
local FREEZE_PART = CONFIG.SEAT.FREEZE_PART

local speed = mathClamp(CONFIG.SPEED.DEFAULT, CONFIG.SPEED.MIN, CONFIG.SPEED.MAX)
local SEATED_SPEED_CAP = CONFIG.SPEED.SEATED_CAP

-- Upright / anti spin
local UPRIGHT_RESPONSIVENESS = 100
local UPRIGHT_MAX_TORQUE = mathHuge
local UPRIGHT_MAX_ANGULAR = 120
local NORMAL_DAMPING = 10
local SEATED_DAMPING = 15
local MAX_YAW_RATE = 8

-- GUI colors
local COLOR_ON = Color3.fromRGB(35, 160, 85)
local COLOR_OFF = Color3.fromRGB(38, 38, 48)
local WHITE = Color3.new(1, 1, 1)
local GREY = Color3.fromRGB(180, 180, 190)
local GREEN = Color3.fromRGB(0, 255, 0)

--==================================================
-- STATE
--==================================================

local flying = false
local seatPickerEnabled = false

local currentSeat = nil
local pendingSeat = nil
local charWeldInst = nil
local pickedPart = nil
local startPushGuard, stopPushGuard  -- defined in the anti-push section

local pickerSuspended = false
local suspendPicker, resumePicker  -- defined after setSeatPicker

local highlight = nil

local root = nil
local humanoid = nil

local attachment = nil
local velocity = nil
local orientation = nil
local alignPos = nil
local holding = false
local idleTimer = 0

local oldAutoRotate = nil
local lastYaw = 0
local seatYaw = 0

-- Last values written to the fly constraints (skip redundant writes)
local lastVel = nil
local lastAppliedYaw = nil
local lastAttPos = nil

local connections = {}
local inputConn = nil
local seatStateConnection = nil

local previousReplicationFocus = nil
local savedReplicationFocus = false

-- Mobile on-screen buttons (keyboard is polled, see isActionDown)
local touchKeys = { W = false, A = false, S = false, D = false, Up = false, Down = false }
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

    for k in pairs(touchKeys) do
        touchKeys[k] = false
    end
end

--- True while the action's key (or its mobile button) is held.
--- Polling instead of event flags means a missed InputEnded can never
--- leave a direction "stuck".
local function isActionDown(action)
    if touchKeys[action] then
        return true
    end

    -- Ignore the keyboard while typing in chat / a TextBox
    if UIS:GetFocusedTextBox() then
        return false
    end

    for _, code in ipairs(CONFIG.MOVE_KEYS[action]) do
        if UIS:IsKeyDown(code) then
            return true
        end
    end

    return false
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
-- BLOCK JUMP WHILE SEATED
--==================================================

local SPACE_ACTION = randomName()

-- Space is only sunk (so it can't kick us off the seat); the fly code reads
-- it through UIS:IsKeyDown, which is unaffected by sinking.
CAS:BindActionAtPriority(
    SPACE_ACTION,
    function()
        if isSeated() then
            return Enum.ContextActionResult.Sink
        end

        return Enum.ContextActionResult.Pass
    end,
    false,
    3000,
    KC.Space
)

-- Mobile jump button
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
    return new("UICorner", { CornerRadius = UDim.new(0, radius) }, obj)
end

local function createButton(text, size, position, parent)
    local b = new("TextButton", {
        Text = text,
        Size = size,
        Position = position,
        BackgroundColor3 = COLOR_OFF,
        TextColor3 = WHITE,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        AutoButtonColor = true,
    }, parent)

    addCorner(b, 7)

    return b
end

local function createLabel(size, position, text, font, textSize, color, parent)
    return new("TextLabel", {
        Size = size,
        Position = position,
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = color,
        Font = font,
        TextSize = textSize,
    }, parent)
end

--==================================================
-- MAIN GUI
--==================================================

local gui = new("ScreenGui", { ResetOnSpawn = false, DisplayOrder = 100 })

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

local main = new("Frame", {
    Size = UDim2.fromOffset(190, 224),
    Position = UDim2.new(0, 20, 0.35, 0),
    BackgroundColor3 = Color3.fromRGB(24, 24, 32),
    Active = true,
}, gui)

addCorner(main, 10)

-- Title bar = drag handle
local titleBar = createLabel(
    UDim2.new(1, 0, 0, 27), UDim2.new(),
    "FLYSEAT",
    Enum.Font.GothamBold, 12, WHITE, main
)

titleBar.Active = true

local flyButton = createButton(
    LABELS.FLY_OFF,
    UDim2.new(1, -16, 0, 31),
    UDim2.fromOffset(8, 32),
    main
)

local minus = createButton("-", UDim2.fromOffset(42, 27), UDim2.fromOffset(8, 69), main)

local speedLabel = createLabel(
    UDim2.fromOffset(82, 27), UDim2.fromOffset(54, 69),
    tostring(speed),
    Enum.Font.GothamBold, 14, WHITE, main
)

local plus = createButton("+", UDim2.fromOffset(42, 27), UDim2.fromOffset(140, 69), main)

local seatButton = createButton(
    LABELS.SEAT_OFF,
    UDim2.new(1, -16, 0, 31),
    UDim2.fromOffset(8, 103),
    main
)

local exitButton = createButton(
    LABELS.EXIT,
    UDim2.new(1, -16, 0, 31),
    UDim2.fromOffset(8, 140),
    main
)

exitButton.BackgroundColor3 = Color3.fromRGB(180, 55, 55)

local statusLabel = createLabel(
    UDim2.new(1, -12, 0, 23), UDim2.fromOffset(6, 180),
    "READY",
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

--- Changes the fly speed, clamped to [MIN, MAX].
local function changeSpeed(delta)
    speed = mathClamp(speed + delta, CONFIG.SPEED.MIN, CONFIG.SPEED.MAX)
    updateGUI()
end

--==================================================
-- HIGHLIGHT (single reusable instance)
--==================================================

-- NOTE: a Highlight with no Adornee highlights its PARENT (Workspace = the
-- whole screen), so it is always disabled before the Adornee is cleared.
local function clearHighlight()
    if highlight then
        highlight.Enabled = false
        highlight.Adornee = nil
    end
end

--- Highlights `part` only if it is a valid, unanchored, non-character part.
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

    if not highlight or not highlight.Parent then
        highlight = new("Highlight", {
            FillColor = GREEN,
            FillTransparency = 0.5,
            OutlineColor = GREEN,
            OutlineTransparency = 0,
            Enabled = false,
            Adornee = part,  -- set BEFORE parenting
        }, Workspace)
    end

    if highlight.Adornee ~= part then
        highlight.Adornee = part
    end

    if not highlight.Enabled then
        highlight.Enabled = true
    end
end

--- Re-evaluates what is under the cursor (timer + click, so it never goes
--- stale and also works on touch where Mouse.Move never fires).
local function refreshHighlight()
    if not seatPickerEnabled then
        return
    end

    if currentSeat then
        clearHighlight()
        return
    end

    updateHighlight(Mouse.Target)
end

--==================================================
-- LIGHTEN / ANTI-GRAVITY
--==================================================

-- part -> original CustomPhysicalProperties (false = default)
local lightened = {}
local lightenSeen = setmetatable({}, { __mode = "k" })
local massless = {}  -- other players' parts we set Massless: part -> original value

local antiGen = 0
local antiObjects = {}

local function stopAntiGravity()
    antiGen += 1

    for _, obj in ipairs(antiObjects) do
        destroy(obj)
    end

    table.clear(antiObjects)
end

--- Upward VectorForce equal to the assembly's weight (weightless part).
local function startAntiGravity(part)
    if not CONFIG.LIGHTEN.ANTI_GRAVITY then
        return
    end

    stopAntiGravity()

    local att = new("Attachment", nil, part)

    local force = new("VectorForce", {
        Attachment0 = att,
        RelativeTo = Enum.ActuatorRelativeTo.World,
        ApplyAtCenterOfMass = true,
        Force = VEC_ZERO,
    }, part)

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

-- Workspace-wide lightening job.
--   fresh = parts that just appeared (always handled first)
--   bulk  = initial / periodic scan (drained within a per-frame time budget)
local GL = { gen = 0, conn = nil, extra = {}, fresh = {}, freshHead = 1, bulk = {}, bulkHead = 1 }

local function stopGlobalLighten()
    GL.gen += 1

    if GL.conn then
        GL.conn:Disconnect()
        GL.conn = nil
    end

    for _, c in ipairs(GL.extra) do
        c:Disconnect()
    end

    table.clear(GL.extra)
    table.clear(GL.fresh)
    table.clear(GL.bulk)
    GL.freshHead = 1
    GL.bulkHead = 1
end

local function restoreLightened()
    stopGlobalLighten()

    for part, original in pairs(lightened) do
        pcall(function()
            part.CustomPhysicalProperties = original or nil
        end)
    end

    for part, original in pairs(massless) do
        pcall(function()
            part.Massless = original
        end)
    end

    table.clear(massless)
    table.clear(lightened)
    table.clear(lightenSeen)

    stopAntiGravity()
end

--- Lightens one loose part. Returns true if it changed.
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

--- Keeps one part of ANOTHER player light. Unlike lightenOne it is meant to be
--- called repeatedly (humanoids can reset physics), so it re-checks every time.
--- Everything it changes is undone by restoreLightened().
local function lightenPlayerPart(p)
    local cfg = CONFIG.LIGHTEN

    if p.Anchored then
        return
    end

    local ok, cur = pcall(function()
        return p.CurrentPhysicalProperties
    end)

    if ok and cur.Density > cfg.MIN_DENSITY + 0.0001 then
        if lightened[p] == nil then
            lightened[p] = p.CustomPhysicalProperties or false
        end

        pcall(function()
            p.CustomPhysicalProperties = PhysicalProperties.new(
                cfg.MIN_DENSITY,
                cur.Friction,
                cur.Elasticity,
                cur.FrictionWeight,
                cur.ElasticityWeight
            )
        end)
    end

    -- The root part is the assembly root: Massless has no effect on it
    if cfg.PLAYERS.MASSLESS and p.Name ~= "HumanoidRootPart" and not p.Massless then
        massless[p] = false

        pcall(function()
            p.Massless = true
        end)
    end
end

--- Lightens EVERY unanchored part in Workspace to MIN_DENSITY (0.01).
--- * New parts jump the queue (DescendantAdded -> `fresh`).
--- * A periodic scan (RESCAN) catches parts that were anchored when they
---   appeared and got unanchored later (dropped items, broken welds, ...).
--- * Work is limited by a time budget per frame, so big maps don't freeze.
--- Runs until the seat is released (restoreLightened -> stopGlobalLighten).
local function startGlobalLighten()
    local g = CONFIG.LIGHTEN.GLOBAL

    if not (CONFIG.LIGHTEN.ENABLED and g.ENABLED) then
        return
    end

    stopGlobalLighten()

    local gen = GL.gen
    local cfg = { MIN_DENSITY = CONFIG.LIGHTEN.MIN_DENSITY, UNIFORM = true }

    local function handle(p, char)
        if not p.Parent or p.Anchored then
            return
        end

        local isCharacter = p.Parent:FindFirstChildOfClass("Humanoid") ~= nil
        local isMine = char and p:IsDescendantOf(char)

        if not isMine and (not isCharacter or g.INCLUDE_PLAYERS) then
            lightenOne(p, cfg)
        end
    end

    --- Queues every unanchored, not-yet-lightened part
    local function scan()
        for _, inst in ipairs(Workspace:GetDescendants()) do
            if inst:IsA("BasePart") and not inst.Anchored and not lightenSeen[inst] then
                GL.bulk[#GL.bulk + 1] = inst
            end
        end
    end

    GL.conn = Workspace.DescendantAdded:Connect(function(inst)
        if inst:IsA("BasePart") then
            GL.fresh[#GL.fresh + 1] = inst
        end
    end)

    -- Other players (already here, newly joined, or respawning): their character
    -- is queued several times while it loads, because characters often spawn
    -- anchored / without all parts yet and would otherwise be skipped.
    local RECHECK_DELAYS = { 0, 0.5, 1, 2.5 }

    local function queueCharacter(char)
        task.spawn(function()
            for _, delay in ipairs(RECHECK_DELAYS) do
                if delay > 0 then
                    taskWait(delay)
                end

                if gen ~= GL.gen or not char.Parent then
                    return
                end

                for _, d in ipairs(char:GetDescendants()) do
                    if d:IsA("BasePart") and not lightenSeen[d] then
                        GL.fresh[#GL.fresh + 1] = d
                    end
                end
            end
        end)
    end

    local function watchPlayer(plr)
        if plr == LP then
            return
        end

        GL.extra[#GL.extra + 1] = plr.CharacterAdded:Connect(queueCharacter)

        if plr.Character then
            queueCharacter(plr.Character)
        end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        watchPlayer(plr)
    end

    GL.extra[#GL.extra + 1] = Players.PlayerAdded:Connect(watchPlayer)

    task.spawn(function()
        local nextScan = 0

        while gen == GL.gen do
            local now = os.clock()

            -- Start a new scan only when the previous one is fully drained
            if now >= nextScan and GL.bulkHead > #GL.bulk then
                nextScan = now + g.RESCAN
                scan()
            end

            local deadline = os.clock() + g.BUDGET
            local char = LP.Character

            while GL.freshHead <= #GL.fresh and os.clock() < deadline do
                local p = GL.fresh[GL.freshHead]
                GL.freshHead += 1
                handle(p, char)
            end

            while GL.bulkHead <= #GL.bulk and os.clock() < deadline do
                local p = GL.bulk[GL.bulkHead]
                GL.bulkHead += 1
                handle(p, char)
            end

            -- Drained: reset so the arrays don't grow forever
            if GL.freshHead > #GL.fresh then
                table.clear(GL.fresh)
                GL.freshHead = 1
            end

            if GL.bulkHead > #GL.bulk then
                table.clear(GL.bulk)
                GL.bulkHead = 1
            end

            taskWait()
        end
    end)
end

--- The picked part and the parts welded to it (never characters).
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

    startAntiGravity(part)
end

local nearbyParams = OverlapParams.new()
nearbyParams.MaxParts = CONFIG.LIGHTEN.NEARBY.QUERY_MAX

--- Every loose part within NEARBY.RADIUS studs (never your own character).
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

--==================================================
-- SEAT CLEANUP
--==================================================

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

        destroy(oldSeat)
    end

    if tempSeat and tempSeat ~= oldSeat then
        destroy(tempSeat)
    end

    restoreLightened()

    pickedPart = nil

    if stopPushGuard then
        stopPushGuard()
    end

    if charWeldInst then
        destroy(charWeldInst)
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
-- SEAT LOGIC
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
--- @param token number         token captured when the operation started
--- @param t number             seconds to wait
--- @param resetOnCancel boolean? undo partial work if the picker was disabled
--- @return boolean             true = keep going, false = cancelled
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

--- Invisible, non-interactive seat part placed under the character.
local function createSeatPart(className, cframe)
    return new(className, {
        Size = Vector3.new(2, 0.2, 2),
        CFrame = cframe,
        Anchored = true,
        Transparency = 1,
        CanCollide = false,
        CanTouch = false,
        CanQuery = false,
        Massless = true,
    }, Workspace)
end

--- Common bookkeeping once a pick has succeeded.
--- @param obj Instance the seat part / weld that now holds the character
local function onPicked(hum, part, obj)
    currentSeat = obj
    pendingSeat = nil

    setupStandUpListener(hum, obj)
    clearHighlight()

    if SUSPEND_PICKER then
        suspendPicker()
    end

    pickedPart = part
    lightenPart(part)
    startGlobalLighten()
    startPushGuard()
end

--- Checks that `part` can be picked; notifies the player when it can't.
local function canPick(part, char, hum)
    if not part or not part.Parent then
        return false
    end

    if part.Anchored then
        notify("ANCHORED - PICK AN UNANCHORED PART")
        return false
    end

    if part:IsDescendantOf(char) then
        return false
    end

    -- Prevent sitting on another real game seat
    if hum.SeatPart and hum.SeatPart ~= currentSeat then
        notify("STAND UP FROM THE GAME SEAT FIRST")
        return false
    end

    return true
end

--- Method 2: no Seat. Weld the character to the part and force the Seated state.
local function weldFallback(token, part, char, hum, rootPart, sitPos, seatCFrame)
    print("[FlySeat] Seat:Sit failed -> Weld fallback")

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

    local holder

    if FREEZE_PART then
        local frozenSeat = createSeatPart("Part", seatCFrame)

        new("WeldConstraint", { Part0 = frozenSeat, Part1 = part }, frozenSeat)

        charWeldInst = new("Weld", {
            Part0 = frozenSeat,
            Part1 = rootPart,
            C0 = CFrame.new(0, 2.5, 0),
        }, rootPart)

        holder = frozenSeat
    else
        holder = new("Weld", {
            Part0 = part,
            Part1 = rootPart,
            C0 = CFrame.new(0, part.Size.Y / 2 + 2.5, 0),
        }, rootPart)
    end

    onPicked(hum, part, holder)

    print("[FlySeat] Sit successful (Weld)")
end

local function sitOnPart(part)
    if not seatPickerEnabled then return end

    local char = getCharacter()
    if not char then return end

    local hum = char:FindFirstChildOfClass("Humanoid")
    local rootPart = char:FindFirstChild("HumanoidRootPart")

    if not (hum and rootPart) then return end
    if not canPick(part, char, hum) then return end

    -- A new attempt supersedes (cancels) any older one still waiting
    sitToken += 1
    local token = sitToken

    cleanupSeat(false)

    pcall(function()
        hum.Sit = false

        hum:ChangeState(HState.GettingUp)
    end)

    if not sitSleep(token, 0.25) or not part.Parent then
        return
    end

    -- Too far away: teleport next to the part first
    if (part.Position - rootPart.Position).Magnitude > 50 then
        pcall(function()
            char:PivotTo(part.CFrame * CFrame.new(0, part.Size.Y / 2 + 5, 0))
        end)

        if not sitSleep(token, 0.15) then
            return
        end
    end

    if token ~= sitToken or not part.Parent then
        return
    end

    local sitPos = part.CFrame * CFrame.new(0, part.Size.Y / 2 + 2.5, 0)
    local seatCFrame = sitPos - Vector3.new(0, 2.5, 0)

    -- METHOD 1: Seat:Sit
    local seat = createSeatPart("Seat", seatCFrame)
    pendingSeat = seat

    pcall(seat.Sit, seat, hum)

    if not sitSleep(token, 0.15, true) then
        return
    end

    if hum.SeatPart == seat then
        if not FREEZE_PART then
            new("WeldConstraint", { Part0 = seat, Part1 = part }, seat)

            if not sitSleep(token, 0.05, true) then
                return
            end

            seat.Anchored = false
        end

        onPicked(hum, part, seat)

        print("[FlySeat] Sit successful (Seat:Sit)")
        return
    end

    -- METHOD 2
    destroy(seat)
    pendingSeat = nil

    weldFallback(token, part, char, hum, rootPart, sitPos, seatCFrame)
end

--==================================================
-- EXIT SEAT
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

        -- Cancel only an unfinished seat operation; never kick the player
        -- out of the current seat.
        if pendingSeat then
            destroy(pendingSeat)
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
-- FLY PHYSICS
--==================================================

local function removeFlyPhysics()
    destroy(velocity)
    destroy(orientation)
    destroy(alignPos)
    destroy(attachment)

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

--- Heading (yaw) of a CFrame, ignoring near-vertical look vectors.
local function getFlatYaw(cf)
    local look = cf.LookVector

    if look.X * look.X + look.Z * look.Z > 0.000001 then
        lastYaw = mathAtan2(-look.X, -look.Z)
    end

    return lastYaw
end

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
    attachment = new("Attachment", nil, root)

    velocity = new("LinearVelocity", {
        Attachment0 = attachment,
        RelativeTo = Enum.ActuatorRelativeTo.World,
        VelocityConstraintMode = Enum.VelocityConstraintMode.Vector,
        ForceLimitsEnabled = false,
        VectorVelocity = VEC_ZERO,
    }, root)

    orientation = new("AlignOrientation", {
        Mode = Enum.OrientationAlignmentMode.OneAttachment,
        Attachment0 = attachment,
        RigidityEnabled = false,
        Responsiveness = UPRIGHT_RESPONSIVENESS,
        MaxTorque = UPRIGHT_MAX_TORQUE,
        MaxAngularVelocity = UPRIGHT_MAX_ANGULAR,
        Enabled = true,
    }, root)

    alignPos = new("AlignPosition", {
        Mode = Enum.PositionAlignmentMode.OneAttachment,
        Attachment0 = attachment,
        RigidityEnabled = CONFIG.HOLD.RIGID,
        MaxForce = mathHuge,
        MaxVelocity = CONFIG.HOLD.MAX_SPEED,
        Responsiveness = CONFIG.HOLD.RESPONSIVENESS,
        Enabled = false,
    }, root)

    lastYaw = getFlatYaw(root.CFrame)

    lastVel = VEC_ZERO
    lastAppliedYaw = nil
    lastAttPos = nil

    updateActuatorAssembly(true)
end

--- Removes pitch/roll spin, keeps (clamped) yaw.
local function stabilizeAssembly(assembly, seated, dt)
    if not assembly or not assembly.Parent then
        return
    end

    local angular = assembly.AssemblyAngularVelocity
    local factor = mathExp(-(seated and SEATED_DAMPING or NORMAL_DAMPING) * dt)

    local x = angular.X * factor
    local z = angular.Z * factor
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
local smoothVel = VEC_ZERO

local INT = CONFIG.INTERVALS
local STATUS_INTERVAL = INT.STATUS
local SIM_INTERVAL = INT.SIM_RADIUS
local COM_INTERVAL = INT.CENTER_OF_MASS
local COM_INTERVAL_SEATED = INT.CENTER_OF_MASS_SEATED
local STAB_INTERVAL = INT.STABILIZE
local HIGHLIGHT_INTERVAL = INT.HIGHLIGHT
local SPEED_SMOOTHING = CONFIG.SPEED.SMOOTHING
local HOLD_ENABLED = CONFIG.HOLD.ENABLED
local HOLD_DELAY = CONFIG.HOLD.DELAY
local HOLD_SNAP = CONFIG.HOLD.SNAP_DISTANCE

-- The fly loop is connected only while fly is ON
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
            humanoid.AutoRotate = oldAutoRotate ~= false

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

local camera = Workspace.CurrentCamera

connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
    camera = Workspace.CurrentCamera
end)

-- Light UI loop: status text, seat-picker highlight, nearby lightening
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

--- Reads the movement keys and returns the (unnormalized) world direction.
local function readDirection(cf)
    local direction = VEC_ZERO

    if isActionDown("W") then direction += cf.LookVector end
    if isActionDown("S") then direction -= cf.LookVector end
    if isActionDown("A") then direction -= cf.RightVector end
    if isActionDown("D") then direction += cf.RightVector end
    if isActionDown("Up") then direction += VEC_Y end
    if isActionDown("Down") then direction -= VEC_Y end

    if direction.Magnitude > 1 then
        direction = direction.Unit
    end

    return direction
end

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
    local direction = readDirection(cf)

    local seated = isSeated()

    -- Re-read center of mass only on seat change or every COM_INTERVAL
    local force = lastSeatedState ~= seated

    -- Heading is captured the moment we become seated
    if seated and not lastSeatedState then
        local look = root.CFrame.LookVector

        if look.X * look.X + look.Z * look.Z > 0.000001 then
            seatYaw = mathAtan2(-look.X, -look.Z)
        end
    end

    -- Left the seat while flying: the exit puts the humanoid in GettingUp,
    -- so switch it back to Physics or it fights the fly constraints.
    if lastSeatedState and not seated then
        pcall(humanoid.ChangeState, humanoid, HState.Physics)
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

    -- Eased speed: abrupt velocity jumps would jerk riders on the part
    local inputVel = direction * (seated and mathMin(speed, SEATED_SPEED_CAP) or speed)
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
    -- stopped (a velocity lock alone lets repeated pushes accumulate as drift)
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

    -- Keep the assembly upright; only yaw is allowed
    local yaw = getFlatYaw(cf)

    if seated and not ROTATE_SEATED then
        yaw = seatYaw
    end

    if yaw ~= lastAppliedYaw then
        orientation.CFrame = CFAngles(0, yaw, 0)
        lastAppliedYaw = yaw
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
-- KEYBOARD (hotkeys only; movement is polled)
--==================================================

connect(UIS.InputBegan, function(input, processed)
    if processed then return end

    local code = input.KeyCode

    if code == K.FLY then
        setFly(not flying)
    elseif code == K.SEAT_PICKER then
        setSeatPicker(not seatPickerEnabled)
    elseif code == K.EXIT_SEAT then
        if currentSeat or pendingSeat or isSeated() then
            exitSeat()
        end
    elseif code == K.SPEED_UP then
        changeSpeed(CONFIG.SPEED.STEP)
    elseif code == K.SPEED_DOWN then
        changeSpeed(-CONFIG.SPEED.STEP)
    elseif code == K.TOGGLE_GUI then
        main.Visible = not main.Visible
    end
end)

connect(UIS.InputEnded, function(input)
    local action = heldInputs[input]

    if action then
        touchKeys[action] = false
        heldInputs[input] = nil
    end
end)

connect(UIS.WindowFocusReleased, clearKeys)

--==================================================
-- MOBILE CONTROLS
--==================================================

do
    local mobile = new("Frame", {
        Size = UDim2.fromOffset(160, 145),
        Position = UDim2.new(1, -175, 1, -165),
        BackgroundTransparency = 1,
        Visible = UIS.TouchEnabled,
    }, gui)

    local BUTTON_SIZE = UDim2.fromOffset(48, 42)

    local function holdButton(text, action, x, y)
        local b = createButton(text, BUTTON_SIZE, UDim2.fromOffset(x, y), mobile)

        connect(b.InputBegan, function(input)
            local t = input.UserInputType

            if t == UIT.Touch or t == UIT.MouseButton1 then
                touchKeys[action] = true
                heldInputs[input] = action
            end
        end)
    end

    holdButton("W", "W", 56, 0)
    holdButton("A", "A", 4, 47)
    holdButton("S", "S", 56, 47)
    holdButton("D", "D", 108, 47)
    holdButton("UP", "Up", 30, 94)
    holdButton("DOWN", "Down", 82, 94)
end


--==================================================
-- CUSTOM DRAG (title bar only)
--==================================================

local stopDrag  -- assigned inside the block below

do
    local dragInput, dragStart, startPos, moveConn

    function stopDrag()
        dragInput = nil

        if moveConn then
            moveConn:Disconnect()
            moveConn = nil
        end
    end

    connect(titleBar.InputBegan, function(input)
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
            if changed.UserInputType ~= UIT.MouseMovement and changed ~= dragInput then
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
end

--==================================================
-- GUI BUTTON EVENTS
--==================================================

connect(flyButton.Activated, function() setFly(not flying) end)
connect(seatButton.Activated, function() setSeatPicker(not seatPickerEnabled) end)
connect(exitButton.Activated, exitSeat)
connect(minus.Activated, function() changeSpeed(-CONFIG.SPEED.STEP) end)
connect(plus.Activated, function() changeSpeed(CONFIG.SPEED.STEP) end)

--==================================================
-- RESPAWN
--==================================================

local function resetForCharacter()
    sitToken += 1

    setFly(false)

    cleanupSeat(false)
    clearHighlight()
end

-- Before the old character is removed (state is still valid) and after the new one spawns
connect(LP.CharacterRemoving, resetForCharacter)
connect(LP.CharacterAdded, resetForCharacter)

--==================================================
-- ANTI-PUSH (runs while a part is picked)
--==================================================
-- Two layers, both local to this client's simulation:
--  1. NoCollisionConstraint between nearby players' main parts and the picked
--     part. Humanoids never touch these, so they hold.
--  2. CanCollide = false on those parts every Stepped and Heartbeat, because
--     Humanoids re-enable collision on their torso / head / root.

do
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
    local pushChanged = setmetatable({}, { __mode = "k" })  -- parts we made non-collidable
    local pushPairs = {}   -- their part -> NoCollisionConstraint
    local pushTimer = 0
    local pushConns = {}

    local function refreshPushTargets()
        table.clear(pushTargets)

        -- Drop constraints whose parts are gone
        for part, constraint in pairs(pushPairs) do
            if not part.Parent or not constraint.Parent then
                destroy(constraint)
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
                    if CONFIG.LIGHTEN.ENABLED and CONFIG.LIGHTEN.PLAYERS.ENABLED and obj:IsA("BasePart") then
                        lightenPlayerPart(obj)
                    end

                    if obj:IsA("BasePart") and (obj.CanCollide or PUSH_KEY_PARTS[obj.Name]) then
                        pushTargets[#pushTargets + 1] = obj

                        -- Layer 1: a constraint against the picked part
                        if pickedPart and pickedPart.Parent
                            and PUSH_KEY_PARTS[obj.Name]
                            and not pushPairs[obj]
                            and created < 20 then

                            local ok, constraint = pcall(new, "NoCollisionConstraint", {
                                Part0 = obj,
                                Part1 = pickedPart,
                            }, pickedPart)

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
            destroy(constraint)
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
end

--==================================================
-- GLOBAL CLEANUP
--==================================================

local function fullCleanup()
    setFly(false)
    setSeatPicker(false)
    cleanupSeat(true)
    stopPushGuard()
    stopDrag()

    destroy(highlight)
    highlight = nil

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

    destroy(gui)

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
