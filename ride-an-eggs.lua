--[[
╔══════════════════════════════════════════════════════════════════╗
║                 RENDERED EGGS ESP + FLY                          ║
║                                                                  ║
║ • ESP all Models inside workspace.RenderedEggs                   ║
║ • Show name + distance at any range                              ║
║ • Group Eggs by name                                             ║
║ • Collapse / expand groups                                       ║
║ • Global ESP ON/OFF                                              ║
║ • Rarity-based ESP filter                                        ║
║ • Search Eggs                                                    ║
║ • Fly to Egg using pathfinding, then return to My Plot           ║
║ • Draggable and resizable menu                                   ║
║ • Newly spawned Eggs are detected automatically                  ║
║ • Automatically find the LocalPlayer plot using Data.Owner       ║
║ • workspace.Plots is scanned at most 2 times                     ║
║ • Configurable Fly Speed 100-500                                 ║
║ • No script-side teleport distance limit                         ║
╚══════════════════════════════════════════════════════════════════╝
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local RenderedEggs = workspace:FindFirstChild("RenderedEggs")
local Plots = workspace:FindFirstChild("Plots")

if not RenderedEggs then
    warn("[Egg ESP] workspace.RenderedEggs was not found")
    return
end

if not Plots then
    warn("[Egg ESP] workspace.Plots was not found")
end


--==============================================================
-- SETTINGS
--==============================================================

local UPDATE_RATE = 0.20

-- Actual height above the object
local HEIGHT_OFFSET = 10

local SHOW_HIGHLIGHT = true
local ESPDisplayMode = "Name + Rarity" -- Name / Rarity / Name + Rarity
local SUPER_OPTIMIZE = false
local setSuperOptimization
local refreshESPDisplay
local applySuperOptimization

-- Fly settings
local FlySpeed = 250
local MIN_FLY_SPEED = 100
local MAX_FLY_SPEED = 500
local FlyHeight = 10
local FlyToPlotAfterEgg = true

-- Auto Farm settings
local AutoFarmEnabled = false
local AutoFarmMode = "TP" -- TP / Fly
local AutoFarmTargetAll = true
local AutoFarmTargets = {}
local AutoFarmBusy = false
local AutoFarmToken = 0
local AutoFarmDelay = 0.12
local runAutoFarm = nil
--==============================================================
-- MANUAL RARITY CONFIG
--==============================================================
-- Thứ tự từ CAO NHẤT -> THẤP NHẤT.
-- Chỉ cần sửa bảng này, không cần workspace.EggSpawns.
-- Order nhỏ hơn = nằm cao hơn trong GUI.

local RARITY_CONFIG = {
    {
        Name = "Etheral",
        Order = 1,
        Color = Color3.fromRGB(170, 170, 255),
        Eggs = {
            "BlackHole Egg",
            "Solaris Egg",
            "Cherub Egg",
            "Volcanic Egg"
        }
    },
    {
        Name = "Divine",
        Order = 2,
        Color = Color3.fromRGB(95, 190, 255),
        Eggs = {
            "Aurora Egg",
            "Galaxy Egg",
            "Bloom Egg"
        }
    },
    {
        Name = "Mythical",
        Order = 3,
        Color = Color3.fromRGB(255, 170, 255),
        Eggs = {
            "Diamond Egg",
            "Crystal Egg",
            "Skull Egg",
            "Asteroid Egg",
            "Dominus Egg",
            "Flaming Egg",
            "Sinister Egg",
            "Soul Egg",
            "Tidal Egg"
        }
    },
    {
        Name = "Legendary",
        Order = 4,
        Color = Color3.fromRGB(255, 170, 0),
        Eggs = {
            "Glass Egg",
            "Golden Egg"
        }
    },
    {
        Name = "Epic",
        Order = 5,
        Color = Color3.fromRGB(170, 85, 255),
        Eggs = {
            "Mushroom Egg",
            "Flower Egg",
            "Slime Egg",
            "Ice Egg"
        }
    },
    {
        Name = "Rare",
        Order = 6,
        Color = Color3.fromRGB(0, 170, 255),
        Eggs = {
            "Cracked Egg",
            "Easter Egg",
            "Stone Egg",
            "Leaf Egg"
        }
    },
    {
        Name = "Common",
        Order = 7,
        Color = Color3.fromRGB(173, 173, 173),
        Eggs = {
            "White Egg",
            "Brown Egg"
        }
    }
}

local RarityByName = {}
local RarityByEggName = {}

for _, info in ipairs(RARITY_CONFIG) do
    RarityByName[string.lower(info.Name)] = info

    for _, eggName in ipairs(info.Eggs or {}) do
        RarityByEggName[string.lower(tostring(eggName))] = info
    end
end

local SelectedRarities = {}
for _, rarityInfo in ipairs(RARITY_CONFIG) do
    SelectedRarities[string.lower(rarityInfo.Name)] = true
end

local function getManualRarity(name)
    if not name then
        return nil
    end

    local key = string.lower(tostring(name))

    -- Ưu tiên tên trứng đã nhập chính xác.
    local exactEgg = RarityByEggName[key]
    if exactEgg then
        return exactEgg
    end

    -- Cho phép tên model có thêm hậu tố/prefix nhưng vẫn khớp tên trứng.
    for eggName, info in pairs(RarityByEggName) do
        if string.find(key, eggName, 1, true) then
            return info
        end
    end

    return nil
end


--==============================================================
-- STATE
--==============================================================

local Running = true
local GlobalESPEnabled = true

local ESPs = {}
local EggEntries = {}
local EggGroups = {}
local Connections = {}

local Character = nil
local RootPart = nil

local PlotScanCount = 0
local CachedMyPlot = nil
local CachedBaseplate = nil

local MAX_PLOT_SCANS = 2

local updateSearch = nil
local getEggTopCFrame = nil
local safeTeleport = nil
local flyToTarget = nil
local getMyPlotBaseplate = nil
local getBaseplateTopCFrame = nil
local FlyBusy = false
local FlyCancelToken = 0


--==============================================================
-- UTILITY
--==============================================================

local function isFiniteNumber(value)
    return typeof(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end


local function isValidPosition(position)
    if typeof(position) ~= "Vector3" then
        return false
    end

    return isFiniteNumber(position.X)
        and isFiniteNumber(position.Y)
        and isFiniteNumber(position.Z)
end


local function getCharacter()
    Character = LocalPlayer.Character

    if not Character then
        RootPart = nil
        return nil
    end

    RootPart =
        Character:FindFirstChild("HumanoidRootPart")
        or Character:FindFirstChild("UpperTorso")
        or Character:FindFirstChild("Torso")

    return Character
end


getCharacter()


--==============================================================
-- CHARACTER
--==============================================================

Connections.CharacterAdded =
    LocalPlayer.CharacterAdded:Connect(function(character)

        Character = character

        RootPart =
            character:WaitForChild(
                "HumanoidRootPart",
                10
            )

    end)


--==============================================================
-- FIND ROOT PART
--==============================================================

local function getRootPart(model)

    if not model
        or not model:IsA("Model") then
        return nil
    end

    if model.PrimaryPart
        and model.PrimaryPart:IsA("BasePart") then

        return model.PrimaryPart
    end

    local root =
        model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("RootPart")
        or model:FindFirstChild("Handle")

    if root
        and root:IsA("BasePart") then

        return root
    end

    return model:FindFirstChildWhichIsA(
        "BasePart",
        true
    )
end


--==============================================================
-- GUI
--==============================================================

local ScreenGui =
    Instance.new("ScreenGui")

ScreenGui.Name =
    "RenderedEggESP"

ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior =
    Enum.ZIndexBehavior.Sibling

ScreenGui.Parent = PlayerGui


--==============================================================
-- MAIN
--==============================================================

local Main =
    Instance.new("Frame")

Main.Name = "Main"

Main.Size =
    UDim2.new(
        0,
        430,
        0,
        560
    )

Main.AnchorPoint =
    Vector2.new(
        0.5,
        0.5
    )

Main.Position =
    UDim2.new(
        0.5,
        0,
        0.5,
        0
    )

Main.BackgroundColor3 =
    Color3.fromRGB(
        22,
        23,
        30
    )

Main.BorderSizePixel = 0
Main.ClipsDescendants = true

Main.Parent = ScreenGui

local MainExpandedSize = Main.Size
local MainMinimized = false
local MINIMIZED_HEIGHT = 56
local MIN_MENU_WIDTH = 430
local MIN_MENU_HEIGHT = 400
local MAX_MENU_WIDTH = 640
local MAX_MENU_HEIGHT = 760

-- UI SCALE
local MainScale = Instance.new("UIScale")
MainScale.Scale = 0.9
MainScale.Parent = Main


local function updateMainScale()
    local camera = workspace.CurrentCamera

    if not camera then
        return
    end

    local viewport = camera.ViewportSize
    local baseWidth = math.max(Main.Size.X.Offset, 1)
    local baseHeight = math.max(Main.Size.Y.Offset, 1)

    -- Scale the whole GUI to fit the current device while keeping its aspect ratio.
    -- This also works when the player rotates between portrait and landscape.
    local availableWidth = math.max(viewport.X - 20, 1)
    local availableHeight = math.max(viewport.Y - 20, 1)
    local scale = math.min(availableWidth / baseWidth, availableHeight / baseHeight, 0.9)

    -- Prevent the GUI from becoming unusably tiny on small screens.
    MainScale.Scale = math.clamp(scale, 0.40, 0.90)
end


updateMainScale()

if workspace.CurrentCamera then
    Connections.ViewportSize =
        workspace.CurrentCamera:GetPropertyChangedSignal(
            "ViewportSize"
        ):Connect(updateMainScale)
end


local MainCorner =
    Instance.new("UICorner")

MainCorner.CornerRadius =
    UDim.new(0, 14)

MainCorner.Parent = Main


local MainStroke =
    Instance.new("UIStroke")

MainStroke.Color =
    Color3.fromRGB(
        75,
        78,
        100
    )

MainStroke.Thickness = 1.5
MainStroke.Transparency = 0.2

MainStroke.Parent = Main


local ResizeHandle =
    Instance.new("TextButton")

ResizeHandle.Size =
    UDim2.new(
        0,
        32,
        0,
        32
    )

ResizeHandle.AnchorPoint =
    Vector2.new(1, 1)

ResizeHandle.Position =
    UDim2.new(1, -6, 1, -6)

ResizeHandle.BackgroundColor3 =
    Color3.fromRGB(
        62,
        64,
        82
    )

ResizeHandle.Text =
    ">"

ResizeHandle.TextColor3 =
    Color3.fromRGB(
        240,
        240,
        248
    )

ResizeHandle.Font =
    Enum.Font.GothamBold

ResizeHandle.TextSize = 16
ResizeHandle.ZIndex = 5

ResizeHandle.Parent = Main


local ResizeCorner =
    Instance.new("UICorner")

ResizeCorner.CornerRadius =
    UDim.new(0, 8)

ResizeCorner.Parent = ResizeHandle


--==============================================================
-- TOP BAR
--==============================================================

local TopBar =
    Instance.new("Frame")

TopBar.Size =
    UDim2.new(
        1,
        0,
        0,
        56
    )

TopBar.BackgroundColor3 =
    Color3.fromRGB(
        35,
        36,
        48
    )

TopBar.BorderSizePixel = 0
TopBar.ClipsDescendants = true

TopBar.Parent = Main


local TopCorner =
    Instance.new("UICorner")

TopCorner.CornerRadius =
    UDim.new(0, 14)

TopCorner.Parent = TopBar


local Accent =
    Instance.new("Frame")

Accent.Size =
    UDim2.new(
        0,
        5,
        1,
        -18
    )

Accent.Position =
    UDim2.new(
        0,
        9,
        0,
        9
    )

Accent.BackgroundColor3 =
    Color3.fromRGB(
        110,
        130,
        255
    )

Accent.BorderSizePixel = 0

Accent.Parent = TopBar


local AccentCorner =
    Instance.new("UICorner")

AccentCorner.CornerRadius =
    UDim.new(1, 0)

AccentCorner.Parent = Accent


local Title =
    Instance.new("TextLabel")

Title.BackgroundTransparency = 1

Title.Position =
    UDim2.new(
        0,
        25,
        0,
        7
    )

Title.Size =
    UDim2.new(
        1,
        -140,
        0,
        24
    )

Title.Font =
    Enum.Font.GothamBold

Title.TextSize = 17

Title.TextColor3 =
    Color3.fromRGB(
        245,
        245,
        255
    )

Title.TextXAlignment =
    Enum.TextXAlignment.Left

Title.Text =
    "Rendered Eggs"

Title.Parent = TopBar


local Minimize =
    Instance.new("TextButton")

Minimize.Size =
    UDim2.new(
        0,
        36,
        0,
        36
    )

Minimize.Position =
    UDim2.new(
        1,
        -85,
        0,
        10
    )

Minimize.BackgroundColor3 =
    Color3.fromRGB(
        62,
        64,
        82
    )

Minimize.Text =
    "-"

Minimize.TextColor3 =
    Color3.fromRGB(
        255,
        255,
        255
    )

Minimize.Font =
    Enum.Font.GothamBold

Minimize.TextSize = 20

Minimize.Parent = TopBar


local MinimizeCorner =
    Instance.new("UICorner")

MinimizeCorner.CornerRadius =
    UDim.new(0, 9)

MinimizeCorner.Parent = Minimize


local Close =
    Instance.new("TextButton")

Close.Size =
    UDim2.new(
        0,
        36,
        0,
        36
    )

Close.Position =
    UDim2.new(
        1,
        -45,
        0,
        10
    )

Close.BackgroundColor3 =
    Color3.fromRGB(
        180,
        60,
        70
    )

Close.Text =
    "X"

Close.TextColor3 =
    Color3.fromRGB(
        255,
        255,
        255
    )

Close.Font =
    Enum.Font.GothamBold

Close.TextSize = 20

Close.Parent = TopBar


local CloseCorner =
    Instance.new("UICorner")

CloseCorner.CornerRadius =
    UDim.new(0, 9)

CloseCorner.Parent = Close


--==============================================================
-- TABS / PAGES
--==============================================================

local TabBar = Instance.new("Frame")
TabBar.Size = UDim2.new(1, -24, 0, 42)
TabBar.Position = UDim2.new(0, 12, 0, 61)
TabBar.BackgroundTransparency = 1
TabBar.Parent = Main

local EggsTab = Instance.new("TextButton")
EggsTab.Size = UDim2.new(0.5, -4, 1, 0)
EggsTab.Position = UDim2.new(0, 0, 0, 0)
EggsTab.BackgroundColor3 = Color3.fromRGB(75, 95, 180)
EggsTab.Text = "EGGS"
EggsTab.TextColor3 = Color3.fromRGB(255,255,255)
EggsTab.Font = Enum.Font.GothamBold
EggsTab.TextSize = 12
EggsTab.Parent = TabBar

local EggsTabCorner = Instance.new("UICorner")
EggsTabCorner.CornerRadius = UDim.new(0, 9)
EggsTabCorner.Parent = EggsTab

local SettingsTab = Instance.new("TextButton")
SettingsTab.Size = UDim2.new(0.5, -4, 1, 0)
SettingsTab.Position = UDim2.new(0.5, 4, 0, 0)
SettingsTab.BackgroundColor3 = Color3.fromRGB(42, 43, 55)
SettingsTab.Text = "SETTINGS"
SettingsTab.TextColor3 = Color3.fromRGB(180,183,198)
SettingsTab.Font = Enum.Font.GothamBold
SettingsTab.TextSize = 12
SettingsTab.Parent = TabBar

local SettingsTabCorner = Instance.new("UICorner")
SettingsTabCorner.CornerRadius = UDim.new(0, 9)
SettingsTabCorner.Parent = SettingsTab

local EggsPage = Instance.new("Frame")
EggsPage.Name = "EggsPage"
EggsPage.Size = UDim2.new(1, -24, 0, 447)
EggsPage.Position = UDim2.new(0, 12, 0, 109)
EggsPage.BackgroundTransparency = 1
EggsPage.Parent = Main

local SettingsPage = Instance.new("ScrollingFrame")
SettingsPage.Name = "SettingsPage"
SettingsPage.Size = UDim2.new(1, -24, 0, 447)
SettingsPage.Position = UDim2.new(0, 12, 0, 109)
SettingsPage.BackgroundTransparency = 1
SettingsPage.BorderSizePixel = 0
SettingsPage.ScrollBarThickness = 4
SettingsPage.Visible = false
SettingsPage.CanvasSize = UDim2.new(0,0,0,0)
SettingsPage.Parent = Main

local function setActiveTab(which)
    local eggs = which == "Eggs"
    EggsPage.Visible = eggs
    SettingsPage.Visible = not eggs
    EggsTab.BackgroundColor3 = eggs and Color3.fromRGB(75,95,180) or Color3.fromRGB(42,43,55)
    SettingsTab.BackgroundColor3 = eggs and Color3.fromRGB(42,43,55) or Color3.fromRGB(75,95,180)
    EggsTab.TextColor3 = eggs and Color3.fromRGB(255,255,255) or Color3.fromRGB(180,183,198)
    SettingsTab.TextColor3 = eggs and Color3.fromRGB(180,183,198) or Color3.fromRGB(255,255,255)
end

EggsTab.MouseButton1Click:Connect(function() setActiveTab("Eggs") end)
SettingsTab.MouseButton1Click:Connect(function() setActiveTab("Settings") end)

--==============================================================
-- CONTROL BUTTONS
--==============================================================

local GlobalToggle =
    Instance.new("TextButton")

GlobalToggle.Size =
    UDim2.new(
        0,
        125,
        0,
        38
    )

GlobalToggle.Position =
    UDim2.new(
        0,
        12,
        0,
        69
    )

GlobalToggle.BackgroundColor3 =
    Color3.fromRGB(
        60,
        155,
        95
    )

GlobalToggle.Text =
    "ESP  |  ON"

GlobalToggle.TextColor3 =
    Color3.fromRGB(
        255,
        255,
        255
    )

GlobalToggle.Font =
    Enum.Font.GothamBold

GlobalToggle.TextSize = 12

GlobalToggle.Parent = Main


local GlobalCorner =
    Instance.new("UICorner")

GlobalCorner.CornerRadius =
    UDim.new(0, 9)

GlobalCorner.Parent = GlobalToggle


local PlotTP =
    Instance.new("TextButton")

PlotTP.Size =
    UDim2.new(
        0,
        140,
        0,
        38
    )

PlotTP.Position =
    UDim2.new(
        0,
        145,
        0,
        69
    )

PlotTP.BackgroundColor3 =
    Color3.fromRGB(
        78,
        100,
        185
    )

PlotTP.Text =
    "My Plot"

PlotTP.TextColor3 =
    Color3.fromRGB(
        255,
        255,
        255
    )

PlotTP.Font =
    Enum.Font.GothamBold

PlotTP.TextSize = 12

PlotTP.Parent = Main


local PlotTPCorner =
    Instance.new("UICorner")

PlotTPCorner.CornerRadius =
    UDim.new(0, 9)

PlotTPCorner.Parent = PlotTP


--==============================================================
-- SEARCH
--==============================================================

local SearchBox =
    Instance.new("Frame")

SearchBox.Size =
    UDim2.new(
        1,
        -124,
        0,
        40
    )

SearchBox.Position =
    UDim2.new(
        0,
        12,
        0,
        117
    )

SearchBox.BackgroundColor3 =
    Color3.fromRGB(
        32,
        33,
        43
    )

SearchBox.BorderSizePixel = 0

SearchBox.Parent = Main


local SearchCorner =
    Instance.new("UICorner")

SearchCorner.CornerRadius =
    UDim.new(0, 9)

SearchCorner.Parent = SearchBox


local SearchIcon =
    Instance.new("TextLabel")

SearchIcon.Size =
    UDim2.new(
        0,
        35,
        1,
        0
    )

SearchIcon.BackgroundTransparency = 1

SearchIcon.Text =
    "S"

SearchIcon.TextColor3 =
    Color3.fromRGB(
        155,
        160,
        180
    )

SearchIcon.Font =
    Enum.Font.GothamBold

SearchIcon.TextSize = 20

SearchIcon.Parent = SearchBox


local Search =
    Instance.new("TextBox")

Search.Position =
    UDim2.new(
        0,
        34,
        0,
        0
    )

Search.Size =
    UDim2.new(
        1,
        -40,
        1,
        0
    )

Search.BackgroundTransparency = 1

Search.TextColor3 =
    Color3.fromRGB(
        240,
        240,
        248
    )

Search.PlaceholderColor3 =
    Color3.fromRGB(
        125,
        128,
        145
    )

Search.PlaceholderText =
    "Search egg type..."

Search.Text =
    ""

Search.ClearTextOnFocus = false

Search.Font =
    Enum.Font.Gotham

Search.TextSize = 12

Search.TextXAlignment =
    Enum.TextXAlignment.Left

Search.Parent = SearchBox


--==============================================================
-- SCROLL LIST
--==============================================================

local List =
    Instance.new("ScrollingFrame")

List.Size =
    UDim2.new(
        1,
        -24,
        0,
        328
    )

List.Position =
    UDim2.new(
        0,
        12,
        0,
        165
    )

List.BackgroundColor3 =
    Color3.fromRGB(
        27,
        28,
        36
    )

List.BorderSizePixel = 0
List.ClipsDescendants = true
List.ScrollingDirection =
    Enum.ScrollingDirection.Y

List.ScrollBarThickness = 4

List.ScrollBarImageTransparency = 0.25

List.CanvasSize =
    UDim2.new(
        0,
        0,
        0,
        0
    )

List.AutomaticCanvasSize =
    Enum.AutomaticSize.None

List.Parent = Main


local ListCorner =
    Instance.new("UICorner")

ListCorner.CornerRadius =
    UDim.new(0, 10)

ListCorner.Parent = List


local ListPadding =
    Instance.new("UIPadding")

ListPadding.PaddingTop =
    UDim.new(0, 5)

ListPadding.PaddingBottom =
    UDim.new(0, 5)

ListPadding.PaddingLeft =
    UDim.new(0, 5)

ListPadding.PaddingRight =
    UDim.new(0, 5)

ListPadding.Parent = List


local ListLayout =
    Instance.new("UIListLayout")

ListLayout.Padding =
    UDim.new(0, 4)

ListLayout.SortOrder =
    Enum.SortOrder.LayoutOrder

ListLayout.Parent = List


ListLayout:GetPropertyChangedSignal(
    "AbsoluteContentSize"
):Connect(function()

    List.CanvasSize =
        UDim2.new(
            0,
            0,
            0,
            ListLayout.AbsoluteContentSize.Y + 12
        )

end)


--==============================================================
-- STATUS
--==============================================================

local Status =
    Instance.new("TextLabel")

Status.Size =
    UDim2.new(
        1,
        -24,
        0,
        40
    )

Status.Position =
    UDim2.new(
        0,
        12,
        0,
        508
    )

Status.BackgroundColor3 =
    Color3.fromRGB(
        29,
        30,
        39
    )

Status.Font =
    Enum.Font.Gotham

Status.TextSize = 12

Status.TextTruncate =
    Enum.TextTruncate.AtEnd

Status.TextYAlignment =
    Enum.TextYAlignment.Center

Status.TextColor3 =
    Color3.fromRGB(
        145,
        149,
        165
    )

Status.TextXAlignment =
    Enum.TextXAlignment.Left

Status.Text =
    ""

Status.Parent = Main
Status.Visible = false


local StatusCorner =
    Instance.new("UICorner")

StatusCorner.CornerRadius =
    UDim.new(0, 8)

StatusCorner.Parent = Status


local StatusPadding =
    Instance.new("UIPadding")

StatusPadding.PaddingLeft =
    UDim.new(0, 10)

StatusPadding.PaddingRight =
    UDim.new(0, 10)

StatusPadding.Parent = Status

-- Move existing controls into the Eggs page.
GlobalToggle.Parent = SettingsPage
GlobalToggle.Position = UDim2.new(0, 0, 0, 0)
PlotTP.Parent = SettingsPage
PlotTP.Position = UDim2.new(0, 0, 0, 46)
SearchBox.Parent = EggsPage
SearchBox.Position = UDim2.new(0, 0, 0, 46)
List.Parent = EggsPage
List.Position = UDim2.new(0, 0, 0, 94)
List.Size = UDim2.new(1, 0, 0, 300)
Status.Parent = EggsPage
Status.Position = UDim2.new(0, 0, 0, 401)
Status.Size = UDim2.new(1, 0, 0, 40)

local FlyStateLabel = Instance.new("TextLabel")
FlyStateLabel.Size = UDim2.new(1, 0, 0, 36)
FlyStateLabel.Position = UDim2.new(0, 0, 0, 92)
FlyStateLabel.BackgroundColor3 = Color3.fromRGB(32,33,43)
FlyStateLabel.Text = "Fly: Ready  |  Speed: " .. tostring(FlySpeed)
FlyStateLabel.TextColor3 = Color3.fromRGB(190,194,210)
FlyStateLabel.Font = Enum.Font.Gotham
FlyStateLabel.TextSize = 11
FlyStateLabel.TextXAlignment = Enum.TextXAlignment.Left
FlyStateLabel.Parent = SettingsPage
local FlyStatePadding = Instance.new("UIPadding")
FlyStatePadding.PaddingLeft = UDim.new(0,10)
FlyStatePadding.Parent = FlyStateLabel
local FlyStateCorner = Instance.new("UICorner")
FlyStateCorner.CornerRadius = UDim.new(0,8)
FlyStateCorner.Parent = FlyStateLabel

local SpeedLabel = Instance.new("TextLabel")
SpeedLabel.Size = UDim2.new(1,0,0,28)
SpeedLabel.BackgroundTransparency = 1
SpeedLabel.Text = "Fly Speed: " .. tostring(FlySpeed)
SpeedLabel.TextColor3 = Color3.fromRGB(230,232,242)
SpeedLabel.Font = Enum.Font.GothamBold
SpeedLabel.TextSize = 12
SpeedLabel.TextXAlignment = Enum.TextXAlignment.Left
SpeedLabel.LayoutOrder = 3
SpeedLabel.Parent = SettingsPage

local SpeedBar = Instance.new("Frame")
SpeedBar.Size = UDim2.new(1,0,0,14)
SpeedBar.BackgroundColor3 = Color3.fromRGB(45,46,58)
SpeedBar.LayoutOrder = 4
SpeedBar.Parent = SettingsPage
local SpeedBarCorner = Instance.new("UICorner")
SpeedBarCorner.CornerRadius = UDim.new(1,0)
SpeedBarCorner.Parent = SpeedBar

local SpeedFill = Instance.new("Frame")
SpeedFill.Size = UDim2.new((FlySpeed-MIN_FLY_SPEED)/(MAX_FLY_SPEED-MIN_FLY_SPEED),0,1,0)
SpeedFill.BackgroundColor3 = Color3.fromRGB(90,120,235)
SpeedFill.BorderSizePixel = 0
SpeedFill.Parent = SpeedBar
local SpeedFillCorner = Instance.new("UICorner")
SpeedFillCorner.CornerRadius = UDim.new(1,0)
SpeedFillCorner.Parent = SpeedFill

local SpeedHit = Instance.new("TextButton")
SpeedHit.Size = UDim2.new(1,0,1,0)
SpeedHit.BackgroundTransparency = 1
SpeedHit.Text = ""
SpeedHit.Parent = SpeedBar

local function setFlySpeed(value)
    FlySpeed = math.clamp(math.floor(tonumber(value) or FlySpeed), MIN_FLY_SPEED, MAX_FLY_SPEED)
    local alpha = (FlySpeed-MIN_FLY_SPEED)/(MAX_FLY_SPEED-MIN_FLY_SPEED)
    SpeedFill.Size = UDim2.new(alpha,0,1,0)
    SpeedLabel.Text = "Fly Speed: " .. tostring(FlySpeed)
    FlyStateLabel.Text = (FlyBusy and "Fly: Flying" or "Fly: Ready") .. "  |  Speed: " .. tostring(FlySpeed)
end

SpeedHit.MouseButton1Down:Connect(function()
    local mouse = LocalPlayer:GetMouse()
    local function update()
        local alpha = math.clamp((mouse.X - SpeedBar.AbsolutePosition.X) / SpeedBar.AbsoluteSize.X, 0, 1)
        setFlySpeed(MIN_FLY_SPEED + alpha * (MAX_FLY_SPEED-MIN_FLY_SPEED))
    end
    update()
    local moveConn
    moveConn = UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement then update() end
    end)
    local endConn
    endConn = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            moveConn:Disconnect()
            endConn:Disconnect()
        end
    end)
end)

local ReturnLabel = Instance.new("TextLabel")
ReturnLabel.Size = UDim2.new(1,0,0,32)
ReturnLabel.BackgroundColor3 = Color3.fromRGB(32,33,43)
ReturnLabel.Text = "Auto return to My Plot after reaching an egg: ON"
ReturnLabel.TextColor3 = Color3.fromRGB(225,228,240)
ReturnLabel.Font = Enum.Font.Gotham
ReturnLabel.TextSize = 11
ReturnLabel.TextXAlignment = Enum.TextXAlignment.Left
ReturnLabel.LayoutOrder = 5
ReturnLabel.Parent = SettingsPage
local ReturnPadding = Instance.new("UIPadding")
ReturnPadding.PaddingLeft = UDim.new(0,10)
ReturnPadding.Parent = ReturnLabel
local ReturnCorner = Instance.new("UICorner")
ReturnCorner.CornerRadius = UDim.new(0,8)
ReturnCorner.Parent = ReturnLabel

local DisplayTitle = Instance.new("TextButton")
DisplayTitle.Size = UDim2.new(1,0,0,34)
DisplayTitle.BackgroundColor3 = Color3.fromRGB(32,33,43)
DisplayTitle.Text = "ESP DISPLAY [+]"
DisplayTitle.TextColor3 = Color3.fromRGB(240,242,250)
DisplayTitle.Font = Enum.Font.GothamBold
DisplayTitle.TextSize = 12
DisplayTitle.TextXAlignment = Enum.TextXAlignment.Left
DisplayTitle.AutoButtonColor = false
DisplayTitle.Parent = SettingsPage
local DisplayTitlePadding = Instance.new("UIPadding")
DisplayTitlePadding.PaddingLeft = UDim.new(0,10)
DisplayTitlePadding.Parent = DisplayTitle
local DisplayTitleCorner = Instance.new("UICorner")
DisplayTitleCorner.CornerRadius = UDim.new(0,8)
DisplayTitleCorner.Parent = DisplayTitle

local DisplayFrame = Instance.new("Frame")
DisplayFrame.Size = UDim2.new(1,0,0,102)
DisplayFrame.BackgroundColor3 = Color3.fromRGB(29,30,39)
DisplayFrame.Visible = false
DisplayFrame.Parent = SettingsPage
local DisplayFrameCorner = Instance.new("UICorner")
DisplayFrameCorner.CornerRadius = UDim.new(0,9)
DisplayFrameCorner.Parent = DisplayFrame
local DisplayLayout = Instance.new("UIListLayout")
DisplayLayout.Padding = UDim.new(0,5)
DisplayLayout.Parent = DisplayFrame
local DisplayPad = Instance.new("UIPadding")
DisplayPad.PaddingTop = UDim.new(0,7)
DisplayPad.PaddingLeft = UDim.new(0,8)
DisplayPad.PaddingRight = UDim.new(0,8)
DisplayPad.Parent = DisplayFrame

local DisplayOpen = false
local DisplayOptions = {"Name", "Rarity", "Name + Rarity"}
local DisplayButtons = {}
local relayoutSettings
local function updateDisplayUI()
    for mode, button in pairs(DisplayButtons) do
        local selected = ESPDisplayMode == mode
        button.Text = (selected and "[ON] " or "[OFF] ") .. mode
        button.BackgroundColor3 = selected and Color3.fromRGB(48,50,65) or Color3.fromRGB(34,35,44)
    end
end
for _, mode in ipairs(DisplayOptions) do
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1,0,0,26)
    button.BackgroundColor3 = Color3.fromRGB(34,35,44)
    button.TextColor3 = Color3.fromRGB(225,228,240)
    button.Font = Enum.Font.GothamBold
    button.TextSize = 10
    button.Text = "[OFF] " .. mode
    button.AutoButtonColor = false
    button.Parent = DisplayFrame
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0,6)
    c.Parent = button
    DisplayButtons[mode] = button
    button.MouseButton1Click:Connect(function()
        ESPDisplayMode = mode
        DisplayTitle.Text = "ESP DISPLAY: " .. mode .. (DisplayOpen and " [-]" or " [+]")
        updateDisplayUI()
        refreshESPDisplay()
    end)
