local ADDON_NAME = ...

local DEFAULTS = {
    showBar = true,
    showRestedXP = true,
    showTimeUntilFull = true,

    logoutWarning = true,
    dontWarnWhenFull = true,
    dontWarnAtMaxLevel = true,

    locked = false,
    alwaysKeepCentered = false,

    width = 460,
    height = 18,
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = -250,
}

local RESTED_CAP_PERCENT = 150

-- Classic rested XP estimate:
-- 5% of a level per 8 hours while resting.
local RESTED_PERCENT_PER_8_HOURS = 5
local RESTED_HOURS_PER_5_PERCENT = 8

local BLIZZARD_RESTED_XP_URL = "https://eu.support.blizzard.com/en/help/article/18305"

local db
local bar
local settingsFrame

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(tostring(message))
end

local function PrintLoadedMessage()
    Print("|cffffffff------------------------------------------------------|r")
    Print("|cff00ff00Rested XP Helper Loaded|r")
    Print("|cffffffffType /rested to open settings|r")
    Print("|cffffffff------------------------------------------------------|r")
end

local function CopyDefaults(source, destination)
    for key, value in pairs(source) do
        if destination[key] == nil then
            destination[key] = value
        end
    end
end

local function GetMaxLevel()
    if type(GetMaxPlayerLevel) == "function" then
        local value = GetMaxPlayerLevel()
        if value and value > 0 then
            return value
        end
    end

    if type(MAX_PLAYER_LEVEL) == "number" and MAX_PLAYER_LEVEL > 0 then
        return MAX_PLAYER_LEVEL
    end

    return 70
end

local function IsMaxLevel()
    return UnitLevel("player") >= GetMaxLevel()
end

local function GetRestedData()
    local maxXP = UnitXPMax("player") or 0
    local restedXP = GetXPExhaustion() or 0
    local restedPercent = 0

    if maxXP > 0 then
        restedPercent = (restedXP / maxXP) * 100
    end

    if restedPercent < 0 then
        restedPercent = 0
    elseif restedPercent > RESTED_CAP_PERCENT then
        restedPercent = RESTED_CAP_PERCENT
    end

    return restedXP, maxXP, restedPercent
end

local function FormatDuration(seconds)
    if not seconds or seconds <= 0 then
        return "0h"
    end

    local totalMinutes = math.floor((seconds + 30) / 60)
    local days = math.floor(totalMinutes / 1440)
    local hours = math.floor((totalMinutes % 1440) / 60)
    local minutes = totalMinutes % 60

    if days > 0 then
        return string.format("%dd %dh", days, hours)
    elseif hours > 0 then
        return string.format("%dh %dm", hours, minutes)
    else
        return string.format("%dm", math.max(1, minutes))
    end
end

local function GetRestedETASeconds(restedPercent)
    if restedPercent >= RESTED_CAP_PERCENT then
        return 0
    end

    local percentRemaining = RESTED_CAP_PERCENT - restedPercent
    local hours = (percentRemaining / RESTED_PERCENT_PER_8_HOURS) * RESTED_HOURS_PER_5_PERCENT

    return hours * 60 * 60
end

local function IsFullyRested()
    local _, _, restedPercent = GetRestedData()
    return restedPercent >= (RESTED_CAP_PERCENT - 0.01)
end

local function BuildBarText()
    if IsMaxLevel() then
        return "MAX LEVEL"
    end

    local _, maxXP, restedPercent = GetRestedData()

    if maxXP <= 0 then
        return "Rested XP unavailable"
    end

    local parts = {}

    if db.showRestedXP == true then
        table.insert(
            parts,
            string.format("Rested XP %.0f%% / %d%%", restedPercent, RESTED_CAP_PERCENT)
        )
    end

    if db.showTimeUntilFull == true then
        if restedPercent >= RESTED_CAP_PERCENT - 0.01 then
            table.insert(parts, "FULLY RESTED")
        else
            table.insert(
                parts,
                FormatDuration(GetRestedETASeconds(restedPercent)) .. " until full"
            )
        end
    end

    return table.concat(parts, " | ")
