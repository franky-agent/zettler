//! OpenGL bindings — minimal subset needed for the game.
//!
//! These are direct C ABI bindings to the GL library.
//! Based on OpenGL 2.1 core profile. Convenience wrappers call c.* directly.

const std = @import("std");

// === Types ===
pub const GLuint = c_uint;
pub const GLint = c_int;
pub const GLsizei = c_int;
pub const GLfloat = f32;
pub const GLclampf = f32;
pub const GLubyte = u8;
pub const GLenum = c_uint;
pub const GLboolean = u8;
pub const GLchar = u8;
pub const GLbitfield = c_uint;
pub const GLshort = c_short;
pub const GLushort = c_ushort;
pub const GLbyte = i8;
pub const GLdouble = f64;
pub const GLsizeiptr = isize;
pub const GLintptr = isize;

// === Constants ===
pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
pub const GL_DEPTH_BUFFER_BIT: GLbitfield = 0x00000100;
pub const GL_STENCIL_BUFFER_BIT: GLbitfield = 0x00000400;
pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_TRIANGLE_STRIP: GLenum = 0x0005;
pub const GL_TRIANGLE_FAN: GLenum = 0x0006;
pub const GL_LINES: GLenum = 0x0001;
pub const GL_LINE_STRIP: GLenum = 0x0003;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_UNSIGNED_SHORT: GLenum = 0x1403;
pub const GL_UNSIGNED_INT: GLenum = 0x1405;
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_DEPTH_TEST: GLenum = 0x0B71;
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_CULL_FACE: GLenum = 0x0B44;
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_SCISSOR_TEST: GLenum = 0x0C11;
pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_ONE: GLenum = 0x0001;
pub const GL_ZERO: GLenum = 0x0000;
pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_ELEMENT_ARRAY_BUFFER: GLenum = 0x8893;
pub const GL_STATIC_DRAW: GLenum = 0x88E4;
pub const GL_DYNAMIC_DRAW: GLenum = 0x88E8;
pub const GL_STREAM_DRAW: GLenum = 0x88E0;
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;
pub const GL_INFO_LOG_LENGTH: GLenum = 0x8B84;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_LINEAR: GLenum = 0x2601;
pub const GL_NEAREST: GLenum = 0x2600;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_CLAMP_TO_EDGE: GLenum = 0x812F;
pub const GL_REPEAT: GLenum = 0x2901;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_RGB: GLenum = 0x1907;
pub const GL_ALPHA: GLenum = 0x1906;
pub const GL_LUMINANCE: GLenum = 0x1909;
pub const GL_LUMINANCE_ALPHA: GLenum = 0x190A;
pub const GL_RGBA8: GLenum = 0x8058;
pub const GL_VIEWPORT: GLenum = 0x0BA2;
pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;
pub const GL_VERTEX_ATTRIB_ARRAY_ENABLED: GLenum = 0x8622;
pub const GL_FRAMEBUFFER: GLenum = 0x8D40;
pub const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;

