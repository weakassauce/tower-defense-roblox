--!strict
-- src/client/Hud.luau
-- Builds and manages the entire player HUD:
--   * Left side panel with stats (HP/Gold/Wave/Enemies) as big icon cards
--     and a selected-tower info card with damage/range/fire-rate stats.
--   * Bottom-center tower selection panel (7 towers). Selected button swaps
--     to a bright gold background with dark text so it's obviously active.
--   * Wave button above the tower panel.
--   * Backpack button + inventory panel on the right side.
--   * Home screen overlay with Play button.
--   * Game-over overlay with Restart.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Hud = {}

-- --- Theme ---
local COLOR_BG_DARK = Color3.fromRGB(20, 15, 10)
local COLOR_BG_CARD = Color3.fromRGB(40, 28, 16)
local COLOR_ACCENT = Color3.fromRGB(212, 165, 116)
local COLOR_ACCENT_BRIGHT = Color3.fromRGB(232, 194, 143)
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_TEXT_DIM = Color3.fromRGB(168, 151, 120)
local COLOR_GOLD_TEXT = Color3.fromRGB(255, 213, 79)
local COLOR_DANGER = Color3.fromRGB(239, 83, 80)

-- Display order for the tower panel
local TOWER_ORDER = { "basic", "sniper", "cannon", "freeze", "lightning", "poison", "flame" }

-- --- Client-side state ---

