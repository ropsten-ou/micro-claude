VERSION = "0.1.0"

-- micro-claude: talk to Claude Code from micro over ACP (Agent Client Protocol).
-- The agent runs as a child process (claude-agent-acp) speaking newline-delimited
-- JSON-RPC 2.0 on stdin/stdout. The conversation is appended to a scratch split.

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local util = import("micro/util")
local goos = import("os")
local time = import("time")

------------------------------------------------------------------------------
-- Minimal JSON (micro's Lua has none built in)
------------------------------------------------------------------------------

local json = {}
local array_mt = {}

-- Mark a table as a JSON array so an empty one encodes as [] rather than {}.
function json.array(t)
    return setmetatable(t or {}, array_mt)
end

local escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    if getmetatable(t) == array_mt then return true end
    return next(t) ~= nil and #t > 0
end

function json.encode(v)
    local t = type(v)
    if v == nil or v == json.null then
        return "null"
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.14g", v)
    elseif t == "string" then
        return encode_string(v)
    elseif t == "table" then
        local out = {}
        if is_array(v) then
            for i = 1, #v do out[i] = json.encode(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        for k, val in pairs(v) do
            out[#out + 1] = encode_string(tostring(k)) .. ":" .. json.encode(val)
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    error("cannot encode " .. t)
end

json.null = setmetatable({}, { __tostring = function() return "null" end })

local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

function json.decode(s)
    local pos = 1

    local function ws()
        pos = s:find("[^ \t\r\n]", pos) or #s + 1
    end

    local value

    local function str()
        pos = pos + 1 -- opening quote
        local parts = {}
        while true do
            local i = s:find('["\\]', pos)
            if not i then error("unterminated string") end
            parts[#parts + 1] = s:sub(pos, i - 1)
            if s:sub(i, i) == '"' then
                pos = i + 1
                return table.concat(parts)
            end
            local c = s:sub(i + 1, i + 1)
            if c == "u" then
                local cp = tonumber(s:sub(i + 2, i + 5), 16)
                pos = i + 6
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
                    local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    pos = pos + 6
                end
                parts[#parts + 1] = utf8_char(cp)
            else
                local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                parts[#parts + 1] = map[c] or c
                pos = i + 2
            end
        end
    end

    function value()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            local obj = {}
            pos = pos + 1
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
            while true do
                ws()
                local k = str()
                ws()
                pos = pos + 1 -- colon
                obj[k] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return obj end
            end
        elseif c == "[" then
            local arr = json.array({})
            pos = pos + 1
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
            while true do
                arr[#arr + 1] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return arr end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(pos, pos + 3) == "true" then
            pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then
            pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then
            pos = pos + 4 return json.null
        end
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if not num or num == "" then error("unexpected '" .. c .. "' at " .. pos) end
        pos = pos + #num
        return tonumber(num)
    end

    return value()
end

------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------

local hill_send          -- tells hill-ops's strip something; defined with hill-ops's code below
local job = nil          -- running agent process
local agent_gen = 0      -- tells a stopped agent's late output and exit from the current one's
local stdout_buf = ""    -- partial line from the agent
local stderr_tail = {}   -- last few stderr lines, shown if the agent dies
local next_id = 1
local pending = {}       -- request id -> callback(result, err)
local session_id = nil
local busy = false       -- a prompt turn is in progress
local queued = nil       -- prompt waiting for the session to be ready

local chat_buf = nil     -- scratch buffer holding the conversation
local chat_pane = nil    -- pane showing it (nil if closed)
local at_line_start = true
local in_message = false -- currently streaming Claude's reply text
local replied = false    -- the "## Claude" heading was shown this turn

local draft_pane = nil   -- split under the chat where a prompt is written (nil if closed)
local draft_for = nil    -- pane Alt-c was pressed in: its file and selection go along

local permission_queue = {}  -- the agent's permission requests, oldest first
local announced = nil        -- the first of them, announced and waiting for Alt-c
local denied = {}            -- toolCallId -> true when the user said no

------------------------------------------------------------------------------
-- Chat pane
------------------------------------------------------------------------------

local function append(text)
    if chat_buf == nil or text == "" then return end
    chat_buf.EventHandler:Insert(chat_buf:End(), text)
    at_line_start = text:sub(-1) == "\n"
    if chat_pane ~= nil then
        chat_pane.Cursor:GotoLoc(chat_buf:End())
        chat_pane:Relocate()
    end
end

-- Start a new block (heading or status line) on a fresh line.
local function block(text)
    if not at_line_start then append("\n") end
    append(text)
end

local function ensure_pane(bp)
    if chat_buf == nil then
        chat_buf = buffer.NewBuffer("", "claude-chat")
        chat_buf.Type.Scratch = true
        chat_buf.Type.Readonly = true
        chat_buf:SetOptionNative("filetype", "markdown")
        chat_buf:SetOptionNative("softwrap", true)
        chat_buf:SetOptionNative("wordwrap", true)
    end
    if chat_pane == nil then
        chat_pane = bp:VSplitIndex(chat_buf, true)
        -- keep typing focus in the file the user was editing
        micro.CurTab():SetActive(micro.CurTab():GetPane(bp:ID()))
    end
end

------------------------------------------------------------------------------
-- Files Claude changes
------------------------------------------------------------------------------

-- Claude's tools write straight to disk, and micro only notices on the next
-- keypress in that pane. So after each tool call, reload open files that
-- changed. A buffer with unsaved edits is left alone (reloading would drop
-- them), with a warning, because saving it would overwrite Claude's change.
local warned = {} -- path -> true once a conflict has been reported

local function open_bufpanes()
    local panes = {}
    local tabs = micro.Tabs().List
    for i = 1, #tabs do
        local list = tabs[i].Panes
        for j = 1, #list do
            local p = list[j]
            -- terminal panes have no Buf
            local ok, buf = pcall(function() return p.Buf end)
            if ok and buf ~= nil then panes[#panes + 1] = p end
        end
    end
    return panes
end

local function sync_open_files()
    if not config.GetGlobalOption("claude.autoreload") then return end
    for _, p in ipairs(open_bufpanes()) do
        local buf = p.Buf
        if buf ~= chat_buf and buf.Path ~= "" then
            if not buf:ExternallyModified() then
                warned[buf.AbsPath] = nil
            elseif not buf:Modified() then
                -- applied as a diff, so Ctrl-z in that file undoes Claude's change
                p:ReOpen()
                block("  ↻ reloaded " .. buf:GetName() .. "\n")
            elseif not warned[buf.AbsPath] then
                warned[buf.AbsPath] = true
                block("  ! " .. buf:GetName() .. " changed on disk but has unsaved edits in micro.\n"
                    .. "    > save keeps yours (overwriting Claude's change); > reopen, then n, loads Claude's.\n")
            end
        end
    end
end

-- Claude reads files from disk, so save unsaved edits before each message.
-- Skip a file that also changed on disk: saving would overwrite Claude's change.
local function save_open_files()
    if not config.GetGlobalOption("claude.autosave") then return end
    local saved = {}
    for _, p in ipairs(open_bufpanes()) do
        local buf = p.Buf
        if buf ~= chat_buf and buf.Path ~= "" and not buf.Type.Scratch
            and not buf.Type.Readonly and buf:Modified() then
            if buf:ExternallyModified() then
                warned[buf.AbsPath] = true
                block("  ! " .. buf:GetName() .. " not saved: it also changed on disk.\n"
                    .. "    > save keeps yours (overwriting Claude's change); > reopen, then n, loads Claude's.\n")
            else
                local err = buf:Save()
                if err ~= nil then
                    block("  ! could not save " .. buf:GetName() .. ": " .. tostring(err) .. "\n")
                else
                    saved[#saved + 1] = buf:GetName()
                end
            end
        end
    end
    if #saved > 0 then block("  saved " .. table.concat(saved, ", ") .. "\n") end
end

------------------------------------------------------------------------------
-- JSON-RPC plumbing
------------------------------------------------------------------------------

local function send(msg)
    if job == nil then return end -- e.g. a permission answered after the agent died
    msg.jsonrpc = "2.0"
    shell.JobSend(job, json.encode(msg) .. "\n")
end

local function request(method, params, cb)
    local id = next_id
    next_id = next_id + 1
    pending[id] = cb
    send({ id = id, method = method, params = params })
end

local function respond(id, result)
    send({ id = id, result = result })
end

local function stop()
    agent_gen = agent_gen + 1 -- ignore what the stopped agent still sends
    if job ~= nil then shell.JobStop(job) end
    job = nil
    session_id = nil
    busy = false
    pending = {}
    permission_queue = {}
    announced = nil
end

------------------------------------------------------------------------------
-- Permissions
------------------------------------------------------------------------------

local function pick_option(options, kinds)
    for _, want in ipairs(kinds) do
        for _, o in ipairs(options) do
            if o.kind == want then return o.optionId end
        end
    end
    return nil
end

local show_next_permission

local function title_of(req)
    return (req.params.toolCall and req.params.toolCall.title) or "a tool"
end

local function answer_permission(req, allowed)
    local kinds = allowed and { "allow_once", "allow_always" } or { "reject_once", "reject_always" }
    local option = pick_option(req.params.options or {}, kinds)
    if option then
        respond(req.id, { outcome = { outcome = "selected", optionId = option } })
    else
        respond(req.id, { outcome = { outcome = "cancelled" } })
    end
    block(allowed and "  ✓ allowed\n" or "  ✗ denied\n")
    if not allowed and req.params.toolCall then
        denied[req.params.toolCall.toolCallId or ""] = true
    end
    table.remove(permission_queue, 1)
    announced = nil
    show_next_permission()
end

-- Keep the waiting question in the info bar, where other messages can
-- replace it, until it's answered.
local function remind(req)
    if announced ~= req then return end
    if not micro.InfoBar().HasPrompt then
        micro.InfoBar():Message("Claude wants to run: " .. title_of(req) .. "  Alt-c to answer")
    end
    micro.After(3 * time.Second, function() remind(req) end)
end

-- A y/n question that opened by itself would take the keys typed in a file
-- or the draft, and a y in a word would allow. So it's only announced, and
-- waits for Alt-c.
function show_next_permission()
    if announced ~= nil or #permission_queue == 0 then return end
    announced = permission_queue[1]
    block("? permission: " .. title_of(announced) .. " (Alt-c to answer)\n")
    remind(announced)
end

-- A cancelled turn answers the questions still waiting, as ACP asks.
local function cancel_permissions()
    for _, req in ipairs(permission_queue) do
        respond(req.id, { outcome = { outcome = "cancelled" } })
    end
    if #permission_queue > 0 then block("  ✗ cancelled\n") end
    permission_queue = {}
    announced = nil
end

-- Alt-c with a permission waiting asks it: y allows, n denies, Escape
-- leaves it waiting. False if none waits.
local function ask_permission()
    local req = announced
    if req == nil then return false end
    micro.InfoBar():YNPrompt("Claude wants to run: " .. title_of(req) .. "  Allow? (y/n, Escape: later)", function(yes, canceled)
        if announced ~= req then return end -- the agent stopped meanwhile
        if canceled then
            micro.InfoBar():Message("Claude wants to run: " .. title_of(req) .. "  Alt-c to answer")
        else
            answer_permission(req, yes)
        end
    end)
    return true
end

------------------------------------------------------------------------------
-- Messages from the agent
------------------------------------------------------------------------------

local function text_of(content)
    if type(content) == "table" and content.type == "text" then return content.text end
    return ""
end

local function on_update(u)
    local kind = u.sessionUpdate
    if kind == "agent_message_chunk" then
        if not in_message then
            block(replied and "\n" or "\n## Claude\n\n")
            in_message = true
            replied = true
        end
        append(text_of(u.content))
    elseif kind == "tool_call" then
        in_message = false
        block("  ▸ " .. (u.title or u.kind or "tool") .. "\n")
    elseif kind == "tool_call_update" then
        -- a denied tool reports failure too; "✗ denied" already said so
        if u.status == "failed" and not denied[u.toolCallId or ""] then
            block("  ✗ " .. (u.title or "tool call") .. " failed\n")
        end
    elseif kind == "plan" then
        in_message = false
        block("  plan:\n")
        for _, e in ipairs(u.entries or {}) do
            local mark = e.status == "completed" and "x" or " "
            append("    [" .. mark .. "] " .. (e.content or "") .. "\n")
        end
    end
    -- agent_thought_chunk, available_commands_update, etc. are ignored for now

    if (kind == "tool_call" or kind == "tool_call_update")
        and (u.status == "completed" or u.status == "failed") then
        sync_open_files()
    end
end

local function on_message(msg)
    if msg.method ~= nil and msg.id ~= nil then
        -- a request from the agent to us
        if msg.method == "session/request_permission" then
            permission_queue[#permission_queue + 1] = msg
            show_next_permission()
        else
            send({ id = msg.id, error = { code = -32601, message = "method not supported: " .. msg.method } })
        end
    elseif msg.method == "session/update" then
        on_update(msg.params.update)
    elseif msg.id ~= nil and pending[msg.id] ~= nil then
        local cb = pending[msg.id]
        pending[msg.id] = nil
        cb(msg.result, msg.error)
    end
end

local function on_stdout(out)
    stdout_buf = stdout_buf .. out
    while true do
        local nl = stdout_buf:find("\n", 1, true)
        if not nl then break end
        local line = stdout_buf:sub(1, nl - 1)
        stdout_buf = stdout_buf:sub(nl + 1)
        if line ~= "" then
            local ok, msg = pcall(json.decode, line)
            if ok and type(msg) == "table" then
                on_message(msg)
            else
                micro.Log("claude: bad line from agent: " .. line)
            end
        end
    end
end

local function on_stderr(out)
    for line in out:gmatch("[^\n]+") do
        stderr_tail[#stderr_tail + 1] = line
        if #stderr_tail > 5 then table.remove(stderr_tail, 1) end
    end
end

-- Tell hill-ops's event log what went wrong with Claude, in the plugin's words:
-- the agent's own message can name a file. A missing login is worth saying.
local function report(what, err)
    if err ~= nil and (err.message or ""):find("Authentication") then
        what = what .. ": Claude needs a login"
    end
    hill_send("error", { what = what })
end

local function on_exit()
    if job == nil then return end -- stopped on purpose
    report(session_id and "Claude's agent exited" or "Claude's agent exited before its session was ready")
    job = nil
    session_id = nil
    busy = false
    pending = {}
    permission_queue = {}
    announced = nil
    block("\n-- agent exited --\n" .. table.concat(stderr_tail, "\n") .. "\n")
end

------------------------------------------------------------------------------
-- Turns
------------------------------------------------------------------------------

local function describe_error(err)
    local m = err.message or "unknown error"
    if m:find("Authentication") then
        m = m .. " (run `claude` in a terminal and use /login)"
    end
    return m
end

local function send_prompt(blocks, shown)
    busy = true
    in_message = false
    replied = false
    block("\n## You\n\n" .. shown .. "\n")
    save_open_files()
    request("session/prompt", { sessionId = session_id, prompt = json.array(blocks) }, function(result, err)
        busy = false
        in_message = false
        sync_open_files()
        if err ~= nil then
            block("\n-- error: " .. describe_error(err) .. " --\n")
            report("a turn with Claude failed", err)
        elseif result.stopReason ~= "end_turn" then
            block("\n-- stopped: " .. tostring(result.stopReason) .. " --\n")
        end
        micro.InfoBar():Message("Claude: done")
    end)
end

local function start()
    local cmd = config.GetGlobalOption("claude.command")
    local cwd = goos.Getwd()
    stdout_buf = ""
    stderr_tail = {}
    -- micro delivers a job's output and exit later, on its main loop, so after
    -- claude-restart the old agent's exit can arrive once the new one runs.
    -- Each agent's callbacks only act while it's the current one.
    agent_gen = agent_gen + 1
    local gen = agent_gen
    -- Without $HILL_SOCKET, nothing the agent runs, such as palace or its
    -- tests, joins the hill-ops micro runs in: its hello would take hill-ops's panes.
    job = shell.JobSpawn("env", { "-u", "HILL_SOCKET", cmd },
        function(out) if gen == agent_gen then on_stdout(out) end end,
        function(out) if gen == agent_gen then on_stderr(out) end end,
        function() if gen == agent_gen then on_exit() end end)
    block("-- starting " .. cmd .. " in " .. cwd .. " --\n")
    request("initialize", {
        protocolVersion = 1,
        clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false },
    }, function(_, err)
        if err ~= nil then
            block("-- initialize failed: " .. describe_error(err) .. " --\n")
            report("Claude's agent failed to start", err)
            return
        end
        request("session/new", { cwd = cwd, mcpServers = json.array({}) }, function(result, err2)
            if err2 ~= nil then
                block("-- session failed: " .. describe_error(err2) .. " --\n")
                report("Claude's session failed to start", err2)
                return
            end
            session_id = result.sessionId
            block("-- session ready --\n")
            if queued ~= nil then
                local q = queued
                queued = nil
                send_prompt(q.blocks, q.shown)
            end
        end)
    end)
end

-- Build the prompt, telling Claude which file is open and attaching the
-- current selection (if any).
local function build_prompt(bp, text)
    local blocks = { { type = "text", text = text } }
    local shown = text
    if bp == nil then return blocks, shown end -- that pane has closed
    local c = bp.Cursor
    if bp.Buf ~= chat_buf and bp.Buf.AbsPath ~= "" then
        local ctx = "The file open in the editor is " .. bp.Buf.AbsPath
            .. " (cursor on line " .. (c.Y + 1) .. ")."
        blocks[#blocks + 1] = { type = "text", text = ctx }
    end
    if bp.Buf ~= chat_buf and c:HasSelection() then
        local sel = util.String(c:GetSelection())
        local a, b = c.CurSelection[1], c.CurSelection[2]
        local first = math.min(a.Y, b.Y) + 1
        local last = math.max(a.Y, b.Y) + 1
        local lines = ":" .. first .. "-" .. last
        local path = bp.Buf.AbsPath ~= "" and bp.Buf.AbsPath or bp.Buf:GetName()
        blocks[#blocks + 1] = { type = "text", text = "Selected from " .. path .. lines .. ":\n```\n" .. sel .. "\n```" }
        shown = shown .. "\n\n(with selection " .. bp.Buf:GetName() .. lines .. ")"
    end
    return blocks, shown
end

-- Send text, about the file and selection in bp (nil: none). Returns false
-- if it wasn't sent, nor queued for the session.
local function ask_text(bp, text)
    if text == "" then return false end
    ensure_pane(bp or micro.CurPane())
    if busy then
        micro.InfoBar():Error("Claude is still working (claude-cancel to stop)")
        return false
    end
    local blocks, shown = build_prompt(bp, text)
    if session_id == nil then
        queued = { blocks = blocks, shown = shown }
        if job == nil then start() end
        return true
    end
    send_prompt(blocks, shown)
    return true
end

------------------------------------------------------------------------------
-- The draft
------------------------------------------------------------------------------

-- micro's info bar holds one line, so a prompt is written in a split under
-- the chat instead, where Enter starts a new line and Alt-c sends it.

local function still_open(bp)
    if bp == nil then return nil end
    for _, p in ipairs(open_bufpanes()) do
        if p:ID() == bp:ID() then return p end
    end
    return nil
end

local function focus(bp)
    micro.CurTab():SetActive(micro.CurTab():GetPane(bp:ID()))
end

local function open_draft(bp)
    draft_for = bp
    if still_open(draft_pane) ~= nil then
        focus(draft_pane)
        return
    end
    ensure_pane(bp)
    local buf = buffer.NewBuffer("", "claude-prompt")
    buf.Type.Scratch = true
    buf:SetOptionNative("filetype", "markdown")
    buf:SetOptionNative("softwrap", true)
    buf:SetOptionNative("wordwrap", true)
    local height = chat_pane:GetView().Height
    draft_pane = chat_pane:HSplitIndex(buf, true) -- and focus moves there
    -- micro sizes a split by the one above it: the chat, here.
    if height > 16 then chat_pane:ResizePane(height - 8) end
    micro.InfoBar():Message("Write to Claude; Alt-c sends, Ctrl-q drops it")
end

local function send_draft()
    local text = util.String(draft_pane.Buf:Bytes()):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        micro.InfoBar():Message("Nothing to send")
        return
    end
    local from = still_open(draft_for)
    if not ask_text(from, text) then return end -- kept, to send once Claude is done
    draft_pane:Quit()
    if from ~= nil then focus(from) end
end

------------------------------------------------------------------------------
-- Commands and bindings
------------------------------------------------------------------------------

-- Alt-c: answer Claude's permission question if one waits, else open the
-- draft, or send it from inside.
function ask(bp)
    if ask_permission() then return end
    if draft_pane ~= nil and bp:ID() == draft_pane:ID() then
        send_draft()
    else
        open_draft(bp)
    end
end

local function cmd_claude(bp, args)
    local words = {}
    for i = 1, #args do words[#words + 1] = args[i] end
    if #words == 0 then ask(bp) else ask_text(bp, table.concat(words, " ")) end
end

local function cmd_cancel(bp)
    if session_id ~= nil and busy then
        send({ method = "session/cancel", params = { sessionId = session_id } })
        cancel_permissions()
        micro.InfoBar():Message("Claude: cancelling")
    end
end

local function cmd_restart(bp)
    stop()
    ensure_pane(bp)
    block("\n-- restarted --\n")
    start()
end

------------------------------------------------------------------------------
-- Settings, and hill-ops
------------------------------------------------------------------------------

-- Inside hill-ops (a strip for settings under the app), micro talks to the strip
-- through `hill-ops connect`: it says hello with its settings profile and keys,
-- Alt-, asks for the settings there, Claude's failures go to hill-ops's event
-- log, and hill-ops says when a setting changed or runs a hint that was clicked.
local hill_job = nil     -- `hill-ops connect`, while micro runs inside hill-ops
local hill_buf = ""      -- partial line from it
local hill_gen = 0       -- tells a stopped bridge's late output from the current one's

-- Declared with the state above, so the agent's code can report errors.
function hill_send(method, params)
    if hill_job == nil then return end
    shell.JobSend(hill_job, json.encode({ jsonrpc = "2.0", method = method, params = params }) .. "\n")
end

-- Apply what changed in settings.json, which micro only reads at start.
local function reapply()
    local path = config.ConfigDir .. "/settings.json"
    local f = io.open(path, "r")
    if f == nil then return end
    local ok, saved = pcall(json.decode, f:read("*a"))
    f:close()
    if not ok or type(saved) ~= "table" then return end
    for name, value in pairs(saved) do
        if type(value) ~= "table" and value ~= json.null
            and config.GetGlobalOption(name) ~= value then
            config.SetGlobalOptionNative(name, value)
        end
    end
    -- Then per-filetype options ("ft:markdown": {...}) for the files open
    -- now; files opened later get them from micro itself.
    for name, options in pairs(saved) do
        if type(options) == "table" and name:sub(1, 3) == "ft:" then
            for _, p in ipairs(open_bufpanes()) do
                if p.Buf:FileType() == name:sub(4) then
                    for option, value in pairs(options) do
                        if value ~= json.null then
                            p.Buf:SetOptionNative(option, value)
                        end
                    end
                end
            end
        end
    end
end

-- Alt-,: the settings, open on the part of micro that had focus: "claude"
-- in the chat, "editor" anywhere else. Inside hill-ops they open in its strip;
-- elsewhere Alt-, runs the settings program in claude.settingscommand (e.g.
-- `hill-ops settings {section}`), then applies what it changed in settings.json.
function settings(bp)
    local section = (chat_buf ~= nil and bp.Buf == chat_buf) and "claude" or "editor"
    if hill_job ~= nil then
        hill_send("settings.open", { group = section })
        return
    end
    local cmd = config.GetGlobalOption("claude.settingscommand")
    if cmd == nil or cmd == "" then
        micro.InfoBar():Message("Set claude.settingscommand to a settings program, e.g. hill-ops settings {section}")
        return
    end
    shell.RunInteractiveShell((cmd:gsub("{section}", section)), false, false)
    reapply()
end

-- What a click on one of micro's hints in hill-ops's strip runs.
local hill_actions = {
    settings = function(bp) settings(bp) end,
    claude = function(bp) ask(bp) end,
    help = function(bp) bp:ToggleHelp() end,
}

-- micro's commands (micro 2.0.15), for the command line in hill-ops's strip.
local hill_commands = {
    { "set", "OPTION VALUE", "set an option, in settings.json too" },
    { "setlocal", "OPTION VALUE", "set an option for this file only" },
    { "toggle", "OPTION", "switch an option between its two values" },
    { "reset", "OPTION", "set an option back to its default" },
    { "show", "OPTION", "show an option's value" },
    { "showkey", "KEY", "show what a key does" },
    { "bind", "KEY ACTION", "bind a key, in bindings.json" },
    { "open", "FILE", "open a file in this pane" },
    { "save", "[FILE]", "save, or save as FILE" },
    { "reopen", "", "load the file again from disk" },
    { "quit", "", "quit micro" },
    { "goto", "LINE[:COL]", "go to a line" },
    { "jump", "LINES", "move that many lines down, or up if negative" },
    { "replace", "SEARCH VALUE [-a]", "replace SEARCH with VALUE, asking each time; -a: all at once" },
    { "replaceall", "SEARCH VALUE", "replace every SEARCH with VALUE" },
    { "vsplit", "[FILE]", "a split beside this one" },
    { "hsplit", "[FILE]", "a split below this one" },
    { "tab", "[FILE]", "a new tab" },
    { "tabswitch", "TAB", "switch to a tab, by number or name" },
    { "tabmove", "[-+]N", "move this tab" },
    { "cd", "DIR", "change the working directory" },
    { "pwd", "", "show the working directory" },
    { "run", "COMMAND", "run a shell command in the background" },
    { "textfilter", "COMMAND", "pipe the selection through a shell command" },
    { "term", "[COMMAND]", "a terminal" },
    { "retab", "", "leading tabs to spaces, or back, as tabstospaces says" },
    { "comment", "", "comment or uncomment the line or selection" },
    { "reload", "", "reload settings, keys, syntax files and colour schemes" },
    { "plugin", "ACTION [NAME]", "list, install, remove, update or search plugins" },
    { "help", "[TOPIC]", "micro's help pages" },
    { "log", "", "micro's log" },
    { "claude", "[TEXT]", "talk to Claude" },
    { "claude-cancel", "", "stop Claude's turn" },
    { "claude-restart", "", "a fresh Claude agent and session" },
}

-- micro's main keys (micro 2.0.15, with this plugin's), for hill-ops's help.
local hill_help = {
    { "Files", {
        { "Ctrl-s", "save" },
        { "Ctrl-o", "open a file" },
        { "Ctrl-q", "close the file; micro quits with the last one" },
        { "Ctrl-t", "a new tab" },
        { "Ctrl-w", "the next split" },
    } },
    { "Editing", {
        { "Ctrl-z Ctrl-y", "undo, redo" },
        { "Ctrl-c Ctrl-x Ctrl-v", "copy, cut, paste" },
        { "Ctrl-k", "cut the line" },
        { "Ctrl-d", "duplicate the line" },
        { "Ctrl-a", "select all" },
        { "Shift-arrows", "select" },
        { "Alt-Up Alt-Down", "move the line or the selection up or down" },
        { "Tab Shift-Tab", "indent or unindent the selection" },
    } },
    { "Moving", {
        { "Ctrl-f", "find" },
        { "Ctrl-n Ctrl-p", "the next or previous match" },
        { "Ctrl-l", "go to a line" },
        { "Home End", "the start or end of the line" },
        { "Ctrl-Up Ctrl-Down", "the start or end of the file" },
        { "PageUp PageDown", "a page up or down" },
    } },
    { "micro", {
        { "Ctrl-e", "the command line, in hill-ops's strip" },
        { "Alt-,", "the settings, in hill-ops's strip" },
        { "Alt-c", "write to Claude about the file and the selection; Alt-c again sends; answer Claude's question" },
        { "Ctrl-g", "micro's own help pages" },
        { "Alt-g", "micro's key menu" },
        { "Ctrl-b", "run a shell command" },
        { "Ctrl-r", "line numbers on or off" },
        { "Ctrl-u Ctrl-j", "record a macro, play it" },
    } },
}

local function on_hill_message(msg)
    if msg.method == "settings.changed" then
        reapply()
    elseif msg.method == "run" and type(msg.params) == "table" then
        local action = hill_actions[msg.params.action]
        if action ~= nil then action(micro.CurPane()) end
    elseif msg.method == "command" and type(msg.params) == "table" and type(msg.params.line) == "string" then
        micro.CurPane():HandleCommand(msg.params.line)
    end
end

-- Ctrl-e: inside hill-ops, the command line is in its strip.
function preCommandMode(bp)
    if hill_job == nil then return true end
    hill_send("command.open", {})
    return false
end

local function join_hill()
    if goos.Getenv("HILL_SOCKET") == "" then return end
    hill_gen = hill_gen + 1
    local gen = hill_gen
    hill_buf = ""
    hill_job = shell.JobSpawn("hill-ops", { "connect" }, function(out)
        if gen ~= hill_gen then return end
        hill_buf = hill_buf .. out
        while true do
            local nl = hill_buf:find("\n", 1, true)
            if not nl then break end
            local line = hill_buf:sub(1, nl - 1)
            hill_buf = hill_buf:sub(nl + 1)
            local ok, msg = pcall(json.decode, line)
            if ok and type(msg) == "table" then on_hill_message(msg) end
        end
    end, function() end, function()
        if gen == hill_gen then hill_job = nil end
    end)
    hill_send("hello", {
        app = "micro",
        profile = config.ConfigDir .. "/plug/claude/hill.toml",
        keys = {
            { "Alt-,", "settings", "settings" },
            { "Alt-c", "Claude", "claude" },
            { "Ctrl-e", "command", "hill.command" },
            { "Ctrl-g", "help", "help" },
            { "", "keys & commands", "hill.help" },
            { "Ctrl-q", "quit" },
        },
        commands = hill_commands,
        help = hill_help,
    })
end

local function leave_hill()
    hill_gen = hill_gen + 1
    if hill_job ~= nil then shell.JobStop(hill_job) end
    hill_job = nil
end

function onQuit(bp)
    if chat_pane ~= nil and bp:ID() == chat_pane:ID() then
        chat_pane = nil
    elseif draft_pane ~= nil and bp:ID() == draft_pane:ID() then
        draft_pane = nil
    elseif chat_pane ~= nil and #open_bufpanes() == (draft_pane ~= nil and 2 or 1) then
        -- The last file has closed and only the chat (and the draft) is
        -- left: they close too, so Ctrl-q quits micro as it would without.
        local chat, draft = chat_pane, draft_pane
        micro.After(0, function()
            if draft ~= nil and draft_pane == draft then draft:Quit() end
            if chat_pane == chat then chat:Quit() end
        end)
    end
    return true
end

-- Inside hill-ops, micro can run over the panes an app runs beside it, such as
-- palace's preview and its Claude pane. hill-ops says how wide the Claude pane
-- was (HILL_CLAUDE_COLUMNS), and the chat opens there at the start, that
-- wide, so Claude stays on the right while you edit.
local chat_columns = tonumber(goos.Getenv("HILL_CLAUDE_COLUMNS"))

function onBufPaneOpen(bp)
    if chat_columns == nil or chat_pane ~= nil or bp.Buf.Type.Scratch then return end
    local columns = chat_columns
    chat_columns = nil -- once; the chat's own pane opens below too
    ensure_pane(bp)
    if chat_pane ~= nil then
        -- micro sizes a split by the one on its left: the file's, here.
        local total = bp:GetView().Width + chat_pane:GetView().Width
        if total > columns + 10 then bp:ResizePane(total - columns) end
    end
    append("Alt-c: ask Claude about this file.\n")
end

function deinit()
    stop()
    leave_hill()
end

function init()
    config.RegisterGlobalOption("claude", "command", "claude-agent-acp")
    config.RegisterGlobalOption("claude", "autoreload", true)
    config.RegisterGlobalOption("claude", "autosave", true)
    config.RegisterGlobalOption("claude", "settingscommand", "")
    config.MakeCommand("claude", cmd_claude, config.NoComplete)
    config.MakeCommand("claude-cancel", cmd_cancel, config.NoComplete)
    config.MakeCommand("claude-restart", cmd_restart, config.NoComplete)
    config.TryBindKey("Alt-c", "lua:claude.ask", false)
    config.TryBindKey("Alt-,", "lua:claude.settings", false)
    config.AddRuntimeFile("claude", config.RTHelp, "help/claude.md")
    join_hill()
end
