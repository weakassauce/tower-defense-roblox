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
	-- Magazine in the grip
	local magazine = makePart(
		"Mag",
		Vector3.new(0.28, 0.4, 0.22),
		Color3.fromRGB(28, 28, 34),
		Enum.Material.Metal
	)
	weldTo(handle, magazine, CFrame.new(0, -0.5, -0.05))
	-- Front sight blade
	local frontSight = makePart(
		"FrontSight",
		Vector3.new(0.06, 0.16, 0.12),
		Color3.fromRGB(20, 20, 24),
		Enum.Material.Metal
	)
	weldTo(handle, frontSight, CFrame.new(0, 0.84, -0.92))
	-- Rear sight notch
	local rearSight = makePart(
		"RearSight",
		Vector3.new(0.28, 0.14, 0.1),
		Color3.fromRGB(20, 20, 24),
		Enum.Material.Metal
	)
	weldTo(handle, rearSight, CFrame.new(0, 0.84, 0.18))
	-- Trigger
	local trigger = makePart(
		"Trigger",
		Vector3.new(0.06, 0.18, 0.08),
		Color3.fromRGB(30, 30, 36),
		Enum.Material.Metal
	)
	weldTo(handle, trigger, CFrame.new(0, 0.24, -0.1))
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
	-- Magazine slotted under the receiver
	local magazine =
		makePart("Mag", Vector3.new(0.3, 0.7, 0.5), Color3.fromRGB(28, 28, 34), Enum.Material.Metal)
	weldTo(handle, magazine, CFrame.new(0, -0.05, -0.4))
	-- Front sight post above the muzzle
	local frontSight = makePart(
		"FrontSight",
		Vector3.new(0.06, 0.2, 0.1),
		Color3.fromRGB(20, 20, 24),
		Enum.Material.Metal
	)
	weldTo(handle, frontSight, CFrame.new(0, 0.78, -3))
	-- Foregrip handle under the barrel
	local foregrip = makePart(
		"Foregrip",
		Vector3.new(0.14, 0.45, 0.3),
		Color3.fromRGB(42, 28, 16),
		Enum.Material.Wood
	)
	weldTo(handle, foregrip, CFrame.new(0, 0.25, -1.6))
	-- Charging handle sticking out of the receiver
	local chargeHandle = makePart(
		"ChargeHandle",
		Vector3.new(0.12, 0.12, 0.4),
		Color3.fromRGB(80, 80, 90),
		Enum.Material.Metal
	)
	weldTo(handle, chargeHandle, CFrame.new(0.3, 0.7, 0.15))
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
	-- Front bead sight on the top barrel
	local bead = makePart(
		"Bead",
		Vector3.new(0.08, 0.1, 0.1),
		Color3.fromRGB(180, 150, 60),
		Enum.Material.Metal
	)
	weldTo(handle, bead, CFrame.new(0, 0.88, -2.3))
	-- Pump action rails along the under-barrel
	local rail = makePart(
		"Rail",
		Vector3.new(0.1, 0.1, 1.6),
		Color3.fromRGB(30, 30, 36),
		Enum.Material.Metal
	)
	weldTo(handle, rail, CFrame.new(0, 0.2, -1.35))
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
	-- Bolt handle sticking out of the receiver
	local bolt = makePart(
		"Bolt",
		Vector3.new(0.16, 0.16, 0.4),
		Color3.fromRGB(80, 80, 90),
		Enum.Material.Metal
	)
	weldTo(handle, bolt, CFrame.new(0.35, 0.78, 0.2))
	-- Long detachable magazine
	local magazine = makePart(
		"Mag",
		Vector3.new(0.3, 0.55, 0.6),
		Color3.fromRGB(28, 28, 34),
		Enum.Material.Metal
	)
	weldTo(handle, magazine, CFrame.new(0, 0.05, -0.2))
	-- Muzzle brake vent slot
	local brake = makePart(
		"BrakeVent",
		Vector3.new(0.08, 0.36, 0.2),
		Color3.fromRGB(18, 18, 22),
		Enum.Material.Metal
	)
	weldTo(handle, brake, CFrame.new(0, 0.65, -4.55))
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
	-- Glowing energy vents along the top of the chassis
	for i = 0, 2 do
		local vent = makePart(
			"Vent_" .. i,
			Vector3.new(0.35, 0.08, 0.18),
			Color3.fromRGB(140, 200, 255),
			Enum.Material.Neon
		)
		weldTo(handle, vent, CFrame.new(0, 1.02, -0.1 - i * 0.4))
	end
	-- Muzzle iris (decorative ring around the neon core)
	local iris = makePart(
		"MuzzleIris",
		Vector3.new(0.55, 0.55, 0.12),
		Color3.fromRGB(60, 70, 110),
		Enum.Material.Metal
	)
	weldTo(handle, iris, CFrame.new(0, 0.65, -2.98))
