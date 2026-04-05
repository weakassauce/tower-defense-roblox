--!strict
-- src/server/Lobby.luau
-- Builds the lobby: a stone platform high above the arena with four
-- themed portals. Only the Realm Defense portal is currently active and
-- teleports players to the arena; the other three are visual stubs for
-- future realms.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RealmDefs = require(ReplicatedStorage.Shared.RealmDefs)

local Lobby = {}

export type PortalRefs = {
	name: string,
	shimmer: Part,
	stateLabel: TextLabel,
	lockBar: Part?,
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
-- character inside the island collision.
local SPAWN_OFFSET = Vector3.new(0, 6, 18)
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

	-- Lock bar that gets added when locked. Stored as a ref so we can
	-- destroy it when the portal unlocks later.
	local refs: PortalRefs = {
		name = theme.name,
		shimmer = shimmer,
		stateLabel = stateLabel,
		lockBar = nil,
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
-- "TOUCH TO ENTER" green label, no lock bar. Locked: dim shimmer, lock
-- bar across the middle, gray "LOCKED — reach wave X in Y" label.
local function applyPortalState(refs: PortalRefs, unlocked: boolean, requirementText: string?)
	refs.active = unlocked
	if unlocked then
		refs.shimmer.Transparency = 0.3
		refs.stateLabel.Text = "[ TOUCH TO ENTER ]"
		refs.stateLabel.TextColor3 = Color3.fromRGB(120, 255, 140)
		if refs.lockBar then
			refs.lockBar:Destroy()
			refs.lockBar = nil
		end
	else
		refs.shimmer.Transparency = 0.78
		refs.stateLabel.Text = requirementText or "[ LOCKED ]"
		refs.stateLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		if not refs.lockBar then
			local bar = Instance.new("Part")
			bar.Name = "LockBar"
			bar.Size = Vector3.new(9, 0.9, 0.7)
			bar.Anchored = true
			bar.CanCollide = false
			bar.TopSurface = Enum.SurfaceType.Smooth
			bar.BottomSurface = Enum.SurfaceType.Smooth
			bar.Color = Color3.fromRGB(40, 40, 40)
			bar.Material = Enum.Material.Metal
			bar.CFrame = refs.shimmer.CFrame * CFrame.Angles(0, 0, math.rad(30))
			bar.Parent = refs.shimmer.Parent
			refs.lockBar = bar
		end
	end
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

	-- A handful of taller statement boulders a bit inward so the lobby
	-- doesn't feel flat
	local bigRockSpots = {
		Vector3.new(cx - 32, 0, cz - 6),
		Vector3.new(cx + 30, 0, cz - 4),
		Vector3.new(cx - 18, 0, cz + 28),
		Vector3.new(cx + 22, 0, cz + 26),
		Vector3.new(cx - 38, 0, cz + 34),
		Vector3.new(cx + 36, 0, cz + 36),
	}
	for i, spot in bigRockSpots do
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
	local portalBaseZ = cz + PORTAL_ROW_Z_OFFSET
	local numPortals = #THEMES
	local firstX = cx - ((numPortals - 1) * PORTAL_SPACING) / 2

	local portals: { PortalRefs } = {}
	for i, theme in THEMES do
		local portalCenter = Vector3.new(firstX + (i - 1) * PORTAL_SPACING, cy, portalBaseZ)
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
	local signPostZ = cz + 32
	local signBoardY = cy + 7
	makePart(folder, "SignPostL", {
		Size = Vector3.new(0.9, 7, 0.9),
		Position = Vector3.new(cx - 6, cy + 3.5, signPostZ),
		Color = Color3.fromRGB(88, 54, 32),
		Material = Enum.Material.Wood,
	})
	makePart(folder, "SignPostR", {
		Size = Vector3.new(0.9, 7, 0.9),
		Position = Vector3.new(cx + 6, cy + 3.5, signPostZ),
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

	local spawnCFrame = CFrame.new(LOBBY_CENTER + SPAWN_OFFSET) * CFrame.Angles(0, math.pi, 0) -- face the portals
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
