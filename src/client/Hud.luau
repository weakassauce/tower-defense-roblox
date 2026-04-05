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
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RealmDefs = require(ReplicatedStorage.Shared.RealmDefs)
local Guns = require(ReplicatedStorage.Shared.Guns)
local GamePassConfig = require(ReplicatedStorage.Shared.GamePassConfig)

local MarketplaceService = game:GetService("MarketplaceService")

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

-- Display order for the tower panel: the 7 universal towers first, then
-- realm signature towers in RealmDefs.ORDER, and finally the premium
-- game-pass tower. Signature towers are hidden by default and only
-- shown by Hud.setRealmTowers().
local TOWER_ORDER = {
	"basic",
	"sniper",
	"cannon",
	"freeze",
	"lightning",
	"poison",
	"flame",
	"paladin",
	"icelance",
	"sandstorm",
	"thornwall",
	"plasma",
	"celestial",
}

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

-- Tower cost = base cost * current realm's costMultiplier. Keeps the
-- HUD in sync with the server-side charge in init.server.luau.
local function scaledCost(baseCost: number): number
	local realm = RealmDefs.get(currentState.realm or "defense")
	return math.floor(baseCost * realm.costMultiplier)
end

-- Premium tower ownership is cached client-side so the tower picker
-- can instantly show the right state (Robux price vs. normal gold
-- price). Refreshed on first query and whenever PromptPurchaseFinished
-- / PremiumTowerUnlocked fires.
local premiumOwnedCached: boolean? = nil

local function ownsPremiumTower(): boolean
	if premiumOwnedCached ~= nil then
		return premiumOwnedCached
	end
	local passId = GamePassConfig.PREMIUM_TOWER.id
	-- Studio + unconfigured pass → auto-unlock so we can test locally.
	if passId == 0 then
		premiumOwnedCached = game:GetService("RunService"):IsStudio()
		return premiumOwnedCached :: boolean
	end
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	premiumOwnedCached = ok and result == true
	return premiumOwnedCached :: boolean
end

-- Called by init.client when PremiumTowerUnlocked fires (after a
-- successful Robux purchase) so the HUD re-renders the card.
function Hud.markPremiumOwned()
	premiumOwnedCached = true
end

-- --- UI references ---
local screen: ScreenGui
local sidePanel: Frame
local towerPanel: Frame
local controlsHint: Frame
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
local returnBtn: TextButton
local cameraBtn: TextButton
local shopBtn: TextButton
local gunToggleBtn: TextButton
local gunToggleIcon: TextLabel
local gunToggleTip: TextLabel
local shopPanel: Frame
local shopCards: { [string]: { card: Frame, actionBtn: TextButton, statusLabel: TextLabel } } = {}
-- Remembers the last gun the player had equipped, so the quick toggle
-- button can re-equip the same gun after unequipping.
local lastEquippedGun: string? = nil
-- Forward-declared so Hud.mount / Hud.onStateUpdate (defined earlier in
-- file order) can call it; the actual body is assigned further down.
local updateShop: () -> ()
local autoWaveBtn: TextButton
local autoWaveEnabled = false
local homeScreen: Frame
local gameOverScreen: Frame
local gameOverLabel: TextLabel
local onReturnCallback: (() -> ())? = nil
local onCameraToggleCallback: (() -> ())? = nil
local onBuyGunCallback: ((string) -> ())? = nil
local onEquipGunCallback: ((string?) -> ())? = nil
local onSelectionChangedCallback: (() -> ())? = nil
local crosshair: Frame
-- Set by Hud.setCrosshairVisible. The RenderStepped follower ANDs this
-- with "mouse not over a HUD button" to get the effective visibility so
-- the crosshair transparently steps aside when hovering UI.
local crosshairShouldShow = false
-- Incremented by GuiButton.MouseEnter, decremented by MouseLeave, on
-- every tracked HUD button. When this is > 0 the crosshair hides and
-- the system cursor comes back so the player can precisely click UI.
local hudHoverCount = 0

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
	sidePanel = panel
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
	towerPanel = panel
	local btnWidth = 94
	local btnGap = 8
	-- Panel auto-sizes horizontally so it fits whatever subset of tower
	-- buttons the current realm exposes.
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Size = UDim2.fromOffset(0, 120)
	panel.AutomaticSize = Enum.AutomaticSize.X
	panel.Position = UDim2.new(0.5, 0, 1, -140)
	panel.BackgroundTransparency = 0.2
	addCorner(panel, 12)
	addStroke(panel, COLOR_ACCENT, 2)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, btnGap)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	for idx, towerType in TOWER_ORDER do
		local def = TowerDefs[towerType]
		if not def then
			continue
		end

		local btn = makeTextButton(panel, "Btn_" .. towerType, "")
		btn.Size = UDim2.fromOffset(btnWidth, 100)
		btn.BackgroundColor3 = COLOR_BG_CARD
		btn.BackgroundTransparency = 0.25
		btn.LayoutOrder = idx
		btn.Visible = false -- hidden until setRealmTowers enables it
		addCorner(btn, 10)
		local stroke = addStroke(btn, COLOR_ACCENT, 1)

		local icon = makeTextLabel(btn, "Icon", def.icon, 36)
		icon.Size = UDim2.new(1, 0, 0, 44)
		icon.Position = UDim2.fromOffset(0, 8)
		icon.TextXAlignment = Enum.TextXAlignment.Center

		local short = def.name
			:gsub(" Tower", "")
			:gsub(" Bunker", "")
			:gsub(" Spire", "")
			:gsub(" Caster", "")
			:gsub(" Druid", "")
			:gsub(" Cannon", "")
			:gsub(" Hall", "")
		local name = makeTextLabel(btn, "Name", short, 12)
		name.Size = UDim2.new(1, 0, 0, 18)
		name.Position = UDim2.fromOffset(0, 54)
		name.TextXAlignment = Enum.TextXAlignment.Center

		local cost = makeTextLabel(btn, "Cost", string.format("%dg", def.cost), 14) -- updated in updateTowerButtons
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

