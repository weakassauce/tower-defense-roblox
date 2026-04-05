--!strict
-- src/server/TowerManager.luau
-- Owns placed towers and their projectiles. Each tick, towers find the
-- nearest enemy in range and fire. Projectiles travel toward their target
-- and deal damage (+ splash/slow/poison) on contact.
-- Ported from towers.js.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Require these as direct module references so Luau's type checker can
-- resolve `TowerDefs.TowerDef` and `EnemyManager.Enemy` from their exports.
local Config = require(ReplicatedStorage.Shared.Config)
local TowerDefs = require(ReplicatedStorage.Shared.TowerDefs)
local EnemyManager = require(script.Parent.EnemyManager)

local TowerManager = {}

export type Tower = {
	gx: number,
	gy: number,
	towerType: string,
	def: TowerDefs.TowerDef,
	model: Model,
	orb: Part,
	x: number,
	z: number,
	projectileY: number,
	fireCooldown: number,
}

type Projectile = {
	part: Part,
	target: EnemyManager.Enemy,
	tower: Tower,
	speed: number,
}

local towers: { Tower } = {}
local projectiles: { Projectile } = {}
local towerFolder: Folder? = nil
local projectileFolder: Folder? = nil

-- --- Tower model builder ---
-- First-pass tower: flat stone base + colored body + glowing orb on top.
-- We'll add per-type composite models in a later pass.

local function buildTowerModel(def: TowerDefs.TowerDef, pos: Vector3): (Model, Part)
	local model = Instance.new("Model")
	model.Name = "Tower_" .. def.name

	local base = Instance.new("Part")
	base.Name = "Base"
	base.Size = Vector3.new(5, 1, 5)
	base.Position = Vector3.new(pos.X, 0.5, pos.Z)
	base.Color = Color3.fromRGB(97, 97, 97)
	base.Material = Enum.Material.Slate
	base.Anchored = true
	base.CanCollide = false
	base.TopSurface = Enum.SurfaceType.Smooth
	base.BottomSurface = Enum.SurfaceType.Smooth
	base.Parent = model

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(3, 5, 3)
	body.Position = Vector3.new(pos.X, 3.5, pos.Z)
	body.Color = def.color
	body.Material = Enum.Material.Brick
	body.Anchored = true
	body.CanCollide = false
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Parent = model

	local orb = Instance.new("Part")
	orb.Name = "Orb"
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(2, 2, 2)
	orb.Position = Vector3.new(pos.X, 7, pos.Z)
	orb.Color = def.accent
	orb.Material = Enum.Material.Neon
	orb.Anchored = true
	orb.CanCollide = false
	orb.Parent = model

	-- Subtle light for bloom-ish glow
	local light = Instance.new("PointLight")
	light.Color = def.accent
	light.Range = 12
	light.Brightness = 2
	light.Parent = orb

	model.PrimaryPart = base
	return model, orb
end

-- --- Public API ---

function TowerManager.init()
	local existingTowers = workspace:FindFirstChild("Towers")
	if existingTowers then
		existingTowers:Destroy()
	end
	local existingProj = workspace:FindFirstChild("Projectiles")
	if existingProj then
		existingProj:Destroy()
	end

	local tf = Instance.new("Folder")
	tf.Name = "Towers"
	tf.Parent = workspace
	towerFolder = tf

	local pf = Instance.new("Folder")
	pf.Name = "Projectiles"
	pf.Parent = workspace
	projectileFolder = pf

	towers = {}
	projectiles = {}
end

function TowerManager.isOccupied(gx: number, gy: number): boolean
	for _, t in towers do
		if t.gx == gx and t.gy == gy then
			return true
		end
	end
	return false
end

function TowerManager.place(gx: number, gy: number, towerType: string): Tower?
	assert(towerFolder, "TowerManager.init() must be called first")
	local def = TowerDefs[towerType]
	if not def then
		warn(string.format("Unknown tower type: %s", towerType))
		return nil
	end

	local pos = Config.gridToWorld(gx, gy)
	local model, orb = buildTowerModel(def, pos)
	model.Parent = towerFolder

	local tower: Tower = {
		gx = gx,
		gy = gy,
		towerType = towerType,
		def = def,
		model = model,
		orb = orb,
		x = pos.X,
		z = pos.Z,
		projectileY = 7, -- matches the orb height
		fireCooldown = 0,
	}
	table.insert(towers, tower)
	return tower