end
local function setDisplayOpen(open)
    DisplayOpen = open
    DisplayFrame.Visible = open
    DisplayTitle.Text = "ESP DISPLAY: " .. ESPDisplayMode .. (open and " [-]" or " [+]")
    if relayoutSettings then
        relayoutSettings()
    end
end
DisplayTitle.MouseButton1Click:Connect(function() setDisplayOpen(not DisplayOpen) end)
updateDisplayUI()

local RarityTitle = Instance.new("TextButton")
RarityTitle.Size = UDim2.new(1,0,0,34)
RarityTitle.BackgroundColor3 = Color3.fromRGB(32,33,43)
RarityTitle.Text = "EGG RARITY FILTER  [+]"
RarityTitle.TextColor3 = Color3.fromRGB(240,242,250)
RarityTitle.Font = Enum.Font.GothamBold
RarityTitle.TextSize = 12
RarityTitle.TextXAlignment = Enum.TextXAlignment.Left
RarityTitle.LayoutOrder = 6
RarityTitle.AutoButtonColor = false
RarityTitle.Parent = SettingsPage
local RarityTitlePadding = Instance.new("UIPadding")
RarityTitlePadding.PaddingLeft = UDim.new(0,10)
RarityTitlePadding.Parent = RarityTitle
local RarityTitleCorner = Instance.new("UICorner")
RarityTitleCorner.CornerRadius = UDim.new(0,8)
RarityTitleCorner.Parent = RarityTitle

