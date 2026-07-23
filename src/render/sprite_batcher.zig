//! Sprite batcher — batches 2D sprites for efficient rendering.
//!
//! Collects sprites and renders them in a single draw call.
//! Supports tinting, rotation, and layer ordering.

const std = @import("std");
const gl = @import("gl.zig");
const Shader = @import("Shader.zig").Shader;
const Texture = @import("Texture.zig").Texture;
const Camera = @import("Camera.zig").Camera;

/// Maximum number of sprites per batch flush. Large enough to hold a whole
/// 1024×1024 map's worth of trees/rocks (each with a shadow) in one scene
/// batch. The batcher auto-flushes when full (see `add`), so this is a
/// throughput hint, not a hard correctness cap.
pub const MAX_SPRITES: usize = 65536;
pub const MAX_VERTICES: usize = MAX_SPRITES * 4;
pub const MAX_INDICES: usize = MAX_SPRITES * 6;

/// A single sprite instance to render.
pub const SpriteInstance = struct {
    x: f32, y: f32,
    width: f32, height: f32,
    u: f32, v: f32,
    uw: f32, vh: f32,
    r: f32 = 1.0, g: f32 = 1.0, b: f32 = 1.0, a: f32 = 1.0,
};

/// Vertex structure for sprite rendering.
pub const SpriteVertex = packed struct {
    x: f32, y: f32,
    u: f32, v: f32,
    r: f32, g: f32, b: f32, a: f32,
};

