local M = {}
local Job = require 'plenary.job'

local function get_api_key(name)
  return os.getenv(name)
end

function M.get_lines_until_cursor()
  local current_buffer = vim.api.nvim_get_current_buf()
  local current_window = vim.api.nvim_get_current_win()
  local cursor_position = vim.api.nvim_win_get_cursor(current_window)
  local row = cursor_position[1]

  local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

  return table.concat(lines, '\n')
end

function M.get_visual_selection()
  local _, srow, scol = unpack(vim.fn.getpos 'v')
  local _, erow, ecol = unpack(vim.fn.getpos '.')

  if vim.fn.mode() == 'V' then
    if srow > erow then
      return vim.api.nvim_buf_get_lines(0, erow - 1, srow, true)
    else
      return vim.api.nvim_buf_get_lines(0, srow - 1, erow, true)
    end
  end

  if vim.fn.mode() == 'v' then
    if srow < erow or (srow == erow and scol <= ecol) then
      return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
    else
      return vim.api.nvim_buf_get_text(0, erow - 1, ecol - 1, srow - 1, scol, {})
    end
  end

  if vim.fn.mode() == '\22' then
    local lines = {}
    if srow > erow then
      srow, erow = erow, srow
    end
    if scol > ecol then
      scol, ecol = ecol, scol
    end
    for i = srow, erow do
      table.insert(lines, vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1, math.max(scol - 1, ecol), {})[1])
    end
    return lines
  end
end

function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
  local url = opts.url
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local data = {
    system = system_prompt,
    messages = { { role = 'user', content = prompt } },
    model = opts.model,
    stream = true,
    max_tokens = 4096,
  }
  local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '-d', vim.json.encode(data) }
  if api_key then
    table.insert(args, '-H')
    table.insert(args, 'x-api-key: ' .. api_key)
    table.insert(args, '-H')
    table.insert(args, 'anthropic-version: 2023-06-01')
  end
  table.insert(args, url)
  return args
end

function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
  local url = opts.url
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local data = {
    messages = { { role = 'system', content = system_prompt }, { role = 'user', content = prompt } },
    model = opts.model,
    temperature = 0.7,
    stream = true,
  }
  local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '-d', vim.json.encode(data) }
  if api_key then
    table.insert(args, '-H')
    table.insert(args, 'Authorization: Bearer ' .. api_key)
  end
  table.insert(args, url)
  return args
end

function M.make_gemini_spec_curl_args(opts, prompt, system_prompt)
  local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
  local url = opts.url .. "/" .. opts.model .. ":generateContent?key=" .. api_key

  local data = {
      contents = {
          {
              parts = { { text = system_prompt } },
              role = "model",
          },
          {
              parts = { { text = prompt } },
              role = "user",
          },
      },
  }

  local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '-d', vim.json.encode(data) }
  table.insert(args, url)
  return args
end

function M.write_string_at_cursor(str)
  vim.schedule(function()
    local current_window = vim.api.nvim_get_current_win()
    local cursor_position = vim.api.nvim_win_get_cursor(current_window)
    local row, col = cursor_position[1], cursor_position[2]

    local lines = vim.split(str, '\n')

    vim.cmd("undojoin")
    vim.api.nvim_put(lines, 'c', true, true)

    local num_lines = #lines
    local last_line_length = #lines[num_lines]
    vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
  end)
end

local function get_prompt(opts)
  local replace = opts.replace
  local visual_lines = M.get_visual_selection()
  local prompt = ''

  if visual_lines then
    prompt = table.concat(visual_lines, '\n')
    if replace then
      vim.api.nvim_command 'normal! d'
      vim.api.nvim_command 'normal! k'
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', false, true, true), 'nx', false)
    end
  else
    prompt = M.get_lines_until_cursor()
  end

  return prompt
end

function M.handle_anthropic_spec_data(data_stream, event_state)
  if event_state == 'content_block_delta' then
    local json = vim.json.decode(data_stream)
    if json.delta and json.delta.text then
      M.write_string_at_cursor(json.delta.text)
    end
  end
end

function M.handle_openai_spec_data(data_stream)
  if data_stream:match '"delta":' then
    local json = vim.json.decode(data_stream)
    if json.choices and json.choices[1] and json.choices[1].delta then
      local content = json.choices[1].delta.content
      if content then
        M.write_string_at_cursor(content)
      end
    end
  end
end

function M.handle_gemini_spec_data(json_str)
  local json = vim.json.decode(json_str)
  if json.candidates and json.candidates[1].content.parts[1].text then
    local content = json.candidates[1].content.parts[1].text
    if content then
      M.write_string_at_cursor(content)
    end
  end
end

local group = vim.api.nvim_create_augroup('DING_LLM_AutoGroup', { clear = true })
local active_job = nil

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_data_fn)
  vim.api.nvim_clear_autocmds { group = group }
  local prompt = get_prompt(opts)
  local system_prompt = opts.system_prompt or 'You are a tsundere uwu anime. Yell at me for not setting my configuration for my llm plugin correctly'
  local args = make_curl_args_fn(opts, prompt, system_prompt)
  local curr_event_state = nil

  local function parse_and_call(line)
    local event = line:match '^event: (.+)$'
    if event then
      curr_event_state = event
      return
    end
    local data_match = line:match '^data: (.+)$'
    if data_match then
      handle_data_fn(data_match, curr_event_state)
    end
  end

  if active_job then
    active_job:shutdown()
    active_job = nil
  end

  active_job = Job:new {
    command = 'curl',
    args = args,
    on_stdout = function(_, out)
      parse_and_call(out)
    end,
    on_stderr = function(_, _) end,
    on_exit = function(j, return_val)
      if return_val ~= 0 then
          print("dingllm: Curl command failed with code:", return_val)
      end

      local json_string = table.concat(j:result())
      local data_str = "data: " .. json_string
      parse_and_call(data_str)

      active_job = nil
    end,
  }

  active_job:start()

  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DING_LLM_Escape',
    callback = function()
      if active_job then
        active_job:shutdown()
        print 'LLM streaming cancelled'
        active_job = nil
      end
    end,
  })

  vim.api.nvim_set_keymap('n', '<Esc>', ':doautocmd User DING_LLM_Escape<CR>', { noremap = true, silent = true })
  return active_job
end

return M
