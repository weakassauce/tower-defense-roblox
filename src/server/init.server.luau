--!strict
-- src/server/init.server.luau
-- Authoritative game loop. Owns the map, enemy/tower managers, game state,
-- and wave controller. Players spawn in the lobby; touching a realm portal
-- builds that realm's themed arena and teleports the player in. Returning
-- to the lobby destroys the arena; re-entering rebuilds it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Config = require(ReplicatedStorage.Shared.Config)
local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local RealmDefs = require(ReplicatedStorage.Shared.RealmDefs)
local Guns = require(ReplicatedStorage.Shared.Guns)
local GamePassConfig = require(ReplicatedStorage.Shared.GamePassConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local MarketplaceService = game:GetService("MarketplaceService")

local Map = require(script.Map)
local EnemyManager = require(script.EnemyManager)
local TowerManager = require(script.TowerManager)
local GameState = require(script.GameState)
local WaveController = require(script.WaveController)
local LightingSetup = require(script.LightingSetup)
local Castle = require(script.Castle)
local Lobby = require(script.Lobby)

print("[TowerDefense] Server booting")

LightingSetup.apply()

-- Strip the default Baseplate / SpawnLocation that come with a blank place
for _, child in workspace:GetChildren() do
	if child.Name == "Baseplate" or child:IsA("SpawnLocation") then
		child:Destroy()
	end
end

-- SpawnLocation goes inside the lobby so new players land there.
local spawn = Instance.new("SpawnLocation")
spawn.Name = "TDSpawn"
spawn.Size = Vector3.new(6, 0.4, 6)
spawn.Anchored = true
spawn.CanCollide = true
spawn.Transparency = 1
spawn.TopSurface = Enum.SurfaceType.Smooth
spawn.BottomSurface = Enum.SurfaceType.Smooth
spawn.Neutral = true
spawn.Enabled = true
spawn.Parent = workspace

TowerManager.init()
EnemyManager.init({ Vector3.new(0, 2, 0) }) -- placeholder waypoints until an arena is built

-- --- Current arena state ---
-- `currentArena` is nil when no realm has been entered yet (fresh server
-- or everyone is back in the lobby). When a player touches a portal we
-- build a realm's themed arena; we keep it alive across ReturnToLobby so
-- quick re-entry is instant, and rebuild it only when the realm changes.
type ArenaState = {
	realm: string,
	mapData: Map.MapData,
}
local currentArena: ArenaState? = nil

local function destroyArena()
	EnemyManager.clear()
	TowerManager.clear()
	WaveController.reset()
	local existingMap = workspace:FindFirstChild("Map")
	if existingMap then
		existingMap:Destroy()
	end
	local existingCastle = workspace:FindFirstChild("Castle")
	if existingCastle then
		existingCastle:Destroy()
	end
	currentArena = nil
end

-- Save the currently active arena's tower layout + game-state into
-- GameState's per-realm save slot so re-entering this realm later
-- picks up where the player left off.
local function stashCurrentRealmProgress()
	if not currentArena then
		return
	end
	GameState.saveCurrentRealm(TowerManager.snapshot())
end

local function buildArena(realmName: string)
	-- Snapshot the previous realm (if any) before tearing it down.
	stashCurrentRealmProgress()

	destroyArena()

	local realm = RealmDefs.get(realmName)
	-- Swap the active path BEFORE building the map: Map.build reads
	-- Config.PATH, and the server place-tower handlers use
	-- Config.isPath to reject placements on the walkway.
	Config.setCurrentPath(realm.path)
	local mapData = Map.build(realmName)

	-- Extend the waypoints with the interior of the castle so enemies
	-- visibly march into the gate before dying.
	local extraWaypoints = Castle.build(mapData.castleCenter, Config.STARTING_HP, realmName)
	for _, wp in extraWaypoints do
		table.insert(mapData.waypoints, wp)
	end

	EnemyManager.init(mapData.waypoints)
	TowerManager.init()

	-- Load saved per-realm progress (hp, wave, inventory, tower layout).
	-- On a fresh start this returns an empty tower list and resets the
	-- per-realm state. Gold is global and is NOT reset here.
	local savedTowers = GameState.startRealm(realmName)
	TowerManager.restoreFrom(savedTowers)
	Castle.updateHp(GameState.get().hp, Config.STARTING_HP)

	currentArena = { realm = realmName, mapData = mapData }
end

-- Arena spawn point (where players land when entering a realm). Uses the
-- map's path start as the "safe edge" so players are behind the defenses.
local function getArenaSpawnCFrame(): CFrame
	return CFrame.new(Vector3.new(0, 8, 0))
end

-- Declared early so the Lobby callback can call it. The actual body is
-- assigned further down, after GameState is wired up.
local broadcastState: () -> ()
local broadcastToPlayer: (Player) -> ()

-- --- Lobby ---
local lobbyData = Lobby.build(function(player, realmName)
	-- A player touched a realm portal: (re)build that realm's arena if
	-- it isn't already the active one, then teleport and notify client.
	if not RealmDefs.exists(realmName) then
		return
	end
	-- Gate: check the unlock requirement against the global highest-wave
	-- table before letting the player enter.
	if not RealmDefs.isUnlocked(realmName, GameState.getHighestWaves()) then
		return
	end
	local rebuilt = false
	if not currentArena or currentArena.realm ~= realmName then
		buildArena(realmName)
		rebuilt = true
	end
	local char = player.Character
	if char then
		char:PivotTo(getArenaSpawnCFrame())
	end
	Remotes.EnterRealm:FireClient(player, realmName)
	if rebuilt then
		broadcastState()
	else
		broadcastToPlayer(player)
	end
end, GameState.getHighestWaves())
spawn.CFrame = lobbyData.spawnCFrame

print(string.format(
	"  Lobby ready. %d tower types, %d realms.",
	(function()
		local n = 0
		for _ in TowerDefs do
			n += 1
		end
		return n
	end)(),
	#RealmDefs.ORDER
))

-- --- State broadcast helpers ---

broadcastState = function()
	Remotes.StateUpdate:FireAllClients(GameState.get())
end

broadcastToPlayer = function(player: Player)
	Remotes.StateUpdate:FireClient(player, GameState.get())
end

Players.PlayerAdded:Connect(function(player)
	task.wait(0.5)
	broadcastToPlayer(player)
end)
for _, player in Players:GetPlayers() do
	task.defer(broadcastToPlayer, player)
end

-- "Play Again" inside the current realm after a defeat. Clears the
-- per-realm save (so we don't reload a game-over state), wipes enemies
-- and towers, and rebuilds the castle. Gold is global and is NOT reset
-- here; the player keeps whatever they had at defeat.
local function resetGame()
	if not currentArena then
		return
	end
	local realmName = currentArena.realm
	EnemyManager.clear()
	TowerManager.clear()
	WaveController.reset()
	GameState.resetCurrentRealm()
	-- Rebuild the castle (it may have exploded on the previous defeat)
	Castle.build(currentArena.mapData.castleCenter, Config.STARTING_HP, realmName)
	Castle.updateHp(GameState.get().hp, Config.STARTING_HP)
	broadcastState()
end

-- --- Premium tower (Game Pass) ownership ---
-- Cached per player; refreshed on join and when a purchase finishes.
local premiumOwners: { [Player]: boolean } = {}

local function ownsPremiumTower(player: Player): boolean
	if premiumOwners[player] ~= nil then
		return premiumOwners[player]
	end
	local passId = GamePassConfig.PREMIUM_TOWER.id
	-- In Studio or when the pass ID hasn't been configured yet, grant
	-- access for free so the developer can still test the tower.
	if passId == 0 or RunService:IsStudio() then
		premiumOwners[player] = true
		return true
	end
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	local owned = ok and result == true
	premiumOwners[player] = owned
	return owned
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(function()
		ownsPremiumTower(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	premiumOwners[player] = nil
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
	if passId == GamePassConfig.PREMIUM_TOWER.id and wasPurchased then
		premiumOwners[player] = true
		-- Tell the client to refresh its tower picker so the celestial
		-- card swaps from "99 R$" to the normal affordable state.
		Remotes.PremiumTowerUnlocked:FireClient(player)
	end
end)

-- --- Remote handlers ---

Remotes.PlaceTower.OnServerEvent:Connect(function(player, gx, gy, towerType)
	if typeof(gx) ~= "number" or typeof(gy) ~= "number" or typeof(towerType) ~= "string" then
		return
	end
	if not currentArena then
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
	-- Premium tower: require the 99 R$ game pass.
	local isPremium = towerType == GamePassConfig.PREMIUM_TOWER_KEY
	if isPremium and not ownsPremiumTower(player) then
		return
	end
	-- Allowed towers in this realm = 5 base + 3 signature + premium.
	local realm = RealmDefs.get(state.realm)
	local isUniversal = false
	for _, universal in RealmDefs.UNIVERSAL_TOWERS do
		if universal == towerType then
			isUniversal = true
			break
		end
	end
	if
		not isUniversal
		and not isPremium
		and not RealmDefs.isSignatureTower(state.realm, towerType)
	then
		return
	end
	if Config.isPath(gx, gy) then
		return
	end
	if TowerManager.isOccupied(gx, gy) then
		return
	end
	-- The premium celestial tower is free to place once the player
	-- owns the game pass — the Robux purchase is the only cost.
	if not isPremium then
		local scaledCost = math.floor(def.cost * realm.costMultiplier)
		if not GameState.trySpend(scaledCost) then
			return
		end
	end
	TowerManager.place(gx, gy, towerType)
	broadcastState()
end)

Remotes.PickupTower.OnServerEvent:Connect(function(_player, gx, gy)
	if typeof(gx) ~= "number" or typeof(gy) ~= "number" then
		return
	end
	if not currentArena then
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
	-- Store the scaled cost (what the player actually paid in this
	-- realm) so the sell refund matches. Re-placing from inventory
	-- charges nothing, so this is purely for the sell path.
	local realm = RealmDefs.get(state.realm)
	local scaledCost = math.floor(tower.def.cost * realm.costMultiplier)
	GameState.addToInventory(tower.towerType, scaledCost)
	TowerManager.remove(tower)
	broadcastState()
end)

Remotes.PlaceFromInventory.OnServerEvent:Connect(function(_player, invIndex, gx, gy)
	if typeof(invIndex) ~= "number" or typeof(gx) ~= "number" or typeof(gy) ~= "number" then
		return
	end
	if not currentArena then
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
	if not currentArena then
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
	if not currentArena then
		return
	end
	if WaveController.startWave() then
		broadcastState()
	end
end)

-- --- Gun shop ---

Remotes.BuyGun.OnServerEvent:Connect(function(_player, gunKey)
	if typeof(gunKey) ~= "string" then
		return
	end
	local def = Guns.defs[gunKey]
	if not def then
		return
	end
	if GameState.ownsGun(gunKey) then
		return
	end
	if not GameState.trySpend(def.cost) then
		return
	end
	GameState.giveGun(gunKey)
	-- Auto-equip the first gun the player buys so they can immediately
	-- start shooting without a second click.
	if GameState.getEquippedGun() == nil then
		GameState.equipGun(gunKey)
	end
	broadcastState()
end)

Remotes.EquipGun.OnServerEvent:Connect(function(_player, gunKey)
	if gunKey ~= nil and typeof(gunKey) ~= "string" then
		return
	end
	if gunKey and not GameState.ownsGun(gunKey) then
		return
	end
	GameState.equipGun(gunKey)
	broadcastState()
end)

-- Per-player fire cooldown so clients can't exceed their gun's fire
-- rate even if they spam the remote.
local lastFireAt: { [Player]: number } = {}

Remotes.FireGun.OnServerEvent:Connect(function(player, targetPos)
	if typeof(targetPos) ~= "Vector3" then
		return
	end
	if not currentArena then
		return
	end
	local state = GameState.get()
	if state.gameOver then
		return
	end
	local gunKey = state.equippedGun
	if not gunKey then
		return
	end
	local def = Guns.defs[gunKey]
	if not def then
		return
	end

	local now = os.clock()
	local minInterval = 1 / def.fireRate
	if lastFireAt[player] and now - lastFireAt[player] < minInterval * 0.9 then
		return
	end
	lastFireAt[player] = now

	local char = player.Character
	if not char then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	-- Origin: the player's right hand (where the gun grip is welded on
	-- the client), pushed forward along the aim direction so the tracer
	-- appears to exit the gun's muzzle instead of the center of the
	-- character.
	local rightHand = char:FindFirstChild("RightHand") :: BasePart?
	local handPos = if rightHand
		then rightHand.Position
		else (root.Position + Vector3.new(0, 0.5, 0))
	local aimDelta = targetPos - handPos
	if aimDelta.Magnitude < 0.01 then
		return
	end
	local aimDir = aimDelta.Unit
	local origin = handPos + aimDir * math.min(2.2, aimDelta.Magnitude * 0.5)

	-- Only hit enemies.
	local enemiesFolder = workspace:FindFirstChild("Enemies")
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = enemiesFolder and { enemiesFolder } or {}

	-- Cast `pellets` rays with random spread within the gun's cone.
	-- Track any killing blow so the client can play an explosion at the
	-- enemy's position when the final shot connects.
	local hitPositions: { Vector3 } = {}
	local killedAt: Vector3? = nil
	for _ = 1, def.pellets do
		local dir = aimDir
		if def.spread > 0 then
			local spreadRad = math.rad(def.spread)
			dir = (dir + Vector3.new(
				(math.random() - 0.5) * spreadRad,
				(math.random() - 0.5) * spreadRad,
				(math.random() - 0.5) * spreadRad
			)).Unit
		end
		local result = workspace:Raycast(origin, dir * def.range, params)
		if result and result.Instance then
			-- Walk up to the enemy Model (direct child of Enemies folder)
			local node: Instance? = result.Instance
			while node and node.Parent ~= enemiesFolder do
				node = node.Parent
			end
			if node and node:IsA("Model") then
				for _, enemy in EnemyManager.getAlive() do
					if enemy.model == node then
						local willKill = (enemy.hp - def.damage) <= 0
						-- "cannon" killer type plays the physics
						-- explosion death animation, so the enemy
						-- literally blows apart on the final shot.
						local killerType = if willKill then "cannon" else "basic"
						EnemyManager.damage(enemy, def.damage, killerType)
						if willKill then
							killedAt = enemy.root.Position
						end
						break
					end
				end
			end
			table.insert(hitPositions, result.Position)
		else
			table.insert(hitPositions, origin + dir * def.range)
		end
	end

	-- Broadcast visual effect: smoke trail from origin→hit for each
	-- pellet, plus an explosion position if anything was killed.
	Remotes.GunFired:FireAllClients(origin, hitPositions, def.tracerColor, killedAt)
	broadcastState()
end)

Players.PlayerRemoving:Connect(function(player)
	lastFireAt[player] = nil
end)

Remotes.Restart.OnServerEvent:Connect(function(_player)
	resetGame()
end)

Remotes.ReturnToLobby.OnServerEvent:Connect(function(player)
	-- Persist the current realm's progress so re-entry resumes where
	-- the player left off.
	stashCurrentRealmProgress()
	local char = player.Character
	if char then
		char:PivotTo(lobbyData.spawnCFrame)
	end
	Remotes.EnterRealm:FireClient(player, "lobby")
end)

-- --- Main game tick ---

RunService.Heartbeat:Connect(function(dt)
	if not currentArena then
		return
	end

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
			Castle.updateHp(GameState.get().hp, Config.STARTING_HP)
			Castle.flashDamage()
			if died then
				Castle.explode()
				Remotes.CastleDestroyed:FireAllClients(
					(currentArena :: ArenaState).mapData.castleCenter
				)
				task.delay(4, function()
					if GameState.get().gameOver then
						Remotes.GameOver:FireAllClients()
					end
				end)
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
		-- Record the achievement on this realm and, if it beat the
		-- previous best, refresh the lobby portals so any newly
		-- unlocked realms visually update right away.
		local s = GameState.get()
		if GameState.updateHighestWave(s.realm, s.waveNum) then
			Lobby.refreshUnlocks(lobbyData, GameState.getHighestWaves())
		end
	end

	EnemyManager.cleanup()

	if stateChanged then
		broadcastState()
	end
end)

print("[TowerDefense] Server ready")
