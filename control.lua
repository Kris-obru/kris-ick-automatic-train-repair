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
	-- Longer-lived identity for rebuild/re-kill cycles (new unit numbers lose registry links).
	storage.ick_identity_cache = storage.ick_identity_cache or {}
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

-- Fuel request count from a 0–100% of inventory capacity setting.
local function fuel_request_amount(item_name, fuel_inv)
	local percent = settings.global["ick-fuel-amount"].value or 100
	if percent <= 0 then
		return 0
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
	local capacity = slots * stack_size
	return math.max(1, math.ceil(capacity * percent / 100))
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
			local snap = {
				current = lua_schedule.current,
				records = records,
				interrupts = interrupts,
			}
			return snap
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
	local snap = {
		current = schedule.current,
		records = records,
		interrupts = {},
	}
	return snap
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

---------------------------------------------------------------------------
-- Identity richness / cache (survive rebuild + repeated destroys)
---------------------------------------------------------------------------

local function schedule_score(schedule)
	if not schedule then
		return 0
	end
	local score = 0
	if schedule.records then
		score = score + #schedule.records * 10
	end
	if schedule.interrupts then
		score = score + #schedule.interrupts * 5
	end
	return score
end

local function record_has_schedule(record)
	return schedule_score(record and record.schedule) > 0
end

local function identity_score(schedule, group, was_automatic)
	local score = schedule_score(schedule)
	if group and group ~= "" then
		score = score + 100
	end
	if was_automatic then
		score = score + 1
	end
	return score
end

-- Hard preference: any timetable beats none. Then richer schedule / group / size.
-- schedule_tick (set on player edits) beats richer-but-stale history.
local function record_preference_score(record, bonus)
	if not record then
		return -1
	end
	local score = (bonus or 0) + identity_score(record.schedule, record.group, record.was_automatic)
	if record_has_schedule(record) then
		score = score + 100000
	end
	-- Strongly prefer fuller consists so a 1–2 car fragment never beats the original 4-car snapshot.
	local car_n = 0
	if record.carriages then
		car_n = #record.carriages
	elseif record.expected then
		for _, c in pairs(record.expected) do
			car_n = car_n + c
		end
	end
	score = score + car_n * 100
	if record.frozen then
		score = score + 10
	end
	-- Player schedule edits stamp schedule_tick; that must outrank older richer snapshots.
	if record.schedule_tick then
		score = score + record.schedule_tick
	end
	return score
end

local function pick_richer_schedule(a, b)
	if schedule_score(a) >= schedule_score(b) then
		return a
	end
	return b
end

local function record_identity_score(record)
	if not record then
		return 0
	end
	return identity_score(record.schedule, record.group, record.was_automatic)
end

-- True when source's timetable should replace target's (recency first, then richness).
local function source_schedule_preferred(source, target)
	if not record_has_schedule(source) then
		return false
	end
	if not record_has_schedule(target) then
		return true
	end
	local st = source.schedule_tick or 0
	local tt = target.schedule_tick or 0
	if st ~= tt then
		return st > tt
	end
	return schedule_score(source.schedule) > schedule_score(target.schedule)
end

-- Merge identity fields: never let an empty snapshot erase a richer schedule/group.
-- When both have schedules, prefer the newer schedule_tick (player edits win over history).
local function merge_expected_counts(a, b)
	local out = {}
	if a then
		for k, v in pairs(a) do
			out[k] = v
		end
	end
	if b then
		for k, v in pairs(b) do
			out[k] = math.max(out[k] or 0, v)
		end
	end
	return out
end