end

function TowerManager.remove(tower: Tower)
	tower.model:Destroy()
	for i = #towers, 1, -1 do
		if towers[i] == tower then
			table.remove(towers, i)
			break
		end
	end
end

function TowerManager.getAt(gx: number, gy: number): Tower?
	for _, t in towers do
		if t.gx == gx and t.gy == gy then
			return t
		end
	end
	return nil
end

-- --- Firing and projectile motion ---

local function fire(tower: Tower, target: EnemyManager.Enemy)
	assert(projectileFolder, "projectileFolder not initialized")

	local proj = Instance.new("Part")
	proj.Name = "Projectile"
	proj.Shape = Enum.PartType.Ball
	proj.Size = Vector3.new(0.8, 0.8, 0.8)
	proj.Color = tower.def.projectileColor
	proj.Material = Enum.Material.Neon
	proj.Anchored = true
	proj.CanCollide = false
	proj.Position = Vector3.new(tower.x, tower.projectileY, tower.z)
	proj.Parent = projectileFolder

	table.insert(projectiles, {
		part = proj,
		target = target,
		tower = tower,
		speed = tower.def.projectileSpeed,
	})
end

local function updateProjectiles(dt: number)
	for i = #projectiles, 1, -1 do
		local p = projectiles[i]

		if not p.target.alive then
			p.part:Destroy()
			table.remove(projectiles, i)
			continue
		end

		local targetPos = p.target.root.Position
		local toTarget = targetPos - p.part.Position
		local dist = toTarget.Magnitude
		local step = p.speed * dt

		if dist <= step + 1 then
			-- Hit
			local def = p.tower.def

			if def.splash > 0 then
				for _, enemy in EnemyManager.getAlive() do
					local d = (enemy.root.Position - targetPos).Magnitude
					if d <= def.splash then
						local falloff = 1 - (d / def.splash) * 0.5
						EnemyManager.damage(enemy, math.floor(def.damage * falloff))
					end
				end
			else
				EnemyManager.damage(p.target, def.damage)
			end

			if def.slowFactor and p.target.alive then
				EnemyManager.applySlow(p.target, def.slowFactor, def.slowDuration or 2)
			end
			if def.poisonDps and p.target.alive then
				EnemyManager.applyPoison(p.target, def.poisonDps, def.poisonDuration or 4)
			end

			p.part:Destroy()
			table.remove(projectiles, i)
		else
			p.part.Position = p.part.Position + toTarget.Unit * step
		end
	end
end

function TowerManager.update(dt: number)
	for _, tower in towers do
		tower.fireCooldown -= dt
		if tower.fireCooldown > 0 then
			continue
		end

		-- Find the nearest enemy in range
		local nearest: EnemyManager.Enemy? = nil
		local nearestDist = math.huge
		for _, enemy in EnemyManager.getAlive() do
			local dx = enemy.root.Position.X - tower.x
			local dz = enemy.root.Position.Z - tower.z
			local d = math.sqrt(dx * dx + dz * dz)
			if d <= tower.def.range and d < nearestDist then
				nearest = enemy
				nearestDist = d
			end
		end

		if nearest then
			fire(tower, nearest)
			tower.fireCooldown = 1 / tower.def.fireRate

			-- Rotate the orb to face the target (flavor, not strictly required)
			local targetPos = nearest.root.Position
			local orbPos = tower.orb.Position
			tower.orb.CFrame =
				CFrame.lookAt(orbPos, Vector3.new(targetPos.X, orbPos.Y, targetPos.Z))
		end
	end

	updateProjectiles(dt)
end

function TowerManager.clear()
	for _, t in towers do
		t.model:Destroy()
	end
	for _, p in projectiles do
		p.part:Destroy()
	end
	towers = {}
	projectiles = {}
end

return TowerManager
