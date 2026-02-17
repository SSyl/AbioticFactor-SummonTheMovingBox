--[[
============================================================================
ConfigUtil - Configuration Schema Validation
============================================================================

Schema-based config validation with automatic type checking, range validation,
and default value substitution. Supports boolean, number, string, and color types.

API:
- ValidateFromSchema(userConfig, schema, logFunc) -> validatedConfig
- ValidateBoolean(value, default, logFunc, fieldName) -> boolean
- ValidateNumber(value, default, min, max, logFunc, fieldName) -> number
- ValidateString(value, default, minLength, maxLength, trim, logFunc, fieldName) -> string
]]

local ConfigUtil = {}

-- ============================================================
-- GENERIC VALIDATORS
-- ============================================================

function ConfigUtil.ValidateBoolean(value, default, logFunc, fieldName)
    if type(value) ~= "boolean" then
        if value ~= nil and logFunc and fieldName then
            logFunc.Warning("Invalid %s (must be boolean), using %s", fieldName, tostring(default))
        end
        return default
    end
    return value
end

function ConfigUtil.ValidateNumber(value, default, min, max, logFunc, fieldName)
    if type(value) ~= "number" then
        if value ~= nil and logFunc and fieldName then
            logFunc.Warning("Invalid %s (must be number), using %s", fieldName, tostring(default))
        end
        return default
    end

    if (min and value < min) or (max and value > max) then
        if logFunc and fieldName then
            local bounds = ""
            if min and max then
                bounds = string.format(" (must be %s-%s)", min, max)
            elseif min then
                bounds = string.format(" (must be >= %s)", min)
            elseif max then
                bounds = string.format(" (must be <= %s)", max)
            end
            logFunc.Warning("Invalid %s%s, using %s", fieldName, bounds, tostring(default))
        end
        return default
    end

    return value
end

function ConfigUtil.ValidateString(value, default, minLength, maxLength, trim, logFunc, fieldName)
    if type(value) ~= "string" then
        if value ~= nil and logFunc and fieldName then
            logFunc.Warning("Invalid %s (must be string), using %s", fieldName, tostring(default))
        end
        return default
    end

    value = value:match("^%s*(.-)%s*$")

    if maxLength and #value > maxLength then
        if trim then
            local trimmed = value:sub(1, maxLength)
            if logFunc and fieldName then
                logFunc.Warning("%s exceeded %d chars, trimmed", fieldName, maxLength)
            end
            return trimmed
        else
            if logFunc and fieldName then
                logFunc.Warning("%s exceeded %d chars, using default", fieldName, maxLength)
            end
            return default
        end
    end

    if minLength and #value < minLength then
        if logFunc and fieldName then
            logFunc.Warning("%s shorter than %d chars, using default", fieldName, minLength)
        end
        return default
    end

    return value
end

-- ============================================================
-- SCHEMA PROCESSOR
-- ============================================================

local function getValueAtPath(tbl, path)
    local current = tbl
    for segment in path:gmatch("[^%.]+") do
        if type(current) ~= "table" then return nil end
        current = current[segment]
    end
    return current
end

local function setValueAtPath(tbl, path, value)
    local segments = {}
    for segment in path:gmatch("[^%.]+") do
        table.insert(segments, segment)
    end

    local current = tbl
    for i = 1, #segments - 1 do
        local segment = segments[i]
        if current[segment] == nil then
            current[segment] = {}
        end
        current = current[segment]
    end

    current[segments[#segments]] = value
end

function ConfigUtil.ValidateFromSchema(userConfig, schema, logFunc)
    local config = userConfig or {}

    for _, entry in ipairs(schema) do
        local path = entry.path
        local entryType = entry.type
        local default = entry.default
        local value = getValueAtPath(config, path)

        local validated
        if entryType == "boolean" then
            validated = ConfigUtil.ValidateBoolean(value, default, logFunc, path)
        elseif entryType == "number" then
            validated = ConfigUtil.ValidateNumber(value, default, entry.min, entry.max, logFunc, path)
        elseif entryType == "string" then
            validated = ConfigUtil.ValidateString(value, default, entry.min, entry.max, entry.trim, logFunc, path)
        else
            validated = value or default
        end

        setValueAtPath(config, path, validated)
    end

    return config
end

return ConfigUtil
