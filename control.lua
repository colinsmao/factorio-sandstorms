---@alias SolarPanelPair { entity: LuaEntity, score: number }

---@class NoiseParams
---@field type "linear"|"x"
---@field noise_expression? LuaNamedNoiseExpression
local NoiseParams = {}

---@class StormParams A storm
---@field intensity number intensity of i corresponds to a minimum solar multiplier of (1-i)
---@field start_tick integer
---@field duration number
---@field ramp_duration number
---@field solar_panels SolarPanelPair[] list of solar panels at storm start, sorted once, O(1) pop
---@field additional_solar_panels SolarPanelPair[] heap of additional solar panels, O(log n) pop
---@field noise_params NoiseParams
local StormParams = {}

local function on_init()
  ---@type {[string]: number}
  storage.original_solar = {}  -- surface_name: original solar_power_multiplier
  ---@type {[string]: StormParams}
  storage.active_storms = {}  -- surface_name: StormParams
end
script.on_init(on_init)

local function smootherstep(x)
  if x <= 0 then return 0 end
  if x >= 1 then return 1 end
  return x * x * x * (x * (6 * x - 15) + 10)
end

---@param return_pair boolean?
local function box_muller_transform(return_pair)  -- converts uniform to normal distribution
  local u1 = math.random()
  local u2 = math.random()
  local r = math.sqrt(-2 * math.log(u1))
  local theta = 2 * math.pi * u2
  local z0 = r * math.cos(theta)
  if return_pair then
    local z1 = r * math.sin(theta)  -- another independent standard normal variable
    return {z0, z1}
  else
    return z0
  end
end

---Sample from a normal distribution N(mean, variance)
---@param mean number
---@param variance number
---@return number
local function sample_normal(mean, variance)
  local std_dev = math.sqrt(variance)
  return mean + std_dev * box_muller_transform()
end

---Sample from a Poisson distribution P(lambda)
---@param lambda number
---@return integer
local function sample_poisson(lambda)
  -- Knuth algorithm
  local L = math.exp(-lambda)
  local k = 0
  local p = 1
  repeat
      k = k + 1
      p = p * math.random()
  until p <= L
  return k - 1
end

---Sample approximately from a binomial distribution B(k, p)
---@param k integer
---@param p number
---@return integer ret guaranteed in range [0, k]
local function sample_binomial_approx(k, p)
  local kp = k * p
  local sample
  if kp < 5 then  -- approximated by poisson P(k*p) for small k*p
    sample = sample_poisson(k * p)
  else  -- otherwise, approximated by normal distribution N(k*p, k*p*(1-p))
    sample = math.floor(sample_normal(kp, kp * (1 - p)) + 0.5)  -- round to the nearest integer
  end
  if sample < 0 then return 0 end
  if sample > k then return k end
  return sample
end

---@param surface_name string
---@return number solar_power_multiplier
local function get_original_solar(surface_name)
  if storage.original_solar[surface_name] == nil then
    local surface = game.get_surface(surface_name)
    if surface == nil then return 1 end
    storage.original_solar[surface_name] = surface.solar_power_multiplier
  end
  return storage.original_solar[surface_name]
  -- return 1
end

---Sets solar multiplier (accounting for original solar value of surface)
---@param surface LuaSurface
---@param multiplier number
local function set_solar_multiplier(surface, multiplier)
  surface.solar_power_multiplier = get_original_solar(surface.name) * multiplier
  -- game.print("solar for surface "..surface.name.." set to "..get_original_solar(surface.name).." * "..multiplier.." = "..surface.solar_power_multiplier)
end

---@param position MapPosition
---@return number
local function noise_function_linear(position)
  return position.x + position.y
end

