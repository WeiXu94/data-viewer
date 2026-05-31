#ifndef DTA_CORE_H
#define DTA_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DtaDoc DtaDoc;

typedef enum {
    DTA_NUMERIC,
    DTA_STRING
} DtaColType;

typedef struct {
    int32_t index;
    char *name;
    char *label;
    DtaColType type;
    char *format;
} DtaColumn;

typedef struct {
    int64_t row_count;
    int32_t col_count;
    DtaColumn *columns;
    char *dataset_label;
} DtaMeta;

typedef struct {
    int64_t offset;
    int32_t count;
    int32_t col_count;
    char **cells;
} DtaChunk;

typedef struct {
    int64_t hits;
    int64_t misses;
    int32_t cached_chunks;
    int32_t chunk_size;
} DtaCacheStats;

enum {
    DTA_CORE_OK = 0,
    DTA_CORE_ERROR_ALLOC = -1000,
    DTA_CORE_ERROR_BAD_ARGUMENT = -1001,
    DTA_CORE_ERROR_OVERFLOW = -1002
};

DtaDoc *dta_open(const char *path, int *out_err);
const DtaMeta *dta_metadata(DtaDoc *doc);
DtaChunk *dta_fetch(DtaDoc *doc, int64_t offset, int32_t count);
void dta_chunk_free(DtaChunk *chunk);
void dta_close(DtaDoc *doc);

int dta_last_error(DtaDoc *doc);
DtaCacheStats dta_cache_stats(DtaDoc *doc);
const char *dta_error_message(int code);

#ifdef __cplusplus
}
#endif

#endif
