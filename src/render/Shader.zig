//! Shader — OpenGL shader compilation and program management.
//!
//! Compiles vertex and fragment shaders from GLSL source,
//! links them into a program, and provides uniform setters.

const std = @import("std");
const gl = @import("gl.zig");

/// An OpenGL shader program.
pub const Shader = struct {
    /// Program ID (0 = invalid).
    program: gl.GLuint = 0,

    // Uniform locations (cached for performance)
    u_projection: gl.GLint = -1,
    u_modelview: gl.GLint = -1,
    u_texture: gl.GLint = -1,
    u_color: gl.GLint = -1,
    u_offset: gl.GLint = -1,
    u_use_mask: gl.GLint = -1,

    /// Compile a shader from vertex and fragment source strings.
    pub fn init(vertex_source: [:0]const u8, fragment_source: [:0]const u8) !Shader {
        var shader = Shader{};

        // Compile vertex shader
        const vs = gl.createShader(gl.GL_VERTEX_SHADER);
        if (vs == 0) return error.ShaderCreateFailed;
        errdefer gl.deleteShader(vs);

        gl.shaderSource(vs, vertex_source);
        gl.compileShader(vs);
        if (gl.getShaderiv(vs, gl.GL_COMPILE_STATUS) == gl.GL_FALSE) {
            const log_len = gl.getShaderiv(vs, gl.GL_INFO_LOG_LENGTH);
            if (log_len > 0) {
                const log = std.heap.page_allocator.alloc(u8, @intCast(log_len)) catch "out of mem";
                defer if (log.len > 0) std.heap.page_allocator.free(log);
            }
            return error.VertexShaderCompileFailed;
        }

        // Compile fragment shader
        const fs = gl.createShader(gl.GL_FRAGMENT_SHADER);
        if (fs == 0) return error.ShaderCreateFailed;
        errdefer gl.deleteShader(fs);

        gl.shaderSource(fs, fragment_source);
        gl.compileShader(fs);
        if (gl.getShaderiv(fs, gl.GL_COMPILE_STATUS) == gl.GL_FALSE) {
            return error.FragmentShaderCompileFailed;
        }

        // Link program
        const prog = gl.createProgram();
        if (prog == 0) return error.ProgramCreateFailed;
        errdefer gl.deleteProgram(prog);

        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        // Explicitly bind attribute locations before linking so the driver
        // always assigns position=0, texcoord=1, color=2 regardless of
        // declaration order in the GLSL source.
        gl.bindAttribLocation(prog, 0, "a_position");
        gl.bindAttribLocation(prog, 1, "a_texcoord");
        gl.bindAttribLocation(prog, 2, "a_color");
        gl.linkProgram(prog);

        // Clean up shaders (they're linked into the program now)
        gl.deleteShader(vs);
        gl.deleteShader(fs);

        shader.program = prog;

        // Cache uniform locations
        shader.u_projection = gl.getUniformLocation(prog, "u_projection");
        shader.u_modelview = gl.getUniformLocation(prog, "u_modelview");
        shader.u_texture = gl.getUniformLocation(prog, "u_texture");
        shader.u_color = gl.getUniformLocation(prog, "u_color");
        shader.u_offset = gl.getUniformLocation(prog, "u_offset");
        shader.u_use_mask = gl.getUniformLocation(prog, "u_use_mask");

        return shader;
    }

    pub fn deinit(self: *Shader) void {
        if (self.program != 0) {
            gl.deleteProgram(self.program);
            self.program = 0;
        }
    }

    /// Bind this shader program for rendering.
    pub fn use(self: *Shader) void {
        gl.useProgram(self.program);
    }

    /// Set the projection matrix uniform.
    pub fn setProjection(self: *Shader, matrix: *const [16]f32) void {
        if (self.u_projection >= 0) {
            gl.uniformMatrix4fv(self.u_projection, matrix);
        }
    }

    /// Set the modelview matrix uniform.
    pub fn setModelview(self: *Shader, matrix: *const [16]f32) void {
        if (self.u_modelview >= 0) {
            gl.uniformMatrix4fv(self.u_modelview, matrix);
        }
    }

    /// Set the texture unit uniform.
    pub fn setTexture(self: *Shader, unit: c_int) void {
        if (self.u_texture >= 0) {
            gl.uniform1i(self.u_texture, unit);
        }
    }

    /// Set the color uniform.
    pub fn setColor(self: *Shader, r: f32, g: f32, b: f32, a: f32) void {
        if (self.u_color >= 0) {
            gl.uniform4f(self.u_color, r, g, b, a);
        }
    }

    /// Set the offset uniform (for sprite positioning).
    pub fn setOffset(self: *Shader, x: f32, y: f32) void {
        if (self.u_offset >= 0) {
            gl.uniform2f(self.u_offset, x, y);
        }
    }

    /// Set the terrain two-pass toggle: 0 = solid base, 1 = dithered overlay.
    pub fn setUseMask(self: *Shader, v: f32) void {
        if (self.u_use_mask >= 0) {
            gl.uniform1f(self.u_use_mask, v);
        }
    }

    /// Create the default shader used for sprite rendering.
    pub fn createDefault() !Shader {
        return try Shader.init(
            default_vertex_source,
            default_fragment_source,
        );
    }

    /// Create the terrain shader with a procedural dithered transition.
    /// Two passes share this shader via u_use_mask:
    ///   0 = SOLID base — clean gap-free triangles, fills every pixel.
    ///   1 = OVERLAY    — boundary tiles' triangles, slightly EXPANDED so they
    ///       bleed into the neighbour, faded out toward their edges with an ordered
    ///       (interleaved-gradient-noise) dither. The discard reveals the base
    ///       (neighbour) behind, producing a clean stippled terrain transition.
    /// a_bary carries the vertex barycentric coords (for the edge-fade); a_color
    /// the fallback colour for terrain without a ground sprite (water).
    /// Vertex: a_position(2), a_ground_local(2), a_ground_region(4), a_bary(2), a_color(4).
    pub fn createMaskedTerrain() !Shader {
        const vs: [:0]const u8 =
            \\#version 120
            \\uniform mat4 u_projection;
            \\uniform mat4 u_modelview;
            \\attribute vec2 a_position;
            \\attribute vec2 a_ground_local;
            \\attribute vec4 a_ground_region;
            \\attribute vec2 a_bary;
            \\attribute vec4 a_color;
            \\varying vec2 v_ground_local;
            \\varying vec4 v_ground_region;
            \\varying vec2 v_bary;
            \\varying vec4 v_color;
            \\void main() {
            \\    v_ground_local  = a_ground_local;
            \\    v_ground_region = a_ground_region;
            \\    v_bary          = a_bary;
            \\    v_color         = a_color;
            \\    gl_Position = u_projection * u_modelview * vec4(a_position, 0.0, 1.0);
            \\}
        ;
        const fs: [:0]const u8 =
            \\#version 120
            \\uniform sampler2D u_texture;
            \\uniform float u_use_mask;
            \\varying vec2 v_ground_local;
            \\varying vec4 v_ground_region;
            \\varying vec2 v_bary;
            \\varying vec4 v_color;
            \\void main() {
            \\    vec2 g = fract(v_ground_local);
            \\    vec4 px = texture2D(u_texture, v_ground_region.xy + g * v_ground_region.zw);
            \\    // v_color.rgb is a brightness/tint multiplier (height shading);
            \\    // a=1 → shaded texture (px*tint), a=0 → flat fallback colour (water).
            \\    vec3 outc = mix(v_color.rgb, px.rgb * v_color.rgb, v_color.a);
            \\    if (u_use_mask > 0.5) {
            \\        // Edge-fade density gradient: ~0 at the rim → 1 toward the core,
            \\        // ramped with smoothstep over a WIDE band so the dither dissolves
            \\        // gradually (matching the density gradient baked into the C# masks).
            \\        vec3 bary = vec3(v_bary, 1.0 - v_bary.x - v_bary.y);
            \\        float e = min(min(bary.x, bary.y), bary.z);
            \\        float coverage = smoothstep(0.0, 0.30, e);
            \\        // Interleaved gradient noise → clean ordered dither in screen space.
            \\        float d = fract(52.9829189 * fract(dot(gl_FragCoord.xy,
            \\                  vec2(0.06711056, 0.00583715))));
            \\        if (coverage < d) discard;
            \\    }
            \\    gl_FragColor = vec4(outc, 1.0);
            \\}
        ;
        const s = try Shader.init(vs, fs);
        gl.bindAttribLocation(s.program, 0, "a_position");
        gl.bindAttribLocation(s.program, 1, "a_ground_local");
        gl.bindAttribLocation(s.program, 2, "a_ground_region");
        gl.bindAttribLocation(s.program, 3, "a_bary");
        gl.bindAttribLocation(s.program, 4, "a_color");
        gl.linkProgram(s.program);
        return s;
    }

};

// === Default GLSL shaders ===

const default_vertex_source: [:0]const u8 =
    \\#version 120
    \\uniform mat4 u_projection;
    \\uniform mat4 u_modelview;
    \\uniform vec2 u_offset;
    \\
    \\attribute vec2 a_position;
    \\attribute vec2 a_texcoord;
    \\attribute vec4 a_color;
    \\
    \\varying vec2 v_texcoord;
    \\varying vec4 v_color;
    \\
    \\void main() {
    \\    vec2 pos = a_position + u_offset;
    \\    gl_Position = u_projection * u_modelview * vec4(pos, 0.0, 1.0);
    \\    v_texcoord = a_texcoord;
    \\    v_color = a_color;
    \\}
;

const default_fragment_source: [:0]const u8 =
    \\#version 120
    \\uniform sampler2D u_texture;
    \\uniform vec4 u_color;
    \\
    \\varying vec2 v_texcoord;
    \\varying vec4 v_color;
    \\
    \\void main() {
    \\    vec4 tex = texture2D(u_texture, v_texcoord);
    \\    gl_FragColor = tex * v_color * u_color;
    \\}
;