end

local function UpdateResizeGrip()
    -- The bar height is fixed; width can be resized horizontally.
end

local GetBarCenterYOffset
local ApplyCenteredPosition

local MINIMUM_REFERENCE_TEXT = "Rested XP 00% / 150% | 10d 00h until full"

local function GetMinimumBarWidth()
    if not bar or not bar.text then
        return 360
    end

    -- Always measure the longest reference string rather than the current
    -- on-screen value. This means the bar can grow wider, but can never be
    -- resized smaller than the space needed for:
    --
    -- Rested XP 00% / 150% | 10d 00h until full
    local currentText = bar.text:GetText()
    local oldWidth = bar.text:GetWidth()

    bar.text:SetWidth(0)
    bar.text:SetText(MINIMUM_REFERENCE_TEXT)

    local textWidth = bar.text:GetStringWidth() or 0

    bar.text:SetText(currentText or "")

    if oldWidth and oldWidth > 0 then
        bar.text:SetWidth(oldWidth)
    end

    -- 28px total padding gives a little breathing room either side.
    local minWidth = math.ceil(textWidth + 28)

    if minWidth < 360 then
        minWidth = 360
    end

    return minWidth
end

local function ApplyBarWidth(width)
    if not bar or not db then
        return
    end

    local minWidth = GetMinimumBarWidth()

    if width < minWidth then
        width = minWidth
    end

    if width > 900 then
        width = 900
    end

    db.width = math.floor(width + 0.5)
    db.height = 18

    bar:SetSize(db.width, 18)

    if bar.text then
        bar.text:SetWidth(math.max(1, db.width - 20))
        bar.text:SetHeight(18)
    end
end

local function UpdateBar()
    if not bar or not db then
        return
    end

    if not db.showBar then
        bar:Hide()
        return
    end

    bar:Show()

    if db.alwaysKeepCentered then
        ApplyCenteredPosition()
    end

    local restedXP, maxXP, restedPercent = GetRestedData()

    -- The fill represents the player's current rested XP as a percentage
    -- of the 150% rested cap.
    bar:SetMinMaxValues(0, RESTED_CAP_PERCENT)
    bar:SetValue(restedPercent)

    local displayText = BuildBarText()

    -- Size first. GetMinimumBarWidth() temporarily changes the font string
    -- while measuring the minimum reference text.
    bar.text:SetText(displayText)
    ApplyBarWidth(db.width or DEFAULTS.width)

    -- Re-apply the real label after width measurement so it is guaranteed to
    -- be the visible on-bar text.
    bar.text:SetText(displayText)
    bar.text:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    bar.text:Show()
end

GetBarCenterYOffset = function()
    if not bar then
        return DEFAULTS.y
    end

    local barCenterY = bar:GetCenter()
    local uiCenterY = UIParent:GetCenter()

    if not barCenterY or not uiCenterY then
        return db.y or DEFAULTS.y
    end

    -- GetCenter() returns x, y. We only want the Y values.
    local _, actualBarCenterY = bar:GetCenter()
    local _, actualUICenterY = UIParent:GetCenter()

    if not actualBarCenterY or not actualUICenterY then
        return db.y or DEFAULTS.y
    end

    return actualBarCenterY - actualUICenterY
end

ApplyCenteredPosition = function()
    if not bar or not db then
        return
    end

    -- Keep the bar centered horizontally but preserve its true screen Y
    -- position, regardless of which anchor WoW used while dragging.
    local verticalY = db.y or DEFAULTS.y

    bar:ClearAllPoints()
    bar:SetPoint("CENTER", UIParent, "CENTER", 0, verticalY)

    db.point = "CENTER"
    db.relativePoint = "CENTER"
    db.x = 0
    db.y = verticalY
end