export type Selection = {
	towerType: string,
	fromInventoryIndex: number, -- -1 if from panel
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local currentState = {
	hp = Config.STARTING_HP,
	gold = Config.STARTING_GOLD,
	waveNum = 0,
	waveActive = false,
	gameOver = false,
	inventory = {},
}

local selection: Selection = { towerType = "basic", fromInventoryIndex = -1 }
local lastPanelTower = "basic"
local onStartedCallback: (() -> ())? = nil

-- --- UI references ---
local screen: ScreenGui
local statsValues: { [string]: TextLabel } = {}
local selectedIcon: TextLabel
local selectedName: TextLabel
local selectedCost: TextLabel
local selectedStats: TextLabel
local waveBtn: TextButton
local towerButtons: { [string]: TextButton } = {}
local towerStrokes: { [string]: UIStroke } = {}
local towerCostLabels: { [string]: TextLabel } = {}
local inventoryBtn: TextButton
local inventoryCountLabel: TextLabel
local inventoryPanel: Frame
local inventoryList: ScrollingFrame
local autoWaveBtn: TextButton
local autoWaveEnabled = false
local homeScreen: Frame
local gameOverScreen: Frame
local gameOverLabel: TextLabel

-- --- Builder helpers ---

local function makeFrame(parent: Instance, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundColor3 = COLOR_BG_DARK
	f.Parent = parent
	return f
end

local function makeTextLabel(
	parent: Instance,
	name: string,
	text: string,
	textSize: number
): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.BackgroundTransparency = 1
	lbl.Text = text
	lbl.TextColor3 = COLOR_TEXT
	lbl.TextSize = textSize
	lbl.Font = Enum.Font.GothamBold
	lbl.Parent = parent
	return lbl
end

local function makeTextButton(parent: Instance, name: string, text: string): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = text
	b.TextColor3 = COLOR_TEXT
	b.TextSize = 16
	b.Font = Enum.Font.GothamBold
	b.BackgroundColor3 = COLOR_BG_DARK
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Parent = parent
	return b
end

local function addStroke(inst: GuiObject, color: Color3, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = inst
	return stroke
end

local function addCorner(inst: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function addGradient(inst: GuiObject, topColor: Color3, bottomColor: Color3)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, topColor),
		ColorSequenceKeypoint.new(1, bottomColor),
	})
	g.Rotation = 90
	g.Parent = inst
end

-- --- Section: left side stats panel ---

local function makeStatCard(
	parent: Instance,
	order: number,
	icon: string,
	name: string,
	initial: string
): TextLabel
	local row = makeFrame(parent, name .. "Card")
	row.Size = UDim2.new(1, -24, 0, 72)
	row.Position = UDim2.fromOffset(12, 48 + (order - 1) * 80)
	row.BackgroundColor3 = COLOR_BG_CARD
	row.BackgroundTransparency = 0.25
	addCorner(row, 10)
	addStroke(row, COLOR_ACCENT, 1)

	local iconLabel = makeTextLabel(row, "Icon", icon, 38)
	iconLabel.Size = UDim2.fromOffset(64, 72)
	iconLabel.Position = UDim2.fromOffset(6, 0)
	iconLabel.TextXAlignment = Enum.TextXAlignment.Center

	local nameLabel = makeTextLabel(row, "Name", name, 11)
	nameLabel.Font = Enum.Font.GothamMedium
	nameLabel.TextColor3 = COLOR_TEXT_DIM
	nameLabel.Size = UDim2.new(1, -80, 0, 16)
	nameLabel.Position = UDim2.fromOffset(76, 14)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left

	local valueLabel = makeTextLabel(row, "Value", initial, 28)
	valueLabel.Font = Enum.Font.GothamBlack
	valueLabel.TextColor3 = COLOR_ACCENT_BRIGHT
	valueLabel.Size = UDim2.new(1, -80, 0, 36)
	valueLabel.Position = UDim2.fromOffset(76, 28)
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left

	return valueLabel
end

local function buildSidePanel(parent: Instance)
	local panel = makeFrame(parent, "SidePanel")
	panel.Size = UDim2.fromOffset(260, 680)
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 20, 0.5, 0)
	panel.BackgroundTransparency = 0.1
	addCorner(panel, 14)
	addStroke(panel, COLOR_ACCENT, 2)
	addGradient(panel, Color3.fromRGB(30, 20, 12), Color3.fromRGB(18, 12, 6))

	local title = makeTextLabel(panel, "Title", "REALM STATS", 16)
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.Size = UDim2.new(1, 0, 0, 30)
	title.Position = UDim2.fromOffset(0, 14)
	title.TextXAlignment = Enum.TextXAlignment.Center

	statsValues.hp = makeStatCard(panel, 1, "❤️", "HEALTH", tostring(Config.STARTING_HP))
	statsValues.gold = makeStatCard(panel, 2, "💰", "GOLD", tostring(Config.STARTING_GOLD))
	statsValues.wave = makeStatCard(panel, 3, "🌊", "WAVE", "0")
	statsValues.enemies = makeStatCard(panel, 4, "👹", "ENEMIES", "0")

	-- Selected tower info card
	local card = makeFrame(panel, "SelectedCard")
	card.Size = UDim2.new(1, -24, 0, 228)
	card.Position = UDim2.fromOffset(12, 48 + 4 * 80 + 12)
	card.BackgroundColor3 = COLOR_BG_CARD
	card.BackgroundTransparency = 0.2
	addCorner(card, 10)
	addStroke(card, COLOR_ACCENT_BRIGHT, 2)

	local cardTitle = makeTextLabel(card, "Title", "SELECTED TOWER", 11)
	cardTitle.Font = Enum.Font.GothamMedium
	cardTitle.TextColor3 = COLOR_TEXT_DIM
	cardTitle.Size = UDim2.new(1, 0, 0, 16)
	cardTitle.Position = UDim2.fromOffset(0, 8)
	cardTitle.TextXAlignment = Enum.TextXAlignment.Center

	selectedIcon = makeTextLabel(card, "Icon", "🏹", 46)
	selectedIcon.Size = UDim2.fromOffset(72, 70)
	selectedIcon.Position = UDim2.fromOffset(8, 28)

	selectedName = makeTextLabel(card, "Name", "Archer Tower", 16)
	selectedName.TextColor3 = COLOR_ACCENT_BRIGHT
	selectedName.Size = UDim2.new(1, -90, 0, 22)
	selectedName.Position = UDim2.fromOffset(80, 30)
	selectedName.TextXAlignment = Enum.TextXAlignment.Left

	selectedCost = makeTextLabel(card, "Cost", "40 gold", 15)
	selectedCost.Font = Enum.Font.GothamBold
	selectedCost.TextColor3 = COLOR_GOLD_TEXT
	selectedCost.Size = UDim2.new(1, -90, 0, 20)
	selectedCost.Position = UDim2.fromOffset(80, 54)
	selectedCost.TextXAlignment = Enum.TextXAlignment.Left

	selectedStats = makeTextLabel(card, "Stats", "", 13)
	selectedStats.Font = Enum.Font.Gotham
	selectedStats.TextColor3 = COLOR_TEXT
	selectedStats.RichText = true
	selectedStats.TextXAlignment = Enum.TextXAlignment.Left
	selectedStats.TextYAlignment = Enum.TextYAlignment.Top
	selectedStats.TextWrapped = true
	selectedStats.Size = UDim2.new(1, -20, 0, 110)
	selectedStats.Position = UDim2.fromOffset(10, 108)
