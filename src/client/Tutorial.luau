--!strict
-- src/client/Tutorial.luau
-- Short, visual, guided tutorial. Shows a Yes/No prompt first, then walks
-- through 10 steps. Each step has a one-line instruction + big emoji icon,
-- a step counter, and (where applicable) a highlighted element with a
-- bouncing arrow pointer.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Hud = require(script.Parent.Hud)

local Tutorial = {}

-- Theme
local COLOR_BG = Color3.fromRGB(20, 15, 10)
local COLOR_ACCENT = Color3.fromRGB(212, 165, 116)
local COLOR_ACCENT_BRIGHT = Color3.fromRGB(232, 194, 143)
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_TEXT_DIM = Color3.fromRGB(200, 180, 140)
local COLOR_HIGHLIGHT = Color3.fromRGB(255, 215, 100)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type Step = {
	icon: string,
	text: string,
	target: string?,
	manual: boolean?,
	conditionName: string?,
}

-- --- Step list ---

local function buildSteps(): { Step }
	return {
		{ icon = "👋", text = "Welcome! Let's get started.", manual = true },
		{ icon = "📊", text = "Your stats live here.", target = "SidePanel", manual = true },
		{
			icon = "🏹",
			text = "Pick a tower.",
			target = "TowerPanel",
			conditionName = "towerSelected",
		},
		{
			icon = "🗺️",
			text = "Click a grass cell to place it.",
			conditionName = "towerPlaced",
		},
		{
			icon = "⚔️",
			text = "Start the wave!",
			target = "WaveBtn",
			conditionName = "waveStarted",
		},
		{ icon = "🏰", text = "Defend the castle!", manual = true },
		{ icon = "🎒", text = "Right-click a placed tower to pick it up.", manual = true },
		{
			icon = "📦",
			text = "Open your inventory.",
			target = "InventoryBtn",
			conditionName = "inventoryOpened",
		},
		{
			icon = "💰",
			text = "Sell or re-place items from here.",
			target = "InventoryPanel",
			manual = true,
		},
		{ icon = "✨", text = "You're ready. Good luck!", manual = true },
	}
end

-- --- State ---

local screen: ScreenGui? = nil
local tooltipIcon: TextLabel? = nil
local tooltipText: TextLabel? = nil
local counterLabel: TextLabel? = nil
local nextBtn: TextButton? = nil
local pointerLabel: TextLabel? = nil
local heartbeatConn: RBXScriptConnection? = nil

local currentStepIndex = 0
local steps: { Step } = {}
local stepStartTowerCount = 0
local stepStartWaveNum = 0
local onCompleteCallback: (() -> ())? = nil

-- --- Helpers ---

