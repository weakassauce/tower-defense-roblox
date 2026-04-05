--!strict
-- src/shared/WaveConfig.luau
-- Wave scaling and enemy group generation. Realm-aware — pulls enemy
-- archetype data (name, color, stats multipliers) from RealmDefs so
-- different realms spawn different themed enemies.
--
-- Economy note: the realm's costMultiplier scales BOTH tower prices
-- AND per-kill gold rewards, so later realms pay out proportionally
-- more gold. That way a player who grinds the previous realm can
-- afford the more expensive towers of the next one.

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
	-- Damage dealt to the castle when this enemy reaches the end of
	-- the path. Small/swarm hits for 1, fast hits for 1, tanks/brutes
	-- hit for a lot more.
	castleDamage: number,
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

-- Per-realm difficulty multiplier applied on top of the wave scaling.
-- Each realm is about 15% harder than the previous one at the same
-- wave number: enemies in the Void Frontier have ~1.75x the HP they
-- would in Realm Defense wave-for-wave. Combined with higher tower
-- costs this keeps later realms beatable only after the player has
-- grinded earlier realms for bank.
local REALM_HP_MULT: { [string]: number } = {
	defense = 1,
	frost = 1.15,
	desert = 1.32,
	forest = 1.52,
	space = 1.75,
}

-- Extra enemy count scaling per realm so later realms throw more
-- bodies on top of the HP bump.
local REALM_COUNT_MULT: { [string]: number } = {
	defense = 1,
	frost = 1.08,
	desert = 1.16,
	forest = 1.25,
	space = 1.35,
}

