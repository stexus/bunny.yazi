-- Run from the repository root with: lua test/regression.lua
local function equal(actual, expected)
  assert(actual == expected, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

local function url(path)
  return setmetatable({
    join = function(_, child) return url(path:gsub('/$', '') .. '/' .. child) end,
  }, {
    __tostring = function() return path end,
    __index = function(_, key)
      if key == 'name' then return path:match('([^/]+)$') end
      if key == 'parent' and path ~= '/' then
        return url(path:match('^(.*)/[^/]+$'):gsub('^$', '/'))
      end
    end,
  })
end

local function fixture(options, cwd, markers)
  local state, events, notices, emitted = {}, {}, {}, {}
  local active = { id = { value = 42 }, current = { cwd = url(cwd or '/repo/subdir') } }
  local context = { active = active, tabs = { active, idx = 1 } }
  local selected, candidates
  local env = setmetatable({
    Url = url,
    cx = context,
    ya = {
      sync = function(fn) return function(...) return fn(state, ...) end end,
      notify = function(msg) notices[#notices + 1] = msg end,
      emit = function(action, args) emitted[#emitted + 1] = { action, args[1] } end,
      which = function(opts)
        candidates = opts.cands
        for i, cand in ipairs(candidates) do
          if cand.on == selected then return i end
        end
      end,
    },
    ps = { sub = function(event, callback) events[event] = callback end },
    fs = {
      cha = function(path) return (markers or {})[tostring(path)] end,
      read_dir = function() return {} end,
    },
  }, { __index = _G })
  local plugin = assert(loadfile('main.lua', 't', env))()
  plugin.setup(state, options)
  return {
    state = state, events = events, notices = notices, emitted = emitted, cx = context,
    run = function(key)
      selected = key
      plugin.entry(state, { args = {} })
      return candidates
    end,
  }
end

local tests = {
  ['filename descriptions use the Url property'] = function()
    local f = fixture({ hops = { { key = 'a', path = '/tmp/bookmark' } }, desc_strategy = 'filename' })
    f.run('a')
    equal(f.state.hops[1].desc, 'bookmark')
    equal(f.emitted[1][2], '/tmp/bookmark')
  end,
  ['boolean options work without notify'] = function()
    local f = fixture({ hops = {}, tabs = false, ephemeral = false })
    equal(#f.run(), 1) -- Only fuzzy search; no initial cd event is required.
    equal(#f.notices, 0)
    equal(f.state.config.tabs, false)
    equal(f.state.config.ephemeral, false)
  end,
  ['invalid boolean options are rejected even with notify'] = function()
    for _, key in ipairs({ 'tabs', 'ephemeral' }) do
      local f = fixture({ hops = {}, [key] = 'yes', notify = true })
      f.run()
      equal(f.notices[1].content, 'Invalid "' .. key .. '" config value')
    end
  end,
  ['history follows tab IDs and event URLs'] = function()
    local f = fixture({ hops = {} })
    f.events.cd({ tab = 42, url = url('/first') })
    f.events.cd({ tab = 42, url = url('/second') })
    f.events.cd({ tab = 42, url = url('/second') })
    f.events.cd({ tab = 99, url = url('/background') })
    f.cx.tabs.idx = 2
    f.run('<Backspace>')
    equal(f.emitted[1][2], '/first')
    equal(f.state.tabhist[99][1], '/background')
  end,
  ['local cd events resolve the emitting tab when the URL is omitted'] = function()
    local f = fixture({ hops = {} })
    f.events.cd({ tab = 42 })
    f.cx.active.current.cwd = url('/next')
    f.events.cd({ tab = { value = 42 } })
    f.cx.tabs[2] = { id = { value = 99 }, current = { cwd = url('/background') } }
    f.events.cd({ tab = 99 })
    f.events.cd({ tab = 100 }) -- A tab that no longer exists.
    f.run('<Backspace>')
    equal(f.emitted[1][2], '/repo/subdir')
    equal(f.state.tabhist[99][1], '/background')
    equal(f.state.tabhist[100], nil)
  end,
  ['repository hops find Git directories, worktree files, and Sapling'] = function()
    for _, marker in ipairs({ '.git', '.hg' }) do
      for _, kind in ipairs(marker == '.git' and { 'is_dir', 'is_file' } or { 'is_dir' }) do
        local f = fixture({ hops = { { key = 'a', path = '@repo/src' } } }, '/repo/subdir', {
          ['/repo/' .. marker] = { [kind] = true },
        })
        f.run('a')
        equal(f.emitted[1][2], '/repo/src')
      end
    end
  end,
  ['repository search includes the filesystem root'] = function()
    local f = fixture({ hops = { { key = 'a', path = '@repo/src' } } }, '/nested', {
      ['/.git'] = { is_dir = true },
    })
    f.run('a')
    equal(f.emitted[1][2], '/src')
  end,
  ['nearest repository wins and empty suffix hops to its root'] = function()
    local f = fixture({ hops = { { key = 'a', path = '@repo/' } } }, '/repo/subdir', {
      ['/repo/.git'] = { is_dir = true },
      ['/repo/subdir/.git'] = { is_file = true },
    })
    f.run('a')
    equal(f.emitted[1][2], '/repo/subdir')
  end,
  ['missing repository reports an error without changing directory'] = function()
    local f = fixture({ hops = { { key = 'a', path = '@repo/src' } } })
    f.run('a')
    equal(#f.emitted, 0)
    equal(f.notices[1].content, 'Not in a git or sapling repository')
  end,
}

local count = 0
for name, test in pairs(tests) do
  test()
  count = count + 1
  print('ok - ' .. name)
end
print(('%d regression tests passed'):format(count))