local RarityFrame = Instance.new("Frame")
RarityFrame.Size = UDim2.new(1,0,0,180)
RarityFrame.BackgroundColor3 = Color3.fromRGB(29,30,39)
RarityFrame.LayoutOrder = 7
RarityFrame.Visible = false
RarityFrame.Parent = SettingsPage
local RarityFrameCorner = Instance.new("UICorner")
RarityFrameCorner.CornerRadius = UDim.new(0,9)
RarityFrameCorner.Parent = RarityFrame
local RarityGrid = Instance.new("UIGridLayout")
RarityGrid.CellSize = UDim2.new(0.5,-6,0,28)
RarityGrid.CellPadding = UDim2.new(0,6,0,5)
RarityGrid.SortOrder = Enum.SortOrder.LayoutOrder
RarityGrid.Parent = RarityFrame
local RarityPad = Instance.new("UIPadding")
RarityPad.PaddingTop = UDim.new(0,8)
RarityPad.PaddingLeft = UDim.new(0,8)
RarityPad.PaddingRight = UDim.new(0,8)
RarityPad.Parent = RarityFrame

local function updateRarityFilterUI()
    for _, child in ipairs(RarityFrame:GetChildren()) do
        if child:IsA("TextButton") then
            local rarityKey = child:GetAttribute("RarityKey")
            local info = RarityByName[rarityKey]
            local on = SelectedRarities[rarityKey] == true
            child.Text = (on and "[ON] " or "[OFF] ") .. (info and info.Name or rarityKey)
            child.TextColor3 = info and info.Color or Color3.fromRGB(220,220,230)
            child.BackgroundColor3 = on and Color3.fromRGB(48,50,65) or Color3.fromRGB(34,35,44)
        end
    end
end

for _, info in ipairs(RARITY_CONFIG) do
    local key = string.lower(info.Name)
    local button = Instance.new("TextButton")
    button.LayoutOrder = info.Order
    button:SetAttribute("RarityKey", key)
    button.BackgroundColor3 = Color3.fromRGB(48,50,65)
    button.Text = "[ON] " .. info.Name
    button.TextColor3 = info.Color
    button.Font = Enum.Font.GothamBold
    button.TextSize = 11
    button.AutoButtonColor = false
    button.Parent = RarityFrame
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0,7)
    c.Parent = button
    button.MouseButton1Click:Connect(function()
        SelectedRarities[key] = not SelectedRarities[key]
        updateRarityFilterUI()
        if updateSearch then updateSearch() end
    end)
end

local RarityFilterOpen = false
local AutoReturnButton
local function setRarityFilterOpen(open)
    RarityFilterOpen = open
    RarityFrame.Visible = open
    RarityTitle.Text = open and "EGG RARITY FILTER  [-]" or "EGG RARITY FILTER  [+]"
    if relayoutSettings then
        relayoutSettings()
    end
end

RarityTitle.MouseButton1Click:Connect(function()
    setRarityFilterOpen(not RarityFilterOpen)
end)

