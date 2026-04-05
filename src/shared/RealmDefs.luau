--!strict
-- src/shared/RealmDefs.luau
-- Single source of truth for per-realm content: map palette, enemy roster,
-- and signature tower. All realm routing code (server init, Map, Castle,
-- EnemyManager, WaveConfig, HUD) reads from this table.

export type RealmPalette = {
	ground: Color3,
	grass: Color3,
	path: Color3,
	wall: Color3,
	wallDark: Color3,
	rock: Color3,
	rockDark: Color3,
	trunk: Color3,
	canopy: { Color3 },
	ridge: { Color3 },
	mountainBase: Color3,
	mountainMid: Color3,
	mountainPeak: Color3,
	castleStone: Color3,
	castleStoneDark: Color3,
	groundMaterial: Enum.Material,
	grassMaterial: Enum.Material,
	pathMaterial: Enum.Material,
	rockMaterial: Enum.Material,
	canopyMaterial: Enum.Material,
	mountainPeakMaterial: Enum.Material,
}

-- Enemies reuse the 3 existing silhouettes (goblin/scout/troll) but swap
-- colors, names, stats, and a single theme flourish per realm.
export type EnemyArchetype = {
	enemyType: string, -- unique key used for death animations & walk params
	silhouette: string, -- "goblin" | "scout" | "troll"
	flourish: string, -- "none" | "crystal" | "bone" | "leaf" | "antenna"
	name: string,
	bodyColor: Color3,
	accentColor: Color3,
	hpMult: number,
	speedMult: number,
	rewardMult: number,
	scale: number,
}

export type UnlockRequirement = {
	realm: string, -- name of the realm whose highest wave must be reached
	wave: number,
}

export type RealmDef = {
	name: string,
	displayName: string,
	signatureTower: string, -- TowerDefs key
	palette: RealmPalette,
	-- Enemy path as (gx, gy) grid coordinates. Each realm has a
	-- different shape and length; the leftmost portal (Realm Defense)
	-- has the longest path and later portals get progressively shorter
	-- paths to ramp up difficulty.
	path: { { number } },
	small: EnemyArchetype,
	fast: EnemyArchetype,
	tank: EnemyArchetype,
	-- Tower cost multiplier for this realm. Money is global across
	-- realms so later realms charge more per tower to create a
	-- progression curve.
	costMultiplier: number,
	-- Gate: the player must have reached this wave in `realm` before
	-- this portal becomes enterable. Nil means always unlocked.
	unlockRequirement: UnlockRequirement?,
}

-- Path tables. Each must start with gx=0 (west edge) and end with
-- gx=15 (east edge) so the castle builds against the east wall.
-- Lengths: defense 37 → frost 25 → desert 21 → forest 18 → space 16.
local PATH_DEFENSE: { { number } } = {
	{ 0, 2 },
	{ 1, 2 },
	{ 2, 2 },
	{ 3, 2 },
	{ 4, 2 },
	{ 5, 2 },
	{ 6, 2 },
	{ 7, 2 },
	{ 7, 3 },
	{ 7, 4 },
	{ 7, 5 },
	{ 7, 6 },
	{ 6, 6 },
	{ 5, 6 },
	{ 4, 6 },
	{ 3, 6 },
	{ 2, 6 },
	{ 2, 7 },
	{ 2, 8 },
	{ 2, 9 },
	{ 2, 10 },
	{ 3, 10 },
	{ 4, 10 },
	{ 5, 10 },
	{ 6, 10 },
	{ 7, 10 },
	{ 8, 10 },
	{ 9, 10 },
	{ 10, 10 },
	{ 10, 11 },
	{ 10, 12 },
	{ 10, 13 },
	{ 11, 13 },
	{ 12, 13 },
	{ 13, 13 },
	{ 14, 13 },
	{ 15, 13 },
}

local PATH_FROST: { { number } } = {
	{ 0, 3 },
	{ 1, 3 },
	{ 2, 3 },
	{ 3, 3 },
	{ 4, 3 },
	{ 5, 3 },
	{ 6, 3 },
	{ 6, 4 },
	{ 6, 5 },
	{ 6, 6 },
	{ 6, 7 },
	{ 6, 8 },
	{ 7, 8 },
	{ 8, 8 },
	{ 9, 8 },
	{ 10, 8 },
	{ 11, 8 },
	{ 12, 8 },
	{ 12, 9 },
	{ 12, 10 },
	{ 12, 11 },
	{ 12, 12 },
	{ 13, 12 },
	{ 14, 12 },
	{ 15, 12 },
}

