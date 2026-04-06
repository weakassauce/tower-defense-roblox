--!strict
-- src/server/WaveController.luau
-- Manages one arena's wave lifecycle: starts a wave, trickles enemies
-- from a spawn queue at the configured interval, and reports when the
-- wave completes so the caller can pay the bonus and broadcast state.
--
-- Instantiated per arena via WaveController.new(gameState, enemyMgr) so
-- multiple players can run concurrent waves in their own arenas. Was a
-- module-level singleton before the multiplayer refactor.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WaveConfig = require(ReplicatedStorage.Shared.WaveConfig)

local EnemyManager = require(script.Parent.EnemyManager)
local GameState = require(script.Parent.GameState)

local WaveController = {}
WaveController.__index = WaveController

type SpawnEntry = {
	enemyType: string,
	silhouette: string,
	flourish: string,
	realm: string,
	hp: number,
	speed: number,
	reward: number,
	castleDamage: number,
	color: Color3,
	accentColor: Color3,
	scale: number,
}

export type WaveController = {
	gameState: GameState.GameState,
	enemyMgr: EnemyManager.EnemyManager,
	spawnQueue: { SpawnEntry },
	spawnTimer: number,
	spawnInterval: number,

	startWave: (self: WaveController) -> boolean,
	update: (self: WaveController, dt: number) -> number,
	reset: (self: WaveController) -> (),
}

-- Build a new WaveController for this arena. Holds references to the
-- arena's GameState (for reading the active realm/wave number and
-- crediting bonus gold) and EnemyManager (for actually spawning the
-- enemies queued up by startWave). No spatial concerns — offsets are
-- the EnemyManager's responsibility via its waypoints.
function WaveController.new(
	gameState: GameState.GameState,
	enemyMgr: EnemyManager.EnemyManager
): WaveController
	local self = setmetatable({
		gameState = gameState,
		enemyMgr = enemyMgr,
		spawnQueue = {} :: { SpawnEntry },
		spawnTimer = 0,
		spawnInterval = 1,
	}, WaveController)
	return (self :: any) :: WaveController
end

function WaveController.startWave(self: WaveController): boolean
	local state = self.gameState:get()
	if state.waveActive or state.gameOver then
		return false
	end

	self.gameState:nextWave()

	local waveCfg = WaveConfig.get(state.realm, state.waveNum)
	self.spawnInterval = waveCfg.spawnInterval
	self.spawnTimer = 0
	self.spawnQueue = {}

	for _, group in waveCfg.enemies do
		for _ = 1, group.count do
			table.insert(self.spawnQueue, {
				enemyType = group.enemyType,
				silhouette = group.silhouette,
				flourish = group.flourish,
				realm = group.realm,
				hp = group.hp,
				speed = group.speed,
				reward = group.reward,
				castleDamage = group.castleDamage,
				color = group.color,
				accentColor = group.accentColor,
				scale = group.scale,
			})
		end
	end

	-- Shuffle so enemy types mix during the wave
	for i = #self.spawnQueue, 2, -1 do
		local j = math.random(1, i)
		self.spawnQueue[i], self.spawnQueue[j] = self.spawnQueue[j], self.spawnQueue[i]
	end

	return true
end

-- Returns the bonus gold granted if the wave just ended on this tick, else 0.
function WaveController.update(self: WaveController, dt: number): number
	local state = self.gameState:get()
	if not state.waveActive or state.gameOver then
		return 0
	end

	if #self.spawnQueue > 0 then
		self.spawnTimer -= dt
		if self.spawnTimer <= 0 then
			local entry = table.remove(self.spawnQueue, 1) :: SpawnEntry
			self.enemyMgr:spawn({
				enemyType = entry.enemyType,
				silhouette = entry.silhouette,
				flourish = entry.flourish,
				realm = entry.realm,
				hp = entry.hp,
				speed = entry.speed,
				reward = entry.reward,
				castleDamage = entry.castleDamage,
				color = entry.color,
				accentColor = entry.accentColor,
				scale = entry.scale,
			})
			self.spawnTimer = self.spawnInterval
		end
	end

	-- Wave is complete when the spawn queue is empty and no enemies are left alive
	if #self.spawnQueue == 0 and #self.enemyMgr:getAlive() == 0 then
		self.gameState:setWaveActive(false)
		local bonus = 15 + state.waveNum * 3
		self.gameState:addGold(bonus)
		return bonus
	end

	return 0
end

function WaveController.reset(self: WaveController)
	self.spawnQueue = {}
	self.spawnTimer = 0
end

return WaveController