local function SavePosition()
    if not bar or not db then
        return
    end

    if db.alwaysKeepCentered then
        -- Save the bar's actual on-screen centre Y instead of the current
        -- anchor offset. This avoids jumps when WoW changes the anchor near
        -- the top or bottom of the screen.
        db.point = "CENTER"
        db.relativePoint = "CENTER"
        db.x = 0
        db.y = math.floor(GetBarCenterYOffset() + 0.5)

        bar:ClearAllPoints()
        bar:SetPoint("CENTER", UIParent, "CENTER", 0, db.y)
        return
    end

    local point, _, relativePoint, x, y = bar:GetPoint(1)

    if not point then
        return
    end

    db.point = point
    db.relativePoint = relativePoint or point
    db.x = math.floor((x or 0) + 0.5)
    db.y = math.floor((y or 0) + 0.5)
end

local function SaveSize()
    if not bar or not db then
        return
    end

    db.width = math.floor((bar:GetWidth() or DEFAULTS.width) + 0.5)
    db.height = math.floor((bar:GetHeight() or DEFAULTS.height) + 0.5)
end

local function ResetBarPosition()
    if not bar then
        return
    end

    db.width = DEFAULTS.width
    db.height = 18
    db.point = DEFAULTS.point
    db.relativePoint = DEFAULTS.relativePoint
    db.x = DEFAULTS.x
    db.y = DEFAULTS.y

    bar:ClearAllPoints()
    bar:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
    bar:SetSize(db.width, db.height)

    UpdateBar()

    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffRested XP Helper:|r Position reset.")
end