local PATH_DESERT: { { number } } = {
	{ 0, 5 },
	{ 1, 5 },
	{ 2, 5 },
	{ 3, 5 },
	{ 4, 5 },
	{ 5, 5 },
	{ 6, 5 },
	{ 7, 5 },
	{ 8, 5 },
	{ 8, 6 },
	{ 8, 7 },
	{ 8, 8 },
	{ 8, 9 },
	{ 8, 10 },
	{ 9, 10 },
	{ 10, 10 },
	{ 11, 10 },
	{ 12, 10 },
	{ 13, 10 },
	{ 14, 10 },
	{ 15, 10 },
}

local PATH_FOREST: { { number } } = {
	{ 0, 8 },
	{ 1, 8 },
	{ 2, 8 },
	{ 3, 8 },
	{ 4, 8 },
	{ 5, 8 },
	{ 6, 8 },
	{ 7, 8 },
	{ 8, 8 },
	{ 9, 8 },
	{ 9, 9 },
	{ 9, 10 },
	{ 10, 10 },
	{ 11, 10 },
	{ 12, 10 },
	{ 13, 10 },
	{ 14, 10 },
	{ 15, 10 },
}

local PATH_SPACE: { { number } } = {
	{ 0, 8 },
	{ 1, 8 },
	{ 2, 8 },
	{ 3, 8 },
	{ 4, 8 },
	{ 5, 8 },
	{ 6, 8 },
	{ 7, 8 },
	{ 8, 8 },
	{ 9, 8 },
	{ 10, 8 },
	{ 11, 8 },
	{ 12, 8 },
	{ 13, 8 },
	{ 14, 8 },
	{ 15, 8 },
}

