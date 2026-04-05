--!strict
-- src/client/init.client.luau
-- Client entry point. Mounts the HUD, sets up placement + camera, and
-- listens for server state updates / game events.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

-- Hide the default Roblox Backpack CoreGui since we mount guns as Tools
-- in the Backpack to get the Humanoid equip animation. Without this the
-- player would see a hotbar with the gun tool icon at the bottom.
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RealmDefs = require(ReplicatedStorage.Shared.RealmDefs)

local Hud = require(script.Hud)
local Placement = require(script.Placement)
local PlayerGun = require(script.PlayerGun)
local Tutorial = require(script.Tutorial)

local player = Players.LocalPlayer
print(string.format("[TowerDefense] Client booting for %s", player.Name))

-- Tutorial is only shown the first time the player walks into the
-- defense portal, not on the home screen or on subsequent returns.
local tutorialShown = false

Hud.mount(function()
	-- Home screen Play button was clicked — drop the player into the lobby
	-- in character view so they can walk to a portal. The tutorial waits
	-- until they actually enter the defense realm.
	Placement.setEnabled(true)
	Placement.enterLobbyMode()
	Hud.setArenaHudVisible(false)
end)

Hud.setReturnCallback(function()
	Remotes.ReturnToLobby:FireServer()
end)

Hud.setCameraToggleCallback(function()
	Placement.toggleCameraMode()
end)

Hud.setBuyGunCallback(function(gunKey)
	Remotes.BuyGun:FireServer(gunKey)
end)

Hud.setEquipGunCallback(function(gunKey)
	-- gunKey may be nil to explicitly unequip; RemoteEvent handles nil fine.
	Remotes.EquipGun:FireServer(gunKey)
end)

Placement.init()
PlayerGun.init()
Hud.setArenaHudVisible(false)

-- Tracks whether the player is currently inside an arena (not the
-- lobby). Used to decide if the gun model / crosshair should be live.
local inArena = false
local equippedGunKey: string? = nil

-- Refreshes the gun model + crosshair based on the current arena /
-- tower-selection / equipped-gun state. The gun is visible only when:
--   * The player is in an arena
--   * A gun is equipped
--   * No tower is currently selected in the HUD (otherwise the player
--     is trying to build, so we auto-unequip).
local function refreshGunVisibility()
	local shouldShow = inArena and equippedGunKey ~= nil and not Hud.isTowerSelected()
	PlayerGun.setVisible(shouldShow)
	Hud.setCrosshairVisible(shouldShow)
end

Hud.setSelectionChangedCallback(refreshGunVisibility)

