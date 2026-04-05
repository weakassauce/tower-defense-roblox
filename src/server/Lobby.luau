--!strict
-- src/server/Lobby.luau
-- Builds the lobby: a stone platform high above the arena with four
-- themed portals. Only the Realm Defense portal is currently active and
-- teleports players to the arena; the other three are visual stubs for
-- future realms.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")

local RealmDefs = require(ReplicatedStorage.Shared.RealmDefs)
local GamePassConfig = require(ReplicatedStorage.Shared.GamePassConfig)
local TowerManager = require(script.Parent.TowerManager)

local Lobby = {}

export type PortalRefs = {
	name: string,
	shimmer: Part,
	stateLabel: TextLabel,
	-- Billboard overlay shown directly on the portal's shimmer face when
	-- the realm is locked. Previously we drew a dark metal bar part
	-- across the portal, but the bar obscured the portal and made the
	-- requirement text unreadable. Now the text sits on the portal face
	-- itself and the bar is gone entirely.
	lockOverlay: BillboardGui?,
	active: boolean, -- whether touching it currently fires onEnterRealm
}

export type LobbyData = {
	folder: Folder,
	spawnCFrame: CFrame,
	portals: { PortalRefs },
}

-- Pushed well clear of the arena so nothing from the battle map bleeds
-- into the skybox behind the lobby.
local LOBBY_CENTER = Vector3.new(0, 1500, 3000)
-- Lifted well above the grass so PivotTo teleports don't bury the
-- character inside the island collision. Z is positive so players
-- spawn on a small landing pad behind the main plaza, giving them a
-- full view of the plaza + portals before they walk forward.
local SPAWN_OFFSET = Vector3.new(0, 6, 34)
local PORTAL_ROW_Z_OFFSET = -32
local PORTAL_SPACING = 20

type PortalTheme = {
	name: string,
	label: string,
	active: boolean,
	pillar: Color3,
	beam: Color3,
	shimmer: Color3,
	labelColor: Color3,
	material: Enum.Material,
}

local THEMES: { PortalTheme } = {
	{
		name = "defense",
		label = "REALM DEFENSE",
		active = true,
		pillar = Color3.fromRGB(140, 130, 115),
		beam = Color3.fromRGB(80, 60, 40),
		shimmer = Color3.fromRGB(230, 60, 40),
		labelColor = Color3.fromRGB(232, 194, 143),
		material = Enum.Material.Slate,
	},
	{
		name = "frost",
		label = "FROST KINGDOM",
		active = true,
		pillar = Color3.fromRGB(144, 164, 174),
		beam = Color3.fromRGB(94, 114, 128),
		shimmer = Color3.fromRGB(100, 200, 255),
		labelColor = Color3.fromRGB(200, 240, 255),
		material = Enum.Material.Ice,
	},
	{
		name = "desert",
		label = "DESERT WASTES",
		active = true,
		pillar = Color3.fromRGB(200, 170, 110),
		beam = Color3.fromRGB(150, 120, 70),
		shimmer = Color3.fromRGB(255, 200, 80),
		labelColor = Color3.fromRGB(255, 220, 150),
		material = Enum.Material.Sand,
	},
	{
		name = "forest",
		label = "DARK FOREST",
		active = true,
		pillar = Color3.fromRGB(70, 55, 40),
		beam = Color3.fromRGB(50, 35, 25),
		shimmer = Color3.fromRGB(80, 200, 100),
		labelColor = Color3.fromRGB(140, 230, 160),
		material = Enum.Material.WoodPlanks,
	},
	{
		name = "space",
		label = "VOID FRONTIER",
		active = true,
		pillar = Color3.fromRGB(60, 52, 90),
		beam = Color3.fromRGB(40, 34, 65),
		shimmer = Color3.fromRGB(180, 90, 240),
		labelColor = Color3.fromRGB(220, 180, 255),
		material = Enum.Material.Metal,
	},
}

