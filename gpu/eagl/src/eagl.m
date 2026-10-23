// SPDX-License-Identifier: MIT
// Replacement OpenGLES.framework for the Bergamota Project (iOS 18.7.8 on the Poco F1).
//
// EAGLContext / EAGLSharegroup are implemented on top of Mesa's OSMesa frontend (gallium softpipe today,
// freedreno later: only libOSMesa changes). Every context is an OpenGL ES context (OSMesa profile 0x36, our
// Mesa patch) with a tiny dummy default framebuffer; real output goes through renderbuffers:
//   renderbufferStorage:fromDrawable:  -> glRenderbufferStorage at the drawable's pixel size
//   presentRenderbuffer:               -> read the renderbuffer back into an IOSurface (BGRA, rotating pool) and
//                                         hand it to the drawable (layer.contents = IOSurface)
//   attachImage:toCoreSurface:...      -> renderbuffer/texture <-> IOSurface association, flushed to the surface
//                                         on glFlush/glFinish/present (CoreAnimation's GLES renderer path)
//   texImageIOSurface:...              -> IOSurface pixels uploaded into the bound texture (copy)
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
#ifdef EAGL_INJECT
// Injection build (-DEAGL_INJECT): the system OpenGLES.framework lives in the dyld shared cache and cannot be replaced by path
// (dyld ignores DYLD_FRAMEWORK_PATH for cache dylibs). Our classes get other names here and, at load time, their methods are
// installed into the REAL EAGLContext / EAGLSharegroup classes (same single `_private` ivar), so every caller (QuartzCore
// included) reaches this implementation. See eagl_inject_patch() at the end of the file.
#define EAGLContext BGEAGLContext
#define EAGLSharegroup BGEAGLSharegroup
#endif
#import "eagl_private.h"
#import <objc/runtime.h>
#import <pthread.h>
#import <stdatomic.h>
#import <objc/message.h>
#import <math.h>
#include "osm.h"
#include "macro_ctx.h"
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <CoreGraphics/CoreGraphics.h>
#include "gl_tab.h"


#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif

#define EAGL_DEBUG(...) do { if (g_debug) fprintf(stderr, "EAGL(shim): " __VA_ARGS__); } while (0)
static int g_debug;

#pragma GCC visibility push(default)
// --- constants -------------------------------------------------------------------------------------------
NSString *const kEAGLDrawablePropertyRetainedBacking = @"EAGLDrawablePropertyRetainedBacking";
NSString *const kEAGLDrawablePropertyColorFormat = @"EAGLDrawablePropertyColorFormat";
NSString *const kEAGLColorFormatRGBA8 = @"EAGLColorFormatRGBA8";
NSString *const kEAGLColorFormatRGB565 = @"EAGLColorFormatRGB565";
NSString *const kEAGLColorFormatSRGBA8 = @"EAGLColorFormatSRGBA8";
NSString *const kEAGLColorFormatRGBA_XR10_64BPP = @"EAGLColorFormatRGBA_XR10_64BPP";
NSString *const kEAGLColorFormatSRGBA_XR10_64BPP = @"EAGLColorFormatSRGBA_XR10_64BPP";
NSString *const kEAGLColorFormatSRGB_XR10 = @"EAGLColorFormatSRGB_XR10";
NSString *const kEAGLColorFormatSRGB_XR10_A8_2P = @"EAGLColorFormatSRGB_XR10_A8_2P";
NSString *const kEAGLContextPropertyAccelerated = @"EAGLContextPropertyAccelerated";
NSString *const kEAGLContextPropertyClientLabel = @"EAGLContextPropertyClientLabel";
NSString *const kEAGLContextPropertyClientRetainRelease = @"EAGLContextPropertyClientRetainRelease";
NSString *const kEAGLContextPropertySharedWithCompute = @"EAGLContextPropertySharedWithCompute";
NSString *const kEAGLContextPropertySharegroup = @"EAGLContextPropertySharegroup";
NSString *const kEAGLContextPropertyVisibleInDebugTools = @"EAGLContextPropertyVisibleInDebugTools";

