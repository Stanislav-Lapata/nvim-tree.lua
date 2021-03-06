local api = vim.api
local luv = vim.loop

local renderer = require'lib.renderer'
local config = require'lib.config'
local git = require'lib.git'
local pops = require'lib.populate'
local populate = pops.populate
local refresh_entries = pops.refresh_entries

local window_opts = config.window_options()

local M = {}

M.Tree = {
  entries = {},
  buf_name = 'LuaTree',
  cwd = nil,
  win_width =  vim.g.lua_tree_width or 30,
  loaded = false,
  bufnr = nil,
  winnr = function()
    for _, i in ipairs(api.nvim_list_wins()) do
      if api.nvim_buf_get_name(api.nvim_win_get_buf(i)):match('.*/'..M.Tree.buf_name..'$') then
        return i
      end
    end
  end,
  options = {
    'noswapfile',
    'norelativenumber',
    'nonumber',
    'nolist',
    'winfixwidth',
    'winfixheight',
    'nofoldenable',
    'nospell',
    'foldmethod=manual',
    'foldcolumn=0'
  }
}

function M.init(with_open, with_render)
  M.Tree.cwd = luv.cwd()
  populate(M.Tree.entries, M.Tree.cwd, M.Tree)

  local stat = luv.fs_stat(M.Tree.cwd)
  M.Tree.last_modified = stat.mtime.sec

  if with_open then
    M.open()
  end

  if with_render then
    renderer.draw(M.Tree, true)
    M.Tree.loaded = true
  end
end

local function get_node_at_line(line)
  local index = 2
  local function iter(entries)
    for _, node in ipairs(entries) do
      if index == line then
        return node
      end
      index = index + 1
      if node.open == true then
        local child = iter(node.entries)
        if child ~= nil then return child end
      end
    end
  end
  return iter
end

function M.get_node_at_cursor()
  local cursor = api.nvim_win_get_cursor(M.Tree.winnr())
  local line = cursor[1]
  if line == 1 and M.Tree.cwd ~= "/" then
    return { name = ".." }
  end

  if M.Tree.cwd == "/" then
    line = line + 1
  end
  return get_node_at_line(line)(M.Tree.entries)
end

function M.unroll_dir(node)
  node.open = not node.open
  if #node.entries > 0 then
    renderer.draw(M.Tree, true)
  else
    populate(node.entries, node.absolute_path)
    renderer.draw(M.Tree, true)
  end
end

local function refresh_git(node)
  git.update_status(node.entries, node.absolute_path or node.cwd)
  for _, entry in pairs(node.entries) do
    if entry.entries ~= nil then
      refresh_git(entry)
    end
  end
end

-- TODO update only entries where directory has changed
local function refresh_nodes(node)
  refresh_entries(node.entries, node.absolute_path or node.cwd)
  for _, entry in ipairs(node.entries) do
    if entry.entries and entry.open then
      refresh_nodes(entry)
    end
  end
end

function M.refresh_tree()
  -- local stat = luv.fs_stat(M.Tree.cwd)
  -- if stat.mtime.sec ~= M.Tree.last_modified then
    refresh_nodes(M.Tree)
  -- end
  if config.get_icon_state().show_git_icon then
    git.reload_roots()
    refresh_git(M.Tree)
  end
  if M.win_open() then
    renderer.draw(M.Tree, true)
  else
    M.Tree.loaded = false
  end
end

function M.set_index_and_redraw(fname)
  local i
  if M.Tree.cwd == '/' then
    i = 0
  else
    i = 1
  end
  local reload = false

  local function iter(entries)
    for _, entry in ipairs(entries) do
      i = i + 1
      if entry.absolute_path == fname then
        return i
      end

      if fname:match(entry.match_path..'/') ~= nil then
        if #entry.entries == 0 then
          reload = true
          populate(entry.entries, entry.absolute_path)
        end
        if entry.open == false then
          reload = true
          entry.open = true
        end
        if iter(entry.entries) ~= nil then
          return i
        end
      elseif entry.open == true then
        iter(entry.entries)
      end
    end
  end

  local index = iter(M.Tree.entries)
  if not M.win_open() then
    M.Tree.loaded = false
    return
  end
  renderer.draw(M.Tree, reload)
  if index then
    api.nvim_win_set_cursor(M.Tree.winnr(), {index, 0})
  end
end

local function check_and_open_split()
  if #api.nvim_list_wins() == 1 then
    api.nvim_command("vnew")
  end
end