end

-- --- Section: tower panel (bottom center) ---

local function buildTowerPanel(parent: Instance)
	local panel = makeFrame(parent, "TowerPanel")
	local btnWidth = 94
	local btnGap = 8
	local totalW = #TOWER_ORDER * btnWidth + (#TOWER_ORDER - 1) * btnGap + 24
	panel.Size = UDim2.fromOffset(totalW, 120)
	panel.Position = UDim2.new(0.5, -totalW / 2, 1, -140)
	panel.BackgroundTransparency = 0.2
	addCorner(panel, 12)
	addStroke(panel, COLOR_ACCENT, 2)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, btnGap)
	layout.Parent = panel

	for _, towerType in TOWER_ORDER do
		local def = TowerDefs[towerType]
		if not def then
			continue
		end

		local btn = makeTextButton(panel, "Btn_" .. towerType, "")
		btn.Size = UDim2.fromOffset(btnWidth, 100)
		btn.BackgroundColor3 = COLOR_BG_CARD
		btn.BackgroundTransparency = 0.25
		addCorner(btn, 10)
		local stroke = addStroke(btn, COLOR_ACCENT, 1)

		local icon = makeTextLabel(btn, "Icon", def.icon, 36)
		icon.Size = UDim2.new(1, 0, 0, 44)
		icon.Position = UDim2.fromOffset(0, 8)
		icon.TextXAlignment = Enum.TextXAlignment.Center

		local short = def.name:gsub(" Tower", ""):gsub(" Bunker", ""):gsub(" Spire", "")
		local name = makeTextLabel(btn, "Name", short, 12)
		name.Size = UDim2.new(1, 0, 0, 18)
		name.Position = UDim2.fromOffset(0, 54)
		name.TextXAlignment = Enum.TextXAlignment.Center

		local cost = makeTextLabel(btn, "Cost", string.format("%dg", def.cost), 14)
		cost.TextColor3 = COLOR_GOLD_TEXT
		cost.Size = UDim2.new(1, 0, 0, 18)
		cost.Position = UDim2.fromOffset(0, 74)
		cost.TextXAlignment = Enum.TextXAlignment.Center

		btn.Activated:Connect(function()
			Hud.selectTower(towerType)
		end)

		towerButtons[towerType] = btn
		towerStrokes[towerType] = stroke
		towerCostLabels[towerType] = cost
	end
end

-- --- Section: wave button ---

local function buildWaveButton(parent: Instance)
	waveBtn = makeTextButton(parent, "WaveBtn", "START WAVE 1")
	waveBtn.Size = UDim2.fromOffset(260, 54)
	waveBtn.Position = UDim2.new(0.5, -130, 1, -300)
	waveBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 80)
	waveBtn.BackgroundTransparency = 0.2
	waveBtn.TextSize = 20
	addCorner(waveBtn, 10)
	addStroke(waveBtn, Color3.fromRGB(165, 214, 167), 2)

	waveBtn.Activated:Connect(function()
		Remotes.StartWave:FireServer()
	end)

	-- Auto-wave toggle just below the main wave button
	autoWaveBtn = makeTextButton(parent, "AutoWaveBtn", "AUTO WAVE: OFF")
	autoWaveBtn.Size = UDim2.fromOffset(260, 32)
	autoWaveBtn.Position = UDim2.new(0.5, -130, 1, -240)
	autoWaveBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	autoWaveBtn.BackgroundTransparency = 0.3
	autoWaveBtn.TextSize = 14
	addCorner(autoWaveBtn, 6)
	addStroke(autoWaveBtn, COLOR_ACCENT, 1)

	autoWaveBtn.Activated:Connect(function()
		autoWaveEnabled = not autoWaveEnabled
		if autoWaveEnabled then
			autoWaveBtn.Text = "AUTO WAVE: ON"
			autoWaveBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 80)
		else
			autoWaveBtn.Text = "AUTO WAVE: OFF"
			autoWaveBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
		end
	end)
