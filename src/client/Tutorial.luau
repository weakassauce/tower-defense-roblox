--!strict
-- src/client/Tutorial.luau
-- Guided tutorial with two phases:
--   1. Lobby phase: a trail of glowing ground-chevrons leads the player
--      from their spawn to the Realm Defense portal. Auto-advances once
--      they step into an arena.
--   2. Arena phase: screen-space bouncing arrow points at HUD buttons,
--      auto-advancing as the player picks a tower, places it, starts a
--      wave, opens the inventory, etc.
-- Each step has a one-line instruction + big emoji icon, a step counter,
-- and a Skip button that aborts the whole tutorial.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Hud = require(script.Parent.Hud)

local Tutorial = {}

-- Theme
local COLOR_BG = Color3.fromRGB(20, 15, 10)
local COLOR_ACCENT = Color3.fromRGB(212, 165, 116)
local COLOR_ACCENT_BRIGHT = Color3.fromRGB(232, 194, 143)
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_TEXT_DIM = Color3.fromRGB(200, 180, 140)
local COLOR_HIGHLIGHT = Color3.fromRGB(255, 215, 100)
local COLOR_GROUND_ARROW = Color3.fromRGB(255, 210, 90)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Device detection — used to tailor tutorial text to the player's
-- input method. "mobile" = touchscreen, "console" = gamepad,
-- "pc" = keyboard + mouse.
type DeviceKind = "pc" | "mobile" | "console"

local function detectDevice(): DeviceKind
	if GuiService:IsTenFootInterface() then
		return "console"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "mobile"
	end
	return "pc"
end

local deviceKind: DeviceKind = detectDevice()

-- Step kinds:
--   walkTo:    build ground-arrow chevron trail to a world target,
--              auto-advances when conditionName is met
--   click:     point screen arrow at a HUD element, auto-advances when
--              conditionName is met
--   manual:    wait for the user to click NEXT
type Step = {
	kind: "walkTo" | "click" | "manual",
	icon: string,
	text: string,
	-- click steps: name of the HUD element to point the screen arrow at
	target: string?,
	-- condition to auto-advance on (walkTo + click steps)
	conditionName: string?,
}

-- --- Step list ---

local function buildSteps(): { Step }
	local isMobile = deviceKind == "mobile"
	local isConsole = deviceKind == "console"

	local tapOrClick = if isMobile then "Tap" elseif isConsole then "Press A on" else "Click"

	local gunDrawText: string
	local gunFireText: string
	if isMobile then
		gunDrawText = "Tap the gun button on the right to draw your weapon!"
		gunFireText = "Shoot the enemies! Tap them to fire!"
	elseif isConsole then
		gunDrawText = "Press Y to draw your gun and fight alongside your towers!"
		gunFireText = "Shoot the enemies! Aim and press RT to fire!"
	else
		gunDrawText = "Press E to draw your gun and fight alongside your towers!"
		gunFireText = "Shoot the enemies! Press E then click to fire!"
	end

	local placeText = if isMobile
		then "Tap a green grass tile to build it!"
		else tapOrClick .. " a grass tile to place it!"

	local cameraHint = if isMobile
		then "Pinch to zoom, drag to look around."
		elseif isConsole
		then "Use the right stick to look around."
		else "Press C to switch between aerial view and walking."

	return {
		{
			kind = "walkTo",
			icon = "🏰",
			text = "Walk into the REALM DEFENSE portal to begin!",
			conditionName = "enteredArena",
		},
		{
			kind = "click",
			icon = "🏹",
			text = tapOrClick .. " a tower from the bottom panel!",
			target = "TowerPanel",
			conditionName = "towerSelected",
		},
		{
			kind = "click",
			icon = "💥",
			text = placeText,
			conditionName = "towerPlaced",
		},
		{
			kind = "click",
			icon = "⚔️",
			text = tapOrClick .. " the green button — here they come!",
			target = "WaveBtn",
			conditionName = "waveStarted",
		},
		{
			kind = "manual",
			icon = "🔫",
			text = gunDrawText,
		},
		{
			kind = "click",
			icon = "🎯",
			text = gunFireText,
			conditionName = "gunFired",
		},
		{
			kind = "manual",
			icon = "🎮",
			text = cameraHint,
		},
		-- --- Shop explanation ---
		{
			kind = "click",
			icon = "🛒",
			text = tapOrClick .. " the armory button to browse and buy stronger guns!",
			target = "ShopBtn",
			conditionName = "shopOpened",
		},
		{
			kind = "manual",
			icon = "💰",
			text = "The armory sells guns for gold. Better guns deal more damage and fire faster!",
		},
		-- --- Pickup + inventory explanation ---
		{
			kind = "manual",
			icon = "✋",
			text = if isMobile
				then "Tap the green PICKUP button, then tap a placed tower to pick it up."
				else "Use the green PICKUP button, then " .. tapOrClick:lower() .. " a placed tower to store it.",
		},
		{
			kind = "click",
			icon = "🎒",
			text = tapOrClick .. " the backpack to open your inventory!",
			target = "InventoryBtn",
			conditionName = "inventoryOpened",
		},
		{
			kind = "manual",
			icon = "📦",
			text = "Your inventory stores picked-up towers. Re-place them anywhere or sell them for gold!",
		},
		{
			kind = "manual",
			icon = "🌟",
			text = "You're all set! Survive more waves to unlock new realms with unique towers!",
		},
	}
