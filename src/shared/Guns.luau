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
-- Pricing curve: every player starts with the free `starter` gun (weak
-- but playable) so the tutorial can teach shooting without forcing a
-- purchase. Early guns (pistol/smg) are affordable in the first realm,
-- mid-tier (rifle/revolver/shotgun) require grinding into frost/desert,
-- high-tier (sniper/flamethrower/minigun) expect you to be deep in
-- forest, and the top-tier (plasma/railgun) are endgame gold sinks
-- meant to be unlocked only after space-realm grinding.
local Guns: { [string]: GunDef } = {
	starter = {
		name = "Rusty Pistol",
		icon = "🪛",
		cost = 0, -- free; server auto-grants on join
		damage = 1,
		fireRate = 1.2,
		range = 30,
		pellets = 1,
		spread = 4,
		tracerColor = Color3.fromRGB(180, 170, 140),
		description = "Dented old sidearm. Free, but weak — replace it as soon as you can.",
	},
	pistol = {
		name = "Sidearm",
		icon = "🔫",
		cost = 100,
		damage = 3,
		fireRate = 2.5,
		range = 45,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(255, 220, 120),
		description = "Cheap sidearm. Chips damage off stragglers.",
	},
	smg = {
		name = "Burst SMG",
		icon = "💨",
		cost = 350,
		damage = 2,
		fireRate = 8,
		range = 40,
		pellets = 1,
		spread = 3,
		tracerColor = Color3.fromRGB(255, 240, 120),
		description = "Automatic burst-fire SMG. Shreds through swarms.",
	},
	shotgun = {
		name = "Boomstick",
		icon = "💥",
		cost = 2400,
		damage = 3,
		fireRate = 1.2,
		range = 32,
		pellets = 5,
		spread = 12,
		tracerColor = Color3.fromRGB(255, 140, 40),
		description = "Close-range scatter gun. Five pellets per shot.",
	},
	rifle = {
		name = "Ranger Rifle",
		icon = "🎯",
		cost = 1600,
		damage = 6,
		fireRate = 3,
		range = 70,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(255, 180, 80),
		description = "Accurate mid-range rifle. Steady support fire.",
	},
	sniper = {
		name = "Longshot",
		icon = "🔭",
		cost = 6500,
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
		cost = 12000,
		damage = 14,
		fireRate = 1.6,
		range = 85,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(180, 100, 255),
		description = "Void-forged weapon. Heavy punch at range.",
	},
	minigun = {
		name = "Minigun",
		icon = "🌀",
		cost = 9000,
		damage = 3,
		fireRate = 12,
		range = 55,
		pellets = 1,
		spread = 4,
		tracerColor = Color3.fromRGB(255, 180, 80),
		description = "Six-barrel rotary cannon. Stream of lead for the late game.",
	},
	revolver = {
		name = "Hand Cannon",
		icon = "🤠",
		cost = 800,
		damage = 12,
		fireRate = 1.6,
		range = 60,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(255, 190, 90),
		description = "Six-shot revolver with stopping power. Slow but hits hard.",
	},
	flamethrower = {
		name = "Dragon's Breath",
		icon = "🔥",
		cost = 4000,
		damage = 2,
		fireRate = 14,
		range = 38,
		pellets = 2,
		spread = 10,
		tracerColor = Color3.fromRGB(255, 110, 40),
		description = "Continuous gout of fire. Short range, shreds swarms.",
	},
	railgun = {
		name = "Railgun",
		icon = "⚙️",
		cost = 18000,
		damage = 55,
		fireRate = 0.5,
		range = 200,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(120, 240, 255),
		description = "Magnetic accelerator. Devastating single shot at any range.",
	},
	starfire = {
		name = "Starfire Rifle",
		icon = "🌟",
		cost = 0, -- Robux-gated; server blocks gold purchases
		damage = 45,
		fireRate = 2.5,
		range = 160,
		pellets = 1,
		spread = 0,
		tracerColor = Color3.fromRGB(255, 220, 160),
		description = "Premium void-forged marksman rifle. Pierces armor, leaves a starlight trail.",
	},
	void_reaper = {
		name = "Void Reaper",
		icon = "💀",
		cost = 0, -- Robux-gated; second premium pass
		damage = 8,
		fireRate = 4,
		range = 50,
		pellets = 6,
		spread = 7,
		tracerColor = Color3.fromRGB(200, 80, 255),
		description = "Premium auto-shotgun. Six piercing void pellets per shot, full auto.",
	},
}

local GunsModule = {}

GunsModule.defs = Guns

-- Ordered so the shop panel has a consistent left-to-right layout.
-- The premium starfire rifle is appended last; the shop card shows it
-- with a Robux label instead of a gold price.
-- Ordered cheapest → most expensive so the shop reads as a natural
-- progression. The free starter sits first, then gold guns by cost,
-- then Robux-gated premium entries.
GunsModule.ORDER = {
	"starter",
	"pistol",
	"smg",
	"revolver",
	"rifle",
	"shotgun",
	"flamethrower",
	"sniper",
	"minigun",
	"plasma",
	"railgun",
	"starfire",
	"void_reaper",
}

function GunsModule.get(key: string): GunDef?
	return Guns[key]
end

return GunsModule
