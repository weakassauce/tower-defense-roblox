--!strict
-- src/server/init.server.luau
-- Multiplayer server entry point. Each player who joins gets:
--   * A reserved slot (1..6) that maps to a unique world-space offset
--   * A per-player GameState instance
--   * A per-player ArenaController that owns their Map / Castle /
--     Towers / Projectiles / Enemies folders at the slot offset
--   * A DataStore-backed PlayerProgress load on join / save on leave
-- The lobby is shared: all players walk around one lobby island and
-- see each other. Touching a realm portal teleports just that player
-- into their own private arena.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Config = require(ReplicatedStorage.Shared.Config)
local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local RealmDefs = require(ReplicatedStorage.Shared.RealmDefs)
local Guns = require(ReplicatedStorage.Shared.Guns)
local GamePassConfig = require(ReplicatedStorage.Shared.GamePassConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local GameState = require(script.GameState)
local LightingSetup = require(script.LightingSetup)
local Lobby = require(script.Lobby)
local Castle = require(script.Castle)
local ArenaController = require(script.ArenaController)
local PlayerSlot = require(script.PlayerSlot)
local PlayerProgress = require(script.PlayerProgress)

print("[TowerDefense] Server booting")

LightingSetup.apply()

-- Loudly warn if any Robux ID is still 0 in a published (non-Studio)
-- server. In Studio the dev-fallback paths hand out premium items for
-- free so local testing works without real IDs; in production those
-- zeros silently break purchases (either nothing happens when the
-- player clicks Buy, or the item is handed out for free to everyone).
-- Printing a single prominent block here means a quick glance at the
-- server logs after publishing catches any missed entries.
if not RunService:IsStudio() then
	local missing: { string } = {}
	if GamePassConfig.PREMIUM_TOWER.id == 0 then
		table.insert(missing, "PREMIUM_TOWER (Celestial Bastion, 99 R$)")
	end
	if GamePassConfig.PREMIUM_GUN.id == 0 then
		table.insert(missing, "PREMIUM_GUN (Starfire Rifle, 49 R$)")
	end
	if GamePassConfig.PREMIUM_GUN_2.id == 0 then
		table.insert(missing, "PREMIUM_GUN_2 (Void Reaper, 49 R$)")
	end
	for i, pack in GamePassConfig.CASH_PACKS do
		if pack.productId == 0 then
			table.insert(
				missing,
				string.format("CASH_PACKS[%d] (%s, %d R$)", i, pack.label, pack.robuxPrice)
			)
		end
	end
	if #missing > 0 then
		warn("============================================================")
		warn("[TowerDefense] Robux IDs not configured. Players CANNOT pay:")
		for _, name in missing do
			warn("  - " .. name)
		end
		warn("Fill these in src/shared/GamePassConfig.luau before launch.")
		warn("============================================================")
	end
end

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
spawn.CanCollide = false
spawn.CanTouch = false
spawn.CanQuery = false
spawn.Transparency = 1
spawn.TopSurface = Enum.SurfaceType.Smooth
spawn.BottomSurface = Enum.SurfaceType.Smooth
spawn.Neutral = true
spawn.Enabled = true
spawn.Parent = workspace

-- --- Per-player contexts ---
-- One entry per connected player, populated on PlayerAdded and removed
-- on PlayerRemoving. Every remote handler and the main Heartbeat loop
-- pull the acting player's context out of here; there's no server-wide
-- singleton game state anymore.
type PlayerContext = {
	player: Player,
	slotIndex: number,
	slotOffset: Vector3,
	gameState: GameState.GameState,
	arena: ArenaController.ArenaController,
	inArena: boolean, -- true while the player is inside an arena (not the lobby)
	premiumOwned: boolean?, -- game-pass ownership cache; nil = not yet checked
	lastSaveAt: number, -- os.clock() of the most recent auto-save
	lastFireAt: number, -- gun rate-limiter
}

local contexts: { [Player]: PlayerContext } = {}

-- --- Broadcast helpers ---
-- Every state update is now targeted at a single player because each
-- player has their own GameState. The old StateUpdate:FireAllClients
-- broadcasted a shared singleton; with per-player state that would
-- leak one player's gold / realm / inventory to everyone else.
local function broadcastToPlayer(ctx: PlayerContext)
	Remotes.StateUpdate:FireClient(ctx.player, ctx.gameState:get())
end

-- --- Lobby camera limits ---
local LOBBY_MAX_ZOOM = 18
local ARENA_MAX_ZOOM = 400

local function applyLobbyCameraLimit(player: Player)
	player.CameraMaxZoomDistance = LOBBY_MAX_ZOOM
end

local function applyArenaCameraLimit(player: Player)
	player.CameraMaxZoomDistance = ARENA_MAX_ZOOM
end

-- --- Lobby (shared, single instance) ---
-- `lobbyData` is built once and stays parented to workspace forever.
-- All players share it. Touching a portal fires the callback with the
-- triggering player so we can route into their specific arena.
local lobbyData: Lobby.LobbyData
local ensurePlayerContext: (player: Player) -> PlayerContext?

-- All portals are built visually unlocked so one player's progression
-- doesn't leak to other players in the shared lobby. The server-side
-- per-player gate in the portal callback is the real lock. This table
-- is passed to Lobby.build so every portal renders in the "open" state.
local ALL_UNLOCKED: { [string]: number } = {}
for _, name in RealmDefs.ORDER do
	ALL_UNLOCKED[name] = 9999
end

lobbyData = Lobby.build(function(player, realmName)
	if not RealmDefs.exists(realmName) then
		return
	end
	local ctx = contexts[player]
	if not ctx then
		return
	end
	-- Gate: check the unlock requirement against THIS player's own
	-- highest-wave progress only. Two players can be at different
	-- unlock stages on the same server and the lock is still correct
	-- per-player because each has their own ArenaController.
	if not RealmDefs.isUnlocked(realmName, ctx.gameState:getHighestWaves()) then
		return
	end
	-- Show the loading screen while the arena builds + streams in.
	local realmDef = RealmDefs.get(realmName)
	Remotes.LoadingScreen:FireClient(player, true, realmDef.displayName)

	local sameRealm = ctx.arena.realmName == realmName
	if not sameRealm then
		ctx.arena:enterRealm(realmName)
	end
	ctx.inArena = true
	applyArenaCameraLimit(player)
	-- Player spawns unarmed. They can equip a gun manually from the
	-- armory if they want to shoot.
	local spawnCF = ctx.arena:getArenaSpawnCFrame()
	pcall(function()
		player:RequestStreamAroundAsync(spawnCF.Position, 5)
	end)
	local char = player.Character
	if char then
		char:PivotTo(spawnCF)
	end
	Remotes.EnterRealm:FireClient(player, realmName, ctx.slotOffset)
	broadcastToPlayer(ctx)
	Remotes.LoadingScreen:FireClient(player, false)
end, ALL_UNLOCKED)
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

-- --- Per-player portal lock overlays ---
-- The lobby's 3D portal Parts are shared — everyone sees the same
-- geometry. To show per-player lock state, we create BillboardGuis in
-- each player's PlayerGui with the portal shimmer as the Adornee. Only
-- that player can see their own PlayerGui children, so each player
-- sees locks that match their own progression.
--
-- `refreshPlayerPortalOverlays(ctx)` is called on join and whenever a
-- wave completes that might have advanced their highest-wave count.
-- It builds or destroys a lock overlay per portal based on whether
-- the player has met the requirement.

local function refreshPlayerPortalOverlays(ctx: PlayerContext)
	local player = ctx.player
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	-- Container ScreenGui for this player's portal overlays. Using a
	-- ScreenGui just as a holder — the BillboardGuis inside it use
	-- Adornee to position themselves in 3D space.
	local container = playerGui:FindFirstChild("PortalLockOverlays") :: ScreenGui?
	if not container then
		container = Instance.new("ScreenGui")
		container.Name = "PortalLockOverlays"
		container.ResetOnSpawn = false
		container.Parent = playerGui
	end

	local highestWaves = ctx.gameState:getHighestWaves()
	for _, refs in lobbyData.portals do
		local realmName = refs.name
		local unlocked = RealmDefs.isUnlocked(realmName, highestWaves)
		local existing = container:FindFirstChild("Lock_" .. realmName) :: BillboardGui?

		if unlocked then
			-- Player has earned this portal — remove lock overlay if present
			if existing then
				existing:Destroy()
			end
		else
			-- Player hasn't earned it — create or update the overlay
			if not existing then
				local overlay = Instance.new("BillboardGui")
				overlay.Name = "Lock_" .. realmName
				overlay.Size = UDim2.fromOffset(280, 110)
				overlay.StudsOffset = Vector3.new(0, 0, 0)
				overlay.AlwaysOnTop = true
				overlay.LightInfluence = 0
				overlay.Adornee = refs.shimmer
				overlay.Parent = container

				local lockedTitle = Instance.new("TextLabel")
				lockedTitle.Name = "LockedTitle"
				lockedTitle.Size = UDim2.fromScale(1, 0.38)
				lockedTitle.Position = UDim2.fromScale(0, 0)
				lockedTitle.BackgroundTransparency = 1
				lockedTitle.Text = "LOCKED"
				lockedTitle.Font = Enum.Font.GothamBlack
				lockedTitle.TextSize = 28
				lockedTitle.TextColor3 = Color3.fromRGB(255, 215, 100)
				lockedTitle.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				lockedTitle.TextStrokeTransparency = 0
				lockedTitle.Parent = overlay

				local reqLabel = Instance.new("TextLabel")
				reqLabel.Name = "RequirementText"
				reqLabel.Size = UDim2.fromScale(1, 0.62)
				reqLabel.Position = UDim2.fromScale(0, 0.38)
				reqLabel.BackgroundTransparency = 1
				reqLabel.Font = Enum.Font.GothamBold
				reqLabel.TextSize = 18
				reqLabel.TextColor3 = Color3.fromRGB(255, 240, 200)
				reqLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
				reqLabel.TextStrokeTransparency = 0
				reqLabel.TextWrapped = true
				reqLabel.Parent = overlay

				-- Build requirement text
				local def = RealmDefs.get(realmName)
				if def.unlockRequirement then
					local req = def.unlockRequirement
					local reqDef = RealmDefs.get(req.realm)
					reqLabel.Text = string.format(
						"[ REACH WAVE %d IN %s ]",
						req.wave,
						string.upper(reqDef.displayName)
					)
				else
					reqLabel.Text = "[ LOCKED ]"
				end
			end
		end
	end
end

-- --- Premium game-pass ownership (per player) ---
local function ownsPremiumTower(ctx: PlayerContext): boolean
	if ctx.gameState:isAdmin() then
		return true
	end
	if ctx.premiumOwned ~= nil then
		return ctx.premiumOwned
	end
	local passId = GamePassConfig.PREMIUM_TOWER.id
	if passId == 0 or RunService:IsStudio() then
		ctx.premiumOwned = true
		return true
	end
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(ctx.player.UserId, passId)
	end)
	local owned = ok and result == true
	ctx.premiumOwned = owned
	return owned
