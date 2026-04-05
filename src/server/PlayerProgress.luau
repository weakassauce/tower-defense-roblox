--!strict
-- src/server/PlayerProgress.luau
-- DataStore wrapper for per-player long-term progression. Persists
-- gold, owned guns, equipped gun, and per-realm best waves across
-- sessions. Per-realm in-progress saves (hp / wave / tower layout) are
-- intentionally NOT persisted — those are ephemeral runs.
--
-- Studio fallback: DataStoreService raises "DataStore API is not
-- enabled" in Studio when "Enable Studio Access to API Services" is
-- off. Every call is wrapped in pcall and falls back to an in-memory
-- cache so the rest of the server still works while testing locally.
-- Once the place is published (or that setting is flipped), the real
-- DataStore picks up and saves persist.

local DataStoreService = game:GetService("DataStoreService")

local PlayerProgress = {}

-- Bump this when the save shape changes in a backwards-incompatible
-- way. Old keys will be ignored (treated as fresh players) instead of
-- loaded into a mismatched schema.
local STORE_NAME = "TowerDefenseProgress_v1"

export type SaveData = {
	gold: number,
	ownedGuns: { [string]: boolean },
	equippedGun: string?,
	highestWaves: { [string]: number },
}

local function keyFor(player: Player): string
	return "user_" .. player.UserId
end

local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[PlayerProgress] GetDataStore failed, falling back to in-memory:", result)
	end
end

-- In-memory fallback table used when the DataStore call fails (Studio
-- without API access). Keeps player saves alive for the current server
-- session only. Also used as a warm cache for successful loads so
-- subsequent reads inside the same session don't re-hit the DataStore.
local memCache: { [string]: SaveData } = {}

local function defaultSave(): SaveData
	return {
		gold = 0, -- 0 here means "use Config.STARTING_GOLD"; caller decides
		ownedGuns = { starter = true },
		equippedGun = "starter",
		highestWaves = {},
	}
end

-- Merge a raw DataStore value into the default shape so any missing
-- fields from an older schema don't nil out the instance. Defensive
-- against corrupt data — any field that doesn't type-check falls back
-- to the default.
local function coerce(raw: any): SaveData
	if typeof(raw) ~= "table" then
		return defaultSave()
	end
	local save = defaultSave()
	if typeof(raw.gold) == "number" then
		save.gold = raw.gold
	end
	if typeof(raw.ownedGuns) == "table" then
		for k, v in raw.ownedGuns do
			if typeof(k) == "string" and v == true then
				save.ownedGuns[k] = true
			end
		end
	end
	if typeof(raw.equippedGun) == "string" then
		save.equippedGun = raw.equippedGun
	end
	if typeof(raw.highestWaves) == "table" then
		for k, v in raw.highestWaves do
			if typeof(k) == "string" and typeof(v) == "number" then
				save.highestWaves[k] = math.floor(v)
			end
		end
	end
	return save
end

-- Load `player`'s save. Returns a usable SaveData even on failure (the
-- default shape). Caller should check `isFresh` to decide whether to
-- seed the player with STARTING_GOLD or trust the persisted gold value.
function PlayerProgress.load(player: Player): (SaveData, boolean)
	local key = keyFor(player)

	if store then
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			if result == nil then
				-- First-time player: cache a default so future saves hit
				-- the same path.
				local fresh = defaultSave()
				memCache[key] = fresh
				return fresh, true
			end
			local coerced = coerce(result)
			memCache[key] = coerced
			return coerced, false
		else
			warn(string.format("[PlayerProgress] load failed for %s: %s", player.Name, tostring(result)))
		end
	end

	-- DataStore unavailable or read failed — check the in-memory cache,
	-- otherwise hand back a fresh default.
	local cached = memCache[key]
	if cached then
		return cached, false
	end
	local fresh = defaultSave()
	memCache[key] = fresh
	return fresh, true
end

-- Persist `data` for `player`. Uses UpdateAsync so concurrent writes
-- (e.g. BindToClose firing mid-session) don't stomp each other. Returns
-- true on success, false if the DataStore call errored.
function PlayerProgress.save(player: Player, data: SaveData): boolean
	local key = keyFor(player)
	memCache[key] = data

	if not store then
		return false
	end

	local ok, err = pcall(function()
		store:UpdateAsync(key, function(_old)
			return data
		end)
	end)
	if not ok then
		warn(string.format("[PlayerProgress] save failed for %s: %s", player.Name, tostring(err)))
	end
	return ok
end

return PlayerProgress