end

local function buildSmg(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.4, 0.9, 0.35)
	grip.Color = Color3.fromRGB(45, 40, 45)
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

local function decorateSmg(handle: Part)
	local receiver = makePart(
		"Receiver",
		Vector3.new(0.4, 0.45, 1.1),
		Color3.fromRGB(55, 55, 62),
		Enum.Material.Metal
	)
	weldTo(handle, receiver, CFrame.new(0, 0.5, -0.25))
	local barrel = makePart(
		"Barrel",
		Vector3.new(0.18, 0.18, 1.1),
		Color3.fromRGB(30, 30, 36),
		Enum.Material.Metal
	)
	weldTo(handle, barrel, CFrame.new(0, 0.5, -1.2))
	local mag = makePart(
		"Mag",
		Vector3.new(0.25, 0.55, 0.22),
		Color3.fromRGB(28, 28, 34),
		Enum.Material.Metal
	)
	weldTo(handle, mag, CFrame.new(0, -0.4, -0.05))
	local stock = makePart(
		"Stock",
		Vector3.new(0.28, 0.35, 0.7),
		Color3.fromRGB(40, 40, 48),
		Enum.Material.Metal
	)
	weldTo(handle, stock, CFrame.new(0, 0.55, 0.55))
	local suppressor = makePart(
		"Suppressor",
		Vector3.new(0.28, 0.28, 0.5),
		Color3.fromRGB(22, 22, 26),
		Enum.Material.Metal
	)
	weldTo(handle, suppressor, CFrame.new(0, 0.5, -2))
	-- Front sight blade
	local frontSight = makePart(
		"FrontSight",
		Vector3.new(0.05, 0.16, 0.1),
		Color3.fromRGB(20, 20, 24),
		Enum.Material.Metal
	)
	weldTo(handle, frontSight, CFrame.new(0, 0.76, -1.6))
end

local function buildMinigun(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.5, 1.1, 0.45)
	grip.Color = Color3.fromRGB(38, 38, 44)
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

local function decorateMinigun(handle: Part)
	-- Massive cylindrical body housing the rotating barrels
	local body = makePart(
		"Body",
		Vector3.new(0.9, 0.9, 1.6),
		Color3.fromRGB(60, 58, 66),
		Enum.Material.Metal
	)
	weldTo(handle, body, CFrame.new(0, 0.7, -0.5))
	-- Six rotary barrels arranged in a tight ring sticking out the front
	for i = 0, 5 do
		local angle = (i / 6) * math.pi * 2
		local bx = math.cos(angle) * 0.22
		local by = 0.7 + math.sin(angle) * 0.22
		local barrel = makePart(
			"RotBarrel_" .. i,
			Vector3.new(0.16, 0.16, 2.2),
			Color3.fromRGB(25, 25, 30),
			Enum.Material.Metal
		)
		weldTo(handle, barrel, CFrame.new(bx, by, -2))
	end
	-- Front barrel collar ring
	local collar = makePart(
		"Collar",
		Vector3.new(0.85, 0.85, 0.2),
		Color3.fromRGB(45, 45, 52),
		Enum.Material.Metal
	)
	weldTo(handle, collar, CFrame.new(0, 0.7, -1.4))
	-- Ammo belt box on the side
	local ammoBox = makePart(
		"AmmoBox",
		Vector3.new(0.35, 0.55, 0.7),
		Color3.fromRGB(28, 28, 34),
		Enum.Material.Metal
	)
	weldTo(handle, ammoBox, CFrame.new(0.5, 0.55, -0.1))
	-- Rear stock
	local stock = makePart(
		"Stock",
		Vector3.new(0.4, 0.55, 0.9),
		Color3.fromRGB(38, 38, 44),
		Enum.Material.Metal
	)
	weldTo(handle, stock, CFrame.new(0, 0.7, 0.85))
	-- Glowing charge indicator on top
	local indicator = makePart(
		"Indicator",
		Vector3.new(0.2, 0.1, 0.4),
		Color3.fromRGB(255, 140, 50),
		Enum.Material.Neon
	)
	weldTo(handle, indicator, CFrame.new(0, 1.2, -0.2))
