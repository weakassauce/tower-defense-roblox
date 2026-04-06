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
local PlayerGun = require(script.Parent.PlayerGun)

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
-- Full ordered list of every tower type the HUD might need to render.
-- buildTowerPanel creates a button for each entry (starting hidden), and
-- setRealmTowers later toggles visibility per realm. Keep this in sync
-- with RealmDefs.UNIVERSAL_TOWERS + every realm's signatureTowers +
-- PREMIUM_TOWER so no signature tower is missing a button.
local TOWER_ORDER = {
	-- Universal base towers (in every realm)
	"basic",
	"sniper",
	"cannon",
	"freeze",
	"flame",
	-- Frost signatures
	"icelance",
	"blizzard_mage",
	"ice_cannon",
	-- Desert signatures
	"sandstorm",
	"sun_archer",
	"pyre_mage",
	-- Forest signatures
	"thornwall",
	"grove_archer",
	"venom_cloud",
	-- Space signatures
	"plasma",
	"void_cannon",
	"tesla_storm",
	-- Premium
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
-- controlsHint removed
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
-- Pickup mode: when ON, the next tap on a placed tower sends it to
-- inventory (mobile-friendly equivalent of right-click pickup). The
-- mode auto-disables after a successful pickup or when the button is
-- tapped again. Desktop players can keep using right-click as a
-- shortcut — both paths fire the same PickupTower remote.
local pickupBtn: TextButton
local pickupBtnStroke: UIStroke
local pickupBtnIcon: TextLabel
local pickupBtnTip: TextLabel
local pickupModeEnabled = false
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
-- Dedicated Robux shop: Celestial tower + Starfire + Void Reaper guns
-- at the top, and 4 cash-pack Developer Products at the bottom. Opens
-- via a side-column button with a 💎 icon. Independent from the gun
-- shop (shopPanel) so premium items have a home separate from the
-- gold-priced progression shop.
local robuxShopPanel: Frame
local robuxShopBtn: TextButton
local onBuyCashPackCallback: ((number) -> ())? = nil
local shopCards: { [string]: { card: Frame, actionBtn: TextButton, statusLabel: TextLabel } } = {}
-- Detail pane refs for the shop preview (viewport + labels). Populated
-- in buildShopPanel and refreshed whenever the selected gun changes.
local shopDetailEmpty: TextLabel? = nil
local shopDetailContent: Frame? = nil
local shopViewportWorld: WorldModel? = nil
local shopCurrentPreviewModel: Model? = nil
local shopDetailName: TextLabel? = nil
local shopDetailStats: TextLabel? = nil
local shopDetailDesc: TextLabel? = nil
local shopDetailCost: TextLabel? = nil
-- Remembers the last gun the player had equipped, so the quick toggle
-- button can re-equip the same gun after unequipping.
local lastEquippedGun: string? = nil
-- Forward-declared so Hud.mount / Hud.onStateUpdate (defined earlier in
-- file order) can call it; the actual body is assigned further down.
local updateShop: () -> ()
-- Forward-declared so buildSideButtons (which wires shopBtn.Activated)
-- can reach into the shop selection logic defined later in the file.
local selectShopGun: (gunKey: string?) -> ()
-- Forward-declared so Hud.onStateUpdate can notify listeners when an
-- auto-clear selection transition happens (e.g. on gun equip).
local fireSelectionChanged: () -> ()
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
-- Fired whenever hudHoverCount crosses zero: called with `true` when
-- the pointer enters the first tracked button, and `false` when it
-- leaves the last. init.client uses this to auto-holster the player's
-- gun so it doesn't get in the way of clicking UI.
local onHoverTransition: ((boolean) -> ())? = nil

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

-- The 5 right-side buttons are stacked as a vertically-centered column:
-- 5 × 64 tall + 4 × 10 gap = 360 total. Top button y-offset = -180 from
-- the screen center; each subsequent button adds 74 (64 + 10). These
-- constants are shared by buildInventory + buildSideButtons below.
local SIDE_BTN_X = -84
local SIDE_BTN_SIZE = 64
local SIDE_BTN_GAP = 10
-- 7 buttons: inventory, return-to-lobby, camera toggle, gun shop, gun
-- holster/equip, pickup mode, robux shop. Pickup is the mobile
-- equivalent of the right-click pickup shortcut — tap it, then tap a
-- placed tower. The robux shop sits at the bottom of the column and
-- uses a diamond icon so it reads as "premium purchases" at a glance.
local SIDE_BTN_COUNT = 7
local SIDE_COLUMN_HEIGHT = SIDE_BTN_COUNT * SIDE_BTN_SIZE + (SIDE_BTN_COUNT - 1) * SIDE_BTN_GAP
local SIDE_BTN_TOP = -SIDE_COLUMN_HEIGHT / 2

local function sideButtonY(index: number): number
	return SIDE_BTN_TOP + (index - 1) * (SIDE_BTN_SIZE + SIDE_BTN_GAP)
end

local function buildInventory(parent: Instance)
	inventoryBtn = makeTextButton(parent, "InventoryBtn", "🎒")
	inventoryBtn.Size = UDim2.fromOffset(SIDE_BTN_SIZE, SIDE_BTN_SIZE)
	inventoryBtn.Position = UDim2.new(1, SIDE_BTN_X, 0.5, sideButtonY(1))
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

	-- Anchor the panel to the right side of the inventory button so the
	-- panel pops to the left of the button column and tracks the button's
	-- vertical-center position across screen sizes.
	inventoryPanel = makeFrame(parent, "InventoryPanel")
	inventoryPanel.Size = UDim2.fromOffset(320, 560)
	inventoryPanel.AnchorPoint = Vector2.new(1, 0.5)
	inventoryPanel.Position = UDim2.new(1, SIDE_BTN_X - 6, 0.5, 0)
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
	returnBtn.Size = UDim2.fromOffset(SIDE_BTN_SIZE, SIDE_BTN_SIZE)
	returnBtn.Position = UDim2.new(1, SIDE_BTN_X, 0.5, sideButtonY(2))
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
	cameraBtn.Size = UDim2.fromOffset(SIDE_BTN_SIZE, SIDE_BTN_SIZE)
	cameraBtn.Position = UDim2.new(1, SIDE_BTN_X, 0.5, sideButtonY(3))
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
	shopBtn.Size = UDim2.fromOffset(SIDE_BTN_SIZE, SIDE_BTN_SIZE)
	shopBtn.Position = UDim2.new(1, SIDE_BTN_X, 0.5, sideButtonY(4))
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
			-- Reset the selection each time the shop reopens so stats
			-- only show after the player explicitly picks a gun.
			if shopPanel.Visible and selectShopGun then
				selectShopGun(nil)
			end
		end
	end)

	-- Quick equip / unequip toggle for the currently selected gun.
	-- Only clickable when the player owns at least one gun.
	gunToggleBtn = makeTextButton(parent, "GunToggleBtn", "")
	gunToggleBtn.Size = UDim2.fromOffset(SIDE_BTN_SIZE, SIDE_BTN_SIZE)
	gunToggleBtn.Position = UDim2.new(1, SIDE_BTN_X, 0.5, sideButtonY(5))
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

	-- --- Pickup mode button (6th in the column) ---
	-- Mobile-friendly way to remove placed towers into inventory. Tap
	-- the button to arm pickup mode, then tap any placed tower. The
	-- mode auto-disables after a pickup, or when the button is tapped
	-- again, so players don't accidentally delete towers.
	pickupBtn = makeTextButton(parent, "PickupBtn", "")
	pickupBtn.Size = UDim2.fromOffset(SIDE_BTN_SIZE, SIDE_BTN_SIZE)
	pickupBtn.Position = UDim2.new(1, SIDE_BTN_X, 0.5, sideButtonY(6))
	pickupBtn.BackgroundColor3 = COLOR_BG_DARK
	pickupBtn.BackgroundTransparency = 0.1
	addCorner(pickupBtn, 12)
	pickupBtnStroke = addStroke(pickupBtn, COLOR_ACCENT, 2)

	pickupBtnIcon = makeTextLabel(pickupBtn, "Icon", "✋", 30)
	pickupBtnIcon.Size = UDim2.new(1, 0, 0, 44)
	pickupBtnIcon.Position = UDim2.fromOffset(0, 6)
	pickupBtnIcon.TextXAlignment = Enum.TextXAlignment.Center

	pickupBtnTip = makeTextLabel(pickupBtn, "Tip", "PICKUP", 10)
	pickupBtnTip.Font = Enum.Font.GothamBold
	pickupBtnTip.TextColor3 = COLOR_ACCENT_BRIGHT
	pickupBtnTip.Size = UDim2.new(1, 0, 0, 12)
	pickupBtnTip.Position = UDim2.fromOffset(0, 50)
	pickupBtnTip.TextXAlignment = Enum.TextXAlignment.Center

	pickupBtn.Activated:Connect(function()
		Hud.setPickupMode(not pickupModeEnabled)
	end)

	-- --- Robux shop button (7th in the column) ---
	-- Diamond icon, purple stroke so it stands out from the other
	-- gold-economy buttons. Tapping toggles the Robux shop panel with
	-- premium towers/guns and cash packs. Unlike the other side
	-- buttons, this one stays visible in both lobby and arena — the
	-- lobby repositions it to the vertical center (see
	-- Hud.setArenaHudVisible) since the rest of the side column is
	-- hidden there.
	robuxShopBtn = makeTextButton(parent, "RobuxShopBtn", "💎")
	robuxShopBtn.Size = UDim2.fromOffset(SIDE_BTN_SIZE, SIDE_BTN_SIZE)
	robuxShopBtn.Position = UDim2.new(1, SIDE_BTN_X, 0.5, sideButtonY(7))
	robuxShopBtn.BackgroundColor3 = COLOR_BG_DARK
	robuxShopBtn.BackgroundTransparency = 0.1
	robuxShopBtn.TextSize = 30
	addCorner(robuxShopBtn, 12)
	addStroke(robuxShopBtn, Color3.fromRGB(180, 110, 255), 2)

	robuxShopBtn.Activated:Connect(function()
		if robuxShopPanel then
			robuxShopPanel.Visible = not robuxShopPanel.Visible
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
	-- Critical: crosshair must NEVER absorb input. Active=false and
	-- Selectable=false together guarantee clicks pass straight through
	-- to whatever GUI element or 3D part is beneath the cursor. Without
	-- this, clicking a HUD button while the crosshair was hovering it
	-- could be eaten by the crosshair frame and never reach the button.
	crosshair.Active = false
	crosshair.Selectable = false
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
		arm.Active = false
		arm.Selectable = false
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
	dot.Active = false
	dot.Selectable = false
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

-- Install MouseEnter / MouseLeave handlers on every GuiButton under
-- PlayerGui so we can reliably detect when the player is hovering a
-- clickable element. Called once on mount (walks the whole tree) and
-- then keeps listening for newly added buttons so dynamically built
-- widgets like inventory slots, tower cards, AND buttons in separate
-- ScreenGuis like the tutorial overlay all get tracked automatically.
--
-- We also dedup with a per-button `hovered` flag: without it, a single
-- rapid re-enter (or an overlapping button stack) could bump the
-- counter twice but only decrement once, stranding the crosshair
-- hidden / the gun holstered.
local trackedButtons: { [GuiButton]: boolean } = {}

local function trackHover(inst: Instance)
	if not inst:IsA("GuiButton") or trackedButtons[inst] then
		return
	end
	trackedButtons[inst] = true
	local hovered = false
	inst.MouseEnter:Connect(function()
		if hovered then
			return
		end
		hovered = true
		hudHoverCount += 1
		if hudHoverCount == 1 and onHoverTransition then
			onHoverTransition(true)
		end
	end)
	inst.MouseLeave:Connect(function()
		if not hovered then
			return
		end
		hovered = false
		hudHoverCount = math.max(0, hudHoverCount - 1)
		if hudHoverCount == 0 and onHoverTransition then
			onHoverTransition(false)
		end
	end)
	-- If the button is destroyed while still hovered, release the
	-- counter so the state doesn't get stuck above zero and leave the
	-- gun permanently holstered.
	inst.AncestryChanged:Connect(function(_, parent)
		if parent == nil and hovered then
			hovered = false
			hudHoverCount = math.max(0, hudHoverCount - 1)
			if hudHoverCount == 0 and onHoverTransition then
				onHoverTransition(false)
			end
		end
	end)
end

-- --- Section: gun shop panel ---

-- --- Section: Robux shop ---
-- Dedicated panel for premium (Robux) purchases. Top row: the 1 premium
-- tower (Celestial Bastion) + 2 premium guns (Starfire, Void Reaper).
-- Bottom row: 4 cash-pack Developer Products that grant in-game gold.
-- Independent from the gun shop so cash packs and premium items aren't
-- buried inside the normal gold progression.
local function buildRobuxShopPanel(parent: Instance)
	robuxShopPanel = makeFrame(parent, "RobuxShopPanel")
	robuxShopPanel.Size = UDim2.fromOffset(760, 520)
	robuxShopPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	robuxShopPanel.Position = UDim2.fromScale(0.5, 0.5)
	robuxShopPanel.BackgroundTransparency = 0.1
	robuxShopPanel.Visible = false
	addCorner(robuxShopPanel, 14)
	addStroke(robuxShopPanel, Color3.fromRGB(180, 110, 255), 2)
	addGradient(robuxShopPanel, Color3.fromRGB(30, 18, 40), Color3.fromRGB(14, 8, 20))

	local title = makeTextLabel(robuxShopPanel, "Title", "💎  ROBUX SHOP", 22)
	title.TextColor3 = Color3.fromRGB(230, 180, 255)
	title.Size = UDim2.new(1, 0, 0, 36)
	title.Position = UDim2.fromOffset(0, 14)
	title.TextXAlignment = Enum.TextXAlignment.Center

	local closeBtn = makeTextButton(robuxShopPanel, "Close", "✕")
	closeBtn.Size = UDim2.fromOffset(34, 34)
	closeBtn.Position = UDim2.new(1, -46, 0, 12)
	closeBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 80)
	closeBtn.TextColor3 = Color3.fromRGB(230, 180, 255)
	addCorner(closeBtn, 8)
	addStroke(closeBtn, Color3.fromRGB(180, 110, 255), 2)
	closeBtn.Activated:Connect(function()
		robuxShopPanel.Visible = false
	end)

	-- --- Top row: premium tower + 2 premium guns ---
	local premiumHeader = makeTextLabel(robuxShopPanel, "PremiumHeader", "PREMIUM UNLOCKS", 14)
	premiumHeader.TextColor3 = Color3.fromRGB(220, 170, 255)
	premiumHeader.Size = UDim2.new(1, -40, 0, 20)
	premiumHeader.Position = UDim2.fromOffset(20, 58)
	premiumHeader.TextXAlignment = Enum.TextXAlignment.Left

	local function makePremiumCard(
		cardParent: Instance,
		x: number,
		name: string,
		icon: string,
		description: string,
		price: number,
		onBuy: () -> ()
	)
		local card = makeFrame(cardParent, name .. "Card")
		card.Size = UDim2.fromOffset(230, 200)
		card.Position = UDim2.fromOffset(x, 86)
		card.BackgroundColor3 = Color3.fromRGB(40, 22, 60)
		addCorner(card, 10)
		addStroke(card, Color3.fromRGB(180, 110, 255), 2)

		local iconLabel = makeTextLabel(card, "Icon", icon, 54)
		iconLabel.Size = UDim2.new(1, 0, 0, 70)
		iconLabel.Position = UDim2.fromOffset(0, 10)
		iconLabel.TextXAlignment = Enum.TextXAlignment.Center

		local nameLabel = makeTextLabel(card, "Name", name, 16)
		nameLabel.TextColor3 = Color3.fromRGB(230, 200, 255)
		nameLabel.Size = UDim2.new(1, -16, 0, 20)
		nameLabel.Position = UDim2.fromOffset(8, 80)
		nameLabel.TextXAlignment = Enum.TextXAlignment.Center

		local desc = makeTextLabel(card, "Desc", description, 12)
		desc.Font = Enum.Font.GothamMedium
		desc.TextColor3 = COLOR_TEXT_DIM
		desc.Size = UDim2.new(1, -16, 0, 52)
		desc.Position = UDim2.fromOffset(8, 102)
		desc.TextWrapped = true
		desc.TextXAlignment = Enum.TextXAlignment.Center

		local buyBtn = makeTextButton(card, "Buy", string.format("%d R$", price))
		buyBtn.Size = UDim2.fromOffset(180, 34)
		buyBtn.AnchorPoint = Vector2.new(0.5, 0)
		buyBtn.Position = UDim2.new(0.5, 0, 0, 158)
		buyBtn.BackgroundColor3 = Color3.fromRGB(90, 50, 140)
		buyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		buyBtn.TextSize = 15
		addCorner(buyBtn, 8)
		addStroke(buyBtn, Color3.fromRGB(180, 110, 255), 2)
		buyBtn.Activated:Connect(onBuy)
	end

	makePremiumCard(
		robuxShopPanel,
		30,
		GamePassConfig.PREMIUM_TOWER.name,
		"🏰",
		GamePassConfig.PREMIUM_TOWER.description,
		GamePassConfig.PREMIUM_TOWER.price,
		function()
			-- Route through the existing BuyGun / PlaceTower prompt path.
			-- The premium tower purchase is normally triggered by clicking
			-- the celestial card in the tower picker, but we can also
			-- initiate the GamePass prompt directly on the client so the
			-- user doesn't need to hunt for it in the picker.
			local passId = GamePassConfig.PREMIUM_TOWER.id
			if passId > 0 then
				pcall(function()
					MarketplaceService:PromptGamePassPurchase(player, passId)
				end)
			end
		end
	)
	makePremiumCard(
		robuxShopPanel,
		265,
		GamePassConfig.PREMIUM_GUN.name,
		"🌟",
		GamePassConfig.PREMIUM_GUN.description,
		GamePassConfig.PREMIUM_GUN.price,
		function()
			if onBuyGunCallback then
				onBuyGunCallback(GamePassConfig.PREMIUM_GUN_KEY)
			end
		end
	)
	makePremiumCard(
		robuxShopPanel,
		500,
		GamePassConfig.PREMIUM_GUN_2.name,
		"💀",
		GamePassConfig.PREMIUM_GUN_2.description,
		GamePassConfig.PREMIUM_GUN_2.price,
		function()
			if onBuyGunCallback then
				onBuyGunCallback(GamePassConfig.PREMIUM_GUN_2_KEY)
			end
		end
	)

	-- --- Bottom row: 4 cash packs ---
	local cashHeader = makeTextLabel(robuxShopPanel, "CashHeader", "CASH PACKS", 14)
	cashHeader.TextColor3 = Color3.fromRGB(255, 220, 120)
	cashHeader.Size = UDim2.new(1, -40, 0, 20)
	cashHeader.Position = UDim2.fromOffset(20, 310)
	cashHeader.TextXAlignment = Enum.TextXAlignment.Left

	local function formatNumber(n: number): string
		-- "25000" → "25,000". Simple thousands-separator.
		local s = tostring(n)
		local out = ""
		for i = 1, #s do
			out = out .. s:sub(i, i)
			local fromRight = #s - i
			if fromRight > 0 and fromRight % 3 == 0 then
				out = out .. ","
			end
		end
		return out
	end

	for i, pack in GamePassConfig.CASH_PACKS do
		local card = makeFrame(robuxShopPanel, "CashPack_" .. i)
		card.Size = UDim2.fromOffset(165, 150)
		card.Position = UDim2.fromOffset(25 + (i - 1) * 180, 338)
		card.BackgroundColor3 = Color3.fromRGB(50, 38, 16)
		addCorner(card, 10)
		addStroke(card, Color3.fromRGB(255, 200, 80), 2)

		local icon = makeTextLabel(card, "Icon", "💰", 38)
		icon.Size = UDim2.new(1, 0, 0, 48)
		icon.Position = UDim2.fromOffset(0, 10)
		icon.TextXAlignment = Enum.TextXAlignment.Center

		local amount = makeTextLabel(card, "Amount", formatNumber(pack.cashAmount), 18)
		amount.TextColor3 = Color3.fromRGB(255, 230, 140)
		amount.Size = UDim2.new(1, -16, 0, 22)
		amount.Position = UDim2.fromOffset(8, 60)
		amount.TextXAlignment = Enum.TextXAlignment.Center

		local label = makeTextLabel(card, "Label", pack.label, 12)
		label.Font = Enum.Font.GothamMedium
		label.TextColor3 = COLOR_TEXT_DIM
		label.Size = UDim2.new(1, -16, 0, 16)
		label.Position = UDim2.fromOffset(8, 84)
		label.TextXAlignment = Enum.TextXAlignment.Center

		local buyBtn = makeTextButton(card, "Buy", string.format("%d R$", pack.robuxPrice))
		buyBtn.Size = UDim2.fromOffset(135, 30)
		buyBtn.AnchorPoint = Vector2.new(0.5, 0)
		buyBtn.Position = UDim2.new(0.5, 0, 0, 108)
		buyBtn.BackgroundColor3 = Color3.fromRGB(140, 90, 30)
		buyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		buyBtn.TextSize = 14
		addCorner(buyBtn, 8)
		addStroke(buyBtn, Color3.fromRGB(255, 200, 80), 2)
		local productId = pack.productId
		buyBtn.Activated:Connect(function()
			if onBuyCashPackCallback then
				onBuyCashPackCallback(productId)
			end
		end)
	end

	-- Footer note so the developer sees why purchases might not fire
	-- in a fresh place until real product IDs are configured.
	local footer = makeTextLabel(
		robuxShopPanel,
		"Footer",
		"Configure real Game Pass / Developer Product IDs in GamePassConfig.luau.",
		11
	)
	footer.Font = Enum.Font.GothamMedium
	footer.TextColor3 = Color3.fromRGB(140, 110, 170)
	footer.Size = UDim2.new(1, -40, 0, 16)
	footer.Position = UDim2.new(0, 20, 1, -28)
	footer.TextXAlignment = Enum.TextXAlignment.Center
