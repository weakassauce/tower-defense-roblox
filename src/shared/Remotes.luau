--!strict
-- src/shared/Remotes.luau
-- All RemoteEvents used by the game. Server creates them, client waits for
-- them, both access by name. Lives in ReplicatedStorage.Shared.Remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

local function getOrMakeFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder then
		return folder :: Folder
	end
	if RunService:IsServer() then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
		return folder :: Folder
	else
		return ReplicatedStorage:WaitForChild("Remotes") :: Folder
	end
end

local function getOrMakeRemote(name: string): RemoteEvent
	local folder = getOrMakeFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		return existing :: RemoteEvent
	end
	if RunService:IsServer() then
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		return remote
	else
		return folder:WaitForChild(name, 10) :: RemoteEvent
	end
end

-- Client → Server (player actions)
Remotes.PlaceTower = getOrMakeRemote("PlaceTower")
Remotes.PickupTower = getOrMakeRemote("PickupTower")
Remotes.PlaceFromInventory = getOrMakeRemote("PlaceFromInventory")
Remotes.SellInventoryItem = getOrMakeRemote("SellInventoryItem")
Remotes.StartWave = getOrMakeRemote("StartWave")
Remotes.Restart = getOrMakeRemote("Restart")
Remotes.ReturnToLobby = getOrMakeRemote("ReturnToLobby")
Remotes.BuyGun = getOrMakeRemote("BuyGun")
Remotes.EquipGun = getOrMakeRemote("EquipGun")
Remotes.FireGun = getOrMakeRemote("FireGun")
-- Client submits a cheat code; server validates and, on match, flips
-- the player into admin mode (all towers / guns free, premium items
-- owned). The server rejects invalid codes silently.
Remotes.UnlockAdmin = getOrMakeRemote("UnlockAdmin")

-- Server → Client (state sync + events)
Remotes.StateUpdate = getOrMakeRemote("StateUpdate")
Remotes.WaveComplete = getOrMakeRemote("WaveComplete")
Remotes.GameOver = getOrMakeRemote("GameOver")
Remotes.CastleDestroyed = getOrMakeRemote("CastleDestroyed")
Remotes.EnterRealm = getOrMakeRemote("EnterRealm")
Remotes.GunFired = getOrMakeRemote("GunFired")
Remotes.PremiumTowerUnlocked = getOrMakeRemote("PremiumTowerUnlocked")

return Remotes
