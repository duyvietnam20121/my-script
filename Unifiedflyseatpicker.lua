-- Unified Fly + Seat Picker

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

-- Fly
local speed = 50
local minSpeed = 10
local maxSpeed = 250
local speedStep = 10

-- Seated speed
local SEATED_SPEED_CAP = 80

-- Upright
local UPRIGHT_RESPONSIVENESS = 65
local UPRIGHT_MAX_TORQUE = 1000000000
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

local highlight = nil

local root = nil
local humanoid = nil

local attachment = nil
local velocity = nil
local orientation = nil

local oldAutoRotate = nil
local lastYaw = 0

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

local SPACE_ACTION = "UnifiedSeatPicker_BlockSpace"

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

-- Resolved once; stepped inside the single Heartbeat loop below
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

local function createButton(name, text, size, position, parent)
    local b = Instance.new("TextButton")

    b.Name = name
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

gui.Name = "UnifiedFlySeatGui"
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

main.Name = "Main"
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
    "FLY + SEAT PICKER",
    Enum.Font.GothamBold, 12, WHITE, main
)

-- FLY BUTTON
local flyButton = createButton(
    "FlyToggle",
    "FLY: OFF",
    UDim2.new(1, -16, 0, 31),
    UDim2.fromOffset(8, 32),
    main
)

-- SPEED
local minus = createButton(
    "SpeedMinus",
    "-",
    UDim2.fromOffset(42, 27),
    UDim2.fromOffset(8, 69),
    main
)

local speedLabel = createLabel(
    UDim2.fromOffset(82, 27), UDim2.fromOffset(54, 69),
    "50",
    Enum.Font.GothamBold, 14, WHITE, main
)

local plus = createButton(
    "SpeedPlus",
    "+",
    UDim2.fromOffset(42, 27),
    UDim2.fromOffset(140, 69),
    main
)

-- SEAT PICKER
local seatButton = createButton(
    "SeatToggle",
    "SEAT PICKER: ON",
    UDim2.new(1, -16, 0, 31),
    UDim2.fromOffset(8, 103),
    main
)

-- EXIT SEAT
local exitButton = createButton(
    "ExitSeat",
    "EXIT SEAT",
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
    flyButton.Text = flying and "FLY: ON" or "FLY: OFF"
    flyButton.BackgroundColor3 = flying and COLOR_ON or COLOR_OFF

    seatButton.Text = seatPickerEnabled
        and "SEAT PICKER: ON"
        or "SEAT PICKER: OFF"
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

        highlight.Name = "SeatPickerHighlight"

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

    local char = getCharacter()

    if char then
        for _, obj in ipairs(char:GetDescendants()) do
            if obj.Name == "SeatPickerCharWeld" then
                pcall(obj.Destroy, obj)
            end
        end
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

            cleanupSeat(false)
        end)
    end)
end

--==================================================
-- ORIGINAL SEAT LOGIC v3
--==================================================

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

    if not part or not part.Parent or part.Anchored then
        return
    end

    if part:IsDescendantOf(char) then
        return
    end

    -- Prevent sitting on another real game seat
    if hum.SeatPart and hum.SeatPart ~= currentSeat then
        warn("[Unified] Stand up from the current game seat first.")
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

    seat.Name = "SelectedSeat"
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

            weld.Name = "SeatPickerWeld"
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

        print("[Unified] Sit successful (Seat:Sit)")
        return
    end

    -- METHOD 2: ORIGINAL WELD FALLBACK
    print("[Unified] Seat:Sit failed -> Weld fallback")

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

        frozenSeat.Name = "SelectedSeat"
        frozenSeat.Size = Vector3.new(2, 0.2, 2)

        frozenSeat.CFrame = seatCFrame

        frozenSeat.Anchored = true
        frozenSeat.Transparency = 1

        frozenSeat.CanCollide = false
        frozenSeat.CanTouch = false
        frozenSeat.CanQuery = false

        frozenSeat.Parent = Workspace

        local partWeld = Instance.new("WeldConstraint")

        partWeld.Name = "SeatPickerWeld"
        partWeld.Part0 = frozenSeat
        partWeld.Part1 = part

        partWeld.Parent = frozenSeat

        currentSeat = frozenSeat

        local charWeld = Instance.new("Weld")

        charWeld.Name = "SeatPickerCharWeld"
        charWeld.Part0 = frozenSeat
        charWeld.Part1 = rootPart

        charWeld.C0 = CFrame.new(0, 2.5, 0)
        charWeld.Parent = rootPart

        setupStandUpListener(hum, frozenSeat)

    else
        local weld = Instance.new("Weld")

        weld.Name = "SeatPickerWeld"
        weld.Part0 = part
        weld.Part1 = rootPart

        weld.C0 = CFrame.new(0, part.Size.Y / 2 + 2.5, 0)

        weld.Parent = rootPart

        currentSeat = weld

        setupStandUpListener(hum, weld)
    end

    clearHighlight()

    print("[Unified] Sit successful (Weld)")
