--!strict
-- src/server/GameState.luau
-- Per-player authoritative game state. One instance is created for each
-- player who joins and destroyed when they leave. Holds:
--   * Long-term progress: gold (carries across realms), per-realm
--     highest wave (used for unlock gating), per-realm saved snapshots
--     (resumes a realm where you left off).
--   * Currently-active realm state: hp, waveNum, waveActive, gameOver,
--     inventory, realm name.
-- Only the active-realm fields are broadcast to the owning client via
-- StateUpdate; the per-realm save table and highest-wave table are
-- server-side only (they flow to the client indirectly as unlocks and
-- resume state).
--
-- This module used to be a singleton shared across every player on the
-- server — the multiplayer refactor moved all state onto per-instance
-- fields and exposed GameState.new() as the constructor. Every call
-- site that previously went through `GameState.x(...)` must now route
-- through a specific player's `gameState:x(...)`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local GamePassConfig = require(ReplicatedStorage.Shared.GamePassConfig)

-- Inventory items whose towerType matches this key are carried with the
-- player across realm transitions + Play Again resets instead of being
-- stashed per-realm. The Celestial Bastion is a Robux purchase, so it
-- would be a huge UX failure if hopping to a new realm silently locked
-- it behind the old realm's save slot.
local CELESTIAL_KEY = GamePassConfig.PREMIUM_TOWER_KEY

export type InventoryItem = {
	towerType: string,
	cost: number,
}

export type PlacedTowerSnapshot = {
	gx: number,
	gy: number,
	towerType: string,
}

-- Snapshot of a single realm's in-progress game. Stored server-side
-- when the player leaves a realm so re-entering resumes the run.
export type RealmSave = {
	hp: number,
	waveNum: number,
	waveActive: boolean,
	gameOver: boolean,
	inventory: { InventoryItem },
	towers: { PlacedTowerSnapshot },
}

export type State = {
	hp: number,
	gold: number,
	waveNum: number,
	waveActive: boolean,
	gameOver: boolean,
	inventory: { InventoryItem },
	realm: string,
	ownedGuns: { [string]: boolean },
	equippedGun: string?,
	-- True once the player has entered the admin cheat code. Flips
	-- cost checks to always-pass on the server and auto-owns every
	-- premium tower/gun. Broadcast so the client UI can hide prices.
	isAdmin: boolean,
}

export type GameState = {
	state: State,
	highestWaves: { [string]: number },
	realmSaves: { [string]: RealmSave },

	get: (self: GameState) -> State,
	getHighestWaves: (self: GameState) -> { [string]: number },
	getHighestWave: (self: GameState, realmName: string) -> number,
	updateHighestWave: (self: GameState, realmName: string, waveNum: number) -> boolean,
	damage: (self: GameState, amount: number) -> boolean,
	addGold: (self: GameState, amount: number) -> (),
	trySpend: (self: GameState, amount: number) -> boolean,
	addToInventory: (self: GameState, towerType: string, cost: number) -> (),
	removeFromInventory: (self: GameState, index: number) -> InventoryItem?,
	peekInventory: (self: GameState, index: number) -> InventoryItem?,
	setWaveActive: (self: GameState, active: boolean) -> (),
	nextWave: (self: GameState) -> (),
	saveCurrentRealm: (self: GameState, towers: { PlacedTowerSnapshot }) -> (),
	getRealmSave: (self: GameState, realmName: string) -> RealmSave?,
	clearRealmSave: (self: GameState, realmName: string) -> (),
	startRealm: (self: GameState, realmName: string) -> { PlacedTowerSnapshot },
	resetCurrentRealm: (self: GameState) -> (),
	setRealm: (self: GameState, realmName: string) -> (),
	ownsGun: (self: GameState, gunKey: string) -> boolean,
	giveGun: (self: GameState, gunKey: string) -> (),
	equipGun: (self: GameState, gunKey: string?) -> (),
	getEquippedGun: (self: GameState) -> string?,
	isAdmin: (self: GameState) -> boolean,
	setAdmin: (self: GameState, allGunKeys: { string }) -> (),
	unlockAllRealms: (self: GameState, realmNames: { string }) -> (),
}