-- --- Section: side buttons (return to lobby + camera toggle) ---

local function buildSideButtons(parent: Instance)
	returnBtn = makeTextButton(parent, "ReturnBtn", "🏠")
	returnBtn.Size = UDim2.fromOffset(64, 64)
	returnBtn.Position = UDim2.new(1, -84, 0, 94)
	returnBtn.TextSize = 32
	returnBtn.BackgroundColor3 = COLOR_BG_DARK
	returnBtn.BackgroundTransparency = 0.1
	addCorner(returnBtn, 12)
	addStroke(returnBtn, COLOR_ACCENT, 2)

	local returnTip = makeTextLabel(returnBtn, "Tip", "LOBBY", 10)
	returnTip.Font = Enum.Font.GothamBold
	returnTip.TextColor3 = COLOR_ACCENT_BRIGHT
	returnTip.Size = UDim2.new(1, 0, 0, 12)
	returnTip.Position = UDim2.fromOffset(0, 50)
	returnTip.TextXAlignment = Enum.TextXAlignment.Center

	returnBtn.Activated:Connect(function()
		if onReturnCallback then
			onReturnCallback()
		end
	end)

	cameraBtn = makeTextButton(parent, "CameraBtn", "📷")
	cameraBtn.Size = UDim2.fromOffset(64, 64)
	cameraBtn.Position = UDim2.new(1, -84, 0, 168)
	cameraBtn.TextSize = 32
	cameraBtn.BackgroundColor3 = COLOR_BG_DARK
	cameraBtn.BackgroundTransparency = 0.1
	addCorner(cameraBtn, 12)
	addStroke(cameraBtn, COLOR_ACCENT, 2)

	local cameraTip = makeTextLabel(cameraBtn, "Tip", "VIEW", 10)
	cameraTip.Font = Enum.Font.GothamBold
	cameraTip.TextColor3 = COLOR_ACCENT_BRIGHT
	cameraTip.Size = UDim2.new(1, 0, 0, 12)
	cameraTip.Position = UDim2.fromOffset(0, 50)
	cameraTip.TextXAlignment = Enum.TextXAlignment.Center

	cameraBtn.Activated:Connect(function()
		if onCameraToggleCallback then
			onCameraToggleCallback()
		end
	end)

	shopBtn = makeTextButton(parent, "ShopBtn", "🔫")
	shopBtn.Size = UDim2.fromOffset(64, 64)
	shopBtn.Position = UDim2.new(1, -84, 0, 242)
	shopBtn.TextSize = 32
	shopBtn.BackgroundColor3 = COLOR_BG_DARK
	shopBtn.BackgroundTransparency = 0.1
	addCorner(shopBtn, 12)
	addStroke(shopBtn, COLOR_ACCENT, 2)

	local shopTip = makeTextLabel(shopBtn, "Tip", "SHOP", 10)
	shopTip.Font = Enum.Font.GothamBold
	shopTip.TextColor3 = COLOR_ACCENT_BRIGHT
	shopTip.Size = UDim2.new(1, 0, 0, 12)
	shopTip.Position = UDim2.fromOffset(0, 50)
	shopTip.TextXAlignment = Enum.TextXAlignment.Center

	shopBtn.Activated:Connect(function()
		if shopPanel then
			shopPanel.Visible = not shopPanel.Visible
		end
	end)

	-- Quick equip / unequip toggle for the currently selected gun.
	-- Only clickable when the player owns at least one gun.
	gunToggleBtn = makeTextButton(parent, "GunToggleBtn", "")
	gunToggleBtn.Size = UDim2.fromOffset(64, 64)
	gunToggleBtn.Position = UDim2.new(1, -84, 0, 316)
	gunToggleBtn.BackgroundColor3 = COLOR_BG_DARK
	gunToggleBtn.BackgroundTransparency = 0.1
	addCorner(gunToggleBtn, 12)
	addStroke(gunToggleBtn, COLOR_ACCENT, 2)

	gunToggleIcon = makeTextLabel(gunToggleBtn, "Icon", "🚫", 30)
	gunToggleIcon.Size = UDim2.new(1, 0, 0, 44)
	gunToggleIcon.Position = UDim2.fromOffset(0, 6)
	gunToggleIcon.TextXAlignment = Enum.TextXAlignment.Center

	gunToggleTip = makeTextLabel(gunToggleBtn, "Tip", "HOLSTER", 10)
	gunToggleTip.Font = Enum.Font.GothamBold
	gunToggleTip.TextColor3 = COLOR_ACCENT_BRIGHT
	gunToggleTip.Size = UDim2.new(1, 0, 0, 12)
	gunToggleTip.Position = UDim2.fromOffset(0, 50)
	gunToggleTip.TextXAlignment = Enum.TextXAlignment.Center

	gunToggleBtn.Activated:Connect(function()
		if not onEquipGunCallback then
			return
		end
		if currentState.equippedGun then
			-- Currently equipped → unequip (remember last gun for re-equip)
			lastEquippedGun = currentState.equippedGun
			onEquipGunCallback(nil)
		else
			-- Nothing equipped → equip the last gun (or first owned)
			local target: string? = lastEquippedGun
			if not target or not currentState.ownedGuns or not currentState.ownedGuns[target] then
				target = nil
				if currentState.ownedGuns then
					for _, key in Guns.ORDER do
						if currentState.ownedGuns[key] then
							target = key
							break
						end
					end
				end
			end
			if target then
				onEquipGunCallback(target)
			end
		end
	end)
