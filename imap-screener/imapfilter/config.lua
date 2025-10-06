--------------------------------------------------------------------
-- imapfilter Screener – iCloud-Serverregel + INBOX Catch-up
-- Fluss:
--   0) Warmup: alle MIDs in Screened indizieren (Approve funktioniert sofort)
--   0a) CATCH-UP: Alles, was doch in INBOX landet (z. B. Hide-My-Mail),
--       wird nach Screened verschoben (Blocklist raus, Whitelist bleibt).
--   1) AUS SCREENED SORTIEREN:
--        Blocklist  -> Blackhole
--        Whitelist  -> INBOX
--        Receipts   -> Receipts (Training + Heuristik)
--        Newsletters-> Newsletters (Training + List-Header)
--        Rest bleibt in Screened
--   2) TRAINING: manuell verschobene Mails -> Listen (additiv)
--   3) APPROVE: Screened -> INBOX (vom Nutzer) => Whitelist
-- Technisch:
--   - Nur contain_* (keine Regex)
--   - Set-basierte Moves
--   - Ordner-Autocreate/-Subscribe
--   - Header-Handling nil-sicher, Message-ID robust
--------------------------------------------------------------------

-- Optionen
options.timeout   = 120
options.create    = true
options.subscribe = true

-- Account (iCloud IMAP)
account = IMAP {
  server   = 'imap.mail.me.com',
  port     = 993,
  ssl      = 'tls1',
  username = 'some.email@icloud.com',       -- z.B. alex.damhuis@icloud.com
  --password = [[DEIN_APPSPEZIFISCHES_PASSWORT]],  -- Alternative
  password = os.getenv('IMAP_PW'),        -- Empfohlen über docker-compose
}

-- Pfade (State/Listen)
local wl_path  = '/state/whitelist.txt'
local bl_path  = '/state/blocklist.txt'
local sid_path = '/state/screened_ids.txt'
local rcl_path = '/state/receiptlist.txt'
local nsl_path = '/state/newsletterlist.txt'

-- Datei-Helpers
local function file_set(path)
  local t = {}
  local f = io.open(path, 'r')
  if f then
    for line in f:lines() do
      line = line:match("^%s*(.-)%s*$")
      if line and #line > 0 and not line:match("^#") then
        t[line:lower()] = true
      end
    end
    f:close()
  end
  return t
end

-- Listen laden
local whitelist      = file_set(wl_path)
local blocklist      = file_set(bl_path)
local screened_ids   = file_set(sid_path)
local receiptlist    = file_set(rcl_path)
local newsletterlist = file_set(nsl_path)


local function file_add_line(path, line)
  local f = io.open(path, 'a'); f:write(line.."\n"); f:close()
end

local function file_del_line(path, needle)
  local lines, f = {}, io.open(path,'r')
  if f then for l in f:lines() do if l:lower() ~= needle:lower() then table.insert(lines,l) end end; f:close() end
  f = io.open(path,'w'); for _,l in ipairs(lines) do f:write(l.."\n") end; f:close()
end

-- Header/Mail-Helpers
local function header_field(h, name)
  if not h or h == "" then return nil end
  if h:sub(1,1) ~= "\n" then h = "\n"..h end
  local v = h:match("\n"..name..":%s*(.-)\r?\n[%u-]+:") or h:match("\n"..name..":%s*(.-)\r?\n\r?\n")
  return v and v:gsub("\r",""):gsub("\n%s+"," ") or nil
end

local function safe_header(mbox, uid)
  local ok, hdr = pcall(function() return mbox[uid]:fetch_header() end)
  if not ok or not hdr then return "" end
  return hdr
end

local function parse_from(addr)
  if not addr then return nil end
  local m = addr:match("<([^>]+)>") or addr
  return m:lower():gsub("^%s+",""):gsub("%s+$","")
end

-- Extrahiere eine nutzbare Absenderadresse (From -> Sender -> Return-Path)
local function extract_sender(hdr)
  local function pick(addr)
    if not addr or addr == "" then return nil end
    -- falls mehrere Adressen: nimm die erste
    addr = addr:match("<([^>]+)>") or addr
    addr = addr:gsub("^%s+",""):gsub("%s+$","")
    -- sehr defensive Normalisierung
    addr = addr:lower()
    -- ganz grob validieren
    if addr:find("@") then return addr end
    return nil
  end

  local from = header_field(hdr, "From")
  local sender = header_field(hdr, "Sender")
  local rpath = header_field(hdr, "Return%-Path")
  return pick(from) or pick(sender) or pick(rpath)
end

-- Message-ID robust ziehen (alle Schreibweisen) + <...> entfernen
local function get_message_id(hdr)
  if not hdr or hdr == "" then return nil end
  local candidates = { "Message%-ID","Message%-Id","Message%-id","Message%-iD" }
  for _,name in ipairs(candidates) do
    local v = header_field(hdr, name)
    if v and #v > 0 then
      v = v:gsub("[<>]", ""):gsub("^%s+",""):gsub("%s+$","")
      if #v > 0 then return v end
    end
  end
  return nil