end

-- --- State ---

local screen: ScreenGui? = nil
local tooltipIcon: TextLabel? = nil
local tooltipText: TextLabel? = nil
local counterLabel: TextLabel? = nil
local nextBtn: TextButton? = nil
local pointerLabel: TextLabel? = nil
local groundArrows: { BasePart } = {}
local groundArrowsFolder: Folder? = nil
local heartbeatConn: RBXScriptConnection? = nil

local currentStepIndex = 0
local steps: { Step } = {}
local stepStartTowerCount = 0
local stepStartWaveNum = 0
local stepStartShotsFired = 0
local stepStartInventoryCount = 0
local enteredArenaFlag = false
local onCompleteCallback: (() -> ())? = nil
-- Bumped every time a step changes (or the tutorial finishes). The
-- manual-step auto-advance timer captures the generation at schedule
-- time and no-ops if it no longer matches when it fires, so a player
-- who skips / finishes before the timer expires doesn't get advanced
-- into a destroyed tutorial.
local stepGeneration = 0

-- Seconds a "manual" (text-only) step stays on screen before auto-
-- advancing. Manual steps are just welcome / goodbye flavor text with
-- no in-world task to complete, so we run them on a timer instead of
-- making the player click NEXT.
local MANUAL_STEP_AUTO_ADVANCE_SECONDS = 2.5

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

-- --- Ground arrow helpers ---

local function clearGroundArrows()
	for _, p in groundArrows do
		if p.Parent then
			p:Destroy()
		end
	end
	groundArrows = {}
	if groundArrowsFolder then
		groundArrowsFolder:Destroy()
		groundArrowsFolder = nil
	end
end

-- Build a single glowing chevron wedge pointing along `direction`, sitting
-- slightly above the ground at `pos`. Returns the WedgePart so the
-- heartbeat can animate it.
local function makeGroundChevron(pos: Vector3, direction: Vector3): BasePart
	local wedge = Instance.new("WedgePart")
	wedge.Name = "TutorialChevron"
	wedge.Size = Vector3.new(4, 0.4, 5)
	wedge.Anchored = true
	wedge.CanCollide = false
	wedge.CanQuery = false
	wedge.CanTouch = false
	wedge.CastShadow = false
	wedge.Material = Enum.Material.Neon
	wedge.Color = COLOR_GROUND_ARROW
	wedge.Transparency = 0.15
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth

	-- WedgePart's pointy edge faces +Z in local space. Orient it so that
	-- its point aims in `direction`.
	local look = Vector3.new(direction.X, 0, direction.Z)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, 1)
	end
	local lookUnit = look.Unit
	wedge.CFrame = CFrame.lookAt(pos, pos + lookUnit)
		* CFrame.Angles(0, math.rad(180), 0) -- WedgePart points -Z by default

	return wedge
end

-- Try to find the Realm Defense portal's shimmer part in the lobby. This
-- is what the ground trail should guide the player toward. Returns nil
-- if the lobby hasn't been built yet (tutorial should retry next frame).
local function findDefensePortalPart(): BasePart?
	local lobby = workspace:FindFirstChild("Lobby")
	if not lobby then
		return nil
	end
	local portal = lobby:FindFirstChild("Portal_defense")
	if not portal then
		return nil
	end
	return portal:FindFirstChild("Shimmer") :: BasePart?
end

