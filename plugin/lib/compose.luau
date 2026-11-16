-- The host half of Compose previews. A preview is one browser pane the window half opens on its
-- session's loopback page (window.luau); window and host VMs do not share buffers, so this half
-- posts the dirty Elide editors of each session's workspace to it. The window lists its sessions
-- in kv (`compose:sessions`, window key to session URL to workspace root); this half reads the
-- list on every editor change, and every 500 ms while it holds dirty editors, so a new session
-- gets them too.
local links = require("./links")
local source = require("./source")
local loopback = require("./loopback")
local SESSIONS = "compose:sessions"
-- Dirty editors by pane: `{ file, text, revision }`.
local documents = {}
local documents_revision = 0
-- Sessions by URL: `{ root, queued, posting, ended? }`, as last listed.
local sessions = {}
local ticking = false

-- Job directories of the snapshot helper the preview service replaced.
pcall(tern.fs.remove, tern.plugin.data .. "/compose-jobs")

-- The newest dirty text of `file` across Elide editors, nil when none is dirty.
local function latest_text(file)
  local newest
  for _, draft in documents do
    if draft.file == file and (not newest or newest.revision < draft.revision) then
      newest = draft
    end
  end
  return newest and newest.text
end

-- Posts a session's queued editor texts (`false`: the editor no longer differs from the file),
-- one request at a time; texts queued meanwhile go out when it returns.
local function post(url, session)
  if session.posting or session.ended or next(session.queued) == nil then
    return
  end
  local sent = session.queued
  local entries = {}
  for file, content in sent do
    table.insert(
      entries,
      '{"file":'
        .. tern.json.encode(file)
        .. ',"text":'
        .. (if content then tern.json.encode(content) else "null")
        .. "}"
    )
  end
  session.queued = {}
  session.posting = true
  loopback.request(
    url .. "documents",
    '{"origin":"host","replace":false,"documents":[' .. table.concat(entries, ",") .. "]}",
    10000,
    function(status, _, _, timed_out)
      session.posting = false
      if status == 0 and timed_out then
        -- No answer in time is no answer: send these texts again unless newer ones are queued.
        for file, content in sent do
          if session.queued[file] == nil then
            session.queued[file] = content
          end
        end
      else
        -- An ended session (gone, or refusing connections) takes no more; the window drops it.
        -- A rejected post is not sent again: the page says why, and the next edit is posted.
        session.ended = status == 0 or status == 404 or status == 410
      end
      post(url, session)
    end
  )
end

-- Reads the listed sessions: a new one is queued every dirty editor of its workspace.
local function sync()
  local listed = {}
  local ok, all = pcall(tern.kv.get, SESSIONS)
  for _, window in (ok and type(all) == "table") and all or {} do
    for url, root in type(window) == "table" and window or {} do
      root = links.absolute(root)
      if type(url) == "string" and root then
        listed[url] = root
      end
    end
  end
  for url in sessions do
    if not listed[url] then
      sessions[url] = nil
    end
  end
  for url, root in listed do
    if not sessions[url] then
      local session = { root = root, queued = {} }
      sessions[url] = session
      for _, draft in documents do
        if links.within(draft.file, root) then
          session.queued[draft.file] = latest_text(draft.file) or false
        end
      end
      post(url, session)
    end
  end
end

local function tick()
  if ticking or next(documents) == nil then
    return
  end
  ticking = true
  tern.timer(500, function()
    ticking = false
    sync()
    tick()
  end)
end

local function document(pane, file, content)
  file = links.absolute(file)
  if not file or (source.extension(file) ~= "kt" and source.extension(file) ~= "java") then
    content = nil
  end
  local previous = documents[pane]
  if (content == nil and previous == nil) or (previous and previous.file == file and previous.text == content) then
    return
  end
  documents_revision += 1
  documents[pane] = type(content) == "string" and { file = file, text = content, revision = documents_revision } or nil
  sync()
  for _, changed in { previous and previous.file, documents[pane] and file } do
    for url, session in sessions do
      if changed and links.within(changed, session.root) then
        session.queued[changed] = latest_text(changed) or false
        post(url, session)
      end
    end
  end
  tick()
end

return { document = document }
