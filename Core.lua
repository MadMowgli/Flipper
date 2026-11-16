-- Flipper: logs auction house buyouts and records price history from
-- Auctionator scans. Data lives in the account-wide SavedVariables FlipperDB:
--
--   FlipperDB.chars["Name-Realm"].trades = { {t, id, name, link, qty, total}, ... }
--   FlipperDB.markets["Realm-Faction"].snaps = { {t = time, p = {[itemID] = copper}}, ... }
--   FlipperDB.items[itemID] = { name, category }     (tracked items: name and category)
local ADDON, ns = ...
local CALLER = "Flipper"

local KEEP_DAYS_DEFAULT = 30   -- days of price history kept in game
local MERGE_WINDOW = 600       -- updates within 10 min overwrite the last snapshot

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Flipper|r: " .. tostring(msg))
end
ns.Print = Print

------------------------------------------------------------------------
-- Database
------------------------------------------------------------------------
local charKey, marketKey

local function InitDB()
  -- The add-on used to be called TradeLog. If its saved file was copied over
  -- (see README), take the old log across once.
  if not FlipperDB and type(TradeLogDB) == "table" then
    FlipperDB = TradeLogDB
  end
  TradeLogDB = nil
  FlipperDB = FlipperDB or {}
  local db = FlipperDB
  db.version = 1
  db.keepDays = db.keepDays or KEEP_DAYS_DEFAULT
  db.chars = db.chars or {}
  db.markets = db.markets or {}
  db.items = db.items or {}
  db.ui = db.ui or {}   -- window settings: font size, scale, size, position

  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or "Unknown"
  local faction = UnitFactionGroup("player") or "Neutral"
  charKey = (UnitName("player") or "Unknown") .. "-" .. realm
  marketKey = realm .. "-" .. faction

  db.chars[charKey] = db.chars[charKey] or {}
  db.chars[charKey].trades = db.chars[charKey].trades or {}
  db.markets[marketKey] = db.markets[marketKey] or {}
  db.markets[marketKey].snaps = db.markets[marketKey].snaps or {}

  -- Keep the category list in the saved file next to the price history.
  for id, info in pairs(ns.items) do
    db.items[id] = { name = info.name, category = info.category }
  end
end

function ns.Trades()
  return FlipperDB.chars[charKey].trades
end

local function Snaps()
  return FlipperDB.markets[marketKey].snaps
end

local function RememberItem(id, name)
  if not id then return end
  local entry = FlipperDB.items[id]
  if not entry then
    FlipperDB.items[id] = { name = name or ("Item " .. id), category = "Bought" }
  elseif name and entry.name:find("^Item %d+$") then
    entry.name = name
  end
end

------------------------------------------------------------------------
-- Auctionator prices
------------------------------------------------------------------------
local function API()
  return Auctionator and Auctionator.API and Auctionator.API.v1
end
ns.HasAuctionator = function() return API() ~= nil end

-- Latest scanned price (copper per piece) or nil.
function ns.GetPrice(itemID, link)
  local api = API()
  if not api then return nil end
  local ok, price
  if link and api.GetAuctionPriceByItemLink then
    ok, price = pcall(api.GetAuctionPriceByItemLink, CALLER, link)
    if ok and price then return price end
  end
  if itemID and api.GetAuctionPriceByItemID then
    ok, price = pcall(api.GetAuctionPriceByItemID, CALLER, itemID)
    if ok and price then return price end
  end
  return nil
end

------------------------------------------------------------------------
-- Price history snapshots
------------------------------------------------------------------------
local function Prune()
  local snaps = Snaps()
  local cutoff = time() - FlipperDB.keepDays * 86400
  while snaps[1] and snaps[1].t < cutoff do
    table.remove(snaps, 1)
  end
end