end

--==================================================
-- EXIT SEAT BUTTON
--==================================================

local function exitSeat()
    -- Removes custom seat/welds and resets the humanoid
    cleanupSeat(true)

    print("[Unified] Exit seat requested")
end

--==================================================
-- SEAT PICKER TOGGLE
--==================================================

local function setSeatPicker(state)
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

--==================================================
-- FLY PHYSICS CLEANUP
--==================================================

local function removeFlyPhysics()
    if velocity then pcall(velocity.Destroy, velocity) end
    if orientation then pcall(orientation.Destroy, orientation) end
    if attachment then pcall(attachment.Destroy, attachment) end

    velocity = nil
    orientation = nil
    attachment = nil

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
    attachment.Name = "UnifiedFlyAttachment"
    attachment.Parent = root

    velocity = Instance.new("LinearVelocity")
    velocity.Name = "UnifiedFlyVelocity"

    velocity.Attachment0 = attachment
    velocity.RelativeTo = Enum.ActuatorRelativeTo.World

    velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector

    velocity.ForceLimitsEnabled = false
    velocity.VectorVelocity = VEC_ZERO

    velocity.Parent = root

    orientation = Instance.new("AlignOrientation")
    orientation.Name = "UnifiedFlyOrientation"

    orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment

    orientation.Attachment0 = attachment

    orientation.RigidityEnabled = false
    orientation.Responsiveness = UPRIGHT_RESPONSIVENESS
    orientation.MaxTorque = UPRIGHT_MAX_TORQUE
    orientation.MaxAngularVelocity = UPRIGHT_MAX_ANGULAR

    orientation.Enabled = true
    orientation.Parent = root

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

    else
        local wasSeated = isSeated()

        flying = false
        clearKeys()

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

    if text ~= lastStatus then
        lastStatus = text
        statusLabel.Text = text
        statusLabel.TextColor3 = color
    end
end

--==================================================
-- SINGLE HEARTBEAT LOOP (network + status + fly)
--==================================================

local statusTimer = 0
local highlightTimer = 0
local simTimer = 0
local comTimer = 0
local stabTimer = 0
local lastSeatedState = nil

local SIM_INTERVAL = 0.25
local COM_INTERVAL = 0.2
local STAB_INTERVAL = 1 / 30
local HIGHLIGHT_INTERVAL = 0.05

-- Camera cached; refreshed only when Workspace.CurrentCamera changes
local camera = Workspace.CurrentCamera

connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
    camera = Workspace.CurrentCamera
end)

