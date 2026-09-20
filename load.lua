-- Must match keySystem.endpoint/product in src/brand/mio.json. The
-- Worker-served stub (microhub-auth/src/loaderStub.ts) substitutes its own
-- origin here instead; this file has no request to take one from.
local AUTH_BASE = "https://auth.mwstack.dev"
local PRODUCT = "mio"
local REPO = "sysscan/miopub"
local BRANCH = "main"

local GAMES = {
	{ slug = "phantom-forces", placeIds = { 292439477 } },
	{ slug = "apocalypse-rising-2", placeIds = { 863266079 }, universeIds = { 358276974 } },
	{ slug = "arsenal", placeIds = { 286090429 }, universeIds = { 111958650 } },
	{ slug = "overkill", placeIds = { 124842176624983 }, universeIds = { 8420998291 } },
	{ slug = "killstreak", placeIds = { 90184287580174 } },
	{ slug = "eclipsis-match", placeIds = { 617834035 }, universeIds = { 252475658 } },
	{ slug = "aqp-deadzone", placeIds = { 106920577206536 }, universeIds = { 9889811676 } },
	{ slug = "frontlines", placeIds = { 5938036553 }, universeIds = { 2132866904 } },
	{ slug = "scp-roleplay", placeIds = { 5041144419 }, universeIds = { 1742264997 } },
	{ slug = "murder-mystery-2", placeIds = { 142823291 }, universeIds = { 66654135 } },
	{ slug = "steal-and-collect", placeIds = { 131309726917016 }, universeIds = { 10326012859 } },
}

local ALIASES = {
	ar2 = "apocalypse-rising-2",
	mm2 = "murder-mystery-2",
	pf = "phantom-forces",
	aqp = "aqp-deadzone",
	eclipsis = "eclipsis-match",
	scp = "scp-roleplay",
}

local function contains(values, target): boolean
	for _, value in ipairs(values or {}) do
		if value == target then
			return true
		end
	end
	return false
end

local function selectGame(): string?
	local forced = shared.__HubForceGame
	if typeof(forced) == "string" and forced ~= "" then
		forced = forced:lower():gsub("^games/", ""):gsub("/init%.lua$", "")
		return ALIASES[forced] or forced
	end
	for _, entry in ipairs(GAMES) do
		if contains(entry.placeIds, game.PlaceId) or contains(entry.universeIds, game.GameId) then
			return entry.slug
		end
	end
	return nil
end

-- Resolve an executor global by name. On some executors (e.g. Potassium) these
-- are chunk globals not mirrored into getgenv(), so probe every environment.
local function execGlobal(name: string): any
	local direct = rawget(getfenv and getfenv() or {}, name)
	if direct ~= nil then
		return direct
	end
	if typeof(getgenv) == "function" then
		local ok, env = pcall(getgenv)
		if ok and type(env) == "table" and env[name] ~= nil then
			return env[name]
		end
	end
	if type(_G) == "table" and _G[name] ~= nil then
		return _G[name]
	end
	return nil
end

-- A body is only a real bundle if it is non-empty and not an HTTP error page.
-- GitHub returns "404: Not Found" (and HttpGet returns "" on non-200), so both
-- must be rejected or the loader will try to compile the error text as Lua.
local function looksLikeBundle(body: any): boolean
	if typeof(body) ~= "string" or #body == 0 then
		return false
	end
	local head = body:sub(1, 32)
	if head:find("^404: Not Found") or head:find("^400:") or head:find("^Not Found") then
		return false
	end
	return true
end

-- request-style HTTP: request / http_request / syn.request. Returns (body, statusCode).
local function requestBody(url: string): (string?, number?)
	local candidates = { execGlobal("request"), execGlobal("http_request") }
	local synTbl = execGlobal("syn")
	if type(synTbl) == "table" then
		table.insert(candidates, synTbl.request)
	end
	for _, reqFn in ipairs(candidates) do
		if typeof(reqFn) == "function" then
			local ok, res = pcall(reqFn, { Url = url, Method = "GET" })
			if ok and type(res) == "table" then
				local status = tonumber(res.StatusCode or res.status_code or res.Status)
				local body = res.Body or res.body
				if (status == nil or status == 200) and looksLikeBundle(body) then
					return body, status
				end
				return nil, status
			end
		end
	end
	return nil, nil
end

-- Tries every HTTP path an executor might expose; returns (body, diagnostic).
-- diagnostic is a short human string describing why it failed (for error output).
local function fetch(url: string): (string?, string?)
	if typeof(game) == "Instance" then
		local ok, body = pcall(function()
			return game:HttpGet(url, true)
		end)
		if ok and looksLikeBundle(body) then
			return body, nil
		end
	end
	local httpGet = execGlobal("HttpGet")
	if typeof(httpGet) == "function" then
		local ok, body = pcall(httpGet, url)
		if ok and looksLikeBundle(body) then
			return body, nil
		end
	end
	local body, status = requestBody(url)
	if looksLikeBundle(body) then
		return body, nil
	end
	return nil, status and ("HTTP " .. tostring(status)) or "empty/unreachable"