end

-- --- Section: inventory (backpack + panel) ---

local function buildInventory(parent: Instance)
	inventoryBtn = makeTextButton(parent, "InventoryBtn", "🎒")
	inventoryBtn.Size = UDim2.fromOffset(64, 64)
	inventoryBtn.Position = UDim2.new(1, -84, 0, 20)
	inventoryBtn.TextSize = 36
	inventoryBtn.BackgroundColor3 = COLOR_BG_DARK
	inventoryBtn.BackgroundTransparency = 0.1
	addCorner(inventoryBtn, 12)
	addStroke(inventoryBtn, COLOR_ACCENT, 2)

	local badge = Instance.new("Frame")
	badge.Name = "Count"
	badge.Size = UDim2.fromOffset(26, 26)
	badge.Position = UDim2.fromOffset(-8, -8)
	badge.BackgroundColor3 = Color3.fromRGB(198, 40, 40)
	badge.BorderSizePixel = 0
	badge.Parent = inventoryBtn
	addCorner(badge, 13)
	addStroke(badge, Color3.fromRGB(255, 255, 255), 2)

	inventoryCountLabel = makeTextLabel(badge, "Count", "0", 14)
	inventoryCountLabel.Size = UDim2.fromScale(1, 1)
	inventoryCountLabel.TextXAlignment = Enum.TextXAlignment.Center
	inventoryCountLabel.TextColor3 = COLOR_TEXT

	inventoryPanel = makeFrame(parent, "InventoryPanel")
	inventoryPanel.Size = UDim2.fromOffset(320, 560)
	inventoryPanel.Position = UDim2.new(1, -340, 0, 100)
	inventoryPanel.BackgroundTransparency = 0.1
	inventoryPanel.Visible = false
	addCorner(inventoryPanel, 14)
	addStroke(inventoryPanel, COLOR_ACCENT, 2)
	addGradient(inventoryPanel, Color3.fromRGB(30, 20, 12), Color3.fromRGB(18, 12, 6))

	local title = makeTextLabel(inventoryPanel, "Title", "INVENTORY", 18)
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.Size = UDim2.new(1, 0, 0, 36)
	title.Position = UDim2.fromOffset(0, 12)
	title.TextXAlignment = Enum.TextXAlignment.Center

	-- ScrollingFrame so many items don't overflow below the panel
	local scrollList = Instance.new("ScrollingFrame")
	scrollList.Name = "List"
	scrollList.Size = UDim2.new(1, -24, 1, -64)
	scrollList.Position = UDim2.fromOffset(12, 52)
	scrollList.BackgroundTransparency = 1
	scrollList.BorderSizePixel = 0
	scrollList.ScrollBarThickness = 6
	scrollList.ScrollBarImageColor3 = COLOR_ACCENT
	scrollList.ScrollBarImageTransparency = 0.2
	scrollList.ScrollingDirection = Enum.ScrollingDirection.Y
	scrollList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollList.CanvasSize = UDim2.fromScale(0, 0)
	scrollList.Parent = inventoryPanel
	inventoryList = scrollList

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.Padding = UDim.new(0, 8)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = inventoryList

	local listPadding = Instance.new("UIPadding")
	listPadding.PaddingRight = UDim.new(0, 6) -- room for the scroll bar
	listPadding.Parent = inventoryList

	inventoryBtn.Activated:Connect(function()
		inventoryPanel.Visible = not inventoryPanel.Visible
	end)
end