local function makePart(parent: Instance, name: string, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

local function buildPortal(
	parent: Instance,
	theme: PortalTheme,
	center: Vector3,
	onTouched: (Player) -> ()
): PortalRefs
	local folder = Instance.new("Folder")
	folder.Name = "Portal_" .. theme.name
	folder.Parent = parent

	local cx = center.X
	local cy = center.Y
	local cz = center.Z

	-- Foundation block
	makePart(folder, "Foundation", {
		Size = Vector3.new(14, 1, 6),
		Position = Vector3.new(cx, cy + 0.5, cz),
		Color = theme.pillar,
		Material = theme.material,
	})

	-- Left + right pillars
	local pillarH = 13
	makePart(folder, "PillarL", {
		Size = Vector3.new(2.4, pillarH, 2.4),
		Position = Vector3.new(cx - 5, cy + 1 + pillarH / 2, cz),
		Color = theme.pillar,
		Material = theme.material,
	})
	makePart(folder, "PillarR", {
		Size = Vector3.new(2.4, pillarH, 2.4),
		Position = Vector3.new(cx + 5, cy + 1 + pillarH / 2, cz),
		Color = theme.pillar,
		Material = theme.material,
	})

	-- Top beam connecting the pillars
	makePart(folder, "Beam", {
		Size = Vector3.new(12, 2, 3.2),
		Position = Vector3.new(cx, cy + 1 + pillarH + 1, cz),
		Color = theme.beam,
		Material = theme.material,
	})

	-- Shimmering portal surface between the pillars
	local shimmer = makePart(folder, "Shimmer", {
		Size = Vector3.new(7.5, pillarH - 1, 0.5),
		Position = Vector3.new(cx, cy + 1 + (pillarH - 1) / 2, cz),
		Color = theme.shimmer,
		Material = Enum.Material.Neon,
		Transparency = 0.3,
		CanCollide = false,
	})
	-- Faint point light inside the portal to make it glow on the floor
	local light = Instance.new("PointLight")
	light.Color = theme.shimmer
	light.Range = 14
	light.Brightness = 1.2
	light.Parent = shimmer

	-- Realm label floating above the beam
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(280, 70)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0
	billboard.Adornee = folder:FindFirstChild("Beam")
	billboard.Parent = folder:FindFirstChild("Beam")

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.fromScale(1, 0.55)
	nameLabel.Position = UDim2.fromScale(0, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = theme.label
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.TextSize = 26
	nameLabel.TextColor3 = theme.labelColor
	nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	nameLabel.TextStrokeTransparency = 0
	nameLabel.Parent = billboard

	local stateLabel = Instance.new("TextLabel")
	stateLabel.Name = "StateLabel"
	stateLabel.Size = UDim2.fromScale(1, 0.45)
	stateLabel.Position = UDim2.fromScale(0, 0.55)
	stateLabel.BackgroundTransparency = 1
	stateLabel.Text = "[ TOUCH TO ENTER ]"
	stateLabel.Font = Enum.Font.GothamBold
	stateLabel.TextSize = 15
	stateLabel.TextColor3 = Color3.fromRGB(120, 255, 140)
	stateLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	stateLabel.TextStrokeTransparency = 0
	stateLabel.Parent = billboard

	-- Lock overlay billboard that gets added when locked. Stored as a
	-- ref so we can destroy it when the portal unlocks later.
	local refs: PortalRefs = {
		name = theme.name,
		shimmer = shimmer,
		stateLabel = stateLabel,
		lockOverlay = nil,
		active = false,
	}

	-- Touch handler is always connected. It delegates to `onTouched`
	-- only when `refs.active` is true so we can lock/unlock at runtime
	-- without rewiring signals.
	local lastTouch: { [Player]: number } = {}
	shimmer.Touched:Connect(function(hit)
		if not refs.active then
			return
		end
		local char = hit:FindFirstAncestorOfClass("Model")
		if not char then
			return
		end
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			return
		end
		local now = tick()
		if lastTouch[player] and now - lastTouch[player] < 1.5 then
			return
		end
		lastTouch[player] = now
		onTouched(player)
	end)

	return refs
end

-- Apply a locked/unlocked state to a portal. Unlocked: bright shimmer,
-- "TOUCH TO ENTER" green label on the beam above. Locked: dim shimmer,
-- a big yellow requirement ("REACH WAVE X IN Y") billboard parented
-- directly to the shimmer face, and the beam label hides so the two
-- don't compete for attention.
local function applyPortalState(refs: PortalRefs, unlocked: boolean, requirementText: string?)
	refs.active = unlocked
	if unlocked then
		refs.shimmer.Transparency = 0.3
		refs.stateLabel.Text = "[ TOUCH TO ENTER ]"
		refs.stateLabel.TextColor3 = Color3.fromRGB(120, 255, 140)
		refs.stateLabel.Visible = true
		if refs.lockOverlay then
			refs.lockOverlay:Destroy()
			refs.lockOverlay = nil
		end
	else
		refs.shimmer.Transparency = 0.78
		-- Hide the tiny beam label while locked; the big in-portal
		-- overlay below carries the requirement text instead.
		refs.stateLabel.Visible = false
		if not refs.lockOverlay then
			local overlay = Instance.new("BillboardGui")
			overlay.Name = "LockOverlay"
			-- Sized to fill most of the portal's shimmer face (~7.5
			-- wide × 12 tall studs). BillboardGui uses stud-based
			-- sizing when SizeOffset is unset.
			overlay.Size = UDim2.fromOffset(280, 110)
			overlay.StudsOffset = Vector3.new(0, 0, 0)
			overlay.AlwaysOnTop = true
			overlay.LightInfluence = 0
			overlay.Adornee = refs.shimmer
			overlay.Parent = refs.shimmer

			local lockedTitle = Instance.new("TextLabel")
			lockedTitle.Name = "LockedTitle"
			lockedTitle.Size = UDim2.fromScale(1, 0.38)
			lockedTitle.Position = UDim2.fromScale(0, 0)
			lockedTitle.BackgroundTransparency = 1
			lockedTitle.Text = "🔒 LOCKED"
			lockedTitle.Font = Enum.Font.GothamBlack
			lockedTitle.TextSize = 28
			lockedTitle.TextColor3 = Color3.fromRGB(255, 215, 100)
			lockedTitle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			lockedTitle.TextStrokeTransparency = 0
			lockedTitle.Parent = overlay

			local reqLabel = Instance.new("TextLabel")
			reqLabel.Name = "RequirementText"
			reqLabel.Size = UDim2.fromScale(1, 0.62)
			reqLabel.Position = UDim2.fromScale(0, 0.38)
			reqLabel.BackgroundTransparency = 1
			reqLabel.Text = requirementText or "[ LOCKED ]"
			reqLabel.Font = Enum.Font.GothamBold
			reqLabel.TextSize = 18
			reqLabel.TextColor3 = Color3.fromRGB(255, 240, 200)
			reqLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			reqLabel.TextStrokeTransparency = 0
			reqLabel.TextWrapped = true
			reqLabel.Parent = overlay

			refs.lockOverlay = overlay
		else
			-- Overlay already exists — just refresh the text in case
			-- the requirement string changed between refreshes.
			local reqLabel = refs.lockOverlay:FindFirstChild("RequirementText") :: TextLabel?
			if reqLabel then
				reqLabel.Text = requirementText or "[ LOCKED ]"
			end
		end
	end
end

-- Places a stone pad with the celestial premium tower spinning on top.
-- Walking into the touch zone prompts the Game Pass purchase for the
-- player. The tower model is rotated server-side via RunService.Heartbeat
-- so every client sees the same spin without extra replication work.
local function buildPremiumPedestal(parent: Instance, center: Vector3)
	local pedestal = Instance.new("Folder")
	pedestal.Name = "PremiumPedestal"
	pedestal.Parent = parent

	local cx, cy, cz = center.X, center.Y, center.Z

	-- Circular stone pad the tower stands on
	local pad = makePart(pedestal, "Pad", {
		Size = Vector3.new(2, 16, 16),
		Position = Vector3.new(cx, cy - 0.5, cz),
		Color = Color3.fromRGB(92, 84, 72),
		Material = Enum.Material.Slate,
	})
	pad.Shape = Enum.PartType.Cylinder
	pad.Orientation = Vector3.new(0, 0, 90)

	-- Darker trim ring
	local trim = makePart(pedestal, "PadTrim", {
		Size = Vector3.new(0.6, 17, 17),
		Position = Vector3.new(cx, cy - 0.2, cz),
		Color = Color3.fromRGB(60, 52, 42),
		Material = Enum.Material.Slate,
	})
	trim.Shape = Enum.PartType.Cylinder
	trim.Orientation = Vector3.new(0, 0, 90)

	-- Runic band of glowing marks around the rim
	for i = 0, 11 do
		local angle = (i / 12) * math.pi * 2
		local rx = cx + math.cos(angle) * 7
		local rz = cz + math.sin(angle) * 7
		local rune = makePart(pedestal, "Rune_" .. i, {
			Size = Vector3.new(0.55, 0.5, 0.55),
			Position = Vector3.new(rx, cy + 0.55, rz),
			Color = Color3.fromRGB(255, 210, 120),
			Material = Enum.Material.Neon,
		})
		rune.CanCollide = false
	end

	-- Build the celestial display model on top of the pad and spin it.
	local display = TowerManager.buildDisplayModel("celestial", Vector3.new(cx, cy + 0.5, cz))
	if display then
		display.Parent = pedestal
		-- Ensure the pivot sits at the pad center so the tower rotates
		-- around its vertical axis (not its bounding-box center, which
		-- would drift off the pedestal as it spins).
		display.WorldPivot = CFrame.new(cx, cy + 0.5, cz)

		local baseCF = CFrame.new(cx, cy + 0.5, cz)
		local angle = 0
		RunService.Heartbeat:Connect(function(dt)
			if not display.Parent then
				return
			end
			angle += dt * 0.5
			display:PivotTo(baseCF * CFrame.Angles(0, angle, 0))
		end)
	end

	-- Floating label above the tower: name, price, tagline
	local labelAnchor = makePart(pedestal, "LabelAnchor", {
		Size = Vector3.new(0.2, 0.2, 0.2),
		Position = Vector3.new(cx, cy + 22, cz),
		Transparency = 1,
		CanCollide = false,
	})
	labelAnchor.CanQuery = false
	labelAnchor.CanTouch = false
	labelAnchor.CastShadow = false

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PedestalLabel"
	billboard.Size = UDim2.fromOffset(320, 90)
	billboard.StudsOffset = Vector3.new(0, 1.5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Adornee = labelAnchor
	billboard.Parent = labelAnchor

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.45)
	title.BackgroundTransparency = 1
	title.Text = "CELESTIAL BASTION"
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 26
	title.TextColor3 = Color3.fromRGB(255, 220, 130)
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.TextStrokeTransparency = 0
	title.Parent = billboard

	local price = Instance.new("TextLabel")
	price.Name = "Price"
	price.Size = UDim2.fromScale(1, 0.3)
	price.Position = UDim2.fromScale(0, 0.45)
	price.BackgroundTransparency = 1
	price.Text = GamePassConfig.PREMIUM_TOWER.price .. " R$"
	price.Font = Enum.Font.GothamBold
	price.TextSize = 22
	price.TextColor3 = Color3.fromRGB(180, 240, 255)
	price.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	price.TextStrokeTransparency = 0
	price.Parent = billboard

	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.Size = UDim2.fromScale(1, 0.25)
	sub.Position = UDim2.fromScale(0, 0.75)
	sub.BackgroundTransparency = 1
	sub.Text = "Step onto the pedestal to purchase"
	sub.Font = Enum.Font.GothamMedium
	sub.TextSize = 14
	sub.TextColor3 = Color3.fromRGB(230, 220, 190)
	sub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	sub.TextStrokeTransparency = 0
	sub.Parent = billboard

	-- Touch zone that prompts the Robux purchase when a player steps
	-- onto the pad. A per-player cooldown stops the prompt from
	-- spamming while they're standing on the pedestal.
	local zone = makePart(pedestal, "PurchaseZone", {
		Size = Vector3.new(16, 24, 16),
		Position = Vector3.new(cx, cy + 10, cz),
		Transparency = 1,
		CanCollide = false,
	})
	zone.CanQuery = false

	local lastPrompt: { [Player]: number } = {}
	zone.Touched:Connect(function(hit)
		local char = hit:FindFirstAncestorOfClass("Model")
		if not char then
			return
		end
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			return
		end
		local now = tick()
		if lastPrompt[player] and now - lastPrompt[player] < 3 then
			return
		end
		lastPrompt[player] = now
		local passId = GamePassConfig.PREMIUM_TOWER.id
		if passId <= 0 then
			return
		end
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, passId)
		end)
	end)
end

