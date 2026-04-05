--!strict
-- src/client/PlayerGun.luau
-- Owns the visual gun model in the player's hand. A Tool is spawned
-- with a Handle part + decorative parts welded on, then parented to
-- the Character so Roblox auto-equips it in the right hand. The model
-- is torn down and rebuilt when the equipped gun changes, and hidden
-- (Tool unparented) while the player is selecting a tower to build.

local Players = game:GetService("Players")

local PlayerGun = {}

local player = Players.LocalPlayer
local currentTool: Tool? = nil
local currentGunKey: string? = nil
local visible = true

-- --- Primitive helpers ---

local function makePart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

-- Uses an explicit Weld with C0 instead of a WeldConstraint so the
-- offset is deterministic regardless of when the handle gets moved to
-- the player's hand by the Humanoid. The gun builders lay decorations
-- out in a "-Z barrel forward, +Y top" local frame, which matches the
-- default Roblox Tool held orientation (with identity Tool.Grip).
local function weldTo(handle: Part, part: Part, cf: CFrame)
	part.Parent = handle.Parent
	local w = Instance.new("Weld")
	w.Part0 = handle
	w.Part1 = part
	w.C0 = cf
	w.C1 = CFrame.new()
	w.Parent = part
end

-- --- Per-gun visual builders ---
-- Each returns the Handle part, which becomes the Tool's grip. All
-- builders orient the barrel along the local -Z direction so the gun
-- points forward from the player's hand naturally.

local function buildPistol(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.4, 0.9, 0.3)
	grip.Color = Color3.fromRGB(35, 25, 18)
	grip.Material = Enum.Material.Wood
	grip.Anchored = false
	grip.CanCollide = false
	grip.CanQuery = false
	grip.CanTouch = false
	grip.Massless = true
	grip.TopSurface = Enum.SurfaceType.Smooth
	grip.BottomSurface = Enum.SurfaceType.Smooth
	return grip
end

local function decoratePistol(handle: Part)
	local slide = makePart(
		"Slide",
		Vector3.new(0.42, 0.42, 1.2),
		Color3.fromRGB(60, 60, 70),
		Enum.Material.Metal
	)
	weldTo(handle, slide, CFrame.new(0, 0.55, -0.35))
	local barrel = makePart(
		"Barrel",
		Vector3.new(0.22, 0.22, 0.5),
		Color3.fromRGB(40, 40, 45),
		Enum.Material.Metal
	)
	weldTo(handle, barrel, CFrame.new(0, 0.55, -1.05))
	local guard = makePart(
		"Guard",
		Vector3.new(0.12, 0.35, 0.45),
		Color3.fromRGB(45, 45, 55),
		Enum.Material.Metal
	)
	weldTo(handle, guard, CFrame.new(0, 0.15, -0.2))
end

local function buildRifle(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.4, 1, 0.35)
	grip.Color = Color3.fromRGB(55, 35, 20)
	grip.Material = Enum.Material.Wood
	grip.Anchored = false
	grip.CanCollide = false
	grip.CanQuery = false
	grip.CanTouch = false
	grip.Massless = true
	grip.TopSurface = Enum.SurfaceType.Smooth
	grip.BottomSurface = Enum.SurfaceType.Smooth
	return grip
end

local function decorateRifle(handle: Part)
	local receiver = makePart(
		"Receiver",
		Vector3.new(0.45, 0.55, 1.3),
		Color3.fromRGB(50, 50, 58),
		Enum.Material.Metal
	)
	weldTo(handle, receiver, CFrame.new(0, 0.55, -0.2))
	local barrel = makePart(
		"Barrel",
		Vector3.new(0.22, 0.22, 2.4),
		Color3.fromRGB(35, 35, 40),
		Enum.Material.Metal
	)
	weldTo(handle, barrel, CFrame.new(0, 0.55, -1.9))
	local stock = makePart(
		"Stock",
		Vector3.new(0.35, 0.55, 1),
		Color3.fromRGB(55, 35, 20),
		Enum.Material.Wood
	)
	weldTo(handle, stock, CFrame.new(0, 0.55, 0.8))
	local scope = makePart(
		"Scope",
		Vector3.new(0.28, 0.28, 0.7),
		Color3.fromRGB(25, 25, 30),
		Enum.Material.Metal
	)
	weldTo(handle, scope, CFrame.new(0, 0.95, -0.2))
	local scopeLens = makePart(
		"Lens",
		Vector3.new(0.22, 0.22, 0.08),
		Color3.fromRGB(120, 200, 255),
		Enum.Material.Neon
	)
	weldTo(handle, scopeLens, CFrame.new(0, 0.95, -0.55))
end

local function buildShotgun(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.4, 1, 0.35)
	grip.Color = Color3.fromRGB(70, 45, 25)
	grip.Material = Enum.Material.Wood
	grip.Anchored = false
	grip.CanCollide = false
	grip.CanQuery = false
	grip.CanTouch = false
	grip.Massless = true
	grip.TopSurface = Enum.SurfaceType.Smooth
	grip.BottomSurface = Enum.SurfaceType.Smooth
	return grip