end

if typeof(loadstring) ~= "function" then
	error("[MioHub] loadstring unavailable", 0)
end

local executionEnvironment = _G
if typeof(getfenv) == "function" then
	local ok, environment = pcall(getfenv, 0)
	if ok and type(environment) == "table" then
		executionEnvironment = environment
	end
end

local slug = selectGame()
if not slug then
	error("[MioHub] this game is not supported (PlaceId " .. tostring(game.PlaceId) .. ", GameId " .. tostring(game.GameId) .. ")", 0)
end

local now = typeof(tick) == "function" and tick() or os.time()
local stamp = tostring(math.floor(now))

-- Mio releases are generated locally with the maximum/hardened profile. Do not
-- fall back to a readable bundle: a missing Mio artifact is a release error,
-- not permission to launch an unprotected build.
local FILENAMES = {
	"bundle-obfuscated.lua",
}

-- The jsDelivr mirror used to be a second source here. It is gone: with the
-- artifact pinned to a hash the Worker publishes, a second origin buys
-- availability rather than security, and it is one more party able to serve
-- bytes to every client. If launch-success telemetry ever argues for it back,
-- re-adding it BEHIND the pin is a safe reversal.
local attempts = {}
for _, filename in ipairs(FILENAMES) do
	local path = "games/" .. slug .. "/" .. filename
	table.insert(attempts, {
		path = path,
		url = "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/" .. path .. "?t=" .. stamp,
	})
end

-- What this pin is and is not. The stub itself arrives from the Worker over
-- TLS, and the bundle is useless without that same Worker (key gate, session,
-- container fetch) -- so taking the expected hash from it is not circular, and
-- it is not "tamper-proof" either. Its one job is to stop the artifact host,
-- or anything on the path to it, from serving code the Worker never blessed.
--
-- Fetched BEFORE the artifact so a failing verifier never costs a download,
-- and carrying the same cache-buster, or a stale hash could be served against
-- a fresh bundle.
local expectedHash = nil
do
	local hashUrl = AUTH_BASE .. "/v1/artifact-hash-by-game/" .. PRODUCT .. "/" .. slug .. "?t=" .. stamp
	local ok, body = pcall(fetch, hashUrl)
	if ok and typeof(body) == "string" then
		expectedHash = body:match('"public_artifact_sha256"%s*:%s*"([0-9a-f]+)"')
	end
end
if typeof(expectedHash) ~= "string" or #expectedHash ~= 64 then
	-- Fails closed, including when the hash endpoint is simply unreachable.
	-- A verifier that gives up under pressure verifies nothing: whoever can
	-- tamper with the artifact leg can usually also blackhole this one. The
	-- availability cost is near zero, because a Worker that cannot answer this
	-- also cannot authorise the session the bundle needs moments later.
	error("[MioHub] could not verify this release; try again shortly.", 0)
end

