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
#import <mach-o/dyld.h>
#import <pthread.h>
#import <sys/time.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <sys/stat.h>
#import <unistd.h>
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
extern void gl_unimpl(void);
static int g_direct;                // BGL_DIRECT=1 (marker word "direct"): display textures are the surface memory, no blit
static int g_dirty_track = 1;       // copy display-size attachments only when drawn into (default; BGL_SYNC_ALL=1 copies every attachment at every flush). Copying both double-buffered display textures every flush overwrote the idle surface with stale pixels: flicker and a missing wallpaper
static int g_debug, g_debug_frames;   // EAGL_SHIM_DEBUG=1: log + PIPE statistics; =2 also per-frame luminance and thumbnails
static volatile int g_target_attach;      // set once attachImage:<target> was used: the render server's convention (see texImageIOSurface)

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
    int kind;                       // 0 = a GL object name was given, 1 = texture bound at the given target, 2 = renderbuffer
    IOSurfaceRef surf;              // retained
    BOOL inverted;
    int direct;                     // the texture IS the surface memory (BGL_DIRECT): no blit, only finish + BO_SYNC
    int dirty;                      // drawn into (or newly attached) since the last sync: display-size attachments are copied only when dirty
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
    int cur_att;                    // index of the attachment the bound draw framebuffer renders into (colour 0), -1 = none
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
// A display/swap-chain IOSurface can be mapped read-only in this process (a write then dies with SIGBUS / KERN_PROTECTION_FAILURE, seen in
// backboardd): check the mapping before the CPU fallback writes into it.
static BOOL mapping_writable(const void *p, size_t len) {
    // Walk the VM regions covering [p, p+len): every one must exist and be writable (a surface mapping may consist of several regions; the first
    // version required ONE region for the whole range and so skipped legitimate writes: the text/icons of the UI went missing).
    vm_address_t cur = (vm_address_t)p, end = cur + len;
    while (cur < end) {
        vm_address_t addr = cur;
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj;
        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return NO;
        if (addr > cur) return NO;
        if (!(info.protection & VM_PROT_WRITE)) {
            // read-only now, but the mapping may allow write (max protection): raise it. Client-memory surfaces of other processes (the Control
            // Center modules' render targets) arrive this way; skipping their sync left them black.
            if (!(info.max_protection & VM_PROT_WRITE) || vm_protect(mach_task_self(), addr > cur ? addr : cur, size - (cur - addr), FALSE, info.protection | VM_PROT_WRITE) != KERN_SUCCESS) return NO;
        }
        cur = addr + size;
    }
    return YES;
}

static void rgba_to_surface(const uint8_t *src, uint32_t w, uint32_t h, IOSurfaceRef s, BOOL flip, BOOL opaque) {
    kern_return_t lk = IOSurfaceLock(s, 0, NULL);
    uint8_t *dst = lk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(s) : NULL;
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    if (!dst || !mapping_writable(dst, bpr * IOSurfaceGetHeight(s))) {
        if (lk == KERN_SUCCESS) IOSurfaceUnlock(s, 0, NULL);
        EAGL_DEBUG("CPU sync skipped: surface %u is not mapped writable here\n", IOSurfaceGetID(s));
        return;
    }
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

// Debug dump (EAGL_SHIM_DEBUG=1): frames 1, 10 and 60 of the attached-image sync, and any time /private/var/tmp/bgl-dump-now exists, are
// written as PPM files to /private/var/tmp/bgl-dump/: "-gl" = what the GL side holds (renderbuffer/texture read back), "-surf" = what the
// CPU sees in the IOSurface right after our sync. The first pixels and the surface geometry go to the log.
static void dump_ppm(const char *path, const uint8_t *rgba_or_bgra, uint32_t w, uint32_t h, size_t stride, int bgra, BOOL flip) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *row = rgba_or_bgra + (size_t)(flip ? h - 1 - y : y) * stride;
        for (uint32_t x = 0; x < w; x++) {
            const uint8_t *q = row + x * 4;
            fputc(bgra ? q[2] : q[0], f); fputc(q[1], f); fputc(bgra ? q[0] : q[2], f);
        }
    }
    fclose(f);
}
static void maybe_dump(EAGLContext *c, int idx, BOOL isTex, uint32_t gw, uint32_t gh, BOOL gpu_path) {
    static int frame;
    struct _EAGLContextPrivate *p = c->_private;
    Attach *a = &p->att[idx];
    if (idx == 0) frame++;
    int now = access("/private/var/tmp/bgl-dump-now", F_OK) == 0;
    if (now && idx == 0) unlink("/private/var/tmp/bgl-dump-now");     // one-shot: a left-over trigger must not dump every frame (it did, after a reboot)
    if (!(frame == 1 || frame == 10 || frame == 60 || now)) return;
    mkdir("/private/var/tmp/bgl-dump", 0777);
    uint32_t w, h;
    uint8_t *buf = read_image(c, a->name, isTex, gw, gh, &w, &h);
    char path[256];
    if (buf) { snprintf(path, sizeof path, "/private/var/tmp/bgl-dump/f%d-a%d-gl.ppm", frame, idx); dump_ppm(path, buf, w, h, (size_t)w * 4, 0, YES); }
    kern_return_t dlk = IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *sp = dlk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(a->surf) : NULL;
    if (!sp) { fprintf(stderr, "EAGL(shim): dump frame %d: surface %u has no CPU mapping (lock %x)\n", frame, IOSurfaceGetID(a->surf), dlk); if (dlk == KERN_SUCCESS) IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL); free(buf); return; }
    size_t bpr = IOSurfaceGetBytesPerRow(a->surf);
    uint32_t sw = (uint32_t)IOSurfaceGetWidth(a->surf), sh = (uint32_t)IOSurfaceGetHeight(a->surf);
    OSType pf = IOSurfaceGetPixelFormat(a->surf);
    fprintf(stderr, "EAGL(shim): dump frame %d attach %d name %u %s: surface %u %ux%u fmt %08x stride %zu inverted %d gpu_blit %d, GL image %ux%u; first pixels (bytes) %02x%02x%02x%02x %02x%02x%02x%02x, centre %02x%02x%02x%02x\n",
            frame, idx, a->name, isTex ? "texture" : "renderbuffer", IOSurfaceGetID(a->surf), sw, sh, (unsigned)pf, bpr, a->inverted, gpu_path, w, h,
            sp[0], sp[1], sp[2], sp[3], sp[4], sp[5], sp[6], sp[7],
            sp[(sh / 2) * bpr + (sw / 2) * 4], sp[(sh / 2) * bpr + (sw / 2) * 4 + 1], sp[(sh / 2) * bpr + (sw / 2) * 4 + 2], sp[(sh / 2) * bpr + (sw / 2) * 4 + 3]);
    if (pf == 'BGRA') { snprintf(path, sizeof path, "/private/var/tmp/bgl-dump/f%d-a%d-surf.ppm", frame, idx); dump_ppm(path, sp, sw, sh, bpr, 1, NO); }
    IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL);
    free(buf);
}