end

-- --- Section: crosshair ---
-- Four short white bars forming a cross at the screen center, shown
-- only while a gun is equipped AND no tower is selected to build.

local function buildCrosshair(parent: Instance)
	crosshair = Instance.new("Frame")
	crosshair.Name = "Crosshair"
	crosshair.Size = UDim2.fromOffset(32, 32)
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5) -- replaced every frame by the follower loop
	crosshair.BackgroundTransparency = 1
	crosshair.Visible = false
	crosshair.ZIndex = 50
	crosshair.Parent = parent

	local function makeArm(name: string, size: UDim2, pos: UDim2)
		local arm = Instance.new("Frame")
		arm.Name = name
		arm.Size = size
		arm.AnchorPoint = Vector2.new(0.5, 0.5)
		arm.Position = pos
		arm.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		arm.BorderSizePixel = 0
		arm.BackgroundTransparency = 0.15
		arm.Parent = crosshair

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(0, 0, 0)
		stroke.Thickness = 1
		stroke.Parent = arm
	end

	makeArm("Top", UDim2.fromOffset(2, 10), UDim2.new(0.5, 0, 0, 4))
	makeArm("Bottom", UDim2.fromOffset(2, 10), UDim2.new(0.5, 0, 1, -4))
	makeArm("Left", UDim2.fromOffset(10, 2), UDim2.new(0, 4, 0.5, 0))
	makeArm("Right", UDim2.fromOffset(10, 2), UDim2.new(1, -4, 0.5, 0))

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.Size = UDim2.fromOffset(2, 2)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dot.BorderSizePixel = 0
	dot.Parent = crosshair

	-- Every frame: if the crosshair is currently allowed (gun equipped,
	-- in arena, no tower selected), pin it to the cursor. If the mouse
	-- is hovering a tracked HUD button (hudHoverCount > 0), step aside
	-- so the player can precisely click UI buttons with the normal cursor.
	RunService.RenderStepped:Connect(function()
		if not crosshairShouldShow then
			crosshair.Visible = false
			UserInputService.MouseIconEnabled = true
			return
		end

		if hudHoverCount > 0 then
			crosshair.Visible = false
			UserInputService.MouseIconEnabled = true
			return
		end

		crosshair.Visible = true
		UserInputService.MouseIconEnabled = false

		local mousePos = UserInputService:GetMouseLocation()
		local inset = GuiService:GetGuiInset()
		crosshair.Position = UDim2.fromOffset(mousePos.X + inset.X, mousePos.Y + inset.Y)
	end)
