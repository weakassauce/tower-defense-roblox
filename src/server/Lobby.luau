--!strict
-- src/server/Lobby.luau
-- Builds the lobby: a stone platform high above the arena with four
-- themed portals. Only the Realm Defense portal is currently active and
-- teleports players to the arena; the other three are visual stubs for
-- future realms.

local Players = game:GetService("Players")

local Lobby = {}

export type LobbyData = {
	folder: Folder,
	spawnCFrame: CFrame,
}

local LOBBY_CENTER = Vector3.new(0, 500, 500)
local PLATFORM_SIZE = Vector3.new(100, 2, 100)
local SPAWN_OFFSET = Vector3.new(0, 2, 18)
local PORTAL_ROW_Z_OFFSET = -32
local PORTAL_SPACING = 22

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
		active = false,
		pillar = Color3.fromRGB(144, 164, 174),
		beam = Color3.fromRGB(94, 114, 128),
		shimmer = Color3.fromRGB(100, 200, 255),
		labelColor = Color3.fromRGB(200, 240, 255),
		material = Enum.Material.Ice,
	},
	{
		name = "desert",
		label = "DESERT WASTES",
		active = false,
		pillar = Color3.fromRGB(200, 170, 110),
		beam = Color3.fromRGB(150, 120, 70),
		shimmer = Color3.fromRGB(255, 200, 80),
		labelColor = Color3.fromRGB(255, 220, 150),
		material = Enum.Material.Sand,
	},
	{
		name = "forest",
		label = "DARK FOREST",
		active = false,
		pillar = Color3.fromRGB(70, 55, 40),
		beam = Color3.fromRGB(50, 35, 25),
		shimmer = Color3.fromRGB(80, 200, 100),
		labelColor = Color3.fromRGB(140, 230, 160),
		material = Enum.Material.WoodPlanks,
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
): ()
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
	billboard.Size = UDim2.fromOffset(240, 60)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0
	billboard.Adornee = folder:FindFirstChild("Beam")
	billboard.Parent = folder:FindFirstChild("Beam")

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.fromScale(1, 0.6)
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
	stateLabel.Size = UDim2.fromScale(1, 0.4)
	stateLabel.Position = UDim2.fromScale(0, 0.6)
	stateLabel.BackgroundTransparency = 1
	stateLabel.Text = theme.active and "[ TOUCH TO ENTER ]" or "[ COMING SOON ]"
	stateLabel.Font = Enum.Font.GothamBold
	stateLabel.TextSize = 16
	stateLabel.TextColor3 = theme.active and Color3.fromRGB(120, 255, 140)
		or Color3.fromRGB(180, 180, 180)
	stateLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	stateLabel.TextStrokeTransparency = 0
	stateLabel.Parent = billboard

	if not theme.active then
		shimmer.Transparency = 0.72
		-- Dim the inactive portal so it reads as "not available"
		local stroke = Instance.new("Part")
		stroke.Name = "LockBar"
		stroke.Size = Vector3.new(8, 0.8, 0.6)
		stroke.Position = Vector3.new(cx, cy + 1 + (pillarH - 1) / 2, cz)
		stroke.Color = Color3.fromRGB(40, 40, 40)
		stroke.Material = Enum.Material.Metal
		stroke.Anchored = true
		stroke.CanCollide = false
		stroke.Parent = folder
		stroke.Rotation = Vector3.new(0, 0, 35)
		return
	end

	-- Active portal: wire up the touch handler
	local lastTouch: { [Player]: number } = {}
	shimmer.Touched:Connect(function(hit)
		local char = hit:FindFirstAncestorOfClass("Model")
		if not char then
			return
		end
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			return
		end
		-- Debounce per player so the touch event doesn't fire dozens of times
		local now = tick()
		if lastTouch[player] and now - lastTouch[player] < 1.5 then
			return
		end
		lastTouch[player] = now
		onTouched(player)
	end)
end

