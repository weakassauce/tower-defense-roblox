--!strict
-- src/shared/Config.luau
-- Grid layout and world-space conversion. Mirrors config.js from the
-- Three.js prototype but uses Roblox studs instead of world units.

local Config = {}

Config.GRID_SIZE = 16
Config.CELL_SIZE = 8 -- Roblox studs per grid cell (was 2 in Three.js)
Config.HALF_GRID = (Config.GRID_SIZE * Config.CELL_SIZE) / 2

-- The path enemies walk along, as (gx, gy) grid coordinates.
-- Identical to the JS version so the layout matches.
Config.PATH = {
	{ 0, 2 },
	{ 1, 2 },
	{ 2, 2 },
	{ 3, 2 },
	{ 4, 2 },
	{ 5, 2 },
	{ 6, 2 },
	{ 7, 2 },
	{ 7, 3 },
	{ 7, 4 },
	{ 7, 5 },
	{ 7, 6 },
	{ 6, 6 },
	{ 5, 6 },
	{ 4, 6 },
	{ 3, 6 },
	{ 2, 6 },
	{ 2, 7 },
	{ 2, 8 },
	{ 2, 9 },
	{ 2, 10 },
	{ 3, 10 },
	{ 4, 10 },
	{ 5, 10 },
	{ 6, 10 },
	{ 7, 10 },
	{ 8, 10 },
	{ 9, 10 },
	{ 10, 10 },
	{ 10, 11 },
	{ 10, 12 },
	{ 10, 13 },
	{ 11, 13 },
	{ 12, 13 },
	{ 13, 13 },
	{ 14, 13 },
	{ 15, 13 },
}

-- Convert grid coordinates to a world position (centered on the grid).
function Config.gridToWorld(gx: number, gy: number): Vector3
	local x = gx * Config.CELL_SIZE - Config.HALF_GRID + Config.CELL_SIZE / 2
	local z = gy * Config.CELL_SIZE - Config.HALF_GRID + Config.CELL_SIZE / 2
	return Vector3.new(x, 0, z)
end

-- Convert world position back to grid coordinates (for placement raycasting).
function Config.worldToGrid(wx: number, wz: number): (number, number)
	local gx = math.floor((wx + Config.HALF_GRID) / Config.CELL_SIZE)
	local gy = math.floor((wz + Config.HALF_GRID) / Config.CELL_SIZE)
	return gx, gy
end

-- Quick lookup set for path cells.
local pathSet: { [string]: boolean } = {}
for _, pair in Config.PATH do
	pathSet[pair[1] .. "," .. pair[2]] = true
end

function Config.isPath(gx: number, gy: number): boolean
	return pathSet[gx .. "," .. gy] == true
end

-- Initial game state
Config.STARTING_HP = 25
Config.STARTING_GOLD = 175
Config.SELL_RATIO = 0.7

return Config