-- --- Section: controls hint ---

local function buildControlsHint(parent: Instance)
	local hint = makeFrame(parent, "ControlsHint")
	hint.Size = UDim2.fromOffset(380, 60)
	hint.Position = UDim2.new(1, -400, 1, -80)
	hint.BackgroundTransparency = 0.35
	addCorner(hint, 8)
	addStroke(hint, COLOR_ACCENT, 1)

	local text = makeTextLabel(hint, "Text", "", 13)
	text.Size = UDim2.new(1, -20, 1, -16)
	text.Position = UDim2.fromOffset(10, 8)
	text.Font = Enum.Font.GothamMedium
	text.RichText = true
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Center
	text.Text = "<b>L-click</b> Place  ·  <b>R-click</b> Pick up  ·  <b>C</b> Explore/Overview"
end

-- --- Section: home screen ---

local function buildHomeScreen(parent: Instance)
	homeScreen = makeFrame(parent, "HomeScreen")
	homeScreen.Size = UDim2.fromScale(1, 1)
	homeScreen.BackgroundColor3 = Color3.fromRGB(8, 4, 2)
	homeScreen.BackgroundTransparency = 0.05
	homeScreen.ZIndex = 100

	local card = makeFrame(homeScreen, "Card")
	card.Size = UDim2.fromOffset(720, 500)
	card.Position = UDim2.new(0.5, -360, 0.5, -250)
	card.BackgroundColor3 = Color3.fromRGB(30, 20, 12)
	card.BackgroundTransparency = 0.05
	card.ZIndex = 101
	addCorner(card, 16)
	addStroke(card, COLOR_ACCENT, 3)
	addGradient(card, Color3.fromRGB(44, 28, 14), Color3.fromRGB(18, 10, 4))

	local title = makeTextLabel(card, "Title", "REALM DEFENSE", 62)
	title.Font = Enum.Font.GothamBlack
	title.Size = UDim2.new(1, 0, 0, 80)
	title.Position = UDim2.fromOffset(0, 70)
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.ZIndex = 102

	local subtitle = makeTextLabel(
		card,
		"Subtitle",
		"Build towers of steel and sorcery. Defend the path. Survive the siege.",
		16
	)
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.TextColor3 = COLOR_TEXT_DIM
	subtitle.Size = UDim2.new(1, -40, 0, 24)
	subtitle.Position = UDim2.fromOffset(20, 170)
	subtitle.TextXAlignment = Enum.TextXAlignment.Center
	subtitle.ZIndex = 102

	local playBtn = makeTextButton(card, "PlayBtn", "PLAY")
	playBtn.Size = UDim2.fromOffset(240, 72)
	playBtn.Position = UDim2.new(0.5, -120, 0, 240)
	playBtn.TextSize = 32
	playBtn.BackgroundColor3 = Color3.fromRGB(109, 58, 16)
	playBtn.ZIndex = 102
	addCorner(playBtn, 10)
	addStroke(playBtn, COLOR_ACCENT_BRIGHT, 3)
	addGradient(playBtn, Color3.fromRGB(160, 90, 30), Color3.fromRGB(80, 40, 10))

	local hint = makeTextLabel(
		card,
		"Hint",
		"<b>L-click</b> Place tower  ·  <b>R-click</b> Pick up  ·  <b>C</b> Switch view",
		14
	)
	hint.Font = Enum.Font.GothamMedium
	hint.RichText = true
	hint.Size = UDim2.new(1, -40, 0, 24)
	hint.Position = UDim2.fromOffset(20, 370)
	hint.TextColor3 = COLOR_TEXT_DIM
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.ZIndex = 102

	playBtn.Activated:Connect(function()
		homeScreen.Visible = false
		if onStartedCallback then
			onStartedCallback()
		end
	end)
end

-- --- Section: game over screen ---

