local function quality_name(quality)
	if not quality then
		return "normal"
	end
	if type(quality) == "string" then
		return quality
	end
	return quality.name or "normal"
end

local function request_key(name, quality)
	return name .. "\0" .. quality
end

local function deep_copy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[deep_copy(k)] = deep_copy(v)
	end
	return copy
end

local function ensure_storage()
	storage.ick_destroyed_train = storage.ick_destroyed_train or {}
	storage.ick_repair_jobs = storage.ick_repair_jobs or {}
	storage.ick_next_job_id = storage.ick_next_job_id or 1
	storage.ick_awaiting_restore = storage.ick_awaiting_restore or {}
	-- Live registry: every known train's identity, always kept up to date.
	storage.ick_trains = storage.ick_trains or {}
	storage.ick_unit_to_train = storage.ick_unit_to_train or {}
end

local function add_request(request_map, name, quality, fuel_count, grid_count)
	quality = quality_name(quality)
	local key = request_key(name, quality)
	local entry = request_map[key]
	if not entry then
		entry = {name = name, quality = quality, fuel_count = 0, grid_count = 0}
		request_map[key] = entry
	end
	entry.fuel_count = entry.fuel_count + (fuel_count or 0)
	entry.grid_count = entry.grid_count + (grid_count or 0)
end

local function build_insert_plan(request_map)
	local insert_plan = {}
	for _, entry in pairs(request_map) do
		local items = {}
		if entry.fuel_count > 0 then
			local stack_size = 50
			local item_proto = prototypes.item[entry.name]
			if item_proto then
				stack_size = item_proto.stack_size
			end
			local in_inventory = {}
			local remaining = entry.fuel_count
			local stack_index = 0
			while remaining > 0 do
				local count = math.min(remaining, stack_size)
				table.insert(in_inventory, {
					inventory = defines.inventory.fuel,
					stack = stack_index,
					count = count,
				})
				remaining = remaining - count
				stack_index = stack_index + 1
			end
			items.in_inventory = in_inventory
		end
		if entry.grid_count > 0 then
			items.grid_count = entry.grid_count
		end
		if items.in_inventory or items.grid_count then
			table.insert(insert_plan, {
				id = {name = entry.name, quality = entry.quality},
				items = items,
			})
		end
	end
	return insert_plan
end

local function merge_insert_plans(request_map, plans)
	if not plans then
		return
	end
	for _, plan in pairs(plans) do
		local id = plan.id
		if id and id.name then
			local quality = quality_name(id.quality)
			local fuel_count = 0
			local grid_count = 0
			if plan.items then
				if plan.items.grid_count then
					grid_count = plan.items.grid_count
				end
				if plan.items.in_inventory then
					for _, pos in pairs(plan.items.in_inventory) do
						local count = pos.count or 1
						if pos.inventory == defines.inventory.fuel then
							fuel_count = fuel_count + count
						else
							grid_count = grid_count + count
						end
					end
				end
			end
			add_request(request_map, id.name, quality, fuel_count, grid_count)
		end
	end
end

local function count_carriages_from_list(carriages)
	local counts = {}
	for _, carriage in pairs(carriages) do
		local carriage_type = carriage.type
		counts[carriage_type] = (counts[carriage_type] or 0) + 1
	end
	return counts
end

local function count_carriages(train)
	if not train then
		return {}
	end
	return count_carriages_from_list(train.carriages)
end

local function counts_match(expected, actual)
	for carriage_type, count in pairs(expected) do
		if (actual[carriage_type] or 0) ~= count then
			return false
		end
	end
	for carriage_type, count in pairs(actual) do
		if (expected[carriage_type] or 0) ~= count then
			return false
		end
	end
	return true
end

local function train_centroid_from_list(carriages)
	local x, y, n = 0, 0, 0
	for _, carriage in pairs(carriages) do
		local pos = carriage.position
		x = x + pos.x
		y = y + pos.y
		n = n + 1
	end
	if n == 0 then
		return nil
	end
	return {x = x / n, y = y / n}
end

local function positions_close(a, b)
	local dx = a.x - b.x
	local dy = a.y - b.y
	return (dx * dx + dy * dy) <= 0.25
end