function WaveConfig.get(realmName: string, waveNum: number): WaveConfig
	local realm = RealmDefs.get(realmName)
	local hpMult = REALM_HP_MULT[realmName] or 1
	local countMult = REALM_COUNT_MULT[realmName] or 1

	-- Count scaling: starts at 6 on wave 1 and grows ~2.2/wave. The old
	-- 8 + wave*3.2 produced 233 enemies on wave 15 which was impossible
	-- to chew through even with 10 basic towers. This curve keeps late
	-- waves dense (~100 enemies) without turning them into HP sponges.
	local baseCount = math.floor((6 + waveNum * 2.2) * countMult)
	local baseHP = (18 + waveNum * 12) * hpMult
	local baseSpeed = (2.5 + math.min(waveNum * 0.15, 2.5)) * SPEED_SCALE
	-- Base gold per kill scales stronger per wave (was 6 + wave/3 * 2).
	local baseReward = 8 + waveNum * 1.4
	-- Realm reward multiplier mirrors the tower cost multiplier: harder
	-- realms pay out proportionally more gold so the player can grind
	-- them for the next realm's more expensive towers and guns.
	local rewardMult = realm.costMultiplier
	local function scaledReward(raw: number): number
		return math.max(1, math.floor(raw * rewardMult))
	end

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
		reward = scaledReward(baseReward * small.rewardMult),
		castleDamage = 1,
		color = small.bodyColor,
		accentColor = small.accentColor,
		scale = small.scale,
	})

	if waveNum >= 4 then
		local fast = realm.fast
		table.insert(enemies, {
			count = math.floor(baseCount * 0.6),
			enemyType = fast.enemyType,
			silhouette = fast.silhouette,
			flourish = fast.flourish,
			realm = realm.name,
			hp = math.floor(baseHP * fast.hpMult),
			speed = baseSpeed * fast.speedMult,
			reward = scaledReward(baseReward * fast.rewardMult + 2),
			castleDamage = 1,
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
			reward = scaledReward(baseReward * tank.rewardMult),
			castleDamage = 3,
			color = tank.bodyColor,
			accentColor = tank.accentColor,
			scale = tank.scale,
		})
	end

	-- Swarm wave: at wave 5+, add a second horde of the realm's small
	-- archetype with reduced HP and smaller scale, like a fresh pack of
	-- goblins piling in behind the main group.
	if waveNum >= 5 then
		table.insert(enemies, {
			count = math.floor(baseCount * 0.7) + math.floor(waveNum * 0.5),
			enemyType = small.enemyType .. "_swarm",
			silhouette = small.silhouette,
			flourish = small.flourish,
			realm = realm.name,
			hp = math.max(1, math.floor(baseHP * small.hpMult * 0.55)),
			speed = baseSpeed * small.speedMult * 1.1,
			reward = scaledReward(baseReward * small.rewardMult * 0.55),
			castleDamage = 1,
			color = small.bodyColor,
			accentColor = small.accentColor,
			scale = small.scale * 0.85,
		})
	end

	-- Elite goblins: at wave 10+, beefy large-scale small-archetype
	-- goblins with armored colors.
	if waveNum >= 10 then
		table.insert(enemies, {
			count = 2 + math.floor((waveNum - 9) / 2),
			enemyType = small.enemyType .. "_elite",
			silhouette = small.silhouette,
			flourish = small.flourish,
			realm = realm.name,
			hp = math.floor(baseHP * small.hpMult * 2.2),
			speed = baseSpeed * small.speedMult * 0.9,
			reward = scaledReward(baseReward * small.rewardMult * 2.5),
			castleDamage = 2,
			color = small.accentColor,
			accentColor = small.bodyColor,
			scale = small.scale * 1.25,
		})
	end

	-- Raider: wave 8+, bulked-up scout archetype.
	if waveNum >= 8 then
		local fastBase = realm.fast
		table.insert(enemies, {
			count = 2 + math.floor((waveNum - 7) / 2),
			enemyType = fastBase.enemyType .. "_raider",
			silhouette = fastBase.silhouette,
			flourish = fastBase.flourish,
			realm = realm.name,
			hp = math.floor(baseHP * fastBase.hpMult * 1.9),
			speed = baseSpeed * fastBase.speedMult * 0.85,
			reward = scaledReward(baseReward * fastBase.rewardMult * 2),
			castleDamage = 2,
			color = fastBase.accentColor,
			accentColor = fastBase.bodyColor,
			scale = fastBase.scale * 1.3,
		})
	end

	-- Brute: wave 12+, oversized tank variant. Walls of meat that
	-- devastate the castle on impact.
	if waveNum >= 12 then
		local tankBase = realm.tank
		table.insert(enemies, {
			count = 1 + math.floor((waveNum - 11) / 3),
			enemyType = tankBase.enemyType .. "_brute",
			silhouette = tankBase.silhouette,
			flourish = tankBase.flourish,
			realm = realm.name,
			hp = math.floor(baseHP * tankBase.hpMult * 1.5),
			speed = baseSpeed * tankBase.speedMult * 0.8,
			reward = scaledReward(baseReward * tankBase.rewardMult * 1.8),
			castleDamage = 5,
			color = tankBase.accentColor,
			accentColor = tankBase.bodyColor,
			scale = tankBase.scale * 1.3,
		})
	end

	-- Mega horde: wave 6+, a third swarm of the small archetype with
	-- cycled accent colors so late waves feel like a genuine mass event
	-- instead of just re-running the main group. Smaller scale and
	-- reduced HP keeps the individual kills cheap but the total count
	-- high.
	if waveNum >= 6 then
		table.insert(enemies, {
			count = math.floor(baseCount * 0.55) + math.floor(waveNum * 0.4),
			enemyType = small.enemyType .. "_horde",
			silhouette = small.silhouette,
			flourish = small.flourish,
			realm = realm.name,
			hp = math.max(1, math.floor(baseHP * small.hpMult * 0.45)),
			speed = baseSpeed * small.speedMult * 1.15,
			reward = scaledReward(baseReward * small.rewardMult * 0.5),
			castleDamage = 1,
			color = small.accentColor,
			accentColor = small.bodyColor,
			scale = small.scale * 0.8,
		})
	end

	-- Berserker: wave 9+, fast tank. Bridges the gap between scouts and
	-- tanks with high HP but above-normal speed. Great threat at mid-game.
	if waveNum >= 9 then
		local fastBase = realm.fast
		local tankBase = realm.tank
		table.insert(enemies, {
			count = 1 + math.floor((waveNum - 8) / 2),
			enemyType = fastBase.enemyType .. "_berserker",
			silhouette = fastBase.silhouette,
			flourish = fastBase.flourish,
			realm = realm.name,
			hp = math.floor(baseHP * tankBase.hpMult * 0.8),
			speed = baseSpeed * fastBase.speedMult * 1.1,
			reward = scaledReward(baseReward * fastBase.rewardMult * 2.2),
			castleDamage = 2,
			color = tankBase.bodyColor,
			accentColor = fastBase.accentColor,
			scale = fastBase.scale * 1.15,
		})
	end

	-- Champion: wave 14+, a single heavily-buffed tank with max HP
	-- mod and max castle damage. Mini-boss per wave.
	if waveNum >= 14 then
		local tankBase = realm.tank
		table.insert(enemies, {
			count = 1 + math.floor((waveNum - 13) / 4),
			enemyType = tankBase.enemyType .. "_champion",
			silhouette = tankBase.silhouette,
			flourish = tankBase.flourish,
			realm = realm.name,
			hp = math.floor(baseHP * tankBase.hpMult * 2.6),
			speed = baseSpeed * tankBase.speedMult * 0.75,
			reward = scaledReward(baseReward * tankBase.rewardMult * 3),
			castleDamage = 8,
			color = tankBase.bodyColor,
			accentColor = Color3.fromRGB(255, 215, 80),
			scale = tankBase.scale * 1.55,
		})
	end

	return {
		enemies = enemies,
		spawnInterval = math.max(0.3, 1.1 - waveNum * 0.05),
	}
end

return WaveConfig