-- Shared rune ring + stone pad builder used by both gun pedestals. Draws
-- a circular stone pad with a glowing rune band around the edge. Factored
-- out so the starfire and void reaper pedestals stay visually in sync
-- when we tweak the base (size, material, rune count, etc).
local function buildGunPedestalBase(parent: Instance, center: Vector3, runeColor: Color3)
	local cx, cy, cz = center.X, center.Y, center.Z
	local pad = makePart(parent, "Pad", {
		Size = Vector3.new(2, 16, 16),
		Position = Vector3.new(cx, cy - 0.5, cz),
		Color = Color3.fromRGB(92, 84, 72),
		Material = Enum.Material.Slate,
	})
	pad.Shape = Enum.PartType.Cylinder
	pad.Orientation = Vector3.new(0, 0, 90)

	local trim = makePart(parent, "PadTrim", {
		Size = Vector3.new(0.6, 17, 17),
		Position = Vector3.new(cx, cy - 0.2, cz),
		Color = Color3.fromRGB(60, 52, 42),
		Material = Enum.Material.Slate,
	})
	trim.Shape = Enum.PartType.Cylinder
	trim.Orientation = Vector3.new(0, 0, 90)

	for i = 0, 11 do
		local angle = (i / 12) * math.pi * 2
		local rx = cx + math.cos(angle) * 7
		local rz = cz + math.sin(angle) * 7
		local rune = makePart(parent, "Rune_" .. i, {
			Size = Vector3.new(0.55, 0.5, 0.55),
			Position = Vector3.new(rx, cy + 0.55, rz),
			Color = runeColor,
			Material = Enum.Material.Neon,
		})
		rune.CanCollide = false
	end
end

-- Spec-driven gun pedestal builder. Takes a table describing the gun's
-- parts, title/price text, and Robux pass info, and builds a stone pad
-- with the gun model floating and spinning above it. Touching the pad
-- prompts the Game Pass purchase for the matching pass.
export type GunPartSpec = {
	name: string,
	size: Vector3,
	offset: Vector3,
	color: Color3,
	material: Enum.Material,
	transparency: number?,
	glowRange: number?,
	glowColor: Color3?,
	glowBrightness: number?,
}

export type GunPedestalSpec = {
	pedestalName: string,
	title: string,
	titleColor: Color3,
	price: string,
	priceColor: Color3,
	subText: string,
	runeColor: Color3,
	passId: () -> number,
	parts: { GunPartSpec },
	displayHeight: number, -- y offset above pad where the model hovers
	tiltDeg: number,
	spinSpeed: number,
}

local function buildGunPedestalFromSpec(parent: Instance, center: Vector3, spec: GunPedestalSpec)
	local pedestal = Instance.new("Folder")
	pedestal.Name = spec.pedestalName
	pedestal.Parent = parent

	local cx, cy, cz = center.X, center.Y, center.Z

	buildGunPedestalBase(pedestal, center, spec.runeColor)

	local gunModel = Instance.new("Model")
	gunModel.Name = spec.pedestalName .. "_Display"
	gunModel.Parent = pedestal

	local displayY = cy + spec.displayHeight
	local basePartRef: Part? = nil
	for _, partSpec in spec.parts do
		local p = Instance.new("Part")
		p.Name = partSpec.name
		p.Size = partSpec.size
		p.Position = Vector3.new(cx, displayY, cz) + partSpec.offset
		p.Color = partSpec.color
		p.Material = partSpec.material
		p.Anchored = true
		p.CanCollide = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if partSpec.transparency then
			p.Transparency = partSpec.transparency
		end
		if partSpec.glowRange then
			local light = Instance.new("PointLight")
			light.Color = partSpec.glowColor or partSpec.color
			light.Range = partSpec.glowRange
			light.Brightness = partSpec.glowBrightness or 2
			light.Parent = p
		end
		p.Parent = gunModel
		basePartRef = basePartRef or p
	end

	gunModel.PrimaryPart = basePartRef
	gunModel.WorldPivot = CFrame.new(cx, displayY, cz)

	local baseCF = CFrame.new(cx, displayY, cz) * CFrame.Angles(0, 0, math.rad(spec.tiltDeg))
	local angle = 0
	RunService.Heartbeat:Connect(function(dt)
		if not gunModel.Parent then
			return
		end
		angle += dt * spec.spinSpeed
		gunModel:PivotTo(baseCF * CFrame.Angles(0, angle, 0))
	end)

	-- Floating label above the gun
	local labelAnchor = makePart(pedestal, "LabelAnchor", {
		Size = Vector3.new(0.2, 0.2, 0.2),
		Position = Vector3.new(cx, cy + 16, cz),
		Transparency = 1,
		CanCollide = false,
	})
	labelAnchor.CanQuery = false
	labelAnchor.CanTouch = false
	labelAnchor.CastShadow = false

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PedestalLabel"
	billboard.Size = UDim2.fromOffset(320, 90)
	billboard.StudsOffset = Vector3.new(0, 1.5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Adornee = labelAnchor
	billboard.Parent = labelAnchor

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.45)
	title.BackgroundTransparency = 1
	title.Text = spec.title
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 26
	title.TextColor3 = spec.titleColor
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.TextStrokeTransparency = 0
	title.Parent = billboard

	local price = Instance.new("TextLabel")
	price.Name = "Price"
	price.Size = UDim2.fromScale(1, 0.3)
	price.Position = UDim2.fromScale(0, 0.45)
	price.BackgroundTransparency = 1
	price.Text = spec.price
	price.Font = Enum.Font.GothamBold
	price.TextSize = 22
	price.TextColor3 = spec.priceColor
	price.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	price.TextStrokeTransparency = 0
	price.Parent = billboard

	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.Size = UDim2.fromScale(1, 0.25)
	sub.Position = UDim2.fromScale(0, 0.75)
	sub.BackgroundTransparency = 1
	sub.Text = spec.subText
	sub.Font = Enum.Font.GothamMedium
	sub.TextSize = 14
	sub.TextColor3 = Color3.fromRGB(230, 220, 190)
	sub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	sub.TextStrokeTransparency = 0
	sub.Parent = billboard

	local zone = makePart(pedestal, "PurchaseZone", {
		Size = Vector3.new(16, 24, 16),
		Position = Vector3.new(cx, cy + 10, cz),
		Transparency = 1,
		CanCollide = false,
	})
	zone.CanQuery = false

	local lastPrompt: { [Player]: number } = {}
	zone.Touched:Connect(function(hit)
		local char = hit:FindFirstAncestorOfClass("Model")
		if not char then
			return
		end
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			return
		end
		local now = tick()
		if lastPrompt[player] and now - lastPrompt[player] < 3 then
			return
		end
		lastPrompt[player] = now
		local passId = spec.passId()
		if passId <= 0 then
			return
		end
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, passId)
		end)
	end)
end

-- Void Reaper pedestal spec: twin-barrel auto-shotgun with purple void
-- cores. Floats + spins on the second premium pedestal west of the main
-- gun pedestal so the two premium guns sit side-by-side.
local function buildVoidReaperPedestal(parent: Instance, center: Vector3)
	local spec: GunPedestalSpec = {
		pedestalName = "PremiumVoidReaperPedestal",
		title = "VOID REAPER",
		titleColor = Color3.fromRGB(220, 130, 255),
		price = GamePassConfig.PREMIUM_GUN_2.price .. " R$",
		priceColor = Color3.fromRGB(200, 120, 255),
		subText = "Step onto the pedestal to purchase",
		runeColor = Color3.fromRGB(220, 100, 255),
		passId = function()
			return GamePassConfig.PREMIUM_GUN_2.id
		end,
		displayHeight = 7,
		tiltDeg = -10,
		spinSpeed = 0.7,
		parts = {
			-- Grip
			{
				name = "Grip",
				size = Vector3.new(0.55, 1.5, 0.6),
				offset = Vector3.new(0.8, -0.6, 0),
				color = Color3.fromRGB(30, 12, 50),
				material = Enum.Material.Metal,
			},
			-- Main chassis
			{
				name = "Chassis",
				size = Vector3.new(2.4, 1.1, 0.85),
				offset = Vector3.new(0.4, 0.1, 0),
				color = Color3.fromRGB(55, 25, 90),
				material = Enum.Material.Metal,
			},
			-- Stock
			{
				name = "Stock",
				size = Vector3.new(1.6, 0.85, 0.6),
				offset = Vector3.new(1.8, 0, 0),
				color = Color3.fromRGB(30, 12, 50),
				material = Enum.Material.Metal,
			},
			-- Top barrel
			{
				name = "BarrelTop",
				size = Vector3.new(4, 0.45, 0.45),
				offset = Vector3.new(-1.9, 0.25, 0),
				color = Color3.fromRGB(28, 12, 50),
				material = Enum.Material.Metal,
			},
			-- Bottom barrel
			{
				name = "BarrelBot",
				size = Vector3.new(4, 0.45, 0.45),
				offset = Vector3.new(-1.9, -0.25, 0),
				color = Color3.fromRGB(28, 12, 50),
				material = Enum.Material.Metal,
			},
			-- Top void core
			{
				name = "CoreTop",
				size = Vector3.new(3.8, 0.3, 0.3),
				offset = Vector3.new(-1.9, 0.25, 0),
				color = Color3.fromRGB(200, 80, 255),
				material = Enum.Material.Neon,
				transparency = 0.2,
			},
			-- Bottom void core
			{
				name = "CoreBot",
				size = Vector3.new(3.8, 0.3, 0.3),
				offset = Vector3.new(-1.9, -0.25, 0),
				color = Color3.fromRGB(200, 80, 255),
				material = Enum.Material.Neon,
				transparency = 0.2,
			},
			-- Muzzle shroud crystal (glows)
			{
				name = "Muzzle",
				size = Vector3.new(0.8, 0.9, 0.85),
				offset = Vector3.new(-4.1, 0, 0),
				color = Color3.fromRGB(220, 100, 255),
				material = Enum.Material.Neon,
				transparency = 0.15,
				glowRange = 12,
				glowColor = Color3.fromRGB(200, 80, 255),
				glowBrightness = 2.5,
			},
			-- Drum magazine
			{
				name = "Drum",
				size = Vector3.new(0.9, 0.95, 0.75),
				offset = Vector3.new(0.3, -0.85, 0),
				color = Color3.fromRGB(40, 18, 70),
				material = Enum.Material.Metal,
			},
			{
				name = "DrumGlow",
				size = Vector3.new(0.5, 0.5, 0.78),
				offset = Vector3.new(0.3, -0.85, 0),
				color = Color3.fromRGB(200, 80, 255),
				material = Enum.Material.Neon,
				transparency = 0.35,
			},
			-- Spine fins
			{
				name = "SpineL",
				size = Vector3.new(1.3, 0.3, 0.1),
				offset = Vector3.new(0.1, 0.85, -0.4),
				color = Color3.fromRGB(220, 100, 255),
				material = Enum.Material.Neon,
				transparency = 0.2,
			},
			{
				name = "SpineR",
				size = Vector3.new(1.3, 0.3, 0.1),
				offset = Vector3.new(0.1, 0.85, 0.4),
				color = Color3.fromRGB(220, 100, 255),
				material = Enum.Material.Neon,
				transparency = 0.2,
			},
			-- Trigger
			{
				name = "Trigger",
				size = Vector3.new(0.25, 0.35, 0.15),
				offset = Vector3.new(0.55, -0.1, 0),
				color = Color3.fromRGB(220, 100, 255),
				material = Enum.Material.Neon,
			},
		},
	}
	buildGunPedestalFromSpec(parent, center, spec)
