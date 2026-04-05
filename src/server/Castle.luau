--!strict
-- src/server/Castle.luau
-- A visible stone castle placed at the end of the path. Each realm gets a
-- themed variant driven by CASTLE_THEMES below (stone color, roof, flag,
-- accent material, and per-realm "flair" geometry like braziers for
-- desert, crystals for frost, or neon strips for space).
--
-- Exposes:
--   Castle.build(pos, maxHp, realmName) -> extra waypoints into the keep
--   Castle.updateHp(current, max)       -- refresh the HP bar
--   Castle.flashDamage()                -- brief red flash on a hit
--   Castle.explode()                    -- physics blow-apart on loss

-- Castle used to stash module-level refs (hpFill, bodyParts, etc.) for
-- the one-and-only castle. The multiplayer refactor moved all of that
-- into a returned context object so each player's arena can own its
-- own castle. Castle.build(...) returns a CastleContext handle; every
-- other public function now takes that handle explicitly.
local Castle = {}

export type CastleContext = {
	folder: Folder,
	center: Vector3,
	hpFill: Frame?,
	hpText: TextLabel?,
	bodyParts: { Part },
	originalColors: { [Part]: Color3 },
}

type CastleTheme = {
	stone: Color3,
	stoneDark: Color3,
	roof: Color3,
	roofMaterial: Enum.Material,
	flag: Color3,
	flagAccent: Color3,
	accent: Color3, -- glowing accent color for crystals/braziers/neon
	accentMaterial: Enum.Material,
	stoneMaterial: Enum.Material,
	baseMaterial: Enum.Material,
	windowGlow: Color3,
	flair: string, -- "brazier" | "crystal" | "flame" | "lantern" | "neon"
}

local CASTLE_THEMES: { [string]: CastleTheme } = {
	defense = {
		stone = Color3.fromRGB(150, 145, 135),
		stoneDark = Color3.fromRGB(95, 90, 82),
		roof = Color3.fromRGB(120, 40, 35),
		roofMaterial = Enum.Material.Slate,
		flag = Color3.fromRGB(200, 40, 30),
		flagAccent = Color3.fromRGB(240, 210, 120),
		accent = Color3.fromRGB(255, 150, 60),
		accentMaterial = Enum.Material.Neon,
		stoneMaterial = Enum.Material.Brick,
		baseMaterial = Enum.Material.Slate,
		windowGlow = Color3.fromRGB(255, 180, 80),
		flair = "brazier",
	},
	frost = {
		stone = Color3.fromRGB(205, 225, 240),
		stoneDark = Color3.fromRGB(135, 165, 195),
		roof = Color3.fromRGB(150, 200, 235),
		roofMaterial = Enum.Material.Ice,
		flag = Color3.fromRGB(110, 190, 240),
		flagAccent = Color3.fromRGB(235, 250, 255),
		accent = Color3.fromRGB(140, 220, 255),
		accentMaterial = Enum.Material.Neon,
		stoneMaterial = Enum.Material.Ice,
		baseMaterial = Enum.Material.Ice,
		windowGlow = Color3.fromRGB(120, 210, 255),
		flair = "crystal",
	},
	desert = {
		stone = Color3.fromRGB(220, 185, 120),
		stoneDark = Color3.fromRGB(150, 115, 65),
		roof = Color3.fromRGB(200, 155, 60),
		roofMaterial = Enum.Material.Sandstone,
		flag = Color3.fromRGB(220, 175, 55),
		flagAccent = Color3.fromRGB(110, 60, 25),
		accent = Color3.fromRGB(255, 165, 40),
		accentMaterial = Enum.Material.Neon,
		stoneMaterial = Enum.Material.Sandstone,
		baseMaterial = Enum.Material.Sandstone,
		windowGlow = Color3.fromRGB(255, 180, 80),
		flair = "flame",
	},
	forest = {
		stone = Color3.fromRGB(95, 85, 65),
		stoneDark = Color3.fromRGB(55, 45, 30),
		roof = Color3.fromRGB(30, 80, 35),
		roofMaterial = Enum.Material.LeafyGrass,
		flag = Color3.fromRGB(55, 150, 60),
		flagAccent = Color3.fromRGB(200, 230, 120),
		accent = Color3.fromRGB(180, 255, 140),
		accentMaterial = Enum.Material.Neon,
		stoneMaterial = Enum.Material.Rock,
		baseMaterial = Enum.Material.Rock,
		windowGlow = Color3.fromRGB(180, 255, 140),
		flair = "lantern",
	},
	space = {
		stone = Color3.fromRGB(62, 68, 92),
		stoneDark = Color3.fromRGB(28, 32, 50),
		roof = Color3.fromRGB(30, 34, 55),
		roofMaterial = Enum.Material.DiamondPlate,
		flag = Color3.fromRGB(180, 90, 240),
		flagAccent = Color3.fromRGB(240, 200, 255),
		accent = Color3.fromRGB(180, 90, 240),
		accentMaterial = Enum.Material.Neon,
		stoneMaterial = Enum.Material.Metal,
		baseMaterial = Enum.Material.DiamondPlate,
		windowGlow = Color3.fromRGB(180, 90, 240),
		flair = "neon",
	},
}

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
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Scratch tables used by track() during a single Castle.build call.
-- build() resets them on entry and captures them into the returned
-- CastleContext on exit; outside of a build call they're empty. Kept
-- at module scope so the merlonRing / buildFlair helpers can call
-- track() without threading a context parameter through every signature.
-- Safe because Castle.build() is atomic (never yields).
local scratchBodyParts: { Part } = {}
local scratchOriginalColors: { [Part]: Color3 } = {}