function Lobby.build(arenaSpawnCFrame: CFrame, onEnterArena: (Player) -> ()): LobbyData
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

	-- --- Main platform ---
	makePart(folder, "Platform", {
		Size = PLATFORM_SIZE,
		Position = Vector3.new(cx, cy - 1, cz),
		Color = Color3.fromRGB(95, 90, 82),
		Material = Enum.Material.Slate,
	})

	-- Outer trim
	makePart(folder, "TrimN", {
		Size = Vector3.new(PLATFORM_SIZE.X, 1.2, 2),
		Position = Vector3.new(cx, cy + 0.1, cz - PLATFORM_SIZE.Z / 2 + 1),
		Color = Color3.fromRGB(60, 55, 48),
		Material = Enum.Material.Slate,
	})
	makePart(folder, "TrimS", {
		Size = Vector3.new(PLATFORM_SIZE.X, 1.2, 2),
		Position = Vector3.new(cx, cy + 0.1, cz + PLATFORM_SIZE.Z / 2 - 1),
		Color = Color3.fromRGB(60, 55, 48),
		Material = Enum.Material.Slate,
	})
	makePart(folder, "TrimE", {
		Size = Vector3.new(2, 1.2, PLATFORM_SIZE.Z),
		Position = Vector3.new(cx + PLATFORM_SIZE.X / 2 - 1, cy + 0.1, cz),
		Color = Color3.fromRGB(60, 55, 48),
		Material = Enum.Material.Slate,
	})
	makePart(folder, "TrimW", {
		Size = Vector3.new(2, 1.2, PLATFORM_SIZE.Z),
		Position = Vector3.new(cx - PLATFORM_SIZE.X / 2 + 1, cy + 0.1, cz),
		Color = Color3.fromRGB(60, 55, 48),
		Material = Enum.Material.Slate,
	})

	-- Corner pillars with torch fires on top
	local cornerXs = { -1, 1 }
	local cornerZs = { -1, 1 }
	for _, sx in cornerXs do
		for _, sz in cornerZs do
			local px = cx + sx * (PLATFORM_SIZE.X / 2 - 4)
			local pz = cz + sz * (PLATFORM_SIZE.Z / 2 - 4)
			makePart(folder, "CornerPillar", {
				Size = Vector3.new(3, 14, 3),
				Position = Vector3.new(px, cy + 6, pz),
				Color = Color3.fromRGB(120, 115, 105),
				Material = Enum.Material.Slate,
			})
			makePart(folder, "TorchBasin", {
				Size = Vector3.new(2.2, 0.6, 2.2),
				Position = Vector3.new(px, cy + 13.3, pz),
				Color = Color3.fromRGB(45, 40, 35),
				Material = Enum.Material.Metal,
			})
			local flame = makePart(folder, "TorchFlame", {
				Size = Vector3.new(1.4, 1.8, 1.4),
				Position = Vector3.new(px, cy + 14.5, pz),
				Color = Color3.fromRGB(255, 150, 60),
				Material = Enum.Material.Neon,
				CanCollide = false,
			})
			flame.Shape = Enum.PartType.Ball
			local torchLight = Instance.new("PointLight")
			torchLight.Color = Color3.fromRGB(255, 170, 90)
			torchLight.Range = 22
			torchLight.Brightness = 1.8
			torchLight.Parent = flame
		end
	end

	-- Decorative central rune circle
	local rune = makePart(folder, "RuneCircle", {
		Size = Vector3.new(16, 0.2, 16),
		Position = Vector3.new(cx, cy + 0.1, cz),
		Color = Color3.fromRGB(232, 194, 143),
		Material = Enum.Material.Neon,
		Transparency = 0.55,
		CanCollide = false,
	})
	rune.Shape = Enum.PartType.Cylinder
	rune.Orientation = Vector3.new(0, 0, 90)

	-- --- Portals along the north edge ---
	local portalBaseZ = cz + PORTAL_ROW_Z_OFFSET
	local numPortals = #THEMES
	local firstX = cx - ((numPortals - 1) * PORTAL_SPACING) / 2

	for i, theme in THEMES do
		local portalCenter = Vector3.new(firstX + (i - 1) * PORTAL_SPACING, cy, portalBaseZ)
		buildPortal(folder, theme, portalCenter, function(player)
			-- Teleport the player's character to the arena
			local char = player.Character
			if char then
				char:PivotTo(arenaSpawnCFrame)
				onEnterArena(player)
			end
		end)
	end

	-- --- Welcome sign behind the spawn ---
	local welcomeBeam = makePart(folder, "WelcomeBeam", {
		Size = Vector3.new(40, 2, 2),
		Position = Vector3.new(cx, cy + 11, cz + PLATFORM_SIZE.Z / 2 - 4),
		Color = Color3.fromRGB(80, 60, 40),
		Material = Enum.Material.Wood,
	})
	local welcomeBillboard = Instance.new("BillboardGui")
	welcomeBillboard.Size = UDim2.fromOffset(480, 80)
	welcomeBillboard.StudsOffset = Vector3.new(0, 4, 0)
	welcomeBillboard.LightInfluence = 0
	welcomeBillboard.Adornee = welcomeBeam
	welcomeBillboard.Parent = welcomeBeam

	local welcomeLabel = Instance.new("TextLabel")
	welcomeLabel.Size = UDim2.fromScale(1, 0.6)
	welcomeLabel.BackgroundTransparency = 1
	welcomeLabel.Text = "CHOOSE YOUR REALM"
	welcomeLabel.Font = Enum.Font.GothamBlack
	welcomeLabel.TextSize = 38
	welcomeLabel.TextColor3 = Color3.fromRGB(232, 194, 143)
	welcomeLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	welcomeLabel.TextStrokeTransparency = 0
	welcomeLabel.Parent = welcomeBillboard

	local welcomeSub = Instance.new("TextLabel")
	welcomeSub.Size = UDim2.fromScale(1, 0.4)
	welcomeSub.Position = UDim2.fromScale(0, 0.6)
	welcomeSub.BackgroundTransparency = 1
	welcomeSub.Text = "Walk into a portal to begin"
	welcomeSub.Font = Enum.Font.GothamMedium
	welcomeSub.TextSize = 18
	welcomeSub.TextColor3 = Color3.fromRGB(200, 180, 140)
	welcomeSub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	welcomeSub.TextStrokeTransparency = 0
	welcomeSub.Parent = welcomeBillboard

	local spawnCFrame = CFrame.new(LOBBY_CENTER + SPAWN_OFFSET)
	return {
		folder = folder,
		spawnCFrame = spawnCFrame,
	}
end

return Lobby
