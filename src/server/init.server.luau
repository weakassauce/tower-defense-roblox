--!strict
-- src/server/init.server.luau
-- ServerScriptService entry point. This is the authoritative game state —
-- tower placement, enemy movement, damage, gold economy all live here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local Config = Shared.Config
local TowerDefs = Shared.TowerDefs
local WaveConfig = Shared.WaveConfig

print("[TowerDefense] Server booting")
print(
	string.format(
		"  Grid: %dx%d @ %d studs/cell",
		Config.GRID_SIZE,
		Config.GRID_SIZE,
		Config.CELL_SIZE
	)
)

local towerCount = 0
for _ in TowerDefs do
	towerCount += 1
end
print(string.format("  Towers available: %d", towerCount))

local wave1 = WaveConfig.get(1)
print(string.format("  Wave 1: %d enemies in first group", wave1.enemies[1].count))

-- TODO: port these systems next
-- local Map = require(script.Map)
-- local EnemyManager = require(script.EnemyManager)
-- local TowerManager = require(script.TowerManager)
--
-- Map.build(workspace)
-- EnemyManager.init()
-- TowerManager.init()

print("[TowerDefense] Server ready")