-- SHA-256 of the fetched artifact, so the bundle is verified against the hash
-- the Worker records for the active release BEFORE it is executed.
--
-- Pure Luau is the path that must always work: Potassium and Volt document a
-- crypt.hash, but Isaeva ships no crypt library at all, and neither catalog
-- documents the algorithm spelling or the return encoding. So crypt.hash is
-- used only as a fast path, and only after it reproduces a known answer.
local SHA256_K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256Hex(message: string): string
	local bxor, band, bnot = bit32.bxor, bit32.band, bit32.bnot
	local rrotate, rshift = bit32.rrotate, bit32.rshift
	local byte, char, rep, format = string.byte, string.char, string.rep, string.format
	local h1, h2, h3, h4 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
	local h5, h6, h7, h8 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

	local length = #message
	local bitLength = length * 8
	local zeros = 64 - ((length + 9) % 64)
	if zeros == 64 then
		zeros = 0
	end
	local high = math.floor(bitLength / 4294967296)
	local low = bitLength % 4294967296
	local tail = char(
		band(rshift(high, 24), 255), band(rshift(high, 16), 255), band(rshift(high, 8), 255), band(high, 255),
		band(rshift(low, 24), 255), band(rshift(low, 16), 255), band(rshift(low, 8), 255), band(low, 255)
	)
	local padded = message .. char(128) .. rep(char(0), zeros) .. tail

	-- string.unpack reads a big-endian word in one call instead of four
	-- string.byte calls; it exists in Roblox Luau, but fall back rather than
	-- assume it on every executor.
	local unpack32 = string.unpack
	local words = table.create and table.create(64) or {}

	for offset = 1, #padded, 64 do
		if unpack32 then
			for index = 1, 16 do
				words[index] = unpack32(">I4", padded, offset + (index - 1) * 4)
			end
		else
			for index = 1, 16 do
				local at = offset + (index - 1) * 4
				local b1, b2, b3, b4 = byte(padded, at, at + 3)
				words[index] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
			end
		end
		for index = 17, 64 do
			local w15 = words[index - 15]
			local w2 = words[index - 2]
			local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
			local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19), rshift(w2, 10))
			words[index] = (words[index - 16] + s0 + words[index - 7] + s1) % 4294967296
		end

		local a, b, c, d = h1, h2, h3, h4
		local e, f, g, hh = h5, h6, h7, h8
		for index = 1, 64 do
			local s1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = (hh + s1 + ch + SHA256_K[index] + words[index]) % 4294967296
			local s0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			local t2 = (s0 + maj) % 4294967296
			hh = g
			g = f
			f = e
			e = (d + t1) % 4294967296
			d = c
			c = b
			b = a
			a = (t1 + t2) % 4294967296
		end

		h1 = (h1 + a) % 4294967296
		h2 = (h2 + b) % 4294967296
		h3 = (h3 + c) % 4294967296
		h4 = (h4 + d) % 4294967296
		h5 = (h5 + e) % 4294967296
		h6 = (h6 + f) % 4294967296
		h7 = (h7 + g) % 4294967296
		h8 = (h8 + hh) % 4294967296
	end

	return format("%08x%08x%08x%08x%08x%08x%08x%08x", h1, h2, h3, h4, h5, h6, h7, h8)
end

-- SHA-256("abc"), the standard vector. Used to decide whether an executor's
-- crypt.hash can be trusted for this, rather than guessing its spelling.
local SHA256_ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

local function toHex(value: any): string?
	if typeof(value) ~= "string" then
		return nil
	end
	if #value == 64 and value:lower():match("^[0-9a-f]+$") then
		return value:lower()
	end
	-- Some executors return the 32 raw digest bytes instead of hex.
	if #value == 32 then
		local out = {}
		for index = 1, 32 do
			out[index] = string.format("%02x", string.byte(value, index))
		end
		return table.concat(out)
	end
	return nil
end

-- Resolved once per boot. The self-test IS the probe: it stays correct if an
-- executor changes its algorithm spelling, which a value recorded at build
-- time would not.
local function resolveHasher()
	local cryptApi = execGlobal("crypt")
	if type(cryptApi) == "table" and typeof(cryptApi.hash) == "function" then
		for _, algorithm in ipairs({ "sha256", "SHA-256", "sha-256", "SHA256" }) do
			local ok, result = pcall(cryptApi.hash, "abc", algorithm)
			if ok and toHex(result) == SHA256_ABC then
				return function(data: string): string?
					local hashOk, digest = pcall(cryptApi.hash, data, algorithm)
					if hashOk then
						return toHex(digest)
					end
					return nil
				end
			end
		end
	end
	return nil
end

local fastHash = resolveHasher()

local function artifactHash(data: string): string?
	if fastHash then
		local digest = fastHash(data)
		if digest then
			return digest
		end
	end
	local ok, digest = pcall(sha256Hex, data)
	if ok then
		return digest
	end
	return nil
end

local lastError = nil
for _, attempt in ipairs(attempts) do
	local ok, source, diag = pcall(fetch, attempt.url)
	if ok and looksLikeBundle(source) then
		-- looksLikeBundle stays as a cheap pre-filter: it turns an HTTP error
		-- page into a clear message instead of an integrity failure.
		local actualHash = artifactHash(source)
		if actualHash ~= expectedHash then
			-- No expected-vs-actual in the message: that would make the loader
			-- a hash oracle for anyone probing it.
			error("[MioHub] bundle integrity check failed; this build was not published by MioHub.", 0)
		end
		local fn, compileError = loadstring(source, "@miohub/" .. attempt.path)
		if fn then
			return fn(executionEnvironment)
		end
		lastError = "compile error: " .. tostring(compileError)
	elseif ok then
		lastError = tostring(diag) .. " @ " .. attempt.url
	else
		lastError = tostring(source)
	end
end

error(
	"[MioHub] could not download the bundle for "
		.. slug
		.. " ("
		.. tostring(lastError)
		.. "). Checked "
		.. REPO
		.. " for games/"
		.. slug
		.. "/{"
		.. table.concat(FILENAMES, ", ")
		.. "} — none were reachable. Publish the obfuscated bundle for this game, or load from a local workspace.",
	0
)
