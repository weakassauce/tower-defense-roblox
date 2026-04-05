--!strict
-- src/server/EnemyManager.luau
-- Owns the list of enemies, spawns them at the first waypoint, walks them
-- through the path, and handles damage / slow / poison / death.
-- Ported from enemies.js.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local _Config = Shared.Config

local EnemyManager = {}

export type EnemyConfig = {
	enemyType: string,
	silhouette: string, -- "goblin" | "scout" | "troll" — picks body geometry
	flourish: string, -- "none" | "crystal" | "bone" | "leaf" | "antenna"
	realm: string,
	hp: number,
	speed: number,
	reward: number,
	color: Color3,
	accentColor: Color3,
	scale: number,
}

export type Enemy = {
	model: Model,
	root: Part,
	hpFill: Frame,
	hpText: TextLabel,
	hpBillboard: BillboardGui,
	hp: number,
	maxHp: number,
	speed: number,
	baseSpeed: number,
	reward: number,
	waypointIndex: number,
	alive: boolean,
	reachedEnd: boolean,
	damaged: boolean,
	rewarded: boolean,
	slowTimer: number,
	poisonTimer: number,
	poisonDps: number,
	enemyType: string,
	silhouette: string,
	color: Color3,
	deathColor: Color3,
	deathY: number,
	walkPhase: number,
	-- Death animation state
	dying: boolean,
	destroyed: boolean,
	deathType: string,
	deathTimer: number,
	deathDuration: number,
	deathStartCF: CFrame,
	originalColors: { [BasePart]: Color3 }?,
}

local enemies: { Enemy } = {}
local waypoints: { Vector3 } = {}
local enemyFolder: Folder? = nil

-- --- Model builders ---
-- All enemy models are built with their "front" features (eyes, snout,
-- club) at local -Z, because the movement code uses CFrame.lookAt which
-- aligns local -Z with the travel direction.

