---@brief [[
--- Mongoose Analytics is a Neovim plugin that tracks and analyzes keystroke patterns in your editor.
--- It provides insights into your typing habits and editor usage patterns by collecting and
--- visualizing keystroke statistics per filetype.
---
--- Features:
--- - Tracks keystroke sequences and their frequency
--- - Measures keystroke timing and duration
--- - Provides filetype-specific analytics
--- - Persists data between sessions
--- - Shows analytics in a floating window
---
--- Usage:
--- ```lua
--- require('mongoose').setup()
--- ```
---
--- Then use the `:Mongoose` command to view analytics for the current buffer.
---@brief ]]

---@tag mongoose

---@config { ['function_order'] = 'ascending' }

local M = {}

local DEFAULT_PROVIDERS = {
  llamacpp = {
    api_url = "http://localhost:8080/completion",
    headers = function(_)
      return {
        ["Content-Type"] = "application/json",
      }
    end,
    format_request = function(prompt)
      -- First, let's ensure our prompt is properly formatted
      if type(prompt) ~= "string" then
        error "Prompt must be a string"
      end

      -- Create the request payload
      local request = {
        prompt = prompt,
        n_predict = 2048,
        temperature = 0.7,
        -- Adding some additional parameters that might help with analysis
        stop = { "</s>", "\n\nHuman:", "\n\nAssistant:" }, -- Stop sequences to prevent rambling
        top_p = 0.9, -- Nucleus sampling parameter
        echo = false, -- Don't echo the prompt in the response
      }

      -- Try to encode the request with error handling
      local ok, encoded = pcall(vim.fn.json_encode, request)
      if not ok then
        error("Failed to encode request: " .. tostring(encoded))
      end

      return encoded
    end,

    parse_response = function(response)
      local ok, decoded = pcall(vim.fn.json_decode, response)
      if not ok then
        error("Failed to decode JSON response: " .. tostring(decoded))
      end

      -- If your API returns the content in a specific field, extract it
      -- For example, if the response looks like: {"content": "actual content"}
      if decoded.content then
        return decoded.content
      else
        -- If the response is the content directly
        return decoded
      end
    end,
  },
}

local config = {
  llm_enabled = false, -- Single flag to control LLM features
}

-- Store key usage statistics
local stats = {}
local data_file = vim.fn.stdpath "data" .. "/mongoose_analytics.json"
local llm_analysis_file = vim.fn.stdpath "data" .. "/mongoose_llm_analysis.json"

-- Timer management
local save_timer = nil
local is_timer_active = false
local current_keys = {}
local last_key_time = 0
local KEY_TIMEOUT = 1000 -- 1 second timeout for key sequences

--- Get current timestamp in milliseconds
---@return number: Current timestamp in milliseconds
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
  readable = readable:gsub("<80>kb", "<BS-") -- Backspace

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
      active_time = ft_data.active_time or 0,
    }

    -- Sanitize each keystroke entry
    for _, keystroke in ipairs(ft_data.keystrokes or {}) do
      local sanitized_keys = sanitize_key_sequence(keystroke.keys or "")
      table.insert(clean[ft].keystrokes, {
        keys = sanitized_keys,
        count = keystroke.count or 0,
        last_used = keystroke.last_used or 0,
        -- Ensure duration is a valid number
        duration = type(keystroke.duration) == "number" and math.abs(keystroke.duration) -- Convert negative to positive
          or 0,
      })
    end
  end
  return clean
end

-- Helper function to escape special pattern characters
local function escape_pattern(text)
  return text:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
end

-- Create a mapping table for special key representations
local special_key_map = {
  ["<CR>"] = "⏎", -- Return/Enter key
  ["<Esc>"] = "⎋", -- Escape key
  ["<Tab>"] = "⇥", -- Tab key
  ["<BS>"] = "⌫", -- Backspace
  ["<Space>"] = "␣", -- Space
}