end

-- Install MouseEnter / MouseLeave handlers on every GuiButton in the
-- HUD so we can reliably detect when the player is hovering a clickable
-- element. Called once on mount (walks the whole tree) and then keeps
-- listening for newly added buttons so dynamically built widgets like
-- inventory slots and tower cards also get tracked.
local function trackHover(inst: Instance)
	if not inst:IsA("GuiButton") then
		return
	end
	inst.MouseEnter:Connect(function()
		hudHoverCount += 1
	end)
	inst.MouseLeave:Connect(function()
		hudHoverCount = math.max(0, hudHoverCount - 1)
	end)
end

-- --- Section: gun shop panel ---

local function buildShopPanel(parent: Instance)
	shopPanel = makeFrame(parent, "ShopPanel")
	shopPanel.Size = UDim2.fromOffset(380, 520)
	shopPanel.AnchorPoint = Vector2.new(1, 0.5)
	shopPanel.Position = UDim2.new(1, -104, 0.5, 0)
	shopPanel.BackgroundTransparency = 0.1
	shopPanel.Visible = false
	addCorner(shopPanel, 14)
	addStroke(shopPanel, COLOR_ACCENT, 2)
	addGradient(shopPanel, Color3.fromRGB(30, 20, 12), Color3.fromRGB(18, 12, 6))

	local title = makeTextLabel(shopPanel, "Title", "ARMORY", 20)
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.Size = UDim2.new(1, 0, 0, 34)
	title.Position = UDim2.fromOffset(0, 12)
	title.TextXAlignment = Enum.TextXAlignment.Center

	local subtitle = makeTextLabel(
		shopPanel,
		"Subtitle",
		"Personal weapons — aim with mouse, click to shoot",
		11
	)
	subtitle.TextColor3 = COLOR_TEXT_DIM
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.Size = UDim2.new(1, -20, 0, 16)
	subtitle.Position = UDim2.fromOffset(10, 42)
	subtitle.TextXAlignment = Enum.TextXAlignment.Center

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Size = UDim2.new(1, -24, 1, -74)
	list.Position = UDim2.fromOffset(12, 64)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.ScrollBarImageColor3 = COLOR_ACCENT
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.fromScale(0, 0)
	list.Parent = shopPanel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = list

	for order, gunKey in Guns.ORDER do
		local def = Guns.defs[gunKey]
		if not def then
			continue
		end

		local card = makeFrame(list, "Card_" .. gunKey)
		card.Size = UDim2.new(1, 0, 0, 92)
		card.BackgroundColor3 = COLOR_BG_CARD
		card.BackgroundTransparency = 0.2
		card.LayoutOrder = order
		addCorner(card, 10)
		addStroke(card, COLOR_ACCENT, 1)

		local icon = makeTextLabel(card, "Icon", def.icon, 34)
		icon.Size = UDim2.fromOffset(64, 64)
		icon.Position = UDim2.fromOffset(8, 14)
		icon.TextXAlignment = Enum.TextXAlignment.Center

		local nameLbl = makeTextLabel(card, "Name", def.name, 16)
		nameLbl.TextColor3 = COLOR_ACCENT_BRIGHT
		nameLbl.Size = UDim2.new(1, -200, 0, 22)
		nameLbl.Position = UDim2.fromOffset(80, 10)
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left

		local statsText = string.format(
			"DMG %d · ROF %.1f · Range %d",
			def.damage * def.pellets,
			def.fireRate,
			def.range
		)
		local stats = makeTextLabel(card, "Stats", statsText, 11)
		stats.Font = Enum.Font.GothamMedium
		stats.TextColor3 = COLOR_TEXT_DIM
		stats.Size = UDim2.new(1, -200, 0, 14)
		stats.Position = UDim2.fromOffset(80, 32)
		stats.TextXAlignment = Enum.TextXAlignment.Left

		local desc = makeTextLabel(card, "Desc", def.description, 11)
		desc.Font = Enum.Font.Gotham
		desc.TextColor3 = COLOR_TEXT_DIM
		desc.Size = UDim2.new(1, -200, 0, 28)
		desc.Position = UDim2.fromOffset(80, 48)
		desc.TextXAlignment = Enum.TextXAlignment.Left
		desc.TextYAlignment = Enum.TextYAlignment.Top
		desc.TextWrapped = true

		local actionBtn = makeTextButton(card, "Action", "BUY")
		actionBtn.Size = UDim2.fromOffset(96, 36)
		actionBtn.Position = UDim2.new(1, -108, 0.5, -18)
		actionBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 80)
		actionBtn.TextSize = 14
		addCorner(actionBtn, 8)
		addStroke(actionBtn, Color3.fromRGB(165, 214, 167), 2)

		local statusLabel = makeTextLabel(card, "Status", string.format("%dg", def.cost), 12)
		statusLabel.TextColor3 = COLOR_GOLD_TEXT
		statusLabel.Size = UDim2.fromOffset(96, 14)
		statusLabel.Position = UDim2.new(1, -108, 0.5, 20)
		statusLabel.TextXAlignment = Enum.TextXAlignment.Center

		actionBtn.Activated:Connect(function()
			if currentState.ownedGuns and currentState.ownedGuns[gunKey] then
				if currentState.equippedGun == gunKey then
					-- Already equipped → clicking it again unequips
					if onEquipGunCallback then
						onEquipGunCallback(nil)
					end
				else
					if onEquipGunCallback then
						onEquipGunCallback(gunKey)
					end
				end
			else
				if onBuyGunCallback then
					onBuyGunCallback(gunKey)
				end
			end
		end)

		shopCards[gunKey] = { card = card, actionBtn = actionBtn, statusLabel = statusLabel }
	end