local function track(part: Part)
	-- Tint-flashable parts: collected so flashDamage can swap them together
	table.insert(scratchBodyParts, part)
	scratchOriginalColors[part] = part.Color
end

-- Thin decorative "arrow slit" — a dark rectangle embedded on a wall face
-- so the keep and corner towers read as inhabited fortifications.
local function arrowSlit(parent: Instance, name: string, cf: CFrame, windowGlow: Color3)
	local slit = makeBlock(
		parent,
		name,
		Vector3.new(0.2, 1.6, 0.4),
		cf,
		Color3.fromRGB(10, 8, 4),
		Enum.Material.SmoothPlastic
	)
	slit.CastShadow = false
	-- A tiny neon backing so the slit glows from inside the wall
	local glow = makeBlock(
		parent,
		name .. "_Glow",
		Vector3.new(0.1, 1.2, 0.25),
		cf,
		windowGlow,
		Enum.Material.Neon
	)
	glow.CastShadow = false
end

-- Ring of small merlon blocks along the top edge of a rectangular base.
local function merlonRing(
	parent: Instance,
	name: string,
	cx: number,
	cy: number,
	cz: number,
	halfW: number,
	halfL: number,
	color: Color3,
	material: Enum.Material
)
	local step = 2
	-- North and south edges
	local i = 1
	local x = -halfW
	while x <= halfW do
		local a = makeBlock(
			parent,
			name .. "_N_" .. i,
			Vector3.new(1, 1.2, 0.8),
			CFrame.new(cx + x, cy, cz - halfL),
			color,
			material
		)
		track(a)
		local b = makeBlock(
			parent,
			name .. "_S_" .. i,
			Vector3.new(1, 1.2, 0.8),
			CFrame.new(cx + x, cy, cz + halfL),
			color,
			material
		)
		track(b)
		i += 1
		x += step
	end
	-- East and west edges
	i = 1
	local z = -halfL + step
	while z < halfL do
		local a = makeBlock(
			parent,
			name .. "_E_" .. i,
			Vector3.new(0.8, 1.2, 1),
			CFrame.new(cx + halfW, cy, cz + z),
			color,
			material
		)
		track(a)
		local b = makeBlock(
			parent,
			name .. "_W_" .. i,
			Vector3.new(0.8, 1.2, 1),
			CFrame.new(cx - halfW, cy, cz + z),
			color,
			material
		)
		track(b)
		i += 1
		z += step
	end