local GameState = {}
GameState.__index = GameState

-- Construct a fresh per-player GameState. Every new player starts with
-- STARTING_HP/GOLD and the free "starter" gun owned + equipped so the
-- tutorial can teach shooting without forcing a purchase. Long-term
-- fields (gold / ownedGuns / equippedGun / highestWaves) are overwritten
-- by the caller immediately after construction if a DataStore load
-- returned non-default data.
function GameState.new(): GameState
	local self = setmetatable({}, GameState)
	self.state = {
		hp = Config.STARTING_HP,
		gold = Config.STARTING_GOLD,
		waveNum = 0,
		waveActive = false,
		gameOver = false,
		inventory = {},
		realm = "defense",
		ownedGuns = { starter = true },
		equippedGun = "starter",
		isAdmin = false,
	}
	self.highestWaves = {}
	self.realmSaves = {}
	return (self :: any) :: GameState
end

function GameState:get(): State
	return self.state
end

function GameState:getHighestWaves(): { [string]: number }
	return self.highestWaves
end

function GameState:getHighestWave(realmName: string): number
	return self.highestWaves[realmName] or 0
end

-- If the current wave number in `realmName` beats the stored best,
-- update it and return true so the caller can refresh UI.
function GameState:updateHighestWave(realmName: string, waveNum: number): boolean
	local prev = self.highestWaves[realmName] or 0
	if waveNum > prev then
		self.highestWaves[realmName] = waveNum
		return true
	end
	return false
end

function GameState:damage(amount: number): boolean
	local state = self.state
	if state.gameOver then
		return false
	end
	state.hp -= amount
	if state.hp <= 0 then
		state.hp = 0
		state.gameOver = true
		return true
	end
	return false
end

function GameState:addGold(amount: number)
	self.state.gold += amount
end

function GameState:trySpend(amount: number): boolean
	local state = self.state
	if state.gold < amount then
		return false
	end
	state.gold -= amount
	return true
end

function GameState:addToInventory(towerType: string, cost: number)
	table.insert(self.state.inventory, { towerType = towerType, cost = cost })
end

function GameState:removeFromInventory(index: number): InventoryItem?
	local inv = self.state.inventory
	if index < 1 or index > #inv then
		return nil
	end
	return table.remove(inv, index)
end

function GameState:peekInventory(index: number): InventoryItem?
	local inv = self.state.inventory
	if index < 1 or index > #inv then
		return nil
	end
	return inv[index]
end

function GameState:setWaveActive(active: boolean)
	self.state.waveActive = active
end

function GameState:nextWave()
	self.state.waveNum += 1
	self.state.waveActive = true
end

-- Save the currently active realm's state (excluding gold which is
-- global) + the list of placed towers so re-entering the realm can
-- restore it. Celestial (Robux) items are stripped from the saved
-- inventory because they travel with the player across realms rather
-- than living in any single realm's save slot — see startRealm /
-- resetCurrentRealm for the carry-over logic.
function GameState:saveCurrentRealm(towers: { PlacedTowerSnapshot })
	local state = self.state
	local savedInventory = {}
	for _, item in state.inventory do
		if item.towerType ~= CELESTIAL_KEY then
			table.insert(savedInventory, item)
		end
	end
	self.realmSaves[state.realm] = {
		hp = state.hp,
		waveNum = state.waveNum,
		waveActive = state.waveActive,
		gameOver = state.gameOver,
		inventory = savedInventory,
		towers = towers,
	}
end

-- Pluck celestial items from the player's current inventory so they can
-- be re-appended after startRealm / resetCurrentRealm replaces the
-- inventory. Returns them as a standalone list.
local function extractCelestial(state: State): { InventoryItem }
	local carry = {}
	for _, item in state.inventory do
		if item.towerType == CELESTIAL_KEY then
			table.insert(carry, item)
		end
	end
	return carry
end

function GameState:getRealmSave(realmName: string): RealmSave?
	return self.realmSaves[realmName]
end

function GameState:clearRealmSave(realmName: string)
	self.realmSaves[realmName] = nil
