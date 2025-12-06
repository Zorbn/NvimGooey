local ffi = require("ffi")
local C = ffi.C
local msgpack = require("luajit-msgpack-pure")

ffi.cdef[[
typedef unsigned int   uint32_t;
typedef int            pid_t;
typedef long ssize_t;

int pipe(int pipefd[2]);
int dup2(int oldfd, int newfd);
pid_t fork(void);
int execvp(const char *file, char *const argv[]);
int close(int fd);
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int fcntl(int fd, int cmd, ...);

static const int O_NONBLOCK = 0x0004; // Different on Linux, this is for Mac
static const int F_SETFL   = 4;
static const int F_GETFL   = 3;

void _exit(int status);
]]

local function spawn(cmd, args)
    args = args or {}

    local argv = ffi.new("char*[?]", #args + 2)
    argv[0] = ffi.new("char[?]", #cmd+1, cmd)
    for i=1,#args do
        argv[i] = ffi.new("char[?]", #args[i]+1, args[i])
    end
    argv[#args+1] = nil

    local child_stdin  = ffi.new("int[2]")
    local child_stdout = ffi.new("int[2]")

    assert(C.pipe(child_stdin) == 0)
    assert(C.pipe(child_stdout) == 0)

    local pid = C.fork()
    assert(pid >= 0)

    if pid == 0 then
        C.close(child_stdin[1])
        C.close(child_stdout[0])

        C.dup2(child_stdin[0], 0)
        C.dup2(child_stdout[1], 1)

        C.close(child_stdin[0])
        C.close(child_stdout[1])

        C.execvp(cmd, argv)
        C._exit(1)
    end

    C.close(child_stdin[0])
    C.close(child_stdout[1])

    C.fcntl(child_stdout[0], C.F_SETFL, ffi.new("int", C.O_NONBLOCK))

    return {
        pid = pid,
        stdin  = child_stdin[1],
        stdout = child_stdout[0]
    }
end

local buf_len = 4096
local buf = ffi.new("char[?]", buf_len)

local function read_nonblocking(fd)
    local n = C.read(fd, buf, buf_len)

    if n < 0 then return nil end

    return ffi.string(buf, n)
end

local function write_to(fd, data)
    return tonumber(C.write(fd, data, #data))
end

local proc = spawn("nvim", { "--embed" })

local response = ""

local visual_grids = {}
local grids = {}
local grid_cursors = {}
local default_foreground
local default_background
local hl_defs = { [0] = {} }

function resize_grid(index, width, height)
    visual_grids[index] = {}
    grids[index] = {}

    for y = 1, height do
        grids[index][y] = {}
        visual_grids[index][y] = { chunks = {}, dirty = true }

        for x = 1, width do
            grids[index][y][x] = {
                text = " ",
                hl_id = 0,
            }
        end
    end
end

function clear_grid(index)
    if not grids[index] or #grids[index] < 1 then return end

    resize_grid(index, #grids[index][1], #grids[index])
end

local function pprint_table(table, depth)
    depth = depth or 0

    local indentation = ("\t"):rep(depth)
    local inner_indentation = ("\t"):rep(depth + 1)

    print("{")

    for key, value in pairs(table) do
        io.write(inner_indentation .. key .. " = ")

        local value_type = type(value)

        if value_type == "table" then
            pprint_table(value, depth + 1)
        elseif value_type == "string" then
            io.write('"' .. value .. '"')
        else
            io.write(tostring(value))
        end

        print(",")
    end

    io.write(indentation .. "}")
end

local function pprint(...)
    for _, value in pairs({ ... }) do
        if type(value) == "table" then
            pprint_table(value)
        else
            io.write(tostring(value))
        end
    end

    print()
end

local redraw_event_handlers = {
    ["grid_resize"] = function(data)
        resize_grid(data[1], data[2], data[3])
    end,
    ["grid_clear"] = function(data)
        clear_grid(data[1])
    end,
    ["grid_line"] = function(data)
        local grid_index = data[1]
        local y = data[2] + 1
        local x_start = data[3] + 1
        local cells = data[4]

        if y <= #visual_grids[grid_index] then
            visual_grids[grid_index][y].dirty = true
        end

        local grid = grids[grid_index]

        local x = x_start
        local hl_id

        for _, cell in ipairs(cells) do
            local count = cell[3] or 1
            hl_id = cell[2] or hl_id

            for i = 1, count do
                grid[y][x] = grid[y][x] or {}
                grid[y][x].text = cell[1]
                grid[y][x].hl_id = hl_id

                x = x + 1
            end
        end
    end,
    ["grid_scroll"] = function(data)
        local grid_index = data[1]
        local top = data[2] + 1
        local bottom = data[3]
        local left = data[4] + 1
        local right = data[5]
        local rows = data[6]

        local grid = grids[grid_index]
        local visual_grid = visual_grids[grid_index]

        local start = (rows < 0 and bottom or top) + rows
        local finish = rows < 0 and top or bottom
        local step = rows < 0 and -1 or 1

        for y = start, finish, step do
            visual_grid[y - rows].dirty = true

            for x = left, right do
                local dst_cell = grid[y - rows][x]
                local src_cell = grid[y][x]

                dst_cell.text = src_cell.text
                dst_cell.hl_id = src_cell.hl_id
            end
        end
    end,
    ["grid_cursor_goto"] = function(data)
        grid_cursors[data[1]] = { y = data[2], x = data[3] }
    end,
    ["flush"] = function(data)
        for grid_index, grid in ipairs(grids) do
            local visual_grid = visual_grids[grid_index]

            for y = 1, #grid do
                if visual_grid[y].dirty then
                    visual_grid[y].dirty = false
                    visual_grid[y].chunks = {}

                    local chunks = visual_grid[y].chunks
                    local last_hl_id

                    for x = 1, #grid[y] do
                        if grid[y][x].hl_id ~= last_hl_id then
                            table.insert(chunks, {
                                text = grid[y][x].text,
                                hl_id = grid[y][x].hl_id,
                            })

                            last_hl_id = grid[y][x].hl_id
                        else
                            local chunk = chunks[#chunks]
                            chunk.text = chunk.text .. grid[y][x].text
                        end
                    end
                end
            end
        end
    end,
    ["default_colors_set"] = function(data)
        default_foreground = data[1]
        default_background = data[2]
    end,
    ["hl_attr_define"] = function(data)
        local id = data[1]
        local rgb_attr = data[2]

        hl_defs[id] = rgb_attr
    end,
}

local notification_handlers = {
    ["redraw"] = function(data)
        for _, event in pairs(data) do
            local handler = redraw_event_handlers[event[1]]

            if handler then
                for i = 2, #event do
                    handler(event[i])
                end
            end
        end
    end,
}

local dpi_scale
local font, font_bold
local line_height
local em_width
local window_width, window_height

function love.load()
    dpi_scale = love.window.getDPIScale()

    local font_size = 16 * love.window.getDPIScale()

    font = love.graphics.newFont("font.ttf", font_size, "normal", 1)
    font_bold = love.graphics.newFont("font-bold.ttf", font_size, "normal", 1)

    love.graphics.setFont(font)

    line_height = font:getHeight()
    em_width = font:getWidth("M")

    love.keyboard.setKeyRepeat(true)

    window_width = love.graphics.getWidth() * dpi_scale
    window_height = love.graphics.getHeight() * dpi_scale

    local width = math.floor(window_width / em_width)
    local height = math.floor(window_height / line_height)

    local msg = msgpack.pack({ 2, "nvim_ui_attach", { width, height, { ["ext_linegrid"] = true } } })

    write_to(proc.stdin, msg)
end

function love.textinput(text)
    local msg = msgpack.pack({ 2, "nvim_input", { text } })

    write_to(proc.stdin, msg)
end

local nvim_keycodes = {
    ["escape"] = "esc",
    ["return"] = "return",
    ["up"] = "up",
    ["down"] = "down",
    ["left"] = "left",
    ["right"] = "right",
    ["backspace"] = "bs",
    ["tab"] = "tab",
}

function love.keypressed(key)
    local keycode = nvim_keycodes[key]
    local has_ctrl = love.keyboard.isDown("lctrl", "rctrl")

    if not keycode and not has_ctrl then return end

    local input = keycode or key

    if has_ctrl then
        input = "C-" .. input
    end

    local msg = msgpack.pack({ 2, "nvim_input", { "<" .. input .. ">" } })

    write_to(proc.stdin, msg)
end

function love.resize(new_window_width, new_window_height)
    window_width = new_window_width * dpi_scale
    window_height = new_window_height * dpi_scale

    local width = math.floor(window_width / em_width)
    local height = math.floor(window_height / line_height)

    local msg = msgpack.pack({ 2, "nvim_ui_try_resize", { width, height } })

    write_to(proc.stdin, msg)
end

function love.update(dt)
    local out = read_nonblocking(proc.stdout)

    if out then
        if #out == 0 then
            love.event.quit()
        end

        response = response .. out

        local offset

        repeat
            offset, msg = msgpack.unpack(response)

            if offset then
                response = response:sub(offset + 1)

                if msg[1] == 2 then
                    local handler = notification_handlers[msg[2]]

                    if handler then
                        handler(msg[3])
                    end
                end
            end
        until not offset
    end
end

function set_color_rgb(rgb)
    local r = bit.rshift(rgb, 16) / 0xff
    local g = bit.band(bit.rshift(rgb, 8), 0xff) / 0xff
    local b = bit.band(rgb, 0xff) / 0xff

    love.graphics.setColor(r, g, b)
end

function love.draw()
    love.graphics.scale(1 / dpi_scale, 1 / dpi_scale)

    for grid_index, visual_grid in ipairs(visual_grids) do
        for i = 1, #visual_grid do
            local y = (i - 1) * line_height
            local x = 0

            for chunk_index, chunk in ipairs(visual_grid[i].chunks) do
                local hl_attr = hl_defs[chunk.hl_id]
                local foreground = hl_attr.foreground or default_foreground
                local background = hl_attr.background or default_background

                if hl_attr.reverse then
                    foreground, background = background, foreground
                end

                if hl_attr.bold then
                    love.graphics.setFont(font_bold)
                else
                    love.graphics.setFont(font)
                end

                local width = font:getWidth(chunk.text)
                local height = line_height

                if i == #visual_grid then
                    height = window_height - y
                end

                if chunk_index == #visual_grid[i].chunks then
                    width = window_width - x
                end

                set_color_rgb(background)
                love.graphics.rectangle("fill", x, y, width, height)

                set_color_rgb(foreground)
                love.graphics.print(chunk.text, x, y)

                x = x + width
            end
        end

        local grid = grids[grid_index]
        local grid_cursor = grid_cursors[grid_index]

        if grid_cursor then
            local x = grid_cursor.x * em_width
            local y = grid_cursor.y * line_height

            set_color_rgb(default_foreground)
            love.graphics.rectangle("fill", x, y, em_width, line_height)

            set_color_rgb(default_background)
            love.graphics.print(grid[grid_cursor.y + 1][grid_cursor.x + 1].text, x, y)
        end
    end
end