__attribute__((visibility("default"))) void EAGLGetVersion(unsigned int *major, unsigned int *minor) {
    if (major) *major = EAGL_MAJOR_VERSION;
    if (minor) *minor = EAGL_MINOR_VERSION;
}
__attribute__((visibility("default"))) const char *EAGLShimVersionString(void) { return "Bergamota OpenGLES shim 0.1 (Mesa OSMesa/softpipe)"; }

#pragma GCC visibility pop

// --- private state ---------------------------------------------------------------------------------------
#define DUMMY_W 16
#define DUMMY_H 16
#define POOL_N 3
#define MAX_BIND 16

typedef struct {                    // renderbuffer bound to a drawable (renderbufferStorage:fromDrawable:)
    GLuint rb;
    id drawable;                    // retained
    uint32_t w, h;
    GLenum fmt;
    IOSurfaceRef pool[POOL_N];
    int next;
} DrawBind;

typedef struct {                    // attachImage:toCoreSurface:invertedRender:
    GLuint name;
    IOSurfaceRef surf;              // retained
    BOOL inverted;
} Attach;

struct _EAGLSharegroupPrivate {
    EAGLRenderingAPI api;
    pthread_mutex_t lock;
    void *live[64];                 // OSMesaContexts alive in this group (first one is the share root)
    int nlive;
};

struct _EAGLContextPrivate {
    osm_ctx osm;
    EAGLRenderingAPI api;
    EAGLSharegroup *sg;
    unsigned char *dummy;
    NSString *label;
    BOOL multithreaded;
    int params[64];
    DrawBind binds[MAX_BIND]; int nbinds;
    Attach att[MAX_BIND]; int natt;
    GLuint tmpfbo;
    EAGLMacroContext *macro;
};

static pthread_key_t g_tls;
static pthread_once_t g_tls_once = PTHREAD_ONCE_INIT;
static void tls_init(void) { pthread_key_create(&g_tls, NULL); }

// --- helpers ---------------------------------------------------------------------------------------------
static IOSurfaceRef make_surface(uint32_t w, uint32_t h) {
    int32_t bpe = 4, fmt = 'BGRA';
    uint32_t bpr = (w * 4 + 63) & ~63u;
    CFNumberRef nw = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)w});
    CFNumberRef nh = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)h});
    CFNumberRef nb = CFNumberCreate(NULL, kCFNumberSInt32Type, &bpe);
    CFNumberRef nf = CFNumberCreate(NULL, kCFNumberSInt32Type, &fmt);
    CFNumberRef nr = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)bpr});
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat, kIOSurfaceBytesPerRow };
    const void *vals[] = { nw, nh, nb, nf, nr };
    CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d); CFRelease(nw); CFRelease(nh); CFRelease(nb); CFRelease(nf); CFRelease(nr);
    return s;
}

static EAGLContext *cur_ctx(void) {
    pthread_once(&g_tls_once, tls_init);
    return (EAGLContext *)pthread_getspecific(g_tls);
}

// Copy an RGBA w*h bottom-up GL readback into a BGRA IOSurface, top-down (or bottom-up when `keep` is set).
static void rgba_to_surface(const uint8_t *src, uint32_t w, uint32_t h, IOSurfaceRef s, BOOL flip, BOOL opaque) {
    IOSurfaceLock(s, 0, NULL);
    uint8_t *dst = IOSurfaceGetBaseAddress(s);
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    size_t sw = IOSurfaceGetWidth(s), sh = IOSurfaceGetHeight(s);
    uint32_t cw = w < sw ? w : (uint32_t)sw, ch = h < sh ? h : (uint32_t)sh;
    for (uint32_t y = 0; y < ch; y++) {
        const uint32_t *sp = (const uint32_t *)(src + (size_t)(flip ? (h - 1 - y) : y) * w * 4);
        uint32_t *dp = (uint32_t *)(dst + y * bpr);
        for (uint32_t x = 0; x < cw; x++) {
            uint32_t p = sp[x];                         // memory R G B A (little endian: 0xAABBGGRR)
            uint32_t r = p & 0xff, b = (p >> 16) & 0xff;
            dp[x] = (p & 0xff00ff00u) | (r << 16) | b | (opaque ? 0xff000000u : 0);
        }
    }
    IOSurfaceUnlock(s, 0, NULL);
}