end

-- Begin play in `realmName`. If a saved game exists AND it's not on the
-- game-over screen, load it; otherwise start fresh. Gold is NEVER reset
-- across realm transitions — it carries over, and is topped up to
-- STARTING_GOLD on fresh entry so the player can always afford a basic
-- tower.
function GameState:startRealm(realmName: string): { PlacedTowerSnapshot }
	local state = self.state
	-- Pull any celestial items out of the current (old) inventory BEFORE
	-- we overwrite it with the new realm's save. They get re-appended
	-- below so the Robux tower survives the realm hop.
	local carriedCelestial = extractCelestial(state)

	state.realm = realmName
	local save = self.realmSaves[realmName]
	local towers: { PlacedTowerSnapshot }
	if save and not save.gameOver then
		state.hp = save.hp
		state.waveNum = save.waveNum
		state.waveActive = save.waveActive
		state.gameOver = false
		state.inventory = table.clone(save.inventory)
		if state.gold < Config.STARTING_GOLD then
			state.gold = Config.STARTING_GOLD
		end
		towers = save.towers
	else
		-- Fresh start
		state.hp = Config.STARTING_HP
		state.waveNum = 0
		state.waveActive = false
		state.gameOver = false
		state.inventory = {}
		if state.gold < Config.STARTING_GOLD then
			state.gold = Config.STARTING_GOLD
		end
		self.realmSaves[realmName] = nil
		towers = {}
	end

	for _, item in carriedCelestial do
		table.insert(state.inventory, item)
	end
	return towers
end

-- "Play Again" inside the current realm after a defeat: clear the save
-- and reset per-realm fields, but leave gold alone (topped up to the
-- minimum starter amount if the player is broke).
function GameState:resetCurrentRealm()
	local state = self.state
	-- Preserve celestial inventory items through the restart so a
	-- Robux-purchased tower isn't wiped by the Play Again flow.
	local carriedCelestial = extractCelestial(state)
	state.hp = Config.STARTING_HP
	state.waveNum = 0
	state.waveActive = false
	state.gameOver = false
	state.inventory = {}
	for _, item in carriedCelestial do
		table.insert(state.inventory, item)
	end
	if state.gold < Config.STARTING_GOLD then
		state.gold = Config.STARTING_GOLD
	end
	self.realmSaves[state.realm] = nil
end

function GameState:setRealm(realmName: string)
	self.state.realm = realmName
end

-- --- Gun shop ---

function GameState:ownsGun(gunKey: string): boolean
	return self.state.ownedGuns[gunKey] == true
end

function GameState:giveGun(gunKey: string)
	self.state.ownedGuns[gunKey] = true
end

function GameState:equipGun(gunKey: string?)
	local state = self.state
	if gunKey == nil then
		state.equippedGun = nil
		return
	end
	if state.ownedGuns[gunKey] then
		state.equippedGun = gunKey
	end
end

function GameState:getEquippedGun(): string?
	return self.state.equippedGun
end

-- --- Admin mode ---

function GameState:isAdmin(): boolean
	return self.state.isAdmin
end

-- Flip the player into admin mode: mark owned = true for every gun
-- key passed in so premium gates (starfire, void_reaper) also open.
-- Cost checks elsewhere consult `state.isAdmin` directly, so there's
-- nothing else to flip here. Gold is topped up to a huge number so
-- the gold counter visibly reflects "effectively infinite" to the
-- player — it's still decremented by purchases for consistency, but
-- they'll never notice.
function GameState:setAdmin(allGunKeys: { string })
	local state = self.state
	state.isAdmin = true
	for _, key in allGunKeys do
		state.ownedGuns[key] = true
	end
	state.gold = math.max(state.gold, 999999999)
end

-- Mark every realm in `realmNames` as having reached a wave count high
-- enough to satisfy any unlock requirement. Used by the admin cheat so
-- every portal in the lobby becomes immediately enterable.
function GameState:unlockAllRealms(realmNames: { string })
	for _, name in realmNames do
		self.highestWaves[name] = math.max(self.highestWaves[name] or 0, 9999)
	end
end

return GameState
