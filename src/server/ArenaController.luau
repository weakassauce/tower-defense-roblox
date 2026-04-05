--!strict
-- src/server/ArenaController.luau
-- Per-player owner for everything that makes up one player's private
-- arena: the workspace folder containing Map / Castle / Towers /
-- Projectiles / Enemies, a GameState instance, and the per-arena
-- EnemyManager / TowerManager / WaveController / CastleContext.
--
-- Each arena is placed at a world-space slot offset (see
-- PlayerSlot.offsetFor) so multiple players' arenas can exist in the
-- same workspace without visually overlapping. The shared lobby lives
-- at its own fixed location and is not owned by this module.
--
-- Lifecycle:
--   local ctrl = ArenaController.new(player, slotOffset, gameState)
--   ctrl:enterRealm("frost")      -- build frost arena + teleport pos
--   ctrl:update(dt)               -- called every Heartbeat by main loop
--   ctrl:returnToLobby()          -- stash current realm, hide arena
--   ctrl:destroy()                -- disconnect cleanup

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local RealmDefs = require(ReplicatedStorage.Shared.RealmDefs)

local GameState = require(script.Parent.GameState)
local EnemyManager = require(script.Parent.EnemyManager)
local TowerManager = require(script.Parent.TowerManager)
local WaveController = require(script.Parent.WaveController)
local Castle = require(script.Parent.Castle)
local Map = require(script.Parent.Map)

local ArenaController = {}
ArenaController.__index = ArenaController

export type ArenaController = {
	player: Player,
	slotOffset: Vector3,
	gameState: GameState.GameState,
	root: Folder,
	realmName: string?,
	mapData: Map.MapData?,
	castleCtx: Castle.CastleContext?,
	enemyMgr: EnemyManager.EnemyManager?,
	towerMgr: TowerManager.TowerManager?,
	waveCtrl: WaveController.WaveController?,
	pathSet: { [string]: boolean },

	enterRealm: (self: ArenaController, realmName: string) -> (),
	returnToLobby: (self: ArenaController) -> (),
	update: (self: ArenaController, dt: number) -> number,
	isPath: (self: ArenaController, gx: number, gy: number) -> boolean,
	getArenaSpawnCFrame: (self: ArenaController) -> CFrame,
	stashCurrentRealm: (self: ArenaController) -> (),
	resetCurrentRealm: (self: ArenaController) -> (),
	destroy: (self: ArenaController) -> (),
}

-- Build a per-realm path set ({ "gx,gy" → true }) that the server uses
-- to validate tower placements against path cells. Each arena owns its
-- own copy so concurrent arenas in different realms don't stomp each
-- other the way the old Config.PATH singleton did.
local function buildPathSet(path: { { number } }): { [string]: boolean }
	local set = {}
	for _, coord in path do
		set[coord[1] .. "," .. coord[2]] = true
	end
	return set
end

-- Tear down every child of a folder but leave the folder itself in
-- place — used when switching realms so the arena's workspace root
-- persists while its contents get rebuilt fresh.
local function clearChildren(folder: Instance)
	for _, child in folder:GetChildren() do
		child:Destroy()
	end
end

function ArenaController.new(
	player: Player,
	slotOffset: Vector3,
	gameState: GameState.GameState
): ArenaController
	local root = Instance.new("Folder")
	root.Name = "PlayerArena_" .. player.UserId
	root.Parent = workspace

	local self = setmetatable({
		player = player,
		slotOffset = slotOffset,
		gameState = gameState,
		root = root,
		realmName = nil,
		mapData = nil,
		castleCtx = nil,
		enemyMgr = nil,
		towerMgr = nil,
		waveCtrl = nil,
		pathSet = {},
	}, ArenaController)
	return (self :: any) :: ArenaController
end

