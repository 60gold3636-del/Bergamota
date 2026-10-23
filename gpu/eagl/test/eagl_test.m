// SPDX-License-Identifier: MIT
// Standalone test for the Bergamota OpenGLES shim: GLES2/GLES3 rendering into IOSurfaces and read back.
// Links the shim by path (never the system OpenGLES.framework). Exit status = number of failed checks.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/EAGLIOSurface.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <OpenGLES/ES1/gl.h>
#import "eagl_private.h"
#include <stdio.h>
#include <string.h>
#include <sys/time.h>

static int g_fail, g_pass;
static const char *g_dump;     // --dump FILE.ppm: write the ES2 frame
static int g_bench;            // --bench: full-screen (750x1334) textured+shaded frames
#define CHECK(cond, ...) do { if (cond) { g_pass++; printf("PASS  "); } else { g_fail++; printf("FAIL  "); } printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

// A stand-in for CAEAGLLayer: answers the selectors the shim queries and records the presented IOSurface.
@interface FakeDrawable : NSObject <EAGLDrawable>
@property (nonatomic, assign) CGRect bounds;
@property (nonatomic, assign) CGFloat contentsScale;
@property (nonatomic, assign) BOOL opaque;
@property (nonatomic, copy) NSDictionary *drawableProperties;
@property (nonatomic, assign) IOSurfaceRef presented;
@property (nonatomic, assign) int presentCount;
@end
@implementation FakeDrawable
- (BOOL)isOpaque { return _opaque; }
- (void)setContents:(id)c { _presented = (IOSurfaceRef)c; _presentCount++; }
@end

static IOSurfaceRef mk_surface(int w, int h) {
    NSDictionary *d = @{ (id)kIOSurfaceWidth : @(w), (id)kIOSurfaceHeight : @(h), (id)kIOSurfaceBytesPerElement : @4,
                         (id)kIOSurfacePixelFormat : @(0x42475241u), (id)kIOSurfaceBytesPerRow : @(((w * 4) + 63) & ~63) };
    return IOSurfaceCreate((CFDictionaryRef)d);
}
static void surf_pixel(IOSurfaceRef s, int x, int y, uint8_t out[4]) {   // BGRA bytes
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *p = (const uint8_t *)IOSurfaceGetBaseAddress(s) + y * IOSurfaceGetBytesPerRow(s) + x * 4;
    memcpy(out, p, 4);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
}
static int near(int a, int b) { return abs(a - b) <= 2; }

static GLuint compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024]; glGetShaderInfoLog(s, sizeof log, NULL, log); printf("shader log: %s\n", log); }
    return ok ? s : 0;
}
static GLuint program(const char *vs, const char *fs) {
    GLuint v = compile(GL_VERTEX_SHADER, vs), f = compile(GL_FRAGMENT_SHADER, fs);
    if (!v || !f) return 0;
    GLuint p = glCreateProgram();
    glAttachShader(p, v); glAttachShader(p, f);
    glBindAttribLocation(p, 0, "pos");
    glLinkProgram(p);
    GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    return ok ? p : 0;
}

static const char *VS100 = "attribute vec2 pos; void main() { gl_Position = vec4(pos, 0.0, 1.0); }";
static const char *FS100 = "precision mediump float; uniform vec4 color; void main() { gl_FragColor = color; }";
static const char *VS300 = "#version 300 es\nlayout(location=0) in vec2 pos; void main() { gl_Position = vec4(pos, 0.0, 1.0); }";
static const char *FS300 = "#version 300 es\nprecision mediump float; uniform vec4 color; out vec4 o; void main() { o = color; }";

static void draw_triangle(GLuint prog, float r, float g, float b) {
    static const GLfloat v[] = { -0.8f, -0.2f, 0.8f, -0.2f, 0.0f, 0.9f };
    glUseProgram(prog);
    glUniform4f(glGetUniformLocation(prog, "color"), r, g, b, 1.0f);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, v);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