local function buildGameOverScreen(parent: Instance)
	gameOverScreen = makeFrame(parent, "GameOverScreen")
	gameOverScreen.Size = UDim2.fromScale(1, 1)
	gameOverScreen.BackgroundColor3 = Color3.fromRGB(8, 4, 2)
	gameOverScreen.BackgroundTransparency = 0.2
	gameOverScreen.Visible = false
	gameOverScreen.ZIndex = 200

	local card = makeFrame(gameOverScreen, "Card")
	card.Size = UDim2.fromOffset(560, 340)
	card.Position = UDim2.new(0.5, -280, 0.5, -170)
	card.BackgroundColor3 = Color3.fromRGB(30, 15, 10)
	card.ZIndex = 201
	addCorner(card, 16)
	addStroke(card, COLOR_DANGER, 3)

	local title = makeTextLabel(card, "Title", "GAME OVER", 56)
	title.Font = Enum.Font.GothamBlack
	title.Size = UDim2.new(1, 0, 0, 72)
	title.Position = UDim2.fromOffset(0, 40)
	title.TextColor3 = COLOR_DANGER
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 202

	gameOverLabel = makeTextLabel(card, "Subtitle", "You survived 0 waves.", 18)
	gameOverLabel.Font = Enum.Font.GothamMedium
	gameOverLabel.Size = UDim2.new(1, 0, 0, 30)
	gameOverLabel.Position = UDim2.fromOffset(0, 150)
	gameOverLabel.TextXAlignment = Enum.TextXAlignment.Center
	gameOverLabel.ZIndex = 202

	local restartBtn = makeTextButton(card, "RestartBtn", "PLAY AGAIN")
	restartBtn.Size = UDim2.fromOffset(220, 60)
	restartBtn.Position = UDim2.new(0.5, -110, 0, 220)
	restartBtn.TextSize = 22
	restartBtn.BackgroundColor3 = Color3.fromRGB(109, 58, 16)
	restartBtn.ZIndex = 202
	addCorner(restartBtn, 10)
	addStroke(restartBtn, COLOR_ACCENT_BRIGHT, 2)

	restartBtn.Activated:Connect(function()
		gameOverScreen.Visible = false
		Remotes.Restart:FireServer()
	end)
end

-- --- Updates ---

local function updateStats()
	statsValues.hp.Text = tostring(currentState.hp)
	statsValues.gold.Text = tostring(currentState.gold)
	statsValues.wave.Text = tostring(currentState.waveNum)
end

local function formatStats(def): string
	local parts = {}
	table.insert(parts, string.format("🎯 <b>Damage</b>  %d", def.damage))
	table.insert(parts, string.format("📏 <b>Range</b>   %d", def.range))
	table.insert(parts, string.format("⚡ <b>Fire rate</b> %.1f/s", def.fireRate))
	if def.splash and def.splash > 0 then
		table.insert(parts, string.format("💥 <b>Splash</b>  %d", def.splash))
	end
	if def.slowFactor then
		table.insert(
			parts,
			string.format("❄️ <b>Slow</b>    %d%%", math.floor((1 - def.slowFactor) * 100))
		)
	end
	if def.poisonDps then
		table.insert(parts, string.format("🧪 <b>Poison</b>  %d/s", def.poisonDps))
	end
	if def.chain then
		table.insert(parts, string.format("⚡ <b>Chains to</b> %d", def.chain + 1))
	end
	return table.concat(parts, "\n")
end

local function updateSelectedInfo()
	local def = TowerDefs[selection.towerType]
	if not def then
		selectedIcon.Text = "—"
		selectedName.Text = "Nothing selected"
		selectedCost.Text = "Click a tower to select"
		selectedCost.TextColor3 = COLOR_TEXT_DIM
		selectedStats.Text = ""
		return
	end
	selectedIcon.Text = def.icon
	selectedName.Text = def.name
	if selection.fromInventoryIndex >= 0 then
		selectedCost.Text = "FREE (from inventory)"
		selectedCost.TextColor3 = COLOR_ACCENT_BRIGHT
	else
		selectedCost.Text = def.cost .. " gold"
		selectedCost.TextColor3 = COLOR_GOLD_TEXT
	end
	selectedStats.Text = formatStats(def)
end

