--!strict
-- src/server/LightingSetup.luau
-- Dials in atmospheric lighting + post-effects on the Lighting service so
-- emissive materials glow and the scene feels warmer. Called once at boot
-- with daytime defaults, and then re-applied per realm when the player
-- enters one (forest + space switch to a dark moonlit sky).

local Lighting = game:GetService("Lighting")

local LightingSetup = {}

-- Ensure a single instance of each post-effect exists on Lighting and
-- return it so the setup + realm calls can mutate it in place.
local function ensureAtmosphere(): Atmosphere
	local a = Lighting:FindFirstChildOfClass("Atmosphere")
	if not a then
		a = Instance.new("Atmosphere")
		a.Parent = Lighting
	end
	return a
end

local function ensureBloom(): BloomEffect
	local b = Lighting:FindFirstChildOfClass("BloomEffect")
	if not b then
		b = Instance.new("BloomEffect")
		b.Parent = Lighting
	end
	return b
end

local function ensureSunRays(): SunRaysEffect
	local s = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if not s then
		s = Instance.new("SunRaysEffect")
		s.Parent = Lighting
	end
	return s
end

local function ensureColorCorrection(): ColorCorrectionEffect
	local c = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if not c then
		c = Instance.new("ColorCorrectionEffect")
		c.Parent = Lighting
	end
	return c
end

-- Removes any child Sky on Lighting so the default procedural sky is
-- restored. Used when switching back to the day preset.
local function clearSky()
	local existing = Lighting:FindFirstChildOfClass("Sky")
	if existing then
		existing:Destroy()
	end
end

-- Daytime preset used by the lobby, defense, frost, and desert realms.
local function applyDayPreset()
	clearSky()
	Lighting.Ambient = Color3.fromRGB(75, 68, 55)
	Lighting.OutdoorAmbient = Color3.fromRGB(130, 120, 100)
	Lighting.Brightness = 2.4
	Lighting.ClockTime = 14.5
	Lighting.ExposureCompensation = 0.1
	Lighting.FogColor = Color3.fromRGB(180, 170, 150)
	Lighting.FogEnd = 100000

	-- Lighter atmosphere: lower density reduces the GPU fill cost on
	-- mobile while still providing a warm golden haze around the arena.
	local atmosphere = ensureAtmosphere()
	atmosphere.Density = 0.2
	atmosphere.Offset = 0.15
	atmosphere.Color = Color3.fromRGB(210, 185, 145)
	atmosphere.Decay = Color3.fromRGB(115, 118, 130)
	atmosphere.Glare = 0.35
	atmosphere.Haze = 1.0

	-- Smaller bloom is much cheaper on mobile GPUs and still gives that
	-- soft glow on neon towers / projectiles.
	local bloom = ensureBloom()
	bloom.Intensity = 0.45
	bloom.Size = 18
	bloom.Threshold = 0.92

	-- SunRays disabled — expensive full-screen pass with minimal visual
	-- payoff in a top-down game. Saves ~2-3 FPS on low-end devices.
	local sunRays = ensureSunRays()
	sunRays.Intensity = 0
	sunRays.Spread = 0

	-- Warmer, slightly more saturated color grading so the palette
	-- looks richer without extra geometry or lights.
	local colorCorrection = ensureColorCorrection()
	colorCorrection.Saturation = 0.18
	colorCorrection.Contrast = 0.1
	colorCorrection.TintColor = Color3.fromRGB(255, 245, 228)
end

-- Nighttime preset used by forest + space (the final 2 realms). The
-- sky is made dark by setting ClockTime to midnight (no sun), and the
-- scene is kept well-lit by drastically boosting Ambient, OutdoorAmbient
-- and Brightness so moonlight + fill light mimic the daytime luminance.
-- This avoids the unreliable "empty Sky faces" trick and consistently
-- gives a dark star-lit sky with a bright arena underneath.
local function applyNightPreset()
	clearSky()
	Lighting.Ambient = Color3.fromRGB(110, 105, 95)
	Lighting.OutdoorAmbient = Color3.fromRGB(200, 190, 170)
	Lighting.Brightness = 4
	Lighting.ClockTime = 0.1
	Lighting.ExposureCompensation = 0.3
	Lighting.FogColor = Color3.fromRGB(18, 20, 34)
	Lighting.FogEnd = 100000

	-- Atmosphere: thin and very dark so the sky itself reads as night
	-- without fogging out the playable area.
	local atmosphere = ensureAtmosphere()
	atmosphere.Density = 0.12
	atmosphere.Offset = 0.25
	atmosphere.Color = Color3.fromRGB(14, 16, 28)
	atmosphere.Decay = Color3.fromRGB(6, 8, 16)
	atmosphere.Glare = 0
	atmosphere.Haze = 0.2

	-- Tighter bloom for a moody glow without tanking mobile FPS.
	local bloom = ensureBloom()
	bloom.Intensity = 0.7
	bloom.Size = 20
	bloom.Threshold = 0.88

	local sunRays = ensureSunRays()
	sunRays.Intensity = 0
	sunRays.Spread = 0

	-- Cool blue tint so night realms feel distinctly different from day.
	local colorCorrection = ensureColorCorrection()
	colorCorrection.Saturation = 0.08
	colorCorrection.Contrast = 0.12
	colorCorrection.TintColor = Color3.fromRGB(220, 225, 255)
end

function LightingSetup.apply()
	applyDayPreset()
end

-- Switches lighting based on which realm the player just entered.
-- `"lobby"` or any early-progression realm → day preset. Forest and
-- space → night preset so the sky reads as dark and ominous for the
-- final two stages.
function LightingSetup.applyForRealm(realmName: string)
	if realmName == "forest" or realmName == "space" then
		applyNightPreset()
	else
		applyDayPreset()
	end
end

return LightingSetup
