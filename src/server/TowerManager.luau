--!strict
-- src/server/TowerManager.luau
-- Owns placed towers and their projectiles. Each tick, towers find the
-- nearest enemy in range and fire. Projectiles travel toward their target
-- and deal damage (+ splash/slow/poison) on contact.
-- Ported from towers.js.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Require these as direct module references so Luau's type checker can
-- resolve `TowerDefs.TowerDef` and `EnemyManager.Enemy` from their exports.
local Config = require(ReplicatedStorage.Shared.Config)
local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local EnemyManager = require(script.Parent.EnemyManager)

-- TowerManager is instantiated per arena via TowerManager.new(...).
-- Used to be a module-level singleton that parented towers and
-- projectiles directly into workspace.Towers / workspace.Projectiles;
-- the multiplayer refactor moved the towers/projectiles lists, folder
-- refs, the owning arena's enemy manager, and the arena's world-space
-- origin offset onto self. TowerManager.buildDisplayModel is still
-- exposed as a static helper because the lobby uses it outside of any
-- arena context.
local TowerManager = {}
TowerManager.__index = TowerManager

export type Tower = {
	gx: number,
	gy: number,
	towerType: string,
	def: TowerDefs.TowerDef,
	model: Model,
	orb: Part,
	x: number,
	z: number,
	projectileY: number,
	fireCooldown: number,
}

type Projectile = {
	part: Part,
	target: EnemyManager.Enemy,
	tower: Tower,
	speed: number,
}

export type TowerManager = {
	towers: { Tower },
	projectiles: { Projectile },
	towerFolder: Folder,
	projectileFolder: Folder,
	originOffset: Vector3,
	enemyMgr: EnemyManager.EnemyManager,

	isOccupied: (self: TowerManager, gx: number, gy: number) -> boolean,
	place: (self: TowerManager, gx: number, gy: number, towerType: string) -> Tower?,
	remove: (self: TowerManager, tower: Tower) -> (),
	getAt: (self: TowerManager, gx: number, gy: number) -> Tower?,
	update: (self: TowerManager, dt: number) -> (),
	clear: (self: TowerManager) -> (),
	snapshot: (self: TowerManager) -> { TowerSnapshot },
	restoreFrom: (self: TowerManager, snapshots: { TowerSnapshot }) -> (),
}

export type TowerSnapshot = { gx: number, gy: number, towerType: string }

-- --- Tower model builders ---
-- Each tower type has a distinctive silhouette built from primitive parts.
-- All builders return (model, focusPart) where focusPart is the visually
-- prominent "turret" piece that the TowerManager rotates to face enemies.

-- Small primitive helpers ----------------------------------------------------