end

local function buildStarfire(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.45, 1.1, 0.4)
	grip.Color = Color3.fromRGB(60, 52, 100)
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

local function decorateStarfire(handle: Part)
	-- Sleek void-metal chassis
	local chassis = makePart(
		"Chassis",
		Vector3.new(0.55, 0.7, 1.8),
		Color3.fromRGB(80, 70, 130),
		Enum.Material.Metal
	)
	weldTo(handle, chassis, CFrame.new(0, 0.65, -0.4))
	-- Elongated crystal barrel with a glowing core
	local barrel = makePart(
		"Barrel",
		Vector3.new(0.3, 0.3, 3.2),
		Color3.fromRGB(50, 45, 85),
		Enum.Material.Metal
	)
	weldTo(handle, barrel, CFrame.new(0, 0.65, -2.6))
	local core = makePart(
		"Core",
		Vector3.new(0.22, 0.22, 3),
		Color3.fromRGB(255, 220, 140),
		Enum.Material.Neon
	)
	weldTo(handle, core, CFrame.new(0, 0.65, -2.6))
	core.Transparency = 0.3
	-- Glowing crystal at the muzzle tip
	local muzzleCrystal = makePart(
		"MuzzleCrystal",
		Vector3.new(0.5, 0.5, 0.4),
		Color3.fromRGB(255, 230, 160),
		Enum.Material.Neon
	)
	weldTo(handle, muzzleCrystal, CFrame.new(0, 0.65, -4.3))
	local muzzleLight = Instance.new("PointLight")
	muzzleLight.Color = Color3.fromRGB(255, 220, 140)
	muzzleLight.Range = 8
	muzzleLight.Brightness = 2
	muzzleLight.Parent = muzzleCrystal
	-- Long scope with orange neon lens
	local scope = makePart(
		"Scope",
		Vector3.new(0.4, 0.4, 1.8),
		Color3.fromRGB(28, 24, 50),
		Enum.Material.Metal
	)
	weldTo(handle, scope, CFrame.new(0, 1.05, -0.5))
	local lens = makePart(
		"Lens",
		Vector3.new(0.32, 0.32, 0.1),
		Color3.fromRGB(255, 210, 130),
		Enum.Material.Neon
	)
	weldTo(handle, lens, CFrame.new(0, 1.05, -1.4))
	-- Stock
	local stock = makePart(
		"Stock",
		Vector3.new(0.4, 0.6, 1.2),
		Color3.fromRGB(60, 52, 100),
		Enum.Material.Metal
	)
	weldTo(handle, stock, CFrame.new(0, 0.65, 0.85))
	-- Twin glowing fins mounted on the sides of the chassis
	for i = 1, 2 do
		local side = if i == 1 then -1 else 1
		local fin = makePart(
			"Fin_" .. i,
			Vector3.new(0.1, 0.55, 1.4),
			Color3.fromRGB(255, 200, 120),
			Enum.Material.Neon
		)
		fin.Transparency = 0.25
		weldTo(handle, fin, CFrame.new(side * 0.4, 0.65, -0.9))
	end
	-- Magazine
	local mag = makePart(
		"Mag",
		Vector3.new(0.32, 0.55, 0.6),
		Color3.fromRGB(40, 36, 70),
		Enum.Material.Metal
	)
	weldTo(handle, mag, CFrame.new(0, 0.05, -0.2))
end

-- --- Revolver: 6-shooter with wooden grip and heavy frame ---

local function buildRevolver(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.42, 1, 0.32)
	grip.Color = Color3.fromRGB(80, 45, 20)
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

