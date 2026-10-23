// SPDX-License-Identifier: MIT
#include <stddef.h>
#include <GL/osmesa.h>
#include "osm.h"

#define OSMESA_ES_PROFILE 0x36      // added by gpu/eagl/mesa/0001-osmesa-es-profile.patch

osm_ctx osm_create(int es_api, osm_ctx share) {
    const int attr[] = {
        OSMESA_FORMAT, OSMESA_RGBA, OSMESA_DEPTH_BITS, 0, OSMESA_STENCIL_BITS, 0,
        OSMESA_PROFILE, OSMESA_ES_PROFILE,
        OSMESA_CONTEXT_MAJOR_VERSION, es_api, OSMESA_CONTEXT_MINOR_VERSION, 0, 0 };
    return (osm_ctx)OSMesaCreateContextAttribs(attr, (OSMesaContext)share);
}
void osm_destroy(osm_ctx c) { OSMesaDestroyContext((OSMesaContext)c); }
int osm_make_current(osm_ctx c, void *buf, int w, int h) {
    if (!c) { OSMesaMakeCurrent(NULL, NULL, GL_UNSIGNED_BYTE, 0, 0); return 1; }
    return OSMesaMakeCurrent((OSMesaContext)c, buf, GL_UNSIGNED_BYTE, w, h) ? 1 : 0;
}
void *osm_getproc(const char *name) { return (void *)OSMesaGetProcAddress(name); }