local function makePart(
	name: string,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Shape = shape or Enum.PartType.Block
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function attachAll(parts: { BasePart }, model: Model)
	for _, p in parts do
		p.Parent = model
	end
end

local function buildGoblin(model: Model, config: EnemyConfig): (Part, number)
	local s = config.scale
	local bodyGreen = config.color
	local darkGreen = Color3.fromRGB(51, 105, 30)
	local darkerGreen = Color3.fromRGB(27, 64, 15)
	local skin = Color3.fromRGB(120, 170, 80)
	local wood = Color3.fromRGB(84, 55, 36)
	local cloth = Color3.fromRGB(62, 39, 35)
	local eyeRed = Color3.fromRGB(255, 23, 68)

	-- Body (green ball)
	local body = makePart(
		"Body",
		Vector3.new(4, 4.2, 4) * s,
		bodyGreen,
		Enum.Material.SmoothPlastic,
		Enum.PartType.Ball
	)

	-- Head
	local head = makePart(
		"Head",
		Vector3.new(2.6, 2.6, 2.6) * s,
		darkGreen,
		Enum.Material.SmoothPlastic,
		Enum.PartType.Ball
	)
	head.CFrame = CFrame.new(0, 3.4 * s, 0)

	-- Pointy ears
	local earL =
		makePart("EarL", Vector3.new(0.6, 1.6, 0.6) * s, darkGreen, Enum.Material.SmoothPlastic)
	earL.CFrame = CFrame.new(-1.5 * s, 4.1 * s, 0) * CFrame.Angles(0, 0, math.rad(-45))
	local earR =
		makePart("EarR", Vector3.new(0.6, 1.6, 0.6) * s, darkGreen, Enum.Material.SmoothPlastic)
	earR.CFrame = CFrame.new(1.5 * s, 4.1 * s, 0) * CFrame.Angles(0, 0, math.rad(45))

	-- Glowing red eyes at the front (-Z)
	local eyeL = makePart(
		"EyeL",
		Vector3.new(0.42, 0.42, 0.42) * s,
		eyeRed,
		Enum.Material.Neon,
		Enum.PartType.Ball
	)
	eyeL.CFrame = CFrame.new(-0.6 * s, 3.55 * s, -1.15 * s)
	local eyeR = makePart(
		"EyeR",
		Vector3.new(0.42, 0.42, 0.42) * s,
		eyeRed,
		Enum.Material.Neon,
		Enum.PartType.Ball
	)
	eyeR.CFrame = CFrame.new(0.6 * s, 3.55 * s, -1.15 * s)

	-- Nose
	local nose = makePart(
		"Nose",
		Vector3.new(0.5, 0.5, 0.5) * s,
		skin,
		Enum.Material.SmoothPlastic,
		Enum.PartType.Ball
	)
	nose.CFrame = CFrame.new(0, 3.1 * s, -1.35 * s)

	-- Arms (hanging down from the shoulders)
	local armL =
		makePart("ArmL", Vector3.new(0.8, 2.6, 0.8) * s, bodyGreen, Enum.Material.SmoothPlastic)
	armL.CFrame = CFrame.new(-2.2 * s, 0.2 * s, 0) * CFrame.Angles(0, 0, math.rad(10))
	local armR =
		makePart("ArmR", Vector3.new(0.8, 2.6, 0.8) * s, bodyGreen, Enum.Material.SmoothPlastic)
	armR.CFrame = CFrame.new(2.2 * s, 0.2 * s, 0) * CFrame.Angles(0, 0, math.rad(-10))

	-- Legs
	local legL =
		makePart("LegL", Vector3.new(1.0, 2.2, 1.0) * s, darkerGreen, Enum.Material.SmoothPlastic)
	legL.CFrame = CFrame.new(-0.9 * s, -2.9 * s, 0)
	local legR =
		makePart("LegR", Vector3.new(1.0, 2.2, 1.0) * s, darkerGreen, Enum.Material.SmoothPlastic)
	legR.CFrame = CFrame.new(0.9 * s, -2.9 * s, 0)

	-- Loincloth around the hips
	local cloth1 =
		makePart("Loincloth", Vector3.new(3.2, 1.3, 3.2) * s, cloth, Enum.Material.Fabric)
	cloth1.CFrame = CFrame.new(0, -1.8 * s, 0)

	-- Wooden club in right hand
	local club = makePart("Club", Vector3.new(0.7, 3.0, 0.7) * s, wood, Enum.Material.Wood)
	club.CFrame = CFrame.new(2.4 * s, -0.5 * s, -0.6 * s)
		* CFrame.Angles(math.rad(15), 0, math.rad(-25))
	local clubHead = makePart(
		"ClubHead",
		Vector3.new(1.2, 1.0, 1.2) * s,
		Color3.fromRGB(115, 80, 55),
		Enum.Material.Wood
	)
	clubHead.CFrame = CFrame.new(2.9 * s, 0.7 * s, -0.8 * s) * CFrame.Angles(0, 0, math.rad(-25))

	attachAll(
		{ body, head, earL, earR, eyeL, eyeR, nose, armL, armR, legL, legR, cloth1, club, clubHead },
		model
	)
	model.PrimaryPart = body
	return body, 5.8 * s
end

local function buildScout(model: Model, config: EnemyConfig): (Part, number)
	local s = config.scale
	local bodyYellow = config.color
	local darkYellow = Color3.fromRGB(245, 127, 23)
	local darker = Color3.fromRGB(150, 70, 10)
	local eyeYellow = Color3.fromRGB(255, 235, 59)

	-- Body is elongated along the -Z forward axis
	local body =
		makePart("Body", Vector3.new(3.4, 2.6, 6.0) * s, bodyYellow, Enum.Material.SmoothPlastic)

	-- Head in front (-Z direction)
	local head = makePart(
		"Head",
		Vector3.new(2.4, 2.2, 2.4) * s,
		darkYellow,
		Enum.Material.SmoothPlastic,
		Enum.PartType.Ball
	)
	head.CFrame = CFrame.new(0, 0.7 * s, -3.0 * s)

	-- Snout (pointy block forward of the head)
	local snout =
		makePart("Snout", Vector3.new(1.4, 1.0, 1.6) * s, darker, Enum.Material.SmoothPlastic)
	snout.CFrame = CFrame.new(0, 0.2 * s, -4.1 * s)

	-- Ears
	local earL =
		makePart("EarL", Vector3.new(0.6, 1.3, 0.6) * s, darker, Enum.Material.SmoothPlastic)
	earL.CFrame = CFrame.new(-0.8 * s, 2.1 * s, -2.8 * s) * CFrame.Angles(0, 0, math.rad(-15))
	local earR =
		makePart("EarR", Vector3.new(0.6, 1.3, 0.6) * s, darker, Enum.Material.SmoothPlastic)
	earR.CFrame = CFrame.new(0.8 * s, 2.1 * s, -2.8 * s) * CFrame.Angles(0, 0, math.rad(15))

	-- Glowing yellow eyes
	local eyeL = makePart(
		"EyeL",
		Vector3.new(0.4, 0.4, 0.4) * s,
		eyeYellow,
		Enum.Material.Neon,
		Enum.PartType.Ball
	)
	eyeL.CFrame = CFrame.new(-0.6 * s, 1.1 * s, -3.7 * s)
	local eyeR = makePart(
		"EyeR",
		Vector3.new(0.4, 0.4, 0.4) * s,
		eyeYellow,
		Enum.Material.Neon,
		Enum.PartType.Ball
	)
	eyeR.CFrame = CFrame.new(0.6 * s, 1.1 * s, -3.7 * s)

	-- Tail (tilted up-back at +Z)
	local tail =
		makePart("Tail", Vector3.new(0.6, 0.6, 3.2) * s, bodyYellow, Enum.Material.SmoothPlastic)
	tail.CFrame = CFrame.new(0, 1.0 * s, 3.5 * s) * CFrame.Angles(math.rad(-25), 0, 0)

	-- 4 legs
	local legGeo = Vector3.new(0.7, 2.2, 0.7) * s
	local legs = {
		{ name = "LegFL", pos = Vector3.new(-1.3, -2.1, -1.8) },
		{ name = "LegFR", pos = Vector3.new(1.3, -2.1, -1.8) },
		{ name = "LegBL", pos = Vector3.new(-1.3, -2.1, 2.0) },
		{ name = "LegBR", pos = Vector3.new(1.3, -2.1, 2.0) },
	}
	local legParts = {}
	for _, info in legs do
		local leg = makePart(info.name, legGeo, darker, Enum.Material.SmoothPlastic)
		leg.CFrame = CFrame.new(info.pos * s)
		table.insert(legParts, leg)
	end

	-- 3 dark mane spikes along the back
	local spike1 =
		makePart("Spike1", Vector3.new(0.5, 1.2, 0.5) * s, darker, Enum.Material.SmoothPlastic)
	spike1.CFrame = CFrame.new(0, 1.9 * s, -1.2 * s) * CFrame.Angles(math.rad(-10), 0, 0)
	local spike2 =
		makePart("Spike2", Vector3.new(0.5, 1.0, 0.5) * s, darker, Enum.Material.SmoothPlastic)
	spike2.CFrame = CFrame.new(0, 1.9 * s, 0)
	local spike3 =
		makePart("Spike3", Vector3.new(0.5, 0.9, 0.5) * s, darker, Enum.Material.SmoothPlastic)
	spike3.CFrame = CFrame.new(0, 1.85 * s, 1.2 * s) * CFrame.Angles(math.rad(10), 0, 0)

	local allParts = { body, head, snout, earL, earR, eyeL, eyeR, tail, spike1, spike2, spike3 }
	for _, leg in legParts do
		table.insert(allParts, leg)
	end
	attachAll(allParts, model)
	model.PrimaryPart = body
	return body, 3.8 * s
end

local function buildTroll(model: Model, config: EnemyConfig): (Part, number)
	local s = config.scale
	local bodyPurple = config.color
	local darkPurple = Color3.fromRGB(74, 20, 140)
	local darkerPurple = Color3.fromRGB(40, 10, 80)
	local horn = Color3.fromRGB(33, 33, 33)
	local tusk = Color3.fromRGB(240, 230, 210)
	local wood = Color3.fromRGB(78, 52, 36)
	local stone = Color3.fromRGB(120, 115, 105)
	local cloth = Color3.fromRGB(62, 39, 35)
	local eyeRed = Color3.fromRGB(255, 82, 82)

	-- Main body
	local body = makePart(
		"Body",
		Vector3.new(5.6, 6.5, 5.4) * s,
		bodyPurple,
		Enum.Material.SmoothPlastic,
		Enum.PartType.Ball
	)

	-- Head
	local head = makePart(
		"Head",
		Vector3.new(3.4, 3.0, 3.4) * s,
		darkPurple,
		Enum.Material.SmoothPlastic,
		Enum.PartType.Ball
	)
	head.CFrame = CFrame.new(0, 4.8 * s, 0)

	-- Horns
	local hornL =
		makePart("HornL", Vector3.new(0.7, 2.8, 0.7) * s, horn, Enum.Material.SmoothPlastic)
	hornL.CFrame = CFrame.new(-1.3 * s, 6.5 * s, 0) * CFrame.Angles(0, 0, math.rad(-20))
	local hornR =
		makePart("HornR", Vector3.new(0.7, 2.8, 0.7) * s, horn, Enum.Material.SmoothPlastic)
	hornR.CFrame = CFrame.new(1.3 * s, 6.5 * s, 0) * CFrame.Angles(0, 0, math.rad(20))

	-- Eyes (front, -Z)
	local eyeL = makePart(
		"EyeL",
		Vector3.new(0.6, 0.6, 0.6) * s,
		eyeRed,
		Enum.Material.Neon,
		Enum.PartType.Ball
	)
	eyeL.CFrame = CFrame.new(-0.9 * s, 4.9 * s, -1.55 * s)
	local eyeR = makePart(
		"EyeR",
		Vector3.new(0.6, 0.6, 0.6) * s,
		eyeRed,
		Enum.Material.Neon,
		Enum.PartType.Ball
	)
	eyeR.CFrame = CFrame.new(0.9 * s, 4.9 * s, -1.55 * s)

	-- Tusks jutting from lower jaw
	local tuskL =
		makePart("TuskL", Vector3.new(0.35, 0.9, 0.35) * s, tusk, Enum.Material.SmoothPlastic)
	tuskL.CFrame = CFrame.new(-0.5 * s, 4.0 * s, -1.65 * s) * CFrame.Angles(math.rad(-15), 0, 0)
	local tuskR =
		makePart("TuskR", Vector3.new(0.35, 0.9, 0.35) * s, tusk, Enum.Material.SmoothPlastic)
	tuskR.CFrame = CFrame.new(0.5 * s, 4.0 * s, -1.65 * s) * CFrame.Angles(math.rad(-15), 0, 0)

	-- Shoulder bulges
	local shL = makePart(
		"ShoulderL",
		Vector3.new(2.4, 2.4, 2.4) * s,
		bodyPurple,
		Enum.Material.SmoothPlastic,
		Enum.PartType.Ball
	)
	shL.CFrame = CFrame.new(-2.8 * s, 2.4 * s, 0)
	local shR = makePart(
		"ShoulderR",
		Vector3.new(2.4, 2.4, 2.4) * s,
		bodyPurple,
		Enum.Material.SmoothPlastic,
		Enum.PartType.Ball
	)
	shR.CFrame = CFrame.new(2.8 * s, 2.4 * s, 0)

	-- Thick arms
	local armL =
		makePart("ArmL", Vector3.new(1.7, 4.2, 1.7) * s, darkPurple, Enum.Material.SmoothPlastic)
	armL.CFrame = CFrame.new(-2.8 * s, -0.4 * s, 0)
	local armR =
		makePart("ArmR", Vector3.new(1.7, 4.2, 1.7) * s, darkPurple, Enum.Material.SmoothPlastic)
	armR.CFrame = CFrame.new(2.8 * s, -0.4 * s, 0)

	-- Legs
	local legL =
		makePart("LegL", Vector3.new(2.0, 3.8, 2.0) * s, darkerPurple, Enum.Material.SmoothPlastic)
	legL.CFrame = CFrame.new(-1.5 * s, -4.8 * s, 0)
	local legR =
		makePart("LegR", Vector3.new(2.0, 3.8, 2.0) * s, darkerPurple, Enum.Material.SmoothPlastic)
	legR.CFrame = CFrame.new(1.5 * s, -4.8 * s, 0)

	-- Loincloth
	local cloth1 =
		makePart("Loincloth", Vector3.new(4.2, 1.8, 4.2) * s, cloth, Enum.Material.Fabric)
	cloth1.CFrame = CFrame.new(0, -3.4 * s, 0)

	-- Stone club gripped in the right hand, tilted back
	local clubShaft =
		makePart("ClubShaft", Vector3.new(0.9, 5.5, 0.9) * s, wood, Enum.Material.Wood)
	clubShaft.CFrame = CFrame.new(3.9 * s, -0.6 * s, -0.9 * s)
		* CFrame.Angles(math.rad(20), 0, math.rad(-15))
	local clubHead = makePart(
		"ClubHead",
		Vector3.new(2.0, 2.0, 2.0) * s,
		stone,
		Enum.Material.Slate,
		Enum.PartType.Ball
	)
	clubHead.CFrame = CFrame.new(4.6 * s, 1.8 * s, -1.7 * s)

	attachAll({
		body,
		head,
		hornL,
		hornR,
		eyeL,
		eyeR,
		tuskL,
		tuskR,
		shL,
		shR,
		armL,
		armR,
		legL,
		legR,
		cloth1,
		clubShaft,
		clubHead,
	}, model)
	model.PrimaryPart = body
	return body, 9.0 * s
end

-- Attaches a single theme decoration on top of an already-built enemy body
-- so realms feel visually distinct without needing 15 separate model
-- builders. Flourishes are stacked at the top of the head (goblin/troll)
-- or along the spine (scout).
local function applyFlourish(model: Model, config: EnemyConfig, barY: number)
	if config.flourish == "none" then
		return
	end
	local s = config.scale
	local accent = config.accentColor
	local topY = barY - 1.2 * s

	if config.flourish == "crystal" then
		-- Ice crystal shards pointing up out of the head/back
		local c1 = makePart("Crystal1", Vector3.new(0.6, 2.0, 0.6) * s, accent, Enum.Material.Ice)
		c1.CFrame = CFrame.new(0, topY + 1.0 * s, 0) * CFrame.Angles(math.rad(10), 0, math.rad(5))
		c1.Transparency = 0.1
		c1.Parent = model
		local c2 = makePart("Crystal2", Vector3.new(0.4, 1.4, 0.4) * s, accent, Enum.Material.Ice)
		c2.CFrame = CFrame.new(0.6 * s, topY + 0.6 * s, 0) * CFrame.Angles(0, 0, math.rad(20))
		c2.Transparency = 0.1
		c2.Parent = model
	elseif config.flourish == "bone" then
		-- Bleached bone horns/ribs
		local boneColor = Color3.fromRGB(240, 230, 210)
		local h1 = makePart(
			"BoneHornL",
			Vector3.new(0.4, 1.6, 0.4) * s,
			boneColor,
			Enum.Material.SmoothPlastic
		)
		h1.CFrame = CFrame.new(-0.7 * s, topY + 0.4 * s, 0)
			* CFrame.Angles(math.rad(-15), 0, math.rad(-25))
		h1.Parent = model
		local h2 = makePart(
			"BoneHornR",
			Vector3.new(0.4, 1.6, 0.4) * s,
			boneColor,
			Enum.Material.SmoothPlastic
		)
		h2.CFrame = CFrame.new(0.7 * s, topY + 0.4 * s, 0)
			* CFrame.Angles(math.rad(-15), 0, math.rad(25))
		h2.Parent = model
		local skull = makePart(
			"SkullCap",
			Vector3.new(1.4, 0.4, 1.4) * s,
			boneColor,
			Enum.Material.SmoothPlastic,
			Enum.PartType.Ball
		)
		skull.CFrame = CFrame.new(0, topY + 0.2 * s, 0)
		skull.Parent = model
	elseif config.flourish == "leaf" then
		-- Vine/leaf crown
		local leafColor = Color3.fromRGB(46, 125, 50)
		for i = 0, 5 do
			local angle = (i / 6) * math.pi * 2
			local leaf = makePart(
				"Leaf" .. i,
				Vector3.new(0.9, 0.25, 0.5) * s,
				leafColor,
				Enum.Material.LeafyGrass
			)
			leaf.CFrame = CFrame.new(
				math.cos(angle) * 0.9 * s,
				topY + 0.3 * s,
				math.sin(angle) * 0.9 * s
			) * CFrame.Angles(0, angle, math.rad(20))
			leaf.Parent = model
		end
		local vine = makePart(
			"Vine",
			Vector3.new(0.3, 1.6, 0.3) * s,
			Color3.fromRGB(60, 100, 40),
			Enum.Material.LeafyGrass
		)
		vine.CFrame = CFrame.new(0, topY + 0.9 * s, 0)
		vine.Parent = model
	elseif config.flourish == "antenna" then
		-- Sci-fi antenna + glowing neon core on the forehead
		local rod = makePart(
			"Antenna",
			Vector3.new(0.25, 2.2, 0.25) * s,
			Color3.fromRGB(60, 66, 90),
			Enum.Material.Metal
		)
		rod.CFrame = CFrame.new(0, topY + 1.1 * s, 0)
		rod.Parent = model
		local tip = makePart(
			"AntennaTip",
			Vector3.new(0.6, 0.6, 0.6) * s,
			accent,
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
		tip.CFrame = CFrame.new(0, topY + 2.3 * s, 0)
		tip.Parent = model
		local light = Instance.new("PointLight")
		light.Color = accent
		light.Range = 6
		light.Brightness = 1.5
		light.Parent = tip
		local visor = makePart("Visor", Vector3.new(1.6, 0.3, 0.2) * s, accent, Enum.Material.Neon)
		visor.CFrame = CFrame.new(0, topY - 0.4 * s, -0.9 * s)
		visor.Parent = model
	end
end

-- Builds a composite enemy model. Returns (model, rootPart, barY) where
-- rootPart is the primary body used for positioning/HP bar attachment,
-- and barY is the local Y distance from the body to the HP bar.
local function buildEnemyModel(config: EnemyConfig): (Model, Part, number)
	local model = Instance.new("Model")
	model.Name = "Enemy_" .. config.enemyType

	local body: Part
	local barY: number
	if config.silhouette == "scout" then
		body, barY = buildScout(model, config)
	elseif config.silhouette == "troll" then
		body, barY = buildTroll(model, config)
	else
		body, barY = buildGoblin(model, config)
	end

	applyFlourish(model, config, barY)
	return model, body, barY
end

local function buildHpBar(
	parent: Part,
	maxHp: number,
	barY: number
): (Frame, TextLabel, BillboardGui)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "HpBar"
	billboard.Size = UDim2.fromOffset(130, 36)
	billboard.StudsOffset = Vector3.new(0, barY + 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	-- Hide HP bars from far away (lobby is 3000+ studs from the arena)
	billboard.MaxDistance = 200
	billboard.Parent = parent

	-- "X/X" text above the bar
	local hpText = Instance.new("TextLabel")
	hpText.Name = "HpText"
	hpText.Size = UDim2.fromOffset(130, 16)
	hpText.Position = UDim2.fromOffset(0, 0)
	hpText.BackgroundTransparency = 1
	hpText.Text = string.format("%d/%d", maxHp, maxHp)
	hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
	hpText.Font = Enum.Font.GothamBold
	hpText.TextSize = 14
	hpText.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	hpText.TextStrokeTransparency = 0
	hpText.TextXAlignment = Enum.TextXAlignment.Center
	hpText.Parent = billboard

	-- Background strip with rounded corners
	local bg = Instance.new("Frame")
	bg.Name = "BarBg"
	bg.Size = UDim2.fromOffset(126, 14)
	bg.Position = UDim2.fromOffset(2, 20)
	bg.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 5)
	bgCorner.Parent = bg

	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = Color3.fromRGB(0, 0, 0)
	bgStroke.Thickness = 2
	bgStroke.Parent = bg

	-- Fill frame (width scales with HP ratio)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(60, 230, 80)
	fill.BorderSizePixel = 0
	fill.Parent = bg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 5)
	fillCorner.Parent = fill

	return fill, hpText, billboard
end

-- --- Public API ---

function EnemyManager.init(waypointList: { Vector3 })
	waypoints = waypointList

	-- Fresh folder each Play session so hot reloads don't pile up enemies
	local existing = workspace:FindFirstChild("Enemies")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = workspace
	enemyFolder = folder

	enemies = {}
end

function EnemyManager.spawn(config: EnemyConfig): Enemy
	assert(#waypoints > 0, "EnemyManager.init(waypoints) must be called first")
	assert(enemyFolder, "enemyFolder not initialized")

	local model, body, barY = buildEnemyModel(config)
	local hpFill, hpText, hpBillboard = buildHpBar(body, config.hp, barY)

	local startPos = waypoints[1]
	model:PivotTo(CFrame.new(startPos))
	model.Parent = enemyFolder

	local enemy: Enemy = {
		model = model,
		root = body,
		hpFill = hpFill,
		hpText = hpText,
		hpBillboard = hpBillboard,
		hp = config.hp,
		maxHp = config.hp,
		speed = config.speed,
		baseSpeed = config.speed,
		reward = config.reward,
		waypointIndex = 2, -- head toward the second waypoint (we already stand on the first)
		alive = true,
		reachedEnd = false,
		damaged = false,
		rewarded = false,
		slowTimer = 0,
		poisonTimer = 0,
		poisonDps = 0,
		enemyType = config.enemyType,
		silhouette = config.silhouette,
		color = config.color,
		deathColor = config.color,
		deathY = barY * 0.4,
		walkPhase = math.random() * math.pi * 2, -- random phase so enemies don't bounce in sync
		dying = false,
		destroyed = false,
		deathType = "",
		deathTimer = 0,
		deathDuration = 0,
		deathStartCF = CFrame.new(startPos),
		originalColors = nil,
	}

	table.insert(enemies, enemy)
	return enemy
end

-- --- Death animation helpers ---

local function captureModelColors(model: Model): { [BasePart]: Color3 }
	local colors: { [BasePart]: Color3 } = {}
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") then
			colors[child] = child.Color
		end
	end
	return colors
end

local function setModelColor(model: Model, color: Color3)
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") then
			child.Color = color
		end
	end
end

local function setModelTransparency(model: Model, transparency: number)
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") then
			child.Transparency = math.clamp(transparency, 0, 1)
		end
	end
end

local function setModelMaterial(model: Model, material: Enum.Material)
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") then
			child.Material = material
		end
	end
end

-- Per-tower death durations
local DEATH_DURATIONS: { [string]: number } = {
	basic = 0.7, -- arrow: flop backward
	sniper = 0.45, -- magic: flash + fade
	cannon = 3.5, -- boom: physics explosion
	freeze = 1.4, -- ice: freeze then shatter
	lightning = 0.6, -- zap: strobe + fade
	poison = 1.3, -- wilt: tilt and fade
	flame = 0.9, -- burn: jitter + shrink-fade
}

local function beginDeath(enemy: Enemy, killerType: string)
	enemy.alive = false
	enemy.dying = true
	enemy.deathType = killerType
	enemy.deathTimer = 0
	enemy.deathDuration = DEATH_DURATIONS[killerType] or 0.7
	enemy.deathStartCF = enemy.model:GetPivot()

	-- Hide the HP bar during the animation
	if enemy.hpBillboard then
		enemy.hpBillboard.Enabled = false
	end

	-- Per-tower setup
	if killerType == "cannon" then
		-- Unanchor everything and fling it outward so physics plays out
		local center = enemy.root.Position
		for _, child in enemy.model:GetDescendants() do
			if child:IsA("BasePart") then
				child.Anchored = false
				child.CanCollide = true
				local dx = child.Position.X - center.X
				local dz = child.Position.Z - center.Z
				local distSq = dx * dx + dz * dz
				local dir = if distSq > 0.01
					then Vector3.new(dx, 0, dz).Unit
					else Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
				child.AssemblyLinearVelocity = dir * (25 + math.random() * 20)
					+ Vector3.new(0, 35 + math.random() * 25, 0)
				child.AssemblyAngularVelocity = Vector3.new(
					(math.random() - 0.5) * 15,
					(math.random() - 0.5) * 15,
					(math.random() - 0.5) * 15
				)
			end
		end
	elseif killerType == "freeze" then
		-- Save colors, tint everything icy blue, swap to Ice material
		enemy.originalColors = captureModelColors(enemy.model)
		setModelColor(enemy.model, Color3.fromRGB(140, 210, 255))
		setModelMaterial(enemy.model, Enum.Material.Ice)
	elseif killerType == "lightning" then
		enemy.originalColors = captureModelColors(enemy.model)
		setModelColor(enemy.model, Color3.fromRGB(255, 255, 180))
	elseif killerType == "flame" then
		setModelColor(enemy.model, Color3.fromRGB(255, 120, 40))
		setModelMaterial(enemy.model, Enum.Material.Neon)
	elseif killerType == "sniper" then
		setModelColor(enemy.model, Color3.fromRGB(255, 255, 255))
		setModelMaterial(enemy.model, Enum.Material.Neon)
	end
end

local function updateDeath(enemy: Enemy, dt: number)
	enemy.deathTimer += dt
	local t = math.clamp(enemy.deathTimer / enemy.deathDuration, 0, 1)
	local kt = enemy.deathType
	local model = enemy.model

	if kt == "basic" then
		-- Archer arrow: flop backward like a felled cartoon villain
		local angle = t * math.rad(95)
		model:PivotTo(enemy.deathStartCF * CFrame.Angles(angle, 0, 0))
		if t > 0.55 then
			setModelTransparency(model, (t - 0.55) / 0.45)
		end
	elseif kt == "sniper" then
		-- Wizard: held bright, then fade out
		setModelTransparency(model, t * 0.9)
		-- Spin as it fades
		model:PivotTo(enemy.deathStartCF * CFrame.Angles(0, t * math.rad(720), 0))
	elseif kt == "cannon" then
		-- Physics is doing the work; just fade out near the end
		if t > 0.7 then
			setModelTransparency(model, (t - 0.7) / 0.3)
		end
	elseif kt == "freeze" then
		-- Wobble slightly while frozen, then shatter (fade) at the end
		local wobble = math.sin(enemy.deathTimer * 6) * 0.05
		model:PivotTo(enemy.deathStartCF * CFrame.Angles(0, 0, wobble))
		if t > 0.7 then
			setModelTransparency(model, (t - 0.7) / 0.3)
		end
	elseif kt == "lightning" then
		-- Violently shake + strobe color
		local shakeX = (math.random() - 0.5) * 1.8
		local shakeZ = (math.random() - 0.5) * 1.8
		model:PivotTo(enemy.deathStartCF + Vector3.new(shakeX, 0, shakeZ))
		if math.floor(enemy.deathTimer * 30) % 2 == 0 then
			setModelColor(model, Color3.fromRGB(255, 255, 180))
		else
			setModelColor(model, Color3.fromRGB(120, 160, 255))
		end
		if t > 0.6 then
			setModelTransparency(model, (t - 0.6) / 0.4)
		end
	elseif kt == "poison" then
		-- Wilt forward slowly, then fade
		local tilt = t * math.rad(110)
		model:PivotTo(enemy.deathStartCF * CFrame.Angles(-tilt, 0, 0))
		-- Slowly sink
		local sink = t * 0.8
		model:PivotTo(model:GetPivot() - Vector3.new(0, sink * 0.1, 0))
		-- Tint green darker
		if t > 0.4 then
			setModelColor(model, Color3.fromRGB(40, 80, 20))
		end
		if t > 0.75 then
			setModelTransparency(model, (t - 0.75) / 0.25)
		end
	elseif kt == "flame" then
		-- Jitter + scale shrink (faked via pivot offset)
		local jitterX = (math.random() - 0.5) * 0.6
		local jitterZ = (math.random() - 0.5) * 0.6
		local jitterY = math.random() * 0.4
		model:PivotTo(enemy.deathStartCF + Vector3.new(jitterX, jitterY, jitterZ))
		-- Color cooler over time (orange → red → black)
		local r = 255 - math.floor(t * 180)
		local g = 120 - math.floor(t * 120)
		setModelColor(model, Color3.fromRGB(math.max(r, 40), math.max(g, 0), 10))
		setModelTransparency(model, t * 0.85)
	else
		-- Default: fade out
		setModelTransparency(model, t)
	end

	if t >= 1 then
		enemy.destroyed = true
		model:Destroy()
	end
end

function EnemyManager.damage(enemy: Enemy, amount: number, killerType: string?)
	if not enemy.alive then
		return
	end

	enemy.hp -= amount
	if enemy.hp <= 0 then
		beginDeath(enemy, killerType or "basic")
		return
	end

	-- Update HP bar + text
	local shownHp = math.max(0, math.ceil(enemy.hp))
	enemy.hpText.Text = string.format("%d/%d", shownHp, enemy.maxHp)
	local ratio = math.max(0, enemy.hp / enemy.maxHp)
	enemy.hpFill.Size = UDim2.fromScale(ratio, 1)
	if ratio > 0.5 then
		enemy.hpFill.BackgroundColor3 = Color3.fromRGB(60, 230, 80)
	elseif ratio > 0.25 then
		enemy.hpFill.BackgroundColor3 = Color3.fromRGB(255, 170, 30)
	else
		enemy.hpFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
	end
end

function EnemyManager.applySlow(enemy: Enemy, factor: number, duration: number)
	enemy.speed = enemy.baseSpeed * factor
	enemy.slowTimer = duration
end

function EnemyManager.applyPoison(enemy: Enemy, dps: number, duration: number)
	enemy.poisonDps = math.max(enemy.poisonDps, dps)
	enemy.poisonTimer = math.max(enemy.poisonTimer, duration)
end

function EnemyManager.getAlive(): { Enemy }
	local alive = {}
	for _, e in enemies do
		if e.alive then
			table.insert(alive, e)
		end
	end
	return alive
end

-- All enemies including dead/reachedEnd ones that haven't been cleaned yet.
-- Used by the main loop to find enemies that need to have their reward
-- paid or HP damage applied to the base.
function EnemyManager.getAll(): { Enemy }
	return enemies
end

-- Walk animation parameters keyed on silhouette (not realm-specific
-- enemyType), so every realm's small/fast/tank enemies share the right
-- bounce profile.
local WALK_PARAMS: { [string]: { bounce: number, wobble: number, freq: number } } = {
	goblin = { bounce = 0.55, wobble = 0.10, freq = 4.0 },
	scout = { bounce = 0.25, wobble = 0.05, freq = 6.5 },
	troll = { bounce = 0.35, wobble = 0.06, freq = 2.2 },
}

local DEFAULT_WALK = WALK_PARAMS.goblin

function EnemyManager.update(dt: number)
	for _, enemy in enemies do
		if enemy.dying and not enemy.destroyed then
			updateDeath(enemy, dt)
			continue
		end
		if not enemy.alive then
			continue
		end

		-- Slow timer
		if enemy.slowTimer > 0 then
			enemy.slowTimer -= dt
			if enemy.slowTimer <= 0 then
				enemy.speed = enemy.baseSpeed
			end
		end

		-- Poison DoT — killed by poison counts as a poison death
		if enemy.poisonTimer > 0 then
			enemy.poisonTimer -= dt
			EnemyManager.damage(enemy, enemy.poisonDps * dt, "poison")
			if not enemy.alive then
				continue
			end
		end

		-- Walk toward current waypoint
		local target = waypoints[enemy.waypointIndex]
		if not target then
			continue
		end

		local currentPos = enemy.root.Position
		local toTarget = Vector3.new(target.X - currentPos.X, 0, target.Z - currentPos.Z)
		local dist = toTarget.Magnitude
		local step = enemy.speed * dt

		-- Advance walk animation phase (scaled by current speed so slowed
		-- enemies also bounce slower)
		local walk = WALK_PARAMS[enemy.silhouette] or DEFAULT_WALK
		enemy.walkPhase += dt * enemy.speed * 0.35
		local p = enemy.walkPhase * walk.freq
		local bounceY = math.abs(math.sin(p)) * walk.bounce
		local wobbleZ = math.sin(p) * walk.wobble

		local nextPos: Vector3
		local nextDir: Vector3? = nil
		if dist <= step then
			enemy.waypointIndex += 1
			if enemy.waypointIndex > #waypoints then
				enemy.alive = false
				enemy.reachedEnd = true
				enemy.destroyed = true
				enemy.model:Destroy()
				continue
			end
			nextPos = Vector3.new(target.X, target.Y, target.Z)
		else
			local dir = toTarget.Unit
			nextPos = Vector3.new(currentPos.X, target.Y, currentPos.Z) + dir * step
			nextDir = dir
		end

		local bouncedPos = nextPos + Vector3.new(0, bounceY, 0)
		local baseCF: CFrame
		if nextDir then
			baseCF = CFrame.lookAt(bouncedPos, bouncedPos + nextDir)
		else
			baseCF = CFrame.new(bouncedPos)
		end
		enemy.model:PivotTo(baseCF * CFrame.Angles(0, 0, wobbleZ))
	end
end

-- Remove fully destroyed enemies from the list. Dying-but-still-animating
-- enemies are kept so their animation can play out.
function EnemyManager.cleanup()
	for i = #enemies, 1, -1 do
		if enemies[i].destroyed then
			table.remove(enemies, i)
		end
	end
end

function EnemyManager.clear()
	for _, enemy in enemies do
		if enemy.model.Parent then
			enemy.model:Destroy()
		end
	end
	enemies = {}
end

return EnemyManager