local function merge_identity_into(target, source)
	if not target or not source then
		return target
	end
	if source_schedule_preferred(source, target) then
		target.schedule = deep_copy(source.schedule)
		target.schedule_tick = source.schedule_tick or target.schedule_tick
	elseif not target.schedule and source.schedule then
		target.schedule = deep_copy(source.schedule)
		target.schedule_tick = source.schedule_tick or target.schedule_tick
	end
	if (not target.group or target.group == "") and source.group and source.group ~= "" then
		target.group = source.group
	end
	if source.was_automatic then
		target.was_automatic = true
	end
	local target_n = target.carriages and #target.carriages or 0
	local source_n = source.carriages and #source.carriages or 0
	if source_n > target_n then
		target.carriages = deep_copy(source.carriages)
		if source.centroid then
			target.centroid = deep_copy(source.centroid)
		end
	end
	-- Never shrink expected layout (fragment snapshots must not replace a 4-car job with 2 cars).
	if source.expected or target.expected then
		target.expected = merge_expected_counts(target.expected, source.expected)
	end
	if source.force_name and not target.force_name then
		target.force_name = source.force_name
	end
	if source.surface_index and not target.surface_index then
		target.surface_index = source.surface_index
	end
	if source.train_id and not target.train_id then
		target.train_id = source.train_id
	end
	return target
end

local function cleanup_identity_cache()
	local cache = storage.ick_identity_cache
	if not cache then
		return
	end
	for i = #cache, 1, -1 do
		local entry = cache[i]
		if not entry or (entry.expire_tick and game.tick > entry.expire_tick) then
			table.remove(cache, i)
		end
	end
end

local function remember_identity(source)
	if not source then
		return
	end
	-- Only cache entries that actually have a schedule (or at least a group).
	if not record_has_schedule(source) and not (source.group and source.group ~= "") then
		return
	end
	ensure_storage()
	cleanup_identity_cache()
	local entry = {
		force_name = source.force_name,
		surface_index = source.surface_index,
		centroid = deep_copy(source.centroid),
		schedule = deep_copy(source.schedule),
		schedule_tick = source.schedule_tick or game.tick,
		group = source.group,
		was_automatic = source.was_automatic,
		expected = deep_copy(source.expected),
		expire_tick = game.tick + 36000,
	}
	local cache = storage.ick_identity_cache
	for i, old in ipairs(cache) do
		if old.force_name == entry.force_name
			and old.surface_index == entry.surface_index
			and old.centroid and entry.centroid
		then
			local dx = old.centroid.x - entry.centroid.x
			local dy = old.centroid.y - entry.centroid.y
			if dx * dx + dy * dy <= 400 then
				-- Newer player edits replace older cache even if the new timetable is shorter.
				if source_schedule_preferred(entry, old)
					or record_preference_score(entry) >= record_preference_score(old)
				then
					cache[i] = entry
				end
				return
			end
		end
	end
	table.insert(cache, entry)
	while #cache > 40 do
		table.remove(cache, 1)
	end
end

-- After a player edits a schedule, overwrite nearby registry/job copies so rebuild
-- does not resurrect the pre-edit timetable from frozen train ids / open jobs.
local function supersede_nearby_schedules(record)
	if not record or not record_has_schedule(record) then
		return
	end
	local stamp = record.schedule_tick or game.tick
	record.schedule_tick = stamp

	local function shares_units(other)
		if not record.carriages or not other.carriages then
			return false
		end
		for _, a in pairs(record.carriages) do
			for _, b in pairs(other.carriages) do
				if a.unit_number and a.unit_number == b.unit_number then
					return true
				end
			end
		end
		return false
	end

	local function nearby(other)
		if not record.centroid or not other.centroid then
			return false
		end
		if record.force_name and other.force_name and record.force_name ~= other.force_name then
			return false
		end
		if record.surface_index and other.surface_index and record.surface_index ~= other.surface_index then
			return false
		end
		local dx = record.centroid.x - other.centroid.x
		local dy = record.centroid.y - other.centroid.y
		return (dx * dx + dy * dy) <= 400
	end

	if storage.ick_trains then
		for _, other in pairs(storage.ick_trains) do
			if other ~= record and (shares_units(other) or nearby(other)) then
				if (other.schedule_tick or 0) < stamp then
					other.schedule = deep_copy(record.schedule)
					other.schedule_tick = stamp
					if record.group then
						other.group = record.group
					end
				end
			end
		end
	end

	if storage.ick_repair_jobs then
		for _, job in pairs(storage.ick_repair_jobs) do
			if nearby(job) and (job.schedule_tick or 0) < stamp then
				job.schedule = deep_copy(record.schedule)
				job.schedule_tick = stamp
				if record.group then
					job.group = record.group
				end
			end
		end
	end
end