-- Server → client state sync. Also watches for a gameOver → not gameOver
-- transition so the cinematic camera is released on restart, and for
-- equipped-gun changes so the visual model swaps in sync with the HUD.
local wasGameOver = false
Remotes.StateUpdate.OnClientEvent:Connect(function(state)
	Hud.onStateUpdate(state)
	if wasGameOver and not state.gameOver then
		Placement.cinematicRelease()
	end
	wasGameOver = state.gameOver

	if state.equippedGun ~= equippedGunKey then
		equippedGunKey = state.equippedGun
		PlayerGun.setEquipped(equippedGunKey)
		refreshGunVisibility()
	end
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

-- --- Gun effects ---
-- Server fires GunFired whenever a gun shot resolves, giving us the
-- muzzle origin, one hit point per pellet, the tracer color, and an
-- optional "killedAt" position (non-nil when the shot landed the
-- killing blow on an enemy). We render a gray smoke-puff trail from
-- the muzzle to each hit, and if anything was killed, a fiery explosion
-- at that enemy's position.

local function spawnSmokePuff(pos: Vector3, sizeScale: number)
	local puff = Instance.new("Part")
	puff.Name = "SmokePuff"
	puff.Shape = Enum.PartType.Ball
	local s = (1.1 + math.random() * 0.6) * sizeScale
	puff.Size = Vector3.new(s, s, s)
	puff.Anchored = true
	puff.CanCollide = false
	puff.CanQuery = false
	puff.CanTouch = false
	puff.CastShadow = false
	puff.Material = Enum.Material.SmoothPlastic
	puff.Color =
		Color3.fromRGB(170 + math.random(0, 25), 170 + math.random(0, 25), 170 + math.random(0, 20))
	puff.Transparency = 0.3
	puff.Position = pos
	puff.Parent = workspace

	task.spawn(function()
		local startSize = puff.Size
		local steps = 18
		for frame = 1, steps do
			local t = frame / steps
			puff.Transparency = 0.3 + t * 0.7
			puff.Size = startSize * (1 + t * 1.8)
			task.wait()
		end
		puff:Destroy()
	end)
end

local function spawnSmokeTrail(origin: Vector3, hitPos: Vector3)
	local delta = hitPos - origin
	local dist = delta.Magnitude
	if dist < 0.3 then
		return
	end
	local dir = delta.Unit
	local count = math.clamp(math.floor(dist / 2.2), 3, 22)
	for i = 0, count do
		local t = i / count
		local jitter = Vector3.new(
			(math.random() - 0.5) * 0.7,
			(math.random() - 0.5) * 0.7,
			(math.random() - 0.5) * 0.7
		)
		local scale = 0.6 + (1 - math.abs(t - 0.5) * 2) * 0.4 -- fatter in the middle
		spawnSmokePuff(origin + dir * (t * dist) + jitter, scale)
	end
end

local function spawnExplosion(pos: Vector3)
	-- Bright neon flash core
	local flash = Instance.new("Part")
	flash.Name = "ExplosionFlash"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(2, 2, 2)
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 210, 90)
	flash.Position = pos
	flash.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 180, 80)
	light.Range = 30
	light.Brightness = 6
	light.Parent = flash

	-- Outer smoke shell
	local smoke = Instance.new("Part")
	smoke.Name = "ExplosionSmoke"
	smoke.Shape = Enum.PartType.Ball
	smoke.Size = Vector3.new(1.5, 1.5, 1.5)
	smoke.Anchored = true
	smoke.CanCollide = false
	smoke.CanQuery = false
	smoke.CanTouch = false
	smoke.CastShadow = false
	smoke.Material = Enum.Material.SmoothPlastic
	smoke.Color = Color3.fromRGB(110, 95, 80)
	smoke.Transparency = 0.1
	smoke.Position = pos
	smoke.Parent = workspace

	-- Flying sparks (unanchored little neon balls)
	for _ = 1, 14 do
		local spark = Instance.new("Part")
		spark.Name = "Spark"
		spark.Shape = Enum.PartType.Ball
		spark.Size = Vector3.new(0.35, 0.35, 0.35)
		spark.Anchored = false
		spark.CanCollide = false
		spark.CanQuery = false
		spark.CanTouch = false
		spark.CastShadow = false
		spark.Massless = true
		spark.Material = Enum.Material.Neon
		spark.Color = Color3.fromRGB(255, 180 + math.random(0, 60), 60)
		spark.Position = pos
			+ Vector3.new(
				(math.random() - 0.5) * 1.5,
				(math.random()) * 1.2,
				(math.random() - 0.5) * 1.5
			)
		spark.AssemblyLinearVelocity = Vector3.new(
			(math.random() - 0.5) * 45,
			15 + math.random() * 25,
			(math.random() - 0.5) * 45
		)
		spark.Parent = workspace
		task.delay(0.75 + math.random() * 0.3, function()
			if spark and spark.Parent then
				spark:Destroy()
			end
		end)
	end

	task.spawn(function()
		local flashStart = flash.Size
		local smokeStart = smoke.Size
		local steps = 30
		for frame = 1, steps do
			local t = frame / steps
			flash.Size = flashStart * (1 + t * 5)
			flash.Transparency = t
			light.Brightness = 6 * (1 - t)
			smoke.Size = smokeStart * (1 + t * 7)
			smoke.Transparency = 0.1 + t * 0.9
			local c = math.max(30, 110 - math.floor(t * 70))
			smoke.Color = Color3.fromRGB(c, c - 15, c - 25)
			task.wait()
		end
		flash:Destroy()
		smoke:Destroy()
	end)
end

