--------------------------------------------------------------------
-- imapfilter Screener – Quelle: SCREENED (iCloud-Serverregel)
-- Fluss:
--   0) Warmup: alle MIDs in Screened indizieren (Approve funktioniert sofort)
--   1) Sortieren AUS Screened:
--        Blocklist  -> Blackhole
--        Whitelist  -> INBOX
--        Receipts   -> Receipts (Trainingsliste + Subject-Heuristik)
--        Newsletters-> Newsletters (Trainingsliste + List-Header)
--        Rest bleibt in Screened
--   2) Training: manuell verschobene Mails trainieren Listen (additiv)
--   3) Approve: Mail von Screened -> INBOX (vom Nutzer) => Absender whitelisten
-- Technisch:
--   - Nur contain_* (keine Regex) für IMAP-Search
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

-- Listen laden
local whitelist      = file_set(wl_path)
local blocklist      = file_set(bl_path)
local screened_ids   = file_set(sid_path)
local receiptlist    = file_set(rcl_path)
local newsletterlist = file_set(nsl_path)

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
local BLACKHOLE   = ensure_box('Blackhole')
local RECEIPTS    = ensure_box('Receipts')
local NEWSLETTERS = ensure_box('Newsletters')

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
-- 1) AUS SCREENED SORTIEREN
--    Blocklist -> Blackhole, Whitelist -> INBOX,
--    dann Receipts, dann Newsletters; Rest bleibt in Screened
--------------------------------------------------------------------
do
  local src = SCREENED:select_all()

  -- Blocklist
  do
    local to_bh = Set {}
    for sender,_ in pairs(blocklist) do
      if is_wildcard(sender) then
        local dom = wildcard_domain(sender)
        to_bh = to_bh + src:contain_from('@'..dom) + src:contain_from('.'..dom)
      else
        to_bh = to_bh + src:contain_from(sender)
      end
    end
    to_bh:move_messages(BLACKHOLE)
    src = SCREENED:select_all()  -- Quelle aktualisieren
  end

  -- Whitelist
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

  -- Receipts (trainierte Absender + Subject-Heuristik)
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

  -- Newsletters (trainierte Absender + List-Header)
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
  end
end

--------------------------------------------------------------------
-- 2) TRAINING: manuell verschobene Mails -> Listen (additiv)
--------------------------------------------------------------------
do
  for _, msg in ipairs(BLACKHOLE:select_all()) do
    local mbox, uid = table.unpack(msg)
    local from = parse_from(header_field(safe_header(mbox, uid), "From"))
    if from and not blocklist[from] then file_add_line(bl_path, from); blocklist[from]=true end
  end
  for _, msg in ipairs(RECEIPTS:select_all()) do
    local mbox, uid = table.unpack(msg)
    local from = parse_from(header_field(safe_header(mbox, uid), "From"))
    if from and not receiptlist[from] then file_add_line(rcl_path, from); receiptlist[from]=true end
  end
  for _, msg in ipairs(NEWSLETTERS:select_all()) do
    local mbox, uid = table.unpack(msg)
    local from = parse_from(header_field(safe_header(mbox, uid), "From"))
    if from and not newsletterlist[from] then file_add_line(nsl_path, from); newsletterlist[from]=true end
  end
end

--------------------------------------------------------------------
-- 3) APPROVE: Screened -> INBOX (vom Nutzer) => Absender whitelisten
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

-- Ende