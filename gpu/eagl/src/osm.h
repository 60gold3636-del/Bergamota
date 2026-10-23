// SPDX-License-Identifier: MIT
// Thin C wrapper around Mesa's OSMesa so that no desktop GL header meets the OpenGLES headers.
#ifndef OSM_H
#define OSM_H
typedef void *osm_ctx;
osm_ctx osm_create(int es_api, osm_ctx share);      // es_api: 1, 2 or 3; returns NULL on failure
void osm_destroy(osm_ctx c);
int osm_make_current(osm_ctx c, void *rgba_buf, int w, int h);   // c == NULL: release the current context
void *osm_getproc(const char *name);
#endif