---@param surface LuaSurface
---@param intensity number
---@param start_tick integer
---@param duration number
---@param ramp_duration number
local function create_dust_storm(surface, intensity, start_tick, duration, ramp_duration)
  local surface_name = surface.name
  if storage.active_storms[surface_name] ~= nil then
    game.print("failed to create dust storm on surface "..surface_name..": storm already ongoing")
    return
  end
  if intensity < 0 or intensity > 1 then
    game.print("failed to create dust storm on surface "..surface_name.." with intensity = "..intensity)
    return
  end
  if duration <= 0 then
    game.print("failed to create dust storm on surface "..surface_name.." with duration = "..duration)
    return
  end
  ramp_duration = math.min(ramp_duration, duration / 2)

  ---@type NoiseParams
  local noise_params = {
    type = "linear"
  }
  -- get all currently existing solar panels, calculate their score, and sort
  local solar_panels = {}
  if noise_params.type == "linear" then
    local min_score = 0
    local max_score = 0
    for _, panel in pairs(surface.find_entities_filtered{type = "solar-panel"}) do
      if string.sub(panel.name, -6) ~= "-dusty" then
        local score = noise_function_linear(panel.position)
        table.insert(solar_panels, {
          entity = panel,
          score = score
        })
        if score < min_score then min_score = score end
        if score > max_score then max_score = score end
      end
    end
    local score_range = max_score - min_score
    if score_range > 0 then
      for i=1,#solar_panels do
        solar_panels[i].score = solar_panels[i].score / score_range
      end
    end
  end
  table.sort(solar_panels, function(a, b) return a.score > b.score end)  -- descending sort (to pop from end)

  storage.active_storms[surface_name] = {
    intensity = intensity,
    start_tick = start_tick,
    duration = duration,
    ramp_duration = ramp_duration,
    solar_panels = solar_panels,
    additional_solar_panels = {},
    noise_params = noise_params
  }
  game.print("created storm on surface "..surface_name.." with intensity="..intensity.." and duration="..duration)
end


---@param panel LuaEntity
---@param new_name string prototype name of the new entity
---@param health_multiplier? number default 1
---@return LuaEntity? new_panel
local function replace_panel(panel, new_name, health_multiplier)
  local surface = panel.surface
  local position = panel.position
  local force = panel.force
  local quality = panel.quality
  local health = panel.health
  panel.destroy{raise_destroy=false}
  local new_panel = surface.create_entity{
    name = new_name,
    position = position,
    force = force,
    quality = quality,
    create_build_effect_smoke = false,
  }
  if new_panel ~= nil then
    new_panel.health = health * (health_multiplier or 1)
  else
    game.print("failed to make " .. new_name .. " at " .. position)
  end
  return new_panel
end

---@param panel LuaEntity
---@param health_multiplier? number default 1
---@return LuaEntity? new_panel
local function make_panel_dusty(panel, health_multiplier)
  if panel.type ~= "solar-panel" then return end
  if string.sub(panel.name, -6) == "-dusty" then return end
  return replace_panel(panel, panel.name .. '-dusty', health_multiplier)
end

---@param panel LuaEntity
---@param health_multiplier? number default 1
---@return LuaEntity? new_panel
local function make_panel_clean(panel, health_multiplier)
  if panel.type ~= "solar-panel" then return end
  if string.sub(panel.name, -6) ~= "-dusty" then return end
  return replace_panel(panel, string.sub(panel.name, 1, -7), health_multiplier)
end

---@param surface LuaSurface
local function check_clean_all_panels(surface)
  for _, panel in pairs(surface.find_entities_filtered{type = "solar-panel"}) do
    if panel.get_health_ratio() == 1 then
      make_panel_clean(panel)
    end
  end
end


