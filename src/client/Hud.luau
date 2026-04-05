--!strict
-- src/client/Hud.luau
-- Builds and manages the entire player HUD: top stat bar, tower panel,
-- wave button, inventory (backpack) + panel, controls hint, home screen,
-- game-over screen. Listens for server state updates via `onStateUpdate`.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Hud = {}

-- --- Theme ---
local COLOR_BG_DARK = Color3.fromRGB(20, 15, 10)
local COLOR_ACCENT = Color3.fromRGB(212, 165, 116)
local COLOR_ACCENT_BRIGHT = Color3.fromRGB(232, 194, 143)
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_GOLD_TEXT = Color3.fromRGB(255, 213, 79)
local COLOR_DANGER = Color3.fromRGB(239, 83, 80)

-- Display order for tower panel buttons
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

-- --- UI references (populated in mount) ---
local screen: ScreenGui
local hpLabel: TextLabel
local goldLabel: TextLabel
local waveLabel: TextLabel
local enemiesLabel: TextLabel
local waveBtn: TextButton
local towerButtons: { [string]: TextButton } = {}
local towerCostLabels: { [string]: TextLabel } = {}
local inventoryBtn: TextButton
local inventoryCountLabel: TextLabel
local inventoryPanel: Frame
local inventoryList: Frame
local homeScreen: Frame
local gameOverScreen: Frame
local gameOverLabel: TextLabel

-- --- Small builder helpers ---

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

local function addStroke(inst: GuiObject, color: Color3, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Parent = inst
end

local function addCorner(inst: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

-- --- Section builders ---

local function buildTopBar(parent: Instance)
	local bar = makeFrame(parent, "TopBar")
	bar.Size = UDim2.new(1, 0, 0, 52)
	bar.Position = UDim2.fromScale(0, 0)
	bar.BackgroundTransparency = 0.2

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 36)
	layout.Parent = bar

	local function makeStat(label: string, initial: string): TextLabel
		local stat = Instance.new("Frame")
		stat.Size = UDim2.fromOffset(140, 40)
		stat.BackgroundTransparency = 1
		stat.Parent = bar

		local lbl = makeTextLabel(stat, "Label", label .. ": ", 18)
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.TextXAlignment = Enum.TextXAlignment.Center

		local value = makeTextLabel(stat, "Value", initial, 22)
		value.TextColor3 = COLOR_ACCENT_BRIGHT
		value.Size = UDim2.fromScale(1, 1)
		value.Position = UDim2.fromOffset(0, 0)
		value.TextXAlignment = Enum.TextXAlignment.Center

		-- Combine via a single label for simplicity; we just mutate the value
		lbl.Visible = false
		value.Text = label .. ": " .. initial
		return value
	end

	hpLabel = makeStat("HP", tostring(Config.STARTING_HP))
	goldLabel = makeStat("Gold", tostring(Config.STARTING_GOLD))
	waveLabel = makeStat("Wave", "0")
	enemiesLabel = makeStat("Enemies", "0")
end

local function buildTowerPanel(parent: Instance)
	local panel = makeFrame(parent, "TowerPanel")
	panel.Size = UDim2.fromOffset(7 * 90 + 10, 100)
	panel.Position = UDim2.new(0.5, -(7 * 90 + 10) / 2, 1, -120)
	panel.BackgroundTransparency = 0.3
	addCorner(panel, 10)
	addStroke(panel, COLOR_ACCENT, 2)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 6)
	layout.Parent = panel

	for _, towerType in TOWER_ORDER do
		local def = TowerDefs[towerType]
		if not def then
			continue
		end

		local btn = makeTextButton(panel, "Btn_" .. towerType, "")
		btn.Size = UDim2.fromOffset(84, 86)
		btn.BackgroundColor3 = COLOR_BG_DARK
		btn.BackgroundTransparency = 0.3
		addCorner(btn, 8)
		addStroke(btn, COLOR_ACCENT, 1)

		local icon = makeTextLabel(btn, "Icon", def.icon, 30)
		icon.Size = UDim2.new(1, 0, 0, 36)
		icon.Position = UDim2.fromOffset(0, 6)
		icon.TextXAlignment = Enum.TextXAlignment.Center

		local name = makeTextLabel(
			btn,
			"Name",
			def.name:gsub(" Tower", ""):gsub(" Bunker", ""):gsub(" Spire", ""),
			12
		)
		name.Size = UDim2.new(1, 0, 0, 16)
		name.Position = UDim2.fromOffset(0, 44)
		name.TextXAlignment = Enum.TextXAlignment.Center

		local cost = makeTextLabel(btn, "Cost", string.format("%dg", def.cost), 13)
		cost.TextColor3 = COLOR_GOLD_TEXT
		cost.Size = UDim2.new(1, 0, 0, 16)
		cost.Position = UDim2.fromOffset(0, 62)
		cost.TextXAlignment = Enum.TextXAlignment.Center

		btn.Activated:Connect(function()
			Hud.selectTower(towerType)
		end)

		towerButtons[towerType] = btn
		towerCostLabels[towerType] = cost
	end
