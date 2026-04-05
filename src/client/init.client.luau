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
local Tutorial = require(script.Tutorial)

local player = Players.LocalPlayer
print(string.format("[TowerDefense] Client booting for %s", player.Name))

Hud.mount(function()
	-- Home screen Play button was clicked — ask whether to run the tutorial
	Tutorial.showPrompt(function()
		-- Yes: enable placement so the player can interact, then start tutorial
		Placement.setEnabled(true)
		Tutorial.start(nil)
	end, function()
		-- No: skip straight to free play
		Placement.setEnabled(true)
	end)
end)

Placement.init()

-- Server → client state sync. Also watches for a gameOver → not gameOver
-- transition so the cinematic camera is released on restart.
local wasGameOver = false
Remotes.StateUpdate.OnClientEvent:Connect(function(state)
	Hud.onStateUpdate(state)
	if wasGameOver and not state.gameOver then
		Placement.cinematicRelease()
	end
	wasGameOver = state.gameOver
end)

-- Wave completion notification. If the player has the AUTO WAVE toggle on,
-- fire StartWave after a short grace period.
Remotes.WaveComplete.OnClientEvent:Connect(function(_bonus)
	if not Hud.isAutoWaveEnabled() then
		return
	end
	task.delay(3, function()
		if not Hud.isAutoWaveEnabled() then
			return
		end
		local state = Hud.getState()
		if state and not state.waveActive and not state.gameOver then
			Remotes.StartWave:FireServer()
		end
	end)
end)

-- When the castle is destroyed, pan the camera to a cinematic angle in
-- front of it, hold for ~1 second while the explosion plays, then pan
-- back to the normal overview view. The Game Over screen is scheduled
-- to appear ~4 seconds after the explosion, so it shows up over the
-- regular view instead of the cinematic.
Remotes.CastleDestroyed.OnClientEvent:Connect(function(castlePos)
	if typeof(castlePos) ~= "Vector3" then
		return
	end
	local eye = castlePos + Vector3.new(-38, 22, -14)
	local target = castlePos + Vector3.new(0, 9, 0)
	Placement.cinematicPanTo(CFrame.lookAt(eye, target), 1.5)

	-- Pan back to the player's character after a short hold
	task.delay(2.7, function()
		Placement.cinematicReturnToCharacter(1.2)
	end)
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