end

-- --- PlayerAdded / PlayerRemoving ---

-- Load the player's DataStore save, seed the GameState from it, and
-- wire up their ArenaController. Returns the new context so the caller
-- can immediately broadcast state or do other per-player setup.
function ensurePlayerContext(player: Player): PlayerContext?
	if contexts[player] then
		return contexts[player]
	end

	local slotIndex, slotOffset = PlayerSlot.allocate(player)
	if not slotIndex or not slotOffset then
		warn(string.format("[TowerDefense] No slot available for %s, server is full", player.Name))
		player:Kick("Server is full.")
		return nil
	end

	local gameState = GameState.new()

	-- Load persistent progress and seed the state. If the load returned
	-- a fresh default, trust Config.STARTING_GOLD; otherwise trust the
	-- persisted gold value even if it's below STARTING_GOLD (player may
	-- have spent down).
	local save, isFresh = PlayerProgress.load(player)
	if not isFresh then
		gameState:get().gold = save.gold
	end
	gameState:get().ownedGuns = save.ownedGuns
	gameState:get().equippedGun = save.equippedGun
	for realmName, wave in save.highestWaves do
		gameState:getHighestWaves()[realmName] = wave
	end
	-- Restore per-realm in-progress saves (tower layout, wave, inventory,
	-- hp) so re-entering a realm resumes exactly where the player left
	-- off last session. Also inject any carried celestial items back into
	-- the starting inventory so the premium tower isn't lost across
	-- sessions.
	for realmName, rs in save.realmSaves do
		gameState.realmSaves[realmName] = {
			hp = rs.hp,
			waveNum = rs.waveNum,
			waveActive = rs.waveActive,
			gameOver = rs.gameOver,
			inventory = rs.inventory,
			towers = rs.towers,
		}
	end
	if save.celestialCount > 0 then
		for _ = 1, save.celestialCount do
			gameState:addToInventory("celestial", 0)
		end
	end

	local arena = ArenaController.new(player, slotOffset, gameState)

	local ctx: PlayerContext = {
		player = player,
		slotIndex = slotIndex,
		slotOffset = slotOffset,
		gameState = gameState,
		arena = arena,
		inArena = false,
		premiumOwned = nil,
		lastSaveAt = os.clock(),
		lastFireAt = 0,
	}
	contexts[player] = ctx
	return ctx