AutoReturnButton = Instance.new("TextButton")
AutoReturnButton.Size = UDim2.new(1,0,0,34)
AutoReturnButton.BackgroundColor3 = Color3.fromRGB(60,145,90)
AutoReturnButton.Text = "AUTO RETURN: ON"
AutoReturnButton.TextColor3 = Color3.fromRGB(255,255,255)
AutoReturnButton.Font = Enum.Font.GothamBold
AutoReturnButton.TextSize = 11
AutoReturnButton.LayoutOrder = 8
AutoReturnButton.Parent = SettingsPage
local AutoReturnCorner = Instance.new("UICorner")
AutoReturnCorner.CornerRadius = UDim.new(0,8)
AutoReturnCorner.Parent = AutoReturnButton

local SuperOptimizeButton = Instance.new("TextButton")
SuperOptimizeButton.Size = UDim2.new(1,0,0,34)
SuperOptimizeButton.BackgroundColor3 = SUPER_OPTIMIZE and Color3.fromRGB(60,145,90) or Color3.fromRGB(145,65,75)
SuperOptimizeButton.Text = SUPER_OPTIMIZE and "SUPER OPTIMIZE: ON" or "SUPER OPTIMIZE: OFF"
SuperOptimizeButton.TextColor3 = Color3.fromRGB(255,255,255)
SuperOptimizeButton.Font = Enum.Font.GothamBold
SuperOptimizeButton.TextSize = 11
SuperOptimizeButton.Parent = SettingsPage
local SuperOptimizeCorner = Instance.new("UICorner")
SuperOptimizeCorner.CornerRadius = UDim.new(0,8)
SuperOptimizeCorner.Parent = SuperOptimizeButton

SuperOptimizeButton.MouseButton1Click:Connect(function()
    if setSuperOptimization then
        setSuperOptimization(not SUPER_OPTIMIZE)
    end
end)

--==============================================================
-- AUTO FARM
--==============================================================

local AutoFarmTitle = Instance.new("TextLabel")
AutoFarmTitle.Size = UDim2.new(1,0,0,28)
AutoFarmTitle.BackgroundTransparency = 1
AutoFarmTitle.Text = "AUTO FARM"
AutoFarmTitle.TextColor3 = Color3.fromRGB(240,242,250)
AutoFarmTitle.Font = Enum.Font.GothamBold
AutoFarmTitle.TextSize = 12
AutoFarmTitle.TextXAlignment = Enum.TextXAlignment.Left
AutoFarmTitle.Parent = SettingsPage

local AutoFarmToggle = Instance.new("TextButton")
AutoFarmToggle.Size = UDim2.new(1,0,0,34)
AutoFarmToggle.BackgroundColor3 = Color3.fromRGB(145,65,75)
AutoFarmToggle.Text = "AUTO FARM: OFF"
AutoFarmToggle.TextColor3 = Color3.fromRGB(255,255,255)
AutoFarmToggle.Font = Enum.Font.GothamBold
AutoFarmToggle.TextSize = 11
AutoFarmToggle.AutoButtonColor = false
AutoFarmToggle.Parent = SettingsPage
local AutoFarmToggleCorner = Instance.new("UICorner")
AutoFarmToggleCorner.CornerRadius = UDim.new(0,8)
AutoFarmToggleCorner.Parent = AutoFarmToggle

local AutoFarmModeButton = Instance.new("TextButton")
AutoFarmModeButton.Size = UDim2.new(1,0,0,34)
AutoFarmModeButton.BackgroundColor3 = Color3.fromRGB(72,155,105)
AutoFarmModeButton.Text = "MODE: TP"
AutoFarmModeButton.TextColor3 = Color3.fromRGB(230,232,242)
AutoFarmModeButton.Font = Enum.Font.GothamBold
AutoFarmModeButton.TextSize = 11
AutoFarmModeButton.AutoButtonColor = false
AutoFarmModeButton.Parent = SettingsPage
local AutoFarmModeCorner = Instance.new("UICorner")
AutoFarmModeCorner.CornerRadius = UDim.new(0,8)
AutoFarmModeCorner.Parent = AutoFarmModeButton

local AutoFarmTargetButton = Instance.new("TextButton")
AutoFarmTargetButton.Size = UDim2.new(1,0,0,34)
AutoFarmTargetButton.BackgroundColor3 = Color3.fromRGB(48,50,65)
AutoFarmTargetButton.Text = "TARGET: ALL EGGS  [click for list]"
AutoFarmTargetButton.TextColor3 = Color3.fromRGB(230,232,242)
AutoFarmTargetButton.Font = Enum.Font.GothamBold
AutoFarmTargetButton.TextSize = 11
AutoFarmTargetButton.TextXAlignment = Enum.TextXAlignment.Left
AutoFarmTargetButton.AutoButtonColor = false
AutoFarmTargetButton.Parent = SettingsPage
local AutoFarmTargetPadding = Instance.new("UIPadding")
AutoFarmTargetPadding.PaddingLeft = UDim.new(0,10)
AutoFarmTargetPadding.Parent = AutoFarmTargetButton
local AutoFarmTargetCorner = Instance.new("UICorner")
AutoFarmTargetCorner.CornerRadius = UDim.new(0,8)
AutoFarmTargetCorner.Parent = AutoFarmTargetButton

local AutoFarmList = Instance.new("ScrollingFrame")
AutoFarmList.Size = UDim2.new(1,0,0,150)
AutoFarmList.BackgroundColor3 = Color3.fromRGB(29,30,39)
AutoFarmList.BorderSizePixel = 0
AutoFarmList.ScrollBarThickness = 4
AutoFarmList.CanvasSize = UDim2.new(0,0,0,0)
AutoFarmList.Visible = false
AutoFarmList.Parent = SettingsPage
local AutoFarmListCorner = Instance.new("UICorner")
AutoFarmListCorner.CornerRadius = UDim.new(0,9)
AutoFarmListCorner.Parent = AutoFarmList
local AutoFarmListLayout = Instance.new("UIListLayout")
AutoFarmListLayout.Padding = UDim.new(0,4)
AutoFarmListLayout.SortOrder = Enum.SortOrder.LayoutOrder
AutoFarmListLayout.Parent = AutoFarmList
local AutoFarmListPad = Instance.new("UIPadding")
AutoFarmListPad.PaddingTop = UDim.new(0,6)
AutoFarmListPad.PaddingLeft = UDim.new(0,6)
AutoFarmListPad.PaddingRight = UDim.new(0,6)
AutoFarmListPad.Parent = AutoFarmList
AutoFarmListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    AutoFarmList.CanvasSize = UDim2.new(0,0,0,AutoFarmListLayout.AbsoluteContentSize.Y + 12)
end)

local AutoFarmListOpen = false
local AutoFarmRows = {}

local function getAutoFarmTargetState(name)
    return AutoFarmTargets[string.lower(tostring(name))] == true
end

local function refreshAutoFarmTargetButton()
    local count = 0
    for _ in pairs(AutoFarmTargets) do count += 1 end
    if AutoFarmTargetAll then
        AutoFarmTargetButton.Text = "TARGET: ALL EGGS  [click for list]"
    elseif count == 0 then
        AutoFarmTargetButton.Text = "TARGET: NONE  [click for list]"
    elseif count == 1 then
        local selected
        for key in pairs(AutoFarmTargets) do selected = key break end
        AutoFarmTargetButton.Text = "TARGET: " .. tostring(selected) .. "  [list]"
    else
        AutoFarmTargetButton.Text = "TARGET: " .. tostring(count) .. " TYPES  [list]"
    end
end

local function refreshAutoFarmRows()
    local names = {}
    local seen = {}
    for model in pairs(EggEntries) do
        if model and model.Parent then
            local key = string.lower(model.Name)
            if not seen[key] then
                seen[key] = true
                table.insert(names, model.Name)
            end
        end
    end
    table.sort(names, function(a,b) return string.lower(a) < string.lower(b) end)

    for key, row in pairs(AutoFarmRows) do
        if not seen[key] then
            row:Destroy()
            AutoFarmRows[key] = nil
        end
    end

    for _, name in ipairs(names) do
        local key = string.lower(name)
        if not AutoFarmRows[key] then
            local row = Instance.new("TextButton")
            row.Name = "Target_" .. name
            row.Size = UDim2.new(1,0,0,28)
            row.BackgroundColor3 = Color3.fromRGB(34,35,44)
            row.TextColor3 = Color3.fromRGB(225,228,240)
            row.Font = Enum.Font.GothamBold
            row.TextSize = 10
            row.AutoButtonColor = false
            row.Parent = AutoFarmList
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0,6)
            c.Parent = row
            row.MouseButton1Click:Connect(function()
                AutoFarmTargetAll = false
                AutoFarmTargets[key] = not AutoFarmTargets[key]
                if not AutoFarmTargets[key] then AutoFarmTargets[key] = nil end
                refreshAutoFarmRows()
                refreshAutoFarmTargetButton()
            end)
            AutoFarmRows[key] = row
        end
        local row = AutoFarmRows[key]
        local on = AutoFarmTargetAll or getAutoFarmTargetState(name)
        row.Text = (on and "[ON] " or "[OFF] ") .. name
        row.BackgroundColor3 = on and Color3.fromRGB(48,50,65) or Color3.fromRGB(34,35,44)
    end
end

local function setAutoFarmListOpen(open)
    AutoFarmListOpen = open
    AutoFarmList.Visible = open
    if open then refreshAutoFarmRows() end
    if relayoutSettings then relayoutSettings() end
end

AutoFarmTargetButton.MouseButton1Click:Connect(function()
    setAutoFarmListOpen(not AutoFarmListOpen)
end)

AutoFarmModeButton.MouseButton1Click:Connect(function()
    AutoFarmMode = AutoFarmMode == "TP" and "Fly" or "TP"
    AutoFarmModeButton.Text = "MODE: " .. string.upper(AutoFarmMode)
    AutoFarmModeButton.BackgroundColor3 = AutoFarmMode == "TP" and Color3.fromRGB(72,155,105) or Color3.fromRGB(77,97,175)
end)

AutoFarmToggle.MouseButton1Click:Connect(function()
    AutoFarmEnabled = not AutoFarmEnabled
    AutoFarmToggle.Text = AutoFarmEnabled and "AUTO FARM: ON" or "AUTO FARM: OFF"
    AutoFarmToggle.BackgroundColor3 = AutoFarmEnabled and Color3.fromRGB(60,145,90) or Color3.fromRGB(145,65,75)
    if AutoFarmEnabled then
        showStatus("Auto Farm " .. AutoFarmMode .. " started", 2)
        task.spawn(runAutoFarm)
    else
        AutoFarmToken += 1
        if FlyBusy then
            FlyCancelToken += 1
            FlyBusy = false
        end
        showStatus("Auto Farm stopped", 1.5)
    end
end)

AutoFarmTargetButton.MouseButton2Click:Connect(function()
    AutoFarmTargetAll = true
    AutoFarmTargets = {}
    refreshAutoFarmRows()
    refreshAutoFarmTargetButton()
end)
refreshAutoFarmTargetButton()

-- Responsive settings layout. Sections push the controls below them
-- instead of overlapping when a dropdown is opened.
relayoutSettings = function()
    local y = 0

    GlobalToggle.Position = UDim2.new(0, 0, 0, y)
    y += 38 + 6

    PlotTP.Position = UDim2.new(0, 0, 0, y)
    y += 38 + 6

    FlyStateLabel.Position = UDim2.new(0, 0, 0, y)
    y += 36 + 6

    SpeedLabel.Position = UDim2.new(0, 0, 0, y)
    y += 28 + 4

    SpeedBar.Position = UDim2.new(0, 0, 0, y)
    y += 14 + 8

    ReturnLabel.Position = UDim2.new(0, 0, 0, y)
    y += 32 + 8

    DisplayTitle.Position = UDim2.new(0, 0, 0, y)
    y += 34

    DisplayFrame.Position = UDim2.new(0, 0, 0, y)
    DisplayFrame.Visible = DisplayOpen
    if DisplayOpen then
        y += 102 + 8
    else
        y += 8
    end

    RarityTitle.Position = UDim2.new(0, 0, 0, y)
    y += 34

    RarityFrame.Position = UDim2.new(0, 0, 0, y)
    RarityFrame.Size = UDim2.new(1, 0, 0, 180)
    RarityFrame.Visible = RarityFilterOpen
    if RarityFilterOpen then
        y += 180 + 8
    else
        y += 8
    end

    AutoReturnButton.Position = UDim2.new(0, 0, 0, y)
    y += 34 + 6

    SuperOptimizeButton.Position = UDim2.new(0, 0, 0, y)
    y += 34 + 10

    AutoFarmTitle.Position = UDim2.new(0, 0, 0, y)
    y += 28 + 4
    AutoFarmToggle.Position = UDim2.new(0, 0, 0, y)
    y += 34 + 5
    AutoFarmModeButton.Position = UDim2.new(0, 0, 0, y)
    y += 34 + 5
    AutoFarmTargetButton.Position = UDim2.new(0, 0, 0, y)
    y += 34 + 5
    AutoFarmList.Position = UDim2.new(0, 0, 0, y)
    AutoFarmList.Visible = AutoFarmListOpen
    if AutoFarmListOpen then y += 150 + 8 else y += 8 end

    SettingsPage.CanvasSize = UDim2.new(0, 0, 0, y)
