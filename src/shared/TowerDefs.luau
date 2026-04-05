--!strict
-- src/shared/TowerDefs.luau
-- Static per-type tower stats. Ported from TOWER_DEFS in config.js.

export type TowerDef = {
	name: string,
	icon: string,
	cost: number,
	range: number, -- studs
	damage: number,
	fireRate: number, -- shots per second
	color: Color3,
	accent: Color3,
	projectileSpeed: number,
	projectileColor: Color3,
	splash: number, -- 0 for no splash
	slowFactor: number?,
	slowDuration: number?,
	poisonDps: number?,
	poisonDuration: number?,
	chain: number?,
	chainRange: number?,
}

-- Three.js used small world units (~2 per cell). In Roblox we use 8 studs
-- per cell, so ranges/speeds are scaled up by 4x.
local SCALE = 4

local TowerDefs: { [string]: TowerDef } = {
	basic = {
		name = "Archer Tower",
		icon = "🏹",
		cost = 60, -- 14.4 DPS x ~4

		range = 5 * SCALE,
		damage = 12,
		fireRate = 1.2,
		color = Color3.fromRGB(158, 158, 158),
		accent = Color3.fromRGB(211, 47, 47),
		projectileSpeed = 28 * SCALE,
		projectileColor = Color3.fromRGB(255, 183, 77),
		splash = 0,
	},
	sniper = {
		name = "Wizard Tower",
		icon = "🔮",
		cost = 80, -- 20.25 DPS x ~4

		range = 11 * SCALE,
		damage = 45,
		fireRate = 0.45,
		color = Color3.fromRGB(94, 53, 177),
		accent = Color3.fromRGB(255, 241, 118),
		projectileSpeed = 50 * SCALE,
		projectileColor = Color3.fromRGB(225, 190, 231),
		splash = 0,
	},
	cannon = {
		name = "Cannon Bunker",
		icon = "💣",
		cost = 100, -- 18.2 DPS x ~4 + splash bonus

		range = 6 * SCALE,
		damage = 28,
		fireRate = 0.65,
		color = Color3.fromRGB(62, 39, 35),
		accent = Color3.fromRGB(255, 111, 0),
		projectileSpeed = 15 * SCALE,
		projectileColor = Color3.fromRGB(33, 33, 33),
		splash = 3 * SCALE,
	},
	freeze = {
		name = "Frost Spire",
		icon = "❄️",
		cost = 50, -- 4.5 DPS x ~4 + slow utility bonus

		range = 5 * SCALE,
		damage = 5,
		fireRate = 0.9,
		color = Color3.fromRGB(79, 195, 247),
		accent = Color3.fromRGB(225, 245, 254),
		projectileSpeed = 20 * SCALE,
		projectileColor = Color3.fromRGB(179, 229, 252),
		splash = 0,
		slowFactor = 0.4,
		slowDuration = 2.5,
	},
	lightning = {
		name = "Storm Tower",
		icon = "⚡",
		cost = 85, -- 12.8 DPS x ~4 + chain bonus

		range = 7 * SCALE,
		damage = 16,
		fireRate = 0.8,
		color = Color3.fromRGB(30, 136, 229),
		accent = Color3.fromRGB(128, 216, 255),
		projectileSpeed = 60 * SCALE,
		projectileColor = Color3.fromRGB(225, 245, 254),
		splash = 0,
		chain = 2,
		chainRange = 4 * SCALE,
	},
	poison = {
		name = "Alchemist Tower",
		icon = "🧪",
		cost = 50, -- 4 DPS x ~4 + DoT bonus

		range = 5 * SCALE,
		damage = 4,
		fireRate = 1.0,
		color = Color3.fromRGB(85, 139, 47),
		accent = Color3.fromRGB(174, 234, 0),
		projectileSpeed = 22 * SCALE,
		projectileColor = Color3.fromRGB(174, 234, 0),
		splash = 0,
		poisonDps = 4,
		poisonDuration = 4,
	},
	flame = {
		name = "Inferno Tower",
		icon = "🔥",
		cost = 75, -- 13.2 DPS x ~4 + splash bonus

		range = 4 * SCALE,
		damage = 6,
		fireRate = 2.2,
		color = Color3.fromRGB(191, 54, 12),
		accent = Color3.fromRGB(255, 171, 0),
		projectileSpeed = 24 * SCALE,
		projectileColor = Color3.fromRGB(255, 110, 64),
		splash = 1.5 * SCALE,
	},

	-- --- Realm signature towers ---
	-- Each realm has exactly one exclusive tower that only becomes
	-- buildable when the player is inside that realm.

	paladin = {
		name = "Paladin Hall", -- signature tower: Realm Defense
		icon = "🛡️",
		cost = 160,
		range = 6 * SCALE,
		damage = 55,
		fireRate = 0.55,
		color = Color3.fromRGB(230, 200, 130),
		accent = Color3.fromRGB(255, 236, 179),
		projectileSpeed = 40 * SCALE,
		projectileColor = Color3.fromRGB(255, 247, 200),
		splash = 2.2 * SCALE,
	},
	icelance = {
		name = "Ice Lance", -- signature tower: Frost Kingdom
		icon = "🧊",
		cost = 140,
		range = 9 * SCALE,
		damage = 34,
		fireRate = 0.7,
		color = Color3.fromRGB(129, 212, 250),
		accent = Color3.fromRGB(225, 245, 254),
		projectileSpeed = 75 * SCALE,
		projectileColor = Color3.fromRGB(225, 245, 254),
		splash = 0,
		slowFactor = 0.3,
		slowDuration = 3,
	},
	sandstorm = {
		name = "Sandstorm Caster", -- signature tower: Desert Wastes
		icon = "🌪️",
		cost = 150,
		range = 6 * SCALE,
		damage = 10,
		fireRate = 1.4,
		color = Color3.fromRGB(200, 160, 80),
		accent = Color3.fromRGB(255, 213, 79),
		projectileSpeed = 28 * SCALE,
		projectileColor = Color3.fromRGB(255, 224, 130),
		splash = 2.5 * SCALE,
		slowFactor = 0.55,
		slowDuration = 2,
		poisonDps = 6,
		poisonDuration = 3,
	},
	thornwall = {
		name = "Thornwall Druid", -- signature tower: Dark Forest
		icon = "🌿",
		cost = 145,
		range = 7 * SCALE,
		damage = 22,
		fireRate = 0.9,
		color = Color3.fromRGB(85, 139, 47),
		accent = Color3.fromRGB(174, 234, 0),
		projectileSpeed = 40 * SCALE,
		projectileColor = Color3.fromRGB(174, 234, 0),
		splash = 0,
		poisonDps = 8,
		poisonDuration = 4,
		chain = 3,
		chainRange = 4 * SCALE,
	},
	plasma = {
		name = "Plasma Cannon", -- signature tower: Void Frontier
		icon = "🛸",
		cost = 170,
		range = 8 * SCALE,
		damage = 42,
		fireRate = 1,
		color = Color3.fromRGB(120, 80, 220),
		accent = Color3.fromRGB(255, 100, 240),
		projectileSpeed = 90 * SCALE,
		projectileColor = Color3.fromRGB(230, 120, 255),
		splash = 1.8 * SCALE,
		chain = 2,
		chainRange = 3 * SCALE,
	},
}

return TowerDefs
