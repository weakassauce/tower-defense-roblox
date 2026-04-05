--!strict
-- src/client/Tutorial.luau
-- Optional guided tutorial that walks new players through placing towers,
-- starting waves, and using the inventory. Shows a Yes/No prompt first so
-- veterans can skip it entirely.
--
-- Steps use a combination of:
--   * A pulsing gold stroke around the target UI element
--   * A tooltip panel at the top of the screen with instruction text
--   * Either a manual "Next" button or an automatic advance condition
--     that fires when the player performs the expected action.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Hud = require(script.Parent.Hud)

local Tutorial = {}

local COLOR_BG = Color3.fromRGB(20, 15, 10)
local COLOR_ACCENT = Color3.fromRGB(212, 165, 116)
local COLOR_ACCENT_BRIGHT = Color3.fromRGB(232, 194, 143)
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_TEXT_DIM = Color3.fromRGB(200, 180, 140)
local COLOR_HIGHLIGHT = Color3.fromRGB(255, 215, 100)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type Step = {
	text: string,
	target: string?, -- name of GUI element to highlight, or nil
	manual: boolean?, -- if true, advance only when the Next button is clicked
	conditionName: string?, -- name of auto-advance condition to watch
}

local screen: ScreenGui? = nil
local highlightFrame: Frame? = nil
local highlightStroke: UIStroke? = nil
local tooltipText: TextLabel? = nil
local nextBtn: TextButton? = nil
local heartbeatConn: RBXScriptConnection? = nil

local currentStepIndex = 0
local steps: { Step } = {}
local stepStartTowerCount = 0
local onCompleteCallback: (() -> ())? = nil

-- --- Step list ---

local function buildSteps(): { Step }
	return {
		{
			text = "Welcome to REALM DEFENSE! I'll walk you through the basics. Click Next to continue.",
			manual = true,
		},
		{
			text = "These are your stats. Keep an eye on your Health, Gold, Wave number, and live Enemy count.",
			target = "SidePanel",
			manual = true,
		},
		{
			text = "These are your towers. Click any tower to select it — let's try the Archer.",
			target = "TowerPanel",
			conditionName = "towerSelected",
		},
		{
			text = "Great! Now click any green grass cell on the map to place the tower.",
			conditionName = "towerPlaced",
		},
		{
			text = "Nice placement! Now click Start Wave to send in the first wave of enemies.",
			target = "WaveBtn",
			conditionName = "waveStarted",
		},
		{
			text = "Your towers attack automatically. Defend the castle at the end of the path!",
			manual = true,
		},
		{
			text = "Right-click any placed tower to pick it up and put it in your inventory. Try it after the tutorial.",
			manual = true,
		},
		{
			text = "Open the inventory with the backpack button on the right edge of the screen.",
			target = "InventoryBtn",
			conditionName = "inventoryOpened",
		},
		{
			text = "From the inventory you can re-place picked-up towers for free, or sell them for 70% of their cost.",
			target = "InventoryPanel",
			manual = true,
		},
		{
			text = "That's it! You're ready to defend the realm. Good luck!",
			manual = true,
		},
	}
end

-- --- Overlay builder ---

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