-- Build `realmName`'s arena under this player's slot. Destroys any
-- existing arena contents first, stashing the previous realm's save so
-- re-entering it later resumes where the player left off.
function ArenaController.enterRealm(self: ArenaController, realmName: string)
	-- Stash previous realm before destroying its folders.
	if self.realmName and self.towerMgr then
		self.gameState:saveCurrentRealm(self.towerMgr:snapshot())
	end

	clearChildren(self.root)
	self.enemyMgr = nil
	self.towerMgr = nil
	self.waveCtrl = nil
	self.castleCtx = nil
	self.mapData = nil

	local realmDef = RealmDefs.get(realmName)
	self.realmName = realmName
	self.pathSet = buildPathSet(realmDef.path)

	-- Config.PATH is a shared module-level value used by gridToWorld /
	-- isPath helpers inside the Map + MapThemes builders. We temporarily
	-- point it at this realm's path for the duration of Map.build, which
	-- is atomic (no yields) so concurrent arenas can't race on it. The
	-- server's own path validation doesn't rely on Config.PATH — we use
	-- self.pathSet, which is per-arena — so this is only for the build.
	Config.setCurrentPath(realmDef.path)

	local mapData = Map.build(realmName, self.root, self.slotOffset)
	self.mapData = mapData

	local castleCtx, extraWaypoints =
		Castle.build(mapData.castleCenter, Config.STARTING_HP, realmName, self.root)
	self.castleCtx = castleCtx
	for _, wp in extraWaypoints do
		table.insert(mapData.waypoints, wp)
	end

	local enemyMgr = EnemyManager.new(mapData.waypoints, self.root)
	self.enemyMgr = enemyMgr

	local towerMgr = TowerManager.new(self.root, self.slotOffset, enemyMgr)
	self.towerMgr = towerMgr

	local waveCtrl = WaveController.new(self.gameState, enemyMgr)
	self.waveCtrl = waveCtrl

	-- Load saved per-realm progress into the GameState and restore any
	-- previously-placed towers. Returns [] on a fresh start.
	local savedTowers = self.gameState:startRealm(realmName)
	towerMgr:restoreFrom(savedTowers)
	Castle.updateHp(castleCtx, self.gameState:get().hp, Config.STARTING_HP)
end

-- Stash current realm progress + tear down folder contents. The root
-- folder stays in place so re-entering a realm can rebuild inside it.
-- GameState's active-realm fields are left as-is; the next enterRealm
-- call will overwrite them via startRealm.
function ArenaController.returnToLobby(self: ArenaController)
	if self.realmName and self.towerMgr then
		self.gameState:saveCurrentRealm(self.towerMgr:snapshot())
	end
	clearChildren(self.root)
	self.enemyMgr = nil
	self.towerMgr = nil
	self.waveCtrl = nil
	self.castleCtx = nil
	self.mapData = nil
	self.realmName = nil
	self.pathSet = {}
end

-- Snapshot the currently-active realm without tearing anything down.
-- Used by the main loop's auto-save path so progress persists mid-game
-- without forcing the player out of their arena.
function ArenaController.stashCurrentRealm(self: ArenaController)
	if self.realmName and self.towerMgr then
		self.gameState:saveCurrentRealm(self.towerMgr:snapshot())
	end
end

-- Play Again flow after a defeat: clear the in-memory per-realm save,
-- reset the GameState's active-realm fields, and rebuild the current
-- realm from scratch (map + castle + fresh towers list). Gold carries.
function ArenaController.resetCurrentRealm(self: ArenaController)
	local realmName = self.realmName
	if not realmName then
		return
	end
	self.gameState:clearRealmSave(realmName)
	self.gameState:resetCurrentRealm()
	-- Rebuild the realm from a clean slate.
	self:enterRealm(realmName)
end

-- Runs one tick of this arena's simulation. Returns the bonus gold
-- granted if a wave just finished (caller broadcasts WaveComplete).
function ArenaController.update(self: ArenaController, dt: number): number
	local enemyMgr = self.enemyMgr
	local towerMgr = self.towerMgr
	local waveCtrl = self.waveCtrl
	if not enemyMgr or not towerMgr or not waveCtrl then
		return 0
	end

	towerMgr:update(dt)
	enemyMgr:update(dt)
	local bonus = waveCtrl:update(dt)
	return bonus
end

-- Server-side path validation. Each arena owns its own path set so
-- two players in different realms can validate placements against
-- their own paths simultaneously. Tower-placement handlers go through
-- this instead of Config.isPath.
function ArenaController.isPath(self: ArenaController, gx: number, gy: number): boolean
	return self.pathSet[gx .. "," .. gy] == true
end

-- Where to teleport the player's character when they enter this
-- arena. Positioned so they face the path looking east — same as the
-- single-player origin, just shifted by the slot offset.
function ArenaController.getArenaSpawnCFrame(self: ArenaController): CFrame
	return CFrame.new(Vector3.new(0, 8, 0) + self.slotOffset)
end

-- Full teardown on player disconnect. Destroys the workspace folder
-- (and everything in it) so nothing leaks between joins.
function ArenaController.destroy(self: ArenaController)
	if self.root and self.root.Parent then
		self.root:Destroy()
	end
	self.enemyMgr = nil
	self.towerMgr = nil
	self.waveCtrl = nil
	self.castleCtx = nil
	self.mapData = nil
	self.realmName = nil
	self.pathSet = {}
end

return ArenaController