local RealmDefs: { [string]: RealmDef } = {
	defense = {
		name = "defense",
		displayName = "Realm Defense",
		signatureTower = "paladin",
		path = PATH_DEFENSE,
		costMultiplier = 1,
		unlockRequirement = nil,
		palette = {
			ground = Color3.fromRGB(46, 85, 34),
			grass = Color3.fromRGB(67, 160, 71),
			path = Color3.fromRGB(141, 110, 99),
			wall = Color3.fromRGB(97, 97, 97),
			wallDark = Color3.fromRGB(66, 66, 66),
			rock = Color3.fromRGB(117, 117, 117),
			rockDark = Color3.fromRGB(78, 78, 78),
			trunk = Color3.fromRGB(82, 52, 36),
			canopy = {
				Color3.fromRGB(27, 94, 32),
				Color3.fromRGB(33, 113, 39),
				Color3.fromRGB(46, 125, 50),
			},
			ridge = {
				Color3.fromRGB(95, 90, 82),
				Color3.fromRGB(110, 100, 90),
				Color3.fromRGB(78, 72, 65),
			},
			mountainBase = Color3.fromRGB(78, 72, 65),
			mountainMid = Color3.fromRGB(105, 96, 85),
			mountainPeak = Color3.fromRGB(240, 240, 245),
			castleStone = Color3.fromRGB(150, 145, 135),
			castleStoneDark = Color3.fromRGB(95, 90, 82),
			groundMaterial = Enum.Material.Grass,
			grassMaterial = Enum.Material.Grass,
			pathMaterial = Enum.Material.Slate,
			rockMaterial = Enum.Material.Rock,
			canopyMaterial = Enum.Material.Grass,
			mountainPeakMaterial = Enum.Material.Snow,
		},
		small = {
			enemyType = "goblin",
			silhouette = "goblin",
			flourish = "none",
			name = "Goblin",
			bodyColor = Color3.fromRGB(85, 139, 47),
			accentColor = Color3.fromRGB(120, 170, 80),
			hpMult = 1,
			speedMult = 1,
			rewardMult = 1,
			scale = 0.65,
		},
		fast = {
			enemyType = "scout",
			silhouette = "scout",
			flourish = "none",
			name = "Scout",
			bodyColor = Color3.fromRGB(251, 192, 45),
			accentColor = Color3.fromRGB(245, 127, 23),
			hpMult = 0.5,
			speedMult = 1.6,
			rewardMult = 1.35,
			scale = 0.55,
		},
		tank = {
			enemyType = "troll",
			silhouette = "troll",
			flourish = "none",
			name = "Troll",
			bodyColor = Color3.fromRGB(106, 27, 154),
			accentColor = Color3.fromRGB(74, 20, 140),
			hpMult = 3,
			speedMult = 0.55,
			rewardMult = 3,
			scale = 0.95,
		},
	},

	frost = {
		name = "frost",
		displayName = "Frost Kingdom",
		signatureTower = "icelance",
		path = PATH_FROST,
		costMultiplier = 1.4,
		unlockRequirement = { realm = "defense", wave = 10 },
		palette = {
			ground = Color3.fromRGB(220, 230, 240),
			grass = Color3.fromRGB(240, 248, 255),
			path = Color3.fromRGB(130, 160, 180),
			wall = Color3.fromRGB(176, 200, 220),
			wallDark = Color3.fromRGB(120, 148, 170),
			rock = Color3.fromRGB(176, 196, 210),
			rockDark = Color3.fromRGB(110, 130, 150),
			trunk = Color3.fromRGB(76, 68, 60),
			canopy = {
				Color3.fromRGB(200, 222, 235),
				Color3.fromRGB(230, 240, 250),
				Color3.fromRGB(160, 195, 220),
			},
			ridge = {
				Color3.fromRGB(176, 200, 220),
				Color3.fromRGB(210, 225, 240),
				Color3.fromRGB(135, 160, 185),
			},
			mountainBase = Color3.fromRGB(110, 140, 165),
			mountainMid = Color3.fromRGB(170, 195, 215),
			mountainPeak = Color3.fromRGB(255, 255, 255),
			castleStone = Color3.fromRGB(200, 220, 235),
			castleStoneDark = Color3.fromRGB(140, 165, 190),
			groundMaterial = Enum.Material.Snow,
			grassMaterial = Enum.Material.Snow,
			pathMaterial = Enum.Material.Ice,
			rockMaterial = Enum.Material.Ice,
			canopyMaterial = Enum.Material.Snow,
			mountainPeakMaterial = Enum.Material.Snow,
		},
		small = {
			enemyType = "frost_iceling",
			silhouette = "goblin",
			flourish = "crystal",
			name = "Iceling",
			bodyColor = Color3.fromRGB(120, 200, 240),
			accentColor = Color3.fromRGB(225, 245, 255),
			hpMult = 1.05,
			speedMult = 0.95,
			rewardMult = 1,
			scale = 0.65,
		},
		fast = {
			enemyType = "frost_wolf",
			silhouette = "scout",
			flourish = "crystal",
			name = "Frost Wolf",
			bodyColor = Color3.fromRGB(180, 210, 230),
			accentColor = Color3.fromRGB(90, 140, 180),
			hpMult = 0.55,
			speedMult = 1.55,
			rewardMult = 1.4,
			scale = 0.55,
		},
		tank = {
			enemyType = "frost_golem",
			silhouette = "troll",
			flourish = "crystal",
			name = "Ice Golem",
			bodyColor = Color3.fromRGB(100, 155, 195),
			accentColor = Color3.fromRGB(200, 230, 250),
			hpMult = 3.2,
			speedMult = 0.5,
			rewardMult = 3.1,
			scale = 0.95,
		},
	},

	desert = {
		name = "desert",
		displayName = "Desert Wastes",
		signatureTower = "sandstorm",
		path = PATH_DESERT,
		costMultiplier = 1.8,
		unlockRequirement = { realm = "frost", wave = 15 },
		palette = {
			ground = Color3.fromRGB(214, 175, 106),
			grass = Color3.fromRGB(230, 200, 130),
			path = Color3.fromRGB(170, 130, 80),
			wall = Color3.fromRGB(200, 165, 105),
			wallDark = Color3.fromRGB(150, 115, 70),
			rock = Color3.fromRGB(190, 160, 110),
			rockDark = Color3.fromRGB(140, 110, 70),
			trunk = Color3.fromRGB(120, 80, 50),
			canopy = {
				Color3.fromRGB(120, 155, 70),
				Color3.fromRGB(140, 175, 80),
				Color3.fromRGB(95, 125, 55),
			},
			ridge = {
				Color3.fromRGB(200, 160, 95),
				Color3.fromRGB(170, 130, 75),
				Color3.fromRGB(215, 175, 110),
			},
			mountainBase = Color3.fromRGB(160, 120, 70),
			mountainMid = Color3.fromRGB(200, 160, 95),
			mountainPeak = Color3.fromRGB(230, 195, 135),
			castleStone = Color3.fromRGB(215, 180, 120),
			castleStoneDark = Color3.fromRGB(150, 115, 70),
			groundMaterial = Enum.Material.Sand,
			grassMaterial = Enum.Material.Sand,
			pathMaterial = Enum.Material.Sand,
			rockMaterial = Enum.Material.Sandstone,
			canopyMaterial = Enum.Material.Grass,
			mountainPeakMaterial = Enum.Material.Sandstone,
		},
		small = {
			enemyType = "desert_scarab",
			silhouette = "goblin",
			flourish = "bone",
			name = "Scarab",
			bodyColor = Color3.fromRGB(180, 125, 60),
			accentColor = Color3.fromRGB(90, 60, 30),
			hpMult = 0.95,
			speedMult = 1.1,
			rewardMult = 1,
			scale = 0.6,
		},
		fast = {
			enemyType = "desert_jackal",
			silhouette = "scout",
			flourish = "bone",
			name = "Jackal",
			bodyColor = Color3.fromRGB(210, 165, 100),
			accentColor = Color3.fromRGB(120, 85, 45),
			hpMult = 0.5,
			speedMult = 1.7,
			rewardMult = 1.35,
			scale = 0.55,
		},
		tank = {
			enemyType = "desert_mummy",
			silhouette = "troll",
			flourish = "bone",
			name = "Mummy King",
			bodyColor = Color3.fromRGB(225, 205, 155),
			accentColor = Color3.fromRGB(140, 110, 75),
			hpMult = 3.4,
			speedMult = 0.5,
			rewardMult = 3.2,
			scale = 0.95,
		},
	},

	forest = {
		name = "forest",
		displayName = "Dark Forest",
		signatureTower = "thornwall",
		path = PATH_FOREST,
		costMultiplier = 2.3,
		unlockRequirement = { realm = "desert", wave = 15 },
		palette = {
			ground = Color3.fromRGB(32, 54, 30),
			grass = Color3.fromRGB(44, 90, 42),
			path = Color3.fromRGB(72, 52, 32),
			wall = Color3.fromRGB(70, 55, 40),
			wallDark = Color3.fromRGB(45, 33, 22),
			rock = Color3.fromRGB(75, 85, 65),
			rockDark = Color3.fromRGB(50, 60, 45),
			trunk = Color3.fromRGB(55, 35, 20),
			canopy = {
				Color3.fromRGB(20, 65, 25),
				Color3.fromRGB(25, 80, 30),
				Color3.fromRGB(12, 50, 18),
			},
			ridge = {
				Color3.fromRGB(72, 70, 55),
				Color3.fromRGB(58, 56, 45),
				Color3.fromRGB(90, 85, 68),
			},
			mountainBase = Color3.fromRGB(50, 48, 38),
			mountainMid = Color3.fromRGB(75, 72, 58),
			mountainPeak = Color3.fromRGB(110, 105, 85),
			castleStone = Color3.fromRGB(85, 75, 60),
			castleStoneDark = Color3.fromRGB(50, 42, 30),
			groundMaterial = Enum.Material.LeafyGrass,
			grassMaterial = Enum.Material.LeafyGrass,
			pathMaterial = Enum.Material.Ground,
			rockMaterial = Enum.Material.Rock,
			canopyMaterial = Enum.Material.LeafyGrass,
			mountainPeakMaterial = Enum.Material.Rock,
		},
		small = {
			enemyType = "forest_sprite",
			silhouette = "goblin",
			flourish = "leaf",
			name = "Wood Sprite",
			bodyColor = Color3.fromRGB(110, 165, 60),
			accentColor = Color3.fromRGB(200, 230, 120),
			hpMult = 1,
			speedMult = 1.05,
			rewardMult = 1,
			scale = 0.65,
		},
		fast = {
			enemyType = "forest_stalker",
			silhouette = "scout",
			flourish = "leaf",
			name = "Shadow Stalker",
			bodyColor = Color3.fromRGB(60, 90, 45),
			accentColor = Color3.fromRGB(30, 55, 20),
			hpMult = 0.55,
			speedMult = 1.65,
			rewardMult = 1.4,
			scale = 0.55,
		},
		tank = {
			enemyType = "forest_treant",
			silhouette = "troll",
			flourish = "leaf",
			name = "Ancient Treant",
			bodyColor = Color3.fromRGB(80, 55, 30),
			accentColor = Color3.fromRGB(40, 90, 40),
			hpMult = 3.3,
			speedMult = 0.5,
			rewardMult = 3.1,
			scale = 0.95,
		},
	},

	space = {
		name = "space",
		displayName = "Void Frontier",
		signatureTower = "plasma",
		path = PATH_SPACE,
		costMultiplier = 3,
		unlockRequirement = { realm = "forest", wave = 15 },
		palette = {
			ground = Color3.fromRGB(40, 30, 55),
			grass = Color3.fromRGB(70, 50, 95),
			path = Color3.fromRGB(110, 85, 155),
			wall = Color3.fromRGB(55, 62, 90),
			wallDark = Color3.fromRGB(30, 36, 55),
			rock = Color3.fromRGB(80, 70, 110),
			rockDark = Color3.fromRGB(45, 38, 70),
			trunk = Color3.fromRGB(70, 62, 100),
			canopy = {
				Color3.fromRGB(130, 80, 220),
				Color3.fromRGB(90, 180, 230),
				Color3.fromRGB(200, 100, 200),
			},
			ridge = {
				Color3.fromRGB(60, 50, 90),
				Color3.fromRGB(90, 75, 125),
				Color3.fromRGB(40, 32, 60),
			},
			mountainBase = Color3.fromRGB(35, 28, 55),
			mountainMid = Color3.fromRGB(70, 58, 105),
			mountainPeak = Color3.fromRGB(160, 120, 220),
			castleStone = Color3.fromRGB(90, 80, 130),
			castleStoneDark = Color3.fromRGB(40, 34, 65),
			groundMaterial = Enum.Material.Slate,
			grassMaterial = Enum.Material.Slate,
			pathMaterial = Enum.Material.Neon,
			rockMaterial = Enum.Material.Slate,
			canopyMaterial = Enum.Material.Neon,
			mountainPeakMaterial = Enum.Material.Neon,
		},
		small = {
			enemyType = "space_drone",
			silhouette = "goblin",
			flourish = "antenna",
			name = "Void Drone",
			bodyColor = Color3.fromRGB(100, 120, 200),
			accentColor = Color3.fromRGB(180, 220, 255),
			hpMult = 1.1,
			speedMult = 1,
			rewardMult = 1,
			scale = 0.65,
		},
		fast = {
			enemyType = "space_scout",
			silhouette = "scout",
			flourish = "antenna",
			name = "Alien Stalker",
			bodyColor = Color3.fromRGB(180, 80, 220),
			accentColor = Color3.fromRGB(255, 130, 240),
			hpMult = 0.55,
			speedMult = 1.7,
			rewardMult = 1.45,
			scale = 0.55,
		},
		tank = {
			enemyType = "space_behemoth",
			silhouette = "troll",
			flourish = "antenna",
			name = "Void Behemoth",
			bodyColor = Color3.fromRGB(80, 60, 150),
			accentColor = Color3.fromRGB(160, 90, 240),
			hpMult = 3.5,
			speedMult = 0.5,
			rewardMult = 3.3,
			scale = 1,
		},
	},
}

