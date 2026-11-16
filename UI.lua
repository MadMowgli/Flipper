-- Flipper table window: /flip
local ADDON, ns = ...

local BASE_FONT = 11
local DEFAULTS = { fontSize = BASE_FONT, scale = 1, opacity = 0.9, height = 460,
                   quickDelete = "CTRL", searchHides = false }
local FONT_MIN, FONT_MAX = 8, 20
local SCALE_MIN, SCALE_MAX = 0.6, 1.6
local OPACITY_MIN, OPACITY_MAX = 0.3, 1
local ITEM_MIN = 120          -- smallest width of the Item column (at base font)
local PAD, GAP, SCROLLBAR = 12, 8, 26
local MAX_SUGGESTIONS = 8

-- Key that, held while clicking a row's X, deletes without asking.
local QUICK_KEYS = { "CTRL", "SHIFT", "ALT", "NONE" }
local QUICK_LABEL = { CTRL = "Ctrl", SHIFT = "Shift", ALT = "Alt", NONE = "Off" }

-- Widths are for the base font size and grow with the font.
-- The Item column takes whatever room is left when the window is resized.
local COLUMNS = {
  { key = "date",   title = "Date",        width = 120, align = "LEFT"  },
  { key = "item",   title = "Item",        width = 220, align = "LEFT"  },
  { key = "qty",    title = "Amount",      width = 60,  align = "RIGHT" },
  { key = "total",  title = "Paid",        width = 105, align = "RIGHT" },
  { key = "each",   title = "Per piece",   width = 105, align = "RIGHT" },
  { key = "now",    title = "Now / piece", width = 105, align = "RIGHT" },
  { key = "change", title = "Change",      width = 70,  align = "RIGHT" },
}

local window, header, scroll, content, status, emptyText, settingsPanel
local searchBox, dropdown
local rows = {}
local shownCount = 0
local L   -- current layout, see ComputeLayout

-- search state
local query, words = "", {}
local suggestions = {}        -- { {name = "Copper Ore", count = 3}, ... }
local firstMatch              -- row index of the first matching row
local tabCycle                -- { names = {...}, i = 1 } while pressing Tab

local function UI()
  return FlipperDB.ui
end

local function Clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

------------------------------------------------------------------------
-- Layout: column widths and row height from font size + window width
------------------------------------------------------------------------
local function ComputeLayout(frameWidth)
  local size = UI().fontSize
  local s = size / BASE_FONT
  local rowH = size + 9
  local widths, fixed = {}, 0
  for _, col in ipairs(COLUMNS) do
    if col.key ~= "item" then
      widths[col.key] = math.floor(col.width * s + 0.5)
      fixed = fixed + widths[col.key]
    end
  end
  fixed = fixed + GAP * #COLUMNS + rowH          -- gaps + the delete button
  local itemMin = math.floor(ITEM_MIN * s + 0.5)
  local chrome = PAD * 2 + SCROLLBAR
  widths.item = math.max(itemMin, (frameWidth or 0) - chrome - fixed)
  return {
    fontSize = size, rowH = rowH, widths = widths,
    contentW = fixed + widths.item,
    minW = fixed + itemMin + chrome,
  }
end

local function ApplyFont(fs, size)
  local path, _, flags = GameFontHighlightSmall:GetFont()
  fs:SetFont(path, size, flags or "")
end

local function AddCells(parent, font)
  local cells = {}
  for _, col in ipairs(COLUMNS) do
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH(col.align)
    fs:SetWordWrap(false)
    cells[col.key] = fs
  end
  return cells
end

local function LayoutCells(holder)
  local x = 0
  for _, col in ipairs(COLUMNS) do
    local fs = holder.cells[col.key]
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", holder, "LEFT", x, 0)
    fs:SetWidth(L.widths[col.key])
    ApplyFont(fs, L.fontSize)
    x = x + L.widths[col.key] + GAP
  end
end

