local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local GetText = require("gettext")
local C_ = _.pgettext
local PLUGIN_L10N_FILE = "koreader.mo"
local LOADED_FLAG = "__todo_i18n_loaded"
local PLUGIN_ROOT = (debug.getinfo(1, "S").source or ""):match("@?(.*/)")

local function currentLocale()
    local locale = G_reader_settings and G_reader_settings:readSetting("language") or _.current_lang
    locale = tostring(locale or "")
    locale = locale:match("^([^:]+)") or locale
    locale = locale:gsub("%..*$", "")
    return locale
end

local function loadPluginTranslations()
    if _G[LOADED_FLAG] then
        return
    end

    if not PLUGIN_ROOT then
        return
    end

    local locale = currentLocale()
    if locale == "" or locale == "C" then
        return
    end

    _G[LOADED_FLAG] = true

    local function tryLoad(lang)
        if lang == "" then
            return false
        end
        local mo_path = string.format("%sl10n/%s/%s", PLUGIN_ROOT, lang, PLUGIN_L10N_FILE)
        local ok, loaded = pcall(function()
            return GetText.loadMO(mo_path)
        end)
        return ok and loaded == true
    end

    if tryLoad(locale) then
        return
    end

    local lang_only = locale:match("^([A-Za-z][A-Za-z])[_%-]")
    if lang_only and tryLoad(lang_only) then
        return
    end

    if locale:lower():match("^zh") then
        tryLoad("zh_CN")
    end
end

local function trim(text)
    text = tostring(text or "")
    return text:match("^%s*(.-)%s*$")
end

local UTF8_CHAR_PATTERN = "[%z\1-\127\194-\244][\128-\191]*"

local function blackOutText(text)
    text = tostring(text or "")
    return (text:gsub(UTF8_CHAR_PATTERN, function(ch)
        if ch:match("%s") then
            return ch
        end
        return "█"
    end))
end

local function findIndex(t, needle)
    for idx, value in ipairs(t) do
        if value == needle then
            return idx
        end
    end
end

local function ensureAfter(t, target, value)
    if not t or type(t) ~= "table" then
        return
    end
    if findIndex(t, value) then
        return
    end
    local idx = findIndex(t, target)
    if idx then
        table.insert(t, idx + 1, value)
    else
        table.insert(t, value)
    end
end

local Todo = WidgetContainer:extend{
    name = "todo",
    is_doc_only = false,
}

Todo.settings_file = DataStorage:getSettingsDir() .. "/todo.lua"
Todo.sort_asc = "asc"
Todo.sort_desc = "desc"
Todo.setting_items = "items"
Todo.setting_show_incomplete_only = "show_incomplete_only"
Todo.setting_sort_order = "sort_order"
Todo.setting_next_id = "next_id"

function Todo:init()
    loadPluginTranslations()

    self:ensureMenuOrderPlacement()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self.settings = LuaSettings:open(self.settings_file)

    self.items = self.settings:readSetting(Todo.setting_items, {})
    self.show_incomplete_only = self.settings:readSetting(Todo.setting_show_incomplete_only) and true or false
    self.sort_order = self.settings:readSetting(Todo.setting_sort_order) or Todo.sort_desc
    self.next_id = tonumber(self.settings:readSetting(Todo.setting_next_id)) or 1
    self.todo_menu = nil
    self.edit_dialog = nil

    self:normalizeState()
end

function Todo:ensureMenuOrderPlacement()
    local reader_order = require("ui/elements/reader_menu_order")
    local filemanager_order = require("ui/elements/filemanager_menu_order")
    ensureAfter(reader_order.main, "collections", "todo")
    ensureAfter(filemanager_order.main, "collections", "todo")
end

function Todo:onDispatcherRegisterActions()
    Dispatcher:registerAction("todo_open_list", {
        category = "none",
        event = "TodoOpenList",
        title = C_("Dispatcher action", "Todo: Open list"),
        general = true,
    })
end

function Todo:onTodoOpenList()
    self:showTodoList()
end