end

-- --- Section: controls hint ---

local function buildControlsHint(parent: Instance)
	local hint = makeFrame(parent, "ControlsHint")
	controlsHint = hint
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
	text.Text =
		"<b>L-click</b> Place / Shoot  ·  <b>R-click</b> Pick up  ·  <b>C</b> Explore/Overview"
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
		selectedCost.Text = scaledCost(def.cost) .. " gold"
		selectedCost.TextColor3 = COLOR_GOLD_TEXT
	end
	selectedStats.Text = formatStats(def)
end

local COLOR_PREMIUM = Color3.fromRGB(255, 215, 100)

local function updateTowerButtons()
	local premiumKey = GamePassConfig.PREMIUM_TOWER_KEY
	local hasPremium = ownsPremiumTower()
	for towerType, btn in towerButtons do
		local def = TowerDefs[towerType]
		local cost = scaledCost(def.cost)
		local canAfford = currentState.gold >= cost
		local costLabel = towerCostLabels[towerType]
		local stroke = towerStrokes[towerType]
		local isSelected = (selection.fromInventoryIndex < 0 and selection.towerType == towerType)

		-- Premium tower special case: if the player doesn't own the
		-- game pass, the card shows a Robux price instead of the
		-- normal gold cost and gets a gold highlight.
		local isLockedPremium = (towerType == premiumKey) and not hasPremium
		if isLockedPremium then
			if costLabel then
				costLabel.Text = GamePassConfig.PREMIUM_TOWER.price .. " R$"
			end
			btn.BackgroundColor3 = Color3.fromRGB(60, 45, 10)
			btn.BackgroundTransparency = 0.1
			stroke.Color = COLOR_PREMIUM
			stroke.Thickness = 3
			btn:FindFirstChild("Name").TextColor3 = COLOR_PREMIUM
			btn:FindFirstChild("Icon").TextColor3 = COLOR_PREMIUM
			if costLabel then
				costLabel.TextColor3 = COLOR_PREMIUM
			end
			continue
		end

		if costLabel then
			costLabel.Text = string.format("%dg", cost)
		end

		if isSelected then
			-- Swap colors so the selection is impossible to miss
			btn.BackgroundColor3 = COLOR_ACCENT_BRIGHT
			btn.BackgroundTransparency = 0
			stroke.Color = Color3.fromRGB(255, 240, 200)
			stroke.Thickness = 4
			btn:FindFirstChild("Name").TextColor3 = Color3.fromRGB(40, 25, 10)
			btn:FindFirstChild("Icon").TextColor3 = Color3.fromRGB(40, 25, 10)
			if costLabel then
				costLabel.TextColor3 = Color3.fromRGB(80, 50, 10)
			end
		elseif towerType == premiumKey then
			-- Owned premium: keep the gold color so it still reads as
			-- special even when unselected.
			btn.BackgroundColor3 = COLOR_BG_CARD
			btn.BackgroundTransparency = canAfford and 0.2 or 0.5
			stroke.Color = COLOR_PREMIUM
			stroke.Thickness = 2
			btn:FindFirstChild("Name").TextColor3 = COLOR_PREMIUM
			btn:FindFirstChild("Icon").TextColor3 = COLOR_PREMIUM
			if costLabel then
				costLabel.TextColor3 = canAfford and COLOR_PREMIUM or COLOR_DANGER
			end
		else
			btn.BackgroundColor3 = COLOR_BG_CARD
			btn.BackgroundTransparency = canAfford and 0.25 or 0.55
			stroke.Color = COLOR_ACCENT
			stroke.Thickness = 1
			btn:FindFirstChild("Name").TextColor3 = COLOR_TEXT
			btn:FindFirstChild("Icon").TextColor3 = COLOR_TEXT
			if costLabel then
				costLabel.TextColor3 = canAfford and COLOR_GOLD_TEXT or COLOR_DANGER
			end
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

