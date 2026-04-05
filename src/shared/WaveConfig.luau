--!strict
-- src/shared/WaveConfig.luau
-- Wave scaling and enemy group generation. Realm-aware — pulls enemy
-- archetype data (name, color, stats multipliers) from RealmDefs so
-- different realms spawn different themed enemies.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RealmDefs = require(ReplicatedStorage.Shared.RealmDefs)

export type EnemyGroup = {
	count: number,
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

export type WaveConfig = {
	enemies: { EnemyGroup },
	spawnInterval: number,
}

local WaveConfig = {}

-- Roblox uses 8 studs per cell vs 2 world units in Three.js, so enemy speeds
-- are scaled up 4x to traverse the grid at the same apparent pace.
local SPEED_SCALE = 4

function WaveConfig.get(realmName: string, waveNum: number): WaveConfig
	local realm = RealmDefs.get(realmName)

	local baseCount = 3 + math.floor(waveNum * 1.5)
	local baseHP = 18 + waveNum * 12
	local baseSpeed = (2.5 + math.min(waveNum * 0.15, 2.5)) * SPEED_SCALE
	local reward = 6 + math.floor(waveNum / 3) * 2

	local enemies: { EnemyGroup } = {}

	local small = realm.small
	table.insert(enemies, {
		count = baseCount,
		enemyType = small.enemyType,
		silhouette = small.silhouette,
		flourish = small.flourish,
		realm = realm.name,
		hp = math.floor(baseHP * small.hpMult),
		speed = baseSpeed * small.speedMult,
		reward = math.max(1, math.floor(reward * small.rewardMult)),
		color = small.bodyColor,
		accentColor = small.accentColor,
		scale = small.scale,
	})

	if waveNum >= 4 then
		local fast = realm.fast
		table.insert(enemies, {
			count = math.floor(baseCount * 0.5),
			enemyType = fast.enemyType,
			silhouette = fast.silhouette,
			flourish = fast.flourish,
			realm = realm.name,
			hp = math.floor(baseHP * fast.hpMult),
			speed = baseSpeed * fast.speedMult,
			reward = math.max(1, math.floor(reward * fast.rewardMult)) + 2,
			color = fast.bodyColor,
			accentColor = fast.accentColor,
			scale = fast.scale,
		})
	end

	if waveNum >= 7 then
		local tank = realm.tank
		table.insert(enemies, {
			count = math.max(1, math.floor((waveNum - 5) / 2)),
			enemyType = tank.enemyType,
			silhouette = tank.silhouette,
			flourish = tank.flourish,
			realm = realm.name,
			hp = math.floor(baseHP * tank.hpMult),
			speed = baseSpeed * tank.speedMult,
			reward = math.max(1, math.floor(reward * tank.rewardMult)),
			color = tank.bodyColor,
			accentColor = tank.accentColor,
			scale = tank.scale,
		})
	end

	return {
		enemies = enemies,
		spawnInterval = math.max(0.4, 1.2 - waveNum * 0.04),
	}
end

return WaveConfig
