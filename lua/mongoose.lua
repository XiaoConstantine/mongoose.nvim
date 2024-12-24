local M = {}

-- Store key usage statistics
local stats = {}
local data_file = vim.fn.stdpath("data") .. "/mongoose_analytics.json"

-- Timer management
local save_timer = nil
local is_timer_active = false
local current_keys = {}
local last_key_time = 0
local KEY_TIMEOUT = 1000 -- 1 second timeout for key sequences

-- Helper function to get current timestamp in milliseconds
local function get_timestamp()
    return vim.loop.now()
end

-- Helper function to convert special key sequences to readable format
local function sanitize_key_sequence(key_sequence)
    -- Convert raw byte sequences to readable format
    local readable = key_sequence:gsub(".", function(c)
        local byte = string.byte(c)
        if byte < 32 or byte >= 127 then
            -- Convert special bytes to their hex representation
            return string.format("<%02x>", byte)
        end
        return c
    end)

    -- Further clean up common Neovim key notations
    readable = readable:gsub("<80><fd>", "<S-") -- Shift key combinations
    readable = readable:gsub("<80><fc>", "<C-") -- Control key combinations
    readable = readable:gsub("<80><fe>", "<M-") -- Alt/Meta key combinations

    return readable
end

local function sanitize_for_json(data)
    -- Create a deep copy that we can safely modify
    local clean = {}

    for ft, ft_data in pairs(data) do
        clean[ft] = {
            keystrokes = {},
            total_keystrokes = ft_data.total_keystrokes or 0,
            session_start = ft_data.session_start or 0,
            active_time = ft_data.active_time or 0
        }

        -- Sanitize each keystroke entry
        for _, keystroke in ipairs(ft_data.keystrokes or {}) do
            local sanitized_keys = sanitize_key_sequence(keystroke.keys or "")
            table.insert(clean[ft].keystrokes, {
                keys = sanitized_keys,
                count = keystroke.count or 0,
                last_used = keystroke.last_used or 0,
                -- Ensure duration is a valid number
                duration = type(keystroke.duration) == "number"
                    and math.abs(keystroke.duration) -- Convert negative to positive
                    or 0
            })
        end
    end
    return clean
end

-- Load existing statistics from file
local function load_stats()
    local file = io.open(data_file, "r")
    if file then
        local content = file:read("*all")
        file:close()
        if content and content ~= "" then
            local ok, decoded = pcall(vim.fn.json_decode, content)
            if ok then
                stats = decoded
            end
        end
    end
end

-- Save statistics to file with proper timer management
local function save_stats()
    -- If a save operation is already scheduled, don't schedule another one
    if is_timer_active then
        return
    end

    -- Create a new timer if we don't have one
    if not save_timer then
        save_timer = vim.loop.new_timer()
    end

    -- Mark the timer as active
    is_timer_active = true

    if not save_timer then
        vim.notify("Failed to create timer", vim.log.levels.ERROR)
        return
    end

    -- Schedule the save operation
    save_timer:start(5000, 0, vim.schedule_wrap(function()
        local file = io.open(data_file, "w")
        if file then
            local clean_stats = sanitize_for_json(stats)

            local ok, encoded = pcall(vim.fn.json_encode, clean_stats)
            if ok then
                file:write(encoded)
            else
                vim.notify("Mongoose: Failed to encode stats - " .. tostring(encoded), vim.log.levels.ERROR)
            end
            file:close()
        end

        -- Mark the timer as inactive after save completes
        is_timer_active = false
    end))
end

-- Initialize statistics for a filetype
local function ensure_filetype_stats(filetype)
    if not stats[filetype] then
        stats[filetype] = {
            keystrokes = {},
            total_keystrokes = 0,
            session_start = get_timestamp(),
            active_time = 0
        }
    end
end

-- Record a keystroke with debouncing
local function record_keystroke(keys, duration)
    local filetype = vim.bo.filetype or 'unknown'
    ensure_filetype_stats(filetype)

    -- Find or create keystroke entry
    local found = false
    for _, entry in ipairs(stats[filetype].keystrokes) do
        if entry.keys == keys then
            entry.count = entry.count + 1
            entry.last_used = get_timestamp()
            entry.duration = (entry.duration * (entry.count - 1) + duration) / entry.count
            found = true
            break
        end
    end

    if not found then
        table.insert(stats[filetype].keystrokes, {
            keys = keys,
            count = 1,
            last_used = get_timestamp(),
            duration = duration
        })
    end

    stats[filetype].total_keystrokes = stats[filetype].total_keystrokes + 1

    -- Schedule a save operation
    save_stats()
end

-- Process a key event safely
local function handle_key(key)
    local current_time = get_timestamp()

    -- Reset sequence if timeout exceeded
    if current_time - last_key_time > KEY_TIMEOUT then
        current_keys = {}
    end

    -- Add new key to sequence
    table.insert(current_keys, key)
    last_key_time = current_time

    -- Process the sequence after a brief delay
    vim.defer_fn(function()
        if #current_keys > 0 then
            local sequence = table.concat(current_keys)
            local duration = math.abs(current_time - last_key_time)
            record_keystroke(sequence, duration)
            current_keys = {}
        end
    end, 100)
end

