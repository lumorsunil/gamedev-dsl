nnoremap <F5> <Cmd>OverseerRunCmd zig build run -Dtarget=x86_64-windows<CR>
nnoremap <F7> <Cmd>below new \| execute "term runic build-web.rn && cd zig-out/web && vite . --open" \| normal a<CR>
nnoremap <F10> <Cmd>below new \| execute "term runic pack-web.rn" \| normal a<CR>

lua <<EOF
function create_component(ctx)
    -- local name = vim.call("input", "name (kebab-case): ")
    local name = ctx.args
    local base_name = name .. ".zig"
    local file_name = "src/components/" .. base_name
    local type_name = kebab_to_pascal(name)
    local field_name = kebab_to_snake(name)

    if vim.fn.filereadable(file_name) == 1 then
        vim.cmd("e " .. file_name)
        return
    end

    vim.cmd("e " .. file_name)
    vim.call("append", 0, {
        'const Game = @import("../game.zig").Game;',
        '',
        'pub const ' .. type_name .. ' = struct {',
        '    enabled: bool = true,',
        '',
        '    pub fn init() @This() {',
        '        return .{};',
        '    }',
        '};',
    })
    vim.cmd("w")

    vim.cmd("e src/components.zig")
    vim.call("append", 0, "pub const " .. type_name .. ' = @import("components/' .. base_name .. '").' .. type_name .. ";")
    vim.cmd("sort")
    vim.cmd("w")
    vim.cmd("bd")

    vim.cmd("e src/component-enum.zig")
    vim.call("append", 4, "    " .. field_name .. ": ?Game.C." .. type_name .. " = null,")
    vim.cmd("5;/^$/-1sort | noh")
    vim.cmd("w")
    vim.cmd("bd")

    vim.cmd("e " .. file_name)
    vim.cmd("4")
end

function create_system(ctx)
    -- local name = vim.call("input", "name (kebab-case): ")
    local name = ctx.args
    local base_name = name .. ".zig"
    local file_name = "src/systems/" .. base_name
    local type_name = kebab_to_pascal(name)

    if vim.fn.filereadable(file_name) == 1 then
        vim.cmd("e " .. file_name)
        return
    end

    vim.cmd("e " .. file_name)
    vim.call("append", 0, {
        'const Game = @import("../game.zig").Game;',
        '',
        'pub const ' .. type_name .. ' = struct {',
        '    enabled: bool = true,',
        '',
        '    pub fn init() @This() {',
        '        return .{};',
        '    }',
        '',
        '    pub fn update(_: *@This(), game: *Game) void {',
        '        _ = game;',
        '    }',
        '};',
    })
    vim.cmd("w")

    vim.cmd("e src/systems.zig")
    vim.call("append", 0, "pub const " .. type_name .. ' = @import("systems/' .. base_name .. '").' .. type_name .. ";")
    vim.cmd("sort")
    vim.cmd("w")
    vim.cmd("bd")

    vim.cmd("e src/setup-systems.zig")
    vim.call("append", 3, "game.addSingleton(Game.S." .. type_name .. ".init());")
    vim.cmd("4,/^}$/-1sort | noh")
    vim.cmd("w")
    vim.cmd("bd")

    vim.cmd("e " .. file_name)
    vim.cmd("11")
end

function kebab_to_pascal(s)
    local res = s:gsub("-(%a)", function(c)
        return c:upper()
    end)

    res = res:gsub("^%a", function(c)
        return c:upper()
    end)

    return res
end

function kebab_to_snake(s)
    return s:gsub("-", "_")
end

vim.api.nvim_create_user_command("CreateComponent", create_component, {nargs=1})
vim.api.nvim_create_user_command("CreateSystem", create_system, {nargs=1})
EOF
