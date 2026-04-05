--!strict
-- src/server/GameState.luau
-- Authoritative game state. Holds:
--   * Global player progress: gold (carries across realms), per-realm
--     highest wave (used for unlock gating), per-realm saved snapshots
--     (resumes a realm where you left off).
--   * Currently-active realm state: hp, waveNum, waveActive, gameOver,
--     inventory, realm name.
-- Only the active-realm fields are broadcast to clients; the per-realm
-- save table is server-side only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local GameState = {}

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
}

-- Public client-facing fields (what StateUpdate broadcasts).
local state: State = {
	hp = Config.STARTING_HP,
	gold = Config.STARTING_GOLD,
	waveNum = 0,
	waveActive = false,
	gameOver = false,
	inventory = {},
	realm = "defense",
	ownedGuns = {},
	equippedGun = nil,
}

-- Server-only progress: best wave reached per realm (for unlocks) and
-- the most recent saved game per realm (for resume-on-re-enter).
local highestWaves: { [string]: number } = {}
local realmSaves: { [string]: RealmSave } = {}

function GameState.get(): State
	return state
end

function GameState.getHighestWaves(): { [string]: number }
	return highestWaves
end

function GameState.getHighestWave(realmName: string): number
	return highestWaves[realmName] or 0
end

-- If the current wave number in `realmName` beats the stored best,
-- update it and return true so the caller can refresh UI.
function GameState.updateHighestWave(realmName: string, waveNum: number): boolean
	local prev = highestWaves[realmName] or 0
	if waveNum > prev then
		highestWaves[realmName] = waveNum
		return true
	end
	return false
end

function GameState.damage(amount: number): boolean
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

function GameState.addGold(amount: number)
	state.gold += amount
end

function GameState.trySpend(amount: number): boolean
	if state.gold < amount then
		return false
	end
	state.gold -= amount
	return true
end

function GameState.addToInventory(towerType: string, cost: number)
	table.insert(state.inventory, { towerType = towerType, cost = cost })
end

function GameState.removeFromInventory(index: number): InventoryItem?
	if index < 1 or index > #state.inventory then
		return nil
	end
	return table.remove(state.inventory, index)
end

function GameState.setWaveActive(active: boolean)
	state.waveActive = active
end

function GameState.nextWave()
	state.waveNum += 1
	state.waveActive = true
end

-- Save the currently active realm's state (excluding gold which is
-- global) + the list of placed towers so re-entering the realm can
-- restore it.
function GameState.saveCurrentRealm(towers: { PlacedTowerSnapshot })
	realmSaves[state.realm] = {
		hp = state.hp,
		waveNum = state.waveNum,
		waveActive = state.waveActive,
		gameOver = state.gameOver,
		inventory = table.clone(state.inventory),
		towers = towers,
	}
end

function GameState.getRealmSave(realmName: string): RealmSave?
	return realmSaves[realmName]
end

function GameState.clearRealmSave(realmName: string)
	realmSaves[realmName] = nil
end

-- Begin play in `realmName`. If a saved game exists AND it's not on the
-- game-over screen, load it; otherwise start fresh. Gold is NEVER reset
-- across realm transitions — it carries over, and is topped up to
-- STARTING_GOLD on fresh entry so the player can always afford a basic
-- tower.
function GameState.startRealm(realmName: string): { PlacedTowerSnapshot }
	state.realm = realmName
	local save = realmSaves[realmName]
	if save and not save.gameOver then
		state.hp = save.hp
		state.waveNum = save.waveNum
		state.waveActive = save.waveActive
		state.gameOver = false
		state.inventory = table.clone(save.inventory)
		if state.gold < Config.STARTING_GOLD then
			state.gold = Config.STARTING_GOLD
		end
		return save.towers
	end
	-- Fresh start
	state.hp = Config.STARTING_HP
	state.waveNum = 0
	state.waveActive = false
	state.gameOver = false
	state.inventory = {}
	if state.gold < Config.STARTING_GOLD then
		state.gold = Config.STARTING_GOLD
	end
	realmSaves[realmName] = nil
	return {}
end

-- "Play Again" inside the current realm after a defeat: clear the save
-- and reset per-realm fields, but leave gold alone (topped up to the
-- minimum starter amount if the player is broke).
function GameState.resetCurrentRealm()
	state.hp = Config.STARTING_HP
	state.waveNum = 0
	state.waveActive = false
	state.gameOver = false
	state.inventory = {}
	if state.gold < Config.STARTING_GOLD then
		state.gold = Config.STARTING_GOLD
	end
	realmSaves[state.realm] = nil
end

function GameState.setRealm(realmName: string)
	state.realm = realmName
end

-- --- Gun shop ---

function GameState.ownsGun(gunKey: string): boolean
	return state.ownedGuns[gunKey] == true
end

function GameState.giveGun(gunKey: string)
	state.ownedGuns[gunKey] = true
end

function GameState.equipGun(gunKey: string?)
	if gunKey == nil then
		state.equippedGun = nil
		return
	end
	if state.ownedGuns[gunKey] then
		state.equippedGun = gunKey
	end
end

function GameState.getEquippedGun(): string?
	return state.equippedGun
end

return GameState