-- Helper function to format special key sequences
local function format_key_for_display(key)
  if not key then
    return ""
  end

  -- First handle the <80><fd> sequence
  local formatted = key:gsub(escape_pattern "<80><fd>", "")

  -- Handle special cases
  for pattern, replacement in pairs(special_key_map) do
    formatted = formatted:gsub(escape_pattern(pattern), replacement)
  end

  -- Handle single-character keys that should be wrapped
  if #formatted == 1 then
    return formatted
  end

  -- If it's a longer sequence and not already wrapped in brackets, wrap it
  if not formatted:match "^<.*>$" then
    return "<" .. formatted .. ">"
  end

  return formatted
end

--- Load existing statistics from file
---@return nil
local function load_stats()
  local file = io.open(data_file, "r")
  if file then
    local content = file:read "*all"
    file:close()
    if content and content ~= "" then
      local ok, decoded = pcall(vim.fn.json_decode, content)
      if ok then
        stats = decoded
      end
    end
  end
end

--- Save statistics to file with proper timer management
---@return nil
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
  save_timer:start(
    5000,
    0,
    vim.schedule_wrap(function()
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
    end)
  )
end

--- Initialize statistics for a filetype
---@param filetype string: The filetype to initialize
---@return nil
local function ensure_filetype_stats(filetype)
  if not stats[filetype] then
    stats[filetype] = {
      keystrokes = {},
      total_keystrokes = 0,
      session_start = get_timestamp(),
      active_time = 0,
    }
  end
end

--- Record a keystroke with debouncing
---@param keys string: The keystroke sequence to record
---@param duration number: Duration of the keystroke sequence
---@return nil
local function record_keystroke(keys, duration)
  local filetype = vim.bo.filetype or "unknown"
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
      duration = duration,
    })
  end

  stats[filetype].total_keystrokes = stats[filetype].total_keystrokes + 1

  -- Schedule a save operation
  save_stats()
end

--- Process a key event safely
---@param key string: The key event to process
---@return nil
local function handle_key(key)
  local current_time = get_timestamp()

  -- Reset sequence if timeout exceeded
  if current_time - last_key_time > KEY_TIMEOUT then
    current_keys = {}
  end

  local sanitized = sanitize_key_sequence(key)

  -- Add new key to sequence
  table.insert(current_keys, sanitized)
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