end

-- Realm-specific flair object flanking the gate. Each variant shares the
-- same size envelope so the layout stays consistent across realms.
local function buildFlair(
	parent: Instance,
	theme: CastleTheme,
	gx: number,
	gz: number,
	side: number -- -1 = north of gate, +1 = south
)
	local tag = if side < 0 then "L" else "R"
	local baseY = 2
	local flair = theme.flair

	if flair == "brazier" then
		-- Stone bowl on a column with orange flame orb
		local column = makeBlock(
			parent,
			"BrazierCol_" .. tag,
			Vector3.new(1, 4, 1),
			CFrame.new(gx, baseY, gz + side * 3.8),
			theme.stoneDark,
			theme.stoneMaterial
		)
		track(column)
		local bowl = makeBlock(
			parent,
			"BrazierBowl_" .. tag,
			Vector3.new(2.4, 0.8, 2.4),
			CFrame.new(gx, 4.4, gz + side * 3.8),
			theme.stoneDark,
			theme.stoneMaterial
		)
		track(bowl)
		local flame = Instance.new("Part")
		flame.Name = "BrazierFlame_" .. tag
		flame.Shape = Enum.PartType.Ball
		flame.Size = Vector3.new(1.8, 2, 1.8)
		flame.Position = Vector3.new(gx, 5.6, gz + side * 3.8)
		flame.Color = theme.accent
		flame.Material = theme.accentMaterial
		flame.Anchored = true
		flame.CanCollide = false
		flame.Parent = parent
		local light = Instance.new("PointLight")
		light.Color = theme.accent
		light.Range = 16
		light.Brightness = 2
		light.Parent = flame
	elseif flair == "crystal" then
		-- Tall ice pillar topped with a glowing crystal shard
		local pillar = makeBlock(
			parent,
			"CrystalPillar_" .. tag,
			Vector3.new(1.2, 4.5, 1.2),
			CFrame.new(gx, 2.25, gz + side * 3.8),
			theme.stone,
			theme.stoneMaterial
		)
		pillar.Transparency = 0.15
		track(pillar)
		local crystal = makeBlock(
			parent,
			"CrystalShard_" .. tag,
			Vector3.new(0.8, 3, 0.8),
			CFrame.new(gx, 6, gz + side * 3.8) * CFrame.Angles(0, 0, math.rad(side * 8)),
			theme.accent,
			theme.accentMaterial
		)
		crystal.Transparency = 0.2
		local light = Instance.new("PointLight")
		light.Color = theme.accent
		light.Range = 14
		light.Brightness = 1.8
		light.Parent = crystal
	elseif flair == "flame" then
		-- Sandstone pillar with a caged flame orb on top
		local pillar = makeBlock(
			parent,
			"FlamePillar_" .. tag,
			Vector3.new(1.3, 5, 1.3),
			CFrame.new(gx, 2.5, gz + side * 3.8),
			theme.stone,
			theme.stoneMaterial
		)
		track(pillar)
		local cage = makeBlock(
			parent,
			"FlameCage_" .. tag,
			Vector3.new(2, 2, 2),
			CFrame.new(gx, 6.2, gz + side * 3.8),
			theme.stoneDark,
			theme.stoneMaterial
		)
		track(cage)
		local orb = Instance.new("Part")
		orb.Name = "FlameOrb_" .. tag
		orb.Shape = Enum.PartType.Ball
		orb.Size = Vector3.new(1.2, 1.2, 1.2)
		orb.Position = Vector3.new(gx, 6.2, gz + side * 3.8)
		orb.Color = theme.accent
		orb.Material = theme.accentMaterial
		orb.Anchored = true
		orb.CanCollide = false
		orb.Parent = parent
		local light = Instance.new("PointLight")
		light.Color = theme.accent
		light.Range = 14
		light.Brightness = 2
		light.Parent = orb
	elseif flair == "lantern" then
		-- Wooden post with a hanging lantern orb
		local post = makeBlock(
			parent,
			"LanternPost_" .. tag,
			Vector3.new(0.8, 5, 0.8),
			CFrame.new(gx, 2.5, gz + side * 3.8),
			theme.stoneDark,
			Enum.Material.Wood
		)
		track(post)
		local crossarm = makeBlock(
			parent,
			"LanternArm_" .. tag,
			Vector3.new(2, 0.3, 0.3),
			CFrame.new(gx + 1, 4.8, gz + side * 3.8),
			theme.stoneDark,
			Enum.Material.Wood
		)
		track(crossarm)
		local orb = Instance.new("Part")
		orb.Name = "LanternOrb_" .. tag
		orb.Shape = Enum.PartType.Ball
		orb.Size = Vector3.new(1, 1.2, 1)
		orb.Position = Vector3.new(gx + 1.7, 4.2, gz + side * 3.8)
		orb.Color = theme.accent
		orb.Material = theme.accentMaterial
		orb.Anchored = true
		orb.CanCollide = false
		orb.Parent = parent
		local light = Instance.new("PointLight")
		light.Color = theme.accent
		light.Range = 12
		light.Brightness = 1.8
		light.Parent = orb
	else -- neon
		-- Metal pylon with stacked neon rings
		local pylon = makeBlock(
			parent,
			"NeonPylon_" .. tag,
			Vector3.new(1, 5, 1),
			CFrame.new(gx, 2.5, gz + side * 3.8),
			theme.stoneDark,
			Enum.Material.Metal
		)
		track(pylon)
		for j = 0, 2 do
			local ring = makeBlock(
				parent,
				"NeonRing_" .. tag .. "_" .. j,
				Vector3.new(1.6, 0.3, 1.6),
				CFrame.new(gx, 1.5 + j * 1.6, gz + side * 3.8),
				theme.accent,
				theme.accentMaterial
			)
			ring.Transparency = 0.1
		end
		local top = Instance.new("Part")
		top.Name = "NeonTop_" .. tag
		top.Shape = Enum.PartType.Ball
		top.Size = Vector3.new(1.4, 1.4, 1.4)
		top.Position = Vector3.new(gx, 5.8, gz + side * 3.8)
		top.Color = theme.accent
		top.Material = theme.accentMaterial
		top.Anchored = true
		top.CanCollide = false
		top.Parent = parent
		local light = Instance.new("PointLight")
		light.Color = theme.accent
		light.Range = 14
		light.Brightness = 2
		light.Parent = top
	end
