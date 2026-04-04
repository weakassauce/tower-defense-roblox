--!strict
-- src/client/init.client.luau
-- StarterPlayerScripts entry point. The client handles the HUD (gold/HP/wave),
-- tower panel, inventory, camera, and visual effects. Game-state mutations go
-- through RemoteEvents back to the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = require(ReplicatedStorage.Shared)
local TowerDefs = Shared.TowerDefs

local player = Players.LocalPlayer
print(string.format("[TowerDefense] Client booting for %s", player.Name))

-- Sanity check: make sure shared modules came across the wire
for towerType, def in TowerDefs do
	print(string.format("  Tower %-10s  cost=%-4d  range=%-4d", towerType, def.cost, def.range))
end

-- TODO: port these systems next
-- local Hud = require(script.Hud)
-- local Inventory = require(script.Inventory)
-- local Effects = require(script.Effects)
--
-- Hud.mount()
-- Inventory.mount()
-- Effects.init()

print("[TowerDefense] Client ready")