function M.show_analytics(specific_filetype)
    -- If stats is empty, show a helpful message
    if not next(stats) then
        vim.notify("No statistics collected yet. Start typing to gather data!", vim.log.levels.INFO)
        return
    end

    -- Create our floating window setup
    local buf = vim.api.nvim_create_buf(false, true)
    local width = 70  -- Made wider to accommodate more detailed stats
    local height = 20 -- Made taller to show more information

    local win_opts = {
        relative = 'editor',
        width = width,
        height = height,
        col = (vim.o.columns - width) / 2,
        row = (vim.o.lines - height) / 2,
        style = 'minimal',
        border = 'rounded'
    }

    -- Helper function to calculate time spent
    local function format_duration(ms)
        if not ms or ms == 0 then return "0ms" end
        if ms < 1000 then return string.format("%.2fms", ms) end
        return string.format("%.2fs", ms / 1000)
    end

    -- Generate content based on whether a specific filetype was requested
    local content = {}
    local total_keystrokes = 0

    -- Helper to add a centered header
    local function add_centered_header(text)
        local padding = math.floor((width - #text) / 2)
        table.insert(content, string.rep(" ", padding) .. text)
    end

    if specific_filetype then
        -- Show detailed stats for the requested filetype
        if not stats[specific_filetype] then
            vim.notify("No statistics available for " .. specific_filetype, vim.log.levels.INFO)
            return
        end

        add_centered_header("🦦 Mongoose Analytics: " .. specific_filetype)
        table.insert(content, string.rep("=", width))
        table.insert(content, "")

        local ft_stats = stats[specific_filetype]
        table.insert(content, string.format("Total Keystrokes: %d", ft_stats.total_keystrokes))
        table.insert(content, string.format("Active Time: %s", format_duration(ft_stats.active_time)))
        table.insert(content, "Most Used Keys:")
        table.insert(content, string.rep("-", width))

        -- Sort and display keystroke data
        local sorted_keys = {}
        for _, entry in ipairs(ft_stats.keystrokes) do
            table.insert(sorted_keys, entry)
        end
        table.sort(sorted_keys, function(a, b) return a.count > b.count end)

        for i = 1, math.min(15, #sorted_keys) do
            local entry = sorted_keys[i]
            table.insert(content, string.format(
                "%-20s Count: %-5d Avg Duration: %s",
                entry.keys,
                entry.count,
                format_duration(entry.duration)
            ))
        end
    else
        -- Show overview of all filetypes
        add_centered_header("🦦 Mongoose Analytics: All Filetypes")
        table.insert(content, string.rep("=", width))
        table.insert(content, "")
        table.insert(content, "Statistics by Filetype:")
        table.insert(content, string.rep("-", width))

        -- Collect and sort filetype data
        local filetype_stats = {}
        for ft, data in pairs(stats) do
            table.insert(filetype_stats, {
                filetype = ft,
                keystrokes = data.total_keystrokes,
                active_time = data.active_time
            })
            total_keystrokes = total_keystrokes + data.total_keystrokes
        end

        table.sort(filetype_stats, function(a, b) return a.keystrokes > b.keystrokes end)

        -- Display total across all filetypes
        table.insert(content, string.format("Total Keystrokes (all types): %d", total_keystrokes))
        table.insert(content, "")

        -- Display stats for each filetype
        for _, ft_data in ipairs(filetype_stats) do
            table.insert(content, string.format(
                "%-15s Keystrokes: %-6d Active Time: %s",
                ft_data.filetype,
                ft_data.keystrokes,
                format_duration(ft_data.active_time)
            ))
        end
    end

    -- Set up the window
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    local win = vim.api.nvim_open_win(buf, true, win_opts)

    -- Window options and keymaps
    if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].winhighlight = 'Normal:Normal'
    end

    if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = false
        vim.bo[buf].buftype = 'nofile'
    end

    -- Enhanced keymaps for navigation
    local opts = { buffer = buf, noremap = true, silent = true }
    vim.keymap.set('n', 'q', ':close<CR>', opts)
    vim.keymap.set('n', '<Esc>', ':close<CR>', opts)

    -- Allow switching between filetypes
    vim.keymap.set('n', '<Tab>', function()
        -- Get list of filetypes
        local fts = {}
        for ft, _ in pairs(stats) do
            table.insert(fts, ft)
        end
        table.sort(fts)

        -- Show filetype selector
        vim.ui.select(fts, {
            prompt = 'Select filetype to view:',
            format_item = function(item)
                return string.format("%s (%d keystrokes)",
                    item,
                    stats[item].total_keystrokes)
            end
        }, function(choice)
            if choice then
                -- Close current window and show new stats
                vim.api.nvim_win_close(win, true)
                M.show_analytics(choice)
            end
        end)
    end, opts)

    -- Add helpful message about navigation
    vim.api.nvim_echo({
        { "Press ",                 "Normal" },
        { "<Tab>",                  "Special" },
        { " to switch filetypes, ", "Normal" },
        { "q",                      "Special" },
        { " to close",              "Normal" }
    }, false, {})
end

-- Cleanup function for proper timer handling
local function cleanup()
    if save_timer then
        save_timer:stop()
        -- Save any pending changes
        local file = io.open(data_file, "w")
        if file then
            local ok, encoded = pcall(vim.fn.json_encode, stats)
            if ok then
                file:write(encoded)
            end
            file:close()
        end
        save_timer:close()
        save_timer = nil
    end
    is_timer_active = false
end

-- Setup function
function M.setup()
    -- Load existing stats
    load_stats()

    -- Create autocmd group
    local group = vim.api.nvim_create_augroup("MongooseAnalytics", { clear = true })

    -- Set up key event handler with proper debouncing
    vim.on_key(function(key)
        vim.schedule(function()
            handle_key(key)
        end)
    end, group)

    -- Create the command
    vim.api.nvim_create_user_command("Mongoose", function()
        M.show_analytics()
    end, {})

    -- Clean up on exit
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = cleanup
    })
end

return M