/// Batches sprites and renders them efficiently.
pub const SpriteBatcher = struct {
    allocator: std.mem.Allocator,
    vertices: []SpriteVertex = &.{},
    indices: []u32 = &.{},
    sprite_count: usize = 0,
    vbo: gl.GLuint = 0,
    ibo: gl.GLuint = 0,
    gl_initialized: bool = false,

    /// Auto-flush state. When non-null, `add`/`addTexturedQuad`/`addRawQuad`
    /// automatically flush (draw + reset) when the buffer is full instead of
    /// silently dropping sprites. Set via `setAutoFlush` before `begin`.
    flush_fn: ?*const fn (*SpriteBatcher) void = null,
    flush_shader: ?*Shader = null,
    flush_texture: ?*Texture = null,
    flush_camera: ?*Camera = null,

    pub fn init(allocator: std.mem.Allocator) SpriteBatcher {
        return .{ .allocator = allocator, .indices = &.{} };
    }

    pub fn deinit(self: *SpriteBatcher) void {
        if (self.gl_initialized) {
            var bufs = [_]gl.GLuint{ self.vbo, self.ibo };
            gl.deleteBuffers(2, &bufs[0]);
        }
        if (self.vertices.len > 0) self.allocator.free(self.vertices);
        if (self.indices.len > 0) self.allocator.free(self.indices);
    }

    pub fn initGL(self: *SpriteBatcher) !void {
        self.vertices = try self.allocator.alloc(SpriteVertex, MAX_VERTICES);
        self.indices = try self.allocator.alloc(u32, MAX_INDICES);
        for (0..MAX_SPRITES) |i| {
            const vi: u32 = @intCast(i * 4);
            const ii = i * 6;
            self.indices[ii + 0] = vi + 0;
            self.indices[ii + 1] = vi + 1;
            self.indices[ii + 2] = vi + 2;
            self.indices[ii + 3] = vi + 0;
            self.indices[ii + 4] = vi + 2;
            self.indices[ii + 5] = vi + 3;
        }
        self.vbo = gl.genBuffers(1);
        self.ibo = gl.genBuffers(1);
        gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(gl.GL_ARRAY_BUFFER, std.mem.sliceAsBytes(self.vertices[0..0]), gl.GL_DYNAMIC_DRAW);
        gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.ibo);
        gl.bufferData(gl.GL_ELEMENT_ARRAY_BUFFER, std.mem.sliceAsBytes(self.indices[0..MAX_INDICES]), gl.GL_STATIC_DRAW);
        self.gl_initialized = true;
    }

    pub fn begin(self: *SpriteBatcher) void { self.sprite_count = 0; }

    /// Register an auto-flush callback so `add` automatically draws and
    /// resets the batch when `MAX_SPRITES` is reached, instead of silently
    /// dropping sprites. Call this before `begin` with the same shader/
    /// texture/camera that will be passed to `render`.
    pub fn setAutoFlush(
        self: *SpriteBatcher,
        shader: *Shader,
        texture: *Texture,
        camera: *Camera,
    ) void {
        self.flush_shader = shader;
        self.flush_texture = texture;
        self.flush_camera = camera;
        self.flush_fn = &autoFlushImpl;
    }

    fn autoFlushImpl(self: *SpriteBatcher) void {
        const shader = self.flush_shader orelse return;
        const texture = self.flush_texture orelse return;
        const camera = self.flush_camera orelse return;
        self.render(shader, texture, camera);
        // render() resets sprite_count to 0; begin() is not needed again.
    }

    pub fn add(self: *SpriteBatcher, sprite: SpriteInstance) void {
        if (self.vertices.len == 0) return;
        if (self.sprite_count >= MAX_SPRITES) {
            if (self.flush_fn) |f| f(self) else return;
        }
        const vi = self.sprite_count * 4;
        const x0 = sprite.x; const y0 = sprite.y;
        const x1 = sprite.x + sprite.width; const y1 = sprite.y + sprite.height;
        const u = sprite.u; const v = sprite.v;
        const uu = sprite.u + sprite.uw; const vv = sprite.v + sprite.vh;
        self.vertices[vi + 0] = .{ .x = x0, .y = y0, .u = u, .v = v, .r = sprite.r, .g = sprite.g, .b = sprite.b, .a = sprite.a };
        self.vertices[vi + 1] = .{ .x = x1, .y = y0, .u = uu, .v = v, .r = sprite.r, .g = sprite.g, .b = sprite.b, .a = sprite.a };
        self.vertices[vi + 2] = .{ .x = x1, .y = y1, .u = uu, .v = vv, .r = sprite.r, .g = sprite.g, .b = sprite.b, .a = sprite.a };
        self.vertices[vi + 3] = .{ .x = x0, .y = y1, .u = u, .v = vv, .r = sprite.r, .g = sprite.g, .b = sprite.b, .a = sprite.a };
        self.sprite_count += 1;
    }

    /// Add an arbitrary quad with per-vertex positions and per-vertex UV coordinates.
    /// Used for isometric diamonds with proper texture mapping.
    pub fn addTexturedQuad(self: *SpriteBatcher,
        ax: f32, ay: f32, au: f32, av: f32,
        bx: f32, by: f32, bu: f32, bv: f32,
        cx: f32, cy: f32, cu: f32, cv: f32,
        dx: f32, dy: f32, du: f32, dv: f32) void {
        if (self.vertices.len == 0) return;
        if (self.sprite_count >= MAX_SPRITES) {
            if (self.flush_fn) |f| f(self) else return;
        }
        const vi = self.sprite_count * 4;
        self.vertices[vi + 0] = .{ .x = ax, .y = ay, .u = au, .v = av, .r = 1, .g = 1, .b = 1, .a = 1 };
        self.vertices[vi + 1] = .{ .x = bx, .y = by, .u = bu, .v = bv, .r = 1, .g = 1, .b = 1, .a = 1 };
        self.vertices[vi + 2] = .{ .x = cx, .y = cy, .u = cu, .v = cv, .r = 1, .g = 1, .b = 1, .a = 1 };
        self.vertices[vi + 3] = .{ .x = dx, .y = dy, .u = du, .v = dv, .r = 1, .g = 1, .b = 1, .a = 1 };
        self.sprite_count += 1;
    }

    /// Add an arbitrary quad (4 world-space positions, solid color, UV=(0,0)).
    pub fn addRawQuad(self: *SpriteBatcher,
        x0: f32, y0: f32,
        x1: f32, y1: f32,
        x2: f32, y2: f32,
        x3: f32, y3: f32,
        r: f32, g: f32, b: f32, a: f32) void {
        if (self.vertices.len == 0) return;
        if (self.sprite_count >= MAX_SPRITES) {
            if (self.flush_fn) |f| f(self) else return;
        }
        const vi = self.sprite_count * 4;
        self.vertices[vi + 0] = .{ .x = x0, .y = y0, .u = 0, .v = 0, .r = r, .g = g, .b = b, .a = a };
        self.vertices[vi + 1] = .{ .x = x1, .y = y1, .u = 1, .v = 0, .r = r, .g = g, .b = b, .a = a };
        self.vertices[vi + 2] = .{ .x = x2, .y = y2, .u = 1, .v = 1, .r = r, .g = g, .b = b, .a = a };
        self.vertices[vi + 3] = .{ .x = x3, .y = y3, .u = 0, .v = 1, .r = r, .g = g, .b = b, .a = a };
        self.sprite_count += 1;
    }

    /// Flush batch and render all sprites with the given shader, texture, camera.
    pub fn render(self: *SpriteBatcher, shader: *Shader, texture: *Texture, camera: *Camera) void {
        if (self.sprite_count == 0 or !self.gl_initialized) return;

        shader.use();
        shader.setTexture(0);
        shader.setColor(1, 1, 1, 1);
        shader.setOffset(0, 0);
        camera.updateMatrices();
        shader.setProjection(&camera.projection);
        shader.setModelview(&camera.modelview);

        texture.bind();

        gl.bindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(gl.GL_ARRAY_BUFFER, std.mem.sliceAsBytes(self.vertices[0..self.sprite_count * 4]), gl.GL_DYNAMIC_DRAW);
        gl.bindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.ibo);

        const stride: i32 = @sizeOf(SpriteVertex);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, 8);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, 16);

        gl.drawElements(gl.GL_TRIANGLES, @intCast(self.sprite_count * 6), gl.GL_UNSIGNED_INT, 0);

        gl.disableVertexAttribArray(0);
        gl.disableVertexAttribArray(1);
        gl.disableVertexAttribArray(2);
        self.sprite_count = 0;
        // Clear auto-flush state so a stale pointer can never be dereferenced
        // by a later add() outside the render pass that registered it.
        self.flush_fn = null;
        self.flush_shader = null;
        self.flush_texture = null;
        self.flush_camera = null;
    }
};