// Read back the renderbuffer (or texture level 0) `name` of the current context into a malloc'ed RGBA buffer.
static uint8_t *read_image(EAGLContext *c, GLuint name, BOOL isTexture, uint32_t hintw, uint32_t hinth, uint32_t *ow, uint32_t *oh) {
    struct _EAGLContextPrivate *p = c->_private;
    GLint oldRead = 0, oldPackAlign = 4, oldRb = 0, oldTex = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &oldRead);
    glGetIntegerv(GL_PACK_ALIGNMENT, &oldPackAlign);
    if (!p->tmpfbo) glGenFramebuffers(1, &p->tmpfbo);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, p->tmpfbo);
    GLint w = 0, h = 0;
    if (isTexture) {
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, name, 0);
        w = (GLint)hintw; h = (GLint)hinth;     // ES has no level-size query; the IOSurface gives the size
        (void)oldTex;
    } else {
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &oldRb);
        glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, name);
        glBindRenderbuffer(GL_RENDERBUFFER, name);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h);
        glBindRenderbuffer(GL_RENDERBUFFER, oldRb);
    }
    uint8_t *buf = NULL;
    if (w > 0 && h > 0 && glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
        buf = malloc((size_t)w * h * 4);
        if (buf) {
            glPixelStorei(GL_PACK_ALIGNMENT, 4);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, buf);
        }
    }
    if (isTexture) glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
    else glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, 0);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, oldRead);
    glPixelStorei(GL_PACK_ALIGNMENT, oldPackAlign);
    *ow = (uint32_t)w; *oh = (uint32_t)h;
    return buf;
}

// Flush every attachImage: association of this context into its IOSurface.
static void sync_attached(EAGLContext *c) {
    struct _EAGLContextPrivate *p = c->_private;
    for (int i = 0; i < p->natt; i++) {
        Attach *a = &p->att[i];
        BOOL isTex = glIsTexture(a->name) && !glIsRenderbuffer(a->name);
        uint32_t w, h;
        uint8_t *buf = read_image(c, a->name, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), &w, &h);
        if (buf) {
            // GL rows are bottom-up; a "normal" surface is top-down. invertedRender means CA already drew it flipped.
            rgba_to_surface(buf, w, h, a->surf, !a->inverted, NO);
            free(buf);
        }
    }
}

// glFlush / glFinish wrappers installed over the Mesa entry points (see eagl_install_hooks).
static void (*mesa_glFlush)(void), (*mesa_glFinish)(void);
static void shim_glFlush(void) { mesa_glFlush(); EAGLContext *c = cur_ctx(); if (c && c->_private->natt) sync_attached(c); }
static void shim_glFinish(void) { mesa_glFinish(); EAGLContext *c = cur_ctx(); if (c && c->_private->natt) sync_attached(c); }

static void eagl_install_hooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gl_resolve_all();
        for (int i = 0; i < gl_nfuncs; i++) {
            if (!strcmp(gl_names[i], "glFlush")) { mesa_glFlush = gl_tab[i]; gl_tab[i] = (void *)shim_glFlush; }
            if (!strcmp(gl_names[i], "glFinish")) { mesa_glFinish = gl_tab[i]; gl_tab[i] = (void *)shim_glFinish; }
        }
        g_debug = getenv("EAGL_SHIM_DEBUG") != NULL;
        if (g_debug) {                  // list the exported entry points Mesa could not provide
            extern void gl_unimpl(void);
            int n = 0;
            for (int i = 0; i < gl_nfuncs; i++) if (gl_tab[i] == (void *)gl_unimpl) { fprintf(stderr, "EAGL(shim): unresolved %s\n", gl_names[i]); n++; }
            fprintf(stderr, "EAGL(shim): %d/%d entry points forwarded to Mesa, %d unresolved\n", gl_nfuncs - n, gl_nfuncs, n);
        }
    });
}