// Per-frame statistics for display-size surfaces (EAGL_SHIM_DEBUG): time since the previous sync, duration of the blit, and a sampled average
// luminance / fraction of black samples of what the CPU sees in the surface afterwards. A flashing display shows up as black or stale frames.
static double now_ms(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec * 1e3 + tv.tv_usec / 1e3; }
static void frame_stats(Attach *a, double t_start, double t_end, int gpu) {
    static double last_t, t0; static int n;
    size_t w = IOSurfaceGetWidth(a->surf), h = IOSurfaceGetHeight(a->surf);
    if (w < 1000 || h < 2000 || n > 3000 || !g_debug_frames) return;
    if (!t0) t0 = t_start;
    double lum = -1, black = -1;
    kern_return_t lk = IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *sp = lk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(a->surf) : NULL;
    if (sp && IOSurfaceGetPixelFormat(a->surf) == 'BGRA') {
        size_t bpr = IOSurfaceGetBytesPerRow(a->surf), cnt = 0, blk = 0; double sum = 0;
        for (size_t y = 3; y < h; y += 61) for (size_t x = 5; x < w; x += 53) { const uint8_t *q = sp + y * bpr + x * 4; sum += (q[0] + q[1] + q[2]) / 3.0; if (q[0] + q[1] + q[2] < 6) blk++; cnt++; }
        lum = sum / cnt; black = (double)blk / cnt;
    }
    if (lk == KERN_SUCCESS) IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL);
    // thumbnails (1/16 scale) of the first 80 syncs: /private/var/tmp/bgl-thumbs.bin = repeated { u32 index, u32 surface, u32 w, u32 h, w*h*3 RGB } (contact sheet on the Mac)
    {
        static uint8_t *tb; static size_t tlen; enum { TW = 71, TH = 153, MAXF = 80 };
        if (n < MAXF && sp == NULL) { /* surface unreadable: nothing */ }
        if (n < MAXF) {
            if (!tb) tb = malloc((size_t)MAXF * (16 + TW * TH * 3));
            kern_return_t lk2 = IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL);
            const uint8_t *sp2 = lk2 == KERN_SUCCESS ? IOSurfaceGetBaseAddress(a->surf) : NULL;
            if (tb && sp2 && IOSurfaceGetPixelFormat(a->surf) == 'BGRA') {
                size_t bpr = IOSurfaceGetBytesPerRow(a->surf);
                uint32_t *hd = (uint32_t *)(tb + tlen); hd[0] = n + 1; hd[1] = IOSurfaceGetID(a->surf); hd[2] = TW; hd[3] = TH;
                uint8_t *o = tb + tlen + 16;
                for (int y = 0; y < TH; y++) for (int x = 0; x < TW; x++) { const uint8_t *q = sp2 + (size_t)(y * 16) * bpr + (size_t)(x * 16) * 4; *o++ = q[2]; *o++ = q[1]; *o++ = q[0]; }
                tlen += 16 + TW * TH * 3;
                if (n + 1 == MAXF) { FILE *f = fopen("/private/var/tmp/bgl-thumbs.bin", "wb"); if (f) { fwrite(tb, 1, tlen, f); fclose(f); } fprintf(stderr, "EAGL(shim): thumbnails written (%zu bytes)\n", tlen); }
            }
            if (lk2 == KERN_SUCCESS) IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL);
        }
    }
    fprintf(stderr, "EAGL(shim): FS #%d t=%.0f dt=%.1f blit=%.1fms surf=%u gpu=%d lum=%.1f black=%.2f\n", ++n, t_end - t0, last_t ? t_start - last_t : 0.0, t_end - t_start, IOSurfaceGetID(a->surf), gpu, lum, black);
    last_t = t_start;
}