end

relayoutSettings()

AutoReturnButton.MouseButton1Click:Connect(function()
    FlyToPlotAfterEgg = not FlyToPlotAfterEgg
    AutoReturnButton.Text = FlyToPlotAfterEgg and "AUTO RETURN: ON" or "AUTO RETURN: OFF"
    AutoReturnButton.BackgroundColor3 = FlyToPlotAfterEgg and Color3.fromRGB(60,145,90) or Color3.fromRGB(145,65,75)
    ReturnLabel.Text = "Auto return to My Plot after reaching an egg: " .. (FlyToPlotAfterEgg and "ON" or "OFF")
end)

SettingsPage.CanvasSize = UDim2.new(0,0,0,460)


local StatusExpiresAt = 0

showStatus = function(message, duration)
    Status.Text = message
    Status.Visible = true
    StatusExpiresAt = os.clock() + (duration or 3)
end


--==============================================================
-- DRAG
--==============================================================

local dragging = false
local dragStart = nil
local startPosition = nil

local resizing = false
local resizeStart = nil
local resizeStartSize = nil
local resizeScale = 1


TopBar.InputBegan:Connect(function(input)

    if MainMinimized then
        return
    end

    if input.UserInputType ==
        Enum.UserInputType.MouseButton1
        or input.UserInputType ==
        Enum.UserInputType.Touch then

        dragging = true

        dragStart =
            input.Position

        startPosition =
            Main.Position

    end

end)


TopBar.InputEnded:Connect(function(input)

    if input.UserInputType ==
        Enum.UserInputType.MouseButton1
        or input.UserInputType ==
        Enum.UserInputType.Touch then

        dragging = false

    end

end)


ResizeHandle.InputBegan:Connect(function(input)
    if MainMinimized then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        resizing = true
        resizeStart = input.Position
        resizeStartSize = Main.Size
        resizeScale = MainScale.Scale
    end
end)


ResizeHandle.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        resizing = false
    end
end)


Connections.InputChanged =
    UserInputService.InputChanged:Connect(
        function(input)

            if MainMinimized or (not dragging and not resizing) then

                return
            end

            if input.UserInputType ~=
                Enum.UserInputType.MouseMovement
                and input.UserInputType ~=
                Enum.UserInputType.Touch then

                return

            end


            if dragging then
                local delta =
                    input.Position - dragStart

                Main.Position =
                    UDim2.new(
                        startPosition.X.Scale,
                        startPosition.X.Offset
                            + delta.X,

                        startPosition.Y.Scale,
                        startPosition.Y.Offset
                            + delta.Y
                    )

                return
            end


            local delta =
                (input.Position - resizeStart) / resizeScale

            local width = math.clamp(
                resizeStartSize.X.Offset + delta.X,
                MIN_MENU_WIDTH,
                MAX_MENU_WIDTH
            )

            local height = math.clamp(
                resizeStartSize.Y.Offset + delta.Y,
                MIN_MENU_HEIGHT,
                MAX_MENU_HEIGHT
            )

            Main.Size = UDim2.new(0, width, 0, height)
            MainExpandedSize = Main.Size
            updateMainScale()

        end
    )


--==============================================================
-- CREATE ESP
--==============================================================

-- Return whether the egg's configured rarity is currently enabled.
-- Eggs that are not in RARITY_CONFIG remain visible so an unknown/new egg
-- does not silently disappear from ESP.
local function getEggTypeEnabled(model)
    if not model then
        return false
    end

    local rarityInfo = getManualRarity(model.Name)
    if not rarityInfo then
        return true
    end

    local key = string.lower(tostring(rarityInfo.Name))
    return SelectedRarities[key] ~= false
end


-- Get a stable target point slightly above the egg for Fly.
local function getEggTopCFrameImpl(model)
    if not model or not model:IsA("Model") or not model.Parent then
        return nil
    end

    local root = getRootPart(model)
    if not root then
        return nil
    end

    local ok, boxCFrame, boxSize = pcall(function()
        return model:GetBoundingBox()
    end)

    if not ok or typeof(boxCFrame) ~= "CFrame" or typeof(boxSize) ~= "Vector3" then
        return CFrame.new(root.Position + Vector3.new(0, 3, 0), root.Position + root.CFrame.LookVector)
    end

    local topPosition = boxCFrame.Position + Vector3.new(0, boxSize.Y * 0.5 + 2, 0)
    return CFrame.new(topPosition, topPosition + root.CFrame.LookVector)
end

getEggTopCFrame = getEggTopCFrameImpl


local function getESPDisplayText(model, rarityInfo, distance)
    local name = model and model.Name or "Egg"
    local rarity = rarityInfo and rarityInfo.Name or "Unknown"
    local text

    if ESPDisplayMode == "Rarity" then
        text = rarity
    elseif ESPDisplayMode == "Name" then
        text = name
    else
        text = name .. "  [" .. rarity .. "]"
    end

    if distance then
        text ..= "\n[" .. math.floor(distance) .. " studs]"
    end

    return text
end

refreshESPDisplay = function()
    for model, esp in pairs(ESPs) do
        if model and model.Parent and esp and esp.Label then
            local rarityInfo = getManualRarity(model.Name)
            esp.Label.Text = getESPDisplayText(model, rarityInfo, nil)
        end
    end
end

local function createESP(model)

    if not model
        or not model:IsA("Model")
        or not model.Parent then

        return

    end


    if ESPs[model] then
        return
    end


    local root =
        getRootPart(model)


    if not root then
        return
    end

    local rarityInfo = getManualRarity(model.Name)
    local rarityColor = rarityInfo and rarityInfo.Color or Color3.fromRGB(220, 220, 230)


    local billboard =
        Instance.new("BillboardGui")

    billboard.Name =
        "EggESP"

    billboard.Adornee =
        root

    billboard.AlwaysOnTop = true

    billboard.Size =
        UDim2.new(
            0,
            190,
            0,
            44
        )

    billboard.StudsOffset =
        Vector3.new(
            0,
            2.5,
            0
        )

    billboard.Enabled =
        GlobalESPEnabled
        and getEggTypeEnabled(model)

    billboard.Parent =
        root


    local label =
        Instance.new("TextLabel")

    label.Name =
        "Info"

    label.Size =
        UDim2.fromScale(
            1,
            1
        )

    label.BackgroundTransparency = 1

    label.Font =
        Enum.Font.GothamBold

    label.TextSize = 13

    label.TextColor3 = rarityColor

    label.TextStrokeTransparency =
        0.15

    label.Text =
        getESPDisplayText(model, rarityInfo)

    label.Parent =
        billboard


    local highlight = nil


    if SHOW_HIGHLIGHT then

        highlight =
            Instance.new("Highlight")

        highlight.Name =
            "EggHighlight"

        highlight.FillColor = rarityColor
        highlight.OutlineColor = rarityColor

        highlight.FillTransparency =
            0.78

        highlight.OutlineTransparency =
            0.1

        highlight.Adornee =
            model

        highlight.Enabled =
            GlobalESPEnabled
            and getEggTypeEnabled(model)

        highlight.Parent =
            model

    end


    ESPs[model] = {
        Billboard = billboard,
        Label = label,
        Highlight = highlight
    }

end


--==============================================================
-- DESTROY ESP
--==============================================================

local function destroyESP(model)

    local esp =
        ESPs[model]

    if not esp then
        return
    end


    if esp.Billboard then
        esp.Billboard:Destroy()
    end


    if esp.Highlight then
        esp.Highlight:Destroy()
    end


    ESPs[model] = nil

end


--==============================================================
-- MANUAL EGG RARITY
--==============================================================

local function getEggRarity(model)
    if not model then
        return nil
    end

    local info = getManualRarity(model.Name)
    if info then
        return info.Name
    end

    return nil
end

local function getRarityInfo(rarity)
    if not rarity then
        return nil
    end

    return RarityByName[string.lower(tostring(rarity))]
end

local function updateGroupLayoutOrder(group)
    if not group or not group.GroupFrame then
        return
    end

    local info = getRarityInfo(group.Rarity)
    if info then
        group.RarityOrder = info.Order
        group.RarityColor = info.Color
        group.GroupFrame.LayoutOrder = info.Order
    else
        -- Unknown rarity always goes after configured rarities.
        group.RarityOrder = #RARITY_CONFIG + 100
        group.RarityColor = Color3.fromRGB(190, 195, 205)
        group.GroupFrame.LayoutOrder = group.RarityOrder
    end
end

--==============================================================
-- CREATE GROUP
--==============================================================

local function createEggGroup(groupName)

    if EggGroups[groupName] then
        return EggGroups[groupName]
    end


    local group = {

        Eggs = {},

        Expanded = true,

        Rarity = nil,

        RarityOrder = #RARITY_CONFIG + 100,

        RarityColor = Color3.fromRGB(190, 195, 205),

        GroupFrame = nil,

        Container = nil

    }


    -- Each Egg group gets one wrapper so the header and its contents
    -- stay together when UIListLayout sorts the scrolling list.
    local GroupFrame =
        Instance.new("Frame")

    GroupFrame.Name =
        "Group_" .. groupName

    GroupFrame.Size =
        UDim2.new(
            1,
            -2,
            0,
            34
        )

    GroupFrame.BackgroundTransparency = 1

    GroupFrame.AutomaticSize =
        Enum.AutomaticSize.Y

    GroupFrame.Parent = List

    local GroupLayout =
        Instance.new("UIListLayout")

    GroupLayout.Padding =
        UDim.new(0, 2)

    GroupLayout.SortOrder =
        Enum.SortOrder.LayoutOrder

    GroupLayout.Parent = GroupFrame

    local Header =
        Instance.new("Frame")

    Header.Name =
        "Header"

    Header.Size =
        UDim2.new(
            1,
            -2,
            0,
            34
        )

    Header.BackgroundColor3 =
        Color3.fromRGB(
            41,
            42,
            54
        )

    Header.BorderSizePixel = 0

    Header.LayoutOrder = 1
    Header.Parent = GroupFrame


    local HeaderCorner =
        Instance.new("UICorner")

    HeaderCorner.CornerRadius =
        UDim.new(0, 7)

    HeaderCorner.Parent =
        Header


    local Toggle =
        Instance.new("TextButton")

    Toggle.Size =
        UDim2.new(
            1,
            -160,
            1,
            0
        )

    Toggle.BackgroundTransparency = 1

    Toggle.TextXAlignment =
        Enum.TextXAlignment.Left

    Toggle.Font =
        Enum.Font.GothamBold

    Toggle.TextSize = 12

    Toggle.TextTruncate =
        Enum.TextTruncate.AtEnd

    Toggle.TextColor3 =
        Color3.fromRGB(
            235,
            237,
            248
        )

    local rarity = group.Rarity
    local rarityInfo = getRarityInfo(rarity)

    Toggle.Text =
        "v  " .. groupName

    Toggle.Parent =
        Header

    local RarityLabel = Instance.new("TextLabel")
    RarityLabel.Name = "Rarity"
    RarityLabel.Size = UDim2.new(0, 88, 1, 0)
    RarityLabel.Position = UDim2.new(1, -158, 0, 0)
    RarityLabel.BackgroundTransparency = 1
    RarityLabel.Font = Enum.Font.GothamBold
    RarityLabel.TextSize = 10
    RarityLabel.TextXAlignment = Enum.TextXAlignment.Right
    RarityLabel.TextTruncate = Enum.TextTruncate.AtEnd
    RarityLabel.Text = rarity or "Unknown"
    RarityLabel.TextColor3 = rarityInfo and rarityInfo.Color or Color3.fromRGB(190, 195, 205)
    RarityLabel.Parent = Header


    local Container =
        Instance.new("Frame")

    Container.Name =
        "Container"

    Container.Size =
        UDim2.new(
            1,
            -2,
            0,
            0
        )

    Container.BackgroundTransparency = 1

    Container.AutomaticSize =
        Enum.AutomaticSize.Y

    Container.Visible = true

    Container.LayoutOrder = 2
    Container.Parent =
        GroupFrame


    local ContainerLayout =
        Instance.new("UIListLayout")

    ContainerLayout.Padding =
        UDim.new(0, 2)

    ContainerLayout.Parent =
        Container


    group.GroupFrame =
        GroupFrame

    group.Container =
        Container


    EggGroups[groupName] =
        group


    Toggle.MouseButton1Click:Connect(
        function()

            group.Expanded =
                not group.Expanded

            Container.Visible =
                group.Expanded

            GroupFrame.AutomaticSize =
                Enum.AutomaticSize.Y

            if group.Expanded then

                Toggle.Text =
                    "v  " .. groupName

            else

                Toggle.Text =
                    ">  " .. groupName

            end

        end
    )



    return group