local function CreateBar()
    if bar then
        return
    end

    bar = CreateFrame("StatusBar", "RestedXpHelperFrame", UIParent)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.20, 0.45, 0.90, 1)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:SetResizable(true)
    bar:EnableMouse(true)

    bar:SetSize(db.width, db.height)
    bar:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)

    bar.background = bar:CreateTexture(nil, "BACKGROUND")
    bar.background:SetAllPoints()
    bar.background:SetColorTexture(0.04, 0.04, 0.04, 0.88)

    bar.borderTop = bar:CreateTexture(nil, "OVERLAY")
    bar.borderTop:SetColorTexture(0.55, 0.55, 0.55, 0.9)
    bar.borderTop:SetPoint("TOPLEFT")
    bar.borderTop:SetPoint("TOPRIGHT")
    bar.borderTop:SetHeight(1)

    bar.borderBottom = bar:CreateTexture(nil, "OVERLAY")
    bar.borderBottom:SetColorTexture(0.55, 0.55, 0.55, 0.9)
    bar.borderBottom:SetPoint("BOTTOMLEFT")
    bar.borderBottom:SetPoint("BOTTOMRIGHT")
    bar.borderBottom:SetHeight(1)

    bar.borderLeft = bar:CreateTexture(nil, "OVERLAY")
    bar.borderLeft:SetColorTexture(0.55, 0.55, 0.55, 0.9)
    bar.borderLeft:SetPoint("TOPLEFT")
    bar.borderLeft:SetPoint("BOTTOMLEFT")
    bar.borderLeft:SetWidth(1)

    bar.borderRight = bar:CreateTexture(nil, "OVERLAY")
    bar.borderRight:SetColorTexture(0.55, 0.55, 0.55, 0.9)
    bar.borderRight:SetPoint("TOPRIGHT")
    bar.borderRight:SetPoint("BOTTOMRIGHT")
    bar.borderRight:SetWidth(1)

    -- Text frame is deliberately placed well above the StatusBar's own
    -- texture level so the label is always visible ON the bar.
    bar.textFrame = CreateFrame("Frame", nil, bar)
    bar.textFrame:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    bar.textFrame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    bar.textFrame:SetFrameStrata("HIGH")
    bar.textFrame:SetFrameLevel(100)

    bar.text = bar.textFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.text:SetPoint("CENTER", bar.textFrame, "CENTER", 0, 0)
    bar.text:SetWidth(math.max(1, db.width - 20))
    bar.text:SetHeight(18)
    bar.text:SetJustifyH("CENTER")
    bar.text:SetJustifyV("MIDDLE")
    bar.text:SetTextColor(1, 1, 1, 1)
    bar.text:SetShadowColor(0, 0, 0, 1)
    bar.text:SetShadowOffset(1, -1)
    bar.text:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    bar.text:SetText("Rested XP")

    -- Horizontal resize handles. Height is always fixed at 18px.
    bar.leftResize = CreateFrame("Button", nil, bar)
    bar.leftResize:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    bar.leftResize:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    bar.leftResize:SetWidth(10)
    bar.leftResize:SetFrameLevel(bar:GetFrameLevel() + 20)

    bar.rightResize = CreateFrame("Button", nil, bar)
    bar.rightResize:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
    bar.rightResize:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    bar.rightResize:SetWidth(10)
    bar.rightResize:SetFrameLevel(bar:GetFrameLevel() + 20)

    -- Visible grab markers so users can see exactly where horizontal
    -- resizing is available. They are only shown while the bar is unlocked.
    bar.leftResize.marker = bar.leftResize:CreateTexture(nil, "OVERLAY")
    bar.leftResize.marker:SetWidth(2)
    bar.leftResize.marker:SetPoint("TOP", bar.leftResize, "TOP", 0, -3)
    bar.leftResize.marker:SetPoint("BOTTOM", bar.leftResize, "BOTTOM", 0, 3)
    bar.leftResize.marker:SetColorTexture(1, 1, 1, 0.85)

    bar.rightResize.marker = bar.rightResize:CreateTexture(nil, "OVERLAY")
    bar.rightResize.marker:SetWidth(2)
    bar.rightResize.marker:SetPoint("TOP", bar.rightResize, "TOP", 0, -3)
    bar.rightResize.marker:SetPoint("BOTTOM", bar.rightResize, "BOTTOM", 0, 3)
    bar.rightResize.marker:SetColorTexture(1, 1, 1, 0.85)

    local function SetResizeHandleVisibility()
        if db.locked then
            bar.leftResize:Hide()
            bar.rightResize:Hide()
        else
            bar.leftResize:Show()
            bar.rightResize:Show()
        end
    end

    bar.UpdateResizeHandles = SetResizeHandleVisibility

    bar.leftResize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not db.locked then
            bar:StartSizing("LEFT")
        end
    end)

    bar.leftResize:SetScript("OnMouseUp", function()
        bar:StopMovingOrSizing()
        ApplyBarWidth(bar:GetWidth() or db.width)
        SavePosition()
    end)

    bar.rightResize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not db.locked then
            bar:StartSizing("RIGHT")
        end
    end)

    bar.rightResize:SetScript("OnMouseUp", function()
        bar:StopMovingOrSizing()
        ApplyBarWidth(bar:GetWidth() or db.width)
        SavePosition()
    end)

    bar.leftResize:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Resize Rested XP Bar")
        GameTooltip:AddLine("Drag this marked edge left/right to change the width.", 1, 1, 1)
        GameTooltip:Show()
    end)

    bar.leftResize:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    bar.rightResize:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Resize Rested XP Bar")
        GameTooltip:AddLine("Drag this marked edge left/right to change the width.", 1, 1, 1)
        GameTooltip:Show()
    end)

    bar.rightResize:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    bar:SetScript("OnSizeChanged", function(self, width)
        if not db then
            return
        end

        -- Force the height back to 22px and prevent width from dropping below
        -- the current text requirement while dragging.
        local minWidth = GetMinimumBarWidth()
        local wantedWidth = width or self:GetWidth() or db.width

        if wantedWidth < minWidth then
            wantedWidth = minWidth
        elseif wantedWidth > 900 then
            wantedWidth = 900
        end

        db.width = math.floor(wantedWidth + 0.5)
        db.height = 18

        if math.abs((self:GetHeight() or 18) - 18) > 0.1
            or math.abs((self:GetWidth() or wantedWidth) - wantedWidth) > 0.1 then
            self:SetSize(wantedWidth, 18)
        end

        if bar.text then
            bar.text:SetWidth(math.max(1, wantedWidth - 20))
            bar.text:SetHeight(18)
        end
    end)

    SetResizeHandleVisibility()

    bar:RegisterForDrag("LeftButton")

    bar:SetScript("OnDragStart", function()
        if not db.locked then
            bar:StartMoving()
        end
    end)

    bar:SetScript("OnDragStop", function()
        bar:StopMovingOrSizing()
        SavePosition()
    end)

    bar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")

        local restedXP, _, restedPercent = GetRestedData()

        GameTooltip:SetText("Rested XP Helper")
        GameTooltip:AddLine(
            string.format("Rested XP: %d (%.1f%% / %d%%)", restedXP, restedPercent, RESTED_CAP_PERCENT),
            1, 1, 1
        )

        if restedPercent >= RESTED_CAP_PERCENT - 0.01 then
            GameTooltip:AddLine("Fully rested.", 0.4, 1, 0.4)
        else
            GameTooltip:AddLine(
                "ETA if resting: " .. FormatDuration(GetRestedETASeconds(restedPercent)),
                0.75, 0.85, 1
            )
        end

        if IsResting() then
            GameTooltip:AddLine("Currently in a resting area.", 0.4, 1, 0.4)
        else
            GameTooltip:AddLine("Not currently in a resting area.", 1, 0.75, 0.25)
        end

        if db.locked then
            GameTooltip:AddLine("Bar locked.", 0.8, 0.8, 0.8)
        else
            GameTooltip:AddLine("Drag to move. Drag either edge to resize width.", 0.8, 0.8, 0.8)
        end

        GameTooltip:AddLine("Type /rested to open settings.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)

    bar:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    UpdateBar()
end

local function ShouldWarnOnLogout()
    if not db.logoutWarning then
        return false
    end

    if IsResting() then
        return false
    end

    if db.dontWarnAtMaxLevel and IsMaxLevel() then
        return false
    end

    if db.dontWarnWhenFull and IsFullyRested() then
        return false
    end

    return true
end

StaticPopupDialogs["RESTED_XP_HELPER_LOGOUT_WARNING"] = {
    text = [[|cff66ccffRested XP|r

Don't forget to log out at an inn or capital city to build up your Rested XP while you're away.

Have a nice break, and see you again soon!]],

    button1 = "OK",

    OnAccept = function()
        -- Informational only.
    end,

    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function HandleLogoutAttempt()
    if not ShouldWarnOnLogout() then
        return
    end

    StaticPopup_Show("RESTED_XP_HELPER_LOGOUT_WARNING")
end

local SetBarDependentOptionsEnabled
local SetLogoutDependentOptionsEnabled

local function CreateCheckbox(parent, label, tooltip, x, y, key, onChanged)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    check:SetChecked(db[key] == true)

    check.text = check:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    check.text:SetPoint("LEFT", check, "RIGHT", 4, 0)
    check.text:SetText(label)

    check:SetScript("OnClick", function(self)
        -- Hard parent/child guards. Even if WoW delivers a click to a disabled
        -- control, child settings cannot change while their parent is off.
        if key == "showRestedXP"
            or key == "showTimeUntilFull"
            or key == "locked"
            or key == "alwaysKeepCentered" then

            if db.showBar ~= true then
                self:SetChecked(db[key] == true)
                return
            end
        end

        if key == "dontWarnWhenFull"
            or key == "dontWarnAtMaxLevel" then

            if db.logoutWarning ~= true then
                self:SetChecked(db[key] == true)
                return
            end
        end

        db[key] = self:GetChecked() and true or false

        if onChanged then
            onChanged(db[key])
        end

        UpdateBar()

        if key == "showBar" and SetBarDependentOptionsEnabled then
            SetBarDependentOptionsEnabled(db.showBar == true)
        end

        if key == "logoutWarning" and SetLogoutDependentOptionsEnabled then
            SetLogoutDependentOptionsEnabled(db.logoutWarning == true)
        end
    end)

    check:SetScript("OnEnter", function(self)
        if tooltip and tooltip ~= "" then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label)
            GameTooltip:AddLine(tooltip, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)

    check:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Keep a registry on both the local section and the main settings
    -- window. The main registry is used for parent/child option behaviour.
    parent.checkboxes = parent.checkboxes or {}
    parent.checkboxes[key] = check

    if settingsFrame then
        settingsFrame.checkboxes = settingsFrame.checkboxes or {}
        settingsFrame.checkboxes[key] = check
    end

    return check
end

local function MakeButton(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button:SetText(text)
    return button
end

SetBarDependentOptionsEnabled = function(enabled)
    if not settingsFrame or not settingsFrame.checkboxes then
        return
    end

    local dependentKeys = {
        "showRestedXP",
        "showTimeUntilFull",
        "locked",
        "alwaysKeepCentered",
    }

    for _, key in ipairs(dependentKeys) do
        local check = settingsFrame.checkboxes[key]

        if check then
            -- Keep the tick stored, but make the option genuinely unavailable
            -- while the Rested XP bar itself is hidden.
            if enabled then
                if check.Enable then
                    check:Enable()
                end
                check:EnableMouse(true)
                check:SetAlpha(1.0)

                if check.text then
                    check.text:SetTextColor(1, 0.82, 0, 1)
                end
            else
                if check.Disable then
                    check:Disable()
                end
                check:EnableMouse(false)
                check:SetAlpha(0.30)

                if check.text then
                    check.text:SetTextColor(0.50, 0.50, 0.50, 1)
                end
            end
        end
    end

    if settingsFrame.resetPositionButton then
        settingsFrame.resetPositionButton:SetEnabled(enabled)
        settingsFrame.resetPositionButton:EnableMouse(enabled)
        settingsFrame.resetPositionButton:SetAlpha(enabled and 1.0 or 0.35)
    end
end

SetLogoutDependentOptionsEnabled = function(enabled)
    if not settingsFrame or not settingsFrame.checkboxes then
        return
    end

    local dependentKeys = {
        "dontWarnWhenFull",
        "dontWarnAtMaxLevel",
    }

    for _, key in ipairs(dependentKeys) do
        local check = settingsFrame.checkboxes[key]

        if check then
            -- Preserve the saved tick, but disable the option while the
            -- master Logout warning option is off.
            if enabled then
                if check.Enable then
                    check:Enable()
                end
                check:EnableMouse(true)
                check:SetAlpha(1.0)

                if check.text then
                    check.text:SetTextColor(1, 0.82, 0, 1)
                end
            else
                if check.Disable then
                    check:Disable()
                end
                check:EnableMouse(false)
                check:SetAlpha(0.30)

                if check.text then
                    check.text:SetTextColor(0.50, 0.50, 0.50, 1)
                end
            end
        end
    end
end

local function RefreshSettings()
    if not settingsFrame or not settingsFrame.checkboxes then
        return
    end

    for key, check in pairs(settingsFrame.checkboxes) do
        if db[key] ~= nil then
            check:SetChecked(db[key] == true)
        end
    end

    SetBarDependentOptionsEnabled(db.showBar == true)
    SetLogoutDependentOptionsEnabled(db.logoutWarning == true)
end

local function CreateSection(parent, titleText, x, y, width, height)
    local section = CreateFrame(
        "Frame",
        nil,
        parent,
        BackdropTemplateMixin and "BackdropTemplate" or nil
    )

    section:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    section:SetSize(width, height)

    if section.SetBackdrop then
        section:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        section:SetBackdropColor(0.035, 0.035, 0.035, 0.98)
        section:SetBackdropBorderColor(0.24, 0.24, 0.24, 1)
    else
        local bg = section:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.035, 0.035, 0.035, 0.98)
    end

    local title = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText(titleText)

    return section
end

local function CreateSettings()
    if settingsFrame then
        return
    end

    local template = BackdropTemplateMixin and "BackdropTemplate" or nil

    settingsFrame = CreateFrame(
        "Frame",
        "RestedXpHelperSettingsFrame",
        UIParent,
        template
    )

    -- Sized so every control has its own space.
    settingsFrame:SetSize(560, 600)
    settingsFrame:SetPoint("CENTER")
    settingsFrame:SetFrameStrata("DIALOG")
    settingsFrame:SetClampedToScreen(true)
    settingsFrame:EnableMouse(true)
    settingsFrame:SetMovable(true)
    settingsFrame:RegisterForDrag("LeftButton")
    settingsFrame:Hide()

    if settingsFrame.SetBackdrop then
        settingsFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = false,
            edgeSize = 28,
            insets = {
                left = 8,
                right = 8,
                top = 8,
                bottom = 8
            },
        })
        settingsFrame:SetBackdropColor(0.015, 0.015, 0.015, 0.98)
    else
        local bg = settingsFrame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.015, 0.015, 0.015, 0.98)
    end

    settingsFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    settingsFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)

    local title = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Rested XP")

    local subtitle = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
    subtitle:SetText("Rested XP Helper settings")

    -- ABOUT
    local about = CreateSection(settingsFrame, "About Rested XP", 24, -68, 512, 96)

    local helpText = about:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    helpText:SetPoint("TOPLEFT", 14, -34)
    helpText:SetWidth(475)
    helpText:SetJustifyH("LEFT")
    helpText:SetText(
        "Rested XP builds fastest while logged out in an inn or capital city. The bar estimates the time remaining until the 150% rested cap."
    )

    local helpLink = CreateFrame("Button", nil, about)
    helpLink:SetPoint("BOTTOMLEFT", 14, 10)
    helpLink:SetSize(460, 18)

    helpLink.text = helpLink:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    helpLink.text:SetPoint("LEFT", 0, 0)
    helpLink.text:SetText("|cff4da6ffBlizzard: Rested Experience Help|r")
    helpLink.text:SetJustifyH("LEFT")

    helpLink:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Blizzard Rested XP Help")
        GameTooltip:AddLine(
            "Click to place the official Blizzard URL into chat so you can copy it.",
            1, 1, 1, true
        )
        GameTooltip:Show()
    end)

    helpLink:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    helpLink:SetScript("OnClick", function()
        ChatFrame_OpenChat(BLIZZARD_RESTED_XP_URL)
    end)

    -- DISPLAY
    -- Display panel sized to contain all controls without touching Logout.
    local display = CreateSection(settingsFrame, "Display", 24, -176, 512, 225)

    CreateCheckbox(
        display,
        "Show Rested XP bar",
        "Master switch for the on-screen Rested XP bar.",
        14, -38, "showBar",
        function()
            SetBarDependentOptionsEnabled(db.showBar == true)
        end
    )

    CreateCheckbox(
        display,
        "Show rested XP %",
        "Adds the current Rested XP percentage to the bar.",
        14, -68, "showRestedXP"
    )

    CreateCheckbox(
        display,
        "Show time until full",
        "Adds the ETA to the 150% rested cap, or FULLY RESTED when capped.",
        14, -98, "showTimeUntilFull"
    )

    CreateCheckbox(
        display,
        "Lock bar",
        "Prevents the bar from being moved or resized accidentally.",
        14, -128, "locked",
        function()
            UpdateResizeGrip()
        end
    )

    CreateCheckbox(
        display,
        "Keep horizontally centered",
        "Keeps the bar centered left-to-right while still allowing you to move it up or down.",
        14, -158, "alwaysKeepCentered",
        function()
            if db.alwaysKeepCentered then
                db.y = math.floor(GetBarCenterYOffset() + 0.5)
                ApplyCenteredPosition()
            end
        end
    )

    local reset = MakeButton(display, "Reset Position", 140, 22)
    reset:SetPoint("BOTTOMLEFT", 14, 12)
    settingsFrame.resetPositionButton = reset

    reset:SetScript("OnClick", function()
        ResetBarPosition()
        RefreshSettings()
    end)

    reset:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Reset Position")
        GameTooltip:AddLine(
            "Moves the bar back to its default starting position.",
            1, 1, 1, true
        )
        GameTooltip:Show()
    end)

    reset:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- LOGOUT REMINDER
    -- Logout panel sits below Display with a clear gap.
    local logout = CreateSection(settingsFrame, "Logout Reminder", 24, -414, 512, 126)

    CreateCheckbox(
        logout,
        "Logout warning",
        "Shows a friendly reminder when logging out outside an inn or capital city.",
        14, -38, "logoutWarning",
        function()
            SetLogoutDependentOptionsEnabled(db.logoutWarning == true)
        end
    )

    CreateCheckbox(
        logout,
        "Don't warn when Rested XP is full",
        "Skips the reminder when your Rested XP is already at the 150% maximum.",
        14, -66, "dontWarnWhenFull"
    )

    CreateCheckbox(
        logout,
        "Don't warn at max level",
        "Skips the reminder when this character has reached the maximum level.",
        14, -94, "dontWarnAtMaxLevel"
    )

    local tip = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tip:SetPoint("BOTTOMLEFT", 28, 18)
    tip:SetText("|cff888888Tip: hover over any option for more information.|r")

    local close = MakeButton(settingsFrame, "Close", 92, 22)
    close:SetPoint("BOTTOMRIGHT", -24, 14)
    close:SetScript("OnClick", function()
        settingsFrame:Hide()
    end)

    SetBarDependentOptionsEnabled(db.showBar == true)
    SetLogoutDependentOptionsEnabled(db.logoutWarning == true)