end

-- Places a stone pad with a spinning premium Starfire Rifle model on
-- top. Walking into the touch zone prompts the game pass purchase and
-- grants the gun via the PromptGamePassPurchaseFinished hook in
-- init.server.luau. Gun model is built from basic parts + welds — we
-- can't require the client-side PlayerGun module, so this is a
-- simplified twin of decorateStarfire.
local function buildPremiumGunPedestal(parent: Instance, center: Vector3)
	local pedestal = Instance.new("Folder")
	pedestal.Name = "PremiumGunPedestal"
	pedestal.Parent = parent

	local cx, cy, cz = center.X, center.Y, center.Z

	local pad = makePart(pedestal, "Pad", {
		Size = Vector3.new(2, 16, 16),
		Position = Vector3.new(cx, cy - 0.5, cz),
		Color = Color3.fromRGB(92, 84, 72),
		Material = Enum.Material.Slate,
	})
	pad.Shape = Enum.PartType.Cylinder
	pad.Orientation = Vector3.new(0, 0, 90)

	local trim = makePart(pedestal, "PadTrim", {
		Size = Vector3.new(0.6, 17, 17),
		Position = Vector3.new(cx, cy - 0.2, cz),
		Color = Color3.fromRGB(60, 52, 42),
		Material = Enum.Material.Slate,
	})
	trim.Shape = Enum.PartType.Cylinder
	trim.Orientation = Vector3.new(0, 0, 90)

	for i = 0, 11 do
		local angle = (i / 12) * math.pi * 2
		local rx = cx + math.cos(angle) * 7
		local rz = cz + math.sin(angle) * 7
		local rune = makePart(pedestal, "Rune_" .. i, {
			Size = Vector3.new(0.55, 0.5, 0.55),
			Position = Vector3.new(rx, cy + 0.55, rz),
			Color = Color3.fromRGB(255, 210, 140),
			Material = Enum.Material.Neon,
		})
		rune.CanCollide = false
	end

	-- --- Simplified Starfire Rifle display model ---
	-- The rifle floats at roughly cy+7 and spins around its center via
	-- Heartbeat. Parts are local to `gunModel` so the whole assembly
	-- rotates together.
	local gunModel = Instance.new("Model")
	gunModel.Name = "StarfireDisplay"
	gunModel.Parent = pedestal

	local function gunPart(
		name: string,
		size: Vector3,
		offset: Vector3,
		color: Color3,
		material: Enum.Material,
		transparency: number?
	): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Position = Vector3.new(cx, cy + 7, cz) + offset
		p.Color = color
		p.Material = material
		p.Anchored = true
		p.CanCollide = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if transparency then
			p.Transparency = transparency
		end
		p.Parent = gunModel
		return p
	end

	-- Build the rifle along the world X axis centered on (cx, cy+7, cz)
	-- so rotating around Y reveals the whole silhouette.
	gunPart(
		"Grip",
		Vector3.new(0.5, 1.4, 0.55),
		Vector3.new(0.8, -0.6, 0),
		Color3.fromRGB(60, 52, 100),
		Enum.Material.Metal
	)
	gunPart(
		"Chassis",
		Vector3.new(2.4, 1, 0.8),
		Vector3.new(0.4, 0, 0),
		Color3.fromRGB(80, 70, 130),
		Enum.Material.Metal
	)
	gunPart(
		"Stock",
		Vector3.new(1.6, 0.8, 0.55),
		Vector3.new(1.8, -0.05, 0),
		Color3.fromRGB(60, 52, 100),
		Enum.Material.Metal
	)
	gunPart(
		"Barrel",
		Vector3.new(4.2, 0.4, 0.4),
		Vector3.new(-1.9, 0, 0),
		Color3.fromRGB(50, 45, 85),
		Enum.Material.Metal
	)
	gunPart(
		"BarrelCore",
		Vector3.new(4, 0.28, 0.28),
		Vector3.new(-1.9, 0, 0),
		Color3.fromRGB(255, 220, 140),
		Enum.Material.Neon,
		0.25
	)

	local muzzle = gunPart(
		"MuzzleCrystal",
		Vector3.new(0.7, 0.7, 0.7),
		Vector3.new(-4.1, 0, 0),
		Color3.fromRGB(255, 230, 160),
		Enum.Material.Neon
	)
	local muzzleLight = Instance.new("PointLight")
	muzzleLight.Color = Color3.fromRGB(255, 220, 140)
	muzzleLight.Range = 10
	muzzleLight.Brightness = 2.2
	muzzleLight.Parent = muzzle

	gunPart(
		"Scope",
		Vector3.new(2, 0.55, 0.55),
		Vector3.new(0.3, 0.85, 0),
		Color3.fromRGB(28, 24, 50),
		Enum.Material.Metal
	)
	gunPart(
		"Lens",
		Vector3.new(0.15, 0.45, 0.45),
		Vector3.new(-0.7, 0.85, 0),
		Color3.fromRGB(255, 210, 130),
		Enum.Material.Neon
	)
	gunPart(
		"Mag",
		Vector3.new(0.75, 0.7, 0.45),
		Vector3.new(0.3, -0.7, 0),
		Color3.fromRGB(40, 36, 70),
		Enum.Material.Metal
	)
	gunPart(
		"FinL",
		Vector3.new(1.6, 0.7, 0.12),
		Vector3.new(0.1, 0, -0.5),
		Color3.fromRGB(255, 200, 120),
		Enum.Material.Neon,
		0.25
	)
	gunPart(
		"FinR",
		Vector3.new(1.6, 0.7, 0.12),
		Vector3.new(0.1, 0, 0.5),
		Color3.fromRGB(255, 200, 120),
		Enum.Material.Neon,
		0.25
	)

	-- Tilt the model slightly so it doesn't sit flat — looks like it's
	-- hovering at an angle on the pedestal.
	gunModel.PrimaryPart = gunModel:FindFirstChild("Chassis") :: Part
	gunModel.WorldPivot = CFrame.new(cx, cy + 7, cz)

	local baseCF = CFrame.new(cx, cy + 7, cz) * CFrame.Angles(0, 0, math.rad(-12))
	local angle = 0
	RunService.Heartbeat:Connect(function(dt)
		if not gunModel.Parent then
			return
		end
		angle += dt * 0.6
		gunModel:PivotTo(baseCF * CFrame.Angles(0, angle, 0))
	end)

	-- Floating label above the gun
	local labelAnchor = makePart(pedestal, "LabelAnchor", {
		Size = Vector3.new(0.2, 0.2, 0.2),
		Position = Vector3.new(cx, cy + 16, cz),
		Transparency = 1,
		CanCollide = false,
	})
	labelAnchor.CanQuery = false
	labelAnchor.CanTouch = false
	labelAnchor.CastShadow = false

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PedestalLabel"
	billboard.Size = UDim2.fromOffset(320, 90)
	billboard.StudsOffset = Vector3.new(0, 1.5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Adornee = labelAnchor
	billboard.Parent = labelAnchor

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.45)
	title.BackgroundTransparency = 1
	title.Text = "STARFIRE RIFLE"
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 26
	title.TextColor3 = Color3.fromRGB(255, 220, 140)
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.TextStrokeTransparency = 0
	title.Parent = billboard

	local price = Instance.new("TextLabel")
	price.Name = "Price"
	price.Size = UDim2.fromScale(1, 0.3)
	price.Position = UDim2.fromScale(0, 0.45)
	price.BackgroundTransparency = 1
	price.Text = GamePassConfig.PREMIUM_GUN.price .. " R$"
	price.Font = Enum.Font.GothamBold
	price.TextSize = 22
	price.TextColor3 = Color3.fromRGB(255, 200, 120)
	price.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	price.TextStrokeTransparency = 0
	price.Parent = billboard

	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.Size = UDim2.fromScale(1, 0.25)
	sub.Position = UDim2.fromScale(0, 0.75)
	sub.BackgroundTransparency = 1
	sub.Text = "Step onto the pedestal to purchase"
	sub.Font = Enum.Font.GothamMedium
	sub.TextSize = 14
	sub.TextColor3 = Color3.fromRGB(230, 220, 190)
	sub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	sub.TextStrokeTransparency = 0
	sub.Parent = billboard

	local zone = makePart(pedestal, "PurchaseZone", {
		Size = Vector3.new(16, 24, 16),
		Position = Vector3.new(cx, cy + 10, cz),
		Transparency = 1,
		CanCollide = false,
	})
	zone.CanQuery = false

	local lastPrompt: { [Player]: number } = {}
	zone.Touched:Connect(function(hit)
		local char = hit:FindFirstAncestorOfClass("Model")
		if not char then
			return
		end
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			return
		end
		local now = tick()
		if lastPrompt[player] and now - lastPrompt[player] < 3 then
			return
		end
		lastPrompt[player] = now
		local passId = GamePassConfig.PREMIUM_GUN.id
		if passId <= 0 then
			return
		end
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, passId)
		end)
	end)