-- Brief flame/ember burst at the gun muzzle whenever a shot fires.
-- The flash is a bright neon core + a spray of small flame balls flung
-- outward in a narrow cone along the aim direction.
local function spawnMuzzleFlash(origin: Vector3, aimDir: Vector3)
	-- Bright neon core flash
	local flash = Instance.new("Part")
	flash.Name = "MuzzleFlash"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(1.1, 1.1, 1.1)
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 220, 120)
	flash.Position = origin
	flash.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 180, 80)
	light.Range = 12
	light.Brightness = 4
	light.Parent = flash

	task.spawn(function()
		local startSize = flash.Size
		local steps = 8
		for frame = 1, steps do
			local t = frame / steps
			flash.Size = startSize * (1 + t * 1.4)
			flash.Transparency = t
			light.Brightness = 4 * (1 - t)
			task.wait()
		end
		flash:Destroy()
	end)

	-- Flame particles: small neon balls flung forward in a narrow cone,
	-- fading from yellow → orange → red → dark as they expand and move.
	for i = 1, 8 do
		local spreadRad = 0.35
		local jitter = Vector3.new(
			(math.random() - 0.5) * spreadRad,
			(math.random() - 0.5) * spreadRad,
			(math.random() - 0.5) * spreadRad
		)
		local dir = (aimDir + jitter).Unit
		local particle = Instance.new("Part")
		particle.Name = "FlameParticle_" .. i
		particle.Shape = Enum.PartType.Ball
		local s = 0.35 + math.random() * 0.35
		particle.Size = Vector3.new(s, s, s)
		particle.Anchored = true
		particle.CanCollide = false
		particle.CanQuery = false
		particle.CanTouch = false
		particle.CastShadow = false
		particle.Material = Enum.Material.Neon
		particle.Color = Color3.fromRGB(255, 200 + math.random(0, 55), 60 + math.random(0, 60))
		particle.Position = origin + dir * 0.3
		particle.Parent = workspace

		task.spawn(function()
			local startSize = particle.Size
			local startPos = particle.Position
			local speed = 18 + math.random() * 12
			local steps = 10 + math.random(0, 4)
			for frame = 1, steps do
				local t = frame / steps
				particle.Position = startPos + dir * (speed * t * 0.03)
				particle.Size = startSize * (1 + t * 0.8)
				particle.Transparency = t
				-- cool from bright yellow → deep red → near-black
				local r = math.clamp(255 - math.floor(t * 60), 60, 255)
				local g = math.clamp(200 - math.floor(t * 200), 0, 255)
				local b = math.clamp(60 - math.floor(t * 60), 0, 255)
				particle.Color = Color3.fromRGB(r, g, b)
				task.wait()
			end
			particle:Destroy()
		end)
	end
end

Remotes.GunFired.OnClientEvent:Connect(function(origin, hits, _color, killedAt)
	if typeof(origin) ~= "Vector3" or typeof(hits) ~= "table" then
		return
	end
	-- Pick the first hit to derive an aim direction for the muzzle
	-- flash cone. Fall back to world forward if somehow nothing was
	-- in the hit list.
	local aimDir = Vector3.new(0, 0, -1)
	for _, hitPos in hits do
		if typeof(hitPos) == "Vector3" then
			local delta = hitPos - origin
			if delta.Magnitude > 0.01 then
				aimDir = delta.Unit
				break
			end
		end
	end
	spawnMuzzleFlash(origin, aimDir)
	for _, hitPos in hits do
		if typeof(hitPos) == "Vector3" then
			spawnSmokeTrail(origin, hitPos)
		end
	end
	if typeof(killedAt) == "Vector3" then
		spawnExplosion(killedAt)
	end
end)