end

-- Builds the castle centered at `pos` (Vector3 in world space). Returns
-- the list of extra waypoints that extend the enemy path into the castle
-- interior (so enemies visually walk into the gate before dying).
-- Build a castle at world-space `pos` parented under `parentFolder`.
-- Returns a CastleContext handle holding refs the caller needs later
-- (HP bar widgets for updateHp, body parts for flashDamage, etc). Was
-- a singleton before the multiplayer refactor — now every call produces
-- a fresh context and nothing lives at module scope across calls. The
-- second return value is the list of extra waypoints that extend the
-- enemy path into the castle gate.
function Castle.build(
	pos: Vector3,
	maxHp: number,
	realmName: string?,
	parentFolder: Instance
): (CastleContext, { Vector3 })
	local theme = CASTLE_THEMES[realmName or "defense"] or CASTLE_THEMES.defense
	local STONE = theme.stone
	local STONE_DARK = theme.stoneDark
	local ROOF = theme.roof

	-- Reset the scratch tables track() writes into, then a fresh folder
	-- parented under the arena container. Previous code used
	-- workspace.Castle as a shared singleton; now every player's arena
	-- holds its own Castle folder under its arena root.
	scratchBodyParts = {}
	scratchOriginalColors = {}

	local folder = Instance.new("Folder")
	folder.Name = "Castle"
	folder.Parent = parentFolder

	local cx = pos.X
	local cz = pos.Z

	-- --- Stone platform with merlon ring ---
	local base = makeBlock(
		folder,
		"Base",
		Vector3.new(18, 2, 20),
		CFrame.new(cx, 1, cz),
		STONE_DARK,
		theme.baseMaterial
	)
	track(base)
	merlonRing(folder, "BaseMerlon", cx, 2.8, cz, 8.5, 9.5, STONE, theme.stoneMaterial)

	-- --- Central keep ---
	local keep = makeBlock(
		folder,
		"Keep",
		Vector3.new(9, 14, 9),
		CFrame.new(cx + 2, 9, cz),
		STONE,
		theme.stoneMaterial
	)
	track(keep)

	-- Arrow slits on the front of the keep
	arrowSlit(
		folder,
		"KeepSlitFL",
		CFrame.new(cx - 2.5, 9, cz - 2) * CFrame.Angles(0, math.rad(90), 0),
		theme.windowGlow
	)
	arrowSlit(
		folder,
		"KeepSlitFR",
		CFrame.new(cx - 2.5, 9, cz + 2) * CFrame.Angles(0, math.rad(90), 0),
		theme.windowGlow
	)
	-- And one higher up in the middle
	arrowSlit(
		folder,
		"KeepSlitUp",
		CFrame.new(cx - 2.5, 13, cz) * CFrame.Angles(0, math.rad(90), 0),
		theme.windowGlow
	)

	-- Keep battlements (merlons around the top)
	for i = 0, 7 do
		local angle = (i / 8) * math.pi * 2
		local bx = cx + 2 + math.cos(angle) * 4.8
		local bz = cz + math.sin(angle) * 4.8
		local bat = makeBlock(
			folder,
			"KeepCren",
			Vector3.new(1, 1.4, 1),
			CFrame.new(bx, 16.7, bz),
			STONE_DARK,
			theme.stoneMaterial
		)
		track(bat)
	end

	-- Conical roof cap on top of the keep
	local keepRoof = makeBlock(
		folder,
		"KeepRoof",
		Vector3.new(6, 3, 6),
		CFrame.new(cx + 2, 17.8, cz),
		ROOF,
		theme.roofMaterial
	)
	track(keepRoof)
	local keepRoofTop = makeBlock(
		folder,
		"KeepRoofTop",
		Vector3.new(2.2, 2, 2.2),
		CFrame.new(cx + 2, 20.3, cz),
		ROOF,
		theme.roofMaterial
	)
	track(keepRoofTop)

	-- --- 4 corner towers ---
	local cornerOffsets = {
		Vector3.new(-7, 0, -8.5),
		Vector3.new(7, 0, -8.5),
		Vector3.new(-7, 0, 8.5),
		Vector3.new(7, 0, 8.5),
	}
	for i, off in cornerOffsets do
		local tx = cx + off.X
		local tz = cz + off.Z
		local tower = makeBlock(
			folder,
			"CornerTower" .. i,
			Vector3.new(3.5, 16, 3.5),
			CFrame.new(tx, 10, tz),
			STONE,
			theme.stoneMaterial
		)
		track(tower)

		-- Arrow slit on the outward face of each tower
		local facing = Vector3.new(off.X, 0, off.Z)
		if facing.Magnitude > 0 then
			facing = facing.Unit
		end
		local slitCF = CFrame.new(tx + facing.X * 1.85, 12, tz + facing.Z * 1.85)
			* CFrame.fromMatrix(Vector3.zero, Vector3.new(-facing.Z, 0, facing.X), Vector3.yAxis)
		arrowSlit(folder, "CornerSlit" .. i, slitCF, theme.windowGlow)

		local cap = makeBlock(
			folder,
			"CornerCap" .. i,
			Vector3.new(4.2, 0.5, 4.2),
			CFrame.new(tx, 18.3, tz),
			STONE_DARK,
			theme.stoneMaterial
		)
		track(cap)
		-- Conical roof as a stacked block
		local roof = makeBlock(
			folder,
			"CornerRoof" .. i,
			Vector3.new(2.4, 2.2, 2.4),
			CFrame.new(tx, 19.7, tz),
			ROOF,
			theme.roofMaterial
		)
		track(roof)
		-- Small spike on top
		local spire = makeBlock(
			folder,
			"CornerSpire" .. i,
			Vector3.new(0.4, 1.4, 0.4),
			CFrame.new(tx, 21.5, tz),
			theme.accent,
			theme.accentMaterial
		)
		spire.CastShadow = false
	end

	-- --- Gate: themed archway on the west side ---
	local gateArch = makeBlock(
		folder,
		"Gate",
		Vector3.new(0.8, 6, 5),
		CFrame.new(cx - 7, 5, cz),
		Color3.fromRGB(20, 12, 6),
		Enum.Material.DiamondPlate
	)
	track(gateArch)

	-- Portcullis bars — four thin vertical bars in front of the gate opening
	for j = 1, 4 do
		local bar = makeBlock(
			folder,
			"Portcullis" .. j,
			Vector3.new(0.25, 5, 0.25),
			CFrame.new(cx - 7.2, 4.5, cz - 1.5 + (j - 1) * 1),
			theme.stoneDark,
			Enum.Material.Metal
		)
		bar.CastShadow = false
	end
	-- Horizontal crossbar
	local crossbar = makeBlock(
		folder,
		"PortcullisBar",
		Vector3.new(0.3, 0.3, 4),
		CFrame.new(cx - 7.2, 6.8, cz),
		theme.stoneDark,
		Enum.Material.Metal
	)
	crossbar.CastShadow = false

	-- Gate flair flanking the archway
	buildFlair(folder, theme, cx - 5.5, cz, -1)
	buildFlair(folder, theme, cx - 5.5, cz, 1)

	-- --- Banner draped on the front of the keep ---
	local banner = makeBlock(
		folder,
		"KeepBanner",
		Vector3.new(0.2, 5, 2.4),
		CFrame.new(cx - 2.6, 10, cz),
		theme.flag,
		Enum.Material.Fabric
	)
	banner.CastShadow = false

	-- Accent trim across the banner
	local bannerTrim = makeBlock(
		folder,
		"KeepBannerTrim",
		Vector3.new(0.25, 0.4, 2.4),
		CFrame.new(cx - 2.6, 12, cz),
		theme.flagAccent,
		Enum.Material.Fabric
	)
	bannerTrim.CastShadow = false

	-- --- Flag pole + flag on top of the keep ---
	makeBlock(
		folder,
		"Pole",
		Vector3.new(0.3, 5, 0.3),
		CFrame.new(cx + 2, 22.5, cz),
		Color3.fromRGB(78, 52, 36),
		Enum.Material.Wood
	)
	makeBlock(
		folder,
		"Flag",
		Vector3.new(3, 1.6, 0.1),
		CFrame.new(cx + 3.5, 23.8, cz),
		theme.flag,
		Enum.Material.Fabric
	)

	-- --- HP bar above the keep ---
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CastleHpBar"
	billboard.Size = UDim2.fromOffset(280, 60)
	billboard.StudsOffset = Vector3.new(0, 18, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	-- Hide from the distant lobby so you don't see a floating HP bar
	-- across the skybox.
	billboard.MaxDistance = 220
	billboard.Parent = keep

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromOffset(280, 22)
	title.Position = UDim2.fromOffset(0, 0)
	title.BackgroundTransparency = 1
	title.Text = "CASTLE"
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(232, 194, 143)
	title.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	title.TextStrokeTransparency = 0
	title.Parent = billboard

	local text = Instance.new("TextLabel")
	text.Name = "HpText"
	text.Size = UDim2.fromOffset(280, 16)
	text.Position = UDim2.fromOffset(0, 22)
	text.BackgroundTransparency = 1
	text.Text = string.format("%d / %d", maxHp, maxHp)
	text.Font = Enum.Font.GothamBold
	text.TextSize = 14
	text.TextColor3 = Color3.fromRGB(255, 255, 255)
	text.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	text.TextStrokeTransparency = 0
	text.Parent = billboard

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.fromOffset(260, 14)
	barBg.Position = UDim2.fromOffset(10, 42)
	barBg.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	barBg.BorderSizePixel = 0
	barBg.Parent = billboard

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 6)
	bgCorner.Parent = barBg
	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = Color3.fromRGB(0, 0, 0)
	bgStroke.Thickness = 2
	bgStroke.Parent = barBg

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(60, 230, 80)
	fill.BorderSizePixel = 0
	fill.Parent = barBg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	-- Capture the scratch tables into the returned context so the
	-- next Castle.build call can overwrite them safely.
	local ctx: CastleContext = {
		folder = folder,
		center = pos,
		hpFill = fill,
		hpText = text,
		bodyParts = scratchBodyParts,
		originalColors = scratchOriginalColors,
	}
	scratchBodyParts = {}
	scratchOriginalColors = {}

	-- Return extra waypoints so enemies walk into the gate and a step
	-- inside before dying
	local extraWaypoints = {
		Vector3.new(cx - 10, 2, cz),
		Vector3.new(cx - 3, 2, cz),
	}
	return ctx, extraWaypoints