end

-- Snapshot the current SaveData for this player and push it to the
-- DataStore. Safe to call repeatedly; the PlayerProgress wrapper
-- handles its own throttling + error logging.
local function persistContext(ctx: PlayerContext)
	local state = ctx.gameState:get()
	-- Count carried celestial items in the active inventory. These are
	-- stripped from realmSaves by saveCurrentRealm (they travel with the
	-- player, not per-realm), so we persist them as a separate count and
	-- re-inject on load.
	local celestialCount = 0
	for _, item in state.inventory do
		if item.towerType == "celestial" then
			celestialCount += 1
		end
	end
	-- Build a serializable copy of realmSaves for the DataStore.
	local realmSavesData: { [string]: PlayerProgress.RealmSaveData } = {}
	for realmName, rs in ctx.gameState.realmSaves do
		realmSavesData[realmName] = {
			hp = rs.hp,
			waveNum = rs.waveNum,
			waveActive = rs.waveActive,
			gameOver = rs.gameOver,
			inventory = rs.inventory,
			towers = rs.towers,
		}
	end
	local data: PlayerProgress.SaveData = {
		gold = state.gold,
		ownedGuns = state.ownedGuns,
		equippedGun = state.equippedGun,
		highestWaves = ctx.gameState:getHighestWaves(),
		realmSaves = realmSavesData,
		celestialCount = celestialCount,
	}
	PlayerProgress.save(ctx.player, data)
	ctx.lastSaveAt = os.clock()