local function updateTowerButtons()
	for towerType, btn in towerButtons do
		local def = TowerDefs[towerType]
		local canAfford = currentState.gold >= def.cost
		local stroke = towerStrokes[towerType]
		local isSelected = (selection.fromInventoryIndex < 0 and selection.towerType == towerType)

		if isSelected then
			-- Swap colors so the selection is impossible to miss
			btn.BackgroundColor3 = COLOR_ACCENT_BRIGHT
			btn.BackgroundTransparency = 0
			stroke.Color = Color3.fromRGB(255, 240, 200)
			stroke.Thickness = 4
			btn:FindFirstChild("Name").TextColor3 = Color3.fromRGB(40, 25, 10)
			btn:FindFirstChild("Icon").TextColor3 = Color3.fromRGB(40, 25, 10)
			towerCostLabels[towerType].TextColor3 = Color3.fromRGB(80, 50, 10)
		else
			btn.BackgroundColor3 = COLOR_BG_CARD
			btn.BackgroundTransparency = canAfford and 0.25 or 0.55
			stroke.Color = COLOR_ACCENT
			stroke.Thickness = 1
			btn:FindFirstChild("Name").TextColor3 = COLOR_TEXT
			btn:FindFirstChild("Icon").TextColor3 = COLOR_TEXT
			towerCostLabels[towerType].TextColor3 = canAfford and COLOR_GOLD_TEXT or COLOR_DANGER
		end
	end
end

local function updateWaveButton()
	if currentState.waveActive then
		waveBtn.Text = "WAVE " .. currentState.waveNum .. " IN PROGRESS"
		waveBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
		waveBtn.AutoButtonColor = false
	else
		waveBtn.Text = "START WAVE " .. (currentState.waveNum + 1)
		waveBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 80)
		waveBtn.AutoButtonColor = true
	end
end