local function find_cached_identity(entity, expected)
	ensure_storage()
	cleanup_identity_cache()
	if not entity or not entity.valid then
		return nil
	end
	local best, best_score = nil, -1
	local pos = entity.position
	for _, entry in ipairs(storage.ick_identity_cache) do
		if entry.force_name == entity.force.name
			and entry.surface_index == entity.surface.index
			and entry.centroid
		then
			local expected_ok = true
			if expected and entry.expected then
				expected_ok = counts_match(entry.expected, expected)
			end
			if expected_ok then
				local dx = entry.centroid.x - pos.x
				local dy = entry.centroid.y - pos.y
				local dist2 = dx * dx + dy * dy
				if dist2 <= 400 then
					-- Prefer scheduled entries; among those, closer + richer.
					local score = record_preference_score(entry) - math.floor(dist2)
					if score > best_score then
						best = entry
						best_score = score
					end
				end
			end
		end
	end
	if not best and expected then
		return find_cached_identity(entity, nil)
	end
	-- If the best hit has no schedule, try again requiring a schedule.
	if best and not record_has_schedule(best) then
		local scheduled_best, scheduled_score = nil, -1
		for _, entry in ipairs(storage.ick_identity_cache) do
			if entry.force_name == entity.force.name
				and entry.surface_index == entity.surface.index
				and entry.centroid
				and record_has_schedule(entry)
			then
				local dx = entry.centroid.x - pos.x
				local dy = entry.centroid.y - pos.y
				local dist2 = dx * dx + dy * dy
				if dist2 <= 400 then
					local score = record_preference_score(entry) - math.floor(dist2)
					if score > scheduled_score then
						scheduled_best = entry
						scheduled_score = score
					end
				end
			end
		end
		if scheduled_best then
			return scheduled_best
		end
	end
	return best
end

-- Scan registry history for the best scheduled train near this entity (ignore blank snapshots).
local function find_scheduled_history_record(entity)
	if not entity or not entity.valid or not storage.ick_trains then
		return nil, nil
	end
	local best, best_id, best_score = nil, nil, -1
	local pos = entity.position
	local force_name = entity.force.name
	local surface_index = entity.surface.index
	local unit = entity.unit_number

	for id, record in pairs(storage.ick_trains) do
		if not record_has_schedule(record) then
			-- User request: disregard history entries without a schedule.
		elseif record.force_name and record.force_name ~= force_name then
			-- skip other forces
		elseif record.surface_index and record.surface_index ~= surface_index then
			-- skip other surfaces
		else
			local related = false
			local dist_penalty = 0
			if record.carriages then
				for _, carriage in pairs(record.carriages) do
					if carriage.unit_number == unit then
						related = true
						break
					end
				end
			end
			if not related and record.centroid then
				local dx = record.centroid.x - pos.x
				local dy = record.centroid.y - pos.y
				local dist2 = dx * dx + dy * dy
				if dist2 <= 400 then
					related = true
					dist_penalty = math.floor(dist2)
				end
			end
			if related then
				local score = record_preference_score(record) - dist_penalty
				if score > best_score then
					best = record
					best_id = id
					best_score = score
				end
			end
		end
	end
	return best, best_id
end

local function pending_is_empty(pending)
	return pending == nil or next(pending) == nil
end

local function train_near_repair_context(train)
	if not train or not train.valid then
		return false
	end
	local first = train.carriages[1]
	if not first then
		return false
	end
	local centroid = train_centroid_from_list(train.carriages)
	if storage.ick_repair_jobs then
		for _, job in pairs(storage.ick_repair_jobs) do
			if job.force_name == first.force.name
				and job.surface_index == first.surface.index
				and job.centroid and centroid
			then
				local dx = job.centroid.x - centroid.x
				local dy = job.centroid.y - centroid.y
				if dx * dx + dy * dy <= 400 then
					return true
				end
			end
		end
	end
	if storage.ick_awaiting_restore then
		for _, waiting in pairs(storage.ick_awaiting_restore) do
			if waiting.force_name == first.force.name
				and waiting.surface_index == first.surface.index
				and waiting.centroid and centroid
			then
				local dx = waiting.centroid.x - centroid.x
				local dy = waiting.centroid.y - centroid.y
				if dx * dx + dy * dy <= 400 then
					return true
				end
			end
		end
	end
	return false
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

