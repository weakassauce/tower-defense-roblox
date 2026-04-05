--!strict
-- src/shared/Guns.luau
-- Static gun stats for the player-combat shop. The same gold pool that
-- buys towers buys guns; guns are purchased once and persist across
-- realms (stored in GameState.ownedGuns).

export type GunDef = {
	name: string,
	icon: string,
	cost: number,
	damage: number,
	fireRate: number, -- shots per second
	range: number, -- studs
	pellets: number, -- >1 for shotgun-style spread
	spread: number, -- degrees of random cone spread per pellet
	tracerColor: Color3,
	description: string,
}

-- Tuning: guns are a SUPPORT weapon, not a replacement for towers.
-- Damage is deliberately low so the player can help finish off stragglers
-- or soften tanks, but towers are still the primary damage source.
local Guns: { [string]: GunDef } = {
	pistol = {
		name = "Sidearm",
		icon = "🔫",
		cost = 80,
		damage = 3,
		fireRate = 2.5,
		range = 45,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(255, 220, 120),
		description = "Cheap sidearm. Chips damage off stragglers.",
	},
	rifle = {
		name = "Ranger Rifle",
		icon = "🎯",
		cost = 180,
		damage = 6,
		fireRate = 3,
		range = 70,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(255, 180, 80),
		description = "Accurate mid-range rifle. Steady support fire.",
	},
	shotgun = {
		name = "Boomstick",
		icon = "💥",
		cost = 150,
		damage = 3,
		fireRate = 1.2,
		range = 32,
		pellets = 5,
		spread = 12,
		tracerColor = Color3.fromRGB(255, 140, 40),
		description = "Close-range scatter gun. Five pellets per shot.",
	},
	sniper = {
		name = "Longshot",
		icon = "🔭",
		cost = 350,
		damage = 28,
		fireRate = 0.7,
		range = 140,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(180, 200, 255),
		description = "Heavy precision rifle. Slow but satisfying.",
	},
	plasma = {
		name = "Plasma Caster",
		icon = "⚡",
		cost = 500,
		damage = 14,
		fireRate = 1.6,
		range = 85,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(180, 100, 255),
		description = "Void-forged weapon. Heavy punch at range.",
	},
}

local GunsModule = {}

GunsModule.defs = Guns

-- Ordered so the shop panel has a consistent left-to-right layout.
GunsModule.ORDER = { "pistol", "rifle", "shotgun", "sniper", "plasma" }

function GunsModule.get(key: string): GunDef?
	return Guns[key]
end

return GunsModule