local function updateInventory()
	inventoryCountLabel.Text = tostring(#currentState.inventory)

	for _, child in inventoryList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	if #currentState.inventory == 0 then
		local empty = makeTextLabel(inventoryList, "Empty", "Right-click a tower to pick it up", 13)
		empty.Font = Enum.Font.GothamMedium
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.TextColor3 = COLOR_TEXT_DIM
		return
	end

	for idx, item in currentState.inventory do
		local def = TowerDefs[item.towerType]
		if not def then
			continue
		end
		local refund = math.floor(item.cost * Config.SELL_RATIO)

		local slot = makeFrame(inventoryList, "Slot_" .. idx)
		slot.Size = UDim2.new(1, 0, 0, 68)
		slot.BackgroundColor3 = COLOR_BG_CARD
		slot.BackgroundTransparency = 0.3
		addCorner(slot, 8)

		local slotStroke = Instance.new("UIStroke")
		slotStroke.Color = (idx == selection.fromInventoryIndex) and COLOR_ACCENT_BRIGHT
			or COLOR_ACCENT
		slotStroke.Thickness = (idx == selection.fromInventoryIndex) and 3 or 1
		slotStroke.Parent = slot

		local icon = makeTextLabel(slot, "Icon", def.icon, 32)
		icon.Size = UDim2.fromOffset(56, 68)
		icon.Position = UDim2.fromOffset(6, 0)
		icon.TextXAlignment = Enum.TextXAlignment.Center

		local name = makeTextLabel(slot, "Name", def.name, 15)
		name.Size = UDim2.fromOffset(170, 26)
		name.Position = UDim2.fromOffset(64, 10)
		name.TextColor3 = COLOR_ACCENT_BRIGHT
		name.TextXAlignment = Enum.TextXAlignment.Left

		local info = makeTextLabel(
			slot,
			"Info",
			string.format("Cost %dg · Refund %dg", item.cost, refund),
			11
		)
		info.Font = Enum.Font.Gotham
		info.Size = UDim2.fromOffset(180, 18)
		info.Position = UDim2.fromOffset(64, 36)
		info.TextColor3 = COLOR_TEXT_DIM
		info.TextXAlignment = Enum.TextXAlignment.Left

		local sellBtn = makeTextButton(slot, "Sell", "Sell +" .. refund .. "g")
		sellBtn.Size = UDim2.fromOffset(84, 40)
		sellBtn.Position = UDim2.new(1, -94, 0.5, -20)
		sellBtn.TextSize = 12
		sellBtn.BackgroundColor3 = Color3.fromRGB(109, 58, 16)
		addCorner(sellBtn, 6)
		addStroke(sellBtn, COLOR_ACCENT_BRIGHT, 1)

		local selectBtn = Instance.new("TextButton")
		selectBtn.Name = "SelectArea"
		selectBtn.Text = ""
		selectBtn.BackgroundTransparency = 1
		selectBtn.Size = UDim2.new(1, -104, 1, 0)
		selectBtn.Position = UDim2.fromOffset(0, 0)
		selectBtn.ZIndex = 5
		selectBtn.Parent = slot

		selectBtn.Activated:Connect(function()
			Hud.selectFromInventory(idx)
		end)
		sellBtn.Activated:Connect(function()
			Remotes.SellInventoryItem:FireServer(idx)
		end)
	end
end

-- --- Public API ---

function Hud.mount(onStarted: () -> ())
	onStartedCallback = onStarted

	screen = Instance.new("ScreenGui")
	screen.Name = "TowerDefenseHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.Parent = playerGui

	buildSidePanel(screen)
	buildTowerPanel(screen)
	buildWaveButton(screen)
	buildInventory(screen)
	buildControlsHint(screen)
	buildGameOverScreen(screen)
	buildHomeScreen(screen)

	updateStats()
	updateTowerButtons()
	updateWaveButton()
	updateInventory()
	updateSelectedInfo()
end

function Hud.onStateUpdate(state)
	currentState = state
	updateStats()
	updateTowerButtons()
	updateWaveButton()
	updateInventory()
	updateSelectedInfo()
end

function Hud.onLiveEnemyCount(count: number)
	statsValues.enemies.Text = tostring(count)
end

function Hud.showGameOver()
	gameOverLabel.Text = string.format("You survived %d waves.", currentState.waveNum)
	gameOverScreen.Visible = true
end

function Hud.selectTower(towerType: string)
	-- Click the already-selected panel button again → deselect
	if selection.fromInventoryIndex < 0 and selection.towerType == towerType then
		selection.towerType = ""
		selection.fromInventoryIndex = -1
	else
		selection.towerType = towerType
		selection.fromInventoryIndex = -1
		lastPanelTower = towerType
	end
	updateTowerButtons()
	updateInventory()
	updateSelectedInfo()
end

function Hud.selectFromInventory(idx: number)
	if selection.fromInventoryIndex == idx then
		Hud.selectTower(lastPanelTower)
		return
	end
	local item = currentState.inventory[idx]
	if not item then
		return
	end
	selection.towerType = item.towerType
	selection.fromInventoryIndex = idx
	updateTowerButtons()
	updateInventory()
	updateSelectedInfo()
end

function Hud.getSelection(): Selection
	return selection
end

function Hud.revertPanelSelection()
	selection.fromInventoryIndex = -1
	selection.towerType = lastPanelTower
	updateTowerButtons()
	updateInventory()
	updateSelectedInfo()
end

-- Used by the tutorial: clear the current selection so the player has to
-- actually click a tower button before the "select a tower" step advances.
function Hud.clearSelection()
	selection.towerType = ""
	selection.fromInventoryIndex = -1
	updateTowerButtons()
	updateInventory()
	updateSelectedInfo()
end

function Hud.isGameOver(): boolean
	return currentState.gameOver
end

-- Tutorial helpers: expose the raw state and let other modules look up UI
-- elements by name so they can be highlighted or queried.
function Hud.getState()
	return currentState
end

function Hud.getElement(name: string): GuiObject?
	if not screen then
		return nil
	end
	return screen:FindFirstChild(name, true) :: GuiObject?
end

-- Exposes the HUD's ScreenGui so the tutorial can parent its highlight
-- directly inside it (same coordinate space, no cross-ScreenGui inset
-- mismatch to fight with).
function Hud.getScreen(): ScreenGui?
	return screen
end

function Hud.isAutoWaveEnabled(): boolean
	return autoWaveEnabled
end

return Hud