-- Refresh every gun card to reflect current ownership and equipped state.
updateShop = function()
	if not shopCards then
		return
	end
	local owned = currentState.ownedGuns or {}
	local equipped = currentState.equippedGun

	-- Track the most recent gun so the quick-toggle button can re-equip
	-- it after the player holsters.
	if equipped then
		lastEquippedGun = equipped
	end

	-- Quick equip/unequip toggle button: grayed out if the player owns
	-- no gun, active if they own at least one.
	if gunToggleBtn and gunToggleIcon and gunToggleTip then
		local ownsAny = false
		for _, hasIt in owned do
			if hasIt then
				ownsAny = true
				break
			end
		end
		if not ownsAny then
			gunToggleBtn.AutoButtonColor = false
			gunToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 30, 20)
			gunToggleIcon.Text = "🚫"
			gunToggleTip.Text = "NO GUN"
			gunToggleTip.TextColor3 = COLOR_TEXT_DIM
		elseif equipped then
			local def = Guns.defs[equipped]
			gunToggleBtn.AutoButtonColor = true
			gunToggleBtn.BackgroundColor3 = Color3.fromRGB(76, 120, 76)
			gunToggleIcon.Text = def and def.icon or "🔫"
			gunToggleTip.Text = "HOLSTER"
			gunToggleTip.TextColor3 = COLOR_ACCENT_BRIGHT
		else
			local def = lastEquippedGun and Guns.defs[lastEquippedGun]
			gunToggleBtn.AutoButtonColor = true
			gunToggleBtn.BackgroundColor3 = COLOR_BG_DARK
			gunToggleIcon.Text = def and def.icon or "🔫"
			gunToggleTip.Text = "EQUIP"
			gunToggleTip.TextColor3 = COLOR_ACCENT_BRIGHT
		end
	end
	for gunKey, refs in shopCards do
		local def = Guns.defs[gunKey]
		if not def then
			continue
		end
		if gunKey == equipped then
			refs.actionBtn.Text = "UNEQUIP"
			refs.actionBtn.BackgroundColor3 = Color3.fromRGB(160, 65, 55)
			refs.actionBtn.AutoButtonColor = true
			refs.statusLabel.Text = "in hand"
			refs.statusLabel.TextColor3 = COLOR_ACCENT_BRIGHT
		elseif owned[gunKey] then
			refs.actionBtn.Text = "EQUIP"
			refs.actionBtn.BackgroundColor3 = Color3.fromRGB(60, 110, 180)
			refs.actionBtn.AutoButtonColor = true
			refs.statusLabel.Text = "owned"
			refs.statusLabel.TextColor3 = COLOR_TEXT_DIM
		else
			refs.actionBtn.Text = "BUY"
			if currentState.gold >= def.cost then
				refs.actionBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 80)
			else
				refs.actionBtn.BackgroundColor3 = Color3.fromRGB(90, 60, 60)
			end
			refs.actionBtn.AutoButtonColor = true
			refs.statusLabel.Text = string.format("%dg", def.cost)
			refs.statusLabel.TextColor3 = currentState.gold >= def.cost and COLOR_GOLD_TEXT
				or COLOR_DANGER
		end
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
	buildSideButtons(screen)
	buildShopPanel(screen)
	buildCrosshair(screen)
	buildControlsHint(screen)
	buildGameOverScreen(screen)
	buildHomeScreen(screen)

	-- Walk the HUD tree once to install hover tracking on every GuiButton,
	-- then keep listening so any dynamically-added buttons (inventory
	-- slots, etc.) also auto-register.
	for _, d in screen:GetDescendants() do
		trackHover(d)
	end
	screen.DescendantAdded:Connect(trackHover)

	updateStats()
	updateTowerButtons()
	updateWaveButton()
	updateInventory()
	updateSelectedInfo()
	updateShop()