// Pipeline statistics (EAGL_SHIM_DEBUG): per interval of 60 display-size syncs, where the time goes. glflush = time inside Mesa's glFlush (batch
// submit), blit = enqueue / render-wait (GPU time of the client's drawing, forced by a finish) / copy-wait (GPU time of the blit) / BO_SYNC,
// cpu = surfaces copied through the CPU (read_image + rgba_to_surface). In this mode the extra finish makes frames slower than they are normally.
static unsigned g_mark_hit, g_mark_miss, g_draw_seen;
static double g_ps_direct_ms; static int g_ps_direct_n;
static double g_ps_flush_ms, g_ps_cpu_ms; static int g_ps_cpu_n, g_ps_syncs, g_ps_skipped;
static void pipe_stats_report(void) {
    static double last[8], last_flush, last_cpu, last_t; static int last_cpu_n, last_syncs;
    double st[8]; osm_sweet_stats(st, 8);
    double now = now_ms(), dn = g_ps_syncs - last_syncs; if (dn < 1) return;
    fprintf(stderr, "EAGL(shim): PIPE %d syncs in %.0f ms (%.1f ms/sync): glFlush %.2f | gpu blits %.0f refused %.0f | render-wait %.2f enqueue %.2f copy-wait %.2f bo_sync %.2f lookup %.2f | cpu copies %d %.2f ms (per sync) | direct display syncs %d %.2f ms each | display copies skipped (clean) %d | draws marking an attachment %u, other draws %u\n",
            (int)dn, now - last_t, (now - last_t) / dn, (g_ps_flush_ms - last_flush) / dn, st[0] - last[0], st[6] - last[6],
            (st[1] - last[1]) / dn, (st[2] - last[2]) / dn, (st[3] - last[3]) / dn, (st[4] - last[4]) / dn, (st[5] - last[5]) / dn,
            g_ps_cpu_n - last_cpu_n, (g_ps_cpu_ms - last_cpu) / dn, g_ps_direct_n, g_ps_direct_n ? g_ps_direct_ms / g_ps_direct_n : 0.0, g_ps_skipped, g_mark_hit, g_mark_miss);
    memcpy(last, st, sizeof st); last_flush = g_ps_flush_ms; last_cpu = g_ps_cpu_ms; last_t = now; last_cpu_n = g_ps_cpu_n; last_syncs = g_ps_syncs;
}

// Flush every attachImage: association of this context into its IOSurface.
static void sync_attached(EAGLContext *c) {
    struct _EAGLContextPrivate *p = c->_private;
    // Safety net: GL work happened but nothing was attributed to an attachment (a render path the tracking does not see): copy everything this flush.
    BOOL force_all = NO;
    if (g_dirty_track) {
        BOOL any = NO; for (int i = 0; i < p->natt; i++) if (p->att[i].dirty) any = YES;
        force_all = !any && g_draw_seen > 0 && p->cur_att < 0;
        g_draw_seen = 0;
    }
    for (int i = 0; i < p->natt; i++) {
        Attach *a = &p->att[i];
        if (g_dirty_track && !force_all && !a->dirty && IOSurfaceGetWidth(a->surf) * IOSurfaceGetHeight(a->surf) >= 1000000) { g_ps_skipped++; continue; }   // display buffer nobody drew into
        a->dirty = 0;
        if (a->direct) { double td = g_debug ? now_ms() : 0; osm_sweet_direct_sync(IOSurfaceGetID(a->surf)); if (g_debug) { g_ps_direct_ms += now_ms() - td; g_ps_direct_n++; } continue; }
        BOOL isTex = a->kind ? (a->kind == 1) : (glIsTexture(a->name) && !glIsRenderbuffer(a->name));
        // Hardware path: the GPU copies the image into the surface (no readback); GL rows are bottom-up, `inverted` means the surface wants them as they are.
        double t_start = g_debug ? now_ms() : 0;
        BOOL flip = a->kind ? a->inverted : !a->inverted;      // target-form attach (the render server): YES = rows flipped, NO = as GL has them (seen on the phone: NO + flip drew the UI upside down)
        if (osm_sweet_active() && osm_sweet_blit(a->name, isTex, IOSurfaceGetID(a->surf), flip, NO)) {
            if (g_debug) { frame_stats(a, t_start, now_ms(), 1); maybe_dump(c, i, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), YES); }
            continue;
        }
        uint32_t w, h;
        double t_cpu0 = g_debug ? now_ms() : 0;
        uint8_t *buf = read_image(c, a->name, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), &w, &h);
        if (buf) {
            // GL rows are bottom-up; a "normal" surface is top-down. invertedRender means CA already drew it flipped.
            rgba_to_surface(buf, w, h, a->surf, flip, NO);
            free(buf);
        }
        if (g_debug) { g_ps_cpu_ms += now_ms() - t_cpu0; g_ps_cpu_n++; }
        if (g_debug) { frame_stats(a, t_start, now_ms(), 0); maybe_dump(c, i, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), NO); }
    }
}