-- A much bigger variant of the enemy-kill explosion used when the
-- castle is destroyed: larger flash, longer-lasting smoke plume, and
-- a dozen+ flying debris sparks.
local function spawnCastleExplosion(pos: Vector3)
	-- Layer 1: a cluster of smaller explosions at and around the castle
	-- so the blast feels wide instead of a single pop.
	for _ = 1, 6 do
		local offset =
			Vector3.new((math.random() - 0.5) * 14, math.random() * 6, (math.random() - 0.5) * 14)
		spawnExplosion(pos + offset)
	end

	-- Layer 2: one oversized central fireball that lingers
	local flash = Instance.new("Part")
	flash.Name = "CastleBoom"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(6, 6, 6)
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 200, 80)
	flash.Position = pos + Vector3.new(0, 8, 0)
	flash.Parent = workspace

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 160, 60)
	light.Range = 80
	light.Brightness = 10
	light.Parent = flash

	local smoke = Instance.new("Part")
	smoke.Name = "CastleSmoke"
	smoke.Shape = Enum.PartType.Ball
	smoke.Size = Vector3.new(8, 8, 8)
	smoke.Anchored = true
	smoke.CanCollide = false
	smoke.CanQuery = false
	smoke.CanTouch = false
	smoke.CastShadow = false
	smoke.Material = Enum.Material.SmoothPlastic
	smoke.Color = Color3.fromRGB(80, 70, 60)
	smoke.Transparency = 0.05
	smoke.Position = pos + Vector3.new(0, 10, 0)
	smoke.Parent = workspace

	-- Heavy debris chunks flung outward with physics
	for _ = 1, 24 do
		local chunk = Instance.new("Part")
		chunk.Name = "CastleDebris"
		chunk.Size =
			Vector3.new(1 + math.random() * 2, 1 + math.random() * 2, 1 + math.random() * 2)
		chunk.Anchored = false
		chunk.CanCollide = false
		chunk.CanQuery = false
		chunk.CanTouch = false
		chunk.CastShadow = false
		chunk.Massless = true
		chunk.Material = Enum.Material.Slate
		chunk.Color = Color3.fromRGB(110 + math.random(0, 30), 100, 90)
		chunk.Position = pos
			+ Vector3.new(
				(math.random() - 0.5) * 4,
				2 + math.random() * 4,
				(math.random() - 0.5) * 4
			)
		chunk.AssemblyLinearVelocity = Vector3.new(
			(math.random() - 0.5) * 90,
			25 + math.random() * 50,
			(math.random() - 0.5) * 90
		)
		chunk.AssemblyAngularVelocity = Vector3.new(
			(math.random() - 0.5) * 10,
			(math.random() - 0.5) * 10,
			(math.random() - 0.5) * 10
		)
		chunk.Parent = workspace
		task.delay(2 + math.random() * 1.5, function()
			if chunk and chunk.Parent then
				chunk:Destroy()
			end
		end)
	end

	task.spawn(function()
		local flashStart = flash.Size
		local smokeStart = smoke.Size
		local steps = 60
		for frame = 1, steps do
			local t = frame / steps
			flash.Size = flashStart * (1 + t * 4)
			flash.Transparency = t
			light.Brightness = 10 * (1 - t)
			smoke.Size = smokeStart * (1 + t * 3)
			smoke.Transparency = 0.05 + t * 0.95
			local c = math.max(20, 80 - math.floor(t * 50))
			smoke.Color = Color3.fromRGB(c, c - 10, c - 15)
			task.wait()
		end
		flash:Destroy()
		smoke:Destroy()
	end)
end

-- Second listener on CastleDestroyed (in addition to the camera pan
-- above): render a big fiery blast at the castle's position.
Remotes.CastleDestroyed.OnClientEvent:Connect(function(castlePos)
	if typeof(castlePos) == "Vector3" then
		spawnCastleExplosion(castlePos)
	end
end)

-- When the player touches the Realm Defense portal, server fires EnterRealm
-- and we flip the camera to the top-down overview for tower placement.
-- When they click the Return to Lobby button, server fires EnterRealm("lobby")
-- and we swap back to the default follow camera. The tutorial is also
-- triggered on first defense-portal entry.
Remotes.EnterRealm.OnClientEvent:Connect(function(realm)
	if realm == "lobby" then
		Placement.enterLobbyMode()
		Hud.setArenaHudVisible(false)
		inArena = false
		refreshGunVisibility()
		return
	end
	if not RealmDefs.exists(realm) then
		return
	end
	-- Sync the active path on the client so the placement preview +
	-- click validation reject the new realm's path cells, not the
	-- previous realm's.
	Config.setCurrentPath(RealmDefs.get(realm).path)
	Placement.enterArenaMode()
	Hud.resetForNewRealm()
	Hud.setArenaHudVisible(true)
	Hud.setRealmTowers(RealmDefs.getTowerList(realm))
	inArena = true
	refreshGunVisibility()
	if not tutorialShown then
		tutorialShown = true
		Tutorial.showPrompt(function()
			Tutorial.start(nil)
		end, function() end)
	end
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