end

local function decorateShotgun(handle: Part)
	-- Double-barrel up top + under, with a pump ring between
	local barrelTop = makePart(
		"BarrelTop",
		Vector3.new(0.3, 0.3, 2.2),
		Color3.fromRGB(40, 40, 45),
		Enum.Material.Metal
	)
	weldTo(handle, barrelTop, CFrame.new(0, 0.7, -1.35))
	local barrelBot = makePart(
		"BarrelBot",
		Vector3.new(0.3, 0.3, 2.2),
		Color3.fromRGB(40, 40, 45),
		Enum.Material.Metal
	)
	weldTo(handle, barrelBot, CFrame.new(0, 0.4, -1.35))
	local pump = makePart(
		"Pump",
		Vector3.new(0.48, 0.5, 0.5),
		Color3.fromRGB(70, 45, 25),
		Enum.Material.Wood
	)
	weldTo(handle, pump, CFrame.new(0, 0.55, -0.9))
	local receiver = makePart(
		"Receiver",
		Vector3.new(0.45, 0.5, 0.7),
		Color3.fromRGB(75, 55, 30),
		Enum.Material.Wood
	)
	weldTo(handle, receiver, CFrame.new(0, 0.55, -0.15))
	local stock = makePart(
		"Stock",
		Vector3.new(0.35, 0.55, 1),
		Color3.fromRGB(70, 45, 25),
		Enum.Material.Wood
	)
	weldTo(handle, stock, CFrame.new(0, 0.55, 0.75))
end

local function buildSniper(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.4, 1.1, 0.35)
	grip.Color = Color3.fromRGB(40, 30, 18)
	grip.Material = Enum.Material.Wood
	grip.Anchored = false
	grip.CanCollide = false
	grip.CanQuery = false
	grip.CanTouch = false
	grip.Massless = true
	grip.TopSurface = Enum.SurfaceType.Smooth
	grip.BottomSurface = Enum.SurfaceType.Smooth
	return grip
end

local function decorateSniper(handle: Part)
	local receiver = makePart(
		"Receiver",
		Vector3.new(0.5, 0.6, 1.5),
		Color3.fromRGB(42, 42, 48),
		Enum.Material.Metal
	)
	weldTo(handle, receiver, CFrame.new(0, 0.65, -0.2))
	local barrel = makePart(
		"Barrel",
		Vector3.new(0.22, 0.22, 3.6),
		Color3.fromRGB(25, 25, 30),
		Enum.Material.Metal
	)
	weldTo(handle, barrel, CFrame.new(0, 0.65, -2.75))
	local muzzle = makePart(
		"Muzzle",
		Vector3.new(0.32, 0.32, 0.25),
		Color3.fromRGB(20, 20, 25),
		Enum.Material.Metal
	)
	weldTo(handle, muzzle, CFrame.new(0, 0.65, -4.6))
	local stock = makePart(
		"Stock",
		Vector3.new(0.38, 0.6, 1.2),
		Color3.fromRGB(40, 30, 18),
		Enum.Material.Wood
	)
	weldTo(handle, stock, CFrame.new(0, 0.65, 0.95))
	local scopeBody = makePart(
		"Scope",
		Vector3.new(0.42, 0.42, 1.4),
		Color3.fromRGB(20, 20, 25),
		Enum.Material.Metal
	)
	weldTo(handle, scopeBody, CFrame.new(0, 1.1, -0.3))
	local scopeLens = makePart(
		"Lens",
		Vector3.new(0.35, 0.35, 0.1),
		Color3.fromRGB(150, 210, 255),
		Enum.Material.Neon
	)
	weldTo(handle, scopeLens, CFrame.new(0, 1.1, -1))
	local bipodL = makePart(
		"BipodL",
		Vector3.new(0.08, 0.6, 0.08),
		Color3.fromRGB(55, 55, 60),
		Enum.Material.Metal
	)
	weldTo(handle, bipodL, CFrame.new(-0.2, 0.2, -2.2) * CFrame.Angles(0, 0, math.rad(-20)))
	local bipodR = makePart(
		"BipodR",
		Vector3.new(0.08, 0.6, 0.08),
		Color3.fromRGB(55, 55, 60),
		Enum.Material.Metal
	)
	weldTo(handle, bipodR, CFrame.new(0.2, 0.2, -2.2) * CFrame.Angles(0, 0, math.rad(20)))
end

local function buildPlasma(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.45, 1, 0.4)
	grip.Color = Color3.fromRGB(55, 55, 75)
	grip.Material = Enum.Material.Metal
	grip.Anchored = false
	grip.CanCollide = false
	grip.CanQuery = false
	grip.CanTouch = false
	grip.Massless = true
	grip.TopSurface = Enum.SurfaceType.Smooth
	grip.BottomSurface = Enum.SurfaceType.Smooth
	return grip
end