local function LayoutRow(row, i)
  row:SetSize(L.contentW, L.rowH)
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * L.rowH)
  LayoutCells(row)
  row.del:SetSize(L.rowH, L.rowH)
  ApplyFont(row.del.text, L.fontSize)
end

local function Layout()
  if not window then return end
  L = ComputeLayout(window:GetWidth())
  header:SetSize(L.contentW, L.rowH)
  LayoutCells(header)
  content:SetSize(L.contentW, math.max(shownCount, 1) * L.rowH)
  for i, row in ipairs(rows) do LayoutRow(row, i) end
  if window.SetResizeBounds then
    window:SetResizeBounds(L.minW, 200)
  elseif window.SetMinResize then
    window:SetMinResize(L.minW, 200)
  end
end

------------------------------------------------------------------------
-- Search: every typed word must appear in the item name (any case)
------------------------------------------------------------------------
local function Matches(trade)
  local name = (trade.name or ""):lower()
  for _, word in ipairs(words) do
    if not name:find(word, 1, true) then return false end
  end
  return true
end

-- Distinct item names in the log that match what was typed.
-- Names that start with the typed text come first.
local function BuildSuggestions()
  suggestions = {}
  if query == "" then return end
  local byName = {}
  for _, trade in ipairs(ns.Trades()) do
    local name = trade.name
    if name and Matches(trade) then
      local entry = byName[name]
      if not entry then
        entry = { name = name, count = 0, starts = name:lower():find(query, 1, true) == 1 }
        byName[name] = entry
        suggestions[#suggestions + 1] = entry
      end
      entry.count = entry.count + 1
    end
  end
  table.sort(suggestions, function(a, b)
    if a.starts ~= b.starts then return a.starts end
    return a.name < b.name
  end)
end

local function UpdateDropdown()
  if not dropdown then return end
  local show = searchBox:HasFocus() and #suggestions > 0
    and not (#suggestions == 1 and suggestions[1].name:lower() == query)
  if not show then
    dropdown:Hide()
    return
  end
  local n = math.min(#suggestions, MAX_SUGGESTIONS)
  for i, button in ipairs(dropdown.buttons) do
    local s = suggestions[i]
    if i <= n then
      button.name = s.name
      button.text:SetText(s.name)
      button.count:SetText(s.count .. "x")
      button:Show()
    else
      button:Hide()
    end
  end
  local more = #suggestions - n
  dropdown.more:SetText(more > 0 and ("... and " .. more .. " more, keep typing") or "")
  dropdown:SetHeight(n * 18 + (more > 0 and 28 or 12))
  dropdown:Show()
end

local function ScrollToFirstMatch()
  if not scroll then return end
  local target = 0
  if query ~= "" and firstMatch then
    local maxScroll = math.max(0, content:GetHeight() - scroll:GetHeight())
    target = math.min((firstMatch - 1) * L.rowH, maxScroll)
  end
  scroll:SetVerticalScroll(target)
end

local function SetQuery(text)
  local new = (text or ""):lower():match("^%s*(.-)%s*$")
  if new == query then
    UpdateDropdown()
    return
  end
  query = new
  words = {}
  for word in query:gmatch("%S+") do words[#words + 1] = word end
  BuildSuggestions()
  UpdateDropdown()
  ns.Refresh()
  ScrollToFirstMatch()
end

-- Tab fills in the first suggestion; pressing Tab again goes to the next one.
local function CompleteFromTab()
  local text = searchBox:GetText()
  if tabCycle and tabCycle.names[tabCycle.i] == text then
    tabCycle.i = tabCycle.i % #tabCycle.names + 1
  else
    if #suggestions == 0 then return end
    local names = {}
    for i = 1, math.min(#suggestions, MAX_SUGGESTIONS) do names[i] = suggestions[i].name end
    tabCycle = { names = names, i = 1 }
  end
  searchBox:SetText(tabCycle.names[tabCycle.i])
  searchBox:SetCursorPosition(#searchBox:GetText())
end

local function CreateSearch(anchor)
  local ok, box = pcall(CreateFrame, "EditBox", "FlipperSearchBox", window, "SearchBoxTemplate")
  if not ok or not box then
    box = CreateFrame("EditBox", "FlipperSearchBox", window, "InputBoxTemplate")
  end
  box:SetSize(190, 20)
  box:SetPoint("LEFT", anchor, "RIGHT", 20, 0)
  box:SetAutoFocus(false)
  box:SetMaxLetters(60)
  box:HookScript("OnTextChanged", function(self) SetQuery(self:GetText()) end)
  box:HookScript("OnEditFocusGained", function() UpdateDropdown() end)
  box:HookScript("OnEditFocusLost", function() if dropdown then dropdown:Hide() end end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
  end)
  box:SetScript("OnTabPressed", CompleteFromTab)
  box:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:SetText("Search your purchases")
    GameTooltip:AddLine("Type part of an item name. Several words narrow it down.", 1, 1, 1, true)
    GameTooltip:AddLine("Tab: fill in a suggestion (again for the next)", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Escape: clear the search", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  box:HookScript("OnLeave", function() GameTooltip:Hide() end)
  searchBox = box

  -- suggestion list under the search box
  local d = CreateFrame("Frame", nil, window, "BackdropTemplate")
  d:SetFrameStrata("DIALOG")
  d:SetWidth(260)
  d:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -2)
  d:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  d:SetBackdropColor(0, 0, 0, 0.97)
  d:EnableMouse(true)
  d:Hide()
  d.buttons = {}
  for i = 1, MAX_SUGGESTIONS do
    local b = CreateFrame("Button", nil, d)
    b:SetHeight(18)
    b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
    b:SetPoint("TOPRIGHT", -6, -6 - (i - 1) * 18)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.2)
    b.count = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.count:SetPoint("RIGHT", -2, 0)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 2, 0)
    b.text:SetPoint("RIGHT", b.count, "LEFT", -6, 0)
    b.text:SetJustifyH("LEFT")
    b.text:SetWordWrap(false)
    b:SetScript("OnClick", function(self)
      box:SetText(self.name)
      box:ClearFocus()
    end)
    d.buttons[i] = b
  end
  d.more = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  d.more:SetPoint("BOTTOMLEFT", 8, 7)
  dropdown = d
end

------------------------------------------------------------------------
-- Deleting a row
------------------------------------------------------------------------
local function DeleteTrade(trade)
  if not trade then return end
  local trades = ns.Trades()
  for i = #trades, 1, -1 do
    if trades[i] == trade then
      table.remove(trades, i)
      break
    end
  end
  BuildSuggestions()
  UpdateDropdown()
  ns.Refresh()
end

StaticPopupDialogs["FLIPPER_DELETE"] = {
  text = "Delete this entry from Flipper?\n\n%s",
  button1 = YES,
  button2 = NO,
  OnAccept = function(self, trade) DeleteTrade(trade) end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

local function QuickDeleteHeld()
  local key = UI().quickDelete
  return (key == "CTRL" and IsControlKeyDown())
    or (key == "SHIFT" and IsShiftKeyDown())
    or (key == "ALT" and IsAltKeyDown())
end

local function OnDeleteClick(trade)
  if not trade then return end
  if QuickDeleteHeld() then
    GameTooltip:Hide()
    DeleteTrade(trade)
    return
  end
  local label = ("%dx %s"):format(trade.qty, trade.link or trade.name or ("Item " .. tostring(trade.id)))
  StaticPopup_Show("FLIPPER_DELETE", label, nil, trade)
end

------------------------------------------------------------------------
-- Row tooltip: item + recorded price history
------------------------------------------------------------------------
local function ShowRowTooltip(row)
  local trade = row.trade
  if not trade then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  local shown = false
  if trade.link then
    shown = pcall(GameTooltip.SetHyperlink, GameTooltip, trade.link)
  end
  if not shown then
    GameTooltip:SetText(trade.name or ("Item " .. tostring(trade.id)))
  end

  local history = ns.History(trade.id)
  GameTooltip:AddLine(" ")
  if #history == 0 then
    GameTooltip:AddLine("No price history yet. Run an Auctionator full scan.", 0.6, 0.6, 0.6, true)
  else
    GameTooltip:AddLine("Price per piece at your scans:", 1, 0.82, 0)
    for i = math.max(1, #history - 9), #history do
      local h = history[i]
      GameTooltip:AddDoubleLine(date("%d %b %H:%M", h.t), ns.Money(h.price), 1, 1, 1, 1, 1, 1)
    end
  end
  GameTooltip:Show()
end

local function GetRow(i)
  local row = rows[i]
  if row then return row end
  row = CreateFrame("Frame", nil, content)
  row:EnableMouse(true)
  row.cells = AddCells(row, "GameFontHighlightSmall")

  local stripe = row:CreateTexture(nil, "BACKGROUND")
  stripe:SetAllPoints()
  stripe:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.05 or 0)

  -- gold tint for rows that match the search
  row.mark = row:CreateTexture(nil, "BORDER")
  row.mark:SetAllPoints()
  row.mark:SetColorTexture(1, 0.82, 0, 0.16)
  row.mark:Hide()

  local hover = row:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetColorTexture(1, 1, 1, 0.10)

  -- small X at the end of the row
  local del = CreateFrame("Button", nil, row)
  del:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  del.text = del:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  del.text:SetPoint("CENTER")
  del.text:SetText("X")
  del.text:SetTextColor(0.8, 0.25, 0.25)
  del:SetScript("OnEnter", function(self)
    self.text:SetTextColor(1, 0.4, 0.4)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Delete this entry")
    local key = UI().quickDelete
    if key ~= "NONE" then
      GameTooltip:AddLine("Hold " .. QUICK_LABEL[key] .. " to skip the confirmation", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
  end)
  del:SetScript("OnLeave", function(self)
    self.text:SetTextColor(0.8, 0.25, 0.25)
    GameTooltip:Hide()
  end)
  del:SetScript("OnClick", function() OnDeleteClick(row.trade) end)
  row.del = del

  row:SetScript("OnEnter", ShowRowTooltip)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  rows[i] = row
  LayoutRow(row, i)
  return row
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local function ApplySettings()
  if not window then return end
  local ui = UI()
  window:SetScale(ui.scale)
  window:SetBackdropColor(0, 0, 0, ui.opacity)
  local minW = ComputeLayout(0).minW
  if window:GetWidth() < minW then window:SetWidth(minW) end
  Layout()
  if settingsPanel and settingsPanel.Update then settingsPanel.Update() end
  ns.Refresh()
end

local function SaveGeometry()
  local ui = UI()
  ui.width, ui.height = window:GetWidth(), window:GetHeight()
  local point, _, relPoint, x, y = window:GetPoint(1)
  if point then ui.pos = { point, relPoint, x, y } end
end

local function EnsureWindow()
  if not window then ns.CreateWindow() end
end

function ns.SetFontSize(size)
  EnsureWindow()
  UI().fontSize = Clamp(math.floor((tonumber(size) or BASE_FONT) + 0.5), FONT_MIN, FONT_MAX)
  ApplySettings()
end

function ns.SetScale(scale)
  EnsureWindow()
  UI().scale = Clamp(tonumber(scale) or 1, SCALE_MIN, SCALE_MAX)
  ApplySettings()
end

function ns.SetOpacity(opacity)
  EnsureWindow()
  UI().opacity = Clamp(tonumber(opacity) or DEFAULTS.opacity, OPACITY_MIN, OPACITY_MAX)
  ApplySettings()
end

-- key: "ctrl", "shift", "alt" or "off". Returns the label, or nil if unknown.
function ns.SetQuickDelete(key)
  EnsureWindow()
  key = tostring(key or ""):upper()
  if key == "OFF" or key == "CONTROL" then key = (key == "OFF") and "NONE" or "CTRL" end
  if not QUICK_LABEL[key] then return nil end
  UI().quickDelete = key
  ApplySettings()
  return QUICK_LABEL[key]
end

function ns.ResetWindow()
  EnsureWindow()
  local ui = UI()
  ui.fontSize, ui.scale, ui.opacity = DEFAULTS.fontSize, DEFAULTS.scale, DEFAULTS.opacity
  ui.quickDelete, ui.searchHides = DEFAULTS.quickDelete, DEFAULTS.searchHides
  ui.width, ui.height, ui.pos = nil, nil, nil
  window:ClearAllPoints()
  window:SetPoint("CENTER")
  window:SetSize(ComputeLayout(0).minW + 100, DEFAULTS.height)
  ApplySettings()
end

-- One settings line:  Label   [-]  value  [+]
local function AddStepper(parent, y, label, getText, onStep)
  local name = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  name:SetPoint("TOPLEFT", 12, y - 5)
  name:SetText(label)

  local plus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  plus:SetSize(22, 20)
  plus:SetPoint("TOPRIGHT", -12, y)
  plus:SetText("+")
  plus:SetScript("OnClick", function() onStep(1) end)

  local value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  value:SetPoint("RIGHT", plus, "LEFT", -4, 0)
  value:SetWidth(44)
  value:SetJustifyH("CENTER")

  local minus = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  minus:SetSize(22, 20)
  minus:SetPoint("RIGHT", value, "LEFT", -4, 0)
  minus:SetText("-")
  minus:SetScript("OnClick", function() onStep(-1) end)

  return function() value:SetText(getText()) end
end

-- One settings line:  Label   [ current choice ]   (click to change)
local function AddChoice(parent, y, label, getText, onClick)
  local name = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  name:SetPoint("TOPLEFT", 12, y - 5)
  name:SetText(label)

  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetSize(100, 20)
  button:SetPoint("TOPRIGHT", -12, y)
  button:SetScript("OnClick", onClick)

  return function() button:SetText(getText()) end
end

local function CreateSettingsPanel()
  local p = CreateFrame("Frame", nil, window, "BackdropTemplate")
  p:SetSize(240, 266)
  p:SetPoint("TOPLEFT", window, "TOPRIGHT", 4, 0)
  p:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  p:SetBackdropColor(0, 0, 0, 0.95)
  p:EnableMouse(true)
  p:Hide()

  local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -12)
  title:SetText("Settings")

  local updaters = {
    AddStepper(p, -36, "Font size",
      function() return UI().fontSize end,
      function(d) ns.SetFontSize(UI().fontSize + d) end),
    AddStepper(p, -62, "Window scale",
      function() return ("%d%%"):format(UI().scale * 100 + 0.5) end,
      function(d) ns.SetScale(UI().scale + d * 0.05) end),
    AddStepper(p, -88, "Background",
      function() return ("%d%%"):format(UI().opacity * 100 + 0.5) end,
      function(d) ns.SetOpacity(UI().opacity + d * 0.1) end),
    AddChoice(p, -118, "Quick delete key",
      function() return QUICK_LABEL[UI().quickDelete] end,
      function()
        local current = UI().quickDelete
        for i, key in ipairs(QUICK_KEYS) do
          if key == current then
            ns.SetQuickDelete(QUICK_KEYS[i % #QUICK_KEYS + 1])
            return
          end
        end
        ns.SetQuickDelete("CTRL")
      end),
    AddChoice(p, -144, "Search shows",
      function() return UI().searchHides and "Matches only" or "All rows" end,
      function()
        UI().searchHides = not UI().searchHides
        ApplySettings()
        ScrollToFirstMatch()
      end),
  }

  local hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", 12, -172)
  hint:SetPoint("RIGHT", -12, 0)
  hint:SetJustifyH("LEFT")
  hint:SetText("Hold the quick delete key while clicking X to skip the confirmation.\nDrag the bottom-right corner to resize.")

  local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  reset:SetSize(216, 22)
  reset:SetPoint("BOTTOM", 0, 12)
  reset:SetText("Reset size, position and settings")
  reset:SetScript("OnClick", function() ns.ResetWindow() end)

  p.Update = function()
    for _, update in ipairs(updaters) do update() end
  end
  p.Update()
  settingsPanel = p
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
function ns.CreateWindow()
  FlipperDB.ui = FlipperDB.ui or {}
  local ui = UI()
  ui.fontSize = Clamp(tonumber(ui.fontSize) or DEFAULTS.fontSize, FONT_MIN, FONT_MAX)
  ui.scale = Clamp(tonumber(ui.scale) or DEFAULTS.scale, SCALE_MIN, SCALE_MAX)
  ui.opacity = Clamp(tonumber(ui.opacity) or DEFAULTS.opacity, OPACITY_MIN, OPACITY_MAX)
  if not QUICK_LABEL[ui.quickDelete] then ui.quickDelete = DEFAULTS.quickDelete end
  ui.searchHides = ui.searchHides and true or false

  local minW = ComputeLayout(0).minW
  local f = CreateFrame("Frame", "FlipperFrame", UIParent, "BackdropTemplate")
  f:SetSize(math.max(ui.width or (minW + 100), minW), ui.height or DEFAULTS.height)
  if ui.pos then
    f:SetPoint(ui.pos[1], UIParent, ui.pos[2], ui.pos[3], ui.pos[4])
  else
    f:SetPoint("CENTER")
  end
  f:SetFrameStrata("HIGH")
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetResizable(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveGeometry()
  end)
  f:Hide()
  tinsert(UISpecialFrames, "FlipperFrame")   -- Escape closes it
  window = f

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", PAD, -12)
  title:SetText("Flipper")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local settingsButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  settingsButton:SetSize(80, 20)
  settingsButton:SetPoint("RIGHT", close, "LEFT", -2, 0)
  settingsButton:SetText("Settings")
  settingsButton:SetScript("OnClick", function()
    if not settingsPanel then CreateSettingsPanel() end
    settingsPanel:SetShown(not settingsPanel:IsShown())
  end)

  CreateSearch(title)

  header = CreateFrame("Frame", nil, f)
  header:SetPoint("TOPLEFT", PAD, -40)
  header.cells = AddCells(header, "GameFontNormalSmall")
  for _, col in ipairs(COLUMNS) do header.cells[col.key]:SetText(col.title) end

  local line = f:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 0.82, 0, 0.4)
  line:SetHeight(1)
  line:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
  line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)

  scroll = CreateFrame("ScrollFrame", "FlipperScrollFrame", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD - 22, 34)

  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(100, 20)
  scroll:SetScrollChild(content)

  emptyText = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  emptyText:SetPoint("CENTER", 0, 0)

  status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  status:SetPoint("BOTTOMLEFT", PAD, 12)
  status:SetPoint("BOTTOMRIGHT", -PAD - 16, 12)
  status:SetJustifyH("LEFT")
  status:SetWordWrap(false)

  -- resize grip in the bottom-right corner
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -4, 4)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    SaveGeometry()
    ns.Refresh()
  end)

  f:SetScript("OnSizeChanged", Layout)
  f:SetScript("OnShow", function()
    BuildSuggestions()
    ns.Refresh()
  end)
  f:SetScript("OnHide", function()
    if searchBox then searchBox:ClearFocus() end
  end)
  ApplySettings()
end

------------------------------------------------------------------------
-- Fill the table
------------------------------------------------------------------------
function ns.Refresh()
  if not window or not window:IsShown() then return end
  local trades = ns.Trades()
  local total = #trades
  local searching = query ~= ""
  local hideOthers = searching and UI().searchHides

  -- Which trades to show (newest first) and which of them match the search.
  local list, isMatch = {}, {}
  local matchCount, matchQty, matchPaid, matchId, sameItem = 0, 0, 0, nil, true
  firstMatch = nil
  for i = total, 1, -1 do
    local trade = trades[i]
    local match = searching and Matches(trade)
    if match then
      matchCount = matchCount + 1
      matchQty = matchQty + trade.qty
      matchPaid = matchPaid + trade.total
      if matchId == nil then matchId = trade.id elseif matchId ~= trade.id then sameItem = false end
    end
    if match or not hideOthers then
      list[#list + 1] = trade
      isMatch[#list] = match
      if match and not firstMatch then firstMatch = #list end
    end
  end
  local count = #list
  shownCount = count

  for i = 1, count do
    local trade = list[i]
    local row = GetRow(i)
    local cells = row.cells
    local each = trade.total / trade.qty
    local now = ns.GetPrice(trade.id, trade.link)

    row.trade = trade
    cells.date:SetText(date("%Y-%m-%d %H:%M", trade.t))
    cells.item:SetText(trade.link or trade.name or ("Item " .. tostring(trade.id)))
    cells.qty:SetText(trade.qty)
    cells.total:SetText(ns.Money(trade.total))
    cells.each:SetText(ns.Money(each))
    cells.now:SetText(ns.Money(now))

    if now and each > 0 then
      local pct = (now - each) / each * 100
      local color = "ffffffff"
      if pct >= 0.05 then color = "ff40ff40" elseif pct <= -0.05 then color = "ffff4040" end
      cells.change:SetText(("|c%s%+.1f%%|r"):format(color, pct))
    else
      cells.change:SetText("|cff808080-|r")
    end

    -- search: tint the matches, fade the rest
    row.mark:SetShown(searching and isMatch[i] and not hideOthers)
    row:SetAlpha((searching and not isMatch[i]) and 0.35 or 1)
    row:Show()
  end
  for i = count + 1, #rows do
    rows[i].trade = nil
    rows[i]:Hide()
  end

  content:SetHeight(math.max(count, 1) * L.rowH)

  if total == 0 then
    emptyText:SetText("Nothing logged yet. Buy something at the auction house.")
  else
    emptyText:SetText("No purchases match your search.")
  end
  emptyText:SetShown(count == 0)

  if searching then
    if matchCount == 0 then
      status:SetText(("No match for \"%s\" in %d purchases."):format(query, total))
    else
      local text = ("%d of %d purchases match: %d pieces for %s"):format(
        matchCount, total, matchQty, ns.Money(matchPaid))
      if sameItem and matchQty > 0 then
        text = text .. (", average %s per piece"):format(ns.Money(matchPaid / matchQty))
      end
      status:SetText(text)
    end
  else
    status:SetText(total .. " purchases. \"Now\" is from your last Auctionator scan. Hover a row for its price history.")
  end
end

-- Item names/links arrive late sometimes; redraw once shortly after.
local refreshQueued
function ns.RefreshSoon()
  if refreshQueued or not window or not window:IsShown() then return end
  refreshQueued = true
  C_Timer.After(0.5, function()
    refreshQueued = false
    ns.Refresh()
  end)
end

function ns.Toggle()
  EnsureWindow()
  window:SetShown(not window:IsShown())
end

------------------------------------------------------------------------
-- Small "Flipper" button above the auction house window
------------------------------------------------------------------------
local ahButton
function ns.AddAuctionHouseButton()
  if ahButton or not AuctionHouseFrame then return end
  ahButton = CreateFrame("Button", nil, AuctionHouseFrame, "UIPanelButtonTemplate")
  ahButton:SetSize(80, 22)
  ahButton:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "TOPRIGHT", -4, 2)
  ahButton:SetText("Flipper")
  ahButton:SetScript("OnClick", function() ns.Toggle() end)
end