end

local function buildShopPanel(parent: Instance)
	shopPanel = makeFrame(parent, "ShopPanel")
	shopPanel.Size = UDim2.fromOffset(760, 460)
	shopPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	shopPanel.Position = UDim2.fromScale(0.5, 0.5)
	shopPanel.BackgroundTransparency = 0.1
	shopPanel.Visible = false
	addCorner(shopPanel, 14)
	addStroke(shopPanel, COLOR_ACCENT, 2)
	addGradient(shopPanel, Color3.fromRGB(30, 20, 12), Color3.fromRGB(18, 12, 6))

	local title = makeTextLabel(shopPanel, "Title", "ARMORY", 22)
	title.TextColor3 = COLOR_ACCENT_BRIGHT
	title.Size = UDim2.new(1, 0, 0, 36)
	title.Position = UDim2.fromOffset(0, 10)
	title.TextXAlignment = Enum.TextXAlignment.Center

	-- Close X button in the top-right corner of the panel
	local closeBtn = makeTextButton(shopPanel, "Close", "×")
	closeBtn.Size = UDim2.fromOffset(36, 36)
	closeBtn.Position = UDim2.new(1, -46, 0, 10)
	closeBtn.TextSize = 28
	closeBtn.BackgroundColor3 = Color3.fromRGB(90, 30, 30)
	addCorner(closeBtn, 8)
	addStroke(closeBtn, COLOR_DANGER, 1)
	closeBtn.Activated:Connect(function()
		shopPanel.Visible = false
	end)

	-- --- Left pane: scrollable list of gun rows ---
	local leftPane = makeFrame(shopPanel, "LeftPane")
	leftPane.Size = UDim2.new(0, 300, 1, -60)
	leftPane.Position = UDim2.fromOffset(12, 50)
	leftPane.BackgroundTransparency = 1

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Size = UDim2.fromScale(1, 1)
	list.Position = UDim2.fromOffset(0, 0)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.ScrollBarImageColor3 = COLOR_ACCENT
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.fromScale(0, 0)
	list.Parent = leftPane

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 6)
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
		card.Size = UDim2.new(1, 0, 0, 66)
		card.BackgroundColor3 = COLOR_BG_CARD
		card.BackgroundTransparency = 0.2
		card.LayoutOrder = order
		addCorner(card, 10)
		addStroke(card, COLOR_ACCENT, 1)

		local icon = makeTextLabel(card, "Icon", def.icon, 30)
		icon.Size = UDim2.fromOffset(52, 66)
		icon.Position = UDim2.fromOffset(6, 0)
		icon.TextXAlignment = Enum.TextXAlignment.Center

		local nameLbl = makeTextLabel(card, "Name", def.name, 15)
		nameLbl.TextColor3 = COLOR_ACCENT_BRIGHT
		nameLbl.Size = UDim2.new(1, -170, 0, 22)
		nameLbl.Position = UDim2.fromOffset(62, 10)
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left

		local statusLabel = makeTextLabel(card, "Status", string.format("%dg", def.cost), 11)
		statusLabel.TextColor3 = COLOR_GOLD_TEXT
		statusLabel.Size = UDim2.new(1, -170, 0, 14)
		statusLabel.Position = UDim2.fromOffset(62, 34)
		statusLabel.TextXAlignment = Enum.TextXAlignment.Left

		local actionBtn = makeTextButton(card, "Action", "BUY")
		actionBtn.Size = UDim2.fromOffset(94, 34)
		actionBtn.Position = UDim2.new(1, -102, 0.5, -17)
		actionBtn.BackgroundColor3 = Color3.fromRGB(76, 175, 80)
		actionBtn.TextSize = 14
		addCorner(actionBtn, 8)
		addStroke(actionBtn, Color3.fromRGB(165, 214, 167), 2)

		actionBtn.Activated:Connect(function()
			if currentState.ownedGuns and currentState.ownedGuns[gunKey] then
				if currentState.equippedGun == gunKey then
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

		-- Clicking the row background (anywhere except the action button)
		-- selects the gun so the right pane shows its preview + stats.
		local selectArea = Instance.new("TextButton")
		selectArea.Name = "SelectArea"
		selectArea.Text = ""
		selectArea.BackgroundTransparency = 1
		selectArea.Size = UDim2.new(1, -110, 1, 0)
		selectArea.Position = UDim2.fromOffset(0, 0)
		selectArea.ZIndex = 2
		selectArea.Parent = card
		selectArea.Activated:Connect(function()
			selectShopGun(gunKey)
		end)

		shopCards[gunKey] = { card = card, actionBtn = actionBtn, statusLabel = statusLabel }
	end

	-- --- Right pane: preview + stats (only populated on selection) ---
	local rightPane = makeFrame(shopPanel, "RightPane")
	rightPane.Size = UDim2.new(0, 420, 1, -60)
	rightPane.Position = UDim2.fromOffset(324, 50)
	rightPane.BackgroundColor3 = Color3.fromRGB(18, 12, 6)
	rightPane.BackgroundTransparency = 0.25
	addCorner(rightPane, 12)
	addStroke(rightPane, COLOR_ACCENT, 1)

	-- Empty-state hint (shown until the player clicks a gun on the left)
	local emptyHint = makeTextLabel(rightPane, "EmptyHint", "◀  SELECT A WEAPON TO PREVIEW", 16)
	emptyHint.Font = Enum.Font.GothamBold
	emptyHint.TextColor3 = COLOR_TEXT_DIM
	emptyHint.Size = UDim2.fromScale(1, 1)
	emptyHint.Position = UDim2.fromScale(0, 0)
	emptyHint.TextXAlignment = Enum.TextXAlignment.Center
	emptyHint.TextYAlignment = Enum.TextYAlignment.Center
	shopDetailEmpty = emptyHint

	-- Detail content frame — hidden until a gun is selected
	local content = makeFrame(rightPane, "Content")
	content.Size = UDim2.fromScale(1, 1)
	content.Position = UDim2.fromScale(0, 0)
	content.BackgroundTransparency = 1
	content.Visible = false
	shopDetailContent = content

	-- ViewportFrame with a 3D preview of the selected gun model
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "GunPreview"
	viewport.Size = UDim2.new(1, -24, 0, 200)
	viewport.Position = UDim2.fromOffset(12, 12)
	viewport.BackgroundColor3 = Color3.fromRGB(8, 5, 2)
	viewport.BackgroundTransparency = 0.25
	viewport.BorderSizePixel = 0
	viewport.LightColor = Color3.fromRGB(255, 240, 220)
	viewport.LightDirection = Vector3.new(-0.4, -0.8, -0.3)
	viewport.Ambient = Color3.fromRGB(140, 130, 120)
	viewport.Parent = content
	local vpCorner = Instance.new("UICorner")
	vpCorner.CornerRadius = UDim.new(0, 10)
	vpCorner.Parent = viewport

	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = viewport
	shopViewportWorld = worldModel

	-- Camera positioned for a tight side-profile view so the gun fills
	-- the frame. FOV 30 zooms in; the model spins on Y so the player
	-- sees every angle starting from the broadside.
	local vpCamera = Instance.new("Camera")
	vpCamera.FieldOfView = 30
	vpCamera.CFrame = CFrame.lookAt(Vector3.new(3, 0.8, 0), Vector3.new(0, 0.3, 0))
	vpCamera.Parent = viewport
	viewport.CurrentCamera = vpCamera

	local nameLbl = makeTextLabel(content, "Name", "", 22)
	nameLbl.TextColor3 = COLOR_ACCENT_BRIGHT
	nameLbl.Font = Enum.Font.GothamBlack
	nameLbl.Size = UDim2.new(1, -24, 0, 30)
	nameLbl.Position = UDim2.fromOffset(12, 220)
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left
	shopDetailName = nameLbl

	local costLbl = makeTextLabel(content, "Cost", "", 14)
	costLbl.TextColor3 = COLOR_GOLD_TEXT
	costLbl.Font = Enum.Font.GothamBold
	costLbl.Size = UDim2.new(1, -24, 0, 18)
	costLbl.Position = UDim2.fromOffset(12, 250)
	costLbl.TextXAlignment = Enum.TextXAlignment.Left
	shopDetailCost = costLbl

	local statsLbl = makeTextLabel(content, "Stats", "", 13)
	statsLbl.TextColor3 = COLOR_TEXT
	statsLbl.Font = Enum.Font.GothamMedium
	statsLbl.Size = UDim2.new(1, -24, 0, 60)
	statsLbl.Position = UDim2.fromOffset(12, 274)
	statsLbl.TextXAlignment = Enum.TextXAlignment.Left
	statsLbl.TextYAlignment = Enum.TextYAlignment.Top
	statsLbl.RichText = true
	shopDetailStats = statsLbl

	local descLbl = makeTextLabel(content, "Desc", "", 12)
	descLbl.TextColor3 = COLOR_TEXT_DIM
	descLbl.Font = Enum.Font.Gotham
	descLbl.Size = UDim2.new(1, -24, 0, 60)
	descLbl.Position = UDim2.fromOffset(12, 338)
	descLbl.TextXAlignment = Enum.TextXAlignment.Left
	descLbl.TextYAlignment = Enum.TextYAlignment.Top
	descLbl.TextWrapped = true
	shopDetailDesc = descLbl
end

-- Populates the right pane with the given gun and highlights the
-- matching row on the left. Pass nil to clear.
selectShopGun = function(gunKey: string?)
	-- Highlight the active row, dim the others
	for key, refs in shopCards do
		local stroke = refs.card:FindFirstChildOfClass("UIStroke")
		if stroke then
			if key == gunKey then
				stroke.Color = COLOR_ACCENT_BRIGHT
				stroke.Thickness = 3
			else
				stroke.Color = COLOR_ACCENT
				stroke.Thickness = 1
			end
		end
	end

	if not gunKey or not shopDetailContent or not shopDetailEmpty then
		if shopDetailContent then
			shopDetailContent.Visible = false
		end
		if shopDetailEmpty then
			shopDetailEmpty.Visible = true
		end
		if shopCurrentPreviewModel then
			shopCurrentPreviewModel:Destroy()
			shopCurrentPreviewModel = nil
		end
		return
	end

	local def = Guns.defs[gunKey]
	if not def then
		return
	end

	shopDetailEmpty.Visible = false
	shopDetailContent.Visible = true

	-- Clear the old preview and build a fresh one
	if shopCurrentPreviewModel then
		shopCurrentPreviewModel:Destroy()
		shopCurrentPreviewModel = nil
	end
	local model = PlayerGun.buildDisplayModel(gunKey)
	if model and shopViewportWorld then
		model.Parent = shopViewportWorld
		shopCurrentPreviewModel = model
	end

	if shopDetailName then
		shopDetailName.Text = def.name
	end
	if shopDetailCost then
		if gunKey == GamePassConfig.PREMIUM_GUN_KEY then
			shopDetailCost.Text = GamePassConfig.PREMIUM_GUN.price .. " R$  (premium)"
			shopDetailCost.TextColor3 = Color3.fromRGB(120, 200, 255)
		elseif gunKey == GamePassConfig.PREMIUM_GUN_2_KEY then
			shopDetailCost.Text = GamePassConfig.PREMIUM_GUN_2.price .. " R$  (premium)"
			shopDetailCost.TextColor3 = Color3.fromRGB(220, 130, 255)
		elseif def.cost == 0 then
			shopDetailCost.Text = "FREE  (starter)"
			shopDetailCost.TextColor3 = COLOR_TEXT_DIM
		else
			shopDetailCost.Text = string.format("%d gold", def.cost)
			shopDetailCost.TextColor3 = COLOR_GOLD_TEXT
		end
	end
	if shopDetailStats then
		shopDetailStats.Text = string.format(
			"<b>DAMAGE</b> %d   ·   <b>ROF</b> %.1f/s   ·   <b>RANGE</b> %d\n<b>PELLETS</b> %d   ·   <b>SPREAD</b> %.1f°",
			def.damage * def.pellets,
			def.fireRate,
			def.range,
			def.pellets,
			def.spread
		)
	end
	if shopDetailDesc then
		shopDetailDesc.Text = def.description
	end
end

-- Spin the currently previewed gun model so the player sees it from all
-- angles. Guarded by shop visibility so it's a cheap no-op while closed.
RunService.RenderStepped:Connect(function()
	if not shopPanel or not shopPanel.Visible then
		return
	end
	if not shopCurrentPreviewModel or not shopCurrentPreviewModel.PrimaryPart then
		return
	end
	-- Start rotated 90° so the initial view is the broadside profile,
	-- then spin slowly so all angles are visible.
	local angle = tick() * 0.6 + math.pi * 0.5
	shopCurrentPreviewModel:PivotTo(CFrame.new(0, 0.2, 0) * CFrame.Angles(0, angle, 0))
end)

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
	elseif selection.towerType == GamePassConfig.PREMIUM_TOWER_KEY then
		-- Celestial Bastion is a Robux unlock. Show the Robux price
		-- prominently — never "X gold" — and once owned, indicate it
		-- is free to place.
		if ownsPremiumTower() then
			selectedCost.Text = GamePassConfig.PREMIUM_TOWER.price .. " R$ (owned · free)"
		else
			selectedCost.Text = GamePassConfig.PREMIUM_TOWER.price .. " R$"
		end
		selectedCost.TextColor3 = Color3.fromRGB(255, 215, 100)
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

		-- Premium tower: ALWAYS show the Robux price on the card so it
		-- reads as a real-money purchase, whether or not the player
		-- already owns it. Locked look gets a dark background; owned
		-- look gets a brighter gold-trimmed background.
		if towerType == premiumKey then
			if costLabel then
				costLabel.Text = GamePassConfig.PREMIUM_TOWER.price .. " R$"
				costLabel.TextColor3 = COLOR_PREMIUM
			end
			if isSelected then
				btn.BackgroundColor3 = COLOR_PREMIUM
				btn.BackgroundTransparency = 0
				stroke.Color = Color3.fromRGB(255, 255, 220)
				stroke.Thickness = 4
				btn:FindFirstChild("Name").TextColor3 = Color3.fromRGB(60, 40, 10)
				btn:FindFirstChild("Icon").TextColor3 = Color3.fromRGB(60, 40, 10)
				if costLabel then
					costLabel.TextColor3 = Color3.fromRGB(60, 40, 10)
				end
			elseif hasPremium then
				btn.BackgroundColor3 = Color3.fromRGB(50, 35, 10)
				btn.BackgroundTransparency = 0.1
				stroke.Color = COLOR_PREMIUM
				stroke.Thickness = 2
				btn:FindFirstChild("Name").TextColor3 = COLOR_PREMIUM
				btn:FindFirstChild("Icon").TextColor3 = COLOR_PREMIUM
			else
				btn.BackgroundColor3 = Color3.fromRGB(60, 45, 10)
				btn.BackgroundTransparency = 0.1
				stroke.Color = COLOR_PREMIUM
				stroke.Thickness = 3
				btn:FindFirstChild("Name").TextColor3 = COLOR_PREMIUM
				btn:FindFirstChild("Icon").TextColor3 = COLOR_PREMIUM
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
		local empty = makeTextLabel(inventoryList, "Empty", "Tap the PICKUP button to store a placed tower", 13)
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

		local isPremium = item.towerType == GamePassConfig.PREMIUM_TOWER_KEY

		if not isPremium then
			local sellBtn = makeTextButton(slot, "Sell", "Sell +" .. refund .. "g")
			sellBtn.Size = UDim2.fromOffset(84, 40)
			sellBtn.Position = UDim2.new(1, -94, 0.5, -20)
			sellBtn.TextSize = 12
			sellBtn.BackgroundColor3 = Color3.fromRGB(109, 58, 16)
			addCorner(sellBtn, 6)
			addStroke(sellBtn, COLOR_ACCENT_BRIGHT, 1)
			sellBtn.Activated:Connect(function()
				Remotes.SellInventoryItem:FireServer(idx)
			end)
		else
			-- Celestial is unsellable (Robux purchase). Replace the sell
			-- button with a small "PREMIUM" tag so the slot still looks
			-- balanced.
			local tag = makeTextLabel(slot, "PremiumTag", "PREMIUM", 11)
			tag.Size = UDim2.fromOffset(84, 40)
			tag.Position = UDim2.new(1, -94, 0.5, -20)
			tag.TextColor3 = COLOR_ACCENT_BRIGHT
			tag.Font = Enum.Font.GothamBlack
			tag.TextXAlignment = Enum.TextXAlignment.Center
		end

		local selectBtn = Instance.new("TextButton")
		selectBtn.Name = "SelectArea"
		selectBtn.Text = ""
		selectBtn.BackgroundTransparency = 1
		selectBtn.Size = UDim2.new(1, (if isPremium then -100 else -104), 1, 0)
		selectBtn.Position = UDim2.fromOffset(0, 0)
		selectBtn.ZIndex = 5
		selectBtn.Parent = slot

		selectBtn.Activated:Connect(function()
			Hud.selectFromInventory(idx)
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
		local isPremium = gunKey == GamePassConfig.PREMIUM_GUN_KEY
		local isPremium2 = gunKey == GamePassConfig.PREMIUM_GUN_2_KEY
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
		elseif isPremium then
			-- Robux-gated — show the game pass price and route the buy
			-- button through the normal BuyGun remote; the server will
			-- intercept and trigger PromptGamePassPurchase.
			refs.actionBtn.Text = "BUY"
			refs.actionBtn.BackgroundColor3 = Color3.fromRGB(80, 140, 200)
			refs.actionBtn.AutoButtonColor = true
			refs.statusLabel.Text = GamePassConfig.PREMIUM_GUN.price .. " R$"
			refs.statusLabel.TextColor3 = Color3.fromRGB(120, 200, 255)
		elseif isPremium2 then
			-- Second premium (void reaper) — same flow, purple accent.
			refs.actionBtn.Text = "BUY"
			refs.actionBtn.BackgroundColor3 = Color3.fromRGB(140, 80, 200)
			refs.actionBtn.AutoButtonColor = true
			refs.statusLabel.Text = GamePassConfig.PREMIUM_GUN_2.price .. " R$"
			refs.statusLabel.TextColor3 = Color3.fromRGB(220, 130, 255)
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
	buildRobuxShopPanel(screen)
	buildCrosshair(screen)
	-- buildControlsHint removed — user doesn't want instructions overlay
	buildGameOverScreen(screen)
	buildHomeScreen(screen)

	-- Walk the entire PlayerGui once to install hover tracking on every
	-- GuiButton, then keep listening so any dynamically-added buttons
	-- (inventory slots, tower cards, tutorial overlay, future panels,
	-- etc.) auto-register. Tracking at the PlayerGui level (not just
	-- our own ScreenGui) is what makes the gun auto-holster work for
	-- buttons in overlays we don't directly own.
	for _, d in playerGui:GetDescendants() do
		trackHover(d)
	end
	playerGui.DescendantAdded:Connect(trackHover)

	updateStats()
	updateTowerButtons()
	updateWaveButton()
	updateInventory()
	updateSelectedInfo()
	updateShop()
end

-- Tracks the previously-equipped gun across broadcasts so we can detect
-- the "just equipped a gun" transition and auto-clear any tower that
-- was selected in the picker. Otherwise the player ends up holding a
-- gun with a ghost tower still queued for placement.
local previousEquippedGun: string? = nil

function Hud.onStateUpdate(state)
	currentState = state
	-- Detect a fresh gun equip (was nil/empty, now set) and drop any
	-- tower selection so the preview + ghost vanish. This lets the
	-- player immediately start shooting without having to manually
	-- click their selected tower again to deselect it.
	local newEquipped = state.equippedGun
	if newEquipped and newEquipped ~= previousEquippedGun then
		if selection.towerType ~= "" then
			selection.towerType = ""
			selection.fromInventoryIndex = -1
			lastPanelTower = "basic"
			fireSelectionChanged()
		end
	end
	previousEquippedGun = newEquipped
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
-- crosshair accordingly. Assigned into the forward-declared binding
-- at the top of the file so Hud.onStateUpdate can reach it.
fireSelectionChanged = function()
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
	-- Tear down any gun preview model that was sitting in the shop
	-- viewport from the previous realm so a stale model can't linger
	-- visibly when the shop is reopened in the new realm. selectShopGun
	-- is called with nil so highlight state on the cards also resets.
	if selectShopGun then
		selectShopGun(nil)
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

-- Called by the Robux shop's cash pack buy buttons with the product id
-- of the pack the player tapped. init.client forwards this to
-- MarketplaceService:PromptProductPurchase.
function Hud.setBuyCashPackCallback(fn: (number) -> ())
	onBuyCashPackCallback = fn
end

function Hud.setSelectionChangedCallback(fn: () -> ())
	onSelectionChangedCallback = fn
end

-- Called with `true` when the pointer enters the first tracked button
-- and `false` when it leaves the last. init.client uses this to auto-
-- holster the player's gun while they're mousing over UI, so the
-- crosshair / tool model doesn't get in the way of clicks.
function Hud.setHoverTransitionCallback(fn: (boolean) -> ())
	onHoverTransition = fn
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
-- Placement.luau, so clicks fire the gun only when a gun is equipped.
function Hud.getEquippedGun(): string?
	return currentState.equippedGun
end

-- True while the mouse (or touch) is over any GuiButton under
-- PlayerGui (HUD, tutorial overlay, tutorial prompt, game-over, etc.
-- — trackHover installs listeners on every one). Used both as a
-- belt-and-suspenders gate in Placement's click handler AND as the
-- trigger for auto-holstering the player's gun while they're aiming
-- at a button to click it.
function Hud.isHoveringHudButton(): boolean
	return hudHoverCount > 0
end

-- Monotonically-increasing counter of player gunshots. Placement calls
-- incrementShotsFired() every time it fires the local FireGun remote,
-- and Tutorial reads getShotsFired() to auto-advance the "tap enemies
-- to shoot" step the instant the player pulls the trigger.
local shotsFired = 0

function Hud.incrementShotsFired()
	shotsFired += 1
end

function Hud.getShotsFired(): number
	return shotsFired
end

-- --- Pickup mode ---
-- Toggle the mobile-friendly tower pickup mode. When enabled, the next
-- tap on a placed tower picks it up. Placement.luau reads isPickupMode
-- during its click handler; if true, clicks that hit a tower are routed
-- to PickupTower and the mode is auto-disabled via notifyTowerPickedUp
-- so players don't delete more towers by accident.
function Hud.setPickupMode(enabled: boolean)
	pickupModeEnabled = enabled
	if not pickupBtn or not pickupBtnStroke or not pickupBtnTip then
		return
	end
	if enabled then
		pickupBtn.BackgroundColor3 = Color3.fromRGB(160, 50, 40)
		pickupBtnStroke.Color = Color3.fromRGB(255, 180, 140)
		pickupBtnStroke.Thickness = 3
		pickupBtnTip.Text = "TAP TOWER"
		pickupBtnTip.TextColor3 = Color3.fromRGB(255, 220, 200)
	else
		pickupBtn.BackgroundColor3 = COLOR_BG_DARK
		pickupBtnStroke.Color = COLOR_ACCENT
		pickupBtnStroke.Thickness = 2
		pickupBtnTip.Text = "PICKUP"
		pickupBtnTip.TextColor3 = COLOR_ACCENT_BRIGHT
	end
end

function Hud.isPickupMode(): boolean
	return pickupModeEnabled
end

-- Called by Placement after a successful pickup so the button visual
-- resets to its default state.
function Hud.notifyTowerPickedUp()
	if pickupModeEnabled then
		Hud.setPickupMode(false)
	end
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
	-- controlsHint removed
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
	if pickupBtn then
		pickupBtn.Visible = v
	end
	if shopPanel and not v then
		shopPanel.Visible = false
	end
	-- Robux shop button stays visible in both lobby and arena. In the
	-- arena it sits in slot 7 of the right-side column; in the lobby
	-- the rest of that column is hidden, so center it vertically on
	-- the right edge instead (offset Y by half the button size to get
	-- true center since the button uses default AnchorPoint 0,0).
	if robuxShopBtn then
		if v then
			robuxShopBtn.Position = UDim2.new(1, SIDE_BTN_X, 0.5, sideButtonY(7))
		else
			robuxShopBtn.Position = UDim2.new(1, SIDE_BTN_X, 0.5, -SIDE_BTN_SIZE / 2)
		end
	end
	if not v then
		-- Leaving the arena → drop pickup mode so it doesn't linger
		-- into the next realm entry.
		Hud.setPickupMode(false)
		Hud.setCrosshairVisible(false)
	end
end

return Hud