local function buildOverlay()
	screen = Instance.new("ScreenGui")
	screen.Name = "TutorialOverlay"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 50
	screen.Parent = playerGui

	-- Subtle dim so the game is still visible
	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dim.BackgroundTransparency = 0.62
	dim.BorderSizePixel = 0
	dim.Parent = screen

	-- Highlight box (follows target each frame)
	highlightFrame = Instance.new("Frame")
	highlightFrame.Name = "Highlight"
	highlightFrame.BackgroundTransparency = 1
	highlightFrame.Visible = false
	highlightFrame.Parent = screen
	addCorner(highlightFrame, 12)
	highlightStroke = addStroke(highlightFrame, COLOR_HIGHLIGHT, 5)

	-- Tooltip panel top-center
	local tooltipFrame = Instance.new("Frame")
	tooltipFrame.Name = "Tooltip"
	tooltipFrame.Size = UDim2.fromOffset(640, 180)
	tooltipFrame.Position = UDim2.new(0.5, -320, 0, 40)
	tooltipFrame.BackgroundColor3 = COLOR_BG
	tooltipFrame.BackgroundTransparency = 0.05
	tooltipFrame.BorderSizePixel = 0
	tooltipFrame.Parent = screen
	addCorner(tooltipFrame, 14)
	addStroke(tooltipFrame, COLOR_ACCENT, 3)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 30)
	title.Position = UDim2.fromOffset(0, 14)
	title.BackgroundTransparency = 1
	title.Text = "TUTORIAL"
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 18
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.Parent = tooltipFrame

	local textLbl = Instance.new("TextLabel")
	textLbl.Name = "Text"
	textLbl.Size = UDim2.new(1, -40, 0, 72)
	textLbl.Position = UDim2.fromOffset(20, 50)
	textLbl.BackgroundTransparency = 1
	textLbl.Text = ""
	textLbl.Font = Enum.Font.GothamMedium
	textLbl.TextSize = 17
	textLbl.TextColor3 = COLOR_TEXT
	textLbl.TextWrapped = true
	textLbl.TextYAlignment = Enum.TextYAlignment.Top
	textLbl.TextXAlignment = Enum.TextXAlignment.Center
	textLbl.Parent = tooltipFrame
	tooltipText = textLbl

	-- Next button (visible when step is manual)
	local nb = Instance.new("TextButton")
	nb.Name = "Next"
	nb.Size = UDim2.fromOffset(130, 40)
	nb.Position = UDim2.new(1, -150, 1, -52)
	nb.Text = "NEXT"
	nb.Font = Enum.Font.GothamBold
	nb.TextSize = 15
	nb.TextColor3 = COLOR_TEXT
	nb.BackgroundColor3 = Color3.fromRGB(109, 58, 16)
	nb.BorderSizePixel = 0
	nb.AutoButtonColor = false
	nb.Parent = tooltipFrame
	addCorner(nb, 8)
	addStroke(nb, COLOR_ACCENT_BRIGHT, 2)
	nextBtn = nb

	-- Skip button (always available)
	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.Size = UDim2.fromOffset(130, 34)
	skip.Position = UDim2.fromOffset(20, 130)
	skip.Text = "SKIP TUTORIAL"
	skip.Font = Enum.Font.GothamBold
	skip.TextSize = 12
	skip.TextColor3 = COLOR_TEXT_DIM
	skip.BackgroundColor3 = Color3.fromRGB(40, 30, 20)
	skip.BorderSizePixel = 0
	skip.AutoButtonColor = false
	skip.Parent = tooltipFrame
	addCorner(skip, 6)
	addStroke(skip, COLOR_ACCENT, 1)

	nb.Activated:Connect(function()
		Tutorial._advance()
	end)
	skip.Activated:Connect(function()
		Tutorial.finish()
	end)
end

-- --- Highlight + conditions ---

local function updateHighlight(targetName: string?)
	if not highlightFrame then
		return
	end
	if not targetName then
		highlightFrame.Visible = false
		return
	end
	local target = Hud.getElement(targetName)
	if not target or not target:IsA("GuiObject") then
		highlightFrame.Visible = false
		return
	end
	local pad = 10
	highlightFrame.Position =
		UDim2.fromOffset(target.AbsolutePosition.X - pad, target.AbsolutePosition.Y - pad)
	highlightFrame.Size =
		UDim2.fromOffset(target.AbsoluteSize.X + pad * 2, target.AbsoluteSize.Y + pad * 2)
	highlightFrame.Visible = true
end

local function checkCondition(name: string): boolean
	if name == "towerSelected" then
		return Hud.getSelection().towerType ~= ""
	elseif name == "towerPlaced" then
		local folder = workspace:FindFirstChild("Towers")
		if not folder then
			return false
		end
		return #folder:GetChildren() > stepStartTowerCount
	elseif name == "waveStarted" then
		local state = Hud.getState()
		return state and state.waveActive == true
	elseif name == "inventoryOpened" then
		local panel = Hud.getElement("InventoryPanel")
		return panel ~= nil and panel.Visible == true
	end
	return false