connect(RunService.Heartbeat, function(dt)
    -- Simulation radius (executor only)
    if setHidden then
        simTimer += dt

        if simTimer >= SIM_INTERVAL then
            simTimer = 0
            pcall(setHidden, LP, "SimulationRadius", mathHuge)
        end
    end

    -- isSeated() is evaluated at most once per frame
    local seated

    -- Status label (every 0.2s)
    statusTimer += dt

    if statusTimer >= 0.2 then
        statusTimer = 0
        seated = isSeated()
        updateStatus(seated)
    end

    -- Keep the highlight in sync (20 Hz)
    if seatPickerEnabled then
        highlightTimer += dt

        if highlightTimer >= HIGHLIGHT_INTERVAL then
            highlightTimer = 0
            refreshHighlight()
        end
    end

    -- Fly movement
    if not flying then
        return
    end

    if not root or not root.Parent
        or not humanoid or not humanoid.Parent
        or humanoid.Health <= 0 then

        setFly(false)
        return
    end

    if not (velocity and velocity.Parent
        and orientation and orientation.Parent
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

    if seated == nil then
        seated = isSeated()
    end

    -- Re-read center of mass only on seat change or every COM_INTERVAL
    local force = lastSeatedState ~= seated
    lastSeatedState = seated

    comTimer += dt

    if comTimer >= COM_INTERVAL then
        comTimer = 0
        force = true
    end

    local assembly = updateActuatorAssembly(force)

    if not assembly then
        return
    end

    -- Speed control
    local targetVel = direction
        * (seated and mathMin(speed, SEATED_SPEED_CAP) or speed)

    if targetVel ~= lastVel then
        velocity.VectorVelocity = targetVel
        lastVel = targetVel
    end

    -- Keep assembly upright, only yaw is allowed
    if orientation then
        local yaw = getFlatYaw(cf)

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
end)

--==================================================
-- KEYBOARD
--==================================================

local FLY_TOGGLE_KEY = KC.F

local keyMap = {
    [KC.W] = "W",
    [KC.A] = "A",
    [KC.S] = "S",
    [KC.D] = "D",

    [KC.Space] = "Up",
    [KC.LeftShift] = "Down",
    [KC.RightShift] = "Down",
    [KC.LeftControl] = "Down",
    [KC.RightControl] = "Down",
}

connect(UIS.InputBegan, function(input, processed)
    if processed then return end

    -- PC hotkey: toggle fly
    if input.KeyCode == FLY_TOGGLE_KEY then
        setFly(not flying)
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

mobile.Name = "MobileControls"
mobile.Size = UDim2.fromOffset(160, 145)

mobile.Position = UDim2.new(1, -175, 1, -165)

mobile.BackgroundTransparency = 1
mobile.Visible = UIS.TouchEnabled

mobile.Parent = gui

local BUTTON_SIZE = UDim2.fromOffset(48, 42)

local function holdButton(name, text, key, x, y)
    local b = createButton(
        name,
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

holdButton("Forward", "W", "W", 56, 0)
holdButton("Left", "A", "A", 4, 47)
holdButton("Backward", "S", "S", 56, 47)
holdButton("Right", "D", "D", 108, 47)
holdButton("Up", "UP", "Up", 30, 94)
holdButton("Down", "DOWN", "Down", 82, 94)

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
    setFly(false)

    cleanupSeat(false)
    clearHighlight()
end)

--==================================================
-- NEARBY MASSLESS (N parts per second, no whole-map scan)
--==================================================
-- Natural Disaster Survival rebuilds the whole map every round and unanchors
-- parts during disasters, so a global part list / DescendantAdded hook would
-- spike on every map load. Instead a native spatial query around the player
-- finds candidates, and only unanchored, non-massless parts are touched.

local MASSLESS_PER_SECOND = 25   -- set to 50 for a faster rollout
local MASSLESS_RADIUS = 120      -- studs around the player
local MASSLESS_QUERY_MAX = 500   -- hard cap on parts returned per query

local massChanged = setmetatable({}, { __mode = "k" })  -- parts we changed
local massAlive = false

local massParams = OverlapParams.new()
massParams.MaxParts = MASSLESS_QUERY_MAX

local function applyMassless(part)
    -- sethiddenproperty first; plain assignment if the executor rejects it
    if not (setHidden and pcall(setHidden, part, "Massless", true)) then
        pcall(function()
            part.Massless = true
        end)
    end

    massChanged[part] = true
end

local function massBatch()
    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")

    if not hrp then
        return
    end

    local ok, parts = pcall(
        Workspace.GetPartBoundsInRadius,
        Workspace,
        hrp.Position,
        MASSLESS_RADIUS,
        massParams
    )

    if not ok then
        return
    end

    local applied = 0

    for i = 1, #parts do
        local part = parts[i]

        if not part.Anchored and not part.Massless then
            applyMassless(part)
            applied += 1

            if applied >= MASSLESS_PER_SECOND then
                break
            end
        end
    end
end

local function startMassless()
    if massAlive then
        return
    end

    massAlive = true

    task.spawn(function()
        while massAlive do
            massBatch()
            taskWait(1)
        end
    end)
end

-- Restores Massless on the parts this script changed
local function stopMassless()
    massAlive = false

    for part in pairs(massChanged) do
        pcall(function()
            part.Massless = false
        end)
    end

    table.clear(massChanged)
end

--==================================================
-- GLOBAL CLEANUP
--==================================================

local function fullCleanup()
    setFly(false)

    setSeatPicker(false)

    cleanupSeat(true)

    stopMassless()

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

setSeatPicker(true)

updateGUI()
startMassless()

print("[Unified Fly + Seat Picker] Loaded")
