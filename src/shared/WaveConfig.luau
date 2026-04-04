--!strict
-- src/shared/WaveConfig.luau
-- Wave scaling and enemy group generation. Ported from getWaveConfig in
-- config.js.

export type EnemyGroup = {
	count: number,
	enemyType: string, -- "goblin" | "scout" | "troll"
	hp: number,
	speed: number, -- studs per second
	reward: number,
	color: Color3,
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

function WaveConfig.get(waveNum: number): WaveConfig
	local baseCount = 3 + math.floor(waveNum * 1.5)
	local baseHP = 18 + waveNum * 12
	local baseSpeed = (2.5 + math.min(waveNum * 0.15, 2.5)) * SPEED_SCALE
	local reward = 6 + math.floor(waveNum / 3) * 2

	local enemies: { EnemyGroup } = {}

	table.insert(enemies, {
		count = baseCount,
		enemyType = "goblin",
		hp = baseHP,
		speed = baseSpeed,
		reward = reward,
		color = Color3.fromRGB(85, 139, 47),
		scale = 0.65,
	})

	if waveNum >= 4 then
		table.insert(enemies, {
			count = math.floor(baseCount * 0.5),
			enemyType = "scout",
			hp = math.floor(baseHP * 0.5),
			speed = baseSpeed * 1.6,
			reward = reward + 2,
			color = Color3.fromRGB(251, 192, 45),
			scale = 0.55,
		})
	end

	if waveNum >= 7 then
		table.insert(enemies, {
			count = math.max(1, math.floor((waveNum - 5) / 2)),
			enemyType = "troll",
			hp = baseHP * 3,
			speed = baseSpeed * 0.55,
			reward = reward * 3,
			color = Color3.fromRGB(106, 27, 154),
			scale = 0.95,
		})
	end

	return {
		enemies = enemies,
		spawnInterval = math.max(0.4, 1.2 - waveNum * 0.04),
	}
end

return WaveConfig
