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
	id = 1785922595,
	name = "Celestial Bastion",
	price = 99,
	description = "A legendary tower of pure starlight — massive damage, huge range, and chain-strike crystal projectiles.",
} :: GamePassInfo

-- Which tower key in TowerDefs this pass unlocks.
GamePassConfig.PREMIUM_TOWER_KEY = "celestial"

-- Premium Robux-gated player gun — separate pass from the tower. Lives
-- on its own lobby pedestal and is granted + auto-equipped when the
-- pass purchase completes on the server.
GamePassConfig.PREMIUM_GUN = {
	id = 1785806515,
	name = "Starfire Rifle",
	price = 49,
	description = "A void-forged marksman rifle. Pierces armor, obliterates tanks, and leaves a trail of starlight.",
} :: GamePassInfo

-- Which gun key in Guns this pass unlocks.
GamePassConfig.PREMIUM_GUN_KEY = "starfire"

-- Second premium Robux-gated gun. Separate pass + pedestal from the
-- starfire rifle so the two premium guns sit side-by-side in the lobby
-- and players can buy them independently.
GamePassConfig.PREMIUM_GUN_2 = {
	id = 1786012274,
	name = "Void Reaper",
	price = 49,
	description = "A premium auto-shotgun from the Void Frontier. Six piercing pellets per shot, full auto.",
} :: GamePassInfo

GamePassConfig.PREMIUM_GUN_2_KEY = "void_reaper"

-- --- Cash packs (Robux → in-game gold) ---
-- These are Developer Products, not Game Passes (repeatable purchases).
-- After uploading the game you need to create each product in the
-- Creator Dashboard and paste the real product id into `productId` below.
-- While the id is 0, the server dev-fallback grants the cash directly
-- in Studio so the shop flow can be tested without real products.

export type CashPackInfo = {
	productId: number,
	robuxPrice: number,
	cashAmount: number,
	label: string,
}

-- Cash pack tiers. Each tier is a strictly better gold/R$ ratio than
-- the tier below so the 4-pack ladder presents a clear "spend more,
-- save more" curve:
--   Pouch  20 R$ →   5,000  ( 250 gold/R$)
--   Sack   49 R$ →  14,000  (~286 gold/R$, +14% vs Pouch)
--   Chest  99 R$ →  32,000  (~323 gold/R$, +13% vs Sack)
--   Vault 249 R$ → 250,000  (~1004 gold/R$, massive whale-tier bonus)
GamePassConfig.CASH_PACKS = {
	{ productId = 3570874538, robuxPrice = 20, cashAmount = 5000, label = "Pouch" },
	{ productId = 3570874781, robuxPrice = 49, cashAmount = 14000, label = "Sack" },
	{ productId = 3570875026, robuxPrice = 99, cashAmount = 32000, label = "Chest" },
	{ productId = 3570875201, robuxPrice = 249, cashAmount = 250000, label = "Vault" },
} :: { CashPackInfo }

-- Look up the cash payout for a given product id. Returns nil if the
-- id isn't one of our known cash packs (so ProcessReceipt can ignore
-- other developer products safely).
function GamePassConfig.getCashForProduct(productId: number): number?
	for _, pack in GamePassConfig.CASH_PACKS do
		if pack.productId == productId and productId > 0 then
			return pack.cashAmount
		end
	end
	return nil
end

return GamePassConfig