local function decorateRevolver(handle: Part)
	local frame = makePart(
		"Frame",
		Vector3.new(0.48, 0.6, 0.95),
		Color3.fromRGB(180, 160, 70),
		Enum.Material.Metal
	)
	weldTo(handle, frame, CFrame.new(0, 0.55, -0.2))
	local cylinder = makePart(
		"Cylinder",
		Vector3.new(0.58, 0.58, 0.6),
		Color3.fromRGB(200, 180, 90),
		Enum.Material.Metal
	)
	weldTo(handle, cylinder, CFrame.new(0, 0.55, -0.35))
	for i = 1, 6 do
		local angle = (i / 6) * math.pi * 2
		local chamber = makePart(
			"Chamber_" .. i,
			Vector3.new(0.12, 0.12, 0.62),
			Color3.fromRGB(30, 20, 10),
			Enum.Material.Metal
		)
		local ox = math.cos(angle) * 0.19
		local oy = math.sin(angle) * 0.19
		weldTo(handle, chamber, CFrame.new(ox, 0.55 + oy, -0.35))
	end
	local barrel = makePart(
		"Barrel",
		Vector3.new(0.28, 0.32, 1.6),
		Color3.fromRGB(45, 45, 50),
		Enum.Material.Metal
	)
	weldTo(handle, barrel, CFrame.new(0, 0.55, -1.4))
	local sightRib = makePart(
		"SightRib",
		Vector3.new(0.08, 0.08, 1.5),
		Color3.fromRGB(30, 30, 34),
		Enum.Material.Metal
	)
	weldTo(handle, sightRib, CFrame.new(0, 0.75, -1.4))
	local frontSight = makePart(
		"FrontSight",
		Vector3.new(0.06, 0.16, 0.1),
		Color3.fromRGB(20, 20, 24),
		Enum.Material.Metal
	)
	weldTo(handle, frontSight, CFrame.new(0, 0.87, -2.15))
	local hammer = makePart(
		"Hammer",
		Vector3.new(0.14, 0.2, 0.2),
		Color3.fromRGB(40, 40, 46),
		Enum.Material.Metal
	)
	weldTo(handle, hammer, CFrame.new(0, 0.82, 0.2))
	local trigger = makePart(
		"Trigger",
		Vector3.new(0.06, 0.2, 0.08),
		Color3.fromRGB(30, 30, 36),
		Enum.Material.Metal
	)
	weldTo(handle, trigger, CFrame.new(0, 0.2, -0.1))
	local triggerGuard = makePart(
		"TriggerGuard",
		Vector3.new(0.08, 0.32, 0.42),
		Color3.fromRGB(180, 160, 70),
		Enum.Material.Metal
	)
	weldTo(handle, triggerGuard, CFrame.new(0, 0.1, -0.05))
end

-- --- Flamethrower: fuel tank backpack + nozzle + pilot light ---

local function buildFlamethrower(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.42, 1, 0.35)
	grip.Color = Color3.fromRGB(35, 35, 40)
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