// glFlush / glFinish wrappers installed over the Mesa entry points (see eagl_install_hooks).
static void (*mesa_glFlush)(void), (*mesa_glFinish)(void);
static void pipe_count_sync(EAGLContext *c) {
    if (!g_debug || !c->_private->natt) return;
    size_t w = 0, h = 0; for (int i = 0; i < c->_private->natt; i++) { size_t aw = IOSurfaceGetWidth(c->_private->att[i].surf); if (aw > w) { w = aw; h = IOSurfaceGetHeight(c->_private->att[i].surf); } }
    if (w >= 1000 && h >= 2000 && ++g_ps_syncs % 60 == 0) pipe_stats_report();
}
static void shim_glFlush(void) { double t = g_debug ? now_ms() : 0; mesa_glFlush(); if (g_debug) g_ps_flush_ms += now_ms() - t; EAGLContext *c = cur_ctx(); if (c && c->_private->natt) { sync_attached(c); pipe_count_sync(c); } }
static void shim_glFinish(void) { double t = g_debug ? now_ms() : 0; mesa_glFinish(); if (g_debug) g_ps_flush_ms += now_ms() - t; EAGLContext *c = cur_ctx(); if (c && c->_private->natt) { sync_attached(c); pipe_count_sync(c); } }

// Dirty tracking of the display-size attachments: the render server draws into one texture per frame (through an FBO) and flushes; copying both of its
// double-buffered display textures at every flush doubled the cost of a frame. Draw/clear entry points mark the attachment the bound FBO renders into,
// FBO binding changes recompute which attachment that is, and sync_attached copies display-size attachments only when marked.
static BOOL att_is_tex(Attach *a) { return a->kind ? a->kind == 1 : (glIsTexture(a->name) && !glIsRenderbuffer(a->name)); }
static void update_cur_target(EAGLContext *c) {
    struct _EAGLContextPrivate *p = c->_private;
    p->cur_att = -1;
    if (!p->natt) return;
    GLint fb = 0, type = 0, name = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    if (!fb) { if (g_debug) { static int n; if (n++ < 20) fprintf(stderr, "EAGL(shim): FBO tracking: no framebuffer bound (%d attachments)\n", p->natt); } return; }
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &name);
    if (type != GL_TEXTURE && type != GL_RENDERBUFFER) return;
    for (int i = 0; i < p->natt; i++) if ((GLint)p->att[i].name == name && att_is_tex(&p->att[i]) == (type == GL_TEXTURE)) { p->cur_att = i; break; }
    if (g_debug) { static int n; if (n++ < 60) fprintf(stderr, "EAGL(shim): [ctx %p] FBO %d colour0 type 0x%x name %d -> attachment %d (of %d)\n", c, fb, type, name, p->cur_att, p->natt); }
}
static inline void mark_cur_dirty(void) { EAGLContext *c = cur_ctx(); if (c && c->_private->cur_att >= 0 && c->_private->cur_att < c->_private->natt) { c->_private->att[c->_private->cur_att].dirty = 1; g_mark_hit++; } else g_mark_miss++; g_draw_seen++; }
static void (*o_DrawArrays)(GLenum, GLint, GLsizei);
static void h_DrawArrays(GLenum a, GLint b, GLsizei c) { mark_cur_dirty(); o_DrawArrays(a, b, c); }
static void (*o_DrawElements)(GLenum, GLsizei, GLenum, const void *);
static void h_DrawElements(GLenum a, GLsizei b, GLenum c, const void *d) { mark_cur_dirty(); o_DrawElements(a, b, c, d); }
static void (*o_DrawArraysInstanced)(GLenum, GLint, GLsizei, GLsizei);
static void h_DrawArraysInstanced(GLenum a, GLint b, GLsizei c, GLsizei d) { mark_cur_dirty(); o_DrawArraysInstanced(a, b, c, d); }
static void (*o_DrawElementsInstanced)(GLenum, GLsizei, GLenum, const void *, GLsizei);
static void h_DrawElementsInstanced(GLenum a, GLsizei b, GLenum c, const void *d, GLsizei e) { mark_cur_dirty(); o_DrawElementsInstanced(a, b, c, d, e); }
static void (*o_DrawRangeElements)(GLenum, GLuint, GLuint, GLsizei, GLenum, const void *);
static void h_DrawRangeElements(GLenum a, GLuint b, GLuint c, GLsizei d, GLenum e, const void *f) { mark_cur_dirty(); o_DrawRangeElements(a, b, c, d, e, f); }
static void (*o_Clear)(GLbitfield);
static void h_Clear(GLbitfield m) { mark_cur_dirty(); o_Clear(m); }
static void (*o_ClearBufferfv)(GLenum, GLint, const GLfloat *);
static void h_ClearBufferfv(GLenum a, GLint b, const GLfloat *c) { mark_cur_dirty(); o_ClearBufferfv(a, b, c); }
static void mark_bound_texture_dirty(void) {     // texture writes (upload / copy) land in the texture bound to GL_TEXTURE_2D
    EAGLContext *c = cur_ctx(); if (!c || !c->_private->natt) return;
    GLint t = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
    for (int i = 0; i < c->_private->natt; i++) if ((GLint)c->_private->att[i].name == t && att_is_tex(&c->_private->att[i])) c->_private->att[i].dirty = 1;
    g_draw_seen++;
}
static void (*o_ClearBufferiv)(GLenum, GLint, const GLint *);
static void h_ClearBufferiv(GLenum a, GLint b, const GLint *c) { mark_cur_dirty(); o_ClearBufferiv(a, b, c); }
static void (*o_ClearBufferuiv)(GLenum, GLint, const GLuint *);
static void h_ClearBufferuiv(GLenum a, GLint b, const GLuint *c) { mark_cur_dirty(); o_ClearBufferuiv(a, b, c); }
static void (*o_ClearBufferfi)(GLenum, GLint, GLfloat, GLint);
static void h_ClearBufferfi(GLenum a, GLint b, GLfloat c, GLint d) { mark_cur_dirty(); o_ClearBufferfi(a, b, c, d); }
static void (*o_BlitFramebuffer)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
static void h_BlitFramebuffer(GLint a, GLint b, GLint c, GLint d, GLint e, GLint f, GLint g, GLint h, GLbitfield i, GLenum j) { mark_cur_dirty(); o_BlitFramebuffer(a, b, c, d, e, f, g, h, i, j); }
static void (*o_CopyTexImage2D)(GLenum, GLint, GLenum, GLint, GLint, GLsizei, GLsizei, GLint);
static void h_CopyTexImage2D(GLenum a, GLint b, GLenum c, GLint d, GLint e, GLsizei f, GLsizei g, GLint h) { o_CopyTexImage2D(a, b, c, d, e, f, g, h); mark_bound_texture_dirty(); }
static void (*o_CopyTexSubImage2D)(GLenum, GLint, GLint, GLint, GLint, GLint, GLsizei, GLsizei);
static void h_CopyTexSubImage2D(GLenum a, GLint b, GLint c, GLint d, GLint e, GLint f, GLsizei g, GLsizei h) { o_CopyTexSubImage2D(a, b, c, d, e, f, g, h); mark_bound_texture_dirty(); }
static void (*o_TexSubImage2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *);
static void h_TexSubImage2D(GLenum a, GLint b, GLint c, GLint d, GLsizei e, GLsizei f, GLenum g, GLenum h, const void *i) { o_TexSubImage2D(a, b, c, d, e, f, g, h, i); mark_bound_texture_dirty(); }
static void (*o_DeleteTextures)(GLsizei, const GLuint *);
static void h_DeleteTextures(GLsizei n, const GLuint *t) {
    if (g_debug) { EAGLContext *c = cur_ctx(); if (c) for (GLsizei i = 0; i < n; i++) for (int k = 0; k < c->_private->natt; k++) if (c->_private->att[k].name == t[i] && att_is_tex(&c->_private->att[k])) fprintf(stderr, "EAGL(shim): [ctx %p] glDeleteTextures(%u) deletes a display attachment (surface %u)\n", c, t[i], IOSurfaceGetID(c->_private->att[k].surf)); }
    o_DeleteTextures(n, t);
}
static void (*o_BindFramebuffer)(GLenum, GLuint);
static void h_BindFramebuffer(GLenum t, GLuint f) { o_BindFramebuffer(t, f); EAGLContext *c = cur_ctx(); if (c) update_cur_target(c); }
static void (*o_FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
static void h_FramebufferTexture2D(GLenum a, GLenum b, GLenum c, GLuint d, GLint e) { o_FramebufferTexture2D(a, b, c, d, e); EAGLContext *x = cur_ctx(); if (x) update_cur_target(x); }
static void (*o_FramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
static void h_FramebufferRenderbuffer(GLenum a, GLenum b, GLenum c, GLuint d) { o_FramebufferRenderbuffer(a, b, c, d); EAGLContext *x = cur_ctx(); if (x) update_cur_target(x); }
static void (*o_DeleteFramebuffers)(GLsizei, const GLuint *);
static void h_DeleteFramebuffers(GLsizei n, const GLuint *f) { o_DeleteFramebuffers(n, f); EAGLContext *x = cur_ctx(); if (x) update_cur_target(x); }
static const struct { const char *name; void **orig; void *hook; } g_dirty_hooks[] = {
    { "glDrawArrays", (void **)&o_DrawArrays, h_DrawArrays }, { "glDrawElements", (void **)&o_DrawElements, h_DrawElements },
    { "glDrawArraysInstanced", (void **)&o_DrawArraysInstanced, h_DrawArraysInstanced }, { "glDrawElementsInstanced", (void **)&o_DrawElementsInstanced, h_DrawElementsInstanced },
    { "glDrawRangeElements", (void **)&o_DrawRangeElements, h_DrawRangeElements }, { "glClear", (void **)&o_Clear, h_Clear }, { "glClearBufferfv", (void **)&o_ClearBufferfv, h_ClearBufferfv },
    { "glClearBufferiv", (void **)&o_ClearBufferiv, h_ClearBufferiv }, { "glClearBufferuiv", (void **)&o_ClearBufferuiv, h_ClearBufferuiv }, { "glClearBufferfi", (void **)&o_ClearBufferfi, h_ClearBufferfi },
    { "glBlitFramebuffer", (void **)&o_BlitFramebuffer, h_BlitFramebuffer }, { "glCopyTexImage2D", (void **)&o_CopyTexImage2D, h_CopyTexImage2D },
    { "glCopyTexSubImage2D", (void **)&o_CopyTexSubImage2D, h_CopyTexSubImage2D }, { "glTexSubImage2D", (void **)&o_TexSubImage2D, h_TexSubImage2D },
    { "glDeleteTextures", (void **)&o_DeleteTextures, h_DeleteTextures },
    { "glBindFramebuffer", (void **)&o_BindFramebuffer, h_BindFramebuffer }, { "glFramebufferTexture2D", (void **)&o_FramebufferTexture2D, h_FramebufferTexture2D },
    { "glFramebufferRenderbuffer", (void **)&o_FramebufferRenderbuffer, h_FramebufferRenderbuffer }, { "glDeleteFramebuffers", (void **)&o_DeleteFramebuffers, h_DeleteFramebuffers },
};

static void eagl_install_hooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gl_resolve_all();
        for (int i = 0; i < gl_nfuncs; i++) {
            if (!strcmp(gl_names[i], "glFlush")) { mesa_glFlush = gl_tab[i]; gl_tab[i] = (void *)shim_glFlush; }
            if (!strcmp(gl_names[i], "glFinish")) { mesa_glFinish = gl_tab[i]; gl_tab[i] = (void *)shim_glFinish; }
        }
        g_debug = getenv("EAGL_SHIM_DEBUG") != NULL; g_debug_frames = g_debug && !strcmp(getenv("EAGL_SHIM_DEBUG"), "2");
        g_dirty_track = !getenv("BGL_SYNC_ALL");
        g_direct = getenv("BGL_DIRECT") != NULL;
        if (g_dirty_track) {
            // every alias of an entry point is hooked (glBindFramebuffer / glBindFramebufferOES / ...: the render server's slots may use either spelling)
            static const char *const sfx[] = { "", "OES", "EXT", "ARB", "APPLE", "ANGLE" };
            for (int i = 0; i < gl_nfuncs; i++)
                for (unsigned k = 0; k < sizeof g_dirty_hooks / sizeof g_dirty_hooks[0]; k++) {
                    size_t n = strlen(g_dirty_hooks[k].name);
                    if (strncmp(gl_names[i], g_dirty_hooks[k].name, n) || gl_tab[i] == (void *)gl_unimpl) continue;
                    BOOL ok = NO; for (unsigned q = 0; q < 6; q++) if (!strcmp(gl_names[i] + n, sfx[q])) ok = YES;
                    if (!ok) continue;
                    if (!*g_dirty_hooks[k].orig) *g_dirty_hooks[k].orig = gl_tab[i];
                    if (g_debug) fprintf(stderr, "EAGL(shim): dirty-tracking hook on %s\n", gl_names[i]);
                    gl_tab[i] = g_dirty_hooks[k].hook;
                }
            for (unsigned k = 0; k < sizeof g_dirty_hooks / sizeof g_dirty_hooks[0]; k++) if (!*g_dirty_hooks[k].orig) g_dirty_track = 0;   // an entry point missing: cannot track reliably
        }
        if (g_debug) {                  // list the exported entry points Mesa could not provide
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
        EAGL_DEBUG("context %p created api %d sharegroup %p osm %p shared-with %p\n", self, (int)api, p->sg, p->osm, share);
        p->macro = macro_ctx_new(p);   // rend = our private block; the slots ignore it (Mesa uses the thread's current context)
    }
    return self;
}

- (void)dealloc {
    struct _EAGLContextPrivate *p = _private;
    EAGL_DEBUG("context %p dealloc (%d attachments, osm %p)\n", self, p ? p->natt : -1, p ? p->osm : NULL);
    if (p) {
        if (cur_ctx() == self) [EAGLContext setCurrentContext:nil];
        for (int i = 0; i < p->nbinds; i++) {
            [p->binds[i].drawable release];
            for (int k = 0; k < POOL_N; k++) if (p->binds[i].pool[k]) { osm_sweet_forget(IOSurfaceGetID(p->binds[i].pool[k])); CFRelease(p->binds[i].pool[k]); }
        }
        for (int i = 0; i < p->natt; i++) if (p->att[i].surf) { osm_sweet_forget(IOSurfaceGetID(p->att[i].surf)); CFRelease(p->att[i].surf); }
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
            for (int k = 0; k < POOL_N; k++) if (b->pool[k]) { osm_sweet_forget(IOSurfaceGetID(b->pool[k])); CFRelease(b->pool[k]); b->pool[k] = NULL; }
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
        for (int k = 0; k < POOL_N; k++) if (b->pool[k]) { osm_sweet_forget(IOSurfaceGetID(b->pool[k])); CFRelease(b->pool[k]); b->pool[k] = NULL; }
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
    BOOL opaque = YES;
    if ([b->drawable respondsToSelector:@selector(isOpaque)]) opaque = ((BOOL (*)(id, SEL))objc_msgSend)(b->drawable, @selector(isOpaque));
    IOSurfaceRef s = b->pool[b->next];
    if (!s) s = b->pool[b->next] = make_surface(b->w, b->h);
    b->next = (b->next + 1) % POOL_N;
    if (!s) return NO;
    if (!(osm_sweet_active() && osm_sweet_blit((unsigned)rb, 0, IOSurfaceGetID(s), 1, opaque))) {     // CPU fallback (softpipe, or a surface the GPU cannot use)
        uint32_t w, h;
        uint8_t *buf = read_image(self, rb, NO, 0, 0, &w, &h);
        if (!buf) return NO;
        rgba_to_surface(buf, w, h, s, YES, opaque);
        free(buf);
    }
    if ([b->drawable respondsToSelector:@selector(setContents:)])
        ((void (*)(id, SEL, id))objc_msgSend)(b->drawable, @selector(setContents:), (id)s);
    return YES;
}
- (BOOL)presentRenderbuffer:(NSUInteger)target atTime:(CFTimeInterval)t { return [self presentRenderbuffer:target]; }
- (BOOL)presentRenderbuffer:(NSUInteger)target afterMinimumDuration:(CFTimeInterval)d { return [self presentRenderbuffer:target]; }

// --- IOSurface ---
- (BOOL)attachImage:(NSUInteger)image toCoreSurface:(IOSurfaceRef)surface invertedRender:(BOOL)inverted {
    // `image` is a GL TARGET (CoreAnimation passes GL_TEXTURE_2D = 3553, found by dumping the server's calls on the phone): the image
    // currently bound at that target gets the IOSurface as its storage. A plain object name (our own tests) is still accepted.
    struct _EAGLContextPrivate *p = _private;
    int kind = 0;
    BOOL direct = NO;
    GLuint name = (GLuint)image;
    if (surface && (image == GL_TEXTURE_2D || image == GL_RENDERBUFFER || image == 0x84f5)) g_target_attach = 1;
    if (surface && (image == GL_TEXTURE_2D || image == GL_RENDERBUFFER || image == 0x84f5 /* TEXTURE_RECTANGLE */)) {
        GLint bound = 0;
        if (image == GL_RENDERBUFFER) { glGetIntegerv(GL_RENDERBUFFER_BINDING, &bound); kind = 2; }
        else { glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound); kind = 1; }
        if (!bound) return NO;
        name = (GLuint)bound;
        uint32_t w = (uint32_t)IOSurfaceGetWidth(surface), h = (uint32_t)IOSurfaceGetHeight(surface);
        if (kind == 2) glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
        else {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            if (g_direct && !inverted && osm_sweet_active() && IOSurfaceGetPixelFormat(surface) == 'BGRA' && osm_sweet_attach_direct(name, IOSurfaceGetID(surface))) direct = YES;
            // keep what the surface already shows: CoreAnimation redraws only the damaged part of a swap-chain buffer
            else if (IOSurfaceGetPixelFormat(surface) == 'BGRA')
                [self texImageIOSurface:surface target:GL_TEXTURE_2D internalFormat:GL_RGBA width:w height:h format:GL_BGRA_EXT type:GL_UNSIGNED_BYTE plane:0 invert:!inverted];   // same row order as the sync
        }
        if (glGetError() != GL_NO_ERROR) EAGL_DEBUG("attachImage: storage for %ux%u failed\n", w, h);
    }
    int idx = -1;
    for (int i = 0; i < p->natt; i++) if (p->att[i].name == name && p->att[i].kind == kind) idx = i;
    if (!surface) {                                     // detach
        if (idx >= 0) { osm_sweet_forget(IOSurfaceGetID(p->att[idx].surf)); CFRelease(p->att[idx].surf); p->att[idx] = p->att[--p->natt]; update_cur_target(self); }
        return YES;
    }
    if (idx < 0) {
        if (p->natt >= MAX_BIND) return NO;
        idx = p->natt++;
    } else { osm_sweet_forget(IOSurfaceGetID(p->att[idx].surf)); CFRelease(p->att[idx].surf); }
    p->att[idx].name = name; p->att[idx].kind = kind; p->att[idx].surf = (IOSurfaceRef)CFRetain(surface); p->att[idx].inverted = inverted; p->att[idx].dirty = 1; p->att[idx].direct = direct;
    // CoreAnimation attaches a NEW texture to the same display surface every frame; the earlier textures keep older pixels. Syncing them all wrote
    // those stale images over the surface in array order (the flicker, the black wallpaper): only the latest attachment of a surface is valid.
    for (int j = p->natt - 1; j >= 0; j--) {
        if (j == idx || IOSurfaceGetID(p->att[j].surf) != IOSurfaceGetID(surface)) continue;
        CFRelease(p->att[j].surf);
        if (idx == p->natt - 1) idx = j;      // the last entry moves into slot j
        p->att[j] = p->att[--p->natt];
    }
    update_cur_target(self);
    EAGL_DEBUG("[ctx %p] attachImage %lu -> %s %u, IOSurface %u (%zux%zu) inverted=%d\n", self, (unsigned long)image, kind == 2 ? "renderbuffer" : kind == 1 ? "texture" : "object", name,
               IOSurfaceGetID(surface), IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), inverted);
    return YES;
}

