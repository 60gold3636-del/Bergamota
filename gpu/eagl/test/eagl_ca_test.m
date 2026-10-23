// SPDX-License-Identifier: MIT
// Step 1 of the CoreAnimation bring-up: drive QuartzCore's GLES renderer (CARenderer, i.e. CA::OGL through
// -[EAGLContext getMacroContextPrivate]) with our shim, in this process only, into an IOSurface-backed FBO.
// The system OpenGLES lives in the dyld cache and cannot be replaced by path, so run with an injection build of the shim
// (EAGL_DEFS=-DEAGL_INJECT gpu/eagl/build.sh): EAGL_INJECT_LIB=<path to its OpenGLES> ./eagl_ca_test
// Exit status = failures; prints which image provides EAGLContext so a mix-up with the system library is visible.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
// The tool links the SDK's OpenGLES, so plain gl* calls would bind to the system library (which has no context here).
// Resolve the GL entry points we call from the injected shim instead.
static void *g_shim;
#define GLF(ret, name, args) static ret (*p_##name) args;
GLF(void, glGenFramebuffers, (GLsizei, GLuint *)) GLF(void, glBindFramebuffer, (GLenum, GLuint))
GLF(void, glGenRenderbuffers, (GLsizei, GLuint *)) GLF(void, glBindRenderbuffer, (GLenum, GLuint))
GLF(void, glRenderbufferStorage, (GLenum, GLenum, GLsizei, GLsizei)) GLF(void, glFramebufferRenderbuffer, (GLenum, GLenum, GLenum, GLuint))
GLF(void, glViewport, (GLint, GLint, GLsizei, GLsizei)) GLF(void, glClearColor, (GLfloat, GLfloat, GLfloat, GLfloat))
GLF(void, glClear, (GLbitfield)) GLF(void, glFinish, (void)) GLF(GLenum, glGetError, (void))
GLF(GLenum, glCheckFramebufferStatus, (GLenum))
#define LOADGL(name) p_##name = dlsym(g_shim ? g_shim : RTLD_DEFAULT, #name)
#define glGenFramebuffers p_glGenFramebuffers
#define glBindFramebuffer p_glBindFramebuffer
#define glGenRenderbuffers p_glGenRenderbuffers
#define glBindRenderbuffer p_glBindRenderbuffer
#define glRenderbufferStorage p_glRenderbufferStorage
#define glFramebufferRenderbuffer p_glFramebufferRenderbuffer
#define glViewport p_glViewport
#define glClearColor p_glClearColor
#define glClear p_glClear
#define glFinish p_glFinish
#define glGetError p_glGetError
#define glCheckFramebufferStatus p_glCheckFramebufferStatus
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdio.h>
#include <string.h>

@interface EAGLContext (BergamotaPrivateCA)
- (BOOL)attachImage:(NSUInteger)image toCoreSurface:(IOSurfaceRef)surface invertedRender:(BOOL)inverted;
@end

static int g_fail;
#define CHECK(cond, ...) do { if (cond) printf("PASS  "); else { g_fail++; printf("FAIL  "); } printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static CGColorRef rgb(CGFloat r, CGFloat g, CGFloat b) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat c[4] = { r, g, b, 1 };
    CGColorRef col = CGColorCreate(cs, c);
    CGColorSpaceRelease(cs);
    return col;
}
static void px(IOSurfaceRef s, int x, int y, uint8_t o[4]) {
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    memcpy(o, (uint8_t *)IOSurfaceGetBaseAddress(s) + y * IOSurfaceGetBytesPerRow(s) + x * 4, 4);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
}

int main(void) {
    @autoreleasepool {
        const char *inj = getenv("EAGL_INJECT_LIB");       // injection build of the shim: patches the real EAGL classes at load
        if (inj && !(g_shim = dlopen(inj, RTLD_NOW))) { printf("FAIL  dlopen %s: %s\n", inj, dlerror()); return 1; }
        LOADGL(glGenFramebuffers); LOADGL(glBindFramebuffer); LOADGL(glGenRenderbuffers); LOADGL(glBindRenderbuffer);
        LOADGL(glRenderbufferStorage); LOADGL(glFramebufferRenderbuffer); LOADGL(glViewport); LOADGL(glClearColor);
        LOADGL(glClear); LOADGL(glFinish); LOADGL(glGetError); LOADGL(glCheckFramebufferStatus);
        printf("EAGLContext image: %s\n", class_getImageName(NSClassFromString(@"EAGLContext")));
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        CHECK(ctx && [EAGLContext setCurrentContext:ctx], "EAGLContext ES3 current");
        if (!ctx) return 1;
        const int W = 256, H = 256;
        NSDictionary *d = @{ (id)kIOSurfaceWidth : @(W), (id)kIOSurfaceHeight : @(H), (id)kIOSurfaceBytesPerElement : @4,
                             (id)kIOSurfacePixelFormat : @(0x42475241u), (id)kIOSurfaceBytesPerRow : @(W * 4) };
        IOSurfaceRef surf = IOSurfaceCreate((CFDictionaryRef)d);
        GLuint fbo, rb;
        glGenFramebuffers(1, &fbo); glGenRenderbuffers(1, &rb);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo); glBindRenderbuffer(GL_RENDERBUFFER, rb);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, W, H);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
        CHECK([ctx attachImage:rb toCoreSurface:surf invertedRender:NO], "attachImage:toCoreSurface:");
        glViewport(0, 0, W, H);
        CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "FBO complete (rb %u)", rb);
        glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);

        CARenderer *r = [CARenderer rendererWithEAGLContext:ctx options:nil];
        CHECK(r != nil, "CARenderer rendererWithEAGLContext:options:");
        if (!r) return 1;
        CALayer *root = [CALayer layer];
        root.bounds = CGRectMake(0, 0, W, H); root.position = CGPointMake(W / 2, H / 2);
        root.backgroundColor = rgb(1, 0, 0);
        CALayer *box = [CALayer layer];
        box.frame = CGRectMake(64, 64, 128, 128);
        box.backgroundColor = rgb(0, 1, 0);
        [root addSublayer:box];
        r.layer = root;
        r.bounds = CGRectMake(0, 0, W, H);
        [CATransaction flush];
        [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
        [r addUpdateRect:r.bounds];
        [r render];
        [r endFrame];
        glFinish();
        printf("GL error after render: 0x%x\n", glGetError());
        uint8_t a[4], b[4];
        px(surf, 10, 10, a); px(surf, 128, 128, b);
        printf("pixel(10,10) BGRA=%d %d %d %d   pixel(128,128) BGRA=%d %d %d %d\n", a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3]);
        CHECK(a[2] > 200 && a[1] < 50 && a[0] < 50, "root layer red reaches the IOSurface");
        CHECK(b[1] > 200 && b[2] < 50 && b[0] < 50, "sublayer green reaches the IOSurface");
    }
    printf("RESULT: %d failed\n", g_fail);
    return g_fail;
}