end

local function buildWaveButton(parent: Instance)
	waveBtn = makeTextButton(parent, "WaveBtn", "Start Wave 1")
	waveBtn.Size = UDim2.fromOffset(220, 48)
	waveBtn.Position = UDim2.new(0.5, -110, 1, -230)
	waveBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 80)
	waveBtn.BackgroundTransparency = 0.25
	waveBtn.TextSize = 18
	addCorner(waveBtn, 8)
	addStroke(waveBtn, Color3.fromRGB(165, 214, 167), 2)

	waveBtn.Activated:Connect(function()
		Remotes.StartWave:FireServer()
	end)
end

local function buildInventory(parent: Instance)
	-- Backpack button (top right, below top bar)
	inventoryBtn = makeTextButton(parent, "InventoryBtn", "🎒")
	inventoryBtn.Size = UDim2.fromOffset(60, 60)
	inventoryBtn.Position = UDim2.new(1, -80, 0, 70)
	inventoryBtn.TextSize = 32
	inventoryBtn.BackgroundTransparency = 0.15
	addCorner(inventoryBtn, 10)
	addStroke(inventoryBtn, COLOR_ACCENT, 2)

	local badge = Instance.new("Frame")
	badge.Name = "Count"
	badge.Size = UDim2.fromOffset(24, 24)
	badge.Position = UDim2.fromOffset(-8, -8)
	badge.BackgroundColor3 = Color3.fromRGB(198, 40, 40)
	badge.BorderSizePixel = 0
	badge.Parent = inventoryBtn
	addCorner(badge, 12)
	addStroke(badge, Color3.fromRGB(255, 255, 255), 2)

	inventoryCountLabel = makeTextLabel(badge, "Count", "0", 13)
	inventoryCountLabel.Size = UDim2.fromScale(1, 1)
	inventoryCountLabel.TextXAlignment = Enum.TextXAlignment.Center
	inventoryCountLabel.TextColor3 = COLOR_TEXT

	-- Inventory panel (slides in from the right)
	inventoryPanel = makeFrame(parent, "InventoryPanel")
	inventoryPanel.Size = UDim2.fromOffset(320, 520)
	inventoryPanel.Position = UDim2.new(1, -340, 0, 140)
	inventoryPanel.BackgroundTransparency = 0.1
	inventoryPanel.Visible = false
	addCorner(inventoryPanel, 12)
	addStroke(inventoryPanel, COLOR_ACCENT, 2)

	local title = makeTextLabel(inventoryPanel, "Title", "INVENTORY", 18)
	title.Size = UDim2.new(1, 0, 0, 36)
	title.Position = UDim2.fromOffset(0, 10)
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.TextXAlignment = Enum.TextXAlignment.Center

	inventoryList = makeFrame(inventoryPanel, "List")
	inventoryList.Size = UDim2.new(1, -20, 1, -60)
	inventoryList.Position = UDim2.fromOffset(10, 50)
	inventoryList.BackgroundTransparency = 1

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = inventoryList

	inventoryBtn.Activated:Connect(function()
		inventoryPanel.Visible = not inventoryPanel.Visible
	end)