-- Record the current Auctionator price of every tracked item.
function ns.Snapshot()
  if not API() then return 0 end
  local prices, count = {}, 0
  for id in pairs(FlipperDB.items) do
    local price = ns.GetPrice(id)
    if price and price > 0 then
      prices[id] = price
      count = count + 1
    end
  end
  if count == 0 then return 0 end

  local snaps = Snaps()
  local now = time()
  local last = snaps[#snaps]
  if last and now - last.t < MERGE_WINDOW then
    -- Same visit to the auction house: keep one snapshot, refresh it.
    last.t, last.p = now, prices
  else
    snaps[#snaps + 1] = { t = now, p = prices }
  end
  Prune()
  return count
end

-- Returns { {t, price}, ... } oldest first for one item.
function ns.History(itemID)
  local out = {}
  for _, snap in ipairs(Snaps()) do
    local price = snap.p[itemID]
    if price then out[#out + 1] = { t = snap.t, price = price } end
  end
  return out
end

------------------------------------------------------------------------
-- Recording a purchase
------------------------------------------------------------------------
local function Record(itemID, link, qty, total)
  if not (itemID and qty and total) or qty <= 0 then return end
  local name
  if link then name = link:match("%[(.-)%]") end
  if not name then
    local infoName, infoLink = GetItemInfo(itemID)
    name, link = infoName, link or infoLink
  end
  name = name or (ns.items[itemID] and ns.items[itemID].name) or ("Item " .. itemID)

  local trades = ns.Trades()
  trades[#trades + 1] = {
    t = time(), id = itemID, name = name, link = link, qty = qty, total = total,
  }
  RememberItem(itemID, name)
  Print(("Logged %dx %s for %s (%s each)"):format(
    qty, link or name, ns.Money(total), ns.Money(total / qty)))
  if ns.Refresh then ns.Refresh() end
end

------------------------------------------------------------------------
-- Capture: commodities (stackable goods)
--   StartCommoditiesPurchase -> COMMODITY_PRICE_UPDATED -> Confirm... -> SUCCEEDED
------------------------------------------------------------------------
local pendingCommodity   -- { id, qty, total, confirmed }
local pendingItems = {}  -- [auctionID] = { id, link, total }

local function CommodityTotalFromResults(itemID, qty)
  local AH = C_AuctionHouse
  if not (AH.GetNumCommoditySearchResults and AH.GetCommoditySearchResultInfo) then return nil end
  local left, total = qty, 0
  for i = 1, AH.GetNumCommoditySearchResults(itemID) or 0 do
    local r = AH.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice and r.quantity then
      local take = math.min(left, r.quantity)
      total = total + take * r.unitPrice
      left = left - take
      if left <= 0 then return total end
    end
  end
  return nil
end

local function HookAuctionHouse()
  local AH = C_AuctionHouse
  if not AH then return end

  if AH.StartCommoditiesPurchase then
    hooksecurefunc(AH, "StartCommoditiesPurchase", function(itemID, quantity)
      pendingCommodity = { id = itemID, qty = quantity }
    end)
  end

  if AH.ConfirmCommoditiesPurchase then
    hooksecurefunc(AH, "ConfirmCommoditiesPurchase", function(itemID, quantity)
      if not pendingCommodity or pendingCommodity.id ~= itemID then
        pendingCommodity = { id = itemID }
      end
      pendingCommodity.qty = quantity
      pendingCommodity.confirmed = true
      if not pendingCommodity.total then
        pendingCommodity.total = CommodityTotalFromResults(itemID, quantity)
      end
    end)
  end

  if AH.CancelCommoditiesPurchase then
    hooksecurefunc(AH, "CancelCommoditiesPurchase", function()
      pendingCommodity = nil
    end)
  end

  -- Single items (gear etc.). Only buyouts are logged, bids are ignored.
  if AH.PlaceBid then
    hooksecurefunc(AH, "PlaceBid", function(auctionID, bidAmount)
      if not (auctionID and bidAmount) then return end
      local info = AH.GetAuctionInfoByID and AH.GetAuctionInfoByID(auctionID)
      if not info then return end
      local buyout = info.buyoutAmount
      if not buyout or buyout <= 0 or bidAmount < buyout then return end  -- a bid
      pendingItems[auctionID] = {
        id = info.itemKey and info.itemKey.itemID,
        link = info.itemLink,
        total = bidAmount,
      }
    end)
  end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local handlers = {}

function handlers.COMMODITY_PRICE_UPDATED(unitPrice, totalPrice)
  if pendingCommodity and not pendingCommodity.confirmed then
    pendingCommodity.total = totalPrice
  end
end

function handlers.COMMODITY_PURCHASE_SUCCEEDED()
  local p = pendingCommodity
  pendingCommodity = nil
  if p and p.confirmed and p.total then
    Record(p.id, nil, p.qty, p.total)
  end
end

function handlers.COMMODITY_PURCHASE_FAILED()
  pendingCommodity = nil
end

function handlers.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
  local p = pendingItems[auctionID]
  pendingItems[auctionID] = nil
  if p then Record(p.id, p.link, 1, p.total) end
end

function handlers.AUCTION_HOUSE_CLOSED()
  pendingCommodity = nil
  wipe(pendingItems)
end

function handlers.AUCTION_HOUSE_SHOW()
  if ns.AddAuctionHouseButton then ns.AddAuctionHouseButton() end
end

function handlers.GET_ITEM_INFO_RECEIVED()
  if ns.RefreshSoon then ns.RefreshSoon() end
end

function handlers.PLAYER_LOGIN()
  InitDB()
  HookAuctionHouse()

  local api = API()
  if api and api.RegisterForDBUpdate then
    -- Fires whenever Auctionator's price database changes (e.g. a full scan).
    pcall(api.RegisterForDBUpdate, CALLER, function()
      if ns.snapshotQueued then return end
      ns.snapshotQueued = true
      C_Timer.After(3, function()
        ns.snapshotQueued = false
        ns.Snapshot()
        if ns.Refresh then ns.Refresh() end
      end)
    end)
  end

  for event in pairs(handlers) do
    if event ~= "PLAYER_LOGIN" then
      pcall(frame.RegisterEvent, frame, event)  -- skip events this client lacks
    end
  end
end

frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, ...)
  local handler = handlers[event]
  if handler then handler(...) end
end)

------------------------------------------------------------------------
-- Money text: 12g 34s 56c
------------------------------------------------------------------------
function ns.Money(copper)
  if not copper then return "|cff808080-|r" end
  copper = math.floor(copper + 0.5)
  local g = math.floor(copper / 10000)
  local s = math.floor(copper % 10000 / 100)
  local c = copper % 100
  local G, S, C = "|cffffd700g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"
  if g > 0 then return ("%d%s %d%s %d%s"):format(g, G, s, S, c, C) end
  if s > 0 then return ("%d%s %d%s"):format(s, S, c, C) end
  return ("%d%s"):format(c, C)
end

------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------
SLASH_FLIPPER1 = "/flip"
SLASH_FLIPPER2 = "/flipper"
SlashCmdList.FLIPPER = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "snapshot" then
    local n = ns.Snapshot()
    Print(n > 0 and ("Saved prices for " .. n .. " items.")
      or "No prices to save (is Auctionator loaded and scanned?).")
    if ns.Refresh then ns.Refresh() end
  elseif msg:match("^font%s+%d+") then
    ns.SetFontSize(msg:match("%d+"))
  elseif msg:match("^scale%s+[%d%.]+") then
    local n = tonumber(msg:match("[%d%.]+"))
    if n and n > 3 then n = n / 100 end   -- accepts 1.2 or 120
    ns.SetScale(n)
  elseif msg:match("^quickdelete") then
    local label = ns.SetQuickDelete(msg:match("^quickdelete%s+(%a+)"))
    Print(label and ("Quick delete key: " .. label)
      or "Use: /flip quickdelete ctrl, shift, alt or off")
  elseif msg == "reset" then
    ns.ResetWindow()
    Print("Window size, position and settings reset.")
  elseif msg == "help" then
    Print("/flip - open the table")
    Print("/flip snapshot - save current Auctionator prices to the history now")
    Print("/flip font 8-20 - font size")
    Print("/flip scale 60-160 - window scale in percent")
    Print("/flip quickdelete ctrl/shift/alt/off - key that skips the delete confirmation")
    Print("/flip reset - reset window size, position and settings")
  else
    ns.Toggle()
  end
end
