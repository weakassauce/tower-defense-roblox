--!strict
-- src/server/WaveController.luau
-- Manages wave lifecycle: starts a wave, trickles enemies from a spawn
-- queue at the configured interval, and reports when the wave completes
-- so the caller can pay the bonus and broadcast state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WaveConfig = require(ReplicatedStorage.Shared.WaveConfig)

local EnemyManager = require(script.Parent.EnemyManager)
local GameState = require(script.Parent.GameState)

local WaveController = {}

type SpawnEntry = {
	enemyType: string,
	silhouette: string,
	flourish: string,
	realm: string,
	hp: number,
	speed: number,
	reward: number,
	color: Color3,
	accentColor: Color3,
	scale: number,
}

local spawnQueue: { SpawnEntry } = {}
local spawnTimer = 0
local spawnInterval = 1

function WaveController.startWave(): boolean
	local state = GameState.get()
	if state.waveActive or state.gameOver then
		return false
	end

	GameState.nextWave()

	local waveCfg = WaveConfig.get(state.realm, state.waveNum)
	spawnInterval = waveCfg.spawnInterval
	spawnTimer = 0
	spawnQueue = {}

	for _, group in waveCfg.enemies do
		for _ = 1, group.count do
			table.insert(spawnQueue, {
				enemyType = group.enemyType,
				silhouette = group.silhouette,
				flourish = group.flourish,
				realm = group.realm,
				hp = group.hp,
				speed = group.speed,
				reward = group.reward,
				color = group.color,
				accentColor = group.accentColor,
				scale = group.scale,
			})
		end
	end

	-- Shuffle so enemy types mix during the wave
	for i = #spawnQueue, 2, -1 do
		local j = math.random(1, i)
		spawnQueue[i], spawnQueue[j] = spawnQueue[j], spawnQueue[i]
	end

	return true
end

-- Returns the bonus gold granted if the wave just ended on this tick, else 0.
function WaveController.update(dt: number): number
	local state = GameState.get()
	if not state.waveActive or state.gameOver then
		return 0
	end

	if #spawnQueue > 0 then
		spawnTimer -= dt
		if spawnTimer <= 0 then
			local entry = table.remove(spawnQueue, 1) :: SpawnEntry
			EnemyManager.spawn({
				enemyType = entry.enemyType,
				silhouette = entry.silhouette,
				flourish = entry.flourish,
				realm = entry.realm,
				hp = entry.hp,
				speed = entry.speed,
				reward = entry.reward,
				color = entry.color,
				accentColor = entry.accentColor,
				scale = entry.scale,
			})
			spawnTimer = spawnInterval
		end
	end

	-- Wave is complete when the spawn queue is empty and no enemies are left alive
	if #spawnQueue == 0 and #EnemyManager.getAlive() == 0 then
		GameState.setWaveActive(false)
		local bonus = 25 + state.waveNum * 6
		GameState.addGold(bonus)
		return bonus
	end

	return 0
end

function WaveController.reset()
	spawnQueue = {}
	spawnTimer = 0
end

return WaveController