end

local function buildControlsHint(parent: Instance)
	local hint = makeFrame(parent, "ControlsHint")
	hint.Size = UDim2.fromOffset(340, 60)
	hint.Position = UDim2.new(0, 20, 1, -80)
	hint.BackgroundTransparency = 0.35
	addCorner(hint, 6)
	addStroke(hint, COLOR_ACCENT, 1)

	local text = makeTextLabel(hint, "Text", "", 12)
	text.Size = UDim2.new(1, -20, 1, -16)
	text.Position = UDim2.fromOffset(10, 8)
	text.Font = Enum.Font.Gotham
	text.RichText = true
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Text =
		"<b>L-click</b> Place  •  <b>R-click</b> Pick up\n<b>Tab</b> Explore/Overview  •  <b>Scroll</b> Zoom"
end

local function buildHomeScreen(parent: Instance)
	homeScreen = makeFrame(parent, "HomeScreen")
	homeScreen.Size = UDim2.fromScale(1, 1)
	homeScreen.BackgroundColor3 = Color3.fromRGB(8, 4, 2)
	homeScreen.BackgroundTransparency = 0.1
	homeScreen.ZIndex = 100

	local card = makeFrame(homeScreen, "Card")
	card.Size = UDim2.fromOffset(680, 480)
	card.Position = UDim2.new(0.5, -340, 0.5, -240)
	card.BackgroundColor3 = Color3.fromRGB(30, 20, 12)
	card.BackgroundTransparency = 0.08
	card.ZIndex = 101
	addCorner(card, 14)
	addStroke(card, COLOR_ACCENT, 2)

	local title = makeTextLabel(card, "Title", "REALM DEFENSE", 56)
	title.Size = UDim2.new(1, 0, 0, 80)
	title.Position = UDim2.fromOffset(0, 60)
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 102

	local subtitle = makeTextLabel(
		card,
		"Subtitle",
		"Build towers of steel and sorcery. Defend the path. Survive the siege.",
		16
	)
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.TextColor3 = Color3.fromRGB(201, 166, 120)
	subtitle.Size = UDim2.new(1, -40, 0, 24)
	subtitle.Position = UDim2.fromOffset(20, 160)
	subtitle.TextXAlignment = Enum.TextXAlignment.Center
	subtitle.ZIndex = 102

	local playBtn = makeTextButton(card, "PlayBtn", "PLAY")
	playBtn.Size = UDim2.fromOffset(220, 64)
	playBtn.Position = UDim2.new(0.5, -110, 0, 220)
	playBtn.TextSize = 28
	playBtn.BackgroundColor3 = Color3.fromRGB(109, 58, 16)
	playBtn.ZIndex = 102
	addCorner(playBtn, 8)
	addStroke(playBtn, COLOR_ACCENT_BRIGHT, 2)

	local hint = makeTextLabel(
		card,
		"Hint",
		"<b>L-click</b> Place tower  •  <b>R-click</b> Pick up  •  <b>Tab</b> Switch to explore mode",
		13
	)
	hint.Font = Enum.Font.Gotham
	hint.RichText = true
	hint.Size = UDim2.new(1, -40, 0, 50)
	hint.Position = UDim2.fromOffset(20, 340)
	hint.TextColor3 = Color3.fromRGB(168, 151, 120)
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.TextWrapped = true
	hint.ZIndex = 102

	playBtn.Activated:Connect(function()
		homeScreen.Visible = false
		if onStartedCallback then
			onStartedCallback()
		end
	end)
end

