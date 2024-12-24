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

    -- Schedule the save operation
    save_timer:start(5000, 0, vim.schedule_wrap(function()
        local file = io.open(data_file, "w")
        if file then
            local ok, encoded = pcall(vim.fn.json_encode, stats)
            if ok then
                file:write(encoded)
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
            local duration = current_time - last_key_time
            record_keystroke(sequence, duration)
            current_keys = {}
        end
    end, 100)
end

-- Display analytics in a float window
function M.show_analytics()
    local filetype = vim.bo.filetype
    if not stats[filetype] then
        vim.notify("No statistics available for " .. filetype, vim.log.levels.INFO)
        return
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local width = 60
    local height = 15

    local win_opts = {
        relative = 'editor',
        width = width,
        height = height,
        col = (vim.o.columns - width) / 2,
        row = (vim.o.lines - height) / 2,
        style = 'minimal',
        border = 'rounded'
    }

    -- Prepare content
    local content = {
        "🦦 Mongoose Analytics: " .. filetype,
        string.rep("=", width),
        "",
        string.format("Total Keystrokes: %d", stats[filetype].total_keystrokes),
        "Most Used Keys:",
        string.rep("-", width)
    }

    -- Sort and get top sequences
    local sorted_keys = {}
    for _, entry in ipairs(stats[filetype].keystrokes) do
        table.insert(sorted_keys, entry)
    end

    table.sort(sorted_keys, function(a, b) return a.count > b.count end)

    for i = 1, math.min(10, #sorted_keys) do
        local entry = sorted_keys[i]
        table.insert(content, string.format(
            "%-20s Count: %-5d Avg Duration: %.2fms",
            entry.keys,
            entry.count,
            entry.duration
        ))
    end

    -- Set up the window
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    local win = vim.api.nvim_open_win(buf, true, win_opts)

    -- Window options
    vim.api.nvim_win_set_option(win, 'winhl', 'Normal:Normal')
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')

    -- Close with 'q'
    vim.keymap.set('n', 'q', ':close<CR>', {
        buffer = buf,
        silent = true,
        noremap = true
    })
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