end

function Hud.onStateUpdate(state)
	currentState = state
	updateStats()
	updateTowerButtons()
	updateWaveButton()
	updateInventory()
	updateSelectedInfo()
	updateShop()
end

function Hud.onLiveEnemyCount(count: number)
	statsValues.enemies.Text = tostring(count)
end

function Hud.showGameOver()
	gameOverLabel.Text = string.format("You survived %d waves.", currentState.waveNum)
	gameOverScreen.Visible = true
end

-- Notify listeners (PlayerGun, crosshair controller) whenever the
-- selection state transitions so they can hide/show the gun model and
-- crosshair accordingly.
local function fireSelectionChanged()
	if onSelectionChangedCallback then
		onSelectionChangedCallback()
	end
end

function Hud.selectTower(towerType: string)
	-- Premium tower: if the player doesn't own the game pass yet,
	-- clicking the card triggers the Robux purchase prompt instead of
	-- selecting the tower.
	if towerType == GamePassConfig.PREMIUM_TOWER_KEY and not ownsPremiumTower() then
		local passId = GamePassConfig.PREMIUM_TOWER.id
		if passId ~= 0 then
			MarketplaceService:PromptGamePassPurchase(player, passId)
		end
		return
	end

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
	fireSelectionChanged()
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
	fireSelectionChanged()
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
	fireSelectionChanged()
end

-- Used by the tutorial: clear the current selection so the player has to
-- actually click a tower button before the "select a tower" step advances.
function Hud.clearSelection()
	selection.towerType = ""
	selection.fromInventoryIndex = -1
	updateTowerButtons()
	updateInventory()
	updateSelectedInfo()
	fireSelectionChanged()
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