function Todo:addToMainMenu(menu_items)
    menu_items.todo = {
        text_func = function()
            return _("Todo")
        end,
        sub_item_table = {
            {
                text_func = function()
                    return _("List")
                end,
                keep_menu_open = true,
                callback = function()
                    self:showTodoList()
                end,
            },
            {
                text_func = function()
                    return _("Hide completed items")
                end,
                checked_func = function()
                    return self.show_incomplete_only
                end,
                keep_menu_open = true,
                callback = function()
                    self.show_incomplete_only = not self.show_incomplete_only
                    self:saveState()
                    self:refreshTodoMenu()
                end,
            },
            {
                text_func = function()
                    return _("Sort order")
                end,
                sub_item_table = {
                    {
                        text_func = function()
                            return _("Ascending")
                        end,
                        keep_menu_open = true,
                        checked_func = function()
                            return self.sort_order == Todo.sort_asc
                        end,
                        callback = function()
                            self:setSortOrder(Todo.sort_asc)
                        end,
                    },
                    {
                        text_func = function()
                            return _("Descending")
                        end,
                        keep_menu_open = true,
                        checked_func = function()
                            return self.sort_order == Todo.sort_desc
                        end,
                        callback = function()
                            self:setSortOrder(Todo.sort_desc)
                        end,
                    },
                },
            },
        },
    }
end

function Todo:getVisibleItems()
    local visible = {}
    for _, item in ipairs(self.items) do
        if not self.show_incomplete_only or not item.done then
            table.insert(visible, item)
        end
    end
    table.sort(visible, function(a, b)
        local aid = tonumber(a.id) or 0
        local bid = tonumber(b.id) or 0
        if aid == bid then
            local act = tonumber(a.created_at) or 0
            local bct = tonumber(b.created_at) or 0
            if self.sort_order == Todo.sort_asc then
                return act < bct
            end
            return act > bct
        end
        if self.sort_order == Todo.sort_asc then
            return aid < bid
        end
        return aid > bid
    end)
    return visible
end

function Todo:setSortOrder(order)
    if order ~= Todo.sort_asc and order ~= Todo.sort_desc then
        return
    end
    if self.sort_order == order then
        return
    end
    self.sort_order = order
    self:saveState()
    self:refreshTodoMenu()
end

function Todo:buildListItemTable()
    local item_table = {}
    local visible = self:getVisibleItems()
    for _, item in ipairs(visible) do
        table.insert(item_table, {
            text = item.done and blackOutText(item.title) or item.title,
            todo_id = item.id,
        })
    end
    return item_table
end

function Todo:showTodoList()
    if self.todo_menu and UIManager:isWidgetShown(self.todo_menu) then
        self:refreshTodoMenu()
        return
    end

    local owner = self
    local menu = Menu:new{
        title = _("Todo"),
        item_table = self:buildListItemTable(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_left_icon = "plus",
    }

    function menu:onLeftButtonTap()
        owner:showEditDialog()
    end

    function menu:onMenuChoice(item)
        owner:onTodoItemChoice(item)
        return true
    end

    function menu:onMenuHold(item)
        owner:onTodoItemHold(item)
        return true
    end

    function menu:onCloseWidget()
        Menu.onCloseWidget(self)
        if owner.todo_menu == self then
            owner.todo_menu = nil
        end
    end

    self.todo_menu = menu
    UIManager:show(menu)
end

function Todo:refreshTodoMenu()
    if not self.todo_menu or not UIManager:isWidgetShown(self.todo_menu) then
        return
    end
    self.todo_menu:switchItemTable(_("Todo"), self:buildListItemTable(), 1)
end

function Todo:onTodoItemChoice(item)
    if not item or not item.todo_id then
        return
    end
    local todo = self:getTodoById(item.todo_id)
    if not todo then
        return
    end
    todo.done = not todo.done
    todo.updated_at = os.time()
    self:saveState()
    self:refreshTodoMenu()
end

function Todo:onTodoItemHold(item)
    if not item or not item.todo_id then
        return
    end
    self:showEditDialog(item.todo_id)
end

function Todo:getTodoById(todo_id)
    for _, item in ipairs(self.items) do
        if item.id == todo_id then
            return item
        end
    end
end

function Todo:showEditDialog(todo_id)
    if self.edit_dialog and UIManager:isWidgetShown(self.edit_dialog) then
        UIManager:close(self.edit_dialog)
    end

    local todo = todo_id and self:getTodoById(todo_id) or nil
    local dialog
    local owner = self

    local button_row = {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                if owner.edit_dialog == dialog then
                    owner.edit_dialog = nil
                end
                UIManager:close(dialog)
            end,
        },
        {
            text = _("Save"),
            is_enter_default = true,
            callback = function()
                owner:saveFromDialog(dialog, todo)
            end,
        },
    }

    if todo then
        table.insert(button_row, 2, {
            text = _("Delete"),
            callback = function()
                owner:deleteTodo(todo.id)
                if owner.edit_dialog == dialog then
                    owner.edit_dialog = nil
                end
                UIManager:close(dialog)
                owner:refreshTodoMenu()
            end,
        })
    end

    dialog = MultiInputDialog:new{
        title = todo and _("Edit todo") or _("Create todo"),
        fields = {
            {
                text = todo and todo.title or "",
                hint = _("Title (required)"),
            },
            {
                text = todo and (todo.content or "") or "",
                hint = _("Content (optional)"),
            },
        },
        buttons = { button_row },
    }

    self.edit_dialog = dialog
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Todo:saveFromDialog(dialog, todo)
    local fields = dialog:getFields()
    local title = trim(fields[1])
    local content = trim(fields[2])

    if title == "" then
        UIManager:show(InfoMessage:new{
            text = _("Title cannot be empty."),
            timeout = 2,
        })
        return
    end

    if content == "" then
        content = nil
    end

    local now = os.time()
    if todo then
        todo.title = title
        todo.content = content
        todo.updated_at = now
    else
        table.insert(self.items, 1, {
            id = self.next_id,
            title = title,
            content = content,
            done = false,
            created_at = now,
            updated_at = now,
        })
        self.next_id = self.next_id + 1
    end

    self:saveState()
    if self.edit_dialog == dialog then
        self.edit_dialog = nil
    end
    UIManager:close(dialog)
    self:refreshTodoMenu()