local function buildGameOverScreen(parent: Instance)
	gameOverScreen = makeFrame(parent, "GameOverScreen")
	gameOverScreen.Size = UDim2.fromScale(1, 1)
	gameOverScreen.BackgroundColor3 = Color3.fromRGB(8, 4, 2)
	gameOverScreen.BackgroundTransparency = 0.2
	gameOverScreen.Visible = false
	gameOverScreen.ZIndex = 200

	local card = makeFrame(gameOverScreen, "Card")
	card.Size = UDim2.fromOffset(520, 320)
	card.Position = UDim2.new(0.5, -260, 0.5, -160)
	card.BackgroundColor3 = Color3.fromRGB(30, 15, 10)
	card.ZIndex = 201
	addCorner(card, 14)
	addStroke(card, COLOR_DANGER, 2)

	local title = makeTextLabel(card, "Title", "GAME OVER", 52)
	title.Size = UDim2.new(1, 0, 0, 72)
	title.Position = UDim2.fromOffset(0, 40)
	title.TextColor3 = COLOR_DANGER
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 202

	gameOverLabel = makeTextLabel(card, "Subtitle", "You survived 0 waves.", 18)
	gameOverLabel.Font = Enum.Font.GothamMedium
	gameOverLabel.Size = UDim2.new(1, 0, 0, 30)
	gameOverLabel.Position = UDim2.fromOffset(0, 140)
	gameOverLabel.TextXAlignment = Enum.TextXAlignment.Center
	gameOverLabel.ZIndex = 202

	local restartBtn = makeTextButton(card, "RestartBtn", "PLAY AGAIN")
	restartBtn.Size = UDim2.fromOffset(200, 56)
	restartBtn.Position = UDim2.new(0.5, -100, 0, 200)
	restartBtn.TextSize = 22
	restartBtn.BackgroundColor3 = Color3.fromRGB(109, 58, 16)
	restartBtn.ZIndex = 202
	addCorner(restartBtn, 8)
	addStroke(restartBtn, COLOR_ACCENT_BRIGHT, 2)

	restartBtn.Activated:Connect(function()
		gameOverScreen.Visible = false
		Remotes.Restart:FireServer()
	end)
end

-- --- Updates ---

local function updateTopBar()
	hpLabel.Text = "HP: " .. currentState.hp
	goldLabel.Text = "Gold: " .. currentState.gold
	waveLabel.Text = "Wave: " .. currentState.waveNum
end

local function updateTowerButtons()
	for towerType, btn in towerButtons do
		local def = TowerDefs[towerType]
		local canAfford = currentState.gold >= def.cost
		local stroke = btn:FindFirstChildOfClass("UIStroke")
		if stroke then
			if selection.fromInventoryIndex < 0 and selection.towerType == towerType then
				stroke.Color = COLOR_ACCENT_BRIGHT
				stroke.Thickness = 3
			else
				stroke.Color = COLOR_ACCENT
				stroke.Thickness = 1
			end
		end
		btn.BackgroundTransparency = canAfford and 0.3 or 0.6
		towerCostLabels[towerType].TextColor3 = canAfford and COLOR_GOLD_TEXT or COLOR_DANGER
	end
end

local function updateWaveButton()
	if currentState.waveActive then
		waveBtn.Text = "Wave " .. currentState.waveNum .. " in progress"
		waveBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
		waveBtn.AutoButtonColor = false
	else
		waveBtn.Text = "Start Wave " .. (currentState.waveNum + 1)
		waveBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 80)
		waveBtn.AutoButtonColor = true
	end
end

