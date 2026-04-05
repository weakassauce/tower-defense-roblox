--!strict
-- src/client/init.client.luau
-- Client entry point. Mounts the HUD, sets up placement + camera, and
-- listens for server state updates / game events.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Hud = require(script.Hud)
local Placement = require(script.Placement)

local player = Players.LocalPlayer
print(string.format("[TowerDefense] Client booting for %s", player.Name))

Hud.mount(function()
	-- Home screen Play button was clicked — enable placement
	Placement.setEnabled(true)
end)

Placement.init()

-- Server → client state sync
Remotes.StateUpdate.OnClientEvent:Connect(function(state)
	Hud.onStateUpdate(state)
end)

-- Wave completion notification (currently just adjusts the wave button text
-- via the state update that follows — the bonus value is available here
-- for future toast notifications)
Remotes.WaveComplete.OnClientEvent:Connect(function(_bonus)
	-- no-op for now
end)

Remotes.GameOver.OnClientEvent:Connect(function()
	Hud.showGameOver()
end)

-- Keep the "Enemies" stat live between state broadcasts by polling the
-- Enemies folder each frame. Not load-bearing — just makes the number
-- feel responsive.
local function getEnemyCount(): number
	local folder = workspace:FindFirstChild("Enemies")
	if not folder then
		return 0
	end
	return #folder:GetChildren()
end

RunService.RenderStepped:Connect(function()
	Hud.onLiveEnemyCount(getEnemyCount())
end)

print("[TowerDefense] Client ready")