end

local function ToggleSettings()
    if not settingsFrame then
        CreateSettings()
    end

    RefreshSettings()

    if settingsFrame:IsShown() then
        settingsFrame:Hide()
    else
        settingsFrame:Show()
    end
end

SLASH_RESTEDXPHELPER1 = "/rested"
SLASH_RESTEDXPHELPER2 = "/restxp"

SlashCmdList["RESTEDXPHELPER"] = function()
    ToggleSettings()
end

local events = CreateFrame("Frame")

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_XP_UPDATE")
events:RegisterEvent("UPDATE_EXHAUSTION")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("PLAYER_UPDATE_RESTING")
events:RegisterEvent("PLAYER_CAMPING")
events:RegisterEvent("PLAYER_QUITING")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then
            return
        end

        RestedXpHelperDB = RestedXpHelperDB or {}
        db = RestedXpHelperDB

        CopyDefaults(DEFAULTS, db)

        if db.showRestedXP == nil then
            db.showRestedXP = true
        end

        if db.showTimeUntilFull == nil then
            db.showTimeUntilFull = true
        end

        if db.showRestedXP == nil then
            db.showRestedXP = true
        end

        if db.showTimeUntilFull == nil then
            db.showTimeUntilFull = true
        end

        -- Keep the bar at its standard starting width and fixed height.
        db.width = 450
        db.height = 18

        -- Compatibility migration for an older development build:
        -- that version forced the bar to TOP / 0 / -20 for everyone.
        -- If that exact saved position is still present, restore the original
        -- default position. Any other custom position is preserved.
        if db.point == "TOP"
            and db.relativePoint == "TOP"
            and (db.x or 0) == 0
            and (db.y or 0) == -20 then

            db.point = "CENTER"
            db.relativePoint = "CENTER"
            db.x = 0
            db.y = -250
        end

        -- Remove old setting from previous versions if present.
        db.showCurrentXP = nil

    elseif event == "PLAYER_LOGIN" then
        if not db then
            RestedXpHelperDB = RestedXpHelperDB or {}
            db = RestedXpHelperDB
            CopyDefaults(DEFAULTS, db)
        end

        db.height = 18

        if db.showRestedXP == nil then
            db.showRestedXP = true
        end

        if db.showTimeUntilFull == nil then
            db.showTimeUntilFull = true
        end

        CreateBar()
        CreateSettings()
        UpdateBar()
        PrintLoadedMessage()

    elseif event == "PLAYER_CAMPING" or event == "PLAYER_QUITING" then
        HandleLogoutAttempt()

    else
        UpdateBar()
    end
end)