end




--==============================================================
-- FLY PATH
--==============================================================

local function getPathWaypoints(startPosition, targetPosition)
    if not isValidPosition(startPosition) or not isValidPosition(targetPosition) then
        return nil
    end

    local path = PathfindingService:CreatePath({
        AgentRadius = 2,
        AgentHeight = 5,
        AgentCanJump = true,
        AgentCanClimb = true,
        WaypointSpacing = 5
    })

    local ok = pcall(function()
        path:ComputeAsync(startPosition, targetPosition)
    end)

    if not ok or path.Status ~= Enum.PathStatus.Success then
        return nil
    end

    local waypoints = path:GetWaypoints()
    if #waypoints == 0 then
        return nil
    end

    return waypoints
end

local function isPathSegmentClear(fromPosition, toPosition, character)
    local direction = toPosition - fromPosition
    local distance = direction.Magnitude
    if distance <= 0.1 then return true end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {character, RenderedEggs}
    params.IgnoreWater = true

    local hit = workspace:Raycast(fromPosition, direction, params)
    return hit == nil
end

local NoclipActive = false
local NoclipOriginalCollision = {}

local function setFlyNoclip(enabled)
    getCharacter()

    if enabled then
        if NoclipActive then
            return
        end

        NoclipOriginalCollision = {}
        if Character and Character.Parent then
            for _, part in ipairs(Character:GetDescendants()) do
                if part:IsA("BasePart") then
                    NoclipOriginalCollision[part] = part.CanCollide
                    part.CanCollide = false
                end
            end
        end
        NoclipActive = true
        return
    end

    if not NoclipActive then
        return
    end

    for part, originalValue in pairs(NoclipOriginalCollision) do
        if part and part.Parent then
            part.CanCollide = originalValue
        end
    end

    NoclipOriginalCollision = {}
    NoclipActive = false
end

local function refreshFlyNoclip()
    if not NoclipActive then
        return
    end

    getCharacter()
    if not Character or not Character.Parent then
        return
    end

    for _, part in ipairs(Character:GetDescendants()) do
        if part:IsA("BasePart") then
            if NoclipOriginalCollision[part] == nil then
                NoclipOriginalCollision[part] = part.CanCollide
            end
            part.CanCollide = false
        end
    end
end


local function flySegment(targetPosition, token)
    getCharacter()
    if not Character or not RootPart or not RootPart.Parent then
        return false, "Character not found"
    end

    local start = RootPart.Position
    if not isValidPosition(start) or not isValidPosition(targetPosition) then
        return false, "Invalid position"
    end

    local distance = (targetPosition - start).Magnitude
    local duration = math.max(distance / math.max(FlySpeed, 1), 0.03)
    local started = os.clock()
    local from = Character:GetPivot()
    local target = CFrame.new(targetPosition, targetPosition + from.LookVector)

    while Running and FlyBusy and token == FlyCancelToken do
        getCharacter()
        refreshFlyNoclip()
        if not RootPart or not Character or not Character.Parent then
            return false, "Character lost"
        end

        local alpha = math.clamp((os.clock() - started) / duration, 0, 1)
        Character:PivotTo(from:Lerp(target, alpha))
        RootPart.AssemblyLinearVelocity = Vector3.zero
        RootPart.AssemblyAngularVelocity = Vector3.zero

        if alpha >= 1 then
            return true
        end
        RunService.Heartbeat:Wait()
    end

    return false, "Fly cancelled"
end

flyToTarget = function(model, afterEgg)
    if FlyBusy then
        return false, "Fly is busy"
    end
    if not model or not model.Parent or not model:IsDescendantOf(RenderedEggs) then
        return false, "Egg no longer exists"
    end

    getCharacter()
    if not Character or not RootPart then
        return false, "Character not found"
    end

    local eggTarget = getEggTopCFrame(model)
    if not eggTarget then
        return false, "Egg is not ready"
    end

    FlyBusy = true
    FlyCancelToken += 1
    local token = FlyCancelToken
    local isVolcanic = string.lower(model.Name) == "volcanic egg"

    -- ONLY Volcanic Egg uses pathfinding and collision stays enabled.
    -- Every other egg uses noclip and flies directly to the egg.
    setFlyNoclip(not isVolcanic)

    FlyStateLabel.Text = isVolcanic
        and "Fly: Finding path  |  Speed: " .. tostring(FlySpeed)
        or "Fly: Noclip  |  Speed: " .. tostring(FlySpeed)
    showStatus("Flying to " .. model.Name, 2)

    local function finish(ok, reason)
        setFlyNoclip(false)
        FlyBusy = false
        FlyStateLabel.Text = ok
            and ("Fly: Ready  |  Speed: " .. tostring(FlySpeed))
            or ("Fly: Stopped  |  Speed: " .. tostring(FlySpeed))
        return ok, reason
    end

    local success = false

    if not isVolcanic then
        -- Other eggs: no pathfinding, no obstacle checks, just noclip direct flight.
        success = flySegment(eggTarget.Position + Vector3.new(0, FlyHeight, 0), token)
    else
        -- Volcanic Egg: pathfinding is mandatory.
        local eggRoot = getRootPart(model)
        local navigationTarget = eggRoot and (eggRoot.Position + Vector3.new(0, 2, 0)) or eggTarget.Position
        local waypoints = getPathWaypoints(RootPart.Position, navigationTarget)

        if not waypoints then
            showStatus("Volcanic Egg: no valid path", 2)
            return finish(false, "No valid path to Volcanic Egg")
        end

        local previousPosition = RootPart.Position
        for _, waypoint in ipairs(waypoints) do
            if token ~= FlyCancelToken then
                return finish(false, "Fly cancelled")
            end

            local waypointPosition = waypoint.Position
            if waypoint.Action == Enum.PathWaypointAction.Jump then
                waypointPosition += Vector3.new(0, 2, 0)
            end

            if not isPathSegmentClear(previousPosition, waypointPosition, Character) then
                showStatus("Volcanic Egg: route blocked", 2)
                return finish(false, "Volcanic route blocked")
            end

            if not flySegment(waypointPosition, token) then
                return finish(false, "Volcanic route failed")
            end
            previousPosition = waypointPosition
        end

        local finalTarget = eggTarget.Position + Vector3.new(0, FlyHeight, 0)
        if not isPathSegmentClear(RootPart.Position, finalTarget, Character) then
            showStatus("Volcanic Egg: final route blocked", 2)
            return finish(false, "Volcanic final route blocked")
        end

        success = flySegment(finalTarget, token)
    end

    if not success then
        if isVolcanic then
            showStatus("Volcanic Egg: route failed, not picked up", 2)
        else
            showStatus("Could not reach " .. model.Name, 2)
        end
        return finish(false, "Could not reach egg")
    end

    if afterEgg and FlyToPlotAfterEgg and token == FlyCancelToken then
        FlyStateLabel.Text = "Fly: Waiting for egg pickup  |  Speed: " .. tostring(FlySpeed)
        showStatus("Waiting for " .. model.Name .. " to be picked up", 3)

        local pickupDeadline = os.clock() + 8
        while Running and FlyBusy and token == FlyCancelToken and os.clock() < pickupDeadline do
            if not model.Parent or not model:IsDescendantOf(RenderedEggs) then
                break
            end
            RunService.Heartbeat:Wait()
        end

        if isVolcanic and model.Parent and model:IsDescendantOf(RenderedEggs) then
            return finish(false, "Volcanic Egg was not picked up")
        end

        if Running and FlyBusy and token == FlyCancelToken then
            local baseplate = getMyPlotBaseplate()
            if baseplate then
                local plotTarget = getBaseplateTopCFrame(baseplate)
                if plotTarget then
                    FlyStateLabel.Text = "Fly: Returning to My Plot  |  Speed: " .. tostring(FlySpeed)
                    local teleported, reason = safeTeleport(Character, RootPart, plotTarget)
                    if not teleported then
                        return finish(false, "Plot teleport failed: " .. tostring(reason))
                    end
                else
                    return finish(false, "Plot target is invalid")
                end
            else
                return finish(false, "My Plot was not found")
            end
        end
    end

    return finish(true)
end

--==============================================================
-- CREATE EGG ENTRY
--==============================================================

local function createEggEntry(model)

    if EggEntries[model] then
        return
    end


    if not model
        or not model:IsA("Model")
        or not model.Parent then

        return

    end


    local group =
        createEggGroup(
            model.Name
        )


    group.Eggs[model] = true

    local rarity = getEggRarity(model)
    if rarity then
        group.Rarity = rarity
    end

    updateGroupLayoutOrder(group)

    if rarity and not group.RarityLabelInitialized then
        group.Rarity = rarity

        local info = getRarityInfo(rarity)
        local header = group.GroupFrame and group.GroupFrame:FindFirstChild("Header")
        local rarityLabel = header and header:FindFirstChild("Rarity")

        if info then
            group.RarityOrder = info.Order
            group.RarityColor = info.Color
        end

        if rarityLabel then
            rarityLabel.Text = rarity
            rarityLabel.TextColor3 = info and info.Color or Color3.fromRGB(190, 195, 205)
        end

        group.RarityLabelInitialized = true
        updateGroupLayoutOrder(group)
    end


    local Row =
        Instance.new("Frame")

    Row.Name =
        "Egg"

    Row.Size =
        UDim2.new(
            1,
            -4,
            0,
            32
        )

    Row.BackgroundColor3 =
        Color3.fromRGB(
            35,
            36,
            46
        )

    Row.BorderSizePixel = 0

    Row.Parent =
        group.Container


    local RowCorner =
        Instance.new("UICorner")

    RowCorner.CornerRadius =
        UDim.new(0, 6)

    RowCorner.Parent =
        Row


    local NameLabel =
        Instance.new("TextLabel")

    NameLabel.Size =
        UDim2.new(
            1,
            -72,
            1,
            0
        )

    NameLabel.Position =
        UDim2.new(
            0,
            8,
            0,
            0
        )

    NameLabel.BackgroundTransparency = 1

    NameLabel.Text =
        model.Name

    NameLabel.TextColor3 =
        Color3.fromRGB(
            220,
            222,
            235
        )

    NameLabel.TextXAlignment =
        Enum.TextXAlignment.Left

    NameLabel.Font =
        Enum.Font.Gotham

    NameLabel.TextSize = 12

    NameLabel.TextTruncate =
        Enum.TextTruncate.AtEnd

    NameLabel.Parent =
        Row


    local TP = Instance.new("TextButton")
    TP.Size = UDim2.new(0, 40, 0, 26)
    TP.Position = UDim2.new(1, -87, 0, 3)
    TP.BackgroundColor3 = Color3.fromRGB(72, 155, 105)
    TP.Text = "TP"
    TP.TextColor3 = Color3.fromRGB(255,255,255)
    TP.Font = Enum.Font.GothamBold
    TP.TextSize = 10
    TP.Parent = Row
    local TPCorner = Instance.new("UICorner")
    TPCorner.CornerRadius = UDim.new(0, 6)
    TPCorner.Parent = TP

    local FlyButton = Instance.new("TextButton")
    FlyButton.Size = UDim2.new(0, 40, 0, 26)
    FlyButton.Position = UDim2.new(1, -44, 0, 3)
    FlyButton.BackgroundColor3 = Color3.fromRGB(77, 97, 175)
    FlyButton.Text = "FLY"
    FlyButton.TextColor3 = Color3.fromRGB(255,255,255)
    FlyButton.Font = Enum.Font.GothamBold
    FlyButton.TextSize = 10
    FlyButton.Parent = Row
    local FlyCorner = Instance.new("UICorner")
    FlyCorner.CornerRadius = UDim.new(0, 6)
    FlyCorner.Parent = FlyButton

    local entry = {

        Model = model,

        Frame = Row,

        Label = NameLabel

    }


    EggEntries[model] =
        entry


    TP.MouseButton1Click:Connect(function()
        if not Running or not model.Parent then return end
        getCharacter()
        local target = getEggTopCFrame(model)
        if not Character or not RootPart or not target then
            showStatus("Egg is not ready")
            return
        end
        local ok, reason = safeTeleport(Character, RootPart, target)
        if ok then
            showStatus("TP -> " .. model.Name, 1.5)
        else
            showStatus("TP failed: " .. tostring(reason), 2)
        end
    end)

    FlyButton.MouseButton1Click:Connect(function()
        if not Running then return end
        if FlyBusy then
            FlyCancelToken += 1
            FlyBusy = false
            FlyStateLabel.Text = "Fly: Cancelled  |  Speed: " .. tostring(FlySpeed)
            showStatus("Fly cancelled")
            FlyButton.Text = "FLY"
            return
        end
        FlyButton.Text = "STOP"
        task.spawn(function()
            flyToTarget(model, true)
            if FlyButton and FlyButton.Parent then FlyButton.Text = "FLY" end
        end)
    end)