end

-- -- Remove MID from screened_ids.{mem+file}, if present
local function clear_sid_for_msg(mbox, uid)
  local mid = get_message_id(safe_header(mbox, uid))
  if mid and screened_ids[mid:lower()] then
    file_del_line(sid_path, mid:lower())
    screened_ids[mid:lower()] = nil
  end
end

-- Wildcards *@domain.tld
local function is_wildcard(entry) return entry:sub(1,2) == '*@' end
local function wildcard_domain(entry) return entry:sub(3):lower() end

-- Heuristik (Receipts)
local RECEIPT_SUBJ = {
  'rechnung','beleg','quittung','steuerbeleg','zahlungsbeleg',
  'bestellbestätigung','auftrag','zahlungseingang','rechnungsnr','rechnung nr',
  'invoice','receipt','order confirmation','payment received','tax invoice'
}

-- Ordner sicherstellen
local function ensure_box(name)
  pcall(function() account:create_mailbox(name) end)  -- "ALREADYEXISTS" ist ok
  pcall(function() account:subscribe(name) end)
  return account[name]
end

local INBOX       = account['INBOX']
local SCREENED    = ensure_box('Screened')
local RECEIPTS    = ensure_box('Receipts')
local NEWSLETTERS = ensure_box('Newsletters')

-- Standard system folders on iCloud
local JUNK          = ensure_box('Junk')
local DELETED       = ensure_box('Deleted Messages')
local ARCHIVE       = ensure_box('Archive')

--------------------------------------------------------------------
-- 0) WARMUP: alle MIDs in Screened indizieren (für Approve)
--------------------------------------------------------------------
do
  for _, msg in ipairs(SCREENED:select_all()) do
    local mbox, uid = table.unpack(msg)
    local mid = get_message_id(safe_header(mbox, uid))
    if mid and not screened_ids[mid:lower()] then
      file_add_line(sid_path, mid:lower()); screened_ids[mid:lower()] = true
      -- io.stdout:write("[warmup] MID="..mid.."\n")
    end
  end
end

--------------------------------------------------------------------
-- 0a) INBOX CATCH-UP (Variante C):
--     Alles, was dennoch in INBOX landet (z. B. Hide-My-Mail),
--     wird nachträglich nach Screened geräumt:
--     - Blocklist -> Blackhole
--     - Whitelist bleibt in INBOX
--     - Rest -> Screened (+MID loggen)
--------------------------------------------------------------------
do
  local unseen = INBOX:is_unseen()

  -- Blocklist -> Blackhole
  local to_bh = Set {}
  for sender,_ in pairs(blocklist) do
    if is_wildcard(sender) then
      local dom = wildcard_domain(sender)
      to_bh = to_bh + unseen:contain_from('@'..dom) + unseen:contain_from('.'..dom)
    else
      to_bh = to_bh + unseen:contain_from(sender)
    end
  end

  -- Rest ohne Whitelist
  local rest = INBOX:is_unseen()
  local wlset = Set {}
  for sender,_ in pairs(whitelist) do
    if is_wildcard(sender) then
      local dom = wildcard_domain(sender)
      wlset = wlset + rest:contain_from('@'..dom) + rest:contain_from('.'..dom)
    else
      wlset = wlset + rest:contain_from(sender)
    end
  end
  rest = rest - wlset

  -- MIDs loggen, dann Rest -> Screened
  for _, msg in ipairs(rest:select_all()) do
    local mbox, uid = table.unpack(msg)
    local mid = get_message_id(safe_header(mbox, uid))
    if mid and not screened_ids[mid:lower()] then
      file_add_line(sid_path, mid:lower()); screened_ids[mid:lower()] = true
    end
  end
  rest:move_messages(SCREENED)
end

--------------------------------------------------------------------
-- 1) AUS SCREENED SORTIEREN
--------------------------------------------------------------------
do
  local src = SCREENED:select_all()

--- Junk -> blocklist (Resync)
do
  for _, msg in ipairs(JUNK:select_all()) do
    local mbox, uid = table.unpack(msg)
    local hdr  = safe_header(mbox, uid)
    local addr = extract_sender(hdr)
    if addr and not blocklist[addr] then
      file_add_line(bl_path, addr); blocklist[addr] = true
      -- optional: auch Domain sperren
      if ADD_DOMAIN_ON_JUNK then
        local dom = email_domain(addr)
        if dom and not blocklist["*@"..dom] then
          file_add_line(bl_path, "*@"..dom); blocklist["*@"..dom] = true
        end
      end
      io.stdout:write(string.format("[train] added to blocklist: %s\n", addr))
    end
    -- MID aus screened_ids.txt löschen, falls noch dort
    clear_sid_for_msg(mbox, uid)
  end