local function updateInventory()
	inventoryCountLabel.Text = tostring(#currentState.inventory)

	-- Clear every GuiObject child (Frames, TextButtons, and — crucially —
	-- any leftover "empty" TextLabel). UIListLayout is a UIBase, not a
	-- GuiObject, so it is preserved.
	for _, child in inventoryList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	if #currentState.inventory == 0 then
		local empty = makeTextLabel(inventoryList, "Empty", "Right-click a tower to pick it up", 13)
		empty.Font = Enum.Font.GothamMedium
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.TextColor3 = Color3.fromRGB(119, 102, 85)
		return
	end

	for idx, item in currentState.inventory do
		local def = TowerDefs[item.towerType]
		if not def then
			continue
		end
		local refund = math.floor(item.cost * Config.SELL_RATIO)

		local slot = makeFrame(inventoryList, "Slot_" .. idx)
		slot.Size = UDim2.new(1, 0, 0, 60)
		slot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		slot.BackgroundTransparency = 0.95
		addCorner(slot, 6)

		local slotStroke = Instance.new("UIStroke")
		slotStroke.Color = (idx == selection.fromInventoryIndex) and COLOR_ACCENT_BRIGHT
			or COLOR_ACCENT
		slotStroke.Thickness = (idx == selection.fromInventoryIndex) and 3 or 1
		slotStroke.Parent = slot

		local icon = makeTextLabel(slot, "Icon", def.icon, 26)
		icon.Size = UDim2.fromOffset(40, 60)
		icon.Position = UDim2.fromOffset(8, 0)
		icon.TextXAlignment = Enum.TextXAlignment.Center

		local name = makeTextLabel(slot, "Name", def.name, 14)
		name.Size = UDim2.fromOffset(160, 24)
		name.Position = UDim2.fromOffset(54, 8)
		name.TextColor3 = COLOR_ACCENT_BRIGHT
		name.TextXAlignment = Enum.TextXAlignment.Left

		local info = makeTextLabel(
			slot,
			"Info",
			string.format("Cost: %dg  •  Refund: %dg", item.cost, refund),
			11
		)
		info.Font = Enum.Font.Gotham
		info.Size = UDim2.fromOffset(180, 20)
		info.Position = UDim2.fromOffset(54, 30)
		info.TextColor3 = Color3.fromRGB(168, 151, 120)
		info.TextXAlignment = Enum.TextXAlignment.Left

		local sellBtn = makeTextButton(slot, "Sell", "Sell +" .. refund .. "g")
		sellBtn.Size = UDim2.fromOffset(80, 36)
		sellBtn.Position = UDim2.new(1, -90, 0.5, -18)
		sellBtn.TextSize = 12
		sellBtn.BackgroundColor3 = Color3.fromRGB(109, 58, 16)
		addCorner(sellBtn, 5)
		addStroke(sellBtn, COLOR_ACCENT_BRIGHT, 1)

		-- Wrap in a button so the whole slot is clickable for selection
		local selectBtn = Instance.new("TextButton")
		selectBtn.Name = "SelectArea"
		selectBtn.Text = ""
		selectBtn.BackgroundTransparency = 1
		selectBtn.Size = UDim2.new(1, -100, 1, 0)
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

	buildTopBar(screen)
	buildTowerPanel(screen)
	buildWaveButton(screen)
	buildInventory(screen)
	buildControlsHint(screen)
	buildGameOverScreen(screen)
	buildHomeScreen(screen)

	updateTopBar()
	updateTowerButtons()
	updateWaveButton()
	updateInventory()
end

function Hud.onStateUpdate(state)
	currentState = state
	updateTopBar()
	updateTowerButtons()
	updateWaveButton()
	updateInventory()
	enemiesLabel.Text = "Enemies: " .. (#currentState.inventory == 0 and "0" or "0")
end

function Hud.onLiveEnemyCount(count: number)
	enemiesLabel.Text = "Enemies: " .. count
end

function Hud.showGameOver()
	gameOverLabel.Text = string.format("You survived %d waves.", currentState.waveNum)
	gameOverScreen.Visible = true
end

function Hud.selectTower(towerType: string)
	selection.towerType = towerType
	selection.fromInventoryIndex = -1
	lastPanelTower = towerType
	updateTowerButtons()
	updateInventory()
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
end

function Hud.getSelection(): Selection
	return selection
end

function Hud.revertPanelSelection()
	selection.fromInventoryIndex = -1
	selection.towerType = lastPanelTower
	updateTowerButtons()
	updateInventory()
end

function Hud.isGameOver(): boolean
	return currentState.gameOver
end

return Hud