local function decorateFlamethrower(handle: Part)
	local body = makePart(
		"Body",
		Vector3.new(0.5, 0.55, 1.3),
		Color3.fromRGB(95, 55, 25),
		Enum.Material.Metal
	)
	weldTo(handle, body, CFrame.new(0, 0.55, -0.2))
	-- Large main nozzle tube
	local nozzle = makePart(
		"Nozzle",
		Vector3.new(0.48, 0.48, 2.2),
		Color3.fromRGB(45, 28, 14),
		Enum.Material.Metal
	)
	weldTo(handle, nozzle, CFrame.new(0, 0.55, -1.7))
	-- Flared tip
	local tip = makePart(
		"Tip",
		Vector3.new(0.72, 0.72, 0.35),
		Color3.fromRGB(25, 15, 8),
		Enum.Material.Metal
	)
	weldTo(handle, tip, CFrame.new(0, 0.55, -2.95))
	-- Glowing pilot flame at the tip
	local pilot = makePart(
		"Pilot",
		Vector3.new(0.2, 0.35, 0.2),
		Color3.fromRGB(255, 150, 40),
		Enum.Material.Neon
	)
	weldTo(handle, pilot, CFrame.new(0.35, 0.7, -2.9))
	local pilotLight = Instance.new("PointLight")
	pilotLight.Color = Color3.fromRGB(255, 140, 30)
	pilotLight.Range = 6
	pilotLight.Brightness = 1.4
	pilotLight.Parent = pilot
	-- Fuel tanks bolted to the underside
	local tankL = makePart(
		"TankL",
		Vector3.new(0.3, 0.8, 0.7),
		Color3.fromRGB(180, 40, 30),
		Enum.Material.Metal
	)
	weldTo(handle, tankL, CFrame.new(-0.2, 0.1, -0.3))
	local tankR = makePart(
		"TankR",
		Vector3.new(0.3, 0.8, 0.7),
		Color3.fromRGB(180, 40, 30),
		Enum.Material.Metal
	)
	weldTo(handle, tankR, CFrame.new(0.2, 0.1, -0.3))
	-- Fuel hose arcing from tank to body
	local hose = makePart(
		"Hose",
		Vector3.new(0.14, 0.14, 0.7),
		Color3.fromRGB(28, 28, 32),
		Enum.Material.Metal
	)
	weldTo(handle, hose, CFrame.new(0, -0.05, 0.1) * CFrame.Angles(math.rad(35), 0, 0))
	-- Valve wheel on top
	local valve = makePart(
		"Valve",
		Vector3.new(0.32, 0.12, 0.32),
		Color3.fromRGB(220, 180, 80),
		Enum.Material.Metal
	)
	weldTo(handle, valve, CFrame.new(0, 0.95, -0.05))
end

-- --- Railgun: long rectangular rail assembly with exposed coils ---

local function buildRailgun(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.42, 1.1, 0.35)
	grip.Color = Color3.fromRGB(30, 32, 42)
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

local function decorateRailgun(handle: Part)
	-- Main chassis block
	local chassis = makePart(
		"Chassis",
		Vector3.new(0.55, 0.75, 2.4),
		Color3.fromRGB(50, 55, 70),
		Enum.Material.Metal
	)
	weldTo(handle, chassis, CFrame.new(0, 0.7, -0.6))
	-- Top rail
	local railTop = makePart(
		"RailTop",
		Vector3.new(0.22, 0.22, 4.2),
		Color3.fromRGB(180, 190, 220),
		Enum.Material.Metal
	)
	weldTo(handle, railTop, CFrame.new(0, 1.1, -2))
	-- Bottom rail
	local railBot = makePart(
		"RailBot",
		Vector3.new(0.22, 0.22, 4.2),
		Color3.fromRGB(180, 190, 220),
		Enum.Material.Metal
	)
	weldTo(handle, railBot, CFrame.new(0, 0.3, -2))
	-- Glowing coil between the rails
	local coil = makePart(
		"Coil",
		Vector3.new(0.18, 0.6, 3.8),
		Color3.fromRGB(100, 220, 255),
		Enum.Material.Neon
	)
	coil.Transparency = 0.3
	weldTo(handle, coil, CFrame.new(0, 0.7, -2))
	-- Five ribbed coil rings along the barrel for silhouette detail
	for i = 0, 4 do
		local z = -0.6 - (i * 0.75)
		local ring = makePart(
			"Ring_" .. i,
			Vector3.new(0.42, 0.42, 0.14),
			Color3.fromRGB(80, 100, 140),
			Enum.Material.Metal
		)
		weldTo(handle, ring, CFrame.new(0, 0.7, z))
	end
	-- Capacitor bank on top
	local capacitor = makePart(
		"Capacitor",
		Vector3.new(0.42, 0.32, 0.8),
		Color3.fromRGB(40, 50, 70),
		Enum.Material.Metal
	)
	weldTo(handle, capacitor, CFrame.new(0, 1.35, -0.2))
	local capLight = makePart(
		"CapLight",
		Vector3.new(0.12, 0.08, 0.62),
		Color3.fromRGB(100, 220, 255),
		Enum.Material.Neon
	)
	weldTo(handle, capLight, CFrame.new(0, 1.52, -0.2))
	-- Stock
	local stock = makePart(
		"Stock",
		Vector3.new(0.38, 0.55, 1),
		Color3.fromRGB(30, 32, 42),
		Enum.Material.Metal
	)
	weldTo(handle, stock, CFrame.new(0, 0.65, 0.75))
	-- Scope
	local scope = makePart(
		"Scope",
		Vector3.new(0.3, 0.3, 0.9),
		Color3.fromRGB(20, 24, 34),
		Enum.Material.Metal
	)
	weldTo(handle, scope, CFrame.new(0, 1.3, 0.2))
	local scopeLens = makePart(
		"Lens",
		Vector3.new(0.24, 0.24, 0.08),
		Color3.fromRGB(120, 220, 255),
		Enum.Material.Neon
	)
	weldTo(handle, scopeLens, CFrame.new(0, 1.3, -0.3))
	local capLightSrc = Instance.new("PointLight")
	capLightSrc.Color = Color3.fromRGB(100, 220, 255)
	capLightSrc.Range = 8
	capLightSrc.Brightness = 1.6
	capLightSrc.Parent = capLight
