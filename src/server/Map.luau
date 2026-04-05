--!strict
-- src/server/Map.luau
-- Builds the realm-agnostic pieces of the arena: ground, grid cells,
-- border walls (with the east wall wrapping the castle), corner watch
-- towers, and the enemy-path waypoints. The themed pieces — the enemy
-- gate (entrance) and the outer surround (trees, ridges, dunes, planets)
-- — are delegated to MapThemes which dispatches per realm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = require(ReplicatedStorage.Shared)
local Config = Shared.Config
local RealmDefs = Shared.RealmDefs
local MapThemes = require(script.Parent.MapThemes)

local Map = {}

export type MapData = {
	folder: Folder,
	cells: Folder,
	waypoints: { Vector3 },
	castleCenter: Vector3,
}

-- Castle geometry (must match Castle.luau)
local CASTLE_OFFSET_X = 15
local CASTLE_HALF_W = 11 -- x half-extent (a bit larger than actual for safety)
local CASTLE_HALF_L = 13 -- z half-extent

local function makePart(parent: Instance, name: string): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function Map.build(realmName: string?): MapData
	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end

	local realm = realmName or "defense"
	local palette = RealmDefs.get(realm).palette

	local COLOR_GROUND = palette.ground
	local COLOR_GRASS = palette.grass
	local COLOR_PATH = palette.path
	local COLOR_WALL = palette.wall
	local COLOR_WALL_DARK = palette.wallDark

	local mapFolder = Instance.new("Folder")
	mapFolder.Name = "Map"
	mapFolder.Parent = workspace

	-- --- Ground platform ---
	-- Two radii:
	--   arenaSize = the playable area (invisible walls are anchored here).
	--   groundSize = the full mainland, extending well past the walls to
	--                host the mountain range that surrounds everything.
	-- The space surround shrinks the ground back down to just the arena
	-- so the map floats against the skybox.
	local arenaPadding = 200
	local arenaSize = Config.GRID_SIZE * Config.CELL_SIZE + arenaPadding
	local arenaHalf = arenaSize / 2

	local mountainPadding = 400
	local groundSize = arenaSize + mountainPadding
	local ground = makePart(mapFolder, "Ground")
	ground.Size = Vector3.new(groundSize, 2, groundSize)
	ground.Position = Vector3.new(0, -1, 0)
	ground.Color = COLOR_GROUND
	ground.Material = palette.groundMaterial

	-- --- Grid cells ---
	local cells = Instance.new("Folder")
	cells.Name = "Cells"
	cells.Parent = mapFolder

	for gx = 0, Config.GRID_SIZE - 1 do
		for gy = 0, Config.GRID_SIZE - 1 do
			local pos = Config.gridToWorld(gx, gy)
			local cell = makePart(cells, string.format("Cell_%d_%d", gx, gy))
			cell.Size = Vector3.new(Config.CELL_SIZE - 0.2, 0.3, Config.CELL_SIZE - 0.2)
			cell.Position = Vector3.new(pos.X, 0.15, pos.Z)
			cell.CanCollide = false

			local isPath = Config.isPath(gx, gy)
			if isPath then
				cell.Color = COLOR_PATH
				cell.Material = palette.pathMaterial
			else
				cell.Color = COLOR_GRASS
				cell.Material = palette.grassMaterial
			end

			cell:SetAttribute("gx", gx)
			cell:SetAttribute("gy", gy)
			cell:SetAttribute("isPath", isPath)
		end
	end

	-- --- Path waypoints + castle center (derived before walls) ---
	local waypoints: { Vector3 } = {}
	for i, coord in Config.PATH do
		local pos = Config.gridToWorld(coord[1], coord[2])
		waypoints[i] = Vector3.new(pos.X, 2, pos.Z)
	end
	local firstWp = waypoints[1]
	local finalWp = waypoints[#waypoints]
	local castleCenter = Vector3.new(finalWp.X + CASTLE_OFFSET_X, 0, finalWp.Z)

	-- --- Invisible containment walls at the arena edges ---
	-- Anchored to the arena size (not the full ground) so the player is
	-- contained to the play area even though the ground extends further
	-- out for the mountains.
	local invis = Instance.new("Folder")
	invis.Name = "InvisibleWalls"
	invis.Parent = mapFolder

	local groundHalf = groundSize / 2
	local invHeight = 80
	local function makeInvisibleWall(name: string, size: Vector3, pos: Vector3)
		local w = makePart(invis, name)
		w.Size = size
		w.Position = pos
		w.Transparency = 1
		w.CanCollide = true
		w.CanTouch = false
		w.CanQuery = false
		w.CastShadow = false
	end
	makeInvisibleWall(
		"InvN",
		Vector3.new(arenaSize, invHeight, 2),
		Vector3.new(0, invHeight / 2, -arenaHalf)
	)
	makeInvisibleWall(
		"InvS",
		Vector3.new(arenaSize, invHeight, 2),
		Vector3.new(0, invHeight / 2, arenaHalf)
	)
	makeInvisibleWall(
		"InvE",
		Vector3.new(2, invHeight, arenaSize),
		Vector3.new(arenaHalf, invHeight / 2, 0)
	)
	makeInvisibleWall(
		"InvW",
		Vector3.new(2, invHeight, arenaSize),
		Vector3.new(-arenaHalf, invHeight / 2, 0)
	)

	-- --- Border stone walls ---
	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	walls.Parent = mapFolder

	local wallHeight = 4
	local wallThickness = 2
	local wallOuterLength = Config.GRID_SIZE * Config.CELL_SIZE + wallThickness * 2
	local halfGrid = Config.HALF_GRID

	local function makeWall(name: string, x: number, z: number, sx: number, sz: number)
		local wall = makePart(walls, name)
		wall.Size = Vector3.new(sx, wallHeight, sz)
		wall.Position = Vector3.new(x, wallHeight / 2, z)
		wall.Color = COLOR_WALL
		wall.Material = Enum.Material.Brick
	end

	makeWall("WallN", 0, -halfGrid - wallThickness / 2, wallOuterLength, wallThickness)
	makeWall("WallS", 0, halfGrid + wallThickness / 2, wallOuterLength, wallThickness)
	makeWall("WallW", -halfGrid - wallThickness / 2, 0, wallThickness, wallOuterLength)

	-- The east wall wraps around the castle. Split it into two segments
	-- skipping the castle's z range, then add three wrap walls.
	local castleEastX = castleCenter.X + CASTLE_HALF_W + wallThickness / 2
	local castleNorthZ = castleCenter.Z - CASTLE_HALF_L -- smaller z
	local castleSouthZ = castleCenter.Z + CASTLE_HALF_L -- larger z

	local wallEastX = halfGrid + wallThickness / 2
	local outerNorthZ = -halfGrid - wallThickness
	local outerSouthZ = halfGrid + wallThickness

	do
		local length = castleNorthZ - outerNorthZ
		local centerZ = (outerNorthZ + castleNorthZ) / 2
		makeWall("WallE_N", wallEastX, centerZ, wallThickness, length)
	end

	do
		local length = outerSouthZ - castleSouthZ
		local centerZ = (castleSouthZ + outerSouthZ) / 2
		makeWall("WallE_S", wallEastX, centerZ, wallThickness, length)
	end

	do
		local length = castleEastX - wallEastX
		local centerX = (wallEastX + castleEastX) / 2
		makeWall("WrapN", centerX, castleNorthZ, length, wallThickness)
	end
	do
		local length = castleEastX - wallEastX
		local centerX = (wallEastX + castleEastX) / 2
		makeWall("WrapS", centerX, castleSouthZ, length, wallThickness)
	end
	do
		local length = castleSouthZ - castleNorthZ + wallThickness
		makeWall("WrapE", castleEastX, castleCenter.Z, wallThickness, length)
	end

	-- Corner watch towers (4 at the original grid corners, plus 2 at the castle wrap corners)
	local corners = Instance.new("Folder")
	corners.Name = "Corners"
	corners.Parent = mapFolder

	local function makeCornerTower(cx: number, cz: number)
		local base = makePart(corners, "CornerBase")
		base.Size = Vector3.new(4, 7, 4)
		base.Position = Vector3.new(cx, 3.5, cz)
		base.Color = COLOR_WALL_DARK
		base.Material = Enum.Material.Brick

		local cap = makePart(corners, "CornerCap")
		cap.Size = Vector3.new(4.6, 0.4, 4.6)
		cap.Position = Vector3.new(cx, 7.2, cz)
		cap.Color = COLOR_WALL
		cap.Material = Enum.Material.Brick
	end

	for _, signs in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
		makeCornerTower(
			signs[1] * (halfGrid + wallThickness / 2),
			signs[2] * (halfGrid + wallThickness / 2)
		)
	end
	makeCornerTower(castleEastX, castleNorthZ)
	makeCornerTower(castleEastX, castleSouthZ)

	-- --- Themed pieces (gate + outer surround) ---
	local themeCtx: MapThemes.ThemeContext = {
		mapFolder = mapFolder,
		palette = palette,
		arenaHalf = arenaHalf,
		groundHalf = groundHalf,
		rng = Random.new(20260404),
		castleCenter = castleCenter,
		castleHalfW = CASTLE_HALF_W,
		castleHalfL = CASTLE_HALF_L,
		ground = ground,
	}

	MapThemes.buildGate(realm, themeCtx, firstWp)
	MapThemes.buildSurround(realm, themeCtx)

	return {
		folder = mapFolder,
		cells = cells,
		waypoints = waypoints,
		castleCenter = castleCenter,
	}
end

return Map