local RealmDefsModule = {}

function RealmDefsModule.get(realmName: string): RealmDef
	local def = RealmDefs[realmName]
	if not def then
		return RealmDefs.defense
	end
	return def
end

function RealmDefsModule.exists(realmName: string): boolean
	return RealmDefs[realmName] ~= nil
end

-- Ordered list of realm names for UI listing
RealmDefsModule.ORDER = { "defense", "frost", "desert", "forest", "space" }

-- The seven universal towers that exist in every realm, plus the realm's
-- signature tower, together form the tower picker for that realm.
RealmDefsModule.UNIVERSAL_TOWERS =
	{ "basic", "sniper", "cannon", "freeze", "lightning", "poison", "flame" }

function RealmDefsModule.getTowerList(realmName: string): { string }
	local def = RealmDefsModule.get(realmName)
	local list = table.clone(RealmDefsModule.UNIVERSAL_TOWERS)
	table.insert(list, def.signatureTower)
	return list
end

-- Returns true if the player has met the unlock requirements for this
-- realm. `highestWaves` maps realm name → highest wave reached. Realms
-- without an unlockRequirement are always unlocked.
function RealmDefsModule.isUnlocked(realmName: string, highestWaves: { [string]: number }): boolean
	local def = RealmDefs[realmName]
	if not def then
		return false
	end
	if not def.unlockRequirement then
		return true
	end
	local req = def.unlockRequirement
	local reached = highestWaves[req.realm] or 0
	return reached >= req.wave
end

return RealmDefsModule