end

function Lobby.build(
	onEnterRealm: (Player, string) -> (),
	initialHighestWaves: { [string]: number }
): LobbyData
	local existing = workspace:FindFirstChild("Lobby")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Lobby"
	folder.Parent = workspace

	local cx = LOBBY_CENTER.X
	local cy = LOBBY_CENTER.Y
	local cz = LOBBY_CENTER.Z

	local rng = Random.new(42)

	-- --- Round grass island ---
	-- Main disc (Cylinder shape, rotated flat). Sized to host all 5 realm
	-- portals along the north edge with room to walk around.
	local island = makePart(folder, "Island", {
		Size = Vector3.new(3, 140, 140),
		Position = Vector3.new(cx, cy - 1.5, cz),
		Color = Color3.fromRGB(60, 130, 50),
		Material = Enum.Material.Grass,
	})
	island.Shape = Enum.PartType.Cylinder
	island.Orientation = Vector3.new(0, 0, 90)

	-- Dirt underside that pokes out below the grass for a layered look
	local dirt = makePart(folder, "Dirt", {
		Size = Vector3.new(5, 146, 146),
		Position = Vector3.new(cx, cy - 4, cz),
		Color = Color3.fromRGB(84, 58, 40),
		Material = Enum.Material.Ground,
	})
	dirt.Shape = Enum.PartType.Cylinder
	dirt.Orientation = Vector3.new(0, 0, 90)

	-- --- Central plaza, spawn landing, and curved paths ---
	-- Players spawn on a small stone landing pad south of the main
	-- plaza and walk along a curved path to reach the central hub, from
	-- which more curved paths radiate to each portal and the premium
	-- pedestal. Every path shares the same uniform stone color so the
	-- lobby reads as one coherent walkway network.
	local plazaY = cy + 0.08
	local plazaRadius = 14
	local spawnPadRadius = 9
	local spawnPadCenter = Vector3.new(cx, cy, cz + 34)

	local PATH_COLOR = Color3.fromRGB(122, 112, 96)
	local PATH_EDGE_COLOR = Color3.fromRGB(82, 74, 62)
	local PATH_MATERIAL = Enum.Material.Slate

	-- Portal row positions are computed here (instead of later in the
	-- function) so the path builder can target them; the portal loop
	-- reuses the same locals.
	local portalBaseZ = cz + PORTAL_ROW_Z_OFFSET
	local numPortals = #THEMES
	local firstPortalX = cx - ((numPortals - 1) * PORTAL_SPACING) / 2
	-- Three premium pedestals: celestial tower to the east, starfire gun
	-- to the west, and void reaper gun further south-west so the two
	-- premium guns sit along the same west-side walkway.
	local pedestalCenter = Vector3.new(cx + 42, cy, cz - 8)
	local gunPedestalCenter = Vector3.new(cx - 42, cy, cz - 8)
	local voidReaperPedestalCenter = Vector3.new(cx - 42, cy, cz + 22)

	-- Helper: makes a circular stone pad at `center` with radius `r`.
	local function buildStonePad(name: string, center: Vector3, r: number)
		local pad = makePart(folder, name, {
			Size = Vector3.new(0.4, r * 2, r * 2),
			Position = Vector3.new(center.X, plazaY, center.Z),
			Color = PATH_EDGE_COLOR,
			Material = PATH_MATERIAL,
			CanCollide = false,
		})
		pad.Shape = Enum.PartType.Cylinder
		pad.Orientation = Vector3.new(0, 0, 90)

		local inner = makePart(folder, name .. "Inner", {
			Size = Vector3.new(0.5, (r - 2) * 2, (r - 2) * 2),
			Position = Vector3.new(center.X, plazaY + 0.04, center.Z),
			Color = PATH_COLOR,
			Material = PATH_MATERIAL,
			CanCollide = false,
		})
		inner.Shape = Enum.PartType.Cylinder
		inner.Orientation = Vector3.new(0, 0, 90)
	end

	-- Main plaza + spawn landing pad
	buildStonePad("Plaza", Vector3.new(cx, cy, cz), plazaRadius)
	buildStonePad("SpawnPad", spawnPadCenter, spawnPadRadius)

	-- Glowing rune ring inside the plaza
	for i = 0, 7 do
		local angle = (i / 8) * math.pi * 2
		local rx = cx + math.cos(angle) * (plazaRadius - 4.5)
		local rz = cz + math.sin(angle) * (plazaRadius - 4.5)
		local rune = makePart(folder, "PlazaRune_" .. i, {
			Size = Vector3.new(0.8, 0.3, 0.8),
			Position = Vector3.new(rx, plazaY + 0.22, rz),
			Color = Color3.fromRGB(255, 210, 130),
			Material = Enum.Material.Neon,
			CanCollide = false,
		})
		rune.Orientation = Vector3.new(0, math.deg(angle), 0)
	end

	-- --- Curved path builder ---
	-- Approximates a quadratic bezier (start, control, end) with a
	-- chain of short stone segments so paths arc gently instead of
	-- reading as stiff straight lines. Each segment is also pushed into
	-- pathSegs so the vegetation-rejection helper stays in sync.
	type PathSeg = { x1: number, z1: number, x2: number, z2: number, halfWidth: number }
	local pathSegs: { PathSeg } = {}

	local PATH_SEGMENT_COUNT = 18

	local function buildCurvedPath(
		name: string,
		startPt: Vector3,
		endPt: Vector3,
		width: number,
		curveFactor: number
	)
		local horizontal = Vector3.new(endPt.X - startPt.X, 0, endPt.Z - startPt.Z)
		local length = horizontal.Magnitude
		if length < 0.5 then
			return
		end

		-- Perpendicular in the XZ plane (90° CCW from direction). A
		-- positive curveFactor bulges the path in the +perp direction.
		local dir = horizontal / length
		local perp = Vector3.new(-dir.Z, 0, dir.X)
		local mid = Vector3.new((startPt.X + endPt.X) / 2, plazaY + 0.05, (startPt.Z + endPt.Z) / 2)
		local control = mid + perp * (length * curveFactor)

		local function bezier(t: number): Vector3
			local u = 1 - t
			local p0 = Vector3.new(startPt.X, plazaY + 0.05, startPt.Z)
			local p2 = Vector3.new(endPt.X, plazaY + 0.05, endPt.Z)
			return (u * u) * p0 + (2 * u * t) * control + (t * t) * p2
		end

		local prev = bezier(0)
		for i = 1, PATH_SEGMENT_COUNT do
			local t = i / PATH_SEGMENT_COUNT
			local cur = bezier(t)
			local seg = cur - prev
			local segLen = Vector3.new(seg.X, 0, seg.Z).Magnitude
			if segLen > 0.05 then
				local segMid = (prev + cur) / 2
				-- Add a small overlap so rotated neighboring segments
				-- don't leave visible seams at sharp curvature.
				local part = makePart(folder, name .. "_" .. i, {
					Size = Vector3.new(width, 0.35, segLen + 0.6),
					Position = segMid,
					Color = PATH_COLOR,
					Material = PATH_MATERIAL,
					CanCollide = false,
				})
				part.CFrame = CFrame.lookAt(segMid, cur)
				table.insert(pathSegs, {
					x1 = prev.X,
					z1 = prev.Z,
					x2 = cur.X,
					z2 = cur.Z,
					halfWidth = width / 2,
				})
			end
			prev = cur
		end
	end

	-- Curved path from the spawn landing up to the main plaza.
	buildCurvedPath(
		"SpawnPath",
		Vector3.new(spawnPadCenter.X, 0, spawnPadCenter.Z - spawnPadRadius + 1),
		Vector3.new(cx, 0, cz + plazaRadius - 1),
		7,
		0.08
	)

	-- Five paths from the plaza fanning out to each portal. Curve
	-- factors alternate sign so adjacent paths swerve in opposite
	-- directions, giving the lobby an organic rather than mechanical
	-- feel.
	local PORTAL_CURVE_FACTORS = { 0.22, -0.15, 0.18, -0.15, 0.22 }
	for i, theme in THEMES do
		local portalX = firstPortalX + (i - 1) * PORTAL_SPACING
		local portalTargetZ = portalBaseZ + 4
		buildCurvedPath(
			"PortalPath_" .. theme.name,
			Vector3.new(cx, 0, cz - plazaRadius + 1),
			Vector3.new(portalX, 0, portalTargetZ),
			6,
			PORTAL_CURVE_FACTORS[i] or 0.12
		)
	end

	-- Curved path to the premium tower pedestal (east)
	buildCurvedPath(
		"PedestalPath",
		Vector3.new(cx + plazaRadius - 1, 0, cz),
		Vector3.new(pedestalCenter.X - 8, 0, pedestalCenter.Z),
		5,
		0.2
	)

	-- Curved path to the premium gun pedestal (west)
	buildCurvedPath(
		"GunPedestalPath",
		Vector3.new(cx - plazaRadius + 1, 0, cz),
		Vector3.new(gunPedestalCenter.X + 8, 0, gunPedestalCenter.Z),
		5,
		-0.2
	)

	-- Short link path from the starfire pedestal down to the void reaper
	-- pedestal so the two premium guns sit on one continuous walkway.
	buildCurvedPath(
		"VoidReaperPath",
		Vector3.new(gunPedestalCenter.X, 0, gunPedestalCenter.Z + 8),
		Vector3.new(voidReaperPedestalCenter.X, 0, voidReaperPedestalCenter.Z - 8),
		5,
		0.05
	)

	-- --- Helpers used by the decoration passes ---

	-- Perpendicular distance from point (px, pz) to the XZ segment.
	local function distToSegment(
		px: number,
		pz: number,
		x1: number,
		z1: number,
		x2: number,
		z2: number
	): number
		local dx = x2 - x1
		local dz = z2 - z1
		local lenSq = dx * dx + dz * dz
		if lenSq < 1e-6 then
			local ex = px - x1
			local ez = pz - z1
			return math.sqrt(ex * ex + ez * ez)
		end
		local t = ((px - x1) * dx + (pz - z1) * dz) / lenSq
		t = math.clamp(t, 0, 1)
		local nx = x1 + t * dx
		local nz = z1 + t * dz
		local ex = px - nx
		local ez = pz - nz
		return math.sqrt(ex * ex + ez * ez)
	end

	-- True if (x, z) overlaps the main plaza, the spawn landing pad,
	-- or any curved path segment, with `clearance` extra buffer so
	-- decorations don't crowd the walkways.
	local function onPathOrPlaza(x: number, z: number, clearance: number): boolean
		local dxp = x - cx
		local dzp = z - cz
		local plazaLimit = plazaRadius + clearance
		if dxp * dxp + dzp * dzp < plazaLimit * plazaLimit then
			return true
		end
		local dxs = x - spawnPadCenter.X
		local dzs = z - spawnPadCenter.Z
		local spawnLimit = spawnPadRadius + clearance
		if dxs * dxs + dzs * dzs < spawnLimit * spawnLimit then
			return true
		end
		for _, seg in pathSegs do
			if distToSegment(x, z, seg.x1, seg.z1, seg.x2, seg.z2) < seg.halfWidth + clearance then
				return true
			end
		end
		return false
	end

	-- True if (x, z) overlaps any premium pedestal (celestial tower east,
	-- starfire gun west, void reaper gun south-west) so decorations don't
	-- clip into the display models or obstruct the touch zones.
	local function onPedestal(x: number, z: number, clearance: number): boolean
		local limit = 9 + clearance
		local dx = x - pedestalCenter.X
		local dz = z - pedestalCenter.Z
		if dx * dx + dz * dz < limit * limit then
			return true
		end
		local gx = x - gunPedestalCenter.X
		local gz = z - gunPedestalCenter.Z
		if gx * gx + gz * gz < limit * limit then
			return true
		end
		local vx = x - voidReaperPedestalCenter.X
		local vz = z - voidReaperPedestalCenter.Z
		return vx * vx + vz * vz < limit * limit
	end

	-- Tries up to `attempts` random positions until one passes the
	-- path/plaza/pedestal checks; returns nil if every attempt fails.
	local function randomOffPathPoint(
		minR: number,
		maxR: number,
		clearance: number,
		attempts: number
	): (number?, number?)
		for _ = 1, attempts do
			local angle = rng:NextNumber() * math.pi * 2
			local r = rng:NextNumber(minR, maxR)
			local px = cx + math.cos(angle) * r
			local pz = cz + math.sin(angle) * r
			if not onPathOrPlaza(px, pz, clearance) and not onPedestal(px, pz, clearance) then
				return px, pz
			end
		end
		return nil, nil
	end

	-- --- Grass tone patches (off-plaza only) ---
	local grassTones = {
		Color3.fromRGB(73, 150, 60),
		Color3.fromRGB(55, 120, 45),
		Color3.fromRGB(82, 160, 65),
	}
	for i = 1, 22 do
		local px, pz = randomOffPathPoint(plazaRadius + 2, 46, 1, 12)
		if px and pz then
			local patch = makePart(folder, "GrassPatch_" .. i, {
				Size = Vector3.new(rng:NextNumber(4, 9), 0.3, rng:NextNumber(4, 9)),
				Position = Vector3.new(px, cy + 0.05, pz),
				Color = grassTones[rng:NextInteger(1, #grassTones)],
				Material = Enum.Material.Grass,
				CanCollide = false,
			})
			patch.Orientation = Vector3.new(0, rng:NextNumber() * 360, 0)
		end
	end

	-- --- Natural boulders around the edge (never on a path) ---
	local rockColors = {
		Color3.fromRGB(118, 112, 100),
		Color3.fromRGB(96, 90, 80),
		Color3.fromRGB(135, 128, 115),
	}
	for i = 1, 14 do
		local bx, bz = randomOffPathPoint(40, 50, 4, 16)
		if bx and bz then
			local sx = rng:NextNumber(3, 7)
			local sy = rng:NextNumber(2.5, 5)
			local sz = rng:NextNumber(3, 7)
			local rock = makePart(folder, "Boulder_" .. i, {
				Size = Vector3.new(sx, sy, sz),
				Position = Vector3.new(bx, cy + sy / 2 - 0.3, bz),
				Color = rockColors[rng:NextInteger(1, #rockColors)],
				Material = Enum.Material.Rock,
			})
			rock.Orientation = Vector3.new(
				rng:NextNumber(-15, 15),
				rng:NextNumber(0, 360),
				rng:NextNumber(-15, 15)
			)
		end
	end

	-- --- Tall rock berm around the outer edge of the island ---
	-- A dense two-row wall of overlapping boulders that rises well
	-- above the player's eye level so looking outward from the plaza
	-- the void skybox behind the island is fully blocked. Back row
	-- is the tall view-blocking wall; front row is shorter chunks
	-- pushed to the rim so the wall reads as layered, not monolithic.
	local ringCount = 110
	for i = 1, ringCount do
		local angle = (i / ringCount) * math.pi * 2 + rng:NextNumber() * 0.04

		-- Back row: tall pillars sized 14-24 studs high (player eye
		-- is ~cy+5, so a 14+ stud rock rising from cy is a solid
		-- horizon blocker).
		local backR = 60 + rng:NextNumber() * 4
		local bx = cx + math.cos(angle) * backR
		local bz = cz + math.sin(angle) * backR
		if not (onPathOrPlaza(bx, bz, 2) or onPedestal(bx, bz, 3)) then
			local sx = rng:NextNumber(5, 10)
			local sy = rng:NextNumber(14, 24)
			local sz = rng:NextNumber(5, 10)
			local tall = makePart(folder, "EdgeWall_" .. i, {
				Size = Vector3.new(sx, sy, sz),
				Position = Vector3.new(bx, cy + sy / 2 - 1, bz),
				Color = rockColors[rng:NextInteger(1, #rockColors)],
				Material = Enum.Material.Rock,
			})
			tall.Orientation = Vector3.new(
				rng:NextNumber(-10, 10),
				rng:NextNumber(0, 360),
				rng:NextNumber(-10, 10)
			)
		end

		-- Front row: chunky rocks nudged outward toward the rim so
		-- the wall feels layered rather than a single cliff face.
		local frontAngle = angle + rng:NextNumber(-0.03, 0.03)
		local frontR = 65 + rng:NextNumber() * 4
		local fx = cx + math.cos(frontAngle) * frontR
		local fz = cz + math.sin(frontAngle) * frontR
		if not (onPathOrPlaza(fx, fz, 2) or onPedestal(fx, fz, 3)) then
			local sx = rng:NextNumber(4, 8)
			local sy = rng:NextNumber(7, 14)
			local sz = rng:NextNumber(4, 8)
			local front = makePart(folder, "EdgeRock_" .. i, {
				Size = Vector3.new(sx, sy, sz),
				Position = Vector3.new(fx, cy + sy / 2 - 0.6, fz),
				Color = rockColors[rng:NextInteger(1, #rockColors)],
				Material = Enum.Material.Rock,
			})
			front.Orientation = Vector3.new(
				rng:NextNumber(-15, 15),
				rng:NextNumber(0, 360),
				rng:NextNumber(-15, 15)
			)
		end
	end

	-- Hanging rock chunks that dangle below the island rim — sells the
	-- "floating in the sky" feel the way game loading screens do.
	local hangingCount = 28
	for i = 1, hangingCount do
		local angle = rng:NextNumber() * math.pi * 2
		local r = 62 + rng:NextNumber() * 8
		local hx = cx + math.cos(angle) * r
		local hz = cz + math.sin(angle) * r
		local drop = 3 + rng:NextNumber() * 9
		local sx = rng:NextNumber(3, 6)
		local sy = rng:NextNumber(4, 9)
		local sz = rng:NextNumber(3, 6)
		local hang = makePart(folder, "HangingRock_" .. i, {
			Size = Vector3.new(sx, sy, sz),
			Position = Vector3.new(hx, cy - drop - sy / 2, hz),
			Color = rockColors[rng:NextInteger(1, #rockColors)],
			Material = Enum.Material.Rock,
			CanCollide = false,
		})
		hang.Orientation =
			Vector3.new(rng:NextNumber(-25, 25), rng:NextNumber(0, 360), rng:NextNumber(-25, 25))
	end

	-- (Removed) Distant mountain range — the snow-topped peaks around
	-- the lobby have been stripped out so the skybox reads cleaner and
	-- draws the eye back to the island + portals instead of a wall of
	-- grey rock. If we want distant silhouette later, prefer a simple
	-- fog / skybox art swap rather than hundreds of rock slab parts.

	-- Bigger statement boulders placed in the south half of the island
	-- (the "dead zone" where no path runs) so they frame the plaza
	-- without blocking any walkway.
	local bigRockSpots = {
		Vector3.new(cx - 28, 0, cz + 28),
		Vector3.new(cx + 28, 0, cz + 28),
		Vector3.new(cx - 44, 0, cz + 18),
		Vector3.new(cx + 44, 0, cz + 18),
		Vector3.new(cx - 20, 0, cz + 46),
		Vector3.new(cx + 20, 0, cz + 46),
	}
	for i, spot in bigRockSpots do
		if onPathOrPlaza(spot.X, spot.Z, 6) or onPedestal(spot.X, spot.Z, 6) then
			continue
		end
		local sx = rng:NextNumber(6, 10)
		local sy = rng:NextNumber(6, 10)
		local sz = rng:NextNumber(6, 10)
		local rock = makePart(folder, "BigBoulder_" .. i, {
			Size = Vector3.new(sx, sy, sz),
			Position = Vector3.new(spot.X, cy + sy / 2 - 0.4, spot.Z),
			Color = rockColors[rng:NextInteger(1, #rockColors)],
			Material = Enum.Material.Rock,
		})
		rock.Orientation =
			Vector3.new(rng:NextNumber(-18, 18), rng:NextNumber(0, 360), rng:NextNumber(-18, 18))

		-- Pile a smaller rock next to each big one for a clustered look
		local offA = rng:NextNumber() * math.pi * 2
		local small = makePart(folder, "BigBoulderPile_" .. i, {
			Size = Vector3.new(
				rng:NextNumber(2.5, 4.2),
				rng:NextNumber(2, 3.2),
				rng:NextNumber(2.5, 4.2)
			),
			Position = Vector3.new(
				spot.X + math.cos(offA) * (sx / 2 + 1.2),
				cy + 1.1,
				spot.Z + math.sin(offA) * (sz / 2 + 1.2)
			),
			Color = rockColors[rng:NextInteger(1, #rockColors)],
			Material = Enum.Material.Rock,
		})
		small.Orientation =
			Vector3.new(rng:NextNumber(-20, 20), rng:NextNumber(0, 360), rng:NextNumber(-20, 20))
	end

	-- --- Trees scattered around the platform edges ---
	local trunkColor = Color3.fromRGB(88, 54, 32)
	local canopyColors = {
		Color3.fromRGB(34, 110, 40),
		Color3.fromRGB(52, 140, 50),
		Color3.fromRGB(24, 95, 32),
	}
	for i = 1, 18 do
		local tx, tz = randomOffPathPoint(34, 50, 4, 16)
		if tx and tz then
			local height = rng:NextNumber(8, 14)
			local trunkThickness = rng:NextNumber(1.2, 1.8)
			makePart(folder, "TreeTrunk_" .. i, {
				Size = Vector3.new(trunkThickness, height, trunkThickness),
				Position = Vector3.new(tx, cy + height / 2, tz),
				Color = trunkColor,
				Material = Enum.Material.Wood,
			})
			local canopySize = rng:NextNumber(6, 9)
			local canopy = makePart(folder, "TreeCanopy_" .. i, {
				Size = Vector3.new(canopySize, canopySize, canopySize),
				Position = Vector3.new(tx, cy + height + canopySize / 2 - 1.5, tz),
				Color = canopyColors[rng:NextInteger(1, #canopyColors)],
				Material = Enum.Material.Grass,
				CanCollide = false,
			})
			canopy.Shape = Enum.PartType.Ball
		end
	end

	-- --- Flower patches for color ---
	local flowerColors = {
		Color3.fromRGB(255, 210, 80),
		Color3.fromRGB(235, 80, 100),
		Color3.fromRGB(180, 100, 230),
		Color3.fromRGB(255, 255, 255),
	}
	for i = 1, 40 do
		local fx, fz = randomOffPathPoint(plazaRadius + 3, 50, 1, 12)
		if fx and fz then
			local flower = makePart(folder, "Flower_" .. i, {
				Size = Vector3.new(0.5, 0.6, 0.5),
				Position = Vector3.new(fx, cy + 0.35, fz),
				Color = flowerColors[rng:NextInteger(1, #flowerColors)],
				Material = Enum.Material.Neon,
				CanCollide = false,
			})
			flower.Shape = Enum.PartType.Ball
		end
	end

	-- --- Small pond tucked into the south-west corner ---
	-- Placed well clear of every path so it's pure decoration.
	local pondX = cx - 34
	local pondZ = cz + 30
	local pond = makePart(folder, "Pond", {
		Size = Vector3.new(1, 14, 10),
		Position = Vector3.new(pondX, cy - 0.2, pondZ),
		Color = Color3.fromRGB(60, 140, 200),
		Material = Enum.Material.Water,
		Transparency = 0.25,
		CanCollide = false,
	})
	pond.Shape = Enum.PartType.Cylinder
	pond.Orientation = Vector3.new(0, 0, 90)
	for i = 1, 6 do
		local angle = (i / 6) * math.pi * 2
		local sx = pondX + math.cos(angle) * 7
		local sz = pondZ + math.sin(angle) * 5
		makePart(folder, "PondRock_" .. i, {
			Size = Vector3.new(
				rng:NextNumber(1.6, 2.6),
				rng:NextNumber(1, 1.8),
				rng:NextNumber(1.6, 2.6)
			),
			Position = Vector3.new(sx, cy + 0.4, sz),
			Color = Color3.fromRGB(80, 110, 60),
			Material = Enum.Material.Rock,
		})
	end

	-- --- Invisible containment walls around the island ---
	local WALL_HALF = 75
	local WALL_HEIGHT = 70
	local WALL_THICKNESS = 2
	local function makeInvisibleWall(name: string, size: Vector3, pos: Vector3)
		local w = makePart(folder, name, {
			Size = size,
			Position = pos,
			Color = Color3.fromRGB(0, 0, 0),
			Material = Enum.Material.SmoothPlastic,
			Transparency = 1,
			CanCollide = true,
		})
		w.CanTouch = false
		w.CanQuery = false
		w.CastShadow = false
	end
	makeInvisibleWall(
		"LobbyWallN",
		Vector3.new(WALL_HALF * 2 + WALL_THICKNESS * 2, WALL_HEIGHT, WALL_THICKNESS),
		Vector3.new(cx, cy + WALL_HEIGHT / 2, cz - WALL_HALF)
	)
	makeInvisibleWall(
		"LobbyWallS",
		Vector3.new(WALL_HALF * 2 + WALL_THICKNESS * 2, WALL_HEIGHT, WALL_THICKNESS),
		Vector3.new(cx, cy + WALL_HEIGHT / 2, cz + WALL_HALF)
	)
	makeInvisibleWall(
		"LobbyWallE",
		Vector3.new(WALL_THICKNESS, WALL_HEIGHT, WALL_HALF * 2),
		Vector3.new(cx + WALL_HALF, cy + WALL_HEIGHT / 2, cz)
	)
	makeInvisibleWall(
		"LobbyWallW",
		Vector3.new(WALL_THICKNESS, WALL_HEIGHT, WALL_HALF * 2),
		Vector3.new(cx - WALL_HALF, cy + WALL_HEIGHT / 2, cz)
	)

	-- --- Portals along the north edge ---
	-- portalBaseZ, numPortals and firstPortalX were already computed
	-- above so the path builder could target them; reuse the same vars
	-- here to keep portal positions and path endpoints in lockstep.
	local portals: { PortalRefs } = {}
	for i, theme in THEMES do
		local portalCenter = Vector3.new(firstPortalX + (i - 1) * PORTAL_SPACING, cy, portalBaseZ)
		local realmName = theme.name
		local refs = buildPortal(folder, theme, portalCenter, function(player)
			onEnterRealm(player, realmName)
		end)
		table.insert(portals, refs)

		local unlocked = RealmDefs.isUnlocked(realmName, initialHighestWaves)
		local requirementText: string? = nil
		if not unlocked then
			local def = RealmDefs.get(realmName)
			if def.unlockRequirement then
				local req = def.unlockRequirement
				local reqDef = RealmDefs.get(req.realm)
				requirementText = string.format(
					"[ REACH WAVE %d IN %s ]",
					req.wave,
					string.upper(reqDef.displayName)
				)
			end
		end
		applyPortalState(refs, unlocked, requirementText)
	end

	-- --- Wooden welcome signpost behind the spawn ---
	-- Two short posts holding a horizontal board; the text is painted on
	-- the board with a SurfaceGui so it sits flat on the wood instead of
	-- floating as a billboard.
	-- Sign sits south of the spawn pad (pad center cz+34, radius 9 →
	-- pad edge cz+43). Place the sign another 8 studs back so the
	-- spawn pad and the sign board don't overlap vertically.
	local signPostZ = cz + 54
	local signBoardY = cy + 7
	-- Posts end just below the sign board (board spans cy+4.5 → cy+9.5)
	-- so the wooden posts don't visually cut through the painted letters
	-- on the front face of the board.
	local postHeight = 4.4
	local postY = cy + postHeight / 2
	makePart(folder, "SignPostL", {
		Size = Vector3.new(0.9, postHeight, 0.9),
		Position = Vector3.new(cx - 6, postY, signPostZ),
		Color = Color3.fromRGB(88, 54, 32),
		Material = Enum.Material.Wood,
	})
	makePart(folder, "SignPostR", {
		Size = Vector3.new(0.9, postHeight, 0.9),
		Position = Vector3.new(cx + 6, postY, signPostZ),
		Color = Color3.fromRGB(88, 54, 32),
		Material = Enum.Material.Wood,
	})
	local signBoard = makePart(folder, "SignBoard", {
		Size = Vector3.new(16, 5, 0.6),
		Position = Vector3.new(cx, signBoardY, signPostZ),
		Color = Color3.fromRGB(120, 80, 46),
		Material = Enum.Material.WoodPlanks,
	})
	-- A slightly darker trim so the board has a carved look
	makePart(folder, "SignTrimTop", {
		Size = Vector3.new(17, 0.6, 0.8),
		Position = Vector3.new(cx, signBoardY + 2.6, signPostZ),
		Color = Color3.fromRGB(78, 48, 28),
		Material = Enum.Material.Wood,
	})
	makePart(folder, "SignTrimBottom", {
		Size = Vector3.new(17, 0.6, 0.8),
		Position = Vector3.new(cx, signBoardY - 2.6, signPostZ),
		Color = Color3.fromRGB(78, 48, 28),
		Material = Enum.Material.Wood,
	})

	local function paintSignFace(face: Enum.NormalId)
		local surface = Instance.new("SurfaceGui")
		surface.Name = "SignFace_" .. face.Name
		surface.Face = face
		surface.CanvasSize = Vector2.new(640, 200)
		surface.PixelsPerStud = 40
		surface.LightInfluence = 0
		surface.Adornee = signBoard
		surface.Parent = signBoard

		local title = Instance.new("TextLabel")
		title.Size = UDim2.fromScale(1, 0.6)
		title.Position = UDim2.fromScale(0, 0.05)
		title.BackgroundTransparency = 1
		title.Text = "CHOOSE YOUR REALM"
		title.Font = Enum.Font.GothamBlack
		title.TextScaled = true
		title.TextColor3 = Color3.fromRGB(255, 240, 200)
		title.TextStrokeColor3 = Color3.fromRGB(40, 20, 8)
		title.TextStrokeTransparency = 0
		title.Parent = surface

		local sub = Instance.new("TextLabel")
		sub.Size = UDim2.fromScale(1, 0.3)
		sub.Position = UDim2.fromScale(0, 0.65)
		sub.BackgroundTransparency = 1
		sub.Text = "Walk into a portal to begin"
		sub.Font = Enum.Font.GothamMedium
		sub.TextScaled = true
		sub.TextColor3 = Color3.fromRGB(235, 210, 170)
		sub.TextStrokeColor3 = Color3.fromRGB(40, 20, 8)
		sub.TextStrokeTransparency = 0
		sub.Parent = surface
	end
	-- Paint both faces so the sign is readable from either side
	paintSignFace(Enum.NormalId.Front)
	paintSignFace(Enum.NormalId.Back)

	-- --- Premium celestial tower display pedestal ---
	-- A stone pad with the celestial tower spinning on top so players
	-- can preview the Robux-gated premium tower from all angles, and
	-- walking onto the pad triggers the Game Pass purchase prompt.
	buildPremiumPedestal(folder, pedestalCenter)
	buildPremiumGunPedestal(folder, gunPedestalCenter)
	buildVoidReaperPedestal(folder, voidReaperPedestalCenter)

	-- Face the portals (north, -Z direction). Default character LookVector
	-- is -Z already, so no extra rotation is needed now that the spawn
	-- sits at the island center rather than 18 studs south of it.
	local spawnCFrame = CFrame.new(LOBBY_CENTER + SPAWN_OFFSET)
	return {
		folder = folder,
		spawnCFrame = spawnCFrame,
		portals = portals,
	}
end

-- Re-evaluate every portal in the given LobbyData against the current
-- highestWaves table. Called whenever a wave completes on the server so
-- newly unlocked portals visually update immediately.
function Lobby.refreshUnlocks(data: LobbyData, highestWaves: { [string]: number })
	for _, refs in data.portals do
		local unlocked = RealmDefs.isUnlocked(refs.name, highestWaves)
		local requirementText: string? = nil
		if not unlocked then
			local def = RealmDefs.get(refs.name)
			if def.unlockRequirement then
				local req = def.unlockRequirement
				local reqDef = RealmDefs.get(req.realm)
				requirementText = string.format(
					"[ REACH WAVE %d IN %s ]",
					req.wave,
					string.upper(reqDef.displayName)
				)
			end
		end
		applyPortalState(refs, unlocked, requirementText)
	end
end

return Lobby