-- 0 = fill the entire fuel inventory (slot_count * stack_size). Positive = fixed override.
local function fuel_request_amount(item_name, fuel_inv)
	local configured = settings.global["ick-fuel-amount"].value
	if configured > 0 then
		return configured
	end
	local stack_size = 50
	local item_proto = prototypes.item[item_name]
	if item_proto then
		stack_size = item_proto.stack_size
	end
	local slots = 1
	if fuel_inv then
		slots = math.max(1, #fuel_inv)
	end
	return slots * stack_size
end

local function serialize_schedule_record(record)
	if not record then
		return nil
	end
	-- Rail entity refs are not storage-safe; keep station-based stops.
	if not record.station then
		return nil
	end
	return {
		station = record.station,
		wait_conditions = deep_copy(record.wait_conditions),
		temporary = record.temporary,
		created_by_interrupt = record.created_by_interrupt,
		allows_unloading = record.allows_unloading,
	}
end

local function snapshot_train_schedule(train)
	if not train then
		return nil
	end
	local ok, lua_schedule = pcall(function()
		return train.get_schedule()
	end)
	if ok and lua_schedule then
		local records = {}
		for _, record in pairs(lua_schedule.get_records() or {}) do
			local serialized = serialize_schedule_record(record)
			if serialized then
				table.insert(records, serialized)
			end
		end
		local interrupts = {}
		for i, interrupt in ipairs(lua_schedule.get_interrupts() or {}) do
			local interrupt_records = {}
			for _, record in pairs(lua_schedule.get_records(i) or {}) do
				local serialized = serialize_schedule_record(record)
				if serialized then
					table.insert(interrupt_records, serialized)
				end
			end
			table.insert(interrupts, {
				name = interrupt.name,
				conditions = deep_copy(interrupt.conditions),
				records = interrupt_records,
			})
		end
		if records[1] or interrupts[1] then
			return {
				current = lua_schedule.current,
				records = records,
				interrupts = interrupts,
			}
		end
	end

	local schedule = train.schedule
	if not schedule or not schedule.records then
		return nil
	end
	local records = {}
	for _, record in pairs(schedule.records) do
		local serialized = serialize_schedule_record(record)
		if serialized then
			table.insert(records, serialized)
		end
	end
	if not records[1] then
		return nil
	end
	return {
		current = schedule.current,
		records = records,
		interrupts = {},
	}
end

local function apply_train_identity(train, group, schedule_snapshot)
	if not train then
		return false
	end
	train.manual_mode = true
	train.speed = 0

	if schedule_snapshot and schedule_snapshot.records and schedule_snapshot.records[1] then
		train.schedule = {
			current = schedule_snapshot.current or 1,
			records = deep_copy(schedule_snapshot.records),
		}
	end

	if group and group ~= "" then
		train.group = group
	elseif schedule_snapshot and schedule_snapshot.interrupts and schedule_snapshot.interrupts[1] then
		local ok, lua_schedule = pcall(function()
			return train.get_schedule()
		end)
		if ok and lua_schedule then
			pcall(function()
				lua_schedule.set_interrupts(deep_copy(schedule_snapshot.interrupts))
			end)
		end
	end
	return true
end

local function pending_is_empty(pending)
	return pending == nil or next(pending) == nil
end

local function hold_train(train)
	if train then
		train.speed = 0
		train.manual_mode = true
	end
end

local function hold_entity_train(entity)
	if entity and entity.valid and entity.train then
		hold_train(entity.train)
	end
end

---------------------------------------------------------------------------
-- Always-on train registry
---------------------------------------------------------------------------

local function freeze_train_id(train_id)
	local record = storage.ick_trains[train_id]
	if not record then
		return
	end
	-- Keep the snapshot for destroy/repair lookup; stop treating it as a live train.
	record.frozen = true
	record.expire_tick = game.tick + 7200
end

local function register_train(train)
	if not train or not train.valid then
		return nil
	end
	ensure_storage()
	local train_id = train.id
	local carriages = {}
	for _, carriage in pairs(train.carriages) do
		table.insert(carriages, {
			unit_number = carriage.unit_number,
			name = carriage.name,
			type = carriage.type,
			quality = quality_name(carriage.quality),
			position = {x = carriage.position.x, y = carriage.position.y},
			orientation = carriage.orientation,
		})
		storage.ick_unit_to_train[carriage.unit_number] = train_id
	end

	local group = train.group
	if group == "" then
		group = nil
	end
	local first = train.carriages[1]
	storage.ick_trains[train_id] = {
		train_id = train_id,
		schedule = snapshot_train_schedule(train),
		group = group,
		was_automatic = train.manual_mode == false,
		manual_mode = train.manual_mode,
		carriages = carriages,
		expected = count_carriages(train),
		centroid = train_centroid_from_list(carriages),
		force_name = first and first.force.name or nil,
		force_index = first and first.force.index or nil,
		surface_index = first and first.surface.index or nil,
		tick = game.tick,
		frozen = false,
	}
	return storage.ick_trains[train_id]
end

local function cleanup_expired_train_records()
	if not storage.ick_trains then
		return
	end
	for train_id, record in pairs(storage.ick_trains) do
		if record.frozen and record.expire_tick and game.tick > record.expire_tick then
			if record.carriages then
				for _, carriage in pairs(record.carriages) do
					if storage.ick_unit_to_train[carriage.unit_number] == train_id then
						storage.ick_unit_to_train[carriage.unit_number] = nil
					end
				end
			end
			storage.ick_trains[train_id] = nil
		end
	end
end

local function refresh_all_trains()
	ensure_storage()
	-- Factorio 2.0: LuaForce.get_trains was removed; use train_manager.
	for _, train in pairs(game.train_manager.get_trains{}) do
		register_train(train)
	end
	cleanup_expired_train_records()
end

local function lookup_train_record(entity, train)
	ensure_storage()
	if entity and entity.unit_number then
		local train_id = storage.ick_unit_to_train[entity.unit_number]
		if train_id and storage.ick_trains[train_id] then
			return storage.ick_trains[train_id], train_id
		end
		-- Survivors may have been remapped to a new train id after a split; still find the
		-- richest record (prefer frozen full consists with a schedule).
		local best, best_id, best_score = nil, nil, -1
		for id, record in pairs(storage.ick_trains) do
			if record.carriages then
				for _, carriage in pairs(record.carriages) do
					if carriage.unit_number == entity.unit_number then
						local score = #(record.carriages)
						if record.schedule then
							score = score + 1000
						end
						if record.group then
							score = score + 100
						end
						if record.frozen then
							score = score + 10
						end
						if score > best_score then
							best = record
							best_id = id
							best_score = score
						end
						break
					end
				end
			end
		end
		if best then
			return best, best_id
		end
	end
	if train and train.valid then
		register_train(train)
		return storage.ick_trains[train.id], train.id
	end
	return nil, nil
end

---------------------------------------------------------------------------
-- Repair jobs
---------------------------------------------------------------------------

local function find_job_for_record(train_id, entity)
	if not storage.ick_repair_jobs then
		return nil
	end
	if train_id then
		for job_id, job in pairs(storage.ick_repair_jobs) do
			if job.source_train_id == train_id then
				return job_id
			end
		end
	end
	if entity then
		local unit = entity.unit_number
		for job_id, job in pairs(storage.ick_repair_jobs) do
			if job.member_unit_numbers[unit] then
				return job_id
			end
			if job.surface_index == entity.surface.index and job.force_name == entity.force.name and job.centroid then
				local dx = job.centroid.x - entity.position.x
				local dy = job.centroid.y - entity.position.y
				if dx * dx + dy * dy <= 225 then
					return job_id
				end
			end
		end
	end
	return nil
end

local function create_repair_job_from_record(record, entity)
	local job_id = storage.ick_next_job_id
	storage.ick_next_job_id = job_id + 1

	local members = {}
	if record.carriages then
		for _, carriage in pairs(record.carriages) do
			members[carriage.unit_number] = true
		end
	else
		members[entity.unit_number] = true
	end

	storage.ick_repair_jobs[job_id] = {
		source_train_id = record.train_id,
		expected = deep_copy(record.expected) or {[entity.type] = 1},
		pending = {},
		built = {},
		member_unit_numbers = members,
		was_automatic = record.was_automatic,
		group = record.group,
		schedule = deep_copy(record.schedule),
		carriages = deep_copy(record.carriages),
		force_index = record.force_index or entity.force.index,
		force_name = record.force_name or entity.force.name,
		surface_index = record.surface_index or entity.surface.index,
		centroid = deep_copy(record.centroid) or {x = entity.position.x, y = entity.position.y},
		created_tick = game.tick,
	}
	return job_id
end

local function arm_schedule_restore(job)
	ensure_storage()
	local token = storage.ick_next_job_id
	storage.ick_next_job_id = token + 1
	storage.ick_awaiting_restore[token] = {
		expected = deep_copy(job.expected),
		group = job.group,
		schedule = deep_copy(job.schedule),
		was_automatic = job.was_automatic,
		force_index = job.force_index,
		force_name = job.force_name,
		surface_index = job.surface_index,
		centroid = deep_copy(job.centroid),
		expire_tick = game.tick + 600,
	}
	return token
end

local function try_apply_awaiting_restore(train)
	if not train or not storage.ick_awaiting_restore then
		return false
	end
	local actual = count_carriages(train)
	local centroid = train_centroid_from_list(train.carriages)
	local first = train.carriages[1]
	if not first then
		return false
	end
	local surface_index = first.surface.index
	local force_name = first.force.name

	for token, waiting in pairs(storage.ick_awaiting_restore) do
		if game.tick > waiting.expire_tick then
			storage.ick_awaiting_restore[token] = nil
		elseif waiting.surface_index == surface_index
			and waiting.force_name == force_name
			and counts_match(waiting.expected, actual)
		then
			local near = true
			if waiting.centroid and centroid then
				local dx = waiting.centroid.x - centroid.x
				local dy = waiting.centroid.y - centroid.y
				near = (dx * dx + dy * dy) <= 400
			end
			if near then
				apply_train_identity(train, waiting.group, waiting.schedule)
				if waiting.was_automatic and settings.global["ick-automatic-mode"].value then
					train.manual_mode = false
				else
					hold_train(train)
				end
				storage.ick_awaiting_restore[token] = nil
				return true
			end
		end
	end
	return false
end

local function try_complete_repair_job(job_id, entity)
	local job = storage.ick_repair_jobs and storage.ick_repair_jobs[job_id]
	if not job then
		return
	end
	if not pending_is_empty(job.pending) then
		hold_entity_train(entity)
		return
	end
	if entity and entity.valid and entity.train and counts_match(job.expected, count_carriages(entity.train)) then
		arm_schedule_restore(job)
		local train = entity.train
		apply_train_identity(train, job.group, job.schedule)
		if job.was_automatic and settings.global["ick-automatic-mode"].value then
			train.manual_mode = false
		else
			hold_train(train)
		end
		storage.ick_repair_jobs[job_id] = nil
	else
		-- Keep the job (and schedule) until counts match or ghosts are cancelled.
		hold_entity_train(entity)
	end
end

local function attach_death_to_job(entity, train, registration_number, record, train_id, allow_create)
	local job_id = find_job_for_record(train_id, entity)
	if not job_id then
		if not allow_create or not record then
			return nil
		end
		job_id = create_repair_job_from_record(record, entity)
	else
		local job = storage.ick_repair_jobs[job_id]
		job.member_unit_numbers[entity.unit_number] = true
		if record then
			if not job.schedule and record.schedule then
				job.schedule = deep_copy(record.schedule)
			end
			if (not job.group or job.group == "") and record.group then
				job.group = record.group
			end
			if record.was_automatic then
				job.was_automatic = true
			end
			if record.carriages and (not job.carriages or #job.carriages < #record.carriages) then
				job.carriages = deep_copy(record.carriages)
				job.expected = deep_copy(record.expected)
				job.centroid = deep_copy(record.centroid)
			end
		end
	end
	storage.ick_repair_jobs[job_id].pending[registration_number] = true
	storage.ick_destroyed_train[registration_number].job_id = job_id
	return job_id
end

local function clear_pending_from_job(registration_number, stored_info, built_successfully)
	local job_id = stored_info.job_id
	if not job_id or not storage.ick_repair_jobs then
		return
	end
	local job = storage.ick_repair_jobs[job_id]
	if not job then
		return
	end
	job.pending[registration_number] = nil
	if built_successfully then
		return
	end
	-- Ghost cancelled/mined: only drop the job if nothing is left pending AND nothing was built.
	if pending_is_empty(job.pending) and pending_is_empty(job.built) then
		storage.ick_repair_jobs[job_id] = nil
	end
end


---------------------------------------------------------------------------
-- Events: keep registry fresh
---------------------------------------------------------------------------

script.on_init(function()
	ensure_storage()
	refresh_all_trains()
end)

script.on_configuration_changed(function()
	ensure_storage()
	refresh_all_trains()
end)

script.on_event(defines.events.on_train_created, function(event)
	ensure_storage()
	-- Freeze old ids instead of deleting — full-wipe repair still needs that snapshot.
	if event.old_train_id_1 then
		freeze_train_id(event.old_train_id_1)
	end
	if event.old_train_id_2 then
		freeze_train_id(event.old_train_id_2)
	end
	register_train(event.train)
	try_apply_awaiting_restore(event.train)
	if storage.ick_repair_jobs and event.train then
		for _, job in pairs(storage.ick_repair_jobs) do
			if not pending_is_empty(job.pending) then
				hold_train(event.train)
				break
			end
		end
	end
end)

script.on_event(defines.events.on_train_schedule_changed, function(event)
	register_train(event.train)
end)

script.on_event(defines.events.on_train_changed_state, function(event)
	-- Keep was_automatic / layout current while trains move and change state.
	register_train(event.train)
end)

script.on_nth_tick(300, function()
	-- Low-frequency refresh so idle trains stay accurate without per-tick cost.
	if game and game.forces then
		refresh_all_trains()
	end
end)


---------------------------------------------------------------------------
-- Death / build / destroy
---------------------------------------------------------------------------

script.on_event(defines.events.on_entity_died, function(event)
	local entity = event.entity
	if not entity.prototype.items_to_place_this then
		return
	end

	ensure_storage()
	local train = entity.train
	-- Prefer the registry snapshot from BEFORE this death (survives Factorio wiping LuaTrain).
	local record, train_id = lookup_train_record(entity, nil)
	if train and train.valid then
		-- Also capture a fresh snapshot if the train is still fully readable.
		local live = register_train(train)
		-- Prefer the larger/richer record for expected composition (pre-split).
		if record and live then
			local record_n = record.carriages and #record.carriages or 0
			local live_n = live.carriages and #live.carriages or 0
			if live_n >= record_n and (live.schedule or live.group) then
				record = live
				train_id = live.train_id
			elseif not record.schedule and live.schedule then
				record.schedule = deep_copy(live.schedule)
			end
		elseif live and not record then
			record = live
			train_id = live.train_id
		end
	end

	local killed_by_train = event.cause and event.cause.train ~= nil
	local had_identity = record and (record.schedule or record.group or record.was_automatic)
	local wants_repair_job = (not killed_by_train) and (had_identity or (train and train.manual_mode == false))
	local existing_job_id = find_job_for_record(train_id, entity)
	local join_existing_job = existing_job_id ~= nil

	local surface = entity.surface
	if train and train.valid then
		if train.speed > 0 then
			for _, carriage in pairs(train.carriages) do
				if carriage.type ~= "locomotive" then
					for i = -15, 15 do
						local x = carriage.position.x + math.cos(math.pi * (carriage.orientation * 2 + 0.5)) * i / 5
						local y = carriage.position.y + math.sin(math.pi * (carriage.orientation * 2 + 0.5)) * i / 5
						local offset_1_x = math.cos(math.pi * carriage.orientation * 2) * 0.75
						local offset_1_y = math.sin(math.pi * carriage.orientation * 2) * 0.75
						surface.create_trivial_smoke{name = "smoke-train-stop", position = {x + offset_1_x, y + offset_1_y}}
						local offset_2_x = math.cos(math.pi * carriage.orientation * 2) * -0.75
						local offset_2_y = math.sin(math.pi * carriage.orientation * 2) * -0.75
						surface.create_trivial_smoke{name = "smoke-train-stop", position = {x + offset_2_x, y + offset_2_y}}
					end
				end
			end
		end
		hold_train(train)
	end

	local ghost_entity
	local existing_ghosts = surface.find_entities_filtered{
		name = "entity-ghost",
		position = entity.position,
		radius = 0.5,
		force = entity.force,
	}
	for _, ghost in pairs(existing_ghosts) do
		if ghost.ghost_name == entity.name then
			ghost_entity = ghost
			break
		end
	end
	if not ghost_entity then
		ghost_entity = surface.create_entity{
			name = "entity-ghost",
			inner_name = entity.name,
			quality = entity.quality,
			position = entity.position,
			orientation = entity.orientation,
			force = entity.force,
			create_build_effect_smoke = false,
		}
	end
	if not ghost_entity then
		return
	end

	-- Tag ghost with job linkage info for stabler rebuild matching.
	pcall(function()
		ghost_entity.tags = {
			ick_unit = entity.unit_number,
			ick_train_id = train_id,
			ick_name = entity.name,
			ick_x = entity.position.x,
			ick_y = entity.position.y,
		}
	end)

	local message = {"gui-alert-tooltip.ick-destroyed-train", entity.localised_name, "?"}
	if event.cause then
		message = {"gui-alert-tooltip.ick-destroyed-train", entity.localised_name, event.cause.localised_name}
	end
	for _, player in pairs(game.players) do
		if player.force == entity.force and player.mod_settings["ick-alert"].value then
			player.add_custom_alert(ghost_entity, {type = "virtual", name = "ick-signal-destroyed-train"}, message, true)
		end
	end

	local fuel_inv = entity.get_fuel_inventory()
	local wagon_inv = entity.get_inventory(defines.inventory.cargo_wagon)
	local request_proxies = surface.find_entities_filtered{type = "item-request-proxy", name = "item-request-proxy", position = entity.position}
	local found_proxies = false
	for _, proxy in pairs(request_proxies) do
		if proxy.proxy_target == entity then
			found_proxies = true
			break
		end
	end
	local has_equipment = entity.grid and entity.grid.equipment[1]

	if wants_repair_job or join_existing_job or has_equipment or (fuel_inv and fuel_inv.is_empty() == false) or (wagon_inv and (wagon_inv.is_filtered() or (wagon_inv.supports_bar() and (wagon_inv.get_bar() <= #wagon_inv)))) or found_proxies then
		local registration_number = script.register_on_object_destroyed(ghost_entity)
		storage.ick_destroyed_train[registration_number] = {
			type = entity.type,
			name = entity.name,
			position = {x = entity.position.x, y = entity.position.y},
			unit_number = entity.unit_number,
			train_id = train_id,
		}

		if wants_repair_job or join_existing_job then
			attach_death_to_job(
				entity,
				train,
				registration_number,
				record,
				train_id,
				wants_repair_job and not join_existing_job
			)
		end

		local request_map = {}
		if settings.global["ick-include-fuel"].value then
			local fuel_type = settings.global["ick-fuel-type"].value
			if fuel_type ~= "" and prototypes.item[fuel_type] then
				add_request(request_map, fuel_type, "normal", fuel_request_amount(fuel_type, fuel_inv), 0)
			elseif fuel_inv and fuel_inv.is_empty() == false then
				for _, item in pairs(fuel_inv.get_contents()) do
					add_request(request_map, item.name, item.quality, fuel_request_amount(item.name, fuel_inv), 0)
				end
			elseif fuel_inv and settings.global["ick-fuel-type"].value == "" then
				-- No fuel left in burner: still request a full inventory of the preferred fuel if set elsewhere — skip.
			end
		end

		if settings.global["ick-include-equipment"].value and has_equipment then
			local ghost_grid = ghost_entity.grid
			if ghost_grid and not ghost_grid.equipment[1] then
				for _, equipment in pairs(entity.grid.equipment) do
					ghost_grid.put{
						name = equipment.name,
						quality = quality_name(equipment.quality),
						position = equipment.position,
						ghost = true,
					}
				end
			end
			for _, item in pairs(entity.grid.get_contents()) do
				add_request(request_map, item.name, item.quality, 0, item.count)
			end
			if entity.type == "cargo-wagon" then
				storage.ick_destroyed_train[registration_number].equipment = entity.grid.get_contents()
			end
		end

		if found_proxies then
			for _, proxy in pairs(request_proxies) do
				if proxy.proxy_target == entity then
					if proxy.insert_plan and next(proxy.insert_plan) then
						merge_insert_plans(request_map, proxy.insert_plan)
					else
						for _, item in pairs(proxy.item_requests) do
							if fuel_inv then
								add_request(request_map, item.name, item.quality, item.count, 0)
							else
								add_request(request_map, item.name, item.quality, 0, item.count)
							end
						end
					end
				end
			end
		end

		local insert_plan = build_insert_plan(request_map)
		if next(insert_plan) then
			ghost_entity.insert_plan = insert_plan
		end

		if wagon_inv then
			if wagon_inv.is_filtered() then
				local filters = {}
				for i = 1, #wagon_inv do
					table.insert(filters, i, wagon_inv.get_filter(i))
				end
				storage.ick_destroyed_train[registration_number].filters = filters
			end
			if wagon_inv.supports_bar() and (wagon_inv.get_bar() <= #wagon_inv) then
				storage.ick_destroyed_train[registration_number].bar = wagon_inv.get_bar()
			end
		end
	end

	-- Unit is gone after death; drop live mapping (frozen copy remains on the repair job).
	if entity.unit_number then
		storage.ick_unit_to_train[entity.unit_number] = nil
	end
end, {{filter = "rolling-stock"}})


local function match_stored_rebuild(entity, stored_info)
	if stored_info.type ~= entity.type or stored_info.name ~= entity.name then
		return false
	end
	if stored_info.position and positions_close(stored_info.position, entity.position) then
		return true
	end
	return false
end

local function built_entity(entity)
	ensure_storage()
	if entity.train then
		register_train(entity.train)
	end
	if not storage.ick_destroyed_train then
		return
	end

	for registration_number, stored_info in pairs(storage.ick_destroyed_train) do
		if match_stored_rebuild(entity, stored_info) then
			local request_proxy = entity.item_request_proxy
			if not request_proxy then
				request_proxy = entity.surface.find_entity("item-request-proxy", entity.position)
			end
			if stored_info.equipment and request_proxy then
				local proxy_registration = script.register_on_object_destroyed(request_proxy)
				storage.ick_destroyed_train[proxy_registration] = {
					position = {x = entity.position.x, y = entity.position.y},
					requests = stored_info.equipment,
					target = entity,
				}
			end

			if stored_info.filters then
				local cargo_inv = entity.get_inventory(defines.inventory.cargo_wagon)
				if cargo_inv then
					for i = 1, #cargo_inv do
						cargo_inv.set_filter(i, stored_info.filters[i])
					end
				end
			end
			if stored_info.bar then
				local cargo_inv = entity.get_inventory(defines.inventory.cargo_wagon)
				if cargo_inv then
					cargo_inv.set_bar(stored_info.bar)
				end
			end

			hold_entity_train(entity)

			if stored_info.job_id and storage.ick_repair_jobs[stored_info.job_id] then
				local job = storage.ick_repair_jobs[stored_info.job_id]
				job.pending[registration_number] = nil
				job.built[registration_number] = true
				try_complete_repair_job(stored_info.job_id, entity)
			end
		end
	end
end

script.on_event(defines.events.on_built_entity, function(event)
	built_entity(event.entity)
end, {{filter = "rolling-stock"}})

script.on_event(defines.events.on_robot_built_entity, function(event)
	built_entity(event.entity)
end, {{filter = "rolling-stock"}})

script.on_event(defines.events.on_tick, function(event)
	local waiting = storage.ick_awaiting_restore
	if not waiting or not next(waiting) then
		return
	end
	for token, entry in pairs(waiting) do
		if event.tick > entry.expire_tick then
			waiting[token] = nil
		elseif entry.centroid and entry.surface_index and entry.force_name then
			local surface = game.surfaces[entry.surface_index]
			if surface then
				local candidates = surface.find_entities_filtered{
					type = {"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon"},
					position = entry.centroid,
					radius = 20,
					force = entry.force_name,
				}
				for _, carriage in pairs(candidates) do
					if carriage.train and try_apply_awaiting_restore(carriage.train) then
						break
					end
				end
			end
		end
	end
end)

script.on_event(defines.events.on_object_destroyed, function(event)
	if not storage.ick_destroyed_train or not storage.ick_destroyed_train[event.registration_number] then
		return
	end
	local registered_entity = storage.ick_destroyed_train[event.registration_number]
	if registered_entity.requests and registered_entity.target and registered_entity.target.valid then
		local inventory = registered_entity.target.get_inventory(defines.inventory.cargo_wagon)
		local grid = registered_entity.target.grid
		for _, entry in pairs(registered_entity.requests) do
			local name = entry.name
			local count = entry.count
			local quality = quality_name(entry.quality)
			if inventory and grid and name and count then
				for _ = 1, count do
					local stack = inventory.find_item_stack({name = name, quality = quality})
					if stack and grid.put{name = name, quality = quality} then
						stack.count = stack.count - 1
					end
				end
			end
		end
	end
	if registered_entity.job_id and registered_entity.type then
		local job = storage.ick_repair_jobs and storage.ick_repair_jobs[registered_entity.job_id]
		-- If this reg is still pending, the ghost was cancelled (not successfully matched as built).
		local was_still_pending = job and job.pending[event.registration_number]
		if was_still_pending then
			clear_pending_from_job(event.registration_number, registered_entity, false)
		end
	end
	storage.ick_destroyed_train[event.registration_number] = nil
end)
