--!strict
-- src/shared/GamePassConfig.luau
-- Game Pass IDs + metadata for premium unlocks. After uploading the
-- game to Roblox and creating the Game Pass in the Creator Dashboard,
-- paste the real ID into PREMIUM_TOWER.id below. While the ID is 0
-- (default), the server + client fall back to auto-unlocking the pass
-- in Roblox Studio so you can still test the tower locally.

export type GamePassInfo = {
	id: number,
	name: string,
	price: number, -- Robux
	description: string,
}

local GamePassConfig = {}

GamePassConfig.PREMIUM_TOWER = {
	id = 0, -- TODO: replace with real Game Pass ID from the Creator Dashboard
	name = "Celestial Bastion",
	price = 99,
	description = "A legendary tower of pure starlight — massive damage, huge range, and chain-strike crystal projectiles.",
} :: GamePassInfo

-- Which tower key in TowerDefs this pass unlocks.
GamePassConfig.PREMIUM_TOWER_KEY = "celestial"

return GamePassConfig