-- Fixed number of chevrons in the trail pool. 8 is enough to span the
-- 77-stud walk from the spawn pad to the defense portal with roughly
-- 9-stud spacing. We pre-allocate once and then reposition them each
-- frame so the trail tracks the player without any destroy/rebuild
-- flicker or stale-position lag.
local GROUND_ARROW_POOL_SIZE = 8
local GROUND_ARROW_LEAD_OFFSET = 4 -- studs in front of HRP where the trail starts
local GROUND_ARROW_TAIL_GAP = 6 -- studs short of the portal where the trail ends

-- Ensure the ground arrow pool + folder exist. Creates them on first
-- call; subsequent calls just return the existing pool. Splitting this
-- off lets updateGroundTrail run every heartbeat without re-parenting
-- anything.
local function ensureGroundArrowPool()
	if groundArrowsFolder and groundArrowsFolder.Parent then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "TutorialGroundArrows"
	folder.Parent = workspace
	groundArrowsFolder = folder
	groundArrows = {}
	for _ = 1, GROUND_ARROW_POOL_SIZE do
		local chevron = makeGroundChevron(Vector3.new(0, -1000, 0), Vector3.new(0, 0, 1))
		chevron.Transparency = 1 -- hidden until first update
		chevron.Parent = folder
		table.insert(groundArrows, chevron)
	end
end

-- Reposition every pooled chevron so the trail leads from the player's
-- current position to the defense portal. Runs every heartbeat (NOT on
-- a timer) so the arrows stay glued to where the player is right now —
-- lag-free responsiveness instead of a 0.5s rebuild window.
local function updateGroundTrail()
	local character = player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	local target = findDefensePortalPart()
	if not target then
		return
	end

	ensureGroundArrowPool()

	local startPos = hrp.Position
	local endPos = Vector3.new(target.Position.X, startPos.Y, target.Position.Z)
	local delta = endPos - startPos
	local dist = delta.Magnitude
	if dist < 4 then
		-- Close enough; hide the trail so arrows don't pile up on the portal.
		for _, chevron in groundArrows do
			chevron.Transparency = 1
		end
		return
	end
	local dir = delta.Unit

	local trailStart = startPos + dir * GROUND_ARROW_LEAD_OFFSET
	local trailEnd = endPos - dir * GROUND_ARROW_TAIL_GAP
	local trailLen = (trailEnd - trailStart).Magnitude
	if trailLen < 2 then
		for _, chevron in groundArrows do
			chevron.Transparency = 1
		end
		return
	end

	-- Chevrons sit ~1 stud above the walkway stone. HRP is 3 studs above
	-- the feet, so (HRP.Y - 2.6) lands just above the plaza surface.
	local trailY = startPos.Y - 2.6

	-- Scale usage of the pool to the trail length so a short walk
	-- doesn't cram 8 chevrons on top of each other. At 10 studs/spacing
	-- we want roughly trailLen / 10 chevrons, clamped to the pool size.
	local active = math.clamp(math.floor(trailLen / 10) + 1, 2, GROUND_ARROW_POOL_SIZE)

	for i, chevron in groundArrows do
		if i <= active then
			local t = active == 1 and 0.5 or (i - 1) / (active - 1)
			local p = trailStart + dir * (trailLen * t)
			-- Fully recompute the CFrame (not just position) so the
			-- chevron instantly rotates if the player circles around
			-- the portal. Using CFrame.lookAt keeps the point always
			-- facing the next chevron.
			chevron.CFrame = CFrame.lookAt(Vector3.new(p.X, trailY, p.Z), Vector3.new(p.X, trailY, p.Z) + dir)
				* CFrame.Angles(0, math.rad(180), 0)
		else
			-- Park unused chevrons far below the map so they don't
			-- visually spam. Also fully transparent as a belt-and-
			-- suspenders hide.
			chevron.CFrame = CFrame.new(0, -1000, 0)
			chevron.Transparency = 1
		end
	end
end

-- Per-frame transparency pulse so the chevrons draw the eye. Position
-- updates happen in updateGroundTrail; this only touches transparency
-- so the pulse is decoupled from the (much more frequent) position
-- refresh and both can run every heartbeat without stomping each other.
local function animateGroundArrows(t: number, active: boolean)
	for i, chevron in groundArrows do
		if not chevron.Parent then
			continue
		end
		if not active then
			chevron.Transparency = 1
			continue
		end
		-- Parked chevrons (Y ~= -1000) stay hidden.
		if chevron.Position.Y < -500 then
			chevron.Transparency = 1
			continue
		end
		local phase = t * 3 + i * 0.35
		local alpha = 0.5 + 0.5 * math.sin(phase)
		chevron.Transparency = 0.1 + alpha * 0.3
	end
