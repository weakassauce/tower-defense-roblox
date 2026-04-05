--!strict
-- src/server/Map.luau
-- Builds the physical map: ground, grid cells (grass/path), border walls,
-- and returns the waypoint list enemies walk along.
-- Ported from map.js.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = require(ReplicatedStorage.Shared)
local Config = Shared.Config

local Map = {}

export type MapData = {
	folder: Folder,
	cells: Folder,
	waypoints: { Vector3 },
}

-- Colors (RGB 0-255, matches the Three.js palette)
local COLOR_GROUND = Color3.fromRGB(46, 85, 34)
local COLOR_GRASS = Color3.fromRGB(67, 160, 71)
local COLOR_PATH = Color3.fromRGB(141, 110, 99)
local COLOR_WALL = Color3.fromRGB(97, 97, 97)
local COLOR_WALL_DARK = Color3.fromRGB(66, 66, 66)

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
	-- Clean up any previous map (hot-reload safe)
	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end

	local mapFolder = Instance.new("Folder")
	mapFolder.Name = "Map"
	mapFolder.Parent = workspace

	-- --- Ground platform (extends beyond the grid for visual padding) ---
	local padding = 24
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

			-- Attributes let the rest of the game query grid info off any cell
			cell:SetAttribute("gx", gx)
			cell:SetAttribute("gy", gy)
			cell:SetAttribute("isPath", isPath)
		end
	end

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
	makeWall("WallE", halfGrid + wallThickness / 2, 0, wallThickness, wallOuterLength)
	makeWall("WallW", -halfGrid - wallThickness / 2, 0, wallThickness, wallOuterLength)

	-- Corner watch towers at each corner of the wall
	local corners = Instance.new("Folder")
	corners.Name = "Corners"
	corners.Parent = mapFolder

	for _, signs in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
		local cx = signs[1] * (halfGrid + wallThickness / 2)
		local cz = signs[2] * (halfGrid + wallThickness / 2)

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

	-- --- Waypoints for enemy pathing ---
	-- Enemies will interpolate between these Vector3s in order.
	local waypoints: { Vector3 } = {}
	for i, coord in Config.PATH do
		local pos = Config.gridToWorld(coord[1], coord[2])
		waypoints[i] = Vector3.new(pos.X, 2, pos.Z)
	end

	return {
		folder = mapFolder,
		cells = cells,
		waypoints = waypoints,
	}
end

return Map