end

  -- Whitelist -> INBOX
  do
    local to_inbox = Set {}
    for sender,_ in pairs(whitelist) do
      if is_wildcard(sender) then
        local dom = wildcard_domain(sender)
        to_inbox = to_inbox + src:contain_from('@'..dom) + src:contain_from('.'..dom)
      else
        to_inbox = to_inbox + src:contain_from(sender)
      end
    end
    to_inbox:move_messages(INBOX)
    src = SCREENED:select_all()
  end

  -- Receipts (Training + Subject-Heuristik)
  do
    local rset = Set {}
    for sender,_ in pairs(receiptlist) do
      if is_wildcard(sender) then
        local dom = wildcard_domain(sender)
        rset = rset + src:contain_from('@'..dom) + src:contain_from('.'..dom)
      else
        rset = rset + src:contain_from(sender)
      end
    end
    for _,kw in ipairs(RECEIPT_SUBJ) do
      rset = rset + src:contain_field('Subject', kw)
    end
    rset:move_messages(RECEIPTS)
    src = SCREENED:select_all()
  end

  -- Newsletters (Training + List-Header)
  do
    local nlset = Set {}
    for sender,_ in pairs(newsletterlist) do
      if is_wildcard(sender) then
        local dom = wildcard_domain(sender)
        nlset = nlset + src:contain_from('@'..dom) + src:contain_from('.'..dom)
      else
        nlset = nlset + src:contain_from(sender)
      end
    end
    nlset = nlset + src:contain_field('List-Id', '@')
    nlset = nlset + src:contain_field('List-Unsubscribe', 'http')
    nlset = nlset + src:contain_field('List-Unsubscribe', 'mailto:')
    nlset:move_messages(NEWSLETTERS)
    -- Rest bleibt in Screened

    -- NEU: alles Ungelesene in "Newsletters" als gelesen markieren
  NEWSLETTERS:is_unseen():mark_seen()
  end
end

--------------------------------------------------------------------
-- 2) TRAINING: manuell verschobene Mails -> Listen (additiv)
--     Junk ersetzt Blackhole vollständig
--------------------------------------------------------------------
do
  -- Junk -> blocklist (resync)
  for _, msg in ipairs(JUNK:select_all()) do
    local mbox, uid = table.unpack(msg)
    local hdr  = safe_header(mbox, uid)
    local addr = extract_sender and extract_sender(hdr) or parse_from(header_field(hdr, "From"))
    if addr and not blocklist[addr] then
      file_add_line(bl_path, addr)
      blocklist[addr] = true
      io.stdout:write(string.format("[train] added to blocklist: %s\n", addr))
    end
    if clear_sid_for_msg then clear_sid_for_msg(mbox, uid) end
  end

  -- Receipts -> receiptlist
  for _, msg in ipairs(RECEIPTS:select_all()) do
    local mbox, uid = table.unpack(msg)
    local from = parse_from(header_field(safe_header(mbox, uid), "From"))
    if from and not receiptlist[from] then
      file_add_line(rcl_path, from)
      receiptlist[from] = true
    end
    clear_sid_for_msg(mbox, uid)
  end

  -- Newsletters -> newsletterlist
  for _, msg in ipairs(NEWSLETTERS:select_all()) do
    local mbox, uid = table.unpack(msg)
    local from = parse_from(header_field(safe_header(mbox, uid), "From"))
    if from and not newsletterlist[from] then
      file_add_line(nsl_path, from)
      newsletterlist[from] = true
    end
    clear_sid_for_msg(mbox, uid)
  end
end

--------------------------------------------------------------------
-- 3) APPROVE: Screened -> INBOX (vom Nutzer) => Whitelist
--------------------------------------------------------------------
do
  for _, msg in ipairs(INBOX:select_all()) do
    local mbox, uid = table.unpack(msg)
    local hdr  = safe_header(mbox, uid)
    local mid  = get_message_id(hdr)
    if mid and screened_ids[mid:lower()] then
      local from = parse_from(header_field(hdr, "From"))
      if from and not whitelist[from] then
        file_add_line(wl_path, from); whitelist[from] = true
      end
      file_del_line(sid_path, mid:lower()); screened_ids[mid:lower()] = nil
      -- io.stdout:write("[approve] MID="..mid.." FROM="..(from or "nil").."\n")
    end
  end
end


--------------------------------------------------------------------
-- Maintenance
-- 1) Junk: mark all unread as seen; older than 7 days -> Deleted Messages
-- 2) Receipts: older than 30 days -> Archive
--------------------------------------------------------------------
do
  -- Junk aufräumen
  JUNK:is_unseen():mark_seen()
  local junk_old = JUNK:is_older(7)
  junk_old:move_messages(DELETED)

  -- Receipts archivieren
  local rc_old = RECEIPTS:is_older(30)
  rc_old:move_messages(ARCHIVE)
end

-- Ende