end

-- --- Overlay builder ---

local function buildOverlay()
	screen = Instance.new("ScreenGui")
	screen.Name = "TutorialOverlay"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 50
	screen.Parent = playerGui

	-- Big bouncing arrow pointer parented in the Hud ScreenGui so
	-- AbsolutePosition math shares the same coordinate space as the HUD
	-- elements we're pointing at.
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

	tooltipIcon = Instance.new("TextLabel")
	tooltipIcon.Name = "Icon"
	tooltipIcon.Size = UDim2.fromOffset(80, 80)
	tooltipIcon.Position = UDim2.fromOffset(20, 40)
	tooltipIcon.BackgroundTransparency = 1
	tooltipIcon.Text = "👋"
	tooltipIcon.Font = Enum.Font.GothamBlack
	tooltipIcon.TextSize = 56
	tooltipIcon.Parent = tf

	tooltipText = Instance.new("TextLabel")
	tooltipText.Name = "Text"
	tooltipText.Size = UDim2.fromOffset(320, 80)
	tooltipText.Position = UDim2.fromOffset(110, 40)
	tooltipText.BackgroundTransparency = 1
	tooltipText.Text = ""
	tooltipText.Font = Enum.Font.GothamBold
	tooltipText.TextSize = 20
	tooltipText.TextColor3 = COLOR_TEXT
	tooltipText.TextWrapped = true
	tooltipText.TextXAlignment = Enum.TextXAlignment.Left
	tooltipText.TextYAlignment = Enum.TextYAlignment.Center
	tooltipText.Parent = tf

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

-- --- Screen pointer update ---

local function updateScreenPointer(targetName: string?)
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

local function getInventoryCount(): number
	local state = Hud.getState()
	if not state or not state.inventory then
		return 0
	end
	return #state.inventory
end

