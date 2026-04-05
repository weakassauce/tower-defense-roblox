--!strict
-- src/server/MapThemes.luau
-- Per-realm map theming: the enemy gate (entrance arch where attackers
-- emerge) and the outer surround (tree rings, ridges, mountains, dunes,
-- distant planets). Map.luau builds the realm-agnostic geometry (ground,
-- grid, walls, corners, castle wrap) and delegates the themed pieces
-- here via MapThemes.buildGate and MapThemes.buildSurround.
--
-- Defense is the reference look. Frost swaps rocks for ice spikes, desert
-- flattens the horizon into low dunes so the player can see the edge,
-- forest replaces the outer zone with a dense wall of view-blocking
-- trees, and space removes the outer terrain entirely in favor of a
-- floating platform with distant planets in the sky.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = require(ReplicatedStorage.Shared)
local RealmDefs = Shared.RealmDefs

local MapThemes = {}

export type ThemeContext = {
	mapFolder: Folder,
	palette: RealmDefs.RealmPalette,
	arenaHalf: number,
	groundHalf: number,
	rng: Random,
	castleCenter: Vector3,
	castleHalfW: number,
	castleHalfL: number,
	ground: Part,
}

-- ============================================================================
-- Shared helpers
-- ============================================================================

local function makePart(parent: Instance, name: string): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function makeWedge(parent: Instance, name: string): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.CanCollide = false
	w.CastShadow = true
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.Parent = parent
	return w
end

local function insideCastleArea(ctx: ThemeContext, x: number, z: number): boolean
	local dx = math.abs(x - ctx.castleCenter.X)
	local dz = math.abs(z - ctx.castleCenter.Z)
	return dx <= ctx.castleHalfW + 3 and dz <= ctx.castleHalfL + 3
end

-- Picks a point in the mid-zone (between the grid border and the outer
-- tree-ring band). Retries up to 8 times to avoid the castle footprint.
local function randomMidPoint(
	ctx: ThemeContext,
	innerEdge: number,
	ringInnerEdge: number
): (number, number)
	for _ = 1, 8 do
		local side = ctx.rng:NextInteger(1, 4)
		local along = ctx.rng:NextNumber(-ringInnerEdge, ringInnerEdge)
		local perp = ctx.rng:NextNumber(innerEdge, ringInnerEdge)
		local x, z
		if side == 1 then
			x, z = along, -perp
		elseif side == 2 then
			x, z = along, perp
		elseif side == 3 then
			x, z = -perp, along
		else
			x, z = perp, along
		end
		if not insideCastleArea(ctx, x, z) then
			return x, z
		end
	end
	return ringInnerEdge - 5, ringInnerEdge - 5
end

-- Picks a point in the outer tree-ring band just inside the arena edge.
local function randomRingPoint(
	ctx: ThemeContext,
	ringInnerEdge: number,
	outerEdge: number
): (number, number)
	local side = ctx.rng:NextInteger(1, 4)
	local along = ctx.rng:NextNumber(-outerEdge, outerEdge)
	local perp = ctx.rng:NextNumber(ringInnerEdge, outerEdge)
	if side == 1 then
		return along, -perp
	elseif side == 2 then
		return along, perp
	elseif side == 3 then
		return -perp, along
	else
		return perp, along
	end
end

-- Picks a point in the ridge/dune band that wraps just outside the arena.
-- Returns x, z, and t in [0, 1] for gradient-by-distance effects.
local function randomRidgePoint(
	ctx: ThemeContext,
	innerR: number,
	outerR: number
): (number, number, number)
	local depth = outerR - innerR
	local side = ctx.rng:NextInteger(1, 4)
	local along = ctx.rng:NextNumber(-(ctx.arenaHalf + 70), ctx.arenaHalf + 70)
	local t = ctx.rng:NextNumber()
	local perp = innerR + t * depth
	if side == 1 then
		return along, -perp, t
	elseif side == 2 then
		return along, perp, t
	elseif side == 3 then
		return -perp, along, t
	else
		return perp, along, t
	end
end

-- Picks a point in the far mountain band out past the ridges.
local function randomMountainPoint(
	ctx: ThemeContext,
	innerEdge: number,
	outerEdge: number
): (number, number)
	local side = ctx.rng:NextInteger(1, 4)
	local along = ctx.rng:NextNumber(-(ctx.groundHalf - 15), ctx.groundHalf - 15)
	local perp = ctx.rng:NextNumber(innerEdge, outerEdge)
	if side == 1 then
		return along, -perp
	elseif side == 2 then
		return along, perp
	elseif side == 3 then
		return -perp, along
	else
		return perp, along
	end
end