local function makeBlock(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function makeCylinder(
	parent: Instance,
	name: string,
	diameter: number,
	height: number,
	cf: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local p = makeBlock(parent, name, Vector3.new(diameter, height, diameter), cf, color, material)
	local mesh = Instance.new("CylinderMesh")
	mesh.Parent = p
	return p
end

local function makeSphere(
	parent: Instance,
	name: string,
	diameter: number,
	pos: Vector3,
	color: Color3,
	material: Enum.Material
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(diameter, diameter, diameter)
	p.Position = pos
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = true
	p.Parent = parent
	return p
end

local function addPointLight(part: Part, color: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Parent = part
end

-- Per-type builders ----------------------------------------------------------

local function buildArcher(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local stone = Color3.fromRGB(158, 158, 158)
	local stoneDark = Color3.fromRGB(97, 97, 97)

	makeBlock(
		model,
		"Base",
		Vector3.new(6, 1.5, 6),
		CFrame.new(cx, 0.75, cz),
		stoneDark,
		Enum.Material.Slate
	)
	local body = makeBlock(
		model,
		"Body",
		Vector3.new(4, 7, 4),
		CFrame.new(cx, 5, cz),
		stone,
		Enum.Material.Brick
	)

	-- Crenellation blocks at the 4 corners of the top
	for _, offset in { { -1.5, -1.5 }, { 1.5, -1.5 }, { -1.5, 1.5 }, { 1.5, 1.5 } } do
		makeBlock(
			model,
			"Crenel",
			Vector3.new(1, 1.4, 1),
			CFrame.new(cx + offset[1], 9.2, cz + offset[2]),
			stoneDark,
			Enum.Material.Brick
		)
	end

	-- Flag pole + flag
	makeBlock(
		model,
		"Pole",
		Vector3.new(0.3, 3, 0.3),
		CFrame.new(cx, 10.5, cz),
		Color3.fromRGB(78, 52, 46),
		Enum.Material.Wood
	)
	makeBlock(
		model,
		"Flag",
		Vector3.new(2.2, 1.2, 0.1),
		CFrame.new(cx + 1.1, 11.2, cz),
		def.accent,
		Enum.Material.Fabric
	)

	return body
end

local function buildWizard(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local stone = Color3.fromRGB(120, 144, 156)

	makeCylinder(
		model,
		"Base",
		7,
		1.6,
		CFrame.new(cx, 0.8, cz),
		Color3.fromRGB(69, 90, 100),
		Enum.Material.Slate
	)
	makeCylinder(model, "Body1", 5, 4, CFrame.new(cx, 3.6, cz), stone, Enum.Material.Brick)
	makeCylinder(model, "Body2", 4, 3, CFrame.new(cx, 7.2, cz), stone, Enum.Material.Brick)
	-- Decorative ring
	makeCylinder(
		model,
		"Ring",
		5.5,
		0.4,
		CFrame.new(cx, 5.4, cz),
		Color3.fromRGB(69, 90, 100),
		Enum.Material.Slate
	)

	-- Glowing orb
	local orb =
		makeSphere(model, "Orb", 2.6, Vector3.new(cx, 10, cz), def.accent, Enum.Material.Neon)
	addPointLight(orb, def.accent, 10, 1.2)

	-- Tip
	makeSphere(model, "Finial", 0.8, Vector3.new(cx, 11.8, cz), def.accent, Enum.Material.Neon)

	return orb
end

local function buildCannon(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local wood = Color3.fromRGB(93, 64, 55)
	local woodDark = Color3.fromRGB(62, 39, 35)
	local iron = Color3.fromRGB(33, 33, 33)

	makeBlock(
		model,
		"Base",
		Vector3.new(6.5, 1.5, 6.5),
		CFrame.new(cx, 0.75, cz),
		Color3.fromRGB(97, 97, 97),
		Enum.Material.Slate
	)
	makeBlock(
		model,
		"Deck",
		Vector3.new(5.5, 0.6, 5.5),
		CFrame.new(cx, 1.8, cz),
		wood,
		Enum.Material.Wood
	)

	-- Short bunker walls (4 sides)
	makeBlock(
		model,
		"WallN",
		Vector3.new(5, 2, 0.6),
		CFrame.new(cx, 3.1, cz - 2.4),
		woodDark,
		Enum.Material.Wood
	)
	makeBlock(
		model,
		"WallS",
		Vector3.new(5, 2, 0.6),
		CFrame.new(cx, 3.1, cz + 2.4),
		woodDark,
		Enum.Material.Wood
	)
	makeBlock(
		model,
		"WallE",
		Vector3.new(0.6, 2, 5),
		CFrame.new(cx + 2.4, 3.1, cz),
		woodDark,
		Enum.Material.Wood
	)
	makeBlock(
		model,
		"WallW",
		Vector3.new(0.6, 2, 5),
		CFrame.new(cx - 2.4, 3.1, cz),
		woodDark,
		Enum.Material.Wood
	)

	-- Cannon barrel lying flat, extending forward along -Z
	local barrel = makeBlock(
		model,
		"Barrel",
		Vector3.new(1.8, 1.6, 5),
		CFrame.new(cx, 4.6, cz - 1),
		iron,
		Enum.Material.Metal
	)

	-- Muzzle ring + glowing ember at the back
	makeBlock(
		model,
		"Muzzle",
		Vector3.new(2.2, 2, 0.5),
		CFrame.new(cx, 4.6, cz - 3.5),
		iron,
		Enum.Material.Metal
	)
	local ember = makeSphere(
		model,
		"Ember",
		0.9,
		Vector3.new(cx, 4.6, cz + 1.6),
		def.accent,
		Enum.Material.Neon
	)
	addPointLight(ember, def.accent, 7, 0.8)

	return barrel
end

local function buildFrost(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local stoneIce = Color3.fromRGB(96, 125, 139)

	makeCylinder(model, "Base", 6, 1.6, CFrame.new(cx, 0.8, cz), stoneIce, Enum.Material.Slate)
	makeCylinder(
		model,
		"Snow",
		6.2,
		0.4,
		CFrame.new(cx, 1.8, cz),
		Color3.fromRGB(255, 255, 255),
		Enum.Material.Snow
	)

	-- Central tall crystal
	local center = makeBlock(
		model,
		"CrystalC",
		Vector3.new(1.6, 7, 1.6),
		CFrame.new(cx, 5.4, cz),
		def.color,
		Enum.Material.Glass
	)
	center.Transparency = 0.1
	addPointLight(center, def.color, 9, 1.2)

	-- Surrounding shorter crystals
	local spots =
		{ { 2.2, 0, 1 }, { -2.2, 0, 1 }, { 0, 2.2, 1.2 }, { 0, -2.2, 1 }, { 1.6, 1.6, 1 } }
	for i, s in spots do
		local h = 2.4 + s[3] * 1.4
		local c = makeBlock(
			model,
			"Crystal" .. i,
			Vector3.new(1, h, 1),
			CFrame.new(cx + s[1], 2.2 + h / 2, cz + s[2]),
			def.color,
			Enum.Material.Glass
		)
		c.Transparency = 0.15
	end

	return center
end

local function buildStorm(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local stone = Color3.fromRGB(69, 90, 100)
	local metal = Color3.fromRGB(144, 164, 174)

	makeCylinder(
		model,
		"Base",
		6,
		1.6,
		CFrame.new(cx, 0.8, cz),
		Color3.fromRGB(38, 50, 56),
		Enum.Material.Slate
	)
	makeCylinder(model, "Body1", 4.5, 5, CFrame.new(cx, 4.1, cz), stone, Enum.Material.Brick)
	makeCylinder(model, "Body2", 3.5, 3, CFrame.new(cx, 8.1, cz), stone, Enum.Material.Brick)

	-- Lightning rod spikes around the top
	for i = 0, 5 do
		local angle = (i / 6) * math.pi * 2
		local sx = math.cos(angle) * 2
		local sz = math.sin(angle) * 2
		makeBlock(
			model,
			"Spike" .. i,
			Vector3.new(0.4, 2.2, 0.4),
			CFrame.new(cx + sx, 10.6, cz + sz),
			metal,
			Enum.Material.Metal
		)
	end

	-- Pulsing orb
	local orb =
		makeSphere(model, "Orb", 2.6, Vector3.new(cx, 11, cz), def.accent, Enum.Material.Neon)
	addPointLight(orb, def.accent, 11, 1.5)

	return orb
end

local function buildAlchemist(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local wood = Color3.fromRGB(93, 64, 55)
	local woodDark = Color3.fromRGB(62, 39, 35)

	makeBlock(
		model,
		"Base",
		Vector3.new(6, 1.4, 6),
		CFrame.new(cx, 0.7, cz),
		Color3.fromRGB(97, 97, 97),
		Enum.Material.Slate
	)

	-- 4 wood corner pillars
	for _, o in { { -2, -2 }, { 2, -2 }, { -2, 2 }, { 2, 2 } } do
		makeBlock(
			model,
			"Pillar",
			Vector3.new(0.7, 5.5, 0.7),
			CFrame.new(cx + o[1], 3.9, cz + o[2]),
			woodDark,
			Enum.Material.Wood
		)
	end

	-- Platform deck
	makeBlock(
		model,
		"Deck",
		Vector3.new(5, 0.5, 5),
		CFrame.new(cx, 6.7, cz),
		wood,
		Enum.Material.Wood
	)

	-- Cauldron (cylinder) + glowing brew disc
	local cauldron = makeCylinder(
		model,
		"Cauldron",
		3.6,
		2.2,
		CFrame.new(cx, 8, cz),
		Color3.fromRGB(33, 33, 33),
		Enum.Material.Metal
	)
	local brew = makeCylinder(
		model,
		"Brew",
		3.2,
		0.3,
		CFrame.new(cx, 9.05, cz),
		def.accent,
		Enum.Material.Neon
	)
	addPointLight(brew, def.accent, 8, 1)

	return cauldron
end

local function buildInferno(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local stone = Color3.fromRGB(78, 52, 46)
	local stoneDark = Color3.fromRGB(62, 39, 35)

	makeCylinder(model, "Base", 6.2, 1.6, CFrame.new(cx, 0.8, cz), stoneDark, Enum.Material.Slate)
	makeCylinder(model, "Body", 5.4, 3.8, CFrame.new(cx, 3.5, cz), stone, Enum.Material.Brick)
	-- Scorch band
	makeCylinder(
		model,
		"Band",
		5.6,
		0.6,
		CFrame.new(cx, 5, cz),
		Color3.fromRGB(33, 20, 15),
		Enum.Material.Brick
	)

	-- Fire pit
	makeCylinder(model, "Pit", 4.6, 0.4, CFrame.new(cx, 5.6, cz), def.accent, Enum.Material.Neon)

	-- Central flame (use a ball for simplicity)
	local flame =
		makeSphere(model, "Flame", 2.4, Vector3.new(cx, 7, cz), def.accent, Enum.Material.Neon)
	addPointLight(flame, def.accent, 10, 1.5)

	return flame
end

-- --- Realm signature towers ---

local function buildPaladin(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	-- Defense realm: a golden fortress with a sun banner and crowned keep.
	local cx, cz = pos.X, pos.Z
	local stone = Color3.fromRGB(200, 170, 110)
	local stoneDark = Color3.fromRGB(120, 95, 50)
	makeBlock(
		model,
		"Base",
		Vector3.new(7, 1.5, 7),
		CFrame.new(cx, 0.75, cz),
		stoneDark,
		Enum.Material.Slate
	)
	makeBlock(
		model,
		"Keep",
		Vector3.new(5, 9, 5),
		CFrame.new(cx, 6, cz),
		stone,
		Enum.Material.Marble
	)
	-- Crowned battlements
	for _, o in { { -1.8, -1.8 }, { 1.8, -1.8 }, { -1.8, 1.8 }, { 1.8, 1.8 } } do
		makeBlock(
			model,
			"Cren",
			Vector3.new(1.3, 1.6, 1.3),
			CFrame.new(cx + o[1], 11.3, cz + o[2]),
			stoneDark,
			Enum.Material.Marble
		)
	end
	-- Sun banner hanging on the front
	makeBlock(
		model,
		"Banner",
		Vector3.new(2.6, 3.4, 0.15),
		CFrame.new(cx, 6.5, cz - 2.6),
		def.accent,
		Enum.Material.Fabric
	)
	local sun =
		makeSphere(model, "Sun", 1.4, Vector3.new(cx, 12.6, cz), def.accent, Enum.Material.Neon)
	addPointLight(sun, def.accent, 12, 2)
	return sun
end

local function buildIcelance(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	-- Frost realm: a tall glassy lance spire on a frozen disc.
	local cx, cz = pos.X, pos.Z
	local ice = Color3.fromRGB(179, 229, 252)
	makeCylinder(
		model,
		"Base",
		7,
		1.4,
		CFrame.new(cx, 0.7, cz),
		Color3.fromRGB(144, 164, 174),
		Enum.Material.Ice
	)
	makeCylinder(model, "Rim", 7.4, 0.4, CFrame.new(cx, 1.6, cz), ice, Enum.Material.Ice)
	-- Outer crystal ring
	for i = 0, 5 do
		local angle = (i / 6) * math.pi * 2
		local sx = cx + math.cos(angle) * 2.4
		local sz = cz + math.sin(angle) * 2.4
		local shard = makeBlock(
			model,
			"Shard" .. i,
			Vector3.new(0.9, 4 + (i % 2) * 1.2, 0.9),
			CFrame.new(sx, 3.8, sz) * CFrame.Angles(math.rad(5), 0, math.rad(5)),
			ice,
			Enum.Material.Glass
		)
		shard.Transparency = 0.2
	end
	-- Central lance
	local lance = makeBlock(
		model,
		"Lance",
		Vector3.new(1.2, 12, 1.2),
		CFrame.new(cx, 8, cz),
		def.color,
		Enum.Material.Glass
	)
	lance.Transparency = 0.1
	addPointLight(lance, def.color, 14, 1.8)
	-- Tip
	makeSphere(model, "Tip", 1.2, Vector3.new(cx, 14.4, cz), def.accent, Enum.Material.Neon)
	return lance
end

local function buildSandstorm(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	-- Desert realm: sandstone ziggurat with a swirling dust orb on top.
	local cx, cz = pos.X, pos.Z
	local sand = Color3.fromRGB(215, 175, 110)
	local sandDark = Color3.fromRGB(150, 115, 70)
	makeBlock(
		model,
		"Step1",
		Vector3.new(7, 2, 7),
		CFrame.new(cx, 1, cz),
		sandDark,
		Enum.Material.Sandstone
	)
	makeBlock(
		model,
		"Step2",
		Vector3.new(5.4, 2, 5.4),
		CFrame.new(cx, 3, cz),
		sand,
		Enum.Material.Sandstone
	)
	makeBlock(
		model,
		"Step3",
		Vector3.new(3.8, 2, 3.8),
		CFrame.new(cx, 5, cz),
		sandDark,
		Enum.Material.Sandstone
	)
	-- Central obelisk
	makeBlock(
		model,
		"Obelisk",
		Vector3.new(1.6, 4.6, 1.6),
		CFrame.new(cx, 8.3, cz),
		sand,
		Enum.Material.Sandstone
	)
	-- Swirling dust orb
	local orb =
		makeSphere(model, "DustOrb", 2.8, Vector3.new(cx, 11.6, cz), def.accent, Enum.Material.Neon)
	addPointLight(orb, def.accent, 12, 1.6)
	-- Ring of smaller particles around the orb
	for i = 0, 5 do
		local angle = (i / 6) * math.pi * 2
		local sx = cx + math.cos(angle) * 2.4
		local sz = cz + math.sin(angle) * 2.4
		makeSphere(
			model,
			"Dust" .. i,
			0.6,
			Vector3.new(sx, 11.6, sz),
			def.accent,
			Enum.Material.Neon
		)
	end
	return orb
end

local function buildThornwall(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	-- Forest realm: a ring of thorn pillars with a glowing heart vine.
	local cx, cz = pos.X, pos.Z
	local bark = Color3.fromRGB(60, 40, 25)
	local leaf = Color3.fromRGB(46, 125, 50)
	makeCylinder(model, "Stump", 7, 1.6, CFrame.new(cx, 0.8, cz), bark, Enum.Material.Wood)
	makeCylinder(model, "Moss", 7.3, 0.5, CFrame.new(cx, 1.7, cz), leaf, Enum.Material.LeafyGrass)
	-- Thorn pillars in a ring, tilted outward
	for i = 0, 7 do
		local angle = (i / 8) * math.pi * 2
		local sx = cx + math.cos(angle) * 2.5
		local sz = cz + math.sin(angle) * 2.5
		local thorn = makeBlock(
			model,
			"Thorn" .. i,
			Vector3.new(0.8, 5 + (i % 2) * 1.2, 0.8),
			CFrame.new(sx, 4.6, sz)
				* CFrame.Angles(math.rad(math.sin(angle) * 12), 0, math.rad(math.cos(angle) * 12)),
			bark,
			Enum.Material.Wood
		)
		thorn.Color = bark
	end
	-- Central heart-vine ball
	local heart =
		makeSphere(model, "Heart", 3.4, Vector3.new(cx, 6.8, cz), def.accent, Enum.Material.Neon)
	addPointLight(heart, def.accent, 12, 1.6)
	-- Leafy canopy over the heart
	makeSphere(model, "Canopy", 4.6, Vector3.new(cx, 9, cz), leaf, Enum.Material.LeafyGrass)
	return heart
end

local function buildPlasma(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	-- Space realm: a chrome disc base + floating plasma core held between fins.
	local cx, cz = pos.X, pos.Z
	local chrome = Color3.fromRGB(120, 130, 170)
	local dark = Color3.fromRGB(45, 40, 70)
	makeCylinder(model, "Base", 7, 1.2, CFrame.new(cx, 0.6, cz), dark, Enum.Material.Metal)
	makeCylinder(model, "Disc", 6.2, 0.5, CFrame.new(cx, 1.4, cz), chrome, Enum.Material.Metal)
	-- Three vertical fins
	for i = 0, 2 do
		local angle = (i / 3) * math.pi * 2
		local sx = cx + math.cos(angle) * 1.8
		local sz = cz + math.sin(angle) * 1.8
		local fin = makeBlock(
			model,
			"Fin" .. i,
			Vector3.new(0.6, 6.5, 2.4),
			CFrame.new(sx, 5.2, sz) * CFrame.Angles(0, angle + math.pi / 2, 0),
			chrome,
			Enum.Material.Metal
		)
		fin.Color = chrome
	end
	-- Hovering plasma core
	local core =
		makeSphere(model, "Core", 2.8, Vector3.new(cx, 6, cz), def.accent, Enum.Material.Neon)
	addPointLight(core, def.accent, 16, 2.5)
	-- Outer halo ring (cylinder mesh scaled flat)
	local halo =
		makeCylinder(model, "Halo", 5, 0.25, CFrame.new(cx, 6, cz), def.color, Enum.Material.Neon)
	halo.Transparency = 0.3
	return core
end

local function buildCelestial(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	-- Premium 99 R$ tower. Layered gold plinth, tall crystal pillar
	-- with inner glow, orbital rings, and a blazing starforge crown.
	local cx, cz = pos.X, pos.Z
	local gold = Color3.fromRGB(255, 215, 110)
	local goldDark = Color3.fromRGB(180, 140, 45)
	local ivory = Color3.fromRGB(255, 245, 220)

	-- Three-tier plinth
	makeCylinder(
		model,
		"PlinthBase",
		8,
		1.4,
		CFrame.new(cx, 0.7, cz),
		goldDark,
		Enum.Material.Marble
	)
	makeCylinder(model, "PlinthMid", 6.5, 0.9, CFrame.new(cx, 1.85, cz), gold, Enum.Material.Marble)
	makeCylinder(
		model,
		"PlinthTop",
		5.2,
		0.7,
		CFrame.new(cx, 2.65, cz),
		goldDark,
		Enum.Material.Marble
	)

	-- Runic band around the plinth
	for i = 0, 7 do
		local angle = (i / 8) * math.pi * 2
		local rx = cx + math.cos(angle) * 3
		local rz = cz + math.sin(angle) * 3
		local rune = makeBlock(
			model,
			"Rune" .. i,
			Vector3.new(0.5, 0.6, 0.5),
			CFrame.new(rx, 2.25, rz) * CFrame.Angles(0, angle, 0),
			def.accent,
			Enum.Material.Neon
		)
		rune.Transparency = 0.2
	end

	-- Central crystal pillar
	local pillar = makeBlock(
		model,
		"Pillar",
		Vector3.new(1.6, 10, 1.6),
		CFrame.new(cx, 8, cz) * CFrame.Angles(0, math.rad(45), 0),
		def.color,
		Enum.Material.Glass
	)
	pillar.Transparency = 0.05
	addPointLight(pillar, def.color, 20, 2.5)

	-- Floating orbital rings around the pillar
	for i = 1, 3 do
		local y = 5 + (i - 1) * 2.5
		local ring = makeCylinder(
			model,
			"Ring" .. i,
			4.5 + (i - 1) * 0.5,
			0.25,
			CFrame.new(cx, y, cz) * CFrame.Angles(math.rad(15 * (i - 1)), 0, 0),
			gold,
			Enum.Material.Neon
		)
		ring.Transparency = 0.25
	end

	-- Six satellite orbs orbiting the pillar at mid-height
	for i = 0, 5 do
		local angle = (i / 6) * math.pi * 2
		local ox = cx + math.cos(angle) * 3.2
		local oz = cz + math.sin(angle) * 3.2
		local orb = makeSphere(
			model,
			"Orb" .. i,
			0.9,
			Vector3.new(ox, 7.5, oz),
			def.accent,
			Enum.Material.Neon
		)
		addPointLight(orb, def.accent, 6, 1.2)
	end

	-- Starforge crown at the very top
	local crown =
		makeSphere(model, "Crown", 3.4, Vector3.new(cx, 14.2, cz), def.color, Enum.Material.Neon)
	addPointLight(crown, def.color, 30, 5)

	-- Six spike crests around the crown
	for i = 0, 5 do
		local angle = (i / 6) * math.pi * 2
		local sx = cx + math.cos(angle) * 1.8
		local sz = cz + math.sin(angle) * 1.8
		local spike = makeBlock(
			model,
			"CrownSpike" .. i,
			Vector3.new(0.4, 2.2, 0.4),
			CFrame.new(sx, 15.6, sz)
				* CFrame.Angles(math.rad(math.cos(angle) * 25), 0, math.rad(math.sin(angle) * 25)),
			ivory,
			Enum.Material.Neon
		)
		spike.Transparency = 0.1
	end

	-- Tiny finial at the very top
	makeSphere(model, "Finial", 0.7, Vector3.new(cx, 17, cz), ivory, Enum.Material.Neon)

	return crown
end

-- ============================================================================
-- Unique realm signature builders (2 extras per non-defense realm)
-- ============================================================================
-- Each non-defense realm has 3 theme-exclusive towers. One uses the
-- dedicated buildIcelance/buildSandstorm/buildThornwall/buildPlasma
-- silhouettes above, and the other two get their own unique builders
-- defined here so the realms don't reuse base-tower visuals.

-- Frost: Blizzard Mage — ice obelisk with 3 orbiting snow shards
local function buildBlizzardMage(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local ice = def.color
	local glow = def.accent
	makeCylinder(
		model,
		"Base",
		6,
		1.4,
		CFrame.new(cx, 0.7, cz),
		Color3.fromRGB(110, 140, 170),
		Enum.Material.Ice
	)
	local pillar = makeBlock(
		model,
		"Pillar",
		Vector3.new(2.6, 10, 2.6),
		CFrame.new(cx, 6.4, cz) * CFrame.Angles(0, math.rad(45), 0),
		ice,
		Enum.Material.Ice
	)
	pillar.Transparency = 0.15
	for i = 0, 2 do
		local angle = (i / 3) * math.pi * 2
		local sx = cx + math.cos(angle) * 3.2
		local sz = cz + math.sin(angle) * 3.2
		local shard = makeBlock(
			model,
			"Shard_" .. i,
			Vector3.new(0.5, 3, 0.5),
			CFrame.new(sx, 8.5, sz) * CFrame.Angles(math.rad(15), angle, 0),
			glow,
			Enum.Material.Ice
		)
		shard.Transparency = 0.1
	end
	local orb = makeSphere(model, "Orb", 2, Vector3.new(cx, 12.5, cz), glow, Enum.Material.Neon)
	addPointLight(orb, glow, 14, 2)
	return orb
end

-- Frost: Icebound Cannon — heavy bunker with a massive ice barrel
local function buildIceCannon(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local stone = Color3.fromRGB(140, 170, 200)
	local ice = def.color
	makeBlock(model, "Base", Vector3.new(7, 2, 7), CFrame.new(cx, 1, cz), stone, Enum.Material.Ice)
	local bunker = makeBlock(
		model,
		"Bunker",
		Vector3.new(5.5, 3.5, 5.5),
		CFrame.new(cx, 3.75, cz),
		stone,
		Enum.Material.Ice
	)
	bunker.Transparency = 0.1
	-- Four icicle teeth around the top of the bunker
	for _, off in { { -2, -2 }, { 2, -2 }, { -2, 2 }, { 2, 2 } } do
		local spike = makeBlock(
			model,
			"Tooth",
			Vector3.new(0.6, 2, 0.6),
			CFrame.new(cx + off[1], 6, cz + off[2]),
			ice,
			Enum.Material.Ice
		)
		spike.Transparency = 0.1
	end
	local barrel = makeCylinder(
		model,
		"Barrel",
		2.2,
		6,
		CFrame.new(cx, 5, cz - 2) * CFrame.Angles(math.rad(90), 0, 0),
		ice,
		Enum.Material.Ice
	)
	barrel.Transparency = 0.15
	local muzzle =
		makeSphere(model, "Muzzle", 2.2, Vector3.new(cx, 5, cz - 5), def.accent, Enum.Material.Neon)
	addPointLight(muzzle, def.accent, 10, 1.8)
	return muzzle
end

-- Desert: Sun Archer — gold pagoda with a radiant sun disc on top
local function buildSunArcher(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local sand = Color3.fromRGB(214, 175, 106)
	local gold = def.color
	makeBlock(
		model,
		"Base",
		Vector3.new(6, 1.4, 6),
		CFrame.new(cx, 0.7, cz),
		sand,
		Enum.Material.Sandstone
	)
	makeBlock(
		model,
		"Tier1",
		Vector3.new(5, 2.4, 5),
		CFrame.new(cx, 2.6, cz),
		gold,
		Enum.Material.Sandstone
	)
	makeBlock(
		model,
		"Tier2",
		Vector3.new(3.8, 2.2, 3.8),
		CFrame.new(cx, 5, cz),
		sand,
		Enum.Material.Sandstone
	)
	makeBlock(
		model,
		"Tier3",
		Vector3.new(2.6, 2, 2.6),
		CFrame.new(cx, 7.1, cz),
		gold,
		Enum.Material.Sandstone
	)
	local disc = makeCylinder(
		model,
		"SunDisc",
		5,
		0.4,
		CFrame.new(cx, 9, cz) * CFrame.Angles(0, 0, math.rad(90)),
		def.accent,
		Enum.Material.Neon
	)
	disc.Transparency = 0.15
	-- Eight sun rays radiating from the disc
	for i = 0, 7 do
		local angle = (i / 8) * math.pi * 2
		local rx = cx + math.cos(angle) * 3.3
		local rz = cz + math.sin(angle) * 3.3
		makeBlock(
			model,
			"Ray_" .. i,
			Vector3.new(0.4, 0.3, 1.8),
			CFrame.new(rx, 9, rz) * CFrame.Angles(0, -angle, 0),
			def.accent,
			Enum.Material.Neon
		)
	end
	local orb =
		makeSphere(model, "SunOrb", 1.8, Vector3.new(cx, 9, cz), def.accent, Enum.Material.Neon)
	addPointLight(orb, def.accent, 16, 2.5)
	return orb
end

-- Desert: Pyre Mage — stepped pyramid altar with an open flame bowl
local function buildPyreMage(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local dark = Color3.fromRGB(120, 60, 30)
	local sand = Color3.fromRGB(180, 100, 50)
	makeBlock(
		model,
		"Base",
		Vector3.new(7, 1.4, 7),
		CFrame.new(cx, 0.7, cz),
		dark,
		Enum.Material.Sandstone
	)
	makeBlock(
		model,
		"Tier1",
		Vector3.new(5.5, 1.6, 5.5),
		CFrame.new(cx, 2.2, cz),
		sand,
		Enum.Material.Sandstone
	)
	makeBlock(
		model,
		"Tier2",
		Vector3.new(4.2, 1.6, 4.2),
		CFrame.new(cx, 3.8, cz),
		dark,
		Enum.Material.Sandstone
	)
	makeBlock(
		model,
		"Tier3",
		Vector3.new(3, 1.6, 3),
		CFrame.new(cx, 5.4, cz),
		sand,
		Enum.Material.Sandstone
	)
	-- Flame bowl on top (hollow cylinder with a neon flame ball)
	local bowl =
		makeCylinder(model, "Bowl", 3, 1, CFrame.new(cx, 6.8, cz), dark, Enum.Material.Sandstone)
	bowl.Transparency = 0.05
	local flame =
		makeSphere(model, "Flame", 2.4, Vector3.new(cx, 8.2, cz), def.accent, Enum.Material.Neon)
	addPointLight(flame, def.accent, 18, 3)
	-- Four horn pillars at the corners of the altar
	for _, off in { { -2.2, -2.2 }, { 2.2, -2.2 }, { -2.2, 2.2 }, { 2.2, 2.2 } } do
		makeBlock(
			model,
			"Horn",
			Vector3.new(0.6, 3.2, 0.6),
			CFrame.new(cx + off[1], 3, cz + off[2]),
			dark,
			Enum.Material.Sandstone
		)
	end
	return flame
end

-- Forest: Grove Archer — gnarled tree tower with arrow nests in the branches
local function buildGroveArcher(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local bark = Color3.fromRGB(70, 45, 25)
	local leaf = def.color
	local accent = def.accent
	makeCylinder(model, "Roots", 6, 1, CFrame.new(cx, 0.5, cz), bark, Enum.Material.Wood)
	local trunk =
		makeCylinder(model, "Trunk", 3, 10, CFrame.new(cx, 6, cz), bark, Enum.Material.Wood)
	-- Three canopy blobs at different heights for a leafy crown
	for i = 0, 2 do
		local y = 9 + i * 1.8
		local s = 6 - i * 0.8
		local canopy = makeSphere(
			model,
			"Canopy_" .. i,
			s,
			Vector3.new(cx + (i - 1) * 0.4, y, cz + (i - 1) * 0.3),
			leaf,
			Enum.Material.LeafyGrass
		)
		canopy.Transparency = 0.05
	end
	-- Two arrow nests tucked into the canopy
	for i = 1, 2 do
		local side = if i == 1 then -1 else 1
		makeBlock(
			model,
			"Nest_" .. i,
			Vector3.new(1.2, 0.6, 1.2),
			CFrame.new(cx + side * 2.2, 9.4, cz),
			bark,
			Enum.Material.Wood
		)
		local arrowTip = makeBlock(
			model,
			"Arrow_" .. i,
			Vector3.new(0.25, 0.25, 1.6),
			CFrame.new(cx + side * 2.2, 9.8, cz - 0.6),
			accent,
			Enum.Material.Neon
		)
		arrowTip.Transparency = 0.1
	end
	local orb =
		makeSphere(model, "Crown", 1.4, Vector3.new(cx, 12.6, cz), accent, Enum.Material.Neon)
	addPointLight(orb, accent, 10, 1.5)
	return trunk
end

-- Forest: Venom Cloud — cauldron on a wooden lattice frame with dripping slime
local function buildVenomCloud(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local bark = Color3.fromRGB(60, 38, 22)
	local venom = def.accent
	makeBlock(
		model,
		"Base",
		Vector3.new(6, 1, 6),
		CFrame.new(cx, 0.5, cz),
		Color3.fromRGB(50, 65, 40),
		Enum.Material.LeafyGrass
	)
	-- 4 wooden legs forming the cauldron frame
	for _, off in { { -2, -2 }, { 2, -2 }, { -2, 2 }, { 2, 2 } } do
		makeBlock(
			model,
			"Leg",
			Vector3.new(0.6, 4, 0.6),
			CFrame.new(cx + off[1], 3, cz + off[2]),
			bark,
			Enum.Material.Wood
		)
	end
	-- Cauldron: dark block with a glowing top pool
	makeCylinder(model, "Cauldron", 5, 2.4, CFrame.new(cx, 5.5, cz), def.color, Enum.Material.Metal)
	local brew =
		makeCylinder(model, "Brew", 4.2, 0.5, CFrame.new(cx, 6.8, cz), venom, Enum.Material.Neon)
	brew.Transparency = 0.15
	addPointLight(brew, venom, 14, 2.5)
	-- Dripping slime blobs hanging off the cauldron rim
	for i = 0, 3 do
		local angle = (i / 4) * math.pi * 2
		local dx = cx + math.cos(angle) * 2.4
		local dz = cz + math.sin(angle) * 2.4
		local drip = makeSphere(
			model,
			"Drip_" .. i,
			0.7,
			Vector3.new(dx, 6.1, dz),
			venom,
			Enum.Material.Neon
		)
		drip.Transparency = 0.2
	end
	-- Steaming crown on top of the brew
	local crown = makeSphere(model, "Crown", 1.8, Vector3.new(cx, 8, cz), venom, Enum.Material.Neon)
	crown.Transparency = 0.3
	return crown
end

-- Space: Void Cannon — alien obelisk with orbiting neon rings
local function buildVoidCannon(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local metal = Color3.fromRGB(40, 36, 70)
	local neon = def.accent
	makeBlock(
		model,
		"Base",
		Vector3.new(6, 2, 6),
		CFrame.new(cx, 1, cz),
		metal,
		Enum.Material.DiamondPlate
	)
	-- Tapered obelisk (3 narrowing slabs stacked)
	makeBlock(
		model,
		"Slab1",
		Vector3.new(3.5, 4, 3.5),
		CFrame.new(cx, 4, cz) * CFrame.Angles(0, math.rad(45), 0),
		def.color,
		Enum.Material.Metal
	)
	makeBlock(
		model,
		"Slab2",
		Vector3.new(2.8, 3.6, 2.8),
		CFrame.new(cx, 7.8, cz) * CFrame.Angles(0, math.rad(45), 0),
		metal,
		Enum.Material.Metal
	)
	makeBlock(
		model,
		"Slab3",
		Vector3.new(2, 3, 2),
		CFrame.new(cx, 11.1, cz) * CFrame.Angles(0, math.rad(45), 0),
		def.color,
		Enum.Material.Metal
	)
	-- Three orbiting neon rings stacked up the obelisk
	for i = 1, 3 do
		local y = 4 + i * 2.4
		local r = 5 - i * 0.7
		local ring = makeCylinder(
			model,
			"Ring_" .. i,
			r,
			0.3,
			CFrame.new(cx, y, cz),
			neon,
			Enum.Material.Neon
		)
		ring.Transparency = 0.2
	end
	local core = makeSphere(model, "Core", 2, Vector3.new(cx, 13.5, cz), neon, Enum.Material.Neon)
	addPointLight(core, neon, 18, 3)
	return core
end

-- Space: Tesla Storm — three coils arcing electricity into a central hub
local function buildTeslaStorm(model: Model, def: TowerDefs.TowerDef, pos: Vector3): Part
	local cx, cz = pos.X, pos.Z
	local metal = Color3.fromRGB(60, 58, 80)
	local arc = def.accent
	makeCylinder(model, "Base", 6, 1.4, CFrame.new(cx, 0.7, cz), metal, Enum.Material.Metal)
	-- Three tesla coils in a triangle around the hub
	for i = 0, 2 do
		local angle = (i / 3) * math.pi * 2 + math.rad(30)
		local px = cx + math.cos(angle) * 2.2
		local pz = cz + math.sin(angle) * 2.2
		makeCylinder(
			model,
			"Coil_" .. i,
			1.2,
			7,
			CFrame.new(px, 4.8, pz),
			metal,
			Enum.Material.Metal
		)
		-- Glowing arc ball on top of each coil
		local tip =
			makeSphere(model, "Tip_" .. i, 1.3, Vector3.new(px, 8.6, pz), arc, Enum.Material.Neon)
		addPointLight(tip, arc, 10, 2)
	end
	-- Central hub that connects the coils
	makeBlock(
		model,
		"Hub",
		Vector3.new(2.6, 3.2, 2.6),
		CFrame.new(cx, 3.6, cz) * CFrame.Angles(0, math.rad(45), 0),
		def.color,
		Enum.Material.Metal
	)
	-- Top antenna rod
	makeCylinder(model, "Rod", 0.4, 3.5, CFrame.new(cx, 7, cz), arc, Enum.Material.Neon)
	local core = makeSphere(model, "Core", 1.8, Vector3.new(cx, 9.4, cz), arc, Enum.Material.Neon)
	addPointLight(core, arc, 16, 3)
	return core
end

local TOWER_BUILDERS: { [string]: (Model, TowerDefs.TowerDef, Vector3) -> Part } = {
	-- Base (universal) towers — available in every realm
	basic = buildArcher,
	sniper = buildWizard,
	cannon = buildCannon,
	freeze = buildFrost,
	flame = buildInferno,

	-- "Unique" signature towers (dedicated silhouettes, 1 per realm).
	-- Defense no longer has signature towers (first realm is base only);
	-- paladin is kept here for backwards compatibility but unused.
	paladin = buildPaladin,
	icelance = buildIcelance,
	sandstorm = buildSandstorm,
	thornwall = buildThornwall,
	plasma = buildPlasma,

	-- The old universal archetypes are now signature-only: poison lives
	-- in forest (venom_cloud), lightning in space (tesla_storm), etc.
	lightning = buildStorm,
	poison = buildAlchemist,

	-- Defense legacy variants (no longer in RealmDefs.defense.signatureTowers,
	-- kept so older save data still has builders to look up).
	thunder_knight = buildStorm,
	chapel_archer = buildArcher,

	-- Themed signature extras — each realm's 2 remaining signatures now
	-- have their own unique builder instead of sharing base visuals.
	blizzard_mage = buildBlizzardMage,
	ice_cannon = buildIceCannon,
	sun_archer = buildSunArcher,
	pyre_mage = buildPyreMage,
	grove_archer = buildGroveArcher,
	venom_cloud = buildVenomCloud,
	void_cannon = buildVoidCannon,
	tesla_storm = buildTeslaStorm,

	-- Premium (game-pass gated) tower
	celestial = buildCelestial,
}

local function buildTowerModel(
	towerType: string,
	def: TowerDefs.TowerDef,
	pos: Vector3
): (Model, Part)
	local model = Instance.new("Model")
	model.Name = "Tower_" .. def.name

	local builder = TOWER_BUILDERS[towerType] or buildArcher
	local focus = builder(model, def, pos)

	-- Use an invisible anchor as the PrimaryPart so pivot reflects world pos
	local anchor = Instance.new("Part")
	anchor.Name = "_Anchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Position = pos
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CastShadow = false
	anchor.Parent = model
	model.PrimaryPart = anchor

	return model, focus
end

-- Builds a display-only copy of a tower model at an arbitrary position.
-- Used by the lobby to drop a celestial tower on a rotating pedestal.
-- The tower builders author their parts at Y=0 assuming the arena
-- ground, so we shift every part up by pos.Y after building to move the
-- finished model into the lobby altitude.
function TowerManager.buildDisplayModel(towerType: string, pos: Vector3): Model?
	local def = TowerDefs[towerType]
	if not def then
		return nil
	end
	local builder = TOWER_BUILDERS[towerType]
	if not builder then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "DisplayTower_" .. towerType
	builder(model, def, Vector3.new(pos.X, 0, pos.Z))
	if pos.Y ~= 0 then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Position = d.Position + Vector3.new(0, pos.Y, 0)
			end
		end
	end
	return model
end

-- --- Public API ---

-- Build a new TowerManager bound to this arena. `parentFolder` is the
-- workspace container for the player's arena; we create Towers and
-- Projectiles subfolders under it. `originOffset` is the arena's
-- world-space slot offset — every tower position is
-- `Config.gridToWorld(gx, gy) + originOffset` so towers end up in
-- their owner's private arena. `enemyMgr` is the same arena's
-- EnemyManager instance; towers query it for targeting, and splash /
-- slow / poison effects route back through it.
function TowerManager.new(
	parentFolder: Instance,
	originOffset: Vector3,
	enemyMgr: EnemyManager.EnemyManager
): TowerManager
	local tf = Instance.new("Folder")
	tf.Name = "Towers"
	tf.Parent = parentFolder

	local pf = Instance.new("Folder")
	pf.Name = "Projectiles"
	pf.Parent = parentFolder

	local self = setmetatable({
		towers = {},
		projectiles = {},
		towerFolder = tf,
		projectileFolder = pf,
		originOffset = originOffset,
		enemyMgr = enemyMgr,
	}, TowerManager)
	return (self :: any) :: TowerManager
end

function TowerManager.isOccupied(self: TowerManager, gx: number, gy: number): boolean
	for _, t in self.towers do
		if t.gx == gx and t.gy == gy then
			return true
		end
	end
	return false
end

function TowerManager.place(self: TowerManager, gx: number, gy: number, towerType: string): Tower?
	local def = TowerDefs[towerType]
	if not def then
		warn(string.format("Unknown tower type: %s", towerType))
		return nil
	end

	local pos = Config.gridToWorld(gx, gy) + self.originOffset
	local model, focus = buildTowerModel(towerType, def, pos)
	model.Parent = self.towerFolder

	local tower: Tower = {
		gx = gx,
		gy = gy,
		towerType = towerType,
		def = def,
		model = model,
		orb = focus,
		x = pos.X,
		z = pos.Z,
		projectileY = focus.Position.Y,
		fireCooldown = 0,
	}
	table.insert(self.towers, tower)
	return tower
end

function TowerManager.remove(self: TowerManager, tower: Tower)
	tower.model:Destroy()
	for i = #self.towers, 1, -1 do
		if self.towers[i] == tower then
			table.remove(self.towers, i)
			break
		end
	end
end

function TowerManager.getAt(self: TowerManager, gx: number, gy: number): Tower?
	for _, t in self.towers do
		if t.gx == gx and t.gy == gy then
			return t
		end
	end
	return nil
end

-- --- Firing and projectile motion ---

local function fire(self: TowerManager, tower: Tower, target: EnemyManager.Enemy)
	local proj = Instance.new("Part")
	proj.Name = "Projectile"
	proj.Shape = Enum.PartType.Ball
	proj.Size = Vector3.new(0.8, 0.8, 0.8)
	proj.Color = tower.def.projectileColor
	proj.Material = Enum.Material.Neon
	proj.Anchored = true
	proj.CanCollide = false
	proj.Position = Vector3.new(tower.x, tower.projectileY, tower.z)
	proj.Parent = self.projectileFolder

	table.insert(self.projectiles, {
		part = proj,
		target = target,
		tower = tower,
		speed = tower.def.projectileSpeed,
	})
end

local function updateProjectiles(self: TowerManager, dt: number)
	local projectiles = self.projectiles
	local enemyMgr = self.enemyMgr
	for i = #projectiles, 1, -1 do
		local p = projectiles[i]

		if not p.target.alive then
			p.part:Destroy()
			table.remove(projectiles, i)
			continue
		end

		local targetPos = p.target.root.Position
		local toTarget = targetPos - p.part.Position
		local dist = toTarget.Magnitude
		local step = p.speed * dt

		if dist <= step + 1 then
			-- Hit
			local def = p.tower.def

			if def.splash > 0 then
				for _, enemy in enemyMgr:getAlive() do
					local d = (enemy.root.Position - targetPos).Magnitude
					if d <= def.splash then
						local falloff = 1 - (d / def.splash) * 0.5
						enemyMgr:damage(
							enemy,
							math.floor(def.damage * falloff),
							p.tower.towerType
						)
					end
				end
			else
				enemyMgr:damage(p.target, def.damage, p.tower.towerType)
			end

			if def.slowFactor and p.target.alive then
				enemyMgr:applySlow(p.target, def.slowFactor, def.slowDuration or 2)
			end
			if def.poisonDps and p.target.alive then
				enemyMgr:applyPoison(p.target, def.poisonDps, def.poisonDuration or 4)
			end

			p.part:Destroy()
			table.remove(projectiles, i)
		else
			p.part.Position = p.part.Position + toTarget.Unit * step
		end
	end
end

function TowerManager.update(self: TowerManager, dt: number)
	local enemyMgr = self.enemyMgr
	for _, tower in self.towers do
		tower.fireCooldown -= dt
		if tower.fireCooldown > 0 then
			continue
		end

		-- Find the nearest enemy in range
		local nearest: EnemyManager.Enemy? = nil
		local nearestDist = math.huge
		for _, enemy in enemyMgr:getAlive() do
			local dx = enemy.root.Position.X - tower.x
			local dz = enemy.root.Position.Z - tower.z
			local d = math.sqrt(dx * dx + dz * dz)
			if d <= tower.def.range and d < nearestDist then
				nearest = enemy
				nearestDist = d
			end
		end

		if nearest then
			fire(self, tower, nearest)
			tower.fireCooldown = 1 / tower.def.fireRate

			-- Only cannon towers physically rotate to aim — everything else
			-- (archers, wizards, frost, storm, alchemist, inferno) is static.
			if tower.towerType == "cannon" then
				local targetPos = nearest.root.Position
				local barrelPos = tower.orb.Position
				tower.orb.CFrame =
					CFrame.lookAt(barrelPos, Vector3.new(targetPos.X, barrelPos.Y, targetPos.Z))
			end
		end
	end

	updateProjectiles(self, dt)
end

function TowerManager.clear(self: TowerManager)
	for _, t in self.towers do
		t.model:Destroy()
	end
	for _, p in self.projectiles do
		p.part:Destroy()
	end
	self.towers = {}
	self.projectiles = {}
end

-- Return a minimal serializable list of every placed tower so the
-- GameState can persist the layout when the player leaves a realm.

function TowerManager.snapshot(self: TowerManager): { TowerSnapshot }
	local out: { TowerSnapshot } = {}
	for _, t in self.towers do
		table.insert(out, { gx = t.gx, gy = t.gy, towerType = t.towerType })
	end
	return out
end

-- Rebuild towers from a snapshot (called on realm re-entry). Skips
-- towers whose type no longer exists (e.g. stale data after a content
-- update). Does NOT charge gold — that was paid when the towers were
-- originally placed.
function TowerManager.restoreFrom(self: TowerManager, snapshots: { TowerSnapshot })
	for _, snap in snapshots do
		if TowerDefs[snap.towerType] then
			TowerManager.place(self, snap.gx, snap.gy, snap.towerType)
		end
	end
end

return TowerManager
