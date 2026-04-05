--!strict
-- src/server/init.server.luau
-- Authoritative game loop. Owns the map, enemy/tower managers, game state,
-- and wave controller. Listens on RemoteEvents for client actions and
-- broadcasts state updates after every change.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Config = require(ReplicatedStorage.Shared.Config)
local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Map = require(script.Map)
local EnemyManager = require(script.EnemyManager)
local TowerManager = require(script.TowerManager)
local GameState = require(script.GameState)
local WaveController = require(script.WaveController)
local LightingSetup = require(script.LightingSetup)

print("[TowerDefense] Server booting")

LightingSetup.apply()

local mapData = Map.build()
EnemyManager.init(mapData.waypoints)
TowerManager.init()

print(
	string.format(
		"  Map: %d cells, %d waypoints, %d tower types",
		#mapData.cells:GetChildren(),
		#mapData.waypoints,
		(function()
			local n = 0
			for _ in TowerDefs do
				n += 1
			end
			return n
		end)()
	)
)

-- --- State broadcast helpers ---

local function broadcastState()
	Remotes.StateUpdate:FireAllClients(GameState.get())
end

local function broadcastToPlayer(player: Player)
	Remotes.StateUpdate:FireClient(player, GameState.get())
end

Players.PlayerAdded:Connect(function(player)
	-- Send the current state to any newly joined player
	task.wait(0.5)
	broadcastToPlayer(player)
end)
for _, player in Players:GetPlayers() do
	task.defer(broadcastToPlayer, player)
end

-- --- Full game reset ---

local function resetGame()
	EnemyManager.clear()
	TowerManager.clear()
	WaveController.reset()
	GameState.reset()
	broadcastState()
end

-- --- Remote handlers ---

Remotes.PlaceTower.OnServerEvent:Connect(function(_player, gx, gy, towerType)
	if typeof(gx) ~= "number" or typeof(gy) ~= "number" or typeof(towerType) ~= "string" then
		return
	end
	local state = GameState.get()
	if state.gameOver then
		return
	end
	local def = TowerDefs[towerType]
	if not def then
		return
	end
	if Config.isPath(gx, gy) then
		return
	end
	if TowerManager.isOccupied(gx, gy) then
		return
	end
	if not GameState.trySpend(def.cost) then
		return
	end
	TowerManager.place(gx, gy, towerType)
	broadcastState()
end)

Remotes.PickupTower.OnServerEvent:Connect(function(_player, gx, gy)
	if typeof(gx) ~= "number" or typeof(gy) ~= "number" then
		return
	end
	local state = GameState.get()
	if state.gameOver then
		return
	end
	local tower = TowerManager.getAt(gx, gy)
	if not tower then
		return
	end
	GameState.addToInventory(tower.towerType, tower.def.cost)
	TowerManager.remove(tower)
	broadcastState()
end)

Remotes.PlaceFromInventory.OnServerEvent:Connect(function(_player, invIndex, gx, gy)
	if typeof(invIndex) ~= "number" or typeof(gx) ~= "number" or typeof(gy) ~= "number" then
		return
	end
	local state = GameState.get()
	if state.gameOver then
		return
	end
	if Config.isPath(gx, gy) or TowerManager.isOccupied(gx, gy) then
		return
	end
	local item = GameState.removeFromInventory(invIndex)
	if not item then
		return
	end
	TowerManager.place(gx, gy, item.towerType)
	broadcastState()
end)

Remotes.SellInventoryItem.OnServerEvent:Connect(function(_player, invIndex)
	if typeof(invIndex) ~= "number" then
		return
	end
	local state = GameState.get()
	if state.gameOver then
		return
	end
	local item = GameState.removeFromInventory(invIndex)
	if not item then
		return
	end
	local refund = math.floor(item.cost * Config.SELL_RATIO)
	GameState.addGold(refund)
	broadcastState()
end)

Remotes.StartWave.OnServerEvent:Connect(function(_player)
	if WaveController.startWave() then
		broadcastState()
	end
end)

Remotes.Restart.OnServerEvent:Connect(function(_player)
	resetGame()
end)

-- --- Main game tick ---

RunService.Heartbeat:Connect(function(dt)
	local state = GameState.get()
	if state.gameOver then
		return
	end

	EnemyManager.update(dt)
	TowerManager.update(dt)

	-- Process enemy deaths (reward) and escapes (HP damage)
	local stateChanged = false
	for _, enemy in EnemyManager.getAll() do
		if enemy.reachedEnd and not enemy.damaged then
			enemy.damaged = true
			local died = GameState.damage(1)
			stateChanged = true
			if died then
				Remotes.GameOver:FireAllClients()
			end
		elseif not enemy.alive and not enemy.reachedEnd and not enemy.rewarded then
			enemy.rewarded = true
			GameState.addGold(enemy.reward)
			stateChanged = true
		end
	end

	-- Wave tick; bonus > 0 signals the wave finished this frame
	local bonus = WaveController.update(dt)
	if bonus > 0 then
		stateChanged = true
		Remotes.WaveComplete:FireAllClients(bonus)
	end

	EnemyManager.cleanup()

	if stateChanged then
		broadcastState()
	end
end)

print("[TowerDefense] Server ready")