-- Reset all stateful HUD buttons to their defaults when the player
-- enters a fresh realm: clear the current tower selection, turn off
-- auto-wave, close the inventory panel. The stats cards (hp/gold/
-- wave/enemies) are driven by the server state broadcast and refresh
-- automatically, so they don't need manual clearing here.
function Hud.resetForNewRealm()
	local hadSelection = selection.towerType ~= ""
	selection.towerType = ""
	selection.fromInventoryIndex = -1
	lastPanelTower = "basic"
	if hadSelection then
		fireSelectionChanged()
	end
	if autoWaveEnabled then
		autoWaveEnabled = false
		if autoWaveBtn then
			autoWaveBtn.Text = "AUTO WAVE: OFF"
			autoWaveBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
		end
	end
	if inventoryPanel then
		inventoryPanel.Visible = false
	end
	if shopPanel then
		shopPanel.Visible = false
	end
	updateTowerButtons()
	updateInventory()
	updateSelectedInfo()
	updateWaveButton()
	updateShop()
end

-- Show only the given tower types in the bottom-center picker, in the
-- order provided. Called by the client when the player enters a realm.
function Hud.setRealmTowers(towerList: { string })
	local allowed: { [string]: number } = {}
	for i, t in towerList do
		allowed[t] = i
	end
	for towerType, btn in towerButtons do
		local order = allowed[towerType]
		if order then
			btn.Visible = true
			btn.LayoutOrder = order
		else
			btn.Visible = false
		end
	end
	-- If the current selection was a tower that isn't available in the
	-- new realm (e.g. the previous realm's signature), drop it.
	if selection.towerType ~= "" and not allowed[selection.towerType] then
		selection.towerType = ""
		selection.fromInventoryIndex = -1
		lastPanelTower = towerList[1] or "basic"
		updateTowerButtons()
		updateSelectedInfo()
		fireSelectionChanged()
	end
end

function Hud.setReturnCallback(fn: () -> ())
	onReturnCallback = fn
end

function Hud.setCameraToggleCallback(fn: () -> ())
	onCameraToggleCallback = fn
end

function Hud.setBuyGunCallback(fn: (string) -> ())
	onBuyGunCallback = fn
end

function Hud.setEquipGunCallback(fn: (string?) -> ())
	onEquipGunCallback = fn
end

function Hud.setSelectionChangedCallback(fn: () -> ())
	onSelectionChangedCallback = fn
end

-- True if the player currently has a tower selected from the picker
-- (either from the bottom panel or the inventory). Used by the gun
-- controller to auto-unequip while building.
function Hud.isTowerSelected(): boolean
	return selection.towerType ~= ""
end

function Hud.setCrosshairVisible(v: boolean)
	crosshairShouldShow = v
	if not v and crosshair then
		crosshair.Visible = false
		UserInputService.MouseIconEnabled = true
	end
	-- When v is true the RenderStepped follower takes over: it decides
	-- per-frame whether to show the crosshair (and hide the system
	-- cursor) or step aside when hovering HUD buttons.
end

-- Exposes the currently equipped gun key to the shooting code in
-- Placement.luau, so left-click fires only when a gun is equipped.
function Hud.getEquippedGun(): string?
	return currentState.equippedGun
end

-- Show or hide every HUD element that is only meaningful inside an
-- active realm: stats panel, tower picker, wave buttons, backpack,
-- controls hint, and the return / camera side buttons. Hidden while
-- the player is in the lobby.
function Hud.setArenaHudVisible(v: boolean)
	if sidePanel then
		sidePanel.Visible = v
	end
	if towerPanel then
		towerPanel.Visible = v
	end
	if waveBtn then
		waveBtn.Visible = v
	end
	if autoWaveBtn then
		autoWaveBtn.Visible = v
	end
	if inventoryBtn then
		inventoryBtn.Visible = v
	end
	if inventoryPanel and not v then
		inventoryPanel.Visible = false
	end
	if controlsHint then
		controlsHint.Visible = v
	end
	if returnBtn then
		returnBtn.Visible = v
	end
	if cameraBtn then
		cameraBtn.Visible = v
	end
	if shopBtn then
		shopBtn.Visible = v
	end
	if gunToggleBtn then
		gunToggleBtn.Visible = v
	end
	if shopPanel and not v then
		shopPanel.Visible = false
	end
	if not v then
		Hud.setCrosshairVisible(false)
	end
end

return Hud