// --- EAGLSharegroup --------------------------------------------------------------------------------------
@implementation EAGLSharegroup
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharedWithCompute:(BOOL)compute {
    if ((self = [super init])) {
        _private = calloc(1, sizeof *_private);
        _private->api = api;
        pthread_mutex_init(&_private->lock, NULL);
    }
    return self;
}
- (instancetype)initWithAPI:(EAGLRenderingAPI)api { return [self initWithAPI:api sharedWithCompute:NO]; }
- (instancetype)init { return [self initWithAPI:kEAGLRenderingAPIOpenGLES2]; }
- (NSUInteger)APIs { return 1u << (_private->api); }
- (void *)getGLIShared { return _private; }
- (NSString *)debugLabel { return objc_getAssociatedObject(self, @selector(debugLabel)); }
- (void)setDebugLabel:(NSString *)l { objc_setAssociatedObject(self, @selector(debugLabel), l, OBJC_ASSOCIATION_COPY_NONATOMIC); }
- (void)dealloc { if (_private) { pthread_mutex_destroy(&_private->lock); free(_private); } [super dealloc]; }
@end

// --- EAGLContext -----------------------------------------------------------------------------------------
@implementation EAGLContext

- (instancetype)initWithAPI:(EAGLRenderingAPI)api { return [self initWithAPI:api properties:nil]; }
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharegroup:(EAGLSharegroup *)sg {
    return [self initWithAPI:api properties:sg ? @{ kEAGLContextPropertySharegroup : sg } : nil];
}
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharedWithCompute:(BOOL)compute {
    return [self initWithAPI:api properties:@{ kEAGLContextPropertySharedWithCompute : @(compute) }];
}
- (instancetype)init { return nil; }

- (instancetype)initWithAPI:(EAGLRenderingAPI)api properties:(NSDictionary *)props {
    eagl_install_hooks();
    if (api < kEAGLRenderingAPIOpenGLES1 || api > kEAGLRenderingAPIOpenGLES3) { [self release]; return nil; }
    if ((self = [super init])) {
        struct _EAGLContextPrivate *p = calloc(1, sizeof *p);
        _private = p;
        p->api = api;
        p->dummy = calloc(DUMMY_W * DUMMY_H, 4);
        EAGLSharegroup *sg = props[kEAGLContextPropertySharegroup];
        p->sg = sg ? [sg retain] : [[EAGLSharegroup alloc] initWithAPI:api];
        NSString *lbl = props[kEAGLContextPropertyClientLabel];
        if ([lbl isKindOfClass:[NSString class]]) p->label = [lbl copy];
        struct _EAGLSharegroupPrivate *g = p->sg->_private;
        pthread_mutex_lock(&g->lock);
        osm_ctx share = g->nlive ? g->live[0] : NULL;
        p->osm = osm_create(api == kEAGLRenderingAPIOpenGLES1 ? 1 : (int)api, share);
        if (p->osm && g->nlive < 64) g->live[g->nlive++] = p->osm;
        pthread_mutex_unlock(&g->lock);
        if (!p->osm) { EAGL_DEBUG("OSMesaCreateContextAttribs failed (api %d)\n", (int)api); [self release]; return nil; }
        p->macro = macro_ctx_new(p);   // rend = our private block; the slots ignore it (Mesa uses the thread's current context)
    }
    return self;
}

- (void)dealloc {
    struct _EAGLContextPrivate *p = _private;
    if (p) {
        if (cur_ctx() == self) [EAGLContext setCurrentContext:nil];
        for (int i = 0; i < p->nbinds; i++) {
            [p->binds[i].drawable release];
            for (int k = 0; k < POOL_N; k++) if (p->binds[i].pool[k]) CFRelease(p->binds[i].pool[k]);
        }
        for (int i = 0; i < p->natt; i++) if (p->att[i].surf) CFRelease(p->att[i].surf);
        if (p->sg) {
            struct _EAGLSharegroupPrivate *g = p->sg->_private;
            pthread_mutex_lock(&g->lock);
            for (int i = 0; i < g->nlive; i++) if (g->live[i] == p->osm) { g->live[i] = g->live[--g->nlive]; break; }
            pthread_mutex_unlock(&g->lock);
        }
        if (p->osm) osm_destroy(p->osm);
        [p->sg release]; [p->label release];
        free(p->dummy); macro_ctx_free(p->macro); free(p);
        _private = NULL;
    }
    [super dealloc];
}

