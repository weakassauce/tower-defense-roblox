--!strict
-- src/server/GameState.luau
-- Authoritative game state — hp, gold, wave, inventory. All mutations
-- flow through this module so the server can broadcast coherent updates
-- to the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local GameState = {}

export type InventoryItem = {
	towerType: string,
	cost: number,
}

export type State = {
	hp: number,
	gold: number,
	waveNum: number,
	waveActive: boolean,
	gameOver: boolean,
	inventory: { InventoryItem },
}

local state: State = {
	hp = Config.STARTING_HP,
	gold = Config.STARTING_GOLD,
	waveNum = 0,
	waveActive = false,
	gameOver = false,
	inventory = {},
}

function GameState.get(): State
	return state
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

function GameState.reset()
	state.hp = Config.STARTING_HP
	state.gold = Config.STARTING_GOLD
	state.waveNum = 0
	state.waveActive = false
	state.gameOver = false
	state.inventory = {}
end

return GameState