local function checkCondition(name: string): boolean
	if name == "enteredArena" then
		return enteredArenaFlag
	elseif name == "towerSelected" then
		return Hud.getSelection().towerType ~= ""
	elseif name == "towerPlaced" then
		local localPlayer = game:GetService("Players").LocalPlayer
		local arena = localPlayer and workspace:FindFirstChild("PlayerArena_" .. localPlayer.UserId)
		local folder = arena and arena:FindFirstChild("Towers") or nil
		return folder ~= nil and #folder:GetChildren() > stepStartTowerCount
	elseif name == "waveStarted" then
		local state = Hud.getState()
		return state ~= nil and state.waveNum > stepStartWaveNum
	elseif name == "inventoryOpened" then
		local panel = Hud.getElement("InventoryPanel")
		return panel ~= nil and panel.Visible == true
	elseif name == "shopOpened" then
		local panel = Hud.getElement("ShopPanel")
		return panel ~= nil and panel.Visible == true
	elseif name == "gunOwned" then
		-- True as soon as the player owns any gun. Checked against the
		-- live state broadcast so it ticks once the BuyGun remote round-
		-- trips.
		local state = Hud.getState()
		if not state or not state.ownedGuns then
			return false
		end
		for _ in pairs(state.ownedGuns) do
			return true
		end
		return false
	elseif name == "gunFired" then
		-- Auto-advance the moment the player pulls the trigger at least
		-- once during this step. Placement calls Hud.incrementShotsFired
		-- for every FireGun remote fire.
		return Hud.getShotsFired() > stepStartShotsFired
	elseif name == "towerPickedUp" then
		-- Inventory grew since the step started → a placed tower was
		-- picked up (or placed from panel, then picked back up).
		return getInventoryCount() > stepStartInventoryCount
	elseif name == "inventoryItemUsed" then
		-- Inventory shrank since the step started → the player either
		-- sold or re-placed an item from their backpack.
		return getInventoryCount() < stepStartInventoryCount
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

	-- New step, new generation: any pending manual-step auto-advance
	-- task from the previous step is now stale and will be ignored.
	stepGeneration += 1
	local thisGeneration = stepGeneration

	if tooltipText then
		tooltipText.Text = step.text
	end
	if tooltipIcon then
		tooltipIcon.Text = step.icon
	end
	if counterLabel then
		counterLabel.Text = string.format("STEP %d / %d", index, #steps)
	end
	-- Next button is shown on every step as an escape hatch. Normal
	-- flow is:
	--   * "click" / "walkTo" steps auto-advance when their condition
	--     fires (e.g. tower placed, wave started).
	--   * "manual" flavor-text steps auto-advance on a timer (below).
	-- The button is purely a fallback so a player never gets stuck if
	-- a condition check misses, or who wants to skip through flavor
	-- text faster than the timer.
	if nextBtn then
		nextBtn.Visible = true
		nextBtn.Text = (index == #steps) and "FINISH" or "NEXT  →"
	end

	-- Snapshot state for auto-advance conditions
	if step.conditionName == "towerSelected" then
		Hud.clearSelection() -- force the user to actually click a tower button
	elseif step.conditionName == "towerPlaced" then
		local localPlayer = game:GetService("Players").LocalPlayer
		local arena = localPlayer and workspace:FindFirstChild("PlayerArena_" .. localPlayer.UserId)
		local folder = arena and arena:FindFirstChild("Towers") or nil
		stepStartTowerCount = folder and #folder:GetChildren() or 0
	elseif step.conditionName == "waveStarted" then
		local state = Hud.getState()
		stepStartWaveNum = (state and state.waveNum) or 0
	elseif step.conditionName == "inventoryOpened" then
		local panel = Hud.getElement("InventoryPanel")
		if panel then
			panel.Visible = false
		end
	elseif step.conditionName == "gunFired" then
		stepStartShotsFired = Hud.getShotsFired()
	elseif
		step.conditionName == "towerPickedUp"
		or step.conditionName == "inventoryItemUsed"
	then
		stepStartInventoryCount = getInventoryCount()
	end

	-- Clean up visuals from the previous step before building this one's.
	clearGroundArrows()
	updateScreenPointer(nil)

	if step.kind == "walkTo" then
		-- Spin up the pool and do an immediate position update so the
		-- trail is visible the frame this step starts. The heartbeat
		-- below keeps it glued to the player's position every frame.
		ensureGroundArrowPool()
		updateGroundTrail()
	elseif step.kind == "click" and step.target then
		updateScreenPointer(step.target)
	elseif step.kind == "manual" then
		-- Flavor-text step with no task to complete — auto-advance on
		-- a timer. The generation check makes this a safe no-op if the
		-- player skipped the tutorial or moved on before the delay.
		task.delay(MANUAL_STEP_AUTO_ADVANCE_SECONDS, function()
			if stepGeneration ~= thisGeneration then
				return
			end
			Tutorial._advance()
		end)
	end
end

function Tutorial._advance()
	currentStepIndex += 1
	if currentStepIndex > #steps then
		Tutorial.finish()
		return
	end
	showStep(currentStepIndex)
end

-- Called from init.client's EnterRealm listener so the lobby-phase step
-- knows it's time to auto-advance.
function Tutorial.notifyArenaEntered()
	enteredArenaFlag = true
end

-- --- Public API ---

function Tutorial.start(onComplete: (() -> ())?)
	onCompleteCallback = onComplete
	steps = buildSteps()
	currentStepIndex = 0
	enteredArenaFlag = false
	buildOverlay()
	-- Yield one frame so the overlay + HUD layouts are computed before
	-- we query any AbsolutePosition/AbsoluteSize for highlighting.
	RunService.Heartbeat:Wait()
	Tutorial._advance()

	heartbeatConn = RunService.Heartbeat:Connect(function(_dt)
		if not screen or currentStepIndex <= 0 or currentStepIndex > #steps then
			return
		end
		local step = steps[currentStepIndex]
		if not step then
			return
		end

		-- Refresh the on-screen pointer each frame so it tracks layout
		-- changes (e.g. HUD button moving as wave number grows).
		if step.kind == "click" and step.target then
			updateScreenPointer(step.target)
		end

		-- Ground trail tracks the player's HRP every single frame
		-- (no rebuild timer) so the arrows are instantly responsive
		-- to movement. The chevrons are a fixed-size pool so this is
		-- just 8 CFrame writes per frame — cheap.
		if step.kind == "walkTo" then
			updateGroundTrail()
			animateGroundArrows(os.clock(), true)
		end

		if step.conditionName and checkCondition(step.conditionName) then
			Tutorial._advance()
		end
	end)
end

function Tutorial.finish()
	-- Bumping the generation makes any in-flight task.delay from a
	-- manual step's auto-advance a no-op when it eventually fires.
	stepGeneration += 1
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	clearGroundArrows()
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
	enteredArenaFlag = false
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