end

function Castle.updateHp(ctx: CastleContext, current: number, max: number)
	local hpFill = ctx.hpFill
	local hpText = ctx.hpText
	if not hpFill or not hpText then
		return
	end
	local clamped = math.max(0, current)
	hpText.Text = string.format("%d / %d", clamped, max)
	local ratio = math.max(0, clamped / max)
	hpFill.Size = UDim2.fromScale(ratio, 1)
	if ratio > 0.5 then
		hpFill.BackgroundColor3 = Color3.fromRGB(60, 230, 80)
	elseif ratio > 0.25 then
		hpFill.BackgroundColor3 = Color3.fromRGB(255, 170, 30)
	else
		hpFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
	end
end

function Castle.flashDamage(ctx: CastleContext)
	local bodyParts = ctx.bodyParts
	local originalColors = ctx.originalColors
	if #bodyParts == 0 then
		return
	end
	task.spawn(function()
		for _, part in bodyParts do
			part.Color = Color3.fromRGB(255, 90, 90)
		end
		task.wait(0.12)
		for _, part in bodyParts do
			part.Color = originalColors[part] or part.Color
		end
	end)
end

-- Unanchors every castle part and launches it outward/upward so the
-- castle physically blows apart when the player loses. The folder is
-- destroyed after a short delay so the pieces can fall and settle.
function Castle.explode(ctx: CastleContext)
	local folder = ctx.folder
	if not folder or not folder.Parent then
		return
	end

	local center = ctx.center
	for _, child in folder:GetDescendants() do
		if child:IsA("BasePart") then
			local dx = child.Position.X - center.X
			local dz = child.Position.Z - center.Z
			local dir: Vector3
			local distSq = dx * dx + dz * dz
			if distSq < 0.25 then
				dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
				if dir.Magnitude < 0.01 then
					dir = Vector3.new(1, 0, 0)
				end
				dir = dir.Unit
			else
				dir = Vector3.new(dx, 0, dz).Unit
			end

			child.Anchored = false
			child.CanCollide = true
			child.CastShadow = true
			child.AssemblyLinearVelocity = dir * (25 + math.random() * 15)
				+ Vector3.new(0, 45 + math.random() * 30, 0)
			child.AssemblyAngularVelocity = Vector3.new(
				(math.random() - 0.5) * 12,
				(math.random() - 0.5) * 12,
				(math.random() - 0.5) * 12
			)
		end
	end

	-- Clear refs since the pieces are now owned by physics
	ctx.hpFill = nil
	ctx.hpText = nil
	ctx.bodyParts = {}

	task.delay(5, function()
		if folder and folder.Parent then
			folder:Destroy()
		end
	end)
end

return Castle