+ (BOOL)setCurrentContext:(EAGLContext *)ctx {
    pthread_once(&g_tls_once, tls_init);
    EAGLContext *old = pthread_getspecific(g_tls);
    if (ctx) {
        struct _EAGLContextPrivate *p = ctx->_private;
        if (!osm_make_current(p->osm, p->dummy, DUMMY_W, DUMMY_H)) return NO;
        [ctx retain];
    } else {
        osm_make_current(NULL, NULL, 0, 0);
    }
    pthread_setspecific(g_tls, ctx);
    [old release];
    return YES;
}
+ (EAGLContext *)currentContext { return [[cur_ctx() retain] autorelease]; }

- (EAGLRenderingAPI)API { return _private->api; }
- (EAGLSharegroup *)sharegroup { return _private->sg; }
- (NSString *)debugLabel { return _private->label; }
- (void)setDebugLabel:(NSString *)l { [_private->label release]; _private->label = [l copy]; }
- (BOOL)isMultiThreaded { return _private->multithreaded; }
- (void)setMultiThreaded:(BOOL)m { _private->multithreaded = m; }

// Private parameter store: CoreAnimation reads/writes a few integer parameters; unknown ones just round-trip.
- (NSUInteger)setParameter:(uint32_t)param to:(int *)value { if (param < 64 && value) _private->params[param] = *value; return 0; }
- (NSUInteger)getParameter:(uint32_t)param to:(int *)value { if (value) *value = param < 64 ? _private->params[param] : 0; return 0; }

- (EAGLMacroContext *)getMacroContextPrivate { return _private->macro; }
- (EAGLMacroContext *)GetMacroContextPrivate { return _private->macro; }
+ (EAGLMacroContext *)GetMacroContextPrivate { EAGLContext *c = cur_ctx(); return c ? c->_private->macro : NULL; }

- (BOOL)setBlockFence:(void (^)(void))block onQueue:(dispatch_queue_t)queue {
    EAGLContext *c = cur_ctx();
    if (c == self) shim_glFinish();
    if (block && queue) dispatch_async(queue, block);
    return YES;
}

// --- drawables ---
static DrawBind *find_bind(struct _EAGLContextPrivate *p, GLuint rb) {
    for (int i = 0; i < p->nbinds; i++) if (p->binds[i].rb == rb) return &p->binds[i];
    return NULL;
}

- (BOOL)renderbufferStorage:(NSUInteger)target fromDrawable:(id<EAGLDrawable>)drawable {
    struct _EAGLContextPrivate *p = _private;
    if (cur_ctx() != self || target != GL_RENDERBUFFER) return NO;
    GLint rb = 0;
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    if (!rb) return NO;
    DrawBind *b = find_bind(p, rb);
    if (!drawable) {                                    // drop the storage
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 0, 0);
        if (b) {
            [b->drawable release]; b->drawable = nil;
            for (int k = 0; k < POOL_N; k++) if (b->pool[k]) { CFRelease(b->pool[k]); b->pool[k] = NULL; }
            *b = p->binds[--p->nbinds];
        }
        return YES;
    }
    CGRect r = CGRectZero; CGFloat scale = 1;
    id d = (id)drawable;
    if ([d respondsToSelector:@selector(bounds)]) r = ((CGRect (*)(id, SEL))objc_msgSend)(d, @selector(bounds));
    if ([d respondsToSelector:@selector(contentsScale)]) scale = ((CGFloat (*)(id, SEL))objc_msgSend)(d, @selector(contentsScale));
    if (scale <= 0) scale = 1;
    uint32_t w = (uint32_t)ceil(r.size.width * scale), h = (uint32_t)ceil(r.size.height * scale);
    if (!w || !h) return NO;
    GLenum fmt = GL_RGBA8;
    NSDictionary *props = [d respondsToSelector:@selector(drawableProperties)] ? [d drawableProperties] : nil;
    NSString *cf = props[kEAGLDrawablePropertyColorFormat];
    if ([cf isEqual:kEAGLColorFormatRGB565]) fmt = GL_RGB565;
    else if ([cf isEqual:kEAGLColorFormatSRGBA8]) fmt = GL_SRGB8_ALPHA8;
    glRenderbufferStorage(GL_RENDERBUFFER, fmt, w, h);
    if (glGetError() != GL_NO_ERROR) return NO;
    if (!b) {
        if (p->nbinds >= MAX_BIND) return NO;
        b = &p->binds[p->nbinds++];
        memset(b, 0, sizeof *b);
        b->rb = rb;
    }
    if (b->drawable != d) { [b->drawable release]; b->drawable = [d retain]; }
    if (b->w != w || b->h != h) {
        for (int k = 0; k < POOL_N; k++) if (b->pool[k]) { CFRelease(b->pool[k]); b->pool[k] = NULL; }
    }
    b->w = w; b->h = h; b->fmt = fmt;
    EAGL_DEBUG("renderbuffer %d <- drawable %ux%u\n", rb, w, h);
    return YES;
}