- (BOOL)texImageIOSurface:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane {
    return [self texImageIOSurface:ioSurface target:target internalFormat:internalFormat width:width height:height
                            format:format type:type plane:plane invert:YES];   // public form: rows as stored
}

- (BOOL)texImageIOSurface:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane invert:(BOOL)invert {
    EAGL_DEBUG("texImageIOSurface %p target 0x%lx ifmt 0x%lx %ux%u fmt 0x%lx type 0x%lx invert %d\n", ioSurface, (unsigned long)target, (unsigned long)internalFormat, width, height, (unsigned long)format, (unsigned long)type, invert);
    if (cur_ctx() != self || !ioSurface || plane != 0) return NO;
    OSType pf = IOSurfaceGetPixelFormat(ioSurface);
    size_t sw = IOSurfaceGetWidth(ioSurface), sh = IOSurfaceGetHeight(ioSurface);
    uint32_t w = width < sw ? width : (uint32_t)sw, h = height < sh ? height : (uint32_t)sh;
    if (!w || !h) return NO;
    // Bytes per texel from the GL format/type CoreAnimation asks for (it uploads A8 masks, LA8, RGBA half float gradients, BGRA ...).
    size_t comps = 0, csz = 1;
    switch (format) {
    case 0x1906: case 0x1909: case 0x1903: comps = 1; break;                 // ALPHA, LUMINANCE, RED
    case 0x190a: case 0x8227: comps = 2; break;                              // LUMINANCE_ALPHA, RG
    case 0x1907: comps = 3; break;                                           // RGB
    case 0x1908: case GL_BGRA_EXT: comps = 4; break;                         // RGBA, BGRA
    default: return NO;
    }
    switch (type) {
    case 0x1401: csz = 1; break;                                             // UNSIGNED_BYTE
    case 0x140b: case 0x8d61: csz = 2; break;                                // HALF_FLOAT(_OES)
    case 0x1406: csz = 4; break;                                             // FLOAT
    case 0x8363: case 0x8033: case 0x8034: comps = 1; csz = 2; break;        // packed 16 bit
    case 0x8368: comps = 1; csz = 4; break;                                  // UNSIGNED_INT_2_10_10_10_REV
    default: return NO;
    }
    size_t bpp = comps * csz, bpr = IOSurfaceGetBytesPerRow(ioSurface);
    if (w * bpp > bpr) return NO;
    BOOL bgra8 = (format == GL_BGRA_EXT && type == 0x1401);                  // swizzled to RGBA below (portable across ES implementations)
    uint8_t *tmp = malloc((size_t)w * h * bpp);
    if (!tmp) return NO;
    kern_return_t lk = IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *src = lk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(ioSurface) : NULL;
    if (!src) {                         // not CPU-mappable here (the render server's display surfaces): nothing to read
        if (lk == KERN_SUCCESS) IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
        EAGL_DEBUG("texImageIOSurface: surface %u has no CPU mapping (lock %x)\n", IOSurfaceGetID(ioSurface), lk);
        free(tmp);
        return NO;
    }
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *sp = src + ((invert || g_target_attach) ? y : (h - 1 - y)) * bpr;   // render server (target-form attach): images keep their native top-down rows; CARenderer-style clients: flipped unless invert
        uint8_t *dp = tmp + (size_t)y * w * bpp;
        if (bgra8) for (uint32_t x = 0; x < w; x++) { uint32_t q = ((const uint32_t *)sp)[x]; ((uint32_t *)dp)[x] = (q & 0xff00ff00u) | ((q & 0xff) << 16) | ((q >> 16) & 0xff); }
        else memcpy(dp, sp, (size_t)w * bpp);
    }
    IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    (void)pf;
    GLint oldAlign = 4, oldRow = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &oldAlign);
    glGetIntegerv(GL_UNPACK_ROW_LENGTH, &oldRow);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    GLenum ifmt = internalFormat == GL_BGRA_EXT ? GL_RGBA : (GLenum)internalFormat;
    glTexImage2D((GLenum)target, 0, ifmt, w, h, 0, bgra8 ? GL_RGBA : (GLenum)format, (GLenum)type, tmp);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) EAGL_DEBUG("  glTexImage2D failed 0x%x (ifmt 0x%lx fmt 0x%lx type 0x%lx)\n", err, (unsigned long)internalFormat, (unsigned long)format, (unsigned long)type);
    // IOSurface textures have no mip chain: make the texture complete with sane defaults (the client overrides them if it cares).
    glTexParameteri((GLenum)target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri((GLenum)target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, oldAlign);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, oldRow);
    free(tmp);
    return err == GL_NO_ERROR;
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
static int patch_class(Class ours, const char *realName) {
    Class real = objc_getClass(realName);
    if (!real || !ours) return 0;
    for (int meta = 0; meta < 2; meta++) {
        Class from = meta ? object_getClass(ours) : ours, to = meta ? object_getClass(real) : real;
        unsigned n = 0;
        Method *ms = class_copyMethodList(from, &n);
        for (unsigned i = 0; i < n; i++)
            class_replaceMethod(to, method_getName(ms[i]), method_getImplementation(ms[i]), method_getTypeEncoding(ms[i]));
        free(ms);
        if (getenv("EAGL_SHIM_DEBUG")) fprintf(stderr, "EAGL(shim): patched %u %s methods of %s\n", n, meta ? "class" : "instance", realName);
    }
    return 1;
}
// The inserted library initializes before the process links OpenGLES in some cases: patch as soon as the real classes exist
// (now, or when a later image load brings them), exactly once.
static void try_patch(void) {
    static int done;
    if (done) return;
    if (objc_getClass("EAGLContext") && objc_getClass("EAGLSharegroup")) {
        patch_class(objc_getClass("BGEAGLContext"), "EAGLContext");
        patch_class(objc_getClass("BGEAGLSharegroup"), "EAGLSharegroup");
        done = 1;
    }
}
static void on_image(const struct mach_header *mh, intptr_t slide) { (void)mh; (void)slide; try_patch(); }
__attribute__((constructor)) static void eagl_inject_patch(void) {
    try_patch();
    _dyld_register_func_for_add_image(on_image);
}
#endif