// === Raw C function declarations ===
pub const c = struct {
    extern "c" fn glClear(mask: GLbitfield) void;
    extern "c" fn glClearColor(r: GLclampf, g: GLclampf, b: GLclampf, a: GLclampf) void;
    extern "c" fn glViewport(x: GLint, y: GLint, width: GLsizei, height: GLsizei) void;
    extern "c" fn glEnable(cap: GLenum) void;
    extern "c" fn glDisable(cap: GLenum) void;
    extern "c" fn glBlendFunc(sfactor: GLenum, dfactor: GLenum) void;
    extern "c" fn glGenTextures(n: GLsizei, textures: *GLuint) void;
    extern "c" fn glDeleteTextures(n: GLsizei, textures: *const GLuint) void;
    extern "c" fn glBindTexture(target: GLenum, texture: GLuint) void;
    extern "c" fn glTexImage2D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, type_: GLenum, pixels: ?*const anyopaque) void;
    extern "c" fn glTexParameteri(target: GLenum, pname: GLenum, param: GLint) void;
    extern "c" fn glCreateShader(shaderType: GLenum) callconv(.c) GLuint;
    extern "c" fn glShaderSource(shader: GLuint, count: GLsizei, string: [*]const [*]const GLchar, length: [*]const GLint) void;
    extern "c" fn glCompileShader(shader: GLuint) void;
    extern "c" fn glGetShaderiv(shader: GLuint, pname: GLenum, params: *GLint) void;
    extern "c" fn glGetShaderInfoLog(shader: GLuint, bufSize: GLsizei, length: *GLsizei, infoLog: [*]GLchar) void;
    extern "c" fn glCreateProgram() callconv(.c) GLuint;
    extern "c" fn glAttachShader(program: GLuint, shader: GLuint) void;
    extern "c" fn glBindAttribLocation(program: GLuint, index: GLuint, name: [*:0]const GLchar) void;
    extern "c" fn glLinkProgram(program: GLuint) void;
    extern "c" fn glGetProgramiv(program: GLuint, pname: GLenum, params: *GLint) void;
    extern "c" fn glGetProgramInfoLog(program: GLuint, bufSize: GLsizei, length: *GLsizei, infoLog: [*]GLchar) void;
    extern "c" fn glUseProgram(program: GLuint) void;
    extern "c" fn glDeleteShader(shader: GLuint) void;
    extern "c" fn glDeleteProgram(program: GLuint) void;
    extern "c" fn glGenBuffers(n: GLsizei, buffers: *GLuint) void;
    extern "c" fn glDeleteBuffers(n: GLsizei, buffers: *const GLuint) void;
    extern "c" fn glBindBuffer(target: GLenum, buffer: GLuint) void;
    extern "c" fn glBufferData(target: GLenum, size: GLsizeiptr, data: ?*const anyopaque, usage: GLenum) void;
    extern "c" fn glGetUniformLocation(program: GLuint, name: [*:0]const GLchar) callconv(.c) GLint;
    extern "c" fn glUniform1i(location: GLint, v0: GLint) void;
    extern "c" fn glUniform1f(location: GLint, v0: GLfloat) void;
    extern "c" fn glUniform2f(location: GLint, v0: GLfloat, v1: GLfloat) void;
    extern "c" fn glUniform4f(location: GLint, v0: GLfloat, v1: GLfloat, v2: GLfloat, v3: GLfloat) void;
    extern "c" fn glUniformMatrix4fv(location: GLint, count: GLsizei, transpose: GLboolean, value: *const [16]f32) void;
    extern "c" fn glEnableVertexAttribArray(index: GLuint) void;
    extern "c" fn glDisableVertexAttribArray(index: GLuint) void;
    extern "c" fn glVertexAttribPointer(index: GLuint, size: GLint, type_: GLenum, normalized: GLboolean, stride: GLsizei, pointer: ?*const anyopaque) void;
    extern "c" fn glDrawArrays(mode: GLenum, first: GLint, count: GLsizei) void;
    extern "c" fn glDrawElements(mode: GLenum, count: GLsizei, type_: GLenum, indices: ?*const anyopaque) void;
    extern "c" fn glActiveTexture(texture: GLenum) void;
    extern "c" fn glGetString(name: GLenum) callconv(.c) [*:0]const GLubyte;
    extern "c" fn glGetIntegerv(pname: GLenum, params: [*]GLint) void;
    extern "c" fn glScissor(x: GLint, y: GLint, width: GLsizei, height: GLsizei) void;
    extern "c" fn glPixelStorei(pname: GLenum, param: GLint) void;
    extern "c" fn glReadPixels(x: GLint, y: GLint, width: GLsizei, height: GLsizei, format: GLenum, type_: GLenum, pixels: ?*anyopaque) void;
};