static void test_present(EAGLRenderingAPI api, const char *vs, const char *fs, const char *tag) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:api];
    CHECK(ctx != nil, "[%s] EAGLContext initWithAPI:%d", tag, (int)api);
    if (!ctx) return;
    CHECK([EAGLContext setCurrentContext:ctx] && [EAGLContext currentContext] == ctx, "[%s] setCurrentContext", tag);
    printf("      GL_VERSION  : %s\n      GL_RENDERER : %s\n      GLSL        : %s\n",
           glGetString(GL_VERSION), glGetString(GL_RENDERER), glGetString(GL_SHADING_LANGUAGE_VERSION));

    FakeDrawable *dr = [[FakeDrawable alloc] init];
    dr.bounds = CGRectMake(0, 0, 128, 128); dr.contentsScale = 1; dr.opaque = YES;
    dr.drawableProperties = @{ kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8 };
    GLuint fbo, rb;
    glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    BOOL st = [ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:dr];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    CHECK(st && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "[%s] renderbufferStorage:fromDrawable: + FBO complete", tag);
    GLint rw = 0; glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &rw);
    CHECK(rw == 128, "[%s] renderbuffer width %d", tag, rw);

    GLuint prog = program(vs, fs);
    CHECK(prog != 0, "[%s] shader compile+link", tag);
    if (prog) {
        glViewport(0, 0, 128, 128);
        glClearColor(0, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT);
        draw_triangle(prog, 1, 0, 0);
        CHECK([ctx presentRenderbuffer:GL_RENDERBUFFER] && dr.presentCount == 1 && dr.presented != NULL, "[%s] presentRenderbuffer delivers an IOSurface", tag);
        if (dr.presented) {
            uint8_t top[4], bot[4], corner[4];
            surf_pixel(dr.presented, 64, 20, top);
            surf_pixel(dr.presented, 64, 100, bot);
            surf_pixel(dr.presented, 2, 2, corner);
            CHECK(IOSurfaceGetWidth(dr.presented) == 128 && IOSurfaceGetPixelFormat(dr.presented) == 'BGRA', "[%s] surface 128x128 BGRA", tag);
            CHECK(near(top[2], 255) && near(top[1], 0) && near(top[0], 0) && near(top[3], 255), "[%s] triangle apex is red at the TOP (BGRA %d %d %d %d)", tag, top[0], top[1], top[2], top[3]);
            CHECK(near(bot[0], 255) && near(bot[2], 0) && near(bot[3], 255), "[%s] below the triangle is the blue clear colour (BGRA %d %d %d %d)", tag, bot[0], bot[1], bot[2], bot[3]);
            CHECK(near(corner[0], 255) && near(corner[2], 0), "[%s] corner is blue", tag);
        }
        if (g_dump && api == kEAGLRenderingAPIOpenGLES2 && dr.presented) {
            IOSurfaceLock(dr.presented, kIOSurfaceLockReadOnly, NULL);
            FILE *f = fopen(g_dump, "wb");
            if (f) {
                fprintf(f, "P6\n128 128\n255\n");
                for (int y = 0; y < 128; y++) for (int x = 0; x < 128; x++) {
                    const uint8_t *q = (const uint8_t *)IOSurfaceGetBaseAddress(dr.presented) + y * IOSurfaceGetBytesPerRow(dr.presented) + x * 4;
                    fputc(q[2], f); fputc(q[1], f); fputc(q[0], f);
                }
                fclose(f);
            }
            IOSurfaceUnlock(dr.presented, kIOSurfaceLockReadOnly, NULL);
        }
        // timing: 20 frames of clear+triangle+present
        struct timeval a, b; gettimeofday(&a, NULL);
        for (int i = 0; i < 20; i++) { glClear(GL_COLOR_BUFFER_BIT); draw_triangle(prog, 1, 0, 0); [ctx presentRenderbuffer:GL_RENDERBUFFER]; }
        gettimeofday(&b, NULL);
        printf("      20 frames 128x128 (draw+readback+present): %.1f ms/frame\n", ((b.tv_sec - a.tv_sec) * 1e3 + (b.tv_usec - a.tv_usec) / 1e3) / 20);
    }
    [EAGLContext setCurrentContext:nil];
    CHECK([EAGLContext currentContext] == nil, "[%s] setCurrentContext:nil", tag);
    [dr release]; [ctx release];
}

