--!strict
-- src/shared/init.luau
-- ReplicatedStorage.Shared — aggregates all shared modules so both server
-- and client can do `local Shared = require(ReplicatedStorage.Shared)`.

local Shared = {}

Shared.Config = require(script.Config)
Shared.TowerDefs = require(script.TowerDefs)
Shared.WaveConfig = require(script.WaveConfig)
Shared.RealmDefs = require(script.RealmDefs)
Shared.Guns = require(script.Guns)
Shared.GamePassConfig = require(script.GamePassConfig)

return Shared