---@param storm StormParams
local function add_dust_from_storm(storm)
  -- stochastic binomial sampling to determine how many remaining clean panels become dusty
  local num_dusty = sample_binomial_approx(#storm.solar_panels, 0.002 * storm.intensity)
  for i=1,num_dusty do
    local last = storm.solar_panels[#storm.solar_panels]  -- peek the last element O(1)
    if last.entity.valid then
      make_panel_dusty(last.entity)  -- 0.5
    end
    table.remove(storm.solar_panels)  -- pop the last element O(1)
  end
end


local TICK_RATE = 10
---@param tick integer
local function update_storms(tick)
  -- storms
  local storms_to_delete = {}
  for surface_name, storm in pairs(storage.active_storms) do
    local surface = game.get_surface(surface_name)
    if surface == nil then
      table.insert(storms_to_delete, surface_name)  -- flag for deletion
    else
      if tick > storm.start_tick + storm.duration then  -- storm is over
        set_solar_multiplier(surface, 1)  -- reset surface
        table.insert(storms_to_delete, surface_name)  -- flag for deletion
      else
        local delta = math.min(tick - storm.start_tick, storm.start_tick + storm.duration - tick)
        if delta < storm.ramp_duration + TICK_RATE then  -- only update during ramp up/down of storm
          local multiplier = 1 - smootherstep(delta / storm.ramp_duration) * storm.intensity
          set_solar_multiplier(surface, multiplier)
        end
        add_dust_from_storm(storm)
      end
    end
  end
  for _, surface_name in pairs(storms_to_delete) do  -- delete finished storms
    storage.active_storms[surface_name] = nil
  end
end


-- prime 50423, 1321
---@param tickdata NthTickEventData
local function main_nth_tick(tickdata)
  local tick = tickdata.tick
  update_storms(tick)
  for _, surface in pairs(game.surfaces) do
    check_clean_all_panels(surface)
  end
end
script.on_nth_tick(TICK_RATE, main_nth_tick)


---@param event EventData.on_script_trigger_effect
local function on_script_trigger(event)
  if string.sub(event.effect_id, 1, 13) == "create-ghost-" then
    local surface = game.get_surface(event.surface_index)
    if surface == nil then return end
    surface.create_entity{
      name = "entity-ghost",
      position = event.source_entity.position,
      force = event.source_entity.force,
      inner_name = string.sub(event.effect_id, 14),  -- "create-ghost-{inner_name}"
      expires = true,
      create_build_effect_smoke = false,
    }
  end
end
script.on_event(defines.events.on_script_trigger_effect, on_script_trigger)


script.on_event("left-click", function(event)
  local player = game.get_player(event.player_index)
  if player == nil then return end
  local cursor_stack = player.cursor_stack
  if cursor_stack == nil or not cursor_stack.valid_for_read then return end
  if cursor_stack.name == "iron-plate" then
    create_dust_storm(player.surface, 0.5, event.tick, 600, 60)
  elseif cursor_stack.name == "copper-plate" then
    
  elseif cursor_stack.name == "plastic-bar" then
    for _, panel in pairs(player.surface.find_entities_filtered{type = "solar-panel"}) do
      make_panel_clean(panel)
    end
  end
end)

script.on_event("right-click", function(event)
  local player = game.get_player(event.player_index)
  if player == nil then return end
  local cursor_stack = player.cursor_stack
  if cursor_stack == nil or not cursor_stack.valid_for_read then return end
  if cursor_stack.name == "iron-plate" then
    create_dust_storm(player.surface, 0.9, event.tick, 300, 120)
  elseif cursor_stack.name == "copper-plate" then
    
  elseif cursor_stack.name == "plastic-bar" then
    for _, panel in pairs(player.surface.find_entities_filtered{type = "solar-panel"}) do
      make_panel_dusty(panel, 0.5)
    end
  end
end)


local function reverse_table(tbl, value)
  for k,v in pairs(tbl) do
    if v == value then
      return k
    end
  end
end

local function print_event(event)
  game.print(reverse_table(defines.events, event.name)..","..reverse_table(defines.gui_type, event.gui_type))
  game.print(serpent.block(event.element))
  if event.item ~= nil then
    game.print(event.item.item_number)
  end
end