static void test_attach_and_texture(void) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    [EAGLContext setCurrentContext:ctx];
    // attachImage:toCoreSurface:invertedRender: -> render, glFinish, surface holds the pixels
    IOSurfaceRef surf = mk_surface(64, 64);
    GLuint fbo, rb;
    glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 64, 64);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    BOOL at = [ctx attachImage:rb toCoreSurface:surf invertedRender:NO];
    CHECK(at, "attachImage:toCoreSurface:invertedRender:");
    glClearColor(0, 1, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    glScissor(0, 0, 64, 16); glEnable(GL_SCISSOR_TEST);        // bottom 16 GL rows magenta
    glClearColor(1, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT); glDisable(GL_SCISSOR_TEST);
    glFinish();
    uint8_t p[4], q[4];
    surf_pixel(surf, 32, 8, p);                                  // top rows of the surface = top of GL image: green
    surf_pixel(surf, 32, 60, q);                                 // bottom rows: magenta
    CHECK(near(p[1], 255) && near(p[0], 0) && near(p[2], 0), "glFinish syncs the attached IOSurface, top row green (BGRA %d %d %d %d)", p[0], p[1], p[2], p[3]);
    CHECK(near(q[2], 255) && near(q[0], 255) && near(q[1], 0), "surface is top-down: bottom row magenta (BGRA %d %d %d %d)", q[0], q[1], q[2], q[3]);

    // texImageIOSurface:...plane:invert:
    IOSurfaceRef src = mk_surface(32, 32);
    IOSurfaceLock(src, 0, NULL);
    for (int y = 0; y < 32; y++) {
        uint8_t *row = (uint8_t *)IOSurfaceGetBaseAddress(src) + y * IOSurfaceGetBytesPerRow(src);
        for (int x = 0; x < 32; x++) { uint8_t *px = row + x * 4; px[0] = 10; px[1] = 20; px[2] = y < 16 ? 30 : 200; px[3] = 255; }
    }
    IOSurfaceUnlock(src, 0, NULL);
    GLuint tex, fbo2;
    glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    BOOL ti = [ctx texImageIOSurface:src target:GL_TEXTURE_2D internalFormat:GL_RGBA width:32 height:32 format:GL_BGRA_EXT type:GL_UNSIGNED_BYTE plane:0];
    CHECK(ti, "texImageIOSurface:...plane:");
    glGenFramebuffers(1, &fbo2); glBindFramebuffer(GL_FRAMEBUFFER, fbo2);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    uint8_t px[4];
    glReadPixels(5, 5, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);        // GL row 5 = surface row 5 (not inverted): R=30
    CHECK(px[0] == 30 && px[1] == 20 && px[2] == 10 && px[3] == 255, "texture holds the surface pixels, BGRA swizzled to RGBA (RGBA %d %d %d %d)", px[0], px[1], px[2], px[3]);
    ti = [ctx texImageIOSurface:src target:GL_TEXTURE_2D internalFormat:GL_RGBA width:32 height:32 format:GL_BGRA_EXT type:GL_UNSIGNED_BYTE plane:0 invert:YES];
    glReadPixels(5, 5, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    CHECK(ti && px[0] == 200, "invert:YES flips rows (R=%d)", px[0]);

    // sharegroup: a texture created in ctx is visible in a second context of the same group
    EAGLContext *c2 = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3 sharegroup:ctx.sharegroup];
    CHECK(c2 != nil && c2.sharegroup == ctx.sharegroup, "sharegroup shared");
    [EAGLContext setCurrentContext:c2];
    CHECK(glIsTexture(tex) == GL_TRUE, "texture visible through the sharegroup");
    EAGLContext *c3 = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:c3];
    CHECK(glIsTexture(tex) == GL_FALSE, "texture NOT visible in an unrelated context");
    [EAGLContext setCurrentContext:nil];
    [c3 release]; [c2 release]; [ctx release];
    CFRelease(surf); CFRelease(src);
}

static void bench(void) {
    EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    [EAGLContext setCurrentContext:ctx];
    FakeDrawable *dr = [[FakeDrawable alloc] init];
    dr.bounds = CGRectMake(0, 0, 375, 667); dr.contentsScale = 2; dr.opaque = YES;
    GLuint fbo, rb, tex;
    glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    [ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:dr];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    static uint32_t texels[256 * 256];
    for (int i = 0; i < 256 * 256; i++) texels[i] = 0xff000000u | ((i & 255) << 8) | (i >> 8);
    glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    const char *vs = "#version 300 es\nlayout(location=0) in vec2 pos; out vec2 uv; void main(){ uv = pos*0.5+0.5; gl_Position = vec4(pos,0.0,1.0); }";
    const char *fs = "#version 300 es\nprecision mediump float; uniform sampler2D t; in vec2 uv; out vec4 o; void main(){ o = texture(t, uv) * vec4(0.9,0.9,1.0,1.0); }";
    GLuint prog = program(vs, fs);
    static const GLfloat quad[] = { -1,-1, 1,-1, -1,1, 1,1 };
    glViewport(0, 0, 750, 1334);
    struct timeval a, b; gettimeofday(&a, NULL);
    int n = 10;
    for (int i = 0; i < n; i++) {
        glUseProgram(prog); glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        [ctx presentRenderbuffer:GL_RENDERBUFFER];
    }
    gettimeofday(&b, NULL);
    printf("BENCH 750x1334 textured full-screen quad + present: %.1f ms/frame\n", ((b.tv_sec - a.tv_sec) * 1e3 + (b.tv_usec - a.tv_usec) / 1e3) / n);
    [EAGLContext setCurrentContext:nil]; [dr release]; [ctx release];
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dump") && i + 1 < argc) g_dump = argv[++i];
        else if (!strcmp(argv[i], "--bench")) g_bench = 1;
    }
    @autoreleasepool {
        printf("%s\n", EAGLShimVersionString());
        unsigned maj = 0, min = 0; EAGLGetVersion(&maj, &min);
        CHECK(maj == 1, "EAGLGetVersion %u.%u", maj, min);
        test_present(kEAGLRenderingAPIOpenGLES2, VS100, FS100, "ES2");
        test_present(kEAGLRenderingAPIOpenGLES3, VS300, FS300, "ES3");
        test_attach_and_texture();
        {   // OpenGL ES 1.1 context (fixed function): creation and one fixed-function call
            EAGLContext *c1 = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
            CHECK(c1 != nil && [EAGLContext setCurrentContext:c1], "[ES1] context");
            if (c1) {
                printf("      GL_VERSION  : %s\n", glGetString(GL_VERSION));
                glMatrixMode(GL_PROJECTION); glLoadIdentity();
                CHECK(glGetError() == GL_NO_ERROR, "[ES1] glMatrixMode/glLoadIdentity");
                [EAGLContext setCurrentContext:nil]; [c1 release];
            }
        }
        if (g_bench) bench();
    }
    printf("RESULT: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