-- Helper function to create consistent table borders
local function create_table_line(widths, style)
  local styles = {
    top = { "┌", "┐", "┬", "─" },
    middle = { "├", "┤", "┼", "─" },
    bottom = { "└", "┘", "┴", "─" },
  }
  local chars = styles[style]
  local parts = { chars[1] }

  for i, width in ipairs(widths) do
    table.insert(parts, string.rep(chars[4], width))
    table.insert(parts, i == #widths and chars[2] or chars[3])
  end

  return table.concat(parts)
end

-- Function to create a table row with proper alignment
local function create_table_row(columns, widths, alignments)
  local parts = { "│" }
  for i, col in ipairs(columns) do
    local width = widths[i]
    local align = alignments[i]
    local format_str = align == "left" and "%-" .. width .. "s" or "%" .. width .. "s"
    table.insert(parts, string.format(format_str, col))
    table.insert(parts, "│")
  end
  return table.concat(parts)
end

--- Display analytics in a float window
---@return nil
function M.show_analytics(specific_filetype)
  if not next(stats) then
    vim.notify("No statistics collected yet. Start typing to gather data!", vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = 80 -- Increased width for better readability
  local height = 20

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = "minimal",
    border = "rounded",
  }

  -- Helper function to format durations consistently
  local function format_duration(ms)
    if not ms or ms == 0 then
      return "0ms"
    end
    if ms < 1000 then
      return string.format("%.2fms", ms)
    end
    return string.format("%.2fs", ms / 1000)
  end

  -- Helper to add centered headers
  local function add_centered_header(text)
    local padding = math.floor((width - #text) / 2)
    return string.rep(" ", padding) .. text
  end

  -- Define table properties
  local widths = { 40, 12, 20 } -- Increased key column width
  local alignments = { "left", "right", "right" }
  local content = {}

  if specific_filetype then
    -- Single filetype view
    if not stats[specific_filetype] then
      vim.notify("No statistics available for " .. specific_filetype, vim.log.levels.INFO)
      return
    end

    table.insert(content, add_centered_header("🦦 Mongoose Analytics: " .. specific_filetype))
    table.insert(content, string.rep("═", width))
    table.insert(content, "")

    local ft_stats = stats[specific_filetype]
    table.insert(content, string.format("Total Keystrokes: %d", ft_stats.total_keystrokes))
    table.insert(content, string.format("Active Time: %s", format_duration(ft_stats.active_time)))
    table.insert(content, "Most Used Keys:")
    table.insert(content, "")

    -- Create keystroke table
    table.insert(content, create_table_line(widths, "top"))
    table.insert(content, create_table_row({ "Key", "Count", "Duration" }, widths, alignments))
    table.insert(content, create_table_line(widths, "middle"))

    local sorted_keys = {}
    for _, entry in ipairs(ft_stats.keystrokes) do
      table.insert(sorted_keys, entry)
    end
    table.sort(sorted_keys, function(a, b)
      return a.count > b.count
    end)

    for i = 1, math.min(15, #sorted_keys) do
      local entry = sorted_keys[i]
      local row = {
        format_key_for_display(entry.keys),
        tostring(entry.count),
        format_duration(entry.duration),
      }
      table.insert(content, create_table_row(row, widths, alignments))
    end

    table.insert(content, create_table_line(widths, "bottom"))
  else
    -- Overview of all filetypes
    table.insert(content, add_centered_header "🦦 Mongoose Analytics: All Filetypes")
    table.insert(content, string.rep("═", width))
    table.insert(content, "")

    local total_keystrokes = 0
    local filetype_stats = {}

    -- Collect statistics
    for ft, data in pairs(stats) do
      table.insert(filetype_stats, {
        filetype = ft,
        keystrokes = data.total_keystrokes,
        active_time = data.active_time,
      })
      total_keystrokes = total_keystrokes + data.total_keystrokes
    end

    -- Create overview table
    table.insert(content, create_table_line(widths, "top"))
    table.insert(content, create_table_row({ "Filetype", "Keystrokes", "Active Time" }, widths, alignments))
    table.insert(content, create_table_line(widths, "middle"))

    table.sort(filetype_stats, function(a, b)
      return a.keystrokes > b.keystrokes
    end)

    for _, ft_data in ipairs(filetype_stats) do
      local row = {
        ft_data.filetype,
        tostring(ft_data.keystrokes),
        format_duration(ft_data.active_time),
      }
      table.insert(content, create_table_row(row, widths, alignments))
    end

    table.insert(content, create_table_line(widths, "bottom"))
    table.insert(content, "")
    table.insert(content, string.format("Total Keystrokes (all types): %d", total_keystrokes))
  end

  -- Set up the window
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  local win = vim.api.nvim_open_win(buf, true, win_opts)

  -- Window options
  if vim.api.nvim_win_is_valid(win) then
    vim.wo[win].winhighlight = "Normal:Normal"
  end

  if vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nofile"
  end

  -- Keymaps
  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "q", ":close<CR>", opts)
  vim.keymap.set("n", "<Esc>", ":close<CR>", opts)

  -- Tab switching functionality
  vim.keymap.set("n", "<Tab>", function()
    local fts = {}
    for ft, _ in pairs(stats) do
      table.insert(fts, ft)
    end
    table.sort(fts)

    vim.ui.select(fts, {
      prompt = "Select filetype to view:",
      format_item = function(item)
        return string.format("%s (%d keystrokes)", item, stats[item].total_keystrokes)
      end,
    }, function(choice)
      if choice then
        vim.api.nvim_win_close(win, true)
        M.show_analytics(choice)
      end
    end)
  end, opts)

  -- Navigation help message
  vim.api.nvim_echo({
    { "Press ", "Normal" },
    { "<Tab>", "Special" },
    { " to switch filetypes, ", "Normal" },
    { "q", "Special" },
    { " to close", "Normal" },
  }, false, {})
end

local function format_keystrokes_for_analysis()
  -- Create a comprehensive analysis of keystroke patterns
  local analysis_text = "Here is my detailed Vim usage analysis across different filetypes:\n\n"

  for filetype, data in pairs(stats) do
    -- Skip internal filetypes and empty strings
    if not filetype:match "^__" and filetype ~= "" then
      analysis_text = analysis_text .. string.format("Filetype: %s\n", filetype)
      analysis_text = analysis_text .. string.format("Total keystrokes: %d\n", data.total_keystrokes)

      -- Sort keystrokes by frequency
      local sorted_keystrokes = {}
      for _, entry in ipairs(data.keystrokes) do
        table.insert(sorted_keystrokes, entry)
      end
      table.sort(sorted_keystrokes, function(a, b)
        return a.count > b.count
      end)

      -- Add the most frequent patterns
      analysis_text = analysis_text .. "Most frequent patterns:\n"
      for i = 1, math.min(15, #sorted_keystrokes) do
        local entry = sorted_keystrokes[i]
        analysis_text = analysis_text
          .. string.format(
            "  - Command sequence: %s\n    Used %d times, average duration: %.2fms\n",
            entry.keys,
            entry.count,
            entry.duration
          )
      end
      analysis_text = analysis_text .. "\n"
    end
  end

  return analysis_text
end

-- Create the LLM analysis prompt
local function create_llm_prompt(analytics_text)
  return string.format(
    [[
As an expert Vim user, please analyze the following Vim usage data collected by Mongoose,
a Vim analytics tool. The data shows keystroke patterns across different filetypes.

%s

Based on this data, please provide:

1. INEFFICIENT PATTERNS: Identify specific inefficient patterns in the user Vim usage.
   Consider repetitive keystrokes, slower alternatives to faster commands, and missed
   opportunities for using more powerful Vim features.

2. RECOMMENDATIONS: For each inefficient pattern, suggest more efficient alternatives.
   Include specific examples of how to use these alternatives effectively.

3. LEARNING PLAN: Create a prioritized learning plan focusing on the top 3-5 most
   impactful improvements the user could make. For each improvement, include:
   - The current inefficient pattern
   - The recommended alternative
   - A simple exercise to practice the new approach
   - Estimated keystroke savings based on their usage patterns

4. ADVANCED TECHNIQUES: Suggest 2-3 advanced Vim techniques that would be particularly
   beneficial given their current workflow patterns.

Please format your response as a JSON object with these sections as keys. Within each
section, provide specific, actionable insights rather than general advice.
]],
    analytics_text
  )
end

-- Helper function to make LLM requests
local function make_llm_request(prompt)
  -- Get provider configuration
  local provider = config.custom_provider or DEFAULT_PROVIDERS[config.provider]
  vim.notify("Using provider: " .. config.provider, vim.log.levels.INFO)

  local success, result = pcall(provider.format_request, prompt)
  if not success then
    local format_error = result
    -- Handle the error
    return nil, "Failed to format request: " .. tostring(format_error)
  end

  -- Construct the curl command with better error capture
  local curl_command = string.format(
    'curl -s -w "\\n%%{http_code}" -X POST %s -H "Content-Type: application/json" -d \'%s\' 2>&1',
    provider.api_url,
    vim.fn.escape(tostring(result), "'\\")
  )

  --vim.notify("Curl command: " .. curl_command, vim.log.levels.INFO)

  local handle = io.popen(curl_command)
  if not handle then
    return nil, "Failed to execute request"
  end

  local response = handle:read "*a"
  handle:close()

  -- Split response into body and status code
  local body, status = response:match "^(.+)\n(%d+)$"
  if not status then
    return nil, "Failed to parse response status code"
  end

  if status ~= "200" then
    return nil, string.format("HTTP request failed with status %s: %s", status, body or "unknown error")
  end

  -- At this point, 'body' contains just the JSON response without the status code
  -- Let's add some debug logging
  --vim.notify("Debug - Response body: " .. body, vim.log.levels.DEBUG)

  -- Parse the response body
  local ok, resp = pcall(provider.parse_response, body)
  if not ok then
    return nil, "Failed to parse response: " .. tostring(resp)
  end

  -- Make sure we got a valid response
  if not resp then
    return nil, "Empty response from server"
  end

  return resp
end

-- The main analysis function
function M.trigger_background_analysis()
  -- First, check if LLM features are enabled and configured
  if not config.llm_enabled then
    vim.notify("LLM analysis is not enabled. Configure it first with configure_llm()", vim.log.levels.WARN)
    return
  end

  -- Read the current analytics data
  --  local stats = read_stats_file()
  if not stats then
    vim.notify("No analytics data available for analysis", vim.log.levels.WARN)
    return
  end

  -- Format the data for analysis
  local usage_data = format_keystrokes_for_analysis()

  local prompt = create_llm_prompt(usage_data)

  -- Create an async operation to avoid blocking Neovim
  vim.schedule(function()
    -- Show a notification that analysis is starting
    vim.notify("Starting Vim usage analysis...", vim.log.levels.INFO)

    -- Make the LLM request
    local result, err = make_llm_request(prompt)

    if err then
      vim.notify("Failed to analyze Vim usage: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Save the analysis results
    local analysis = {
      timestamp = os.time(),
      analysis = result,
      source_data = {
        total_keystrokes = 0, -- We'll calculate this
        analyzed_filetypes = {}, -- We'll fill this
      },
    }

    -- Calculate some metadata about the analyzed data
    for filetype, data in pairs(stats) do
      if not filetype:match "^__" and filetype ~= "" then
        analysis.source_data.total_keystrokes = analysis.source_data.total_keystrokes + data.total_keystrokes
        table.insert(analysis.source_data.analyzed_filetypes, filetype)
      end
    end

    -- Save the analysis to a file
    local analysis_file = io.open(llm_analysis_file, "w")
    if analysis_file then
      local ok, encoded = pcall(vim.fn.json_encode, analysis)
      if ok then
        analysis_file:write(encoded)
        analysis_file:close()
        vim.notify("Vim usage analysis completed! Use :Mongoose to view results.", vim.log.levels.INFO)
      else
        vim.notify("Failed to save analysis results", vim.log.levels.ERROR)
      end
    end
  end)
end

--- Cleanup function for proper timer handling
---@return nil
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

function M.configure_llm(opts)
  -- First, validate the basic requirements
  if not opts then
    vim.notify("LLM configuration options are required", vim.log.levels.ERROR)
    return false
  end

  -- Handle provider selection
  if not opts.provider then
    vim.notify("LLM provider must be specified", vim.log.levels.ERROR)
    return false
  end

  -- Reset previous configuration
  config.llm_enabled = true
  config.provider = nil
  config.api_key = nil
  config.custom_provider = nil

  -- Handle custom provider configuration
  if type(opts.provider) == "table" then
    -- Validate custom provider configuration
    if
      not opts.provider.api_url
      or not opts.provider.headers
      or not opts.provider.format_request
      or not opts.provider.parse_response
    then
      vim.notify("Custom provider missing required fields", vim.log.levels.ERROR)
      return false
    end
    config.custom_provider = opts.provider
    config.provider = "custom"
  else
    -- Handle built-in providers
    if not DEFAULT_PROVIDERS[opts.provider] then
      vim.notify("Unknown LLM provider: " .. opts.provider, vim.log.levels.ERROR)
      return false
    end
    config.provider = opts.provider
  end

  -- Handle API key if required
  if opts.provider == "anthropic" and not opts.api_key then
    vim.notify("API key required for Anthropic Claude", vim.log.levels.ERROR)
    return false
  end
  config.api_key = opts.api_key

  -- If we got here, configuration is valid
  config.llm_enabled = true
  return true
end

--- Initialize the Mongoose Analytics plugin
---@return nil
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

  vim.api.nvim_create_user_command("MongooseLLMAnalyze", function()
    -- Before triggering analysis, make sure LLM features are properly configured
    if not config.llm_enabled then
      vim.notify("LLM analysis is not enabled. Please configure LLM features first.", vim.log.levels.WARN)
      return
    end

    -- Call our analysis function
    M.trigger_background_analysis()
  end, {
    desc = "Analyze Vim usage patterns using LLM",
  })

  -- Clean up on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = cleanup,
  })
end

return M