end

-- --- Void Reaper: premium auto-shotgun with twin barrels + void glow ---

local function buildVoidReaper(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.44, 1, 0.38)
	grip.Color = Color3.fromRGB(30, 12, 50)
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

local function decorateVoidReaper(handle: Part)
	local chassis = makePart(
		"Chassis",
		Vector3.new(0.6, 0.78, 1.6),
		Color3.fromRGB(55, 25, 90),
		Enum.Material.Metal
	)
	weldTo(handle, chassis, CFrame.new(0, 0.6, -0.4))
	-- Twin wide barrels side-by-side
	local barrelL = makePart(
		"BarrelL",
		Vector3.new(0.35, 0.35, 2.4),
		Color3.fromRGB(28, 12, 50),
		Enum.Material.Metal
	)
	weldTo(handle, barrelL, CFrame.new(-0.18, 0.7, -1.6))
	local barrelR = makePart(
		"BarrelR",
		Vector3.new(0.35, 0.35, 2.4),
		Color3.fromRGB(28, 12, 50),
		Enum.Material.Metal
	)
	weldTo(handle, barrelR, CFrame.new(0.18, 0.7, -1.6))
	-- Glowing void cores inside each barrel
	local coreL = makePart(
		"CoreL",
		Vector3.new(0.22, 0.22, 2.2),
		Color3.fromRGB(200, 80, 255),
		Enum.Material.Neon
	)
	coreL.Transparency = 0.2
	weldTo(handle, coreL, CFrame.new(-0.18, 0.7, -1.6))
	local coreR = makePart(
		"CoreR",
		Vector3.new(0.22, 0.22, 2.2),
		Color3.fromRGB(200, 80, 255),
		Enum.Material.Neon
	)
	coreR.Transparency = 0.2
	weldTo(handle, coreR, CFrame.new(0.18, 0.7, -1.6))
	-- Muzzle shroud crystal
	local muzzle = makePart(
		"Muzzle",
		Vector3.new(0.78, 0.6, 0.45),
		Color3.fromRGB(180, 70, 240),
		Enum.Material.Neon
	)
	muzzle.Transparency = 0.15
	weldTo(handle, muzzle, CFrame.new(0, 0.7, -2.95))
	local muzzleLight = Instance.new("PointLight")
	muzzleLight.Color = Color3.fromRGB(200, 80, 255)
	muzzleLight.Range = 10
	muzzleLight.Brightness = 2
	muzzleLight.Parent = muzzle
	-- Drum magazine under the chassis
	local drum = makePart(
		"Drum",
		Vector3.new(0.75, 0.75, 0.6),
		Color3.fromRGB(40, 18, 70),
		Enum.Material.Metal
	)
	weldTo(handle, drum, CFrame.new(0, 0.08, -0.3))
	local drumGlow = makePart(
		"DrumGlow",
		Vector3.new(0.4, 0.4, 0.62),
		Color3.fromRGB(200, 80, 255),
		Enum.Material.Neon
	)
	drumGlow.Transparency = 0.4
	weldTo(handle, drumGlow, CFrame.new(0, 0.08, -0.3))
	-- Twin glowing spines along the top
	for i = 1, 2 do
		local side = if i == 1 then -1 else 1
		local spine = makePart(
			"Spine_" .. i,
			Vector3.new(0.08, 0.35, 1.3),
			Color3.fromRGB(220, 100, 255),
			Enum.Material.Neon
		)
		spine.Transparency = 0.2
		weldTo(handle, spine, CFrame.new(side * 0.28, 1.08, -0.5))
	end
	-- Stock
	local stock = makePart(
		"Stock",
		Vector3.new(0.38, 0.6, 0.95),
		Color3.fromRGB(30, 12, 50),
		Enum.Material.Metal
	)
	weldTo(handle, stock, CFrame.new(0, 0.55, 0.7))
	-- Trigger
	local trigger = makePart(
		"Trigger",
		Vector3.new(0.06, 0.22, 0.1),
		Color3.fromRGB(220, 100, 255),
		Enum.Material.Neon
	)
	weldTo(handle, trigger, CFrame.new(0, 0.18, -0.1))