local function decoratePlasma(handle: Part)
	local chassis = makePart(
		"Chassis",
		Vector3.new(0.55, 0.7, 1.8),
		Color3.fromRGB(110, 120, 160),
		Enum.Material.Metal
	)
	weldTo(handle, chassis, CFrame.new(0, 0.65, -0.5))
	local core = makePart(
		"Core",
		Vector3.new(0.5, 0.5, 0.5),
		Color3.fromRGB(200, 100, 255),
		Enum.Material.Neon
	)
	core.Shape = Enum.PartType.Ball
	weldTo(handle, core, CFrame.new(0, 0.65, -0.5))
	local coreLight = Instance.new("PointLight")
	coreLight.Color = Color3.fromRGB(200, 100, 255)
	coreLight.Range = 8
	coreLight.Brightness = 2
	coreLight.Parent = core
	local barrel = makePart(
		"Barrel",
		Vector3.new(0.3, 0.3, 1.6),
		Color3.fromRGB(80, 90, 130),
		Enum.Material.Metal
	)
	weldTo(handle, barrel, CFrame.new(0, 0.65, -1.95))
	local muzzle = makePart(
		"Muzzle",
		Vector3.new(0.45, 0.45, 0.3),
		Color3.fromRGB(200, 100, 255),
		Enum.Material.Neon
	)
	weldTo(handle, muzzle, CFrame.new(0, 0.65, -2.85))
	-- Side fins
	local finL = makePart(
		"FinL",
		Vector3.new(0.12, 0.8, 1.4),
		Color3.fromRGB(180, 90, 255),
		Enum.Material.Neon
	)
	finL.Transparency = 0.3
	weldTo(handle, finL, CFrame.new(-0.45, 0.65, -1))
	local finR = makePart(
		"FinR",
		Vector3.new(0.12, 0.8, 1.4),
		Color3.fromRGB(180, 90, 255),
		Enum.Material.Neon
	)
	finR.Transparency = 0.3
	weldTo(handle, finR, CFrame.new(0.45, 0.65, -1))
end

local GUN_BUILDERS: { [string]: { build: () -> Part, decorate: (Part) -> () } } = {
	pistol = { build = buildPistol, decorate = decoratePistol },
	rifle = { build = buildRifle, decorate = decorateRifle },
	shotgun = { build = buildShotgun, decorate = decorateShotgun },
	sniper = { build = buildSniper, decorate = decorateSniper },
	plasma = { build = buildPlasma, decorate = decoratePlasma },
}

-- --- Tool lifecycle ---

local function destroyCurrent()
	if currentTool then
		currentTool:Destroy()
		currentTool = nil
	end
end

local function createTool(gunKey: string): Tool?
	local builder = GUN_BUILDERS[gunKey]
	if not builder then
		return nil
	end
	local tool = Instance.new("Tool")
	tool.Name = gunKey
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ManualActivationOnly = true
	-- Use identity rotation for the grip now that AXIS_FIX in weldTo
	-- has rotated all decorations into the +X-forward orientation
	-- Roblox's default Tool grip expects. A small -Y offset tucks the
	-- handle into the fist so decorations aren't clipping the palm.
	tool.Grip = CFrame.new(0, -0.4, 0)

	local handle = builder.build()
	handle.Name = "Handle"
	handle.Parent = tool
	builder.decorate(handle)
	return tool
end

local function mount()
	if not currentGunKey or not visible then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	-- Already mounted and in the character
	if currentTool and currentTool.Parent == character then
		return
	end
	if not currentTool then
		currentTool = createTool(currentGunKey)
		if not currentTool then
			return
		end
	end
	-- Parent to Backpack then explicitly equip via the Humanoid so the
	-- equip animation triggers reliably and the tool ends up in the
	-- character model.
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		currentTool.Parent = backpack
		humanoid:EquipTool(currentTool)
	else
		currentTool.Parent = character
	end
end

local function unmount()
	if not currentTool then
		return
	end
	-- Stash the tool off-screen without destroying it so we don't lose
	-- the welded model. Unequip through the humanoid so the arm drops.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:UnequipTools()
	end
	currentTool.Parent = nil
end

-- --- Public API ---

-- Switch to a new gun (or nil to hold nothing). Tears down the existing
-- Tool and builds a fresh one.
function PlayerGun.setEquipped(gunKey: string?)
	if gunKey == currentGunKey then
		return
	end
	destroyCurrent()
	currentGunKey = gunKey
	if gunKey then
		mount()
	end
end

-- Temporarily hide or show the gun model without forgetting which one
-- is equipped. Used to unequip while the player is selecting a tower
-- from the HUD picker and re-equip once they're done.
function PlayerGun.setVisible(v: boolean)
	if v == visible then
		return
	end
	visible = v
	if visible then
		mount()
	else
		unmount()
	end
end

function PlayerGun.init()
	player.CharacterAdded:Connect(function(_character)
		-- Old tool was parented to the previous character; it's gone
		-- now, so rebuild a fresh one for the new character.
		if currentTool then
			currentTool:Destroy()
			currentTool = nil
		end
		if currentGunKey and visible then
			task.wait(0.3) -- give the character a beat to finish loading
			mount()
		end
	end)
end

return PlayerGun