end

local function showStep(index: number)
	local step = steps[index]
	if not step then
		Tutorial.finish()
		return
	end

	if tooltipText then
		tooltipText.Text = step.text
	end
	if nextBtn then
		nextBtn.Visible = step.manual == true
	end

	-- Snapshot state used by auto-advance conditions
	if step.conditionName == "towerPlaced" then
		local folder = workspace:FindFirstChild("Towers")
		stepStartTowerCount = folder and #folder:GetChildren() or 0
	end

	updateHighlight(step.target)
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
	Tutorial._advance()

	heartbeatConn = RunService.Heartbeat:Connect(function()
		if currentStepIndex <= 0 or currentStepIndex > #steps then
			return
		end
		local step = steps[currentStepIndex]
		if not step then
			return
		end

		-- Refresh highlight position + pulse its stroke
		if step.target then
			updateHighlight(step.target)
		end
		if highlightStroke then
			local t = os.clock()
			highlightStroke.Thickness = 3 + 3 * (0.5 + 0.5 * math.sin(t * 4.2))
		end

		-- Auto-advance if the condition is met
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
	if screen then
		screen:Destroy()
		screen = nil
	end
	highlightFrame = nil
	highlightStroke = nil
	tooltipText = nil
	nextBtn = nil
	currentStepIndex = 0
	if onCompleteCallback then
		local cb = onCompleteCallback
		onCompleteCallback = nil
		cb()
	end
end

-- Shows a "Would you like a tutorial?" prompt. Calls onYes or onNo based
-- on the player's choice.
function Tutorial.showPrompt(onYes: () -> (), onNo: () -> ())
	local promptGui = Instance.new("ScreenGui")
	promptGui.Name = "TutorialPrompt"
	promptGui.IgnoreGuiInset = true
	promptGui.ResetOnSpawn = false
	promptGui.DisplayOrder = 60
	promptGui.Parent = playerGui

	-- Darker backdrop so it reads as a modal
	local dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dim.BackgroundTransparency = 0.35
	dim.BorderSizePixel = 0
	dim.Parent = promptGui

	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(560, 340)
	card.Position = UDim2.new(0.5, -280, 0.5, -170)
	card.BackgroundColor3 = Color3.fromRGB(30, 20, 12)
	card.BorderSizePixel = 0
	card.Parent = promptGui
	addCorner(card, 16)
	addStroke(card, COLOR_ACCENT, 3)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 56)
	title.Position = UDim2.fromOffset(0, 38)
	title.BackgroundTransparency = 1
	title.Text = "NEW TO THE GAME?"
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 30
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.Parent = card

	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, -60, 0, 72)
	text.Position = UDim2.fromOffset(30, 110)
	text.BackgroundTransparency = 1
	text.Text =
		"Would you like a quick guided tour that walks you through placing towers, starting waves, and using the inventory?"
	text.Font = Enum.Font.GothamMedium
	text.TextSize = 17
	text.TextColor3 = COLOR_TEXT_DIM
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.Parent = card

	local function makeBtn(name: string, label: string, bgColor: Color3, x: number): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.Size = UDim2.fromOffset(220, 58)
		btn.Position = UDim2.fromOffset(x, 230)
		btn.Text = label
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 18
		btn.TextColor3 = COLOR_TEXT
		btn.BackgroundColor3 = bgColor
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Parent = card
		addCorner(btn, 10)
		addStroke(btn, COLOR_ACCENT_BRIGHT, 2)
		return btn
	end

	local yesBtn = makeBtn("Yes", "YES, SHOW ME", Color3.fromRGB(109, 58, 16), 40)
	local noBtn = makeBtn("No", "NO, SKIP", Color3.fromRGB(60, 50, 40), 300)

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