- (BOOL)presentRenderbuffer:(NSUInteger)target {
    struct _EAGLContextPrivate *p = _private;
    if (cur_ctx() != self || target != GL_RENDERBUFFER) return NO;
    GLint rb = 0;
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    DrawBind *b = rb ? find_bind(p, rb) : NULL;
    if (!b) return NO;
    uint32_t w, h;
    uint8_t *buf = read_image(self, rb, NO, 0, 0, &w, &h);
    if (!buf) return NO;
    IOSurfaceRef s = b->pool[b->next];
    if (!s) s = b->pool[b->next] = make_surface(b->w, b->h);
    b->next = (b->next + 1) % POOL_N;
    if (!s) { free(buf); return NO; }
    BOOL opaque = YES;
    if ([b->drawable respondsToSelector:@selector(isOpaque)]) opaque = ((BOOL (*)(id, SEL))objc_msgSend)(b->drawable, @selector(isOpaque));
    rgba_to_surface(buf, w, h, s, YES, opaque);
    free(buf);
    if ([b->drawable respondsToSelector:@selector(setContents:)])
        ((void (*)(id, SEL, id))objc_msgSend)(b->drawable, @selector(setContents:), (id)s);
    return YES;
}
- (BOOL)presentRenderbuffer:(NSUInteger)target atTime:(CFTimeInterval)t { return [self presentRenderbuffer:target]; }
- (BOOL)presentRenderbuffer:(NSUInteger)target afterMinimumDuration:(CFTimeInterval)d { return [self presentRenderbuffer:target]; }

// --- IOSurface ---
- (BOOL)attachImage:(NSUInteger)image toCoreSurface:(IOSurfaceRef)surface invertedRender:(BOOL)inverted {
    struct _EAGLContextPrivate *p = _private;
    int idx = -1;
    for (int i = 0; i < p->natt; i++) if (p->att[i].name == image) idx = i;
    if (!surface) {                                     // detach
        if (idx >= 0) { CFRelease(p->att[idx].surf); p->att[idx] = p->att[--p->natt]; }
        return YES;
    }
    if (idx < 0) {
        if (p->natt >= MAX_BIND) return NO;
        idx = p->natt++;
    } else CFRelease(p->att[idx].surf);
    p->att[idx].name = (GLuint)image; p->att[idx].surf = (IOSurfaceRef)CFRetain(surface); p->att[idx].inverted = inverted;
    EAGL_DEBUG("attachImage %lu -> IOSurface %p inverted=%d\n", (unsigned long)image, surface, inverted);
    return YES;
}

- (BOOL)texImageIOSurface:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane {
    return [self texImageIOSurface:ioSurface target:target internalFormat:internalFormat width:width height:height
                            format:format type:type plane:plane invert:NO];
}