// === Convenience wrappers ===
pub fn clear(mask: GLbitfield) void { c.glClear(mask); }
pub fn clearColor(r: GLclampf, g: GLclampf, b: GLclampf, a: GLclampf) void { c.glClearColor(r, g, b, a); }
pub fn viewport(x: GLint, y: GLint, w: GLsizei, h: GLsizei) void { c.glViewport(x, y, w, h); }
pub fn enable(cap: GLenum) void { c.glEnable(cap); }
pub fn disable(cap: GLenum) void { c.glDisable(cap); }
pub fn blendFunc(sf: GLenum, df: GLenum) void { c.glBlendFunc(sf, df); }
pub fn genTextures(n: GLsizei) GLuint { var t: GLuint = 0; c.glGenTextures(n, &t); return t; }
pub fn deleteTextures(n: GLsizei, textures: *const GLuint) void { c.glDeleteTextures(n, textures); }
pub fn bindTexture(target: GLenum, texture: GLuint) void { c.glBindTexture(target, texture); }
pub fn texImage2D(target: GLenum, level: GLint, ifmt: GLint, w: GLsizei, h: GLsizei, format: GLenum, type_: GLenum, pixels: ?*const anyopaque) void {
    c.glTexImage2D(target, level, ifmt, w, h, 0, format, type_, pixels);
}
pub fn texParameteri(target: GLenum, pname: GLenum, param: GLint) void { c.glTexParameteri(target, pname, param); }
pub fn createShader(kind: GLenum) GLuint { return c.glCreateShader(kind); }
pub fn shaderSource(shader: GLuint, src: [:0]const u8) void {
    const strings = [_][*]const GLchar{@ptrCast(src.ptr)};
    const lens = [_]GLint{@intCast(src.len)};
    c.glShaderSource(shader, 1, &strings, &lens);
}
pub fn compileShader(shader: GLuint) void { c.glCompileShader(shader); }
pub fn getShaderiv(shader: GLuint, pname: GLenum) GLint {
    var params: GLint = 0;
    c.glGetShaderiv(shader, pname, &params);
    return params;
}
pub fn createProgram() GLuint { return c.glCreateProgram(); }
pub fn attachShader(prog: GLuint, shad: GLuint) void { c.glAttachShader(prog, shad); }
pub fn bindAttribLocation(prog: GLuint, index: GLuint, name: [*:0]const u8) void { c.glBindAttribLocation(prog, index, @ptrCast(name)); }
pub fn linkProgram(prog: GLuint) void { c.glLinkProgram(prog); }
pub fn useProgram(prog: GLuint) void { c.glUseProgram(prog); }
pub fn deleteShader(shader: GLuint) void { c.glDeleteShader(shader); }
pub fn deleteProgram(prog: GLuint) void { c.glDeleteProgram(prog); }
pub fn genBuffers(n: GLsizei) GLuint { var b: GLuint = 0; c.glGenBuffers(n, &b); return b; }
pub fn deleteBuffers(n: GLsizei, bufs: *const GLuint) void { c.glDeleteBuffers(n, bufs); }
pub fn bindBuffer(target: GLenum, buffer: GLuint) void { c.glBindBuffer(target, buffer); }
pub fn bufferData(target: GLenum, data: []const u8, usage: GLenum) void {
    c.glBufferData(target, @intCast(data.len), data.ptr, usage);
}
pub fn getUniformLocation(prog: GLuint, name: [*:0]const u8) GLint {
    return c.glGetUniformLocation(prog, @ptrCast(name));
}
pub fn uniform1i(loc: GLint, v0: GLint) void { c.glUniform1i(loc, v0); }
pub fn uniform1f(loc: GLint, v0: GLfloat) void { c.glUniform1f(loc, v0); }
pub fn uniform2f(loc: GLint, v0: GLfloat, v1: GLfloat) void { c.glUniform2f(loc, v0, v1); }
pub fn uniform4f(loc: GLint, v0: GLfloat, v1: GLfloat, v2: GLfloat, v3: GLfloat) void { c.glUniform4f(loc, v0, v1, v2, v3); }
pub fn uniformMatrix4fv(loc: GLint, value: *const [16]f32) void {
    c.glUniformMatrix4fv(loc, 1, GL_FALSE, @ptrCast(value));
}
pub fn enableVertexAttribArray(idx: GLuint) void { c.glEnableVertexAttribArray(idx); }
pub fn disableVertexAttribArray(idx: GLuint) void { c.glDisableVertexAttribArray(idx); }
pub fn vertexAttribPointer(idx: GLuint, size: GLint, type_: GLenum, norm: GLboolean, stride: GLsizei, pointer: usize) void {
    c.glVertexAttribPointer(idx, size, type_, norm, stride, @ptrFromInt(pointer));
}
pub fn drawArrays(mode: GLenum, first: GLint, count: GLsizei) void { c.glDrawArrays(mode, first, count); }
pub fn drawElements(mode: GLenum, count: GLsizei, type_: GLenum, indices: usize) void {
    c.glDrawElements(mode, count, type_, @ptrFromInt(indices));
}
pub fn getString(name: GLenum) [:0]const u8 {
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(c.glGetString(name))), 0);
}
pub fn scissor(x: GLint, y: GLint, w: GLsizei, h: GLsizei) void { c.glScissor(x, y, w, h); }
pub fn pixelStorei(pname: GLenum, param: GLint) void { c.glPixelStorei(pname, param); }
pub fn readPixels(x: GLint, y: GLint, w: GLsizei, h: GLsizei, format: GLenum, type_: GLenum, pixels: []u8) void {
    c.glReadPixels(x, y, w, h, format, type_, pixels.ptr);
}