function M.open_file(mode, filename)
  api.nvim_command('noautocmd wincmd '..window_opts.open_command)
  if mode == 'preview' then
    check_and_open_split()
    api.nvim_command(string.format("edit %s", filename))
    api.nvim_command('noautocmd wincmd '..window_opts.preview_command)
  else
    if mode == 'edit' then
      check_and_open_split()
    end
    api.nvim_command(string.format("%s %s", mode, filename))
  end
  local cur_win = api.nvim_get_current_win()
  M.win_focus()
  api.nvim_command('vertical resize '..M.Tree.win_width)
  M.win_focus(cur_win)
  if vim.g.lua_tree_quit_on_open then
    M.close()
  end
end

function M.change_dir(foldername)
  api.nvim_command('cd '..foldername)
  M.Tree.entries = {}
  M.init(false, M.Tree.bufnr ~= nil)
end

local function set_mapping(buf, key, fn)
  api.nvim_buf_set_keymap(buf, 'n', key, ':lua require"tree".'..fn..'<cr>', {
      nowait = true, noremap = true, silent = true
    })
end

local function set_mappings()
  if vim.g.lua_tree_disable_keybindings == 1 then
      return
  end

  local buf = M.Tree.bufnr
  local bindings = config.get_bindings()

  local mappings = {
    ['<2-LeftMouse>'] = 'on_keypress("edit")';
    ['<2-RightMouse>'] = 'on_keypress("cd")';
    [bindings.cd] = 'on_keypress("cd")';
    [bindings.edit] = 'on_keypress("edit")';
    [bindings.edit_vsplit] = 'on_keypress("vsplit")';
    [bindings.edit_split] = 'on_keypress("split")';
    [bindings.edit_tab] = 'on_keypress("tabnew")';
    [bindings.toggle_ignored] = 'on_keypress("toggle_ignored")';
    [bindings.toggle_dotfiles] = 'on_keypress("toggle_dotfiles")';
    [bindings.refresh] = 'on_keypress("refresh")';
    [bindings.create] = 'on_keypress("create")';
    [bindings.remove] = 'on_keypress("remove")';
    [bindings.rename] = 'on_keypress("rename")';
    [bindings.preview] = 'on_keypress("preview")';
    [bindings.cut] = 'on_keypress("cut")';
    [bindings.copy] = 'on_keypress("copy")';
    [bindings.paste] = 'on_keypress("paste")';
    [bindings.prev_git_item] = 'on_keypress("prev_git_item")';
    [bindings.next_git_item] = 'on_keypress("next_git_item")';
    gx = "xdg_open()";
  }

  for k,v in pairs(mappings) do
    if type(k) == 'table' then
      for _, key in pairs(k) do
        set_mapping(buf, key, v)
      end
    else
      set_mapping(buf, k, v)
    end
  end
end

local function create_buf()
  local options = {
    bufhidden = 'wipe';
    buftype = 'nofile';
    modifiable = false;
  }

  M.Tree.bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(M.Tree.bufnr, M.Tree.buf_name)

  for opt, val in pairs(options) do
    api.nvim_buf_set_option(M.Tree.bufnr, opt, val)
  end
  set_mappings()
end

local function create_win()
  api.nvim_command("vsplit")
  api.nvim_command("wincmd "..window_opts.side)
  api.nvim_command("vertical resize "..M.Tree.win_width)
end

function M.close()
  if #api.nvim_list_wins() == 1 then
    return vim.cmd ':q!'
  end
  api.nvim_win_close(M.Tree.winnr(), true)
  M.Tree.bufnr = nil
end

function M.open()
  create_buf()
  create_win()
  api.nvim_win_set_buf(M.Tree.winnr(), M.Tree.bufnr)

  for _, opt in pairs(M.Tree.options) do
    api.nvim_command('setlocal '..opt)
  end

  renderer.draw(M.Tree, not M.Tree.loaded)
  M.Tree.loaded = true

  api.nvim_buf_set_option(M.Tree.bufnr, 'filetype', M.Tree.buf_name)
  api.nvim_command('setlocal '..window_opts.split_command)
end

function M.win_open()
  return M.Tree.winnr() ~= nil
end

function M.win_focus(winnr)
  local wnr = winnr or M.Tree.winnr()
  api.nvim_set_current_win(wnr)
end

function M.toggle_ignored()
  pops.show_ignored = not pops.show_ignored
  return M.refresh_tree()
end

function M.toggle_dotfiles()
  pops.show_dotfiles = not pops.show_dotfiles
  return M.refresh_tree()
end

return M