end

-- Respawn handler: if the player was in an arena, put them back into
-- their arena spawn instead of dropping them into the lobby.
local function hookCharacterRespawn(ctx: PlayerContext)
	ctx.player.CharacterAdded:Connect(function(char)
		task.wait()
		local targetCF = if ctx.inArena
			then ctx.arena:getArenaSpawnCFrame()
			else lobbyData.spawnCFrame
		pcall(function()
			ctx.player:RequestStreamAroundAsync(targetCF.Position, 5)
		end)
		char:PivotTo(targetCF)
	end)
end

local function onPlayerAdded(player: Player)
	applyLobbyCameraLimit(player)
	local ctx = ensurePlayerContext(player)
	if not ctx then
		return
	end
	hookCharacterRespawn(ctx)

	-- Kick off a premium-tower ownership probe in the background so
	-- the cache is warm when the player first touches the tower picker.
	task.spawn(function()
		ownsPremiumTower(ctx)
	end)

	-- Initial state push. Wait a moment for the client to subscribe
	-- and for PlayerGui to exist so lock overlays can be parented.
	task.wait(0.5)
	refreshPlayerPortalOverlays(ctx)
	broadcastToPlayer(ctx)
end

local function onPlayerRemoving(player: Player)
	local ctx = contexts[player]
	if not ctx then
		return
	end
	-- Stash any in-progress realm so re-joining this session resumes
	-- where the player left off. DataStore only persists the long-term
	-- fields; per-realm in-progress state stays server-local.
	ctx.arena:stashCurrentRealm()
	persistContext(ctx)
	ctx.arena:destroy()
	PlayerSlot.release(player)
	contexts[player] = nil