end


--==============================================================
-- REGISTER MODEL
--==============================================================

local function registerModel(model)

    if not Running then
        return
    end


    if not model
        or not model:IsA("Model")
        or not model.Parent then

        return

    end


    if not model:IsDescendantOf(
        RenderedEggs
    ) then

        return

    end


    if not EggEntries[model] then

        createEggEntry(model)

    end


    if not ESPs[model] then

        createESP(model)

    end


    if updateSearch then
        updateSearch()
    end

end


--==============================================================
-- SUPER VISUAL OPTIMIZATION
--==============================================================

local OptimizationState = setmetatable({}, {__mode = "k"})
local LightingOptimizationState = {}
local TerrainOptimizationState = nil

local function rememberObjectState(obj, key, value)
    local state = OptimizationState[obj]
    if not state then
        state = {}
        OptimizationState[obj] = state
    end
    if state[key] == nil then
        state[key] = value
    end
end

local function optimizeObject(obj)
    if not obj then return end

    if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam")
        or obj:IsA("Smoke") or obj:IsA("Fire") or obj:IsA("Sparkles") then
        pcall(function()
            rememberObjectState(obj, "Enabled", obj.Enabled)
            obj.Enabled = false
        end)
        return
    end

    if obj:IsA("PostEffect") then
        pcall(function()
            rememberObjectState(obj, "Enabled", obj.Enabled)
            obj.Enabled = false
        end)
        return
    end

    if obj:IsA("SurfaceAppearance") then
        pcall(function()
            rememberObjectState(obj, "Parent", obj.Parent)
            obj.Parent = nil
        end)
        return
    end

    if obj:IsA("Decal") or obj:IsA("Texture") then
        pcall(function()
            rememberObjectState(obj, "Transparency", obj.Transparency)
            obj.Transparency = 1
        end)
        return
    end

    if obj:IsA("BasePart") then
        pcall(function()
            rememberObjectState(obj, "CastShadow", obj.CastShadow)
            rememberObjectState(obj, "Reflectance", obj.Reflectance)
            rememberObjectState(obj, "Material", obj.Material)
            obj.CastShadow = false
            obj.Reflectance = 0
            obj.Material = Enum.Material.Plastic
        end)

        if obj:IsA("MeshPart") then
            pcall(function()
                rememberObjectState(obj, "TextureID", obj.TextureID)
                obj.TextureID = ""
            end)
        end
    elseif obj:IsA("SpecialMesh") then
        pcall(function()
            rememberObjectState(obj, "TextureId", obj.TextureId)
            obj.TextureId = ""
        end)
    end
end

local function restoreObject(obj)
    local state = OptimizationState[obj]
    if not state then return end

    pcall(function()
        if state.Enabled ~= nil and obj.Parent then obj.Enabled = state.Enabled end
    end)
    pcall(function()
        if state.Transparency ~= nil and obj.Parent then obj.Transparency = state.Transparency end
    end)
    pcall(function()
        if state.CastShadow ~= nil and obj.Parent then obj.CastShadow = state.CastShadow end
        if state.Reflectance ~= nil and obj.Parent then obj.Reflectance = state.Reflectance end
        if state.Material ~= nil and obj.Parent then obj.Material = state.Material end
    end)
    pcall(function()
        if state.TextureID ~= nil and obj.Parent then obj.TextureID = state.TextureID end
        if state.TextureId ~= nil and obj.Parent then obj.TextureId = state.TextureId end
    end)
    pcall(function()
        if state.Parent and obj.Parent == nil then obj.Parent = state.Parent end
    end)

    OptimizationState[obj] = nil
end

local function applyWorldOptimization()
    for _, obj in ipairs(workspace:GetDescendants()) do
        optimizeObject(obj)
    end

    local Lighting = game:GetService("Lighting")
    for _, effect in ipairs(Lighting:GetChildren()) do
        if effect:IsA("PostEffect") or effect:IsA("Atmosphere") or effect:IsA("Clouds") then
            if not LightingOptimizationState[effect] then
                LightingOptimizationState[effect] = {
                    Enabled = (effect:IsA("PostEffect") or effect:IsA("Clouds")) and effect.Enabled or nil,
                    Density = effect:IsA("Atmosphere") and effect.Density or nil,
                    Haze = effect:IsA("Atmosphere") and effect.Haze or nil,
                    Glare = effect:IsA("Atmosphere") and effect.Glare or nil,
                }
            end
            pcall(function()
                if effect:IsA("PostEffect") or effect:IsA("Clouds") then effect.Enabled = false end
                if effect:IsA("Atmosphere") then
                    effect.Density = 0
                    effect.Haze = 0
                    effect.Glare = 0
                end
            end)
        end
    end

    pcall(function()
        if LightingOptimizationState._Lighting == nil then
            LightingOptimizationState._Lighting = {
                GlobalShadows = Lighting.GlobalShadows,
                EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
                EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
            }
        end
        Lighting.GlobalShadows = false
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
    end)

    pcall(function()
        local terrain = workspace:FindFirstChildOfClass("Terrain")
        if terrain then
            if not TerrainOptimizationState then
                TerrainOptimizationState = {
                    Decoration = terrain.Decoration,
                    WaterWaveSize = terrain.WaterWaveSize,
                    WaterWaveSpeed = terrain.WaterWaveSpeed,
                    WaterReflectance = terrain.WaterReflectance,
                }
            end
            terrain.Decoration = false
            terrain.WaterWaveSize = 0
            terrain.WaterWaveSpeed = 0
            terrain.WaterReflectance = 0
        end
    end)
end

local function restoreWorldOptimization()
    for obj in pairs(OptimizationState) do
        restoreObject(obj)
    end

    local Lighting = game:GetService("Lighting")
    for effect, state in pairs(LightingOptimizationState) do
        if effect ~= "_Lighting" and effect and effect.Parent then
            pcall(function()
                if state.Enabled ~= nil then effect.Enabled = state.Enabled end
                if state.Density ~= nil then effect.Density = state.Density end
                if state.Haze ~= nil then effect.Haze = state.Haze end
                if state.Glare ~= nil then effect.Glare = state.Glare end
            end)
        end
    end

    local lightState = LightingOptimizationState._Lighting
    if lightState then
        pcall(function()
            Lighting.GlobalShadows = lightState.GlobalShadows
            Lighting.EnvironmentDiffuseScale = lightState.EnvironmentDiffuseScale
            Lighting.EnvironmentSpecularScale = lightState.EnvironmentSpecularScale
        end)
    end

    local terrain = workspace:FindFirstChildOfClass("Terrain")
    if terrain and TerrainOptimizationState then
        pcall(function()
            terrain.Decoration = TerrainOptimizationState.Decoration
            terrain.WaterWaveSize = TerrainOptimizationState.WaterWaveSize
            terrain.WaterWaveSpeed = TerrainOptimizationState.WaterWaveSpeed
            terrain.WaterReflectance = TerrainOptimizationState.WaterReflectance
        end)
    end
end

setSuperOptimization = function(enabled)
    SUPER_OPTIMIZE = enabled == true

    if SUPER_OPTIMIZE then
        applyWorldOptimization()
    else
        restoreWorldOptimization()
        OptimizationState = setmetatable({}, {__mode = "k"})
        LightingOptimizationState = {}
        TerrainOptimizationState = nil
    end

    if SuperOptimizeButton and SuperOptimizeButton.Parent then
        SuperOptimizeButton.Text = SUPER_OPTIMIZE and "SUPER OPTIMIZE: ON" or "SUPER OPTIMIZE: OFF"
        SuperOptimizeButton.BackgroundColor3 = SUPER_OPTIMIZE and Color3.fromRGB(60,145,90) or Color3.fromRGB(145,65,75)
    end
end

setSuperOptimization(SUPER_OPTIMIZE)

-- Compatibility wrapper used by the egg-spawn handler.
-- The optimization implementation is optimizeObject().
applySuperOptimization = function(object)
    if SUPER_OPTIMIZE and object then
        optimizeObject(object)
        for _, descendant in ipairs(object:GetDescendants()) do
            optimizeObject(descendant)
        end
    end
end

Connections.OptimizationDescendantAdded = workspace.DescendantAdded:Connect(function(obj)
    if SUPER_OPTIMIZE then
        task.defer(function()
            if SUPER_OPTIMIZE and obj and obj.Parent then
                optimizeObject(obj)
            end
        end)
    end
end)

--==============================================================
-- NEW EGG SPAWN HANDLER
--==============================================================

local function tryRegisterEgg(object)

    if not Running then
        return
    end


    if not object
        or not object:IsA("Model") then

        return

    end


    if not object:IsDescendantOf(
        RenderedEggs
    ) then

        return

    end


    task.defer(function()

        if not Running
            or not object.Parent
            or not object:IsDescendantOf(
                RenderedEggs
            ) then

            return

        end


        local deadline =
            os.clock() + 2


        repeat

            if not Running
                or not object.Parent
                or not object:IsDescendantOf(
                    RenderedEggs
                ) then

                return

            end


            if getRootPart(object) then
                break
            end


            task.wait(0.05)

        until os.clock() >= deadline


        if not Running
            or not object.Parent
            or not object:IsDescendantOf(
                RenderedEggs
            ) then

            return

        end


        if SUPER_OPTIMIZE then
            applySuperOptimization(object)
        end
        registerModel(object)

    end)

end


--==============================================================
-- INITIAL SCAN
--==============================================================

for _, object in ipairs(
    RenderedEggs:GetDescendants()
) do

    if object:IsA("Model") then

        registerModel(object)

    end

end


--==============================================================
-- NEW DESCENDANTS
--==============================================================

Connections.DescendantAdded =
    RenderedEggs.DescendantAdded:Connect(
        function(object)

            tryRegisterEgg(object)

        end
    )


--==============================================================
-- EGG TOP CFRAME
--==============================================================

getEggTopCFrame = function(egg)

    if not egg
        or not egg:IsA("Model")
        or not egg.Parent then

        return nil

    end


    local cf, size =
        egg:GetBoundingBox()


    if not isValidPosition(
        cf.Position
    ) then

        return nil

    end


    if not isFiniteNumber(size.Y)
        or size.Y <= 0 then

        return nil

    end


    local targetPosition =
        Vector3.new(
            cf.Position.X,
            cf.Position.Y
                + (size.Y * 0.5)
                + HEIGHT_OFFSET,
            cf.Position.Z
        )


    if not isValidPosition(
        targetPosition
    ) then

        return nil

    end


    return CFrame.new(
        targetPosition
    )

end


--==============================================================
-- SAFE TELEPORT
--==============================================================