local function register_train(train, opts)
	if not train or not train.valid then
		return nil
	end
	opts = opts or {}
	ensure_storage()
	local train_id = train.id
	local previous = storage.ick_trains[train_id]
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
	local schedule = snapshot_train_schedule(train)
	local was_automatic = train.manual_mode == false
	local first = train.carriages[1]
	local schedule_tick = previous and previous.schedule_tick or nil

	-- Mid-repair / fragment trains often have no schedule yet. Keep richer identity
	-- unless this is an explicit schedule change (force_identity).
	if opts.force_identity then
		-- Live timetable is authoritative (player edit or intentional apply).
		schedule_tick = game.tick
	elseif previous then
		if schedule_score(schedule) < schedule_score(previous.schedule) then
			schedule = deep_copy(previous.schedule)
			schedule_tick = previous.schedule_tick
		end
		if (not group or group == "") and previous.group and previous.group ~= "" then
			group = previous.group
		end
		if previous.was_automatic then
			was_automatic = true
		end
	end

	-- If this train id still has no timetable, pull one from scheduled history nearby.
	if not opts.force_identity and schedule_score(schedule) == 0 and first then
		local hist = find_scheduled_history_record(first)
		if hist and hist.schedule then
			schedule = deep_copy(hist.schedule)
			schedule_tick = hist.schedule_tick or schedule_tick
			if (not group or group == "") and hist.group then
				group = hist.group
			end
			if hist.was_automatic then
				was_automatic = true
			end
		end
	end

	storage.ick_trains[train_id] = {
		train_id = train_id,
		schedule = schedule,
		schedule_tick = schedule_tick,
		group = group,
		was_automatic = was_automatic,
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

	local record = storage.ick_trains[train_id]
	if opts.force_identity then
		-- Player cleared/edited schedule: drop nearby cache so we don't resurrect the old one.
		if record_identity_score(record) <= 0 and record.centroid and record.force_name and record.surface_index then
			local cache = storage.ick_identity_cache
			if cache then
				for i = #cache, 1, -1 do
					local old = cache[i]
					if old.force_name == record.force_name
						and old.surface_index == record.surface_index
						and old.centroid
					then
						local dx = old.centroid.x - record.centroid.x
						local dy = old.centroid.y - record.centroid.y
						if dx * dx + dy * dy <= 400 then
							table.remove(cache, i)
						end
					end
				end
			end
			-- Also clear stale schedules on nearby frozen records / open jobs.
			if storage.ick_trains then
				for _, other in pairs(storage.ick_trains) do
					if other ~= record and other.centroid and record.centroid
						and other.force_name == record.force_name
						and other.surface_index == record.surface_index
					then
						local dx = other.centroid.x - record.centroid.x
						local dy = other.centroid.y - record.centroid.y
						if dx * dx + dy * dy <= 400 and (other.schedule_tick or 0) < (record.schedule_tick or 0) then
							other.schedule = nil
							other.schedule_tick = record.schedule_tick
						end
					end
				end
			end
		elseif opts.remember and record_identity_score(record) > 0 then
			supersede_nearby_schedules(record)
			remember_identity(record)
		elseif record_has_schedule(record) then
			supersede_nearby_schedules(record)
		end
	elseif opts.remember and record_identity_score(record) > 0 then
		remember_identity(record)
	end
	return record
end

local function inherit_identity_onto_train_record(train, old_id_1, old_id_2)
	if not train or not train.valid then
		return
	end
	local record = storage.ick_trains[train.id]
	if not record then
		record = register_train(train)
	end
	if not record then
		return
	end
	for _, oid in ipairs({old_id_1, old_id_2}) do
		if oid and storage.ick_trains[oid] then
			merge_identity_into(record, storage.ick_trains[oid])
		end
	end
	local first = train.carriages[1]
	if first then
		local cached = find_cached_identity(first, record.expected)
		if cached then
			merge_identity_into(record, cached)
		end
	end
	if storage.ick_repair_jobs and first then
		for job_id, job in pairs(storage.ick_repair_jobs) do
			if job.surface_index == first.surface.index
				and job.force_name == first.force.name
				and job.centroid
				and record.centroid
			then
				local dx = job.centroid.x - record.centroid.x
				local dy = job.centroid.y - record.centroid.y
				if dx * dx + dy * dy <= 400 then
					merge_identity_into(record, job)
				end
			end
		end
	end
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
	cleanup_identity_cache()
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
	local best, best_id, best_score = nil, nil, -1

	local function consider(record, id, bonus)
		if not record then
			return
		end
		local score = record_preference_score(record, bonus)
		if score > best_score then
			best = record
			best_id = id
			best_score = score
		end
	end


	if entity and entity.unit_number then
		-- Unit map hit (may be a blank live train after rebuild — still consider, but
		-- scheduled history below will outrank it).
		local mapped_id = storage.ick_unit_to_train[entity.unit_number]
		if mapped_id and storage.ick_trains[mapped_id] then
			consider(storage.ick_trains[mapped_id], mapped_id, 50)
		end

		-- Any registry row that still lists this unit.
		for id, record in pairs(storage.ick_trains) do
			if record.carriages then
				for _, carriage in pairs(record.carriages) do
					if carriage.unit_number == entity.unit_number then
						consider(record, id, 80)
						break
					end
				end
			end
		end

		-- Prefer historical trains that actually had a schedule (ignore blank snapshots).
		local hist, hist_id = find_scheduled_history_record(entity)
		if hist then
			consider(hist, hist_id, 200)
		end
	end

	if best then
		return best, best_id
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
	local best_id, best_score = nil, -1

	local function consider(job_id, job, bonus)
		local score = (bonus or 0) + record_preference_score(job)
		if job.awaiting_refuel then
			score = score + 50
		end
		if not pending_is_empty(job.pending) then
			score = score + 20
		end
		if score > best_score then
			best_id = job_id
			best_score = score
		end
	end

	if train_id then
		for job_id, job in pairs(storage.ick_repair_jobs) do
			if job.source_train_id == train_id then
				consider(job_id, job, 500)
			end
		end
	end
	if entity then
		local unit = entity.unit_number
		for job_id, job in pairs(storage.ick_repair_jobs) do
			if job.member_unit_numbers[unit] then
				consider(job_id, job, 400)
			elseif job.surface_index == entity.surface.index
				and job.force_name == entity.force.name
				and job.centroid
			then
				local dx = job.centroid.x - entity.position.x
				local dy = job.centroid.y - entity.position.y
				local dist2 = dx * dx + dy * dy
				-- Trains are long; mid-rebuild kills must still join the open job.
				if dist2 <= 1600 then
					consider(job_id, job, 300)
				elseif dist2 <= 3600 then
					consider(job_id, job, 150)
				end
			end
		end
	end
	return best_id
end

local function create_repair_job_from_record(record, entity)
	-- Prefer joining a nearby open job over spawning a second undersized job.
	local nearby = find_job_for_record(record and record.train_id, entity)
	if nearby and storage.ick_repair_jobs[nearby] then
		local job = storage.ick_repair_jobs[nearby]
		if record then
			merge_identity_into(job, record)
		end
		job.member_unit_numbers[entity.unit_number] = true
		return nearby
	end

	-- Enrich from scheduled history so a 1–2 car fragment does not set expected too small.
	local seed = deep_copy(record) or {}
	local hist = find_scheduled_history_record(entity)
	if hist then
		merge_identity_into(seed, hist)
	end
	local cached = find_cached_identity(entity, seed.expected)
	if cached then
		merge_identity_into(seed, cached)
	end

	local job_id = storage.ick_next_job_id
	storage.ick_next_job_id = job_id + 1

	local members = {}
	if seed.carriages then
		for _, carriage in pairs(seed.carriages) do
			members[carriage.unit_number] = true
		end
	else
		members[entity.unit_number] = true
	end

	storage.ick_repair_jobs[job_id] = {
		source_train_id = seed.train_id or (record and record.train_id),
		expected = deep_copy(seed.expected) or {[entity.type] = 1},
		pending = {},
		built = {},
		member_unit_numbers = members,
		was_automatic = seed.was_automatic,
		group = seed.group,
		schedule = deep_copy(seed.schedule),
		schedule_tick = seed.schedule_tick,
		carriages = deep_copy(seed.carriages),
		force_index = seed.force_index or entity.force.index,
		force_name = seed.force_name or entity.force.name,
		surface_index = seed.surface_index or entity.surface.index,
		centroid = deep_copy(seed.centroid) or {x = entity.position.x, y = entity.position.y},
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
		schedule_tick = job.schedule_tick,
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
				register_train(train, {force_identity = true, remember = true})
				storage.ick_awaiting_restore[token] = nil
				return true
			end
		end
	end
	return false
end

-- Fill ratio of one fuel inventory (0..1), or nil if this carriage has no burner fuel.
local function carriage_fuel_fill_ratio(carriage)
	if not carriage or not carriage.valid then
		return nil
	end
	local inv = carriage.get_fuel_inventory()
	if not inv or #inv == 0 then
		return nil
	end
	local fallback_stack = 50
	local fuel_type = settings.global["ick-fuel-type"].value
	if fuel_type ~= "" and prototypes.item[fuel_type] then
		fallback_stack = prototypes.item[fuel_type].stack_size
	end
	local filled = 0
	local capacity = 0
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read then
			filled = filled + stack.count
			capacity = capacity + stack.prototype.stack_size
		else
			capacity = capacity + fallback_stack
		end
	end
	if capacity <= 0 then
		return 1
	end
	return filled / capacity
end

-- True when every fuel-bearing carriage on the train meets the configured fill %.
-- Carriages without a fuel inventory are ignored. Trains with no burners pass.
local function train_meets_refuel_threshold(train)
	if not settings.global["ick-require-refuel"].value then
		return true
	end
	if not train or not train.valid then
		return false
	end
	local threshold = (settings.global["ick-refuel-percent"].value or 100) / 100
	for _, carriage in pairs(train.carriages) do
		local ratio = carriage_fuel_fill_ratio(carriage)
		if ratio ~= nil and ratio + 1e-9 < threshold then
			return false
		end
	end
	return true
end

local function find_train_near_job(job)
	if not job or not job.centroid or not job.surface_index or not job.force_name then
		return nil, nil
	end
	local surface = game.surfaces[job.surface_index]
	if not surface then
		return nil, nil
	end
	local candidates = surface.find_entities_filtered{
		type = {"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon"},
		position = job.centroid,
		radius = 20,
		force = job.force_name,
	}
	for _, carriage in pairs(candidates) do
		local train = carriage.train
		if train and counts_match(job.expected, count_carriages(train)) then
			return train, carriage
		end
	end
	return nil, nil
end

local function try_complete_repair_job(job_id, entity)
	local job = storage.ick_repair_jobs and storage.ick_repair_jobs[job_id]
	if not job then
		return
	end
	local train = entity and entity.valid and entity.train
	local counts_ok = train and counts_match(job.expected, count_carriages(train))

	-- If the live consist already matches, leftover "pending" ghost regs are stale
	-- (rebuild matched poorly, or cars were destroyed again mid-repair). Do not block
	-- schedule restore on them — that left trains with empty LuaTrain.schedule forever.
	if counts_ok and not pending_is_empty(job.pending) then
		local n = 0
		for reg, _ in pairs(job.pending) do
			n = n + 1
			job.pending[reg] = nil
			job.built[reg] = true
			if storage.ick_destroyed_train then
				storage.ick_destroyed_train[reg] = nil
			end
		end
	end

	if not pending_is_empty(job.pending) then
		hold_entity_train(entity)
		return
	end
	if counts_ok then
		-- Recover timetable onto the job before any apply (also while waiting for fuel).
		if not record_has_schedule(job) then
			local hist = find_scheduled_history_record(entity)
			if hist then
				merge_identity_into(job, hist)
			end
			local cached = find_cached_identity(entity, job.expected)
			if cached then
				merge_identity_into(job, cached)
			end
		end

		if not train_meets_refuel_threshold(train) then
			-- Consist is whole: put schedule/group back now so the GUI is not empty while
			-- waiting for fuel. Only automatic mode from the *job* stays deferred until fuel.
			local was_manual = train.manual_mode
			local live_sched = snapshot_train_schedule(train)
			local need_apply = job.schedule_applied_train_id ~= train.id
				or schedule_score(live_sched) < schedule_score(job.schedule)
			if need_apply and record_has_schedule(job) then
				apply_train_identity(train, job.group, job.schedule)
				train.manual_mode = was_manual
				job.schedule_applied_train_id = train.id
				register_train(train, {force_identity = true, remember = true})
			end
			job.awaiting_refuel = true
			return
		end
		-- Preserve player automatic if they already enabled it (e.g. after fueling by hand).
		local player_had_auto = train.manual_mode == false
		job.awaiting_refuel = nil
		arm_schedule_restore(job)
		apply_train_identity(train, job.group, job.schedule)
		if player_had_auto or (job.was_automatic and settings.global["ick-automatic-mode"].value) then
			train.manual_mode = false
		else
			hold_train(train)
		end
		-- Rebind new unit numbers to this train id and cache identity for the next kill cycle.
		local live = register_train(train, {force_identity = true, remember = true})
		if live then
			remember_identity({
				force_name = job.force_name or live.force_name,
				surface_index = job.surface_index or live.surface_index,
				centroid = live.centroid or job.centroid,
				schedule = job.schedule or live.schedule,
				schedule_tick = job.schedule_tick or live.schedule_tick or game.tick,
				group = job.group or live.group,
				was_automatic = job.was_automatic or live.was_automatic,
				expected = job.expected or live.expected,
			})
		else
			remember_identity(job)
		end
		storage.ick_repair_jobs[job_id] = nil
	else
		-- Keep the job (and schedule) until counts match or ghosts are cancelled.
		hold_entity_train(entity)
	end
end

-- Re-check jobs for a live train (player fuel insert, fast transfer, etc.).
local function try_complete_jobs_for_train(train)
	if not train or not train.valid or not storage.ick_repair_jobs then
		return
	end
	local actual = count_carriages(train)
	local first = train.carriages[1]
	if not first then
		return
	end
	for job_id, job in pairs(storage.ick_repair_jobs) do
		if counts_match(job.expected, actual) then
			try_complete_repair_job(job_id, first)
		end
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
			merge_identity_into(job, record)
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
	-- ick-fuel-amount used to be an absolute count (0 = full inventory). It is now 0–100%.
	if not storage.ick_migrated_fuel_amount_percent then
		local current = settings.global["ick-fuel-amount"].value
		if current == 0 or current > 100 then
			settings.global["ick-fuel-amount"] = {value = 100}
		end
		storage.ick_migrated_fuel_amount_percent = true
	end
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
	inherit_identity_onto_train_record(event.train, event.old_train_id_1, event.old_train_id_2)
	try_apply_awaiting_restore(event.train)
	if storage.ick_repair_jobs and event.train then
		for job_id, job in pairs(storage.ick_repair_jobs) do
			if event.train.carriages[1] then
				try_complete_repair_job(job_id, event.train.carriages[1])
			end
			if not pending_is_empty(job.pending) and storage.ick_repair_jobs[job_id] then
				hold_train(event.train)
			end
		end
	end
end)

script.on_event(defines.events.on_train_schedule_changed, function(event)
	local train = event.train
	if not train or not train.valid then
		return
	end
	local live_schedule = snapshot_train_schedule(train)
	local near_repair = train_near_repair_context(train)
	if schedule_score(live_schedule) > 0 then
		-- Real timetable present — accept and cache.
		register_train(train, {force_identity = true, remember = true})
		return
	end
	-- Empty schedule events fire on splits/rebuilds and were wiping inherited identity + cache.
	-- While a repair is in progress nearby, preserve history. Otherwise allow a true clear.
	if near_repair then
		register_train(train)
		inherit_identity_onto_train_record(train, nil, nil)
	else
		register_train(train, {force_identity = true, remember = true})
	end
end)

script.on_event(defines.events.on_train_changed_state, function(event)
	-- Keep layout current while trains move.
	register_train(event.train)
end)

script.on_nth_tick(300, function()
	-- Low-frequency refresh so idle trains stay accurate without per-tick cost.
	if game and game.forces then
		for _, train in pairs(game.train_manager.get_trains{}) do
			register_train(train)
		end
		cleanup_expired_train_records()
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

	-- Prefer historical records that still have a schedule; disregard blank snapshots.
	local record, train_id = lookup_train_record(entity, nil)

	local hist, hist_id = find_scheduled_history_record(entity)
	if hist and (not record or not record_has_schedule(record) or record_preference_score(hist) > record_preference_score(record)) then
		if record then
			merge_identity_into(hist, record)
		end
		record = hist
		train_id = hist_id or train_id
	end

	if train and train.valid then
		local live = register_train(train)
		if record and live then
			-- Never let a blank live fragment replace a scheduled history record.
			if record_has_schedule(record) and not record_has_schedule(live) then
				merge_identity_into(record, live)
			elseif record_has_schedule(live) and schedule_score(live.schedule) > schedule_score(record.schedule) then
				merge_identity_into(live, record)
				record = live
				train_id = live.train_id
			else
				merge_identity_into(record, live)
			end
		elseif live and not record then
			record = live
			train_id = live.train_id
		end
	end

	local cached = find_cached_identity(entity, record and record.expected or nil)
	if cached and record_has_schedule(cached) then
		if not record then
			record = {
				train_id = train_id,
				schedule = deep_copy(cached.schedule),
				group = cached.group,
				was_automatic = cached.was_automatic,
				expected = deep_copy(cached.expected),
				centroid = deep_copy(cached.centroid),
				force_name = cached.force_name,
				surface_index = cached.surface_index,
				carriages = nil,
			}
		else
			merge_identity_into(record, cached)
		end
	elseif cached and record then
		merge_identity_into(record, cached)
	end

	-- Open repair jobs often still hold the pre-damage schedule across rebuilds.
	local existing_job_id = find_job_for_record(train_id, entity)
	if existing_job_id and storage.ick_repair_jobs[existing_job_id] then
		local job = storage.ick_repair_jobs[existing_job_id]
		if not record then
			record = {
				train_id = job.source_train_id or train_id,
				schedule = deep_copy(job.schedule),
				group = job.group,
				was_automatic = job.was_automatic,
				expected = deep_copy(job.expected),
				centroid = deep_copy(job.centroid),
				force_name = job.force_name,
				surface_index = job.surface_index,
				carriages = deep_copy(job.carriages),
			}
			train_id = job.source_train_id or train_id
		else
			merge_identity_into(record, job)
		end
	end

	-- Final pass: if we still lack a schedule, search history/jobs one more time.
	if record and not record_has_schedule(record) then
		local again = find_scheduled_history_record(entity)
		if again then
			merge_identity_into(record, again)
		end
	end


	local killed_by_train = event.cause and event.cause.train ~= nil
	local had_identity = record and (record.schedule or record.group or record.was_automatic)
	local wants_repair_job = (not killed_by_train) and (had_identity or (train and train.manual_mode == false))
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

			if stored_info.job_id and storage.ick_repair_jobs[stored_info.job_id] then
				local job = storage.ick_repair_jobs[stored_info.job_id]
				job.pending[registration_number] = nil
				job.built[registration_number] = true
				-- Only keep forcing manual while cars are still missing; awaiting-refuel must not.
				if not pending_is_empty(job.pending) then
					hold_entity_train(entity)
				end
				try_complete_repair_job(stored_info.job_id, entity)
			else
				hold_entity_train(entity)
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
	if waiting and next(waiting) then
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
	end

	-- Re-check repair jobs (including ones with stale pending ghosts).
	local jobs = storage.ick_repair_jobs
	if not jobs or not next(jobs) then
		return
	end
	local has_awaiting = false
	for _, job in pairs(jobs) do
		if job.awaiting_refuel or not pending_is_empty(job.pending) then
			has_awaiting = true
			break
		end
	end
	local interval = has_awaiting and 5 or 30
	if event.tick % interval ~= 0 then
		return
	end
	for job_id, job in pairs(jobs) do
		local _, carriage = find_train_near_job(job)
		if carriage then
			try_complete_repair_job(job_id, carriage)
		end
	end
end)

-- Player shift-transfers fuel (or other items) into rolling stock.
script.on_event(defines.events.on_player_fast_transferred, function(event)
	local entity = event.entity
	if entity and entity.valid and entity.train then
		try_complete_jobs_for_train(entity.train)
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
