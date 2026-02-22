-- UI/DebugFrame.lua
-- Scrollable, selectable text frame for diagnostic output.
-- Use DA:DebugOutput(line) to append a line and show the frame.
-- Text can be highlighted and Ctrl+C copied like a normal text box.

DisenchantingAddon = DisenchantingAddon or {}
local DA = DisenchantingAddon

local FRAME_W  = 660
local FRAME_H  = 460
local LINE_H   = 15   -- approximate px per line for height calculation

local debugFrame = nil

local function CreateDebugFrame()
    local f = CreateFrame("Frame", "DisenchantingAddonDebugFrame", UIParent,
        "BasicFrameTemplateWithInset")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()

    f.TitleText:SetText("Disenchanting Advisor — Diagnostics")

    -- Toolbar buttons (title bar row)
    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(60, 22)
    clearBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -28)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function() f.editBox:SetText("") end)

    local selAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    selAllBtn:SetSize(80, 22)
    selAllBtn:SetPoint("LEFT", clearBtn, "RIGHT", 4, 0)
    selAllBtn:SetText("Select All")
    selAllBtn:SetScript("OnClick", function()
        f.editBox:SetFocus()
        f.editBox:HighlightText()   -- selects all; then Ctrl+C copies
    end)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("LEFT", selAllBtn, "RIGHT", 6, 0)
    hint:SetText("|cFF888888Select All → Ctrl+C to copy|r")

    -- Scroll frame — starts below the title bar + clear button row
    local sf = CreateFrame("ScrollFrame", "DisenchantingAddonDebugScroll", f,
        "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",       8, -54)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",  -28,   8)

    -- Multiline EditBox as scroll child — selectable, not user-editable
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetFontObject(GameFontNormalSmall)
    eb:SetWidth(FRAME_W - 44)
    eb:SetAutoFocus(false)
    eb:SetTextInsets(4, 4, 4, 4)
    eb:SetMaxLetters(0)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    sf:SetScrollChild(eb)

    -- Resize the EditBox to fit its content so the scrollbar works.
    -- No auto-scroll — output stays at the top so you can read it all,
    -- scroll down manually to see new lines.
    eb:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        local lines = select(2, text:gsub("\n", "\n")) + 1
        self:SetHeight(math.max(1, lines * LINE_H + LINE_H))
    end)

    f.editBox    = eb
    f.scrollFrame = sf
    debugFrame = f
end

-- ---------------------------------------------------------------------------
-- Public: append one line of text and ensure the frame is visible.
-- Accepts plain text or WoW colour-code strings.
-- ---------------------------------------------------------------------------
function DA:DebugOutput(text)
    if not debugFrame then CreateDebugFrame() end
    debugFrame:Show()
    local eb  = debugFrame.editBox
    local cur = eb:GetText()
    eb:SetText(cur == "" and text or (cur .. "\n" .. text))
end

-- ---------------------------------------------------------------------------
-- Public: clear all text in the debug frame.
-- ---------------------------------------------------------------------------
function DA:ClearDebugOutput()
    if debugFrame then debugFrame.editBox:SetText("") end
end

-- ---------------------------------------------------------------------------
-- Public: toggle the debug frame open/closed.
-- ---------------------------------------------------------------------------
function DA:ToggleDebugFrame()
    if not debugFrame then CreateDebugFrame() end
    if debugFrame:IsShown() then
        debugFrame:Hide()
    else
        debugFrame:Show()
    end
end