end

-- --- Starter: rusty dented pistol. Visually the same silhouette as the
-- regular pistol but rust-brown colored and missing detail, so it reads
-- as a hand-me-down weapon the player should upgrade away from.

local function buildStarter(): Part
	local grip = Instance.new("Part")
	grip.Name = "Handle"
	grip.Size = Vector3.new(0.38, 0.85, 0.28)
	grip.Color = Color3.fromRGB(60, 40, 20)
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

local function decorateStarter(handle: Part)
	-- Rusty slide
	local slide = makePart(
		"Slide",
		Vector3.new(0.4, 0.4, 1.1),
		Color3.fromRGB(110, 75, 45),
		Enum.Material.CorrodedMetal
	)
	weldTo(handle, slide, CFrame.new(0, 0.52, -0.3))
	-- Short dented barrel
	local barrel = makePart(
		"Barrel",
		Vector3.new(0.2, 0.2, 0.45),
		Color3.fromRGB(80, 55, 30),
		Enum.Material.CorrodedMetal
	)
	weldTo(handle, barrel, CFrame.new(0, 0.52, -0.92))
	-- Minimal trigger guard
	local guard = makePart(
		"Guard",
		Vector3.new(0.1, 0.3, 0.38),
		Color3.fromRGB(65, 45, 25),
		Enum.Material.CorrodedMetal
	)
	weldTo(handle, guard, CFrame.new(0, 0.14, -0.18))
	-- Tiny magazine
	local magazine = makePart(
		"Mag",
		Vector3.new(0.24, 0.32, 0.2),
		Color3.fromRGB(45, 30, 15),
		Enum.Material.CorrodedMetal
	)
	weldTo(handle, magazine, CFrame.new(0, -0.45, -0.05))
end

local GUN_BUILDERS: { [string]: { build: () -> Part, decorate: (Part) -> () } } = {
	starter = { build = buildStarter, decorate = decorateStarter },
	pistol = { build = buildPistol, decorate = decoratePistol },
	rifle = { build = buildRifle, decorate = decorateRifle },
	shotgun = { build = buildShotgun, decorate = decorateShotgun },
	sniper = { build = buildSniper, decorate = decorateSniper },
	plasma = { build = buildPlasma, decorate = decoratePlasma },
	smg = { build = buildSmg, decorate = decorateSmg },
	minigun = { build = buildMinigun, decorate = decorateMinigun },
	starfire = { build = buildStarfire, decorate = decorateStarfire },
	revolver = { build = buildRevolver, decorate = decorateRevolver },
	flamethrower = { build = buildFlamethrower, decorate = decorateFlamethrower },
	railgun = { build = buildRailgun, decorate = decorateRailgun },
	void_reaper = { build = buildVoidReaper, decorate = decorateVoidReaper },
}

-- Builds a display-only copy of a gun as a Model (no Tool wrapper) so
-- shops / previews can drop it into a ViewportFrame. The decorations use
-- weldTo which attaches to handle.Parent, so we parent the handle to the
-- model before calling decorate.
function PlayerGun.buildDisplayModel(gunKey: string): Model?
	local builder = GUN_BUILDERS[gunKey]
	if not builder then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "Display_" .. gunKey
	local handle = builder.build()
	handle.Name = "Handle"
	handle.Parent = model
	builder.decorate(handle)
	model.PrimaryPart = handle
	return model
end

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