local function addCorner(inst: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function addStroke(inst: GuiObject, color: Color3, thickness: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = inst
	return s
end

-- --- Overlay builder ---

local function buildOverlay()
	screen = Instance.new("ScreenGui")
	screen.Name = "TutorialOverlay"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 50
	screen.Parent = playerGui

	-- Big bouncing arrow pointer. Parented inside the Hud ScreenGui so
	-- AbsolutePosition math is in the same coordinate space as the HUD
	-- elements we're pointing at (avoids any cross-ScreenGui inset mismatch).
	local hudScreen = Hud.getScreen() or screen

	local pl = Instance.new("TextLabel")
	pl.Name = "TutorialPointer"
	pl.AnchorPoint = Vector2.new(0, 0)
	pl.Size = UDim2.fromOffset(120, 120)
	pl.BackgroundTransparency = 1
	pl.Text = "⬇"
	pl.Font = Enum.Font.GothamBlack
	pl.TextSize = 90
	pl.TextColor3 = COLOR_HIGHLIGHT
	pl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	pl.TextStrokeTransparency = 0
	pl.Visible = false
	pl.ZIndex = 500
	pl.Parent = hudScreen
	pointerLabel = pl

	-- Compact tooltip (560x140) pinned top-center
	local tf = Instance.new("Frame")
	tf.Name = "Tooltip"
	tf.Size = UDim2.fromOffset(560, 140)
	tf.Position = UDim2.new(0.5, -280, 0, 36)
	tf.BackgroundColor3 = COLOR_BG
	tf.BackgroundTransparency = 0.05
	tf.BorderSizePixel = 0
	tf.Parent = screen
	addCorner(tf, 14)
	addStroke(tf, COLOR_ACCENT, 3)

	-- Step counter (top-left)
	counterLabel = Instance.new("TextLabel")
	counterLabel.Name = "Counter"
	counterLabel.Size = UDim2.fromOffset(140, 22)
	counterLabel.Position = UDim2.fromOffset(16, 10)
	counterLabel.BackgroundTransparency = 1
	counterLabel.Text = "STEP 1 / 10"
	counterLabel.Font = Enum.Font.GothamBold
	counterLabel.TextSize = 12
	counterLabel.TextColor3 = COLOR_ACCENT_BRIGHT
	counterLabel.TextXAlignment = Enum.TextXAlignment.Left
	counterLabel.Parent = tf

	-- Skip (top-right)
	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.Size = UDim2.fromOffset(90, 26)
	skip.Position = UDim2.new(1, -106, 0, 8)
	skip.Text = "SKIP"
	skip.Font = Enum.Font.GothamBold
	skip.TextSize = 11
	skip.TextColor3 = COLOR_TEXT_DIM
	skip.BackgroundColor3 = Color3.fromRGB(40, 30, 20)
	skip.BorderSizePixel = 0
	skip.AutoButtonColor = false
	skip.Parent = tf
	addCorner(skip, 6)
	addStroke(skip, COLOR_ACCENT, 1)
	skip.Activated:Connect(function()
		Tutorial.finish()
	end)

	-- Big icon on the left
	tooltipIcon = Instance.new("TextLabel")
	tooltipIcon.Name = "Icon"
	tooltipIcon.Size = UDim2.fromOffset(80, 80)
	tooltipIcon.Position = UDim2.fromOffset(20, 40)
	tooltipIcon.BackgroundTransparency = 1
	tooltipIcon.Text = "👋"
	tooltipIcon.Font = Enum.Font.GothamBlack
	tooltipIcon.TextSize = 56
	tooltipIcon.Parent = tf

	-- Instruction text (right of icon)
	tooltipText = Instance.new("TextLabel")
	tooltipText.Name = "Text"
	tooltipText.Size = UDim2.fromOffset(320, 80)
	tooltipText.Position = UDim2.fromOffset(110, 40)
	tooltipText.BackgroundTransparency = 1
	tooltipText.Text = ""
	tooltipText.Font = Enum.Font.GothamBold
	tooltipText.TextSize = 22
	tooltipText.TextColor3 = COLOR_TEXT
	tooltipText.TextWrapped = true
	tooltipText.TextXAlignment = Enum.TextXAlignment.Left
	tooltipText.TextYAlignment = Enum.TextYAlignment.Center
	tooltipText.Parent = tf

	-- Next button (visible only on manual steps)
	local nb = Instance.new("TextButton")
	nb.Name = "Next"
	nb.Size = UDim2.fromOffset(110, 44)
	nb.Position = UDim2.new(1, -126, 1, -56)
	nb.Text = "NEXT  →"
	nb.Font = Enum.Font.GothamBold
	nb.TextSize = 16
	nb.TextColor3 = COLOR_TEXT
	nb.BackgroundColor3 = Color3.fromRGB(109, 58, 16)
	nb.BorderSizePixel = 0
	nb.AutoButtonColor = false
	nb.Parent = tf
	addCorner(nb, 8)
	addStroke(nb, COLOR_ACCENT_BRIGHT, 2)
	nextBtn = nb
	nb.Activated:Connect(function()
		Tutorial._advance()
	end)
end

-- --- Pointer update ---

local function updatePointer(targetName: string?)
	if not pointerLabel then
		return
	end
	if not targetName then
		pointerLabel.Visible = false
		return
	end
	local target = Hud.getElement(targetName)
	if not target or not target:IsA("GuiObject") then
		pointerLabel.Visible = false
		return
	end

	local camera = workspace.CurrentCamera
	local screenH = camera and camera.ViewportSize.Y or 720

	local targetTop = target.AbsolutePosition.Y
	local targetBottom = target.AbsolutePosition.Y + target.AbsoluteSize.Y
	local targetCenterX = target.AbsolutePosition.X + target.AbsoluteSize.X / 2

	-- If target is in the top portion of the screen, point up from below;
	-- otherwise point down from above
	local bounce = math.sin(os.clock() * 5) * 6
	if targetTop < screenH * 0.35 then
		pointerLabel.Text = "⬆"
		pointerLabel.Position = UDim2.fromOffset(targetCenterX - 40, targetBottom + 14 + bounce)
	else
		pointerLabel.Text = "⬇"
		pointerLabel.Position = UDim2.fromOffset(targetCenterX - 40, targetTop - 90 - bounce)
	end
	pointerLabel.Visible = true
end

-- --- Condition checks ---

local function checkCondition(name: string): boolean
	if name == "towerSelected" then
		return Hud.getSelection().towerType ~= ""
	elseif name == "towerPlaced" then
		local folder = workspace:FindFirstChild("Towers")
		return folder ~= nil and #folder:GetChildren() > stepStartTowerCount
	elseif name == "waveStarted" then
		local state = Hud.getState()
		return state ~= nil and state.waveNum > stepStartWaveNum
	elseif name == "inventoryOpened" then
		local panel = Hud.getElement("InventoryPanel")
		return panel ~= nil and panel.Visible == true
	end
	return false
end

-- --- Step dispatch ---

local function showStep(index: number)
	local step = steps[index]
	if not step then
		Tutorial.finish()
		return
	end

	if tooltipText then
		tooltipText.Text = step.text
	end
	if tooltipIcon then
		tooltipIcon.Text = step.icon
	end
	if counterLabel then
		counterLabel.Text = string.format("STEP %d / %d", index, #steps)
	end
	if nextBtn then
		nextBtn.Visible = step.manual == true
		nextBtn.Text = (index == #steps) and "FINISH" or "NEXT  →"
	end

	-- Snapshot state for auto-advance conditions
	if step.conditionName == "towerSelected" then
		Hud.clearSelection() -- force the user to actually click a tower button
	elseif step.conditionName == "towerPlaced" then
		local folder = workspace:FindFirstChild("Towers")
		stepStartTowerCount = folder and #folder:GetChildren() or 0
	elseif step.conditionName == "waveStarted" then
		local state = Hud.getState()
		stepStartWaveNum = (state and state.waveNum) or 0
	elseif step.conditionName == "inventoryOpened" then
		-- Force the inventory panel closed so the user has to open it
		local panel = Hud.getElement("InventoryPanel")
		if panel then
			panel.Visible = false
		end
	end

	updatePointer(step.target)
end

function Tutorial._advance()
	currentStepIndex += 1
	if currentStepIndex > #steps then
		Tutorial.finish()
		return
	end
	showStep(currentStepIndex)
end

-- --- Public API ---

function Tutorial.start(onComplete: (() -> ())?)
	onCompleteCallback = onComplete
	steps = buildSteps()
	currentStepIndex = 0
	buildOverlay()
	-- Yield one frame so the overlay + HUD layouts are computed before
	-- we query any AbsolutePosition/AbsoluteSize for highlighting.
	RunService.Heartbeat:Wait()
	Tutorial._advance()

	heartbeatConn = RunService.Heartbeat:Connect(function()
		if not screen or currentStepIndex <= 0 or currentStepIndex > #steps then
			return
		end
		local step = steps[currentStepIndex]
		if not step then
			return
		end

		-- Refresh the pointer each frame so it tracks layout changes
		if step.target then
			updatePointer(step.target)
		end

		-- Auto-advance if the step's condition is met
		if step.conditionName and checkCondition(step.conditionName) then
			Tutorial._advance()
		end
	end)
end

function Tutorial.finish()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	-- Pointer lives in the Hud screen, not the Tutorial screen, so
	-- destroy it explicitly before tearing down the Tutorial screen.
	if pointerLabel then
		pointerLabel:Destroy()
	end
	if screen then
		screen:Destroy()
		screen = nil
	end
	tooltipIcon = nil
	tooltipText = nil
	counterLabel = nil
	nextBtn = nil
	pointerLabel = nil
	currentStepIndex = 0
	if onCompleteCallback then
		local cb = onCompleteCallback
		onCompleteCallback = nil
		cb()
	end
end

-- Shows a "Would you like a tutorial?" prompt.
function Tutorial.showPrompt(onYes: () -> (), onNo: () -> ())
	local promptGui = Instance.new("ScreenGui")
	promptGui.Name = "TutorialPrompt"
	promptGui.IgnoreGuiInset = true
	promptGui.ResetOnSpawn = false
	promptGui.DisplayOrder = 60
	promptGui.Parent = playerGui

	local dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dim.BackgroundTransparency = 0.35
	dim.BorderSizePixel = 0
	dim.Parent = promptGui

	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(520, 300)
	card.Position = UDim2.new(0.5, -260, 0.5, -150)
	card.BackgroundColor3 = Color3.fromRGB(30, 20, 12)
	card.BorderSizePixel = 0
	card.Parent = promptGui
	addCorner(card, 16)
	addStroke(card, COLOR_ACCENT, 3)

	local icon = Instance.new("TextLabel")
	icon.Size = UDim2.fromOffset(80, 80)
	icon.Position = UDim2.new(0.5, -40, 0, 22)
	icon.BackgroundTransparency = 1
	icon.Text = "📘"
	icon.Font = Enum.Font.GothamBlack
	icon.TextSize = 60
	icon.Parent = card

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 36)
	title.Position = UDim2.fromOffset(0, 108)
	title.BackgroundTransparency = 1
	title.Text = "NEW TO THE GAME?"
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 26
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.Parent = card

	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, -40, 0, 26)
	text.Position = UDim2.fromOffset(20, 148)
	text.BackgroundTransparency = 1
	text.Text = "Quick tour of the basics?"
	text.Font = Enum.Font.GothamMedium
	text.TextSize = 16
	text.TextColor3 = COLOR_TEXT_DIM
	text.Parent = card

	local function makeBtn(name: string, label: string, bgColor: Color3, x: number): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.Size = UDim2.fromOffset(200, 54)
		btn.Position = UDim2.fromOffset(x, 210)
		btn.Text = label
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 17
		btn.TextColor3 = COLOR_TEXT
		btn.BackgroundColor3 = bgColor
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Parent = card
		addCorner(btn, 10)
		addStroke(btn, COLOR_ACCENT_BRIGHT, 2)
		return btn
	end

	local yesBtn = makeBtn("Yes", "YES, SHOW ME", Color3.fromRGB(109, 58, 16), 30)
	local noBtn = makeBtn("No", "NO, SKIP", Color3.fromRGB(60, 50, 40), 290)

	yesBtn.Activated:Connect(function()
		promptGui:Destroy()
		onYes()
	end)
	noBtn.Activated:Connect(function()
		promptGui:Destroy()
		onNo()
	end)
end

return Tutorial