safeTeleport = function(
    character,
    root,
    targetCFrame
)

    if not character
        or not character.Parent then

        return false,
            "Character is invalid"

    end


    if not root
        or not root.Parent then

        return false,
            "RootPart is invalid"

    end


    if not targetCFrame then

        return false,
            "Target is invalid"

    end


    local targetPosition =
        targetCFrame.Position


    if not isValidPosition(
        targetPosition
    ) then

        return false,
            "Target position is invalid"

    end


    -- No distance check is performed.
    -- Teleport directly to the target position.

    root.AssemblyLinearVelocity =
        Vector3.zero

    root.AssemblyAngularVelocity =
        Vector3.zero


    character:PivotTo(
        targetCFrame
    )


    root.AssemblyLinearVelocity =
        Vector3.zero

    root.AssemblyAngularVelocity =
        Vector3.zero


    return true

end


--==============================================================
-- FIND MY PLOT
--==============================================================

local function scanMyPlot()

    if not Plots then
        return nil
    end


    if PlotScanCount >=
        MAX_PLOT_SCANS then

        return CachedMyPlot

    end


    PlotScanCount += 1

    CachedMyPlot = nil
    CachedBaseplate = nil


    for _, plot in ipairs(
        Plots:GetChildren()
    ) do

        local data =
            plot:FindFirstChild(
                "Data"
            )


        if data then

            local owner =
                data:FindFirstChild(
                    "Owner"
                )


            if owner
                and owner:IsA(
                    "ObjectValue"
                )
                and owner.Value ==
                    LocalPlayer then


                CachedMyPlot =
                    plot


                local baseplate =
                    plot:FindFirstChild(
                        "Baseplate"
                    )


                if not baseplate then

                    baseplate =
                        plot:FindFirstChild(
                            "Baseplate",
                            true
                        )

                end


                if baseplate
                    and baseplate:IsA(
                        "BasePart"
                    ) then

                    CachedBaseplate =
                        baseplate

                end


                break

            end

        end

    end


    return CachedMyPlot

end


--==============================================================
-- GET MY PLOT
--==============================================================

local function getMyPlot()

    if CachedMyPlot
        and CachedMyPlot.Parent then


        local data =
            CachedMyPlot:FindFirstChild(
                "Data"
            )


        local owner =
            data
            and data:FindFirstChild(
                "Owner"
            )


        if owner
            and owner:IsA(
                "ObjectValue"
            )
            and owner.Value ==
                LocalPlayer then

            return CachedMyPlot

        end

    end


    return scanMyPlot()

end


--==============================================================
-- GET BASEPLATE
--==============================================================

getMyPlotBaseplate = function()

    local plot =
        getMyPlot()


    if not plot then
        return nil
    end


    if CachedBaseplate
        and CachedBaseplate.Parent
        and CachedBaseplate:IsDescendantOf(
            plot
        ) then

        return CachedBaseplate

    end


    local baseplate =
        plot:FindFirstChild(
            "Baseplate"
        )


    if not baseplate then

        baseplate =
            plot:FindFirstChild(
                "Baseplate",
                true
            )

    end


    if baseplate
        and baseplate:IsA(
            "BasePart"
        ) then

        CachedBaseplate =
            baseplate

        return baseplate

    end


    return nil

end


--==============================================================
-- BASEPLATE TOP
--==============================================================

getBaseplateTopCFrame = function(
    baseplate
)

    if not baseplate
        or not baseplate:IsA("BasePart")
        or not baseplate.Parent then

        return nil

    end


    local size =
        baseplate.Size

    local cf =
        baseplate.CFrame


    if not isFiniteNumber(size.Y)
        or size.Y <= 0 then

        return nil

    end


    if not isValidPosition(
        cf.Position
    ) then

        return nil

    end


    local verticalOffset =
        (size.Y * 0.5)
        + HEIGHT_OFFSET


    local target =
        cf * CFrame.new(
            0,
            verticalOffset,
            0
        )


    if not isValidPosition(
        target.Position
    ) then

        return nil

    end


    return target

end


--==============================================================
-- GLOBAL ESP BUTTON
--==============================================================

GlobalToggle.MouseButton1Click:Connect(
    function()

        GlobalESPEnabled =
            not GlobalESPEnabled


        if GlobalESPEnabled then

            GlobalToggle.Text =
                "ESP  |  ON"

            GlobalToggle.BackgroundColor3 =
                Color3.fromRGB(
                    60,
                    155,
                    95
                )

        else

            GlobalToggle.Text =
                "ESP  |  OFF"

            GlobalToggle.BackgroundColor3 =
                Color3.fromRGB(
                    145,
                    65,
                    75
                )

        end


        for model, esp in pairs(
            ESPs
        ) do

            if esp then

                local group =
                    EggGroups[
                        model.Name
                    ]


                local enabled =
                    GlobalESPEnabled and getEggTypeEnabled(model)


                esp.Billboard.Enabled =
                    enabled


                if esp.Highlight then

                    esp.Highlight.Enabled =
                        enabled

                end

            end

        end

    end
)


--==============================================================
-- TP MY PLOT
--==============================================================

PlotTP.MouseButton1Click:Connect(
    function()

        if not Running then
            return
        end


        getCharacter()


        if not Character
            or not RootPart then

            showStatus(
                "Character not found"
            )

            return

        end


        local baseplate =
            getMyPlotBaseplate()


        if not baseplate then

            showStatus(
                "Your Plot was not found"
            )

            return

        end


        local target =
            getBaseplateTopCFrame(
                baseplate
            )


        if not target then

            showStatus(
                "Invalid Baseplate"
            )

            return

        end


        local success, reason =
            safeTeleport(
                Character,
                RootPart,
                target
            )


        if success then

            showStatus(
                "Teleported to My Plot"
            )

        else

            showStatus(
                "Teleport failed: "
                .. tostring(reason)
            )

        end

    end
)


--==============================================================


--==============================================================
-- SEARCH
--==============================================================

updateSearch = function()

    local query =
        string.lower(
            Search.Text or ""
        )

    local groupHasMatch = {}

    for model, entry in pairs(EggEntries) do
        if entry and entry.Model and entry.Frame and entry.Model.Parent then
            local name =
                string.lower(
                    entry.Model.Name
                )

            local matches =
                query == ""
                or string.find(
                    name,
                    query,
                    1,
                    true
                ) ~= nil

            entry.Frame.Visible = matches

            local group =
                EggGroups[entry.Model.Name]

            if group and matches then
                groupHasMatch[group] = true
            end
        elseif entry and entry.Frame then
            entry.Frame.Visible = false
        end
    end

    for _, group in pairs(EggGroups) do
        if query == "" then
            group.GroupFrame.Visible = true
        else
            group.GroupFrame.Visible = groupHasMatch[group] == true
        end
    end


end


Search:GetPropertyChangedSignal(
    "Text"
):Connect(
    updateSearch
)


--==============================================================
-- AUTO FARM ENGINE
--==============================================================

runAutoFarm = function()
    if AutoFarmBusy or not AutoFarmEnabled or not Running then return end
    AutoFarmBusy = true
    AutoFarmToken += 1
    local token = AutoFarmToken

    local ok, err = pcall(function()
        while Running and AutoFarmEnabled and token == AutoFarmToken do
            getCharacter()
            local origin = RootPart and RootPart.Position
            local egg = nil
            local bestDistance = math.huge

            if origin then
                for model in pairs(EggEntries) do
                    if model and model.Parent and model:IsDescendantOf(RenderedEggs) then
                        local targetAllowed = AutoFarmTargetAll
                        if not targetAllowed then
                            targetAllowed = AutoFarmTargets[string.lower(model.Name)] == true
                        end

                        if targetAllowed then
                            local root = getRootPart(model)
                            if root then
                                local distance = (origin - root.Position).Magnitude
                                if distance < bestDistance then
                                    egg = model
                                    bestDistance = distance
                                end
                            end
                        end
                    end
                end
            end

            if not egg then
                if AutoFarmListOpen then refreshAutoFarmRows() end
                task.wait(0.35)
                continue
            end

            if AutoFarmMode == "TP" then
                getCharacter()
                local target = getEggTopCFrame(egg)
                if Character and RootPart and target then
                    local teleported = safeTeleport(Character, RootPart, target)
                    if teleported then
                        showStatus("Auto TP -> " .. egg.Name, 0.8)
                    end
                end
                task.wait(AutoFarmDelay)
            else
                -- Run Fly synchronously so Auto Farm never starts multiple
                -- Fly jobs for the same egg and never loses track of FlyBusy.
                if not FlyBusy then
                    flyToTarget(egg, true)
                    task.wait(AutoFarmDelay)
                else
                    task.wait(0.08)
                end
            end
        end
    end)

    if not ok then
        warn("[AutoFarm] " .. tostring(err))
        FlyBusy = false
    end

    AutoFarmBusy = false
end


--==============================================================
-- UPDATE LOOP
--==============================================================

task.spawn(function()

    while Running do

        getCharacter()


        local root =
            RootPart



        for model, esp in pairs(
            ESPs
        ) do


            if not model
                or not model.Parent
                or not model:IsDescendantOf(
                    RenderedEggs
                ) then


                destroyESP(model)


                local entry =
                    EggEntries[model]


                if entry then

                    if entry.Frame then
                        entry.Frame:Destroy()
                    end

                    EggEntries[model] =
                        nil

                end


                local group =
                    EggGroups[
                        model.Name
                    ]


                if group then
                    group.Eggs[model] =
                        nil

                    if next(group.Eggs) then
                    else
                        group.GroupFrame:Destroy()
                        EggGroups[model.Name] = nil
                    end
                end


            else


                local eggRoot =
                    getRootPart(model)


                if eggRoot then


                    local distance = 0


                    if root then

                        distance =
                            (
                                root.Position
                                - eggRoot.Position
                            ).Magnitude

                    end


                    local group =
                        EggGroups[
                            model.Name
                        ]


                    local enabled =
                        GlobalESPEnabled and getEggTypeEnabled(model)


                    esp.Billboard.Enabled =
                        enabled


                    local rarityInfo = getManualRarity(model.Name)
                    local rarityColor = rarityInfo and rarityInfo.Color or Color3.fromRGB(220, 220, 230)
                    esp.Label.TextColor3 = rarityColor

                    if esp.Highlight then
                        esp.Highlight.FillColor = rarityColor
                        esp.Highlight.OutlineColor = rarityColor
                        esp.Highlight.Enabled =
                            enabled
                    end


                    esp.Label.Text = getESPDisplayText(model, rarityInfo, root and distance or nil)


                    local entry =
                        EggEntries[model]


                    if entry then

                        if root then

                            entry.Label.Text =
                                model.Name
                                .. "  ["
                                .. math.floor(
                                    distance
                                )
                                .. " studs]"

                        else

                            entry.Label.Text =
                                model.Name

                        end


                    end

                end

            end

        end


        if Status.Visible
            and os.clock() >= StatusExpiresAt then

            Status.Visible = false
            Status.Text = ""
        end


        task.wait(
            UPDATE_RATE
        )

    end

end)


--==============================================================
-- SHUTDOWN
--==============================================================

shutdown = function()

    if not Running then
        return
    end


    Running = false
    AutoFarmEnabled = false
    AutoFarmToken += 1
    FlyCancelToken += 1
    FlyBusy = false


    for model in pairs(
        ESPs
    ) do

        destroyESP(model)

    end


    for _, connection in pairs(
        Connections
    ) do

        if connection then

            pcall(function()
                connection:Disconnect()
            end)

        end

    end


    if ScreenGui then
        ScreenGui:Destroy()
    end

end


Minimize.MouseButton1Click:Connect(
    function()
        MainMinimized = not MainMinimized

        local position = Main.Position
        local halfHeightDifference =
            (MainExpandedSize.Y.Offset - MINIMIZED_HEIGHT)
            * MainScale.Scale
            * 0.5

        if MainMinimized then
            dragging = false
            resizing = false
            ResizeHandle.Visible = false

            Main.Position = UDim2.new(
                position.X.Scale,
                position.X.Offset,
                position.Y.Scale,
                position.Y.Offset - halfHeightDifference
            )

            Main.Size = UDim2.new(
                MainExpandedSize.X.Scale,
                MainExpandedSize.X.Offset,
                0,
                MINIMIZED_HEIGHT
            )

            Minimize.Text = "+"
        else
            ResizeHandle.Visible = true
            Main.Size = MainExpandedSize

            Main.Position = UDim2.new(
                position.X.Scale,
                position.X.Offset,
                position.Y.Scale,
                position.Y.Offset + halfHeightDifference
            )

            Minimize.Text = "-"
        end
    end
)


Close.MouseButton1Click:Connect(
    shutdown
)


--==============================================================
-- START
--==============================================================

print(
    "[Rendered Eggs] ESP + Fly loaded"
)
