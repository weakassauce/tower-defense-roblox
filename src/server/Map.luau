--!strict
-- src/server/Map.luau
-- Builds the physical map: ground, grid cells, border walls that wrap
-- around the castle on the east side, vegetation, a dense outer tree
-- ring, and the enemy-path waypoints. Returns the castle position so
-- the server script can build the castle model at the right place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = require(ReplicatedStorage.Shared)
local Config = Shared.Config

local Map = {}

export type MapData = {
	folder: Folder,
	cells: Folder,
	waypoints: { Vector3 },
	castleCenter: Vector3,
}

-- Colors
local COLOR_GROUND = Color3.fromRGB(46, 85, 34)
local COLOR_GRASS = Color3.fromRGB(67, 160, 71)
local COLOR_PATH = Color3.fromRGB(141, 110, 99)
local COLOR_WALL = Color3.fromRGB(97, 97, 97)
local COLOR_WALL_DARK = Color3.fromRGB(66, 66, 66)

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

function Map.build(): MapData
	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end

	local mapFolder = Instance.new("Folder")
	mapFolder.Name = "Map"
	mapFolder.Parent = workspace

	-- --- Ground platform (big enough to host the castle + dense tree ring) ---
	local padding = 200
	local groundSize = Config.GRID_SIZE * Config.CELL_SIZE + padding
	local ground = makePart(mapFolder, "Ground")
	ground.Size = Vector3.new(groundSize, 2, groundSize)
	ground.Position = Vector3.new(0, -1, 0)
	ground.Color = COLOR_GROUND
	ground.Material = Enum.Material.Grass

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
				cell.Material = Enum.Material.Slate
			else
				cell.Color = COLOR_GRASS
				cell.Material = Enum.Material.Grass
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
	local finalWp = waypoints[#waypoints]
	local castleCenter = Vector3.new(finalWp.X + CASTLE_OFFSET_X, 0, finalWp.Z)

	-- --- Invisible containment walls at the ground edges ---
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
		Vector3.new(groundSize, invHeight, 2),
		Vector3.new(0, invHeight / 2, -groundHalf)
	)
	makeInvisibleWall(
		"InvS",
		Vector3.new(groundSize, invHeight, 2),
		Vector3.new(0, invHeight / 2, groundHalf)
	)
	makeInvisibleWall(
		"InvE",
		Vector3.new(2, invHeight, groundSize),
		Vector3.new(groundHalf, invHeight / 2, 0)
	)
	makeInvisibleWall(
		"InvW",
		Vector3.new(2, invHeight, groundSize),
		Vector3.new(-groundHalf, invHeight / 2, 0)
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

	-- Upper east segment (from outerNorthZ to castleNorthZ at wallEastX)
	do
		local length = castleNorthZ - outerNorthZ
		local centerZ = (outerNorthZ + castleNorthZ) / 2
		makeWall("WallE_N", wallEastX, centerZ, wallThickness, length)
	end

	-- Lower east segment (from castleSouthZ to outerSouthZ at wallEastX)
	do
		local length = outerSouthZ - castleSouthZ
		local centerZ = (castleSouthZ + outerSouthZ) / 2
		makeWall("WallE_S", wallEastX, centerZ, wallThickness, length)
	end

	-- Castle wrap — north wall from wallEastX out to castleEastX
	do
		local length = castleEastX - wallEastX
		local centerX = (wallEastX + castleEastX) / 2
		makeWall("WrapN", centerX, castleNorthZ, length, wallThickness)
	end
	-- Castle wrap — south wall
	do
		local length = castleEastX - wallEastX
		local centerX = (wallEastX + castleEastX) / 2
		makeWall("WrapS", centerX, castleSouthZ, length, wallThickness)
	end
	-- Castle wrap — outer east wall
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

	-- --- Vegetation ---
	local vegetation = Instance.new("Folder")
	vegetation.Name = "Vegetation"
	vegetation.Parent = mapFolder

	local vegRng = Random.new(20260404)
	local innerEdge = halfGrid + 6
	local ringInnerEdge = groundHalf - 30 -- beginning of the dense outer ring
	local outerEdge = groundHalf - 8 -- outer cap for all vegetation

	-- Returns true if (x,z) falls inside the castle wrap area so we can
	-- skip vegetation there.
	local function insideCastleArea(x: number, z: number): boolean
		local dx = math.abs(x - castleCenter.X)
		local dz = math.abs(z - castleCenter.Z)
		return dx <= CASTLE_HALF_W + 3 and dz <= CASTLE_HALF_L + 3
	end

	-- Picks a point between the grid walls and the inner edge of the tree
	-- ring. Rejects (retries) up to 8 times if the point lands in the
	-- castle area.
	local function randomMidPoint(): (number, number)
		for _ = 1, 8 do
			local side = vegRng:NextInteger(1, 4)
			local along = vegRng:NextNumber(-ringInnerEdge, ringInnerEdge)
			local perp = vegRng:NextNumber(innerEdge, ringInnerEdge)
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
			if not insideCastleArea(x, z) then
				return x, z
			end
		end
		-- Fallback: some far corner
		return ringInnerEdge - 5, ringInnerEdge - 5
	end

	-- Picks a point inside the dense outer ring (near the ground edge)
	local function randomRingPoint(): (number, number)
		local side = vegRng:NextInteger(1, 4)
		local along = vegRng:NextNumber(-outerEdge, outerEdge)
		local perp = vegRng:NextNumber(ringInnerEdge, outerEdge)
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

	local TRUNK_COLOR = Color3.fromRGB(82, 52, 36)
	local CANOPY_COLORS = {
		Color3.fromRGB(27, 94, 32),
		Color3.fromRGB(33, 113, 39),
		Color3.fromRGB(46, 125, 50),
		Color3.fromRGB(20, 82, 28),
	}
	local BUSH_COLORS = {
		Color3.fromRGB(56, 142, 60),
		Color3.fromRGB(67, 160, 71),
		Color3.fromRGB(46, 125, 50),
	}
	local ROCK_COLORS = {
		Color3.fromRGB(117, 117, 117),
		Color3.fromRGB(97, 97, 97),
		Color3.fromRGB(78, 78, 78),
	}

	local function spawnTree(i: number, x: number, z: number, scale: number)
		local trunk = makePart(vegetation, "Trunk_" .. i)
		trunk.Size = Vector3.new(1.2 * scale, 7 * scale, 1.2 * scale)
		trunk.Position = Vector3.new(x, 3.5 * scale, z)
		trunk.Color = TRUNK_COLOR
		trunk.Material = Enum.Material.Wood
		trunk.CanCollide = false

		local canopy = makePart(vegetation, "Canopy_" .. i)
		canopy.Shape = Enum.PartType.Ball
		canopy.Size = Vector3.new(6 * scale, 6 * scale, 6 * scale)
		canopy.Position = Vector3.new(x, 8.5 * scale, z)
		canopy.Color = CANOPY_COLORS[vegRng:NextInteger(1, #CANOPY_COLORS)]
		canopy.Material = Enum.Material.Grass
		canopy.CanCollide = false
	end

	-- Scattered trees in the mid-zone (between walls and outer ring)
	for i = 1, 70 do
		local tx, tz = randomMidPoint()
		local scale = 0.85 + vegRng:NextNumber() * 0.7
		spawnTree(i, tx, tz, scale)
	end

	-- Bushes in the mid-zone
	for i = 1, 50 do
		local bx, bz = randomMidPoint()
		local s = 1.5 + vegRng:NextNumber() * 1.3
		local bush = makePart(vegetation, "Bush_" .. i)
		bush.Shape = Enum.PartType.Ball
		bush.Size = Vector3.new(s * 1.5, s, s * 1.5)
		bush.Position = Vector3.new(bx, s * 0.4, bz)
		bush.Color = BUSH_COLORS[vegRng:NextInteger(1, #BUSH_COLORS)]
		bush.Material = Enum.Material.Grass
		bush.CanCollide = false
	end

	-- Rocks in the mid-zone
	for i = 1, 35 do
		local rx, rz = randomMidPoint()
		local sx = 1.4 + vegRng:NextNumber() * 2
		local sy = 0.8 + vegRng:NextNumber() * 1.2
		local sz = 1.4 + vegRng:NextNumber() * 2
		local rock = makePart(vegetation, "Rock_" .. i)
		rock.Size = Vector3.new(sx, sy, sz)
		rock.CFrame = CFrame.new(rx, sy * 0.5, rz)
			* CFrame.Angles(0, vegRng:NextNumber() * math.pi * 2, 0)
		rock.Color = ROCK_COLORS[vegRng:NextInteger(1, #ROCK_COLORS)]
		rock.Material = Enum.Material.Rock
		rock.CanCollide = false
	end

	-- --- Dense outer tree ring (visual barrier hiding the ground edge) ---
	-- Large trees packed close together near the ground edges, forming a
	-- forest wall so the player never sees the end of the world.
	for i = 1, 240 do
		local tx, tz = randomRingPoint()
		local scale = 1.4 + vegRng:NextNumber() * 0.9
		spawnTree(1000 + i, tx, tz, scale)
	end

	return {
		folder = mapFolder,
		cells = cells,
		waypoints = waypoints,
		castleCenter = castleCenter,
	}
end

return Map