end

function Todo:deleteTodo(todo_id)
    for idx, item in ipairs(self.items) do
        if item.id == todo_id then
            table.remove(self.items, idx)
            break
        end
    end
    self:saveState()
end

function Todo:saveState()
    self.settings:saveSetting(Todo.setting_items, self.items)
    self.settings:saveSetting(Todo.setting_show_incomplete_only, self.show_incomplete_only)
    self.settings:saveSetting(Todo.setting_sort_order, self.sort_order)
    self.settings:saveSetting(Todo.setting_next_id, self.next_id)
    self.settings:flush()
end

function Todo:normalizeState()
    local changed = false
    if type(self.items) ~= "table" then
        self.items = {}
        changed = true
    end

    local normalized = {}
    local max_id = 0
    local seen_ids = {}
    for _, item in ipairs(self.items) do
        if type(item) == "table" then
            local title = trim(item.title)
            if title ~= "" then
                local raw_id = item.id
                local todo_id = tonumber(raw_id) or 0
                if todo_id ~= raw_id then
                    changed = true
                end
                if todo_id <= 0 or seen_ids[todo_id] then
                    todo_id = max_id + 1
                    changed = true
                end
                if todo_id > max_id then
                    max_id = todo_id
                end
                seen_ids[todo_id] = true
                local raw_created_at = item.created_at
                local raw_updated_at = item.updated_at
                local created_at = tonumber(raw_created_at)
                local updated_at = tonumber(raw_updated_at)
                if created_at == nil then
                    created_at = os.time()
                    changed = true
                elseif created_at ~= raw_created_at then
                    changed = true
                end
                if updated_at == nil then
                    updated_at = os.time()
                    changed = true
                elseif updated_at ~= raw_updated_at then
                    changed = true
                end
                local done = item.done == true
                if item.done ~= done then
                    changed = true
                end
                local content = type(item.content) == "string" and item.content or nil
                if item.content ~= content then
                    changed = true
                end
                if title ~= item.title then
                    changed = true
                end
                table.insert(normalized, {
                    id = todo_id,
                    title = title,
                    content = content,
                    done = done,
                    created_at = created_at,
                    updated_at = updated_at,
                })
            else
                changed = true
            end
        else
            changed = true
        end
    end

    self.items = normalized
    if type(self.next_id) ~= "number" or self.next_id <= max_id then
        self.next_id = max_id + 1
        changed = true
    end
    local normalized_show_incomplete_only = self.show_incomplete_only and true or false
    if self.show_incomplete_only ~= normalized_show_incomplete_only then
        changed = true
    end
    self.show_incomplete_only = normalized_show_incomplete_only
    if self.sort_order ~= Todo.sort_asc and self.sort_order ~= Todo.sort_desc then
        self.sort_order = Todo.sort_desc
        changed = true
    end
    if changed then
        self:saveState()
    end
end

function Todo:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return Todo