- (BOOL)texImageIOSurface:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane invert:(BOOL)invert {
    if (cur_ctx() != self || !ioSurface || plane != 0) return NO;
    OSType pf = IOSurfaceGetPixelFormat(ioSurface);
    if (pf != 'BGRA' && pf != 'RGBA' && pf != 0) return NO;      // only 8-bit 4 byte surfaces for now
    size_t sw = IOSurfaceGetWidth(ioSurface), sh = IOSurfaceGetHeight(ioSurface);
    uint32_t w = width < sw ? width : (uint32_t)sw, h = height < sh ? height : (uint32_t)sh;
    if (!w || !h) return NO;
    uint32_t *tmp = malloc((size_t)w * h * 4);
    if (!tmp) return NO;
    IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *src = IOSurfaceGetBaseAddress(ioSurface);
    size_t bpr = IOSurfaceGetBytesPerRow(ioSurface);
    for (uint32_t y = 0; y < h; y++) {
        const uint32_t *sp = (const uint32_t *)(src + (invert ? (h - 1 - y) : y) * bpr);
        uint32_t *dp = tmp + (size_t)y * w;
        if (pf == 'RGBA') memcpy(dp, sp, (size_t)w * 4);
        else for (uint32_t x = 0; x < w; x++) { uint32_t q = sp[x]; dp[x] = (q & 0xff00ff00u) | ((q & 0xff) << 16) | ((q >> 16) & 0xff); }
    }
    IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    GLint oldAlign = 4, oldRow = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &oldAlign);
    glGetIntegerv(GL_UNPACK_ROW_LENGTH, &oldRow);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    GLenum ifmt = internalFormat == GL_BGRA_EXT ? GL_RGBA : (GLenum)internalFormat;
    glTexImage2D((GLenum)target, 0, ifmt, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, tmp);
    glPixelStorei(GL_UNPACK_ALIGNMENT, oldAlign);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, oldRow);
    free(tmp);
    return glGetError() == GL_NO_ERROR;
}

@end

#pragma GCC visibility push(default)
// --- C SPI exported by Apple's OpenGLES.framework -------------------------------------------------------
EAGLMacroContext *EAGLGetCurrentMacroContextPrivate(void) {
    EAGLContext *c = cur_ctx();
    return c ? [c getMacroContextPrivate] : NULL;
}
void *GLIContextFromEAGLContext(EAGLContext *c) { return c ? (void *)c->_private : NULL; }
void EAGLMemoryNotificationRecycling(void) {}
// GLC* dispatch-selection entry points: no function-table swapping behind Mesa; accept and ignore.
void GLCBackDispatch(void) {}
void GLCFrontDispatch(void) {}
void *GLCGetProfilerStorage(void) { return NULL; }
void GLCRestoreDispatch(void) {}
void GLCRestoreDispatchFunction(void) {}
void GLCSelectDispatchBounded(void) {}
void GLCSelectDispatchFunction(void) {}
void GLCSetCompilationPerformanceCallback(void) {}
void GLCSetProfilerStorage(void) {}
#pragma GCC visibility pop

#ifdef EAGL_INJECT
static void patch_class(Class ours, const char *realName) {
    Class real = objc_getClass(realName);
    if (!real || !ours) { fprintf(stderr, "EAGL(shim): cannot patch %s\n", realName); return; }
    for (int meta = 0; meta < 2; meta++) {
        Class from = meta ? object_getClass(ours) : ours, to = meta ? object_getClass(real) : real;
        unsigned n = 0;
        Method *ms = class_copyMethodList(from, &n);
        for (unsigned i = 0; i < n; i++)
            class_replaceMethod(to, method_getName(ms[i]), method_getImplementation(ms[i]), method_getTypeEncoding(ms[i]));
        free(ms);
        if (getenv("EAGL_SHIM_DEBUG")) fprintf(stderr, "EAGL(shim): patched %u %s methods of %s\n", n, meta ? "class" : "instance", realName);
    }
}
__attribute__((constructor)) static void eagl_inject_patch(void) {
    patch_class(objc_getClass("BGEAGLContext"), "EAGLContext");
    patch_class(objc_getClass("BGEAGLSharegroup"), "EAGLSharegroup");
}
#endif