-- Spawns a trunk+canopy tree using the palette.
local function spawnTree(
	ctx: ThemeContext,
	parent: Instance,
	i: number,
	x: number,
	z: number,
	scale: number
)
	local palette = ctx.palette
	local trunk = makePart(parent, "Trunk_" .. i)
	trunk.Size = Vector3.new(1.2 * scale, 7 * scale, 1.2 * scale)
	trunk.Position = Vector3.new(x, 3.5 * scale, z)
	trunk.Color = palette.trunk
	trunk.Material = Enum.Material.Wood

	local canopy = makePart(parent, "Canopy_" .. i)
	canopy.Shape = Enum.PartType.Ball
	canopy.Size = Vector3.new(6 * scale, 6 * scale, 6 * scale)
	canopy.Position = Vector3.new(x, 8.5 * scale, z)
	canopy.Color = palette.canopy[ctx.rng:NextInteger(1, #palette.canopy)]
	canopy.Material = palette.canopyMaterial
end

-- Builds a stepped mountain at (mx, mz) using the palette's mountain
-- colors and material. Shared across realms that want mountains.
local function buildMountain(ctx: ThemeContext, parent: Instance, i: number, mx: number, mz: number)
	local palette = ctx.palette
	local rng = ctx.rng
	local baseW = 24 + rng:NextNumber() * 24
	local baseH = 22 + rng:NextNumber() * 20
	local midW = baseW * (0.55 + rng:NextNumber() * 0.15)
	local midH = 18 + rng:NextNumber() * 18
	local peakW = midW * (0.45 + rng:NextNumber() * 0.2)
	local peakH = 10 + rng:NextNumber() * 16
	local yaw = rng:NextNumber() * math.pi * 2

	local base = makePart(parent, "MntBase_" .. i)
	base.Size = Vector3.new(baseW, baseH, baseW)
	base.CFrame = CFrame.new(mx, baseH / 2 - 2, mz) * CFrame.Angles(0, yaw, 0)
	base.Color = palette.mountainBase
	base.Material = palette.rockMaterial

	local offX = (rng:NextNumber() - 0.5) * baseW * 0.15
	local offZ = (rng:NextNumber() - 0.5) * baseW * 0.15
	local mid = makePart(parent, "MntMid_" .. i)
	mid.Size = Vector3.new(midW, midH, midW)
	mid.CFrame = CFrame.new(mx + offX, baseH + midH / 2 - 2, mz + offZ)
		* CFrame.Angles(0, yaw + 0.35, 0)
	mid.Color = palette.mountainMid
	mid.Material = palette.rockMaterial

	local upperW = midW * 0.7
	local upperH = 10 + rng:NextNumber() * 12
	local upper = makePart(parent, "MntUpper_" .. i)
	upper.Size = Vector3.new(upperW, upperH, upperW)
	upper.CFrame = CFrame.new(mx + offX * 0.6, baseH + midH + upperH / 2 - 2, mz + offZ * 0.6)
		* CFrame.Angles(0, yaw + 0.7, 0)
	upper.Color = palette.mountainMid
	upper.Material = palette.rockMaterial

	local peak = makePart(parent, "MntPeak_" .. i)
	peak.Size = Vector3.new(peakW, peakH, peakW)
	peak.CFrame = CFrame.new(
		mx + offX * 0.3,
		baseH + midH + upperH + peakH / 2 - 2,
		mz + offZ * 0.3
	) * CFrame.Angles(0, yaw + 1.1, 0)
	peak.Color = palette.mountainPeak
	peak.Material = palette.mountainPeakMaterial
end

-- ============================================================================
-- Gates
-- ============================================================================

-- Defense: medieval stone arch with wooden drawbridge planks and a red
-- banner. This is the original gate from Map.luau; kept verbatim.
local function buildGateDefense(ctx: ThemeContext, firstWp: Vector3)
	local gate = Instance.new("Folder")
	gate.Name = "EnemyGate"
	gate.Parent = ctx.mapFolder

	local gx = firstWp.X
	local gz = firstWp.Z
	local stone = Color3.fromRGB(120, 115, 105)
	local stoneDark = Color3.fromRGB(76, 72, 65)
	local wood = Color3.fromRGB(93, 64, 55)
	local woodDark = Color3.fromRGB(62, 39, 35)
	local darkOpening = Color3.fromRGB(12, 6, 2)

	local function gatePart(name: string): Part
		local p = makePart(gate, name)
		p.CastShadow = true
		return p
	end

	local base = gatePart("Base")
	base.Size = Vector3.new(14, 1.2, 12)
	base.Position = Vector3.new(gx - 3, 0.6, gz)
	base.Color = stoneDark
	base.Material = Enum.Material.Slate

	local pillarL = gatePart("PillarL")
	pillarL.Size = Vector3.new(3.5, 12, 3.5)
	pillarL.Position = Vector3.new(gx - 3, 7.2, gz - 4.8)
	pillarL.Color = stone
	pillarL.Material = Enum.Material.Brick

	local pillarR = gatePart("PillarR")
	pillarR.Size = Vector3.new(3.5, 12, 3.5)
	pillarR.Position = Vector3.new(gx - 3, 7.2, gz + 4.8)
	pillarR.Color = stone
	pillarR.Material = Enum.Material.Brick

	local arch = gatePart("Arch")
	arch.Size = Vector3.new(4, 2.4, 11)
	arch.Position = Vector3.new(gx - 3, 14.4, gz)
	arch.Color = stoneDark
	arch.Material = Enum.Material.Brick

	local capL = gatePart("CapL")
	capL.Size = Vector3.new(4.4, 0.8, 4.4)
	capL.Position = Vector3.new(gx - 3, 15.8, gz - 4.8)
	capL.Color = stoneDark
	capL.Material = Enum.Material.Brick

	local capR = gatePart("CapR")
	capR.Size = Vector3.new(4.4, 0.8, 4.4)
	capR.Position = Vector3.new(gx - 3, 15.8, gz + 4.8)
	capR.Color = stoneDark
	capR.Material = Enum.Material.Brick

	local opening = gatePart("Opening")
	opening.Size = Vector3.new(0.6, 10, 7)
	opening.Position = Vector3.new(gx - 5.4, 6.2, gz)
	opening.Color = darkOpening
	opening.Material = Enum.Material.SmoothPlastic

	for i = 1, 5 do
		local plank = gatePart("Plank" .. i)
		plank.Size = Vector3.new(1.3, 0.35, 8)
		plank.Position = Vector3.new(gx + (i - 1) * 1.4, 1.4, gz)
		plank.Color = if i % 2 == 0 then woodDark else wood
		plank.Material = Enum.Material.Wood
	end

	local chainL = gatePart("ChainL")
	chainL.Size = Vector3.new(0.3, 10, 0.3)
	chainL.Position = Vector3.new(gx + 5, 7, gz - 4.4)
	chainL.Color = Color3.fromRGB(55, 52, 48)
	chainL.Material = Enum.Material.Metal

	local chainR = gatePart("ChainR")
	chainR.Size = Vector3.new(0.3, 10, 0.3)
	chainR.Position = Vector3.new(gx + 5, 7, gz + 4.4)
	chainR.Color = Color3.fromRGB(55, 52, 48)
	chainR.Material = Enum.Material.Metal

	local banner = gatePart("Banner")
	banner.Size = Vector3.new(0.2, 2.8, 2.2)
	banner.Position = Vector3.new(gx - 2.6, 12, gz)
	banner.Color = Color3.fromRGB(120, 30, 30)
	banner.Material = Enum.Material.Fabric
end

-- Frost: crystalline ice arch with jagged ice spikes jutting out of the
-- pillars. Opening is a deep cold void; the cap stones are snow-capped
-- with glowing blue crystals on top.
local function buildGateFrost(ctx: ThemeContext, firstWp: Vector3)
	local gate = Instance.new("Folder")
	gate.Name = "EnemyGate"
	gate.Parent = ctx.mapFolder

	local gx = firstWp.X
	local gz = firstWp.Z
	local ice = Color3.fromRGB(180, 215, 235)
	local iceDark = Color3.fromRGB(110, 150, 185)
	local snow = Color3.fromRGB(245, 250, 255)
	local crystal = Color3.fromRGB(120, 210, 255)
	local voidBlue = Color3.fromRGB(6, 14, 28)

	local function gatePart(name: string): Part
		local p = makePart(gate, name)
		p.CastShadow = true
		return p
	end

	-- Frozen stone platform
	local base = gatePart("Base")
	base.Size = Vector3.new(14, 1.2, 12)
	base.Position = Vector3.new(gx - 3, 0.6, gz)
	base.Color = iceDark
	base.Material = Enum.Material.Ice

	-- Snow dusting on top of the platform
	local snowDust = gatePart("SnowDust")
	snowDust.Size = Vector3.new(13.6, 0.3, 11.6)
	snowDust.Position = Vector3.new(gx - 3, 1.35, gz)
	snowDust.Color = snow
	snowDust.Material = Enum.Material.Snow

	-- Ice pillars (slightly translucent)
	local pillarL = gatePart("PillarL")
	pillarL.Size = Vector3.new(3.2, 12, 3.2)
	pillarL.Position = Vector3.new(gx - 3, 7.2, gz - 4.8)
	pillarL.Color = ice
	pillarL.Material = Enum.Material.Ice
	pillarL.Transparency = 0.15

	local pillarR = gatePart("PillarR")
	pillarR.Size = Vector3.new(3.2, 12, 3.2)
	pillarR.Position = Vector3.new(gx - 3, 7.2, gz + 4.8)
	pillarR.Color = ice
	pillarR.Material = Enum.Material.Ice
	pillarR.Transparency = 0.15

	-- Ice spikes jutting outward from each pillar at several heights. The
	-- spikes are rotated tall narrow wedges with their point facing away
	-- from the gate opening.
	local function spike(name: string, px: number, py: number, pz: number, dir: number, len: number)
		local s = gatePart(name)
		s.Size = Vector3.new(0.6, len, 0.6)
		-- Angle the spike outward along +/- Z depending on direction
		s.CFrame = CFrame.new(px, py, pz) * CFrame.Angles(math.rad(dir * 70), 0, 0)
		s.Color = ice
		s.Material = Enum.Material.Ice
		s.Transparency = 0.1
	end
	-- Left pillar spikes (point away in -Z)
	spike("SpikeL1", gx - 3, 4, gz - 6.8, -1, 5)
	spike("SpikeL2", gx - 3, 8, gz - 7.2, -1, 6)
	spike("SpikeL3", gx - 3, 11, gz - 6.6, -1, 4.5)
	-- Right pillar spikes (+Z)
	spike("SpikeR1", gx - 3, 4, gz + 6.8, 1, 5)
	spike("SpikeR2", gx - 3, 8, gz + 7.2, 1, 6)
	spike("SpikeR3", gx - 3, 11, gz + 6.6, 1, 4.5)

	-- Icy arch connecting the pillars
	local arch = gatePart("Arch")
	arch.Size = Vector3.new(4, 2.4, 11)
	arch.Position = Vector3.new(gx - 3, 14.4, gz)
	arch.Color = iceDark
	arch.Material = Enum.Material.Ice

	-- Hanging icicles from the arch front face
	for i = 1, 7 do
		local icicle = gatePart("Icicle_" .. i)
		local len = 1.2 + ctx.rng:NextNumber() * 2.2
		icicle.Size = Vector3.new(0.45, len, 0.45)
		icicle.Position = Vector3.new(gx - 5.1, 13 - len / 2, gz - 4.5 + (i - 1) * 1.5)
		icicle.Color = ice
		icicle.Material = Enum.Material.Ice
		icicle.Transparency = 0.1
	end

	-- Snow-capped pillar caps
	local capL = gatePart("CapL")
	capL.Size = Vector3.new(4.2, 0.8, 4.2)
	capL.Position = Vector3.new(gx - 3, 15.8, gz - 4.8)
	capL.Color = snow
	capL.Material = Enum.Material.Snow

	local capR = gatePart("CapR")
	capR.Size = Vector3.new(4.2, 0.8, 4.2)
	capR.Position = Vector3.new(gx - 3, 15.8, gz + 4.8)
	capR.Color = snow
	capR.Material = Enum.Material.Snow

	-- Glowing crystal shards on the caps
	local function capCrystal(name: string, px: number, pz: number)
		local c = gatePart(name)
		c.Size = Vector3.new(0.6, 3, 0.6)
		c.Position = Vector3.new(px, 17.7, pz)
		c.Color = crystal
		c.Material = Enum.Material.Neon
		c.Transparency = 0.2
		local light = Instance.new("PointLight")
		light.Color = crystal
		light.Range = 10
		light.Brightness = 1.5
		light.Parent = c
	end
	capCrystal("CrystalL", gx - 3, gz - 4.8)
	capCrystal("CrystalR", gx - 3, gz + 4.8)

	-- Deep cold void opening
	local opening = gatePart("Opening")
	opening.Size = Vector3.new(0.6, 10, 7)
	opening.Position = Vector3.new(gx - 5.4, 6.2, gz)
	opening.Color = voidBlue
	opening.Material = Enum.Material.SmoothPlastic

	-- Frozen ice-slab "planks" instead of wooden drawbridge
	for i = 1, 5 do
		local plank = gatePart("IcePlank" .. i)
		plank.Size = Vector3.new(1.3, 0.35, 8)
		plank.Position = Vector3.new(gx + (i - 1) * 1.4, 1.4, gz)
		plank.Color = if i % 2 == 0 then iceDark else ice
		plank.Material = Enum.Material.Ice
		plank.Transparency = 0.2
	end
end

-- Desert: weathered sandstone arch with dark banded pillars, a weathered
-- cloth banner, and bleached skulls on the caps.
local function buildGateDesert(ctx: ThemeContext, firstWp: Vector3)
	local gate = Instance.new("Folder")
	gate.Name = "EnemyGate"
	gate.Parent = ctx.mapFolder

	local gx = firstWp.X
	local gz = firstWp.Z
	local sand = Color3.fromRGB(214, 175, 106)
	local sandDark = Color3.fromRGB(150, 110, 60)
	local sandMid = Color3.fromRGB(182, 140, 85)
	local bone = Color3.fromRGB(235, 220, 185)
	local darkOpening = Color3.fromRGB(14, 8, 2)
	local banner = Color3.fromRGB(160, 100, 55)

	local function gatePart(name: string): Part
		local p = makePart(gate, name)
		p.CastShadow = true
		return p
	end

	-- Sandstone platform
	local base = gatePart("Base")
	base.Size = Vector3.new(14, 1.2, 12)
	base.Position = Vector3.new(gx - 3, 0.6, gz)
	base.Color = sandDark
	base.Material = Enum.Material.Sandstone

	-- Pillars (taller, squarer than defense — step-pyramid feel)
	local pillarL = gatePart("PillarL")
	pillarL.Size = Vector3.new(4, 12, 4)
	pillarL.Position = Vector3.new(gx - 3, 7.2, gz - 4.8)
	pillarL.Color = sand
	pillarL.Material = Enum.Material.Sandstone

	local pillarR = gatePart("PillarR")
	pillarR.Size = Vector3.new(4, 12, 4)
	pillarR.Position = Vector3.new(gx - 3, 7.2, gz + 4.8)
	pillarR.Color = sand
	pillarR.Material = Enum.Material.Sandstone

	-- Dark hieroglyph-style bands on the pillars
	for i = 0, 2 do
		local y = 4 + i * 4
		local bandL = gatePart("BandL_" .. i)
		bandL.Size = Vector3.new(4.2, 0.8, 4.2)
		bandL.Position = Vector3.new(gx - 3, y, gz - 4.8)
		bandL.Color = sandDark
		bandL.Material = Enum.Material.Sandstone

		local bandR = gatePart("BandR_" .. i)
		bandR.Size = Vector3.new(4.2, 0.8, 4.2)
		bandR.Position = Vector3.new(gx - 3, y, gz + 4.8)
		bandR.Color = sandDark
		bandR.Material = Enum.Material.Sandstone
	end

	-- Curved arch (modeled as a thick slab — curvature faked with the
	-- slight layered look)
	local arch = gatePart("Arch")
	arch.Size = Vector3.new(5, 2.8, 12)
	arch.Position = Vector3.new(gx - 3, 14.6, gz)
	arch.Color = sandMid
	arch.Material = Enum.Material.Sandstone

	local archTop = gatePart("ArchTop")
	archTop.Size = Vector3.new(4, 1.2, 10.5)
	archTop.Position = Vector3.new(gx - 3, 16.6, gz)
	archTop.Color = sand
	archTop.Material = Enum.Material.Sandstone

	-- Pillar caps with skull decorations
	local capL = gatePart("CapL")
	capL.Size = Vector3.new(4.6, 0.8, 4.6)
	capL.Position = Vector3.new(gx - 3, 17.6, gz - 4.8)
	capL.Color = sandDark
	capL.Material = Enum.Material.Sandstone

	local capR = gatePart("CapR")
	capR.Size = Vector3.new(4.6, 0.8, 4.6)
	capR.Position = Vector3.new(gx - 3, 17.6, gz + 4.8)
	capR.Color = sandDark
	capR.Material = Enum.Material.Sandstone

	-- Skulls on top (ball for skull, two cubes for eye sockets)
	local function skull(name: string, px: number, pz: number)
		local s = gatePart(name .. "_Skull")
		s.Shape = Enum.PartType.Ball
		s.Size = Vector3.new(2.2, 2.2, 2.2)
		s.Position = Vector3.new(px, 19.1, pz)
		s.Color = bone
		s.Material = Enum.Material.SmoothPlastic

		local eyeL = gatePart(name .. "_EyeL")
		eyeL.Size = Vector3.new(0.4, 0.6, 0.6)
		eyeL.Position = Vector3.new(px - 1.05, 19.2, pz - 0.55)
		eyeL.Color = Color3.fromRGB(10, 6, 2)
		eyeL.Material = Enum.Material.SmoothPlastic

		local eyeR = gatePart(name .. "_EyeR")
		eyeR.Size = Vector3.new(0.4, 0.6, 0.6)
		eyeR.Position = Vector3.new(px - 1.05, 19.2, pz + 0.55)
		eyeR.Color = Color3.fromRGB(10, 6, 2)
		eyeR.Material = Enum.Material.SmoothPlastic
	end
	skull("L", gx - 3, gz - 4.8)
	skull("R", gx - 3, gz + 4.8)

	-- Dark opening (cavern beyond the arch)
	local opening = gatePart("Opening")
	opening.Size = Vector3.new(0.6, 10, 7)
	opening.Position = Vector3.new(gx - 5.4, 6.2, gz)
	opening.Color = darkOpening
	opening.Material = Enum.Material.SmoothPlastic

	-- Weathered stone-slab path instead of wooden planks
	for i = 1, 5 do
		local slab = gatePart("SandSlab" .. i)
		slab.Size = Vector3.new(1.3, 0.35, 8)
		slab.Position = Vector3.new(gx + (i - 1) * 1.4, 1.4, gz)
		slab.Color = if i % 2 == 0 then sandDark else sandMid
		slab.Material = Enum.Material.Sandstone
	end

	-- Tattered banner hanging from the arch
	local tatter = gatePart("Banner")
	tatter.Size = Vector3.new(0.2, 3.2, 2.6)
	tatter.Position = Vector3.new(gx - 2.4, 12, gz)
	tatter.Color = banner
	tatter.Material = Enum.Material.Fabric
end

-- Forest: overgrown timber arch with twisted trunks, hanging vines, and a
-- canopy of leaves poking out of the top.
local function buildGateForest(ctx: ThemeContext, firstWp: Vector3)
	local gate = Instance.new("Folder")
	gate.Name = "EnemyGate"
	gate.Parent = ctx.mapFolder

	local gx = firstWp.X
	local gz = firstWp.Z
	local bark = Color3.fromRGB(68, 42, 24)
	local barkDark = Color3.fromRGB(42, 26, 14)
	local moss = Color3.fromRGB(52, 105, 48)
	local leaf = Color3.fromRGB(30, 100, 35)
	local leafDark = Color3.fromRGB(18, 66, 22)
	local darkOpening = Color3.fromRGB(4, 14, 6)
	local dirt = Color3.fromRGB(54, 36, 22)

	local function gatePart(name: string): Part
		local p = makePart(gate, name)
		p.CastShadow = true
		return p
	end

	-- Mossy dirt platform
	local base = gatePart("Base")
	base.Size = Vector3.new(14, 1.2, 12)
	base.Position = Vector3.new(gx - 3, 0.6, gz)
	base.Color = dirt
	base.Material = Enum.Material.Ground

	-- Moss patches on the platform
	for i = 1, 4 do
		local patch = gatePart("MossPatch_" .. i)
		patch.Size =
			Vector3.new(2 + ctx.rng:NextNumber() * 1.5, 0.25, 2 + ctx.rng:NextNumber() * 1.5)
		patch.Position =
			Vector3.new(gx - 3 + ctx.rng:NextNumber(-5, 5), 1.35, gz + ctx.rng:NextNumber(-4, 4))
		patch.Color = moss
		patch.Material = Enum.Material.LeafyGrass
	end

	-- Twisted thick trunks as pillars
	local pillarL = gatePart("PillarL")
	pillarL.Shape = Enum.PartType.Cylinder
	pillarL.Size = Vector3.new(13, 3.6, 3.6)
	pillarL.CFrame = CFrame.new(gx - 3, 7.5, gz - 5) * CFrame.Angles(0, 0, math.rad(90))
	pillarL.Color = bark
	pillarL.Material = Enum.Material.Wood

	local pillarR = gatePart("PillarR")
	pillarR.Shape = Enum.PartType.Cylinder
	pillarR.Size = Vector3.new(13, 3.6, 3.6)
	pillarR.CFrame = CFrame.new(gx - 3, 7.5, gz + 5) * CFrame.Angles(0, 0, math.rad(90))
	pillarR.Color = bark
	pillarR.Material = Enum.Material.Wood

	-- Exposed roots at the base
	for i = 1, 4 do
		local root = gatePart("Root_" .. i)
		root.Size = Vector3.new(4 + ctx.rng:NextNumber() * 2, 0.8, 0.8)
		root.CFrame = CFrame.new(gx - 1 + ctx.rng:NextNumber() * 2, 1.4, gz - 6 + (i - 1) * 4)
			* CFrame.Angles(0, ctx.rng:NextNumber() * math.pi * 2, 0)
		root.Color = barkDark
		root.Material = Enum.Material.Wood
	end

	-- Thick wooden crossbeam (arch)
	local arch = gatePart("Arch")
	arch.Shape = Enum.PartType.Cylinder
	arch.Size = Vector3.new(13, 2.6, 2.6)
	arch.CFrame = CFrame.new(gx - 3, 14.5, gz) * CFrame.Angles(math.rad(90), 0, 0)
	arch.Color = barkDark
	arch.Material = Enum.Material.Wood

	-- Leaf canopy clusters on top of each pillar
	local function canopyBall(
		name: string,
		px: number,
		py: number,
		pz: number,
		s: number,
		dark: boolean
	)
		local c = gatePart(name)
		c.Shape = Enum.PartType.Ball
		c.Size = Vector3.new(s, s, s)
		c.Position = Vector3.new(px, py, pz)
		c.Color = if dark then leafDark else leaf
		c.Material = Enum.Material.LeafyGrass
	end
	canopyBall("CanopyL1", gx - 3, 17, gz - 5, 7, false)
	canopyBall("CanopyL2", gx - 5, 18, gz - 5, 5.5, true)
	canopyBall("CanopyL3", gx - 1, 18, gz - 5, 5.5, false)
	canopyBall("CanopyR1", gx - 3, 17, gz + 5, 7, false)
	canopyBall("CanopyR2", gx - 5, 18, gz + 5, 5.5, true)
	canopyBall("CanopyR3", gx - 1, 18, gz + 5, 5.5, false)
	canopyBall("CanopyMid", gx - 3, 18.5, gz, 6.5, true)

	-- Hanging vines (thin dangling cylinders)
	for i = 1, 6 do
		local len = 3 + ctx.rng:NextNumber() * 3
		local vine = gatePart("Vine_" .. i)
		vine.Size = Vector3.new(0.3, len, 0.3)
		vine.Position = Vector3.new(
			gx - 5.2,
			14 - len / 2,
			gz - 5 + (i - 1) * 2 + ctx.rng:NextNumber(-0.4, 0.4)
		)
		vine.Color = moss
		vine.Material = Enum.Material.LeafyGrass
	end

	-- Dark tangled opening
	local opening = gatePart("Opening")
	opening.Size = Vector3.new(0.6, 10, 7)
	opening.Position = Vector3.new(gx - 5.4, 6.2, gz)
	opening.Color = darkOpening
	opening.Material = Enum.Material.SmoothPlastic

	-- Wooden plank drawbridge (rough logs)
	for i = 1, 5 do
		local plank = gatePart("Log" .. i)
		plank.Size = Vector3.new(1.3, 0.4, 8)
		plank.Position = Vector3.new(gx + (i - 1) * 1.4, 1.4, gz)
		plank.Color = if i % 2 == 0 then barkDark else bark
		plank.Material = Enum.Material.Wood
	end
end

-- Space: dark metal gate with neon energy strips, glowing rings on the
-- pillars, and a shimmering purple energy opening.
local function buildGateSpace(ctx: ThemeContext, firstWp: Vector3)
	local gate = Instance.new("Folder")
	gate.Name = "EnemyGate"
	gate.Parent = ctx.mapFolder

	local gx = firstWp.X
	local gz = firstWp.Z
	local metal = Color3.fromRGB(48, 52, 68)
	local metalDark = Color3.fromRGB(22, 26, 38)
	local neon = Color3.fromRGB(180, 90, 240)
	local neonBlue = Color3.fromRGB(90, 180, 255)
	local voidDark = Color3.fromRGB(6, 4, 16)

	local function gatePart(name: string): Part
		local p = makePart(gate, name)
		p.CastShadow = true
		return p
	end

	-- Metal landing pad with glowing neon edge
	local base = gatePart("Base")
	base.Size = Vector3.new(14, 1.2, 12)
	base.Position = Vector3.new(gx - 3, 0.6, gz)
	base.Color = metalDark
	base.Material = Enum.Material.DiamondPlate

	local edge = gatePart("BaseEdge")
	edge.Size = Vector3.new(14.6, 0.3, 12.6)
	edge.Position = Vector3.new(gx - 3, 1.35, gz)
	edge.Color = neon
	edge.Material = Enum.Material.Neon
	edge.Transparency = 0.15

	-- Dark metal pillars
	local pillarL = gatePart("PillarL")
	pillarL.Size = Vector3.new(2.8, 12, 2.8)
	pillarL.Position = Vector3.new(gx - 3, 7.2, gz - 4.8)
	pillarL.Color = metal
	pillarL.Material = Enum.Material.Metal

	local pillarR = gatePart("PillarR")
	pillarR.Size = Vector3.new(2.8, 12, 2.8)
	pillarR.Position = Vector3.new(gx - 3, 7.2, gz + 4.8)
	pillarR.Color = metal
	pillarR.Material = Enum.Material.Metal

	-- Glowing neon rings stacked on the pillars
	local function ring(name: string, px: number, py: number, pz: number, color: Color3)
		local r = gatePart(name)
		r.Shape = Enum.PartType.Cylinder
		r.Size = Vector3.new(0.5, 3.4, 3.4)
		r.CFrame = CFrame.new(px, py, pz) * CFrame.Angles(0, 0, math.rad(90))
		r.Color = color
		r.Material = Enum.Material.Neon
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = 8
		light.Brightness = 1.5
		light.Parent = r
	end
	ring("RingL1", gx - 3, 4, gz - 4.8, neonBlue)
	ring("RingL2", gx - 3, 8, gz - 4.8, neon)
	ring("RingL3", gx - 3, 12, gz - 4.8, neonBlue)
	ring("RingR1", gx - 3, 4, gz + 4.8, neonBlue)
	ring("RingR2", gx - 3, 8, gz + 4.8, neon)
	ring("RingR3", gx - 3, 12, gz + 4.8, neonBlue)

	-- Heavy metal crossbeam with a neon energy strip along the front
	local arch = gatePart("Arch")
	arch.Size = Vector3.new(4, 2.4, 11)
	arch.Position = Vector3.new(gx - 3, 14.4, gz)
	arch.Color = metalDark
	arch.Material = Enum.Material.DiamondPlate

	local archStrip = gatePart("ArchStrip")
	archStrip.Size = Vector3.new(0.3, 0.6, 10.4)
	archStrip.Position = Vector3.new(gx - 5.1, 14.4, gz)
	archStrip.Color = neon
	archStrip.Material = Enum.Material.Neon

	-- Glowing orb caps
	local function orbCap(name: string, px: number, pz: number)
		local o = gatePart(name)
		o.Shape = Enum.PartType.Ball
		o.Size = Vector3.new(2.4, 2.4, 2.4)
		o.Position = Vector3.new(px, 16.5, pz)
		o.Color = neon
		o.Material = Enum.Material.Neon
		local light = Instance.new("PointLight")
		light.Color = neon
		light.Range = 12
		light.Brightness = 2
		light.Parent = o
	end
	orbCap("OrbL", gx - 3, gz - 4.8)
	orbCap("OrbR", gx - 3, gz + 4.8)

	-- Shimmering purple energy field instead of a dark opening
	local shimmer = gatePart("Opening")
	shimmer.Size = Vector3.new(0.4, 10, 7)
	shimmer.Position = Vector3.new(gx - 5.3, 6.2, gz)
	shimmer.Color = neon
	shimmer.Material = Enum.Material.ForceField
	shimmer.Transparency = 0.3

	local openingDark = gatePart("OpeningBack")
	openingDark.Size = Vector3.new(0.3, 10, 7)
	openingDark.Position = Vector3.new(gx - 5.6, 6.2, gz)
	openingDark.Color = voidDark
	openingDark.Material = Enum.Material.SmoothPlastic

	-- Grated metal walkway instead of wooden planks
	for i = 1, 5 do
		local plate = gatePart("Plate" .. i)
		plate.Size = Vector3.new(1.3, 0.35, 8)
		plate.Position = Vector3.new(gx + (i - 1) * 1.4, 1.4, gz)
		plate.Color = if i % 2 == 0 then metalDark else metal
		plate.Material = Enum.Material.DiamondPlate
	end

	-- Neon strips between the plates
	for i = 1, 4 do
		local strip = gatePart("Strip" .. i)
		strip.Size = Vector3.new(0.1, 0.25, 7.8)
		strip.Position = Vector3.new(gx + (i - 0.5) * 1.4 - 0.7, 1.5, gz)
		strip.Color = neonBlue
		strip.Material = Enum.Material.Neon
	end
end

-- ============================================================================
-- Surrounds
-- ============================================================================

-- Defense: original behavior — scattered vegetation + dense tree ring +
-- wedge ridge rocks + stepped mountain range. Extracted verbatim from
-- Map.luau so Realm Defense stays identical.
local function buildSurroundDefense(ctx: ThemeContext)
	local palette = ctx.palette
	local rng = ctx.rng
	local arenaHalf = ctx.arenaHalf
	local groundHalf = ctx.groundHalf
	-- Mid-zone extends from just outside the grid border (grid half = 64
	-- studs + 6 padding) to 30 studs shy of the arena edge. These are the
	-- same bounds the original Map.luau used before the MapThemes refactor.
	local innerEdge = 64 + 6
	local ringInnerEdge = arenaHalf - 30
	local outerEdge = arenaHalf - 8

	local vegetation = Instance.new("Folder")
	vegetation.Name = "Vegetation"
	vegetation.Parent = ctx.mapFolder

	local BUSH_COLORS = palette.canopy
	local ROCK_COLORS = { palette.rock, palette.rockDark, palette.wallDark }

	-- Scattered trees in the mid-zone
	for i = 1, 70 do
		local tx, tz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local scale = 0.85 + rng:NextNumber() * 0.7
		spawnTree(ctx, vegetation, i, tx, tz, scale)
	end

	-- Bushes
	for i = 1, 50 do
		local bx, bz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local s = 1.5 + rng:NextNumber() * 1.3
		local bush = makePart(vegetation, "Bush_" .. i)
		bush.Shape = Enum.PartType.Ball
		bush.Size = Vector3.new(s * 1.5, s, s * 1.5)
		bush.Position = Vector3.new(bx, s * 0.4, bz)
		bush.Color = BUSH_COLORS[rng:NextInteger(1, #BUSH_COLORS)]
		bush.Material = palette.canopyMaterial
	end

	-- Rocks
	for i = 1, 35 do
		local rx, rz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local sx = 1.4 + rng:NextNumber() * 2
		local sy = 0.8 + rng:NextNumber() * 1.2
		local sz = 1.4 + rng:NextNumber() * 2
		local rock = makePart(vegetation, "Rock_" .. i)
		rock.Size = Vector3.new(sx, sy, sz)
		rock.CFrame = CFrame.new(rx, sy * 0.5, rz)
			* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
		rock.Color = ROCK_COLORS[rng:NextInteger(1, #ROCK_COLORS)]
		rock.Material = palette.rockMaterial
	end

	-- Dense outer tree ring
	for i = 1, 240 do
		local tx, tz = randomRingPoint(ctx, ringInnerEdge, outerEdge)
		local scale = 1.4 + rng:NextNumber() * 0.9
		spawnTree(ctx, vegetation, 1000 + i, tx, tz, scale)
	end

	-- Jagged ridge rocks
	local ridges = Instance.new("Folder")
	ridges.Name = "Ridges"
	ridges.Parent = ctx.mapFolder

	local ridgeInnerR = arenaHalf - 8
	local ridgeOuterR = arenaHalf + 92
	local RIDGE_COLORS = palette.ridge

	for i = 1, 700 do
		local rx, rz, t = randomRidgePoint(ctx, ridgeInnerR, ridgeOuterR)
		local heightBase = 6 + t * 85
		local heightJitter = rng:NextNumber() * 55
		local height = heightBase + heightJitter
		local width = 6 + rng:NextNumber() * 14
		local depth = 6 + rng:NextNumber() * 14
		local yaw = rng:NextNumber() * math.pi * 2
		local tiltX = (rng:NextNumber() - 0.5) * 0.35
		local tiltZ = (rng:NextNumber() - 0.5) * 0.35
		local wedge = makeWedge(ridges, "Ridge_" .. i)
		wedge.Size = Vector3.new(width, height, depth)
		wedge.CFrame = CFrame.new(rx, height / 2 - 2, rz) * CFrame.Angles(tiltX, yaw, tiltZ)
		wedge.Color = RIDGE_COLORS[rng:NextInteger(1, #RIDGE_COLORS)]
		wedge.Material = palette.rockMaterial
	end

	for i = 1, 300 do
		local rx, rz, t = randomRidgePoint(ctx, ridgeInnerR, ridgeOuterR)
		local heightBase = 10 + t * 60
		local heightJitter = rng:NextNumber() * 40
		local height = heightBase + heightJitter
		local width = 6 + rng:NextNumber() * 14
		local depth = 6 + rng:NextNumber() * 14
		local yaw = rng:NextNumber() * math.pi * 2
		local wedge = makeWedge(ridges, "RidgeFlip_" .. i)
		wedge.Size = Vector3.new(width, height, depth)
		wedge.CFrame = CFrame.new(rx, height / 2 - 2, rz)
			* CFrame.Angles(math.pi, 0, 0)
			* CFrame.Angles(0, yaw, 0)
		wedge.Color = RIDGE_COLORS[rng:NextInteger(1, #RIDGE_COLORS)]
		wedge.Material = palette.rockMaterial
	end

	-- Mountain range
	local mountains = Instance.new("Folder")
	mountains.Name = "Mountains"
	mountains.Parent = ctx.mapFolder

	local mountainInnerEdge = arenaHalf + 110
	local mountainOuterEdge = groundHalf - 25
	for i = 1, 48 do
		local mx, mz = randomMountainPoint(ctx, mountainInnerEdge, mountainOuterEdge)
		buildMountain(ctx, mountains, i, mx, mz)
	end
end

-- Frost: replace ridge wedge rocks with tall ice spikes and scatter
-- glacier slabs in the mid-zone. Mountains become icy peaks via the
-- palette already set on RealmDefs.
local function buildSurroundFrost(ctx: ThemeContext)
	local palette = ctx.palette
	local rng = ctx.rng
	local arenaHalf = ctx.arenaHalf
	local groundHalf = ctx.groundHalf
	local innerEdge = 64 + 6
	local ringInnerEdge = arenaHalf - 30
	local outerEdge = arenaHalf - 8

	local vegetation = Instance.new("Folder")
	vegetation.Name = "Vegetation"
	vegetation.Parent = ctx.mapFolder

	-- Frosty conifers in the mid-zone (sparse — the arena reads as open
	-- tundra, not a forest).
	for i = 1, 35 do
		local tx, tz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local scale = 0.9 + rng:NextNumber() * 0.6
		spawnTree(ctx, vegetation, i, tx, tz, scale)
	end

	-- Glacier slabs (low rectangular ice chunks, tilted slightly)
	for i = 1, 45 do
		local bx, bz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local sx = 3 + rng:NextNumber() * 4
		local sy = 1 + rng:NextNumber() * 1.6
		local sz = 3 + rng:NextNumber() * 4
		local slab = makePart(vegetation, "GlacierSlab_" .. i)
		slab.Size = Vector3.new(sx, sy, sz)
		slab.CFrame = CFrame.new(bx, sy * 0.45, bz)
			* CFrame.Angles(
				(rng:NextNumber() - 0.5) * 0.2,
				rng:NextNumber() * math.pi * 2,
				(rng:NextNumber() - 0.5) * 0.2
			)
		slab.Color = palette.rock
		slab.Material = Enum.Material.Ice
		slab.Transparency = 0.15
	end

	-- Small ice crystals scattered in the mid-zone
	for i = 1, 30 do
		local cx, cz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local crystal = makePart(vegetation, "Crystal_" .. i)
		crystal.Size = Vector3.new(0.6, 2 + rng:NextNumber() * 2, 0.6)
		crystal.CFrame = CFrame.new(cx, 1.2, cz)
			* CFrame.Angles(
				(rng:NextNumber() - 0.5) * 0.4,
				rng:NextNumber() * math.pi * 2,
				(rng:NextNumber() - 0.5) * 0.4
			)
		crystal.Color = Color3.fromRGB(150, 220, 250)
		crystal.Material = Enum.Material.Glass
		crystal.Transparency = 0.2
	end

	-- Sparser outer frozen tree ring (half density of defense)
	for i = 1, 110 do
		local tx, tz = randomRingPoint(ctx, ringInnerEdge, outerEdge)
		local scale = 1.3 + rng:NextNumber() * 0.8
		spawnTree(ctx, vegetation, 1000 + i, tx, tz, scale)
	end

	-- --- Ice spike field replacing the ridge rocks ---
	-- Tall narrow ice pillars rotated slightly, in the same band where
	-- defense puts wedge rocks. Uses block primitives sized long-and-thin
	-- so the field reads as a crystalline glacier forest.
	local ridges = Instance.new("Folder")
	ridges.Name = "IceSpikes"
	ridges.Parent = ctx.mapFolder

	local ridgeInnerR = arenaHalf - 8
	local ridgeOuterR = arenaHalf + 92
	for i = 1, 900 do
		local rx, rz, t = randomRidgePoint(ctx, ridgeInnerR, ridgeOuterR)
		local heightBase = 8 + t * 95
		local heightJitter = rng:NextNumber() * 45
		local height = heightBase + heightJitter
		local thick = 1.2 + rng:NextNumber() * 3.5
		local tiltX = (rng:NextNumber() - 0.5) * 0.25
		local tiltZ = (rng:NextNumber() - 0.5) * 0.25
		local yaw = rng:NextNumber() * math.pi * 2
		local spike = makePart(ridges, "Spike_" .. i)
		spike.Size = Vector3.new(thick, height, thick)
		spike.CFrame = CFrame.new(rx, height / 2 - 2, rz) * CFrame.Angles(tiltX, yaw, tiltZ)
		spike.Color = palette.rock
		spike.Material = Enum.Material.Ice
		spike.Transparency = 0.1
	end

	-- Wider glacier slabs between the spikes for variety
	for i = 1, 200 do
		local rx, rz, t = randomRidgePoint(ctx, ridgeInnerR, ridgeOuterR)
		local width = 10 + rng:NextNumber() * 18
		local depth = 10 + rng:NextNumber() * 18
		local height = 6 + t * 18 + rng:NextNumber() * 6
		local yaw = rng:NextNumber() * math.pi * 2
		local slab = makePart(ridges, "Glacier_" .. i)
		slab.Size = Vector3.new(width, height, depth)
		slab.CFrame = CFrame.new(rx, height / 2 - 2, rz)
			* CFrame.Angles((rng:NextNumber() - 0.5) * 0.15, yaw, (rng:NextNumber() - 0.5) * 0.15)
		slab.Color = palette.rockDark
		slab.Material = Enum.Material.Ice
		slab.Transparency = 0.2
	end

	-- --- Icy mountain range (stepped peaks using the palette) ---
	local mountains = Instance.new("Folder")
	mountains.Name = "Mountains"
	mountains.Parent = ctx.mapFolder

	local mountainInnerEdge = arenaHalf + 110
	local mountainOuterEdge = groundHalf - 25
	for i = 1, 48 do
		local mx, mz = randomMountainPoint(ctx, mountainInnerEdge, mountainOuterEdge)
		buildMountain(ctx, mountains, i, mx, mz)
	end
end

-- Desert: flatten the horizon. Replace ridges and mountains with low
-- rolling dunes (wide flat ellipsoids) so the player can see past them
-- to the end of the world. Mid-zone gets sparse cacti and bleached bones
-- instead of trees.
local function buildSurroundDesert(ctx: ThemeContext)
	local palette = ctx.palette
	local rng = ctx.rng
	local arenaHalf = ctx.arenaHalf
	local groundHalf = ctx.groundHalf
	local innerEdge = 64 + 6
	local ringInnerEdge = arenaHalf - 30

	local vegetation = Instance.new("Folder")
	vegetation.Name = "Vegetation"
	vegetation.Parent = ctx.mapFolder

	local cactusGreen = Color3.fromRGB(75, 125, 60)
	local cactusDark = Color3.fromRGB(55, 95, 45)
	local bone = Color3.fromRGB(235, 220, 185)

	-- Cacti — tall narrow green cylinders with little arms
	for i = 1, 22 do
		local cx, cz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local h = 5 + rng:NextNumber() * 4
		local trunk = makePart(vegetation, "CactusTrunk_" .. i)
		trunk.Shape = Enum.PartType.Cylinder
		trunk.Size = Vector3.new(h, 1.2, 1.2)
		trunk.CFrame = CFrame.new(cx, h / 2, cz) * CFrame.Angles(0, 0, math.rad(90))
		trunk.Color = if rng:NextNumber() > 0.5 then cactusGreen else cactusDark
		trunk.Material = Enum.Material.Grass

		-- Maybe add a side arm
		if rng:NextNumber() > 0.4 then
			local armLen = 2 + rng:NextNumber() * 1.2
			local arm = makePart(vegetation, "CactusArm_" .. i)
			arm.Shape = Enum.PartType.Cylinder
			arm.Size = Vector3.new(armLen, 0.9, 0.9)
			local yaw = rng:NextNumber() * math.pi * 2
			arm.CFrame = CFrame.new(cx + math.cos(yaw) * 1.2, h * 0.65, cz + math.sin(yaw) * 1.2)
				* CFrame.Angles(0, yaw, 0)
			arm.Color = cactusGreen
			arm.Material = Enum.Material.Grass
		end
	end

	-- Bleached bones / skulls lying in the sand
	for i = 1, 14 do
		local bx, bz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		if rng:NextNumber() > 0.5 then
			-- Skull
			local skull = makePart(vegetation, "Skull_" .. i)
			skull.Shape = Enum.PartType.Ball
			skull.Size = Vector3.new(1.5, 1.5, 1.5)
			skull.Position = Vector3.new(bx, 0.75, bz)
			skull.Color = bone
			skull.Material = Enum.Material.SmoothPlastic
		else
			-- Ribcage (several thin arcs)
			for j = 1, 4 do
				local rib = makePart(vegetation, "Rib_" .. i .. "_" .. j)
				rib.Size = Vector3.new(0.25, 1.8, 0.25)
				rib.CFrame = CFrame.new(bx + (j - 2) * 0.55, 0.9, bz)
					* CFrame.Angles(math.rad(10), 0, math.rad(15))
				rib.Color = bone
				rib.Material = Enum.Material.SmoothPlastic
			end
		end
	end

	-- Small stone outcrops scattered in the sand
	for i = 1, 30 do
		local rx, rz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local sx = 1.5 + rng:NextNumber() * 2.5
		local sy = 0.6 + rng:NextNumber() * 1.2
		local sz = 1.5 + rng:NextNumber() * 2.5
		local rock = makePart(vegetation, "DesertRock_" .. i)
		rock.Size = Vector3.new(sx, sy, sz)
		rock.CFrame = CFrame.new(rx, sy * 0.5, rz)
			* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
		rock.Color = palette.rockDark
		rock.Material = Enum.Material.Sandstone
	end

	-- No dense outer tree ring for desert — leave the horizon open.

	-- --- Low rolling dunes replacing the ridges and mountains ---
	-- Dunes are wide flattened ellipsoids that sit low enough to see over
	-- (max height ~12 studs, well under the 70-stud invisible wall). They
	-- sprawl from the arena edge all the way to the ground edge in one
	-- continuous band so there's no tall blocker ruining the horizon.
	local dunes = Instance.new("Folder")
	dunes.Name = "Dunes"
	dunes.Parent = ctx.mapFolder

	local duneInner = arenaHalf - 8
	local duneOuter = groundHalf - 20
	local duneDepth = duneOuter - duneInner

	-- A helper specific to the dune band (wider than randomRidgePoint's
	-- arena+70 band so dunes cover the entire outer ground).
	local function randomDunePoint(): (number, number, number)
		local side = rng:NextInteger(1, 4)
		local along = rng:NextNumber(-(groundHalf - 15), groundHalf - 15)
		local t = rng:NextNumber()
		local perp = duneInner + t * duneDepth
		if side == 1 then
			return along, -perp, t
		elseif side == 2 then
			return along, perp, t
		elseif side == 3 then
			return -perp, along, t
		else
			return perp, along, t
		end
	end

	for i = 1, 500 do
		local dx, dz, t = randomDunePoint()
		-- Height grows gently with distance but never tall enough to wall
		-- off the view.
		local dh = 2 + t * 8 + rng:NextNumber() * 2.5 -- range 2-12
		local dw = 14 + rng:NextNumber() * 28
		local ddp = 14 + rng:NextNumber() * 28
		local yaw = rng:NextNumber() * math.pi * 2
		local dune = makePart(dunes, "Dune_" .. i)
		dune.Shape = Enum.PartType.Ball
		dune.Size = Vector3.new(dw, dh, ddp)
		dune.CFrame = CFrame.new(dx, dh * 0.3 - 0.5, dz) * CFrame.Angles(0, yaw, 0)
		dune.Color = if rng:NextNumber() > 0.6 then palette.mountainMid else palette.grass
		dune.Material = Enum.Material.Sand
	end

	-- A few slightly taller sandstone mesas dotted far away for silhouette
	-- variety (still below the horizon ceiling).
	for i = 1, 12 do
		local mx, mz, _t = randomDunePoint()
		local h = 8 + rng:NextNumber() * 6 -- 8-14
		local w = 20 + rng:NextNumber() * 18
		local d = 20 + rng:NextNumber() * 18
		local mesa = makePart(dunes, "Mesa_" .. i)
		mesa.Size = Vector3.new(w, h, d)
		mesa.CFrame = CFrame.new(mx, h / 2 - 1, mz)
			* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
		mesa.Color = palette.mountainBase
		mesa.Material = Enum.Material.Sandstone
	end
end

-- Forest: replace the entire outer zone with a wall of tall dense trees
-- so the player can't see past the edge of the arena. No ridges, no
-- mountains — just layers of increasingly large trees.
local function buildSurroundForest(ctx: ThemeContext)
	local palette = ctx.palette
	local rng = ctx.rng
	local arenaHalf = ctx.arenaHalf
	local groundHalf = ctx.groundHalf
	local innerEdge = 64 + 6
	local ringInnerEdge = arenaHalf - 30
	local outerEdge = arenaHalf - 8

	local vegetation = Instance.new("Folder")
	vegetation.Name = "Vegetation"
	vegetation.Parent = ctx.mapFolder

	local BUSH_COLORS = palette.canopy

	-- Dense mid-zone trees
	for i = 1, 110 do
		local tx, tz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local scale = 0.9 + rng:NextNumber() * 0.9
		spawnTree(ctx, vegetation, i, tx, tz, scale)
	end

	-- Undergrowth bushes and small rocks
	for i = 1, 80 do
		local bx, bz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local s = 1.6 + rng:NextNumber() * 1.4
		local bush = makePart(vegetation, "Bush_" .. i)
		bush.Shape = Enum.PartType.Ball
		bush.Size = Vector3.new(s * 1.6, s, s * 1.6)
		bush.Position = Vector3.new(bx, s * 0.4, bz)
		bush.Color = BUSH_COLORS[rng:NextInteger(1, #BUSH_COLORS)]
		bush.Material = palette.canopyMaterial
	end

	for i = 1, 30 do
		local rx, rz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local sx = 1.4 + rng:NextNumber() * 1.8
		local sy = 0.6 + rng:NextNumber() * 1
		local sz = 1.4 + rng:NextNumber() * 1.8
		local rock = makePart(vegetation, "MossyRock_" .. i)
		rock.Size = Vector3.new(sx, sy, sz)
		rock.CFrame = CFrame.new(rx, sy * 0.5, rz)
			* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
		rock.Color = palette.rock
		rock.Material = palette.rockMaterial
	end

	-- --- Solid wall of towering trees ---
	-- Builds a denser, taller tree than the standard palette-driven one
	-- so the wall reads as a blocking forest rather than scattered trees.
	local function spawnGiantTree(parent: Instance, i: number, x: number, z: number, scale: number)
		local trunk = makePart(parent, "GiantTrunk_" .. i)
		trunk.Size = Vector3.new(2 * scale, 18 * scale, 2 * scale)
		trunk.Position = Vector3.new(x, 9 * scale, z)
		trunk.Color = palette.trunk
		trunk.Material = Enum.Material.Wood

		-- Stacked canopy balls so the tree has silhouette depth.
		for j = 1, 3 do
			local csize = (9 - j * 1.2) * scale
			local canopy = makePart(parent, "GiantCanopy_" .. i .. "_" .. j)
			canopy.Shape = Enum.PartType.Ball
			canopy.Size = Vector3.new(csize, csize, csize)
			canopy.Position = Vector3.new(
				x + (rng:NextNumber() - 0.5) * 2,
				(16 + j * 3) * scale,
				z + (rng:NextNumber() - 0.5) * 2
			)
			canopy.Color = palette.canopy[rng:NextInteger(1, #palette.canopy)]
			canopy.Material = palette.canopyMaterial
		end
	end

	-- Ring 1 — at the arena edge (normal outer tree ring, denser)
	for i = 1, 360 do
		local tx, tz = randomRingPoint(ctx, ringInnerEdge, outerEdge)
		local scale = 1.3 + rng:NextNumber() * 0.8
		spawnTree(ctx, vegetation, 1000 + i, tx, tz, scale)
	end

	-- Ring 2 — just outside the arena (giant trees at the ridge band)
	local wall1 = Instance.new("Folder")
	wall1.Name = "ForestWall1"
	wall1.Parent = ctx.mapFolder

	local ridgeInnerR = arenaHalf - 8
	local ridgeOuterR = arenaHalf + 92
	for i = 1, 500 do
		local tx, tz, _t = randomRidgePoint(ctx, ridgeInnerR, ridgeOuterR)
		local scale = 1.8 + rng:NextNumber() * 1.2
		spawnGiantTree(wall1, i, tx, tz, scale)
	end

	-- Ring 3 — farther out (even bigger trees filling the mountain band)
	local wall2 = Instance.new("Folder")
	wall2.Name = "ForestWall2"
	wall2.Parent = ctx.mapFolder

	local farInner = arenaHalf + 110
	local farOuter = groundHalf - 25
	for i = 1, 320 do
		local mx, mz = randomMountainPoint(ctx, farInner, farOuter)
		local scale = 2.2 + rng:NextNumber() * 1.6
		spawnGiantTree(wall2, i, mx, mz, scale)
	end
end

-- Space: no outer mountains, no tree ring, no ridges. The arena reads
-- as a floating asteroid in the void with distant planets and a few
-- drifting moonrocks. The outer ground is hidden so the player sees the
-- skybox at the edge.
local function buildSurroundSpace(ctx: ThemeContext)
	local palette = ctx.palette
	local rng = ctx.rng
	local arenaHalf = ctx.arenaHalf
	local innerEdge = 64 + 6
	local ringInnerEdge = arenaHalf - 30

	-- Hide the outer ground padding so only the arena shows. The ground
	-- part was sized as arena+mountainPadding in Map.luau; we shrink it
	-- here to just the arena footprint so the map "floats".
	local arenaFootprint = arenaHalf * 2
	ctx.ground.Size = Vector3.new(arenaFootprint, 2, arenaFootprint)
	ctx.ground.Color = Color3.fromRGB(55, 48, 80)
	ctx.ground.Material = Enum.Material.Slate

	-- Crater detail on the ground (overlay bumps so it feels moonlike)
	local craters = Instance.new("Folder")
	craters.Name = "Craters"
	craters.Parent = ctx.mapFolder
	for i = 1, 40 do
		local cx, cz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local s = 1.8 + rng:NextNumber() * 3.5
		local crater = makePart(craters, "Crater_" .. i)
		crater.Shape = Enum.PartType.Cylinder
		crater.Size = Vector3.new(0.4, s, s)
		crater.CFrame = CFrame.new(cx, 0.1, cz) * CFrame.Angles(0, 0, math.rad(90))
		crater.Color = Color3.fromRGB(30, 25, 55)
		crater.Material = Enum.Material.Slate
	end

	-- Moonrocks sparsely scattered on the surface
	for i = 1, 20 do
		local rx, rz = randomMidPoint(ctx, innerEdge, ringInnerEdge)
		local sx = 1.6 + rng:NextNumber() * 2.4
		local sy = 1 + rng:NextNumber() * 1.6
		local sz = 1.6 + rng:NextNumber() * 2.4
		local rock = makePart(craters, "Moonrock_" .. i)
		rock.Shape = Enum.PartType.Ball
		rock.Size = Vector3.new(sx, sy, sz)
		rock.CFrame = CFrame.new(rx, sy * 0.5, rz)
			* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
		rock.Color = palette.rock
		rock.Material = Enum.Material.Slate
	end

	-- Jagged asteroid edge falling away from the arena — WedgeParts
	-- pointing down to sell the "broken rock" look at the map rim.
	local edge = Instance.new("Folder")
	edge.Name = "AsteroidEdge"
	edge.Parent = ctx.mapFolder

	for i = 1, 80 do
		local angle = (i / 80) * math.pi * 2 + rng:NextNumber() * 0.04
		local r = arenaHalf + rng:NextNumber() * 6
		local ex = math.cos(angle) * r
		local ez = math.sin(angle) * r
		local height = 6 + rng:NextNumber() * 14
		local width = 4 + rng:NextNumber() * 5
		local depth = 4 + rng:NextNumber() * 5
		local chunk = makeWedge(edge, "EdgeChunk_" .. i)
		chunk.Size = Vector3.new(width, height, depth)
		chunk.CFrame = CFrame.new(ex, -height / 2 - 1, ez)
			* CFrame.Angles(math.pi, angle + math.rad(90), 0)
		chunk.Color = palette.rockDark
		chunk.Material = Enum.Material.Slate
	end

	-- --- Distant planets floating in the sky ---
	-- Placed far from the arena center and high in the sky so they read
	-- as astral bodies rather than set dressing the player can reach.
	local planets = Instance.new("Folder")
	planets.Name = "Planets"
	planets.Parent = ctx.mapFolder

	type PlanetSpec = {
		name: string,
		color: Color3,
		material: Enum.Material,
		size: number,
		pos: Vector3,
		hasRing: boolean,
		ringColor: Color3?,
		glow: number,
	}

	local PLANETS: { PlanetSpec } = {
		{
			name = "GasGiant",
			color = Color3.fromRGB(210, 155, 85),
			material = Enum.Material.Sand,
			size = 340,
			pos = Vector3.new(-1200, 420, -1100),
			hasRing = true,
			ringColor = Color3.fromRGB(230, 200, 150),
			glow = 0,
		},
		{
			name = "RedPlanet",
			color = Color3.fromRGB(180, 70, 50),
			material = Enum.Material.Slate,
			size = 220,
			pos = Vector3.new(1400, 320, -900),
			hasRing = false,
			ringColor = nil,
			glow = 0,
		},
		{
			name = "IceMoon",
			color = Color3.fromRGB(200, 230, 255),
			material = Enum.Material.Ice,
			size = 140,
			pos = Vector3.new(900, 280, 1300),
			hasRing = false,
			ringColor = nil,
			glow = 0,
		},
		{
			name = "VoidOrb",
			color = Color3.fromRGB(160, 90, 240),
			material = Enum.Material.Neon,
			size = 110,
			pos = Vector3.new(-1100, 240, 1200),
			hasRing = false,
			ringColor = nil,
			glow = 3,
		},
		{
			name = "DistantSun",
			color = Color3.fromRGB(255, 220, 140),
			material = Enum.Material.Neon,
			size = 180,
			pos = Vector3.new(-200, 520, -1600),
			hasRing = false,
			ringColor = nil,
			glow = 5,
		},
	}

	for _, spec in PLANETS do
		local body = makePart(planets, spec.name)
		body.Shape = Enum.PartType.Ball
		body.Size = Vector3.new(spec.size, spec.size, spec.size)
		body.Position = spec.pos
		body.Color = spec.color
		body.Material = spec.material
		body.CastShadow = false
		if spec.glow > 0 then
			local light = Instance.new("PointLight")
			light.Color = spec.color
			light.Range = 60
			light.Brightness = spec.glow
			light.Parent = body
		end

		if spec.hasRing and spec.ringColor then
			local ringDiameter = spec.size * 1.9
			local ring = makePart(planets, spec.name .. "_Ring")
			ring.Shape = Enum.PartType.Cylinder
			ring.Size = Vector3.new(2, ringDiameter, ringDiameter)
			ring.CFrame = CFrame.new(spec.pos)
				* CFrame.Angles(0, math.rad(30), math.rad(20))
				* CFrame.Angles(0, 0, math.rad(90))
			ring.Color = spec.ringColor
			ring.Material = Enum.Material.SmoothPlastic
			ring.Transparency = 0.35
			ring.CastShadow = false
		end
	end

	-- A handful of floating asteroid chunks around the arena rim for
	-- mid-distance parallax.
	local asteroids = Instance.new("Folder")
	asteroids.Name = "Asteroids"
	asteroids.Parent = ctx.mapFolder

	for i = 1, 30 do
		local angle = rng:NextNumber() * math.pi * 2
		local r = arenaHalf + 80 + rng:NextNumber() * 200
		local y = 20 + rng:NextNumber() * 140
		local ax = math.cos(angle) * r
		local az = math.sin(angle) * r
		local s = 3 + rng:NextNumber() * 8
		local asteroid = makePart(asteroids, "Asteroid_" .. i)
		asteroid.Shape = Enum.PartType.Ball
		asteroid.Size = Vector3.new(s, s * (0.7 + rng:NextNumber() * 0.5), s)
		asteroid.CFrame = CFrame.new(ax, y, az)
			* CFrame.Angles(
				rng:NextNumber() * math.pi,
				rng:NextNumber() * math.pi,
				rng:NextNumber() * math.pi
			)
		asteroid.Color = palette.rockDark
		asteroid.Material = Enum.Material.Slate
		asteroid.CastShadow = false
	end
end

-- ============================================================================
-- Dispatch
-- ============================================================================

local GATE_BUILDERS: { [string]: (ThemeContext, Vector3) -> () } = {
	defense = buildGateDefense,
	frost = buildGateFrost,
	desert = buildGateDesert,
	forest = buildGateForest,
	space = buildGateSpace,
}

local SURROUND_BUILDERS: { [string]: (ThemeContext) -> () } = {
	defense = buildSurroundDefense,
	frost = buildSurroundFrost,
	desert = buildSurroundDesert,
	forest = buildSurroundForest,
	space = buildSurroundSpace,
}

function MapThemes.buildGate(realmName: string, ctx: ThemeContext, firstWp: Vector3)
	local fn = GATE_BUILDERS[realmName] or GATE_BUILDERS.defense
	fn(ctx, firstWp)
end

function MapThemes.buildSurround(realmName: string, ctx: ThemeContext)
	local fn = SURROUND_BUILDERS[realmName] or SURROUND_BUILDERS.defense
	fn(ctx)
end

return MapThemes
