--!strict
-- src/server/EnemyManager.luau
-- Owns the list of enemies, spawns them at the first waypoint, walks them
-- through the path, and handles damage / slow / poison / death.
-- Ported from enemies.js.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local _Config = Shared.Config

local EnemyManager = {}

export type EnemyConfig = {
	enemyType: string,
	hp: number,
	speed: number,
	reward: number,
	color: Color3,
	scale: number,
}

export type Enemy = {
	model: Model,
	root: Part,
	hpFill: Frame,
	hp: number,
	maxHp: number,
	speed: number,
	baseSpeed: number,
	reward: number,
	waypointIndex: number,
	alive: boolean,
	reachedEnd: boolean,
	damaged: boolean,
	rewarded: boolean,
	slowTimer: number,
	poisonTimer: number,
	poisonDps: number,
	enemyType: string,
	color: Color3,
}

local enemies: { Enemy } = {}
local waypoints: { Vector3 } = {}
local enemyFolder: Folder? = nil

-- --- Model builders ---

local function buildBody(config: EnemyConfig): Part
	local body = Instance.new("Part")
	body.Shape = Enum.PartType.Ball
	body.Anchored = true
	body.CanCollide = false
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Material = Enum.Material.SmoothPlastic
	body.Color = config.color

	-- Different sizes per type — we'll refine shapes in a later pass
	local baseSize = 4
	if config.enemyType == "troll" then
		baseSize = 6
	elseif config.enemyType == "scout" then
		baseSize = 3
	end
	local s = baseSize * config.scale
	body.Size = Vector3.new(s, s, s)

	return body
end

local function buildHpBar(parent: Part): Frame
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "HpBar"
	billboard.Size = UDim2.fromOffset(80, 10)
	billboard.StudsOffset = Vector3.new(0, parent.Size.Y * 0.6 + 1.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = parent

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(102, 187, 106)
	fill.BorderSizePixel = 0
	fill.Parent = bg

	return fill
end

-- --- Public API ---

function EnemyManager.init(waypointList: { Vector3 })
	waypoints = waypointList

	-- Fresh folder each Play session so hot reloads don't pile up enemies
	local existing = workspace:FindFirstChild("Enemies")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = workspace
	enemyFolder = folder

	enemies = {}
end

function EnemyManager.spawn(config: EnemyConfig): Enemy
	assert(#waypoints > 0, "EnemyManager.init(waypoints) must be called first")
	assert(enemyFolder, "enemyFolder not initialized")

	local body = buildBody(config)
	local hpFill = buildHpBar(body)

	local model = Instance.new("Model")
	model.Name = "Enemy_" .. config.enemyType
	body.Parent = model
	model.PrimaryPart = body

	local startPos = waypoints[1]
	model:PivotTo(CFrame.new(startPos))
	model.Parent = enemyFolder

	local enemy: Enemy = {
		model = model,
		root = body,
		hpFill = hpFill,
		hp = config.hp,
		maxHp = config.hp,
		speed = config.speed,
		baseSpeed = config.speed,
		reward = config.reward,
		waypointIndex = 2, -- head toward the second waypoint (we already stand on the first)
		alive = true,
		reachedEnd = false,
		damaged = false,
		rewarded = false,
		slowTimer = 0,
		poisonTimer = 0,
		poisonDps = 0,
		enemyType = config.enemyType,
		color = config.color,
	}

	table.insert(enemies, enemy)
	return enemy
end

function EnemyManager.damage(enemy: Enemy, amount: number)
	if not enemy.alive then
		return
	end

	enemy.hp -= amount
	if enemy.hp <= 0 then
		enemy.alive = false
		enemy.model:Destroy()
		return
	end

	-- Update HP bar
	local ratio = math.max(0, enemy.hp / enemy.maxHp)
	enemy.hpFill.Size = UDim2.fromScale(ratio, 1)
	if ratio > 0.5 then
		enemy.hpFill.BackgroundColor3 = Color3.fromRGB(102, 187, 106)
	elseif ratio > 0.25 then
		enemy.hpFill.BackgroundColor3 = Color3.fromRGB(255, 167, 38)
	else
		enemy.hpFill.BackgroundColor3 = Color3.fromRGB(239, 83, 80)
	end
end

function EnemyManager.applySlow(enemy: Enemy, factor: number, duration: number)
	enemy.speed = enemy.baseSpeed * factor
	enemy.slowTimer = duration
end

function EnemyManager.applyPoison(enemy: Enemy, dps: number, duration: number)
	enemy.poisonDps = math.max(enemy.poisonDps, dps)
	enemy.poisonTimer = math.max(enemy.poisonTimer, duration)
end

function EnemyManager.getAlive(): { Enemy }
	local alive = {}
	for _, e in enemies do
		if e.alive then
			table.insert(alive, e)
		end
	end
	return alive
end

-- All enemies including dead/reachedEnd ones that haven't been cleaned yet.
-- Used by the main loop to find enemies that need to have their reward
-- paid or HP damage applied to the base.
function EnemyManager.getAll(): { Enemy }
	return enemies
end

function EnemyManager.update(dt: number)
	for _, enemy in enemies do
		if not enemy.alive then
			continue
		end

		-- Slow timer
		if enemy.slowTimer > 0 then
			enemy.slowTimer -= dt
			if enemy.slowTimer <= 0 then
				enemy.speed = enemy.baseSpeed
			end
		end

		-- Poison DoT
		if enemy.poisonTimer > 0 then
			enemy.poisonTimer -= dt
			EnemyManager.damage(enemy, enemy.poisonDps * dt)
			if not enemy.alive then
				continue
			end
		end

		-- Walk toward current waypoint
		local target = waypoints[enemy.waypointIndex]
		if not target then
			continue
		end

		local currentPos = enemy.root.Position
		local toTarget = Vector3.new(target.X - currentPos.X, 0, target.Z - currentPos.Z)
		local dist = toTarget.Magnitude
		local step = enemy.speed * dt

		if dist <= step then
			enemy.waypointIndex += 1
			if enemy.waypointIndex > #waypoints then
				enemy.alive = false
				enemy.reachedEnd = true
				enemy.model:Destroy()
				continue
			end
			enemy.model:PivotTo(CFrame.new(target))
		else
			local dir = toTarget.Unit
			local newPos = currentPos + dir * step
			-- Face direction of travel so multi-part models will look right later
			enemy.model:PivotTo(CFrame.lookAt(newPos, newPos + dir))
		end
	end
end

-- Remove dead enemies from the list (call after damage/reward processing)
function EnemyManager.cleanup()
	for i = #enemies, 1, -1 do
		if not enemies[i].alive then
			table.remove(enemies, i)
		end
	end
end

function EnemyManager.clear()
	for _, enemy in enemies do
		if enemy.alive then
			enemy.model:Destroy()
		end
	end
	enemies = {}
end

return EnemyManager