end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle any players already in the server when this script finishes
-- booting (e.g. a hot reload).
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- --- BindToClose: final save pass before shutdown ---
game:BindToClose(function()
	-- Roblox gives us up to 30 seconds on BindToClose. Save every
	-- connected player in parallel so slow saves don't starve others.
	local tasks = {}
	for _, ctx in contexts do
		local c = ctx
		table.insert(tasks, task.spawn(function()
			pcall(function()
				persistContext(c)
			end)
		end))
	end
	-- Yield a tick so spawned tasks get a chance to hit the DataStore
	-- before the server goes down. BindToClose will wait on this
	-- coroutine's return, which gives us the full grace period.
	for _ = 1, 120 do
		task.wait(0.1)
		local allDone = true
		for _, t in tasks do
			if coroutine.status(t) ~= "dead" then
				allDone = false
				break
			end
		end
		if allDone then
			break
		end
	end
end)

-- --- Admin cheat code ---
local ADMIN_CODE = "5695"

Remotes.UnlockAdmin.OnServerEvent:Connect(function(player, code)
	if typeof(code) ~= "string" or code ~= ADMIN_CODE then
		return
	end
	local ctx = contexts[player]
	if not ctx or ctx.gameState:isAdmin() then
		return
	end
	local keys = {}
	for key in pairs(Guns.defs) do
		table.insert(keys, key)
	end
	ctx.gameState:setAdmin(keys)
	ctx.gameState:unlockAllRealms(RealmDefs.ORDER)
	refreshPlayerPortalOverlays(ctx)
	ctx.premiumOwned = true
	Remotes.PremiumTowerUnlocked:FireClient(player)
	broadcastToPlayer(ctx)
	print(string.format("[TowerDefense] Admin unlocked for %s", player.Name))
end)

-- --- Cash pack Developer Products ---
local function processReceipt(info: { PlayerId: number, ProductId: number, PurchaseId: string })
	local payout = GamePassConfig.getCashForProduct(info.ProductId)
	if not payout then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local player = Players:GetPlayerByUserId(info.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ctx = contexts[player]
	if not ctx then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	ctx.gameState:addGold(payout)
	broadcastToPlayer(ctx)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
MarketplaceService.ProcessReceipt = processReceipt

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
	local ctx = contexts[player]
	if not ctx or not wasPurchased then
		return
	end
	if passId == GamePassConfig.PREMIUM_TOWER.id then
		ctx.premiumOwned = true
		Remotes.PremiumTowerUnlocked:FireClient(player)
	elseif passId == GamePassConfig.PREMIUM_GUN.id then
		local gunKey = GamePassConfig.PREMIUM_GUN_KEY
		if not ctx.gameState:ownsGun(gunKey) then
			ctx.gameState:giveGun(gunKey)
		end
		ctx.gameState:equipGun(gunKey)
		broadcastToPlayer(ctx)
	elseif passId == GamePassConfig.PREMIUM_GUN_2.id then
		local gunKey = GamePassConfig.PREMIUM_GUN_2_KEY
		if not ctx.gameState:ownsGun(gunKey) then
			ctx.gameState:giveGun(gunKey)
		end
		ctx.gameState:equipGun(gunKey)
		broadcastToPlayer(ctx)
	end
end)

