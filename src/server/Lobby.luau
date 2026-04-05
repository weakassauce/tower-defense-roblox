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

	local rng = Random.new(42)

	-- --- Round grass island ---
	-- Main disc (Cylinder shape, rotated flat)
	local island = makePart(folder, "Island", {
		Size = Vector3.new(3, 110, 110),
		Position = Vector3.new(cx, cy - 1.5, cz),
		Color = Color3.fromRGB(60, 130, 50),
		Material = Enum.Material.Grass,
	})
	island.Shape = Enum.PartType.Cylinder
	island.Orientation = Vector3.new(0, 0, 90)

	-- Dirt underside that pokes out below the grass for a layered look
	local dirt = makePart(folder, "Dirt", {
		Size = Vector3.new(5, 115, 115),
		Position = Vector3.new(cx, cy - 4, cz),
		Color = Color3.fromRGB(84, 58, 40),
		Material = Enum.Material.Ground,
	})
	dirt.Shape = Enum.PartType.Cylinder
	dirt.Orientation = Vector3.new(0, 0, 90)

	-- Smaller rough grass patches on top for variation
	local grassTones = {
		Color3.fromRGB(73, 150, 60),
		Color3.fromRGB(55, 120, 45),
		Color3.fromRGB(82, 160, 65),
	}
	for i = 1, 22 do
		local angle = rng:NextNumber() * math.pi * 2
		local r = rng:NextNumber() * 46
		local px = cx + math.cos(angle) * r
		local pz = cz + math.sin(angle) * r
		local patch = makePart(folder, "GrassPatch_" .. i, {
			Size = Vector3.new(rng:NextNumber(4, 9), 0.3, rng:NextNumber(4, 9)),
			Position = Vector3.new(px, cy + 0.05, pz),
			Color = grassTones[rng:NextInteger(1, #grassTones)],
			Material = Enum.Material.Grass,
			CanCollide = false,
		})
		patch.Orientation = Vector3.new(0, rng:NextNumber() * 360, 0)
	end

	-- --- Natural boulders around the edge ---
	local rockColors = {
		Color3.fromRGB(118, 112, 100),
		Color3.fromRGB(96, 90, 80),
		Color3.fromRGB(135, 128, 115),
	}
	for i = 1, 14 do
		local angle = (i / 14) * math.pi * 2 + rng:NextNumber() * 0.2
		local r = 44 + rng:NextNumber() * 6
		local bx = cx + math.cos(angle) * r
		local bz = cz + math.sin(angle) * r
		local sx = rng:NextNumber(3, 7)
		local sy = rng:NextNumber(2.5, 5)
		local sz = rng:NextNumber(3, 7)
		local rock = makePart(folder, "Boulder_" .. i, {
			Size = Vector3.new(sx, sy, sz),
			Position = Vector3.new(bx, cy + sy / 2 - 0.3, bz),
			Color = rockColors[rng:NextInteger(1, #rockColors)],
			Material = Enum.Material.Rock,
		})
		rock.Orientation =
			Vector3.new(rng:NextNumber(-15, 15), rng:NextNumber(0, 360), rng:NextNumber(-15, 15))
	end

	-- --- Trees scattered around the platform edges ---
	local trunkColor = Color3.fromRGB(88, 54, 32)
	local canopyColors = {
		Color3.fromRGB(34, 110, 40),
		Color3.fromRGB(52, 140, 50),
		Color3.fromRGB(24, 95, 32),
	}
	for i = 1, 18 do
		-- Reject positions near the portal row so they don't clip
		local angle, r, tx, tz
		repeat
			angle = rng:NextNumber() * math.pi * 2
			r = rng:NextNumber(30, 48)
			tx = cx + math.cos(angle) * r
			tz = cz + math.sin(angle) * r
		until not (tz < cz + PORTAL_ROW_Z_OFFSET + 14 and math.abs(tx - cx) < 55)

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

	-- --- Central campfire (logs + flame) ---
	-- Ring of stones around the fire pit
	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2
		local sx = cx + math.cos(angle) * 3
		local sz = cz + math.sin(angle) * 3
		makePart(folder, "FireStone_" .. i, {
			Size = Vector3.new(1.4, 1, 1.4),
			Position = Vector3.new(sx, cy + 0.5, sz),
			Color = Color3.fromRGB(96, 90, 80),
			Material = Enum.Material.Rock,
		})
	end
	-- Crossed logs
	local log1 = makePart(folder, "FireLog1", {
		Size = Vector3.new(5, 0.8, 0.8),
		Position = Vector3.new(cx, cy + 1.1, cz),
		Color = Color3.fromRGB(70, 44, 26),
		Material = Enum.Material.Wood,
	})
	log1.Orientation = Vector3.new(0, 25, 0)
	local log2 = makePart(folder, "FireLog2", {
		Size = Vector3.new(5, 0.8, 0.8),
		Position = Vector3.new(cx, cy + 1.1, cz),
		Color = Color3.fromRGB(56, 34, 20),
		Material = Enum.Material.Wood,
	})
	log2.Orientation = Vector3.new(0, -30, 0)
	-- Flame ball with a warm point light
	local flame = makePart(folder, "Flame", {
		Size = Vector3.new(2.4, 2.8, 2.4),
		Position = Vector3.new(cx, cy + 2.8, cz),
		Color = Color3.fromRGB(255, 150, 50),
		Material = Enum.Material.Neon,
		CanCollide = false,
	})
	flame.Shape = Enum.PartType.Ball
	local fireLight = Instance.new("PointLight")
	fireLight.Color = Color3.fromRGB(255, 170, 90)
	fireLight.Range = 28
	fireLight.Brightness = 2.5
	fireLight.Parent = flame

	-- --- Flower patches for color ---
	local flowerColors = {
		Color3.fromRGB(255, 210, 80),
		Color3.fromRGB(235, 80, 100),
		Color3.fromRGB(180, 100, 230),
		Color3.fromRGB(255, 255, 255),
	}
	for i = 1, 40 do
		local angle = rng:NextNumber() * math.pi * 2
		local r = rng:NextNumber(6, 42)
		local fx = cx + math.cos(angle) * r
		local fz = cz + math.sin(angle) * r
		-- Skip near the campfire and the portal row
		if (fx - cx) ^ 2 + (fz - cz) ^ 2 < 36 then
			continue
		end
		if fz < cz + PORTAL_ROW_Z_OFFSET + 10 and math.abs(fx - cx) < 50 then
			continue
		end
		local flower = makePart(folder, "Flower_" .. i, {
			Size = Vector3.new(0.5, 0.6, 0.5),
			Position = Vector3.new(fx, cy + 0.35, fz),
			Color = flowerColors[rng:NextInteger(1, #flowerColors)],
			Material = Enum.Material.Neon,
			CanCollide = false,
		})
		flower.Shape = Enum.PartType.Ball
	end

	-- --- Small pond ---
	local pondX = cx - 22
	local pondZ = cz + 18
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
	-- Mossy stones around the pond
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

	-- --- Portals along the north edge ---
	local portalBaseZ = cz + PORTAL_ROW_Z_OFFSET
	local numPortals = #THEMES
	local firstX = cx - ((numPortals - 1) * PORTAL_SPACING) / 2

	for i, theme in THEMES do
		local portalCenter = Vector3.new(firstX + (i - 1) * PORTAL_SPACING, cy, portalBaseZ)
		buildPortal(folder, theme, portalCenter, function(player)
			local char = player.Character
			if char then
				char:PivotTo(arenaSpawnCFrame)
				onEnterArena(player)
			end
		end)
	end

	-- --- Wooden welcome signpost behind the spawn ---
	local signPostZ = cz + 32
	makePart(folder, "SignPost", {
		Size = Vector3.new(0.8, 10, 0.8),
		Position = Vector3.new(cx, cy + 4.5, signPostZ),
		Color = Color3.fromRGB(88, 54, 32),
		Material = Enum.Material.Wood,
	})
	local signBoard = makePart(folder, "SignBoard", {
		Size = Vector3.new(14, 4, 0.6),
		Position = Vector3.new(cx, cy + 10, signPostZ),
		Color = Color3.fromRGB(120, 80, 46),
		Material = Enum.Material.Wood,
	})
	local welcomeBillboard = Instance.new("BillboardGui")
	welcomeBillboard.Size = UDim2.fromOffset(480, 80)
	welcomeBillboard.StudsOffset = Vector3.new(0, 0, 0)
	welcomeBillboard.LightInfluence = 0
	welcomeBillboard.Adornee = signBoard
	welcomeBillboard.Parent = signBoard

	local welcomeLabel = Instance.new("TextLabel")
	welcomeLabel.Size = UDim2.fromScale(1, 0.6)
	welcomeLabel.BackgroundTransparency = 1
	welcomeLabel.Text = "CHOOSE YOUR REALM"
	welcomeLabel.Font = Enum.Font.GothamBlack
	welcomeLabel.TextSize = 34
	welcomeLabel.TextColor3 = Color3.fromRGB(255, 240, 200)
	welcomeLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	welcomeLabel.TextStrokeTransparency = 0
	welcomeLabel.Parent = welcomeBillboard

	local welcomeSub = Instance.new("TextLabel")
	welcomeSub.Size = UDim2.fromScale(1, 0.4)
	welcomeSub.Position = UDim2.fromScale(0, 0.6)
	welcomeSub.BackgroundTransparency = 1
	welcomeSub.Text = "Walk into a portal to begin"
	welcomeSub.Font = Enum.Font.GothamMedium
	welcomeSub.TextSize = 17
	welcomeSub.TextColor3 = Color3.fromRGB(230, 210, 170)
	welcomeSub.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	welcomeSub.TextStrokeTransparency = 0
	welcomeSub.Parent = welcomeBillboard

	local spawnCFrame = CFrame.new(LOBBY_CENTER + SPAWN_OFFSET) * CFrame.Angles(0, math.pi, 0) -- face the portals
	return {
		folder = folder,
		spawnCFrame = spawnCFrame,
	}
end

return Lobby