-- --- Remote handlers (every handler routes through the caller's context) ---

Remotes.PlaceTower.OnServerEvent:Connect(function(player, gx, gy, towerType)
	if typeof(gx) ~= "number" or typeof(gy) ~= "number" or typeof(towerType) ~= "string" then
		return
	end
	local ctx = contexts[player]
	if not ctx or not ctx.inArena then
		return
	end
	local state = ctx.gameState:get()
	if state.gameOver then
		return
	end
	local def = TowerDefs[towerType]
	if not def then
		return
	end
	local isPremium = towerType == GamePassConfig.PREMIUM_TOWER_KEY
	if isPremium and not ownsPremiumTower(ctx) then
		return
	end
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
	-- Per-arena path + occupancy checks so concurrent arenas don't race
	-- on a shared Config.PATH value.
	if ctx.arena:isPath(gx, gy) then
		return
	end
	local towerMgr = ctx.arena.towerMgr
	if not towerMgr or towerMgr:isOccupied(gx, gy) then
		return
	end
	if not isPremium and not ctx.gameState:isAdmin() then
		local scaledCost = math.floor(def.cost * realm.costMultiplier)
		if not ctx.gameState:trySpend(scaledCost) then
			return
		end
	end
	towerMgr:place(gx, gy, towerType)
	broadcastToPlayer(ctx)
end)

Remotes.PickupTower.OnServerEvent:Connect(function(player, gx, gy)
	if typeof(gx) ~= "number" or typeof(gy) ~= "number" then
		return
	end
	local ctx = contexts[player]
	if not ctx or not ctx.inArena then
		return
	end
	local state = ctx.gameState:get()
	if state.gameOver then
		return
	end
	local towerMgr = ctx.arena.towerMgr
	if not towerMgr then
		return
	end
	local tower = towerMgr:getAt(gx, gy)
	if not tower then
		return
	end
	local itemCost: number
	if tower.towerType == GamePassConfig.PREMIUM_TOWER_KEY then
		itemCost = 0
	else
		local realm = RealmDefs.get(state.realm)
		itemCost = math.floor(tower.def.cost * realm.costMultiplier)
	end
	ctx.gameState:addToInventory(tower.towerType, itemCost)
	towerMgr:remove(tower)
	broadcastToPlayer(ctx)
end)

Remotes.PlaceFromInventory.OnServerEvent:Connect(function(player, invIndex, gx, gy)
	if typeof(invIndex) ~= "number" or typeof(gx) ~= "number" or typeof(gy) ~= "number" then
		return
	end
	local ctx = contexts[player]
	if not ctx or not ctx.inArena then
		return
	end
	local state = ctx.gameState:get()
	if state.gameOver then
		return
	end
	local towerMgr = ctx.arena.towerMgr
	if not towerMgr then
		return
	end
	if ctx.arena:isPath(gx, gy) or towerMgr:isOccupied(gx, gy) then
		return
	end
	local item = ctx.gameState:removeFromInventory(invIndex)
	if not item then
		return
	end
	towerMgr:place(gx, gy, item.towerType)
	broadcastToPlayer(ctx)
end)

Remotes.SellInventoryItem.OnServerEvent:Connect(function(player, invIndex)
	if typeof(invIndex) ~= "number" then
		return
	end
	local ctx = contexts[player]
	if not ctx or not ctx.inArena then
		return
	end
	local state = ctx.gameState:get()
	if state.gameOver then
		return
	end
	local preview = ctx.gameState:peekInventory(invIndex)
	if not preview or preview.towerType == GamePassConfig.PREMIUM_TOWER_KEY then
		return
	end
	local item = ctx.gameState:removeFromInventory(invIndex)
	if not item then
		return
	end
	local refund = math.floor(item.cost * Config.SELL_RATIO)
	ctx.gameState:addGold(refund)
	broadcastToPlayer(ctx)
end)

Remotes.StartWave.OnServerEvent:Connect(function(player)
	local ctx = contexts[player]
	if not ctx or not ctx.inArena then
		return
	end
	local waveCtrl = ctx.arena.waveCtrl
	if waveCtrl and waveCtrl:startWave() then
		broadcastToPlayer(ctx)
	end
end)

-- --- Gun shop ---

Remotes.BuyGun.OnServerEvent:Connect(function(player, gunKey)
	if typeof(gunKey) ~= "string" then
		return
	end
	local ctx = contexts[player]
	if not ctx then
		return
	end
	local def = Guns.defs[gunKey]
	if not def then
		return
	end
	if ctx.gameState:ownsGun(gunKey) then
		return
	end
	if gunKey == GamePassConfig.PREMIUM_GUN_KEY then
		if ctx.gameState:isAdmin() then
			ctx.gameState:giveGun(gunKey)
			ctx.gameState:equipGun(gunKey)
			broadcastToPlayer(ctx)
			return
		end
		local passId = GamePassConfig.PREMIUM_GUN.id
		if passId > 0 then
			pcall(function()
				MarketplaceService:PromptGamePassPurchase(player, passId)
			end)
		elseif RunService:IsStudio() then
			ctx.gameState:giveGun(gunKey)
			if ctx.gameState:getEquippedGun() == nil then
				ctx.gameState:equipGun(gunKey)
			end
			broadcastToPlayer(ctx)
		end
		return
	end
	if gunKey == GamePassConfig.PREMIUM_GUN_2_KEY then
		if ctx.gameState:isAdmin() then
			ctx.gameState:giveGun(gunKey)
			ctx.gameState:equipGun(gunKey)
			broadcastToPlayer(ctx)
			return
		end
		local passId = GamePassConfig.PREMIUM_GUN_2.id
		if passId > 0 then
			pcall(function()
				MarketplaceService:PromptGamePassPurchase(player, passId)
			end)
		elseif RunService:IsStudio() then
			ctx.gameState:giveGun(gunKey)
			if ctx.gameState:getEquippedGun() == nil then
				ctx.gameState:equipGun(gunKey)
			end
			broadcastToPlayer(ctx)
		end
		return
	end
	if not ctx.gameState:isAdmin() and not ctx.gameState:trySpend(def.cost) then
		return
	end
	ctx.gameState:giveGun(gunKey)
	if ctx.gameState:getEquippedGun() == nil then
		ctx.gameState:equipGun(gunKey)
	end
	broadcastToPlayer(ctx)
end)

Remotes.EquipGun.OnServerEvent:Connect(function(player, gunKey)
	if gunKey ~= nil and typeof(gunKey) ~= "string" then
		return
	end
	local ctx = contexts[player]
	if not ctx then
		return
	end
	if gunKey and not ctx.gameState:ownsGun(gunKey) then
		return
	end
	ctx.gameState:equipGun(gunKey)
	broadcastToPlayer(ctx)
end)

Remotes.FireGun.OnServerEvent:Connect(function(player, targetPos)
	if typeof(targetPos) ~= "Vector3" then
		return
	end
	local ctx = contexts[player]
	if not ctx or not ctx.inArena then
		return
	end
	local state = ctx.gameState:get()
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
	if now - ctx.lastFireAt < minInterval * 0.9 then
		return
	end
	ctx.lastFireAt = now

	local char = player.Character
	if not char then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

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

	-- Only hit enemies in THIS player's arena. The enemyMgr.folder is
	-- the per-arena Enemies subfolder, which means raycasts naturally
	-- ignore other players' arenas even though they all share workspace.
	local enemyMgr = ctx.arena.enemyMgr
	if not enemyMgr then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { enemyMgr.folder }

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
			local node: Instance? = result.Instance
			while node and node.Parent ~= enemyMgr.folder do
				node = node.Parent
			end
			if node and node:IsA("Model") then
				for _, enemy in enemyMgr:getAlive() do
					if enemy.model == node then
						local willKill = (enemy.hp - def.damage) <= 0
						local killerType = if willKill then "cannon" else "basic"
						enemyMgr:damage(enemy, def.damage, killerType)
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

	-- Only the shooting player needs to see their own tracer/smoke —
	-- every arena is private, so no other player is present to witness
	-- it. Was FireAllClients in single-player.
	Remotes.GunFired:FireClient(player, origin, hitPositions, def.tracerColor, killedAt)
	broadcastToPlayer(ctx)
end)

Remotes.Restart.OnServerEvent:Connect(function(player)
	local ctx = contexts[player]
	if not ctx or not ctx.inArena then
		return
	end
	local realmDef = RealmDefs.get(ctx.arena.realmName or "defense")
	Remotes.LoadingScreen:FireClient(player, true, realmDef.displayName)
	ctx.arena:resetCurrentRealm()
	local spawnCF = ctx.arena:getArenaSpawnCFrame()
	pcall(function()
		player:RequestStreamAroundAsync(spawnCF.Position, 5)
	end)
	local char = player.Character
	if char then
		char:PivotTo(spawnCF)
	end
	broadcastToPlayer(ctx)
	Remotes.LoadingScreen:FireClient(player, false)
end)

Remotes.ReturnToLobby.OnServerEvent:Connect(function(player)
	local ctx = contexts[player]
	if not ctx then
		return
	end
	Remotes.LoadingScreen:FireClient(player, true, "Lobby")
	ctx.arena:returnToLobby()
	ctx.inArena = false
	applyLobbyCameraLimit(player)
	ctx.gameState:equipGun(nil)
	pcall(function()
		player:RequestStreamAroundAsync(lobbyData.spawnCFrame.Position, 5)
	end)
	local char = player.Character
	if char then
		char:PivotTo(lobbyData.spawnCFrame)
	end
	Remotes.EnterRealm:FireClient(player, "lobby", Vector3.zero)
	broadcastToPlayer(ctx)
	Remotes.LoadingScreen:FireClient(player, false)
end)

-- --- Main game tick ---
-- Iterates every connected player's arena and runs one update step.
-- Per-player state changes fire targeted broadcasts, not FireAllClients,
-- so players in different realms never see each other's state.

local AUTO_SAVE_INTERVAL = 60 -- seconds

RunService.Heartbeat:Connect(function(dt)
	for _, ctx in contexts do
		if not ctx.inArena then
			continue
		end
		local state = ctx.gameState:get()
		if state.gameOver then
			continue
		end

		local enemyMgr = ctx.arena.enemyMgr
		local towerMgr = ctx.arena.towerMgr
		local waveCtrl = ctx.arena.waveCtrl
		local castleCtx = ctx.arena.castleCtx
		if not enemyMgr or not towerMgr or not waveCtrl or not castleCtx then
			continue
		end

		towerMgr:update(dt)
		enemyMgr:update(dt)

		local stateChanged = false
		for _, enemy in enemyMgr:getAll() do
			if enemy.reachedEnd and not enemy.damaged then
				enemy.damaged = true
				local died = ctx.gameState:damage(enemy.castleDamage)
				stateChanged = true
				Castle.updateHp(castleCtx, ctx.gameState:get().hp, Config.STARTING_HP)
				Castle.flashDamage(castleCtx)
				if died then
					Castle.explode(castleCtx)
					Remotes.CastleDestroyed:FireClient(ctx.player, castleCtx.center)
					local owner = ctx
					task.delay(4, function()
						if owner.gameState:get().gameOver then
							Remotes.GameOver:FireClient(owner.player)
						end
					end)
				end
			elseif not enemy.alive and not enemy.reachedEnd and not enemy.rewarded then
				enemy.rewarded = true
				ctx.gameState:addGold(enemy.reward)
				stateChanged = true
			end
		end

		local bonus = waveCtrl:update(dt)
		if bonus > 0 then
			stateChanged = true
			Remotes.WaveComplete:FireClient(ctx.player, bonus)
			local s = ctx.gameState:get()
			if ctx.gameState:updateHighestWave(s.realm, s.waveNum) then
				-- New personal best — refresh this player's lock overlays
				-- so any newly unlocked portal immediately clears its lock.
				refreshPlayerPortalOverlays(ctx)
			end
		end

		enemyMgr:cleanup()

		-- Auto-save throttle: persist progress every AUTO_SAVE_INTERVAL
		-- seconds so a crash doesn't lose more than a minute of play.
		if os.clock() - ctx.lastSaveAt > AUTO_SAVE_INTERVAL then
			task.spawn(persistContext, ctx)
		end

		if stateChanged then
			broadcastToPlayer(ctx)
		end
	end
end)

print("[TowerDefense] Server ready